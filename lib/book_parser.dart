import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fast_gbk/fast_gbk.dart';

import 'models.dart';

class BookFingerprint {
  static Future<String> generate(File file) async {
    try {
      if (!await file.exists()) return "";
      final int length = await file.length();
      if (length == 0) return "fp_empty_0";

      final raf = await file.open(mode: FileMode.read);
      try {
        final headerLen = min(4096, length);
        final header = await raf.read(headerLen);
        List<int> footer = [];
        if (length > 4096) {
          final footerLen = min(4096, length - 4096);
          await raf.setPosition(length - footerLen);
          footer = await raf.read(footerLen);
        }
        final builder = BytesBuilder(copy: false)
          ..add(utf8.encode('$length:'))
          ..add(header);
        if (footer.isNotEmpty) {
          builder.add(footer);
        }
        return md5.convert(builder.takeBytes()).toString();
      } finally {
        await raf.close();
      }
    } catch (_) {
      return "fp_${file.path.hashCode}";
    }
  }
}

class _TocEntry {
  final String title;
  final int level;
  final String? fragmentId;
  _TocEntry({required this.title, required this.level, this.fragmentId});
}

class _SliceCandidate {
  final String text;
  final int startOffset;
  final int endOffset;
  const _SliceCandidate({required this.text, required this.startOffset, required this.endOffset});
}

class BookParser {
  static const int maxSliceChars = 280;
  static const int _cacheSchemaVersion = 2;
  static const int _maxCachedBooks = 5;

  static final RegExp _hasReadableReg = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static const Set<String> _enAbbreviations = {
    'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc',
    'fig', 'vol', 'no', 'inc', 'ltd', 'co', 'gen', 'col', 'lt', 'sgt',
    'capt', 'rev', 'hon', 'pres', 'gov', 'e.g', 'i.e',
  };

  /// 在独立 Isolate 中完成文件读取/缓存命中、解码、目录抽提、自然段与智能合并切片
  static Future<Map<String, dynamic>> openBookInIsolate(
    String filePath,
    String splitMode,
    int mergeMinChars, {
    String? cacheDirPath,
  }) {
    return Isolate.run(() async {
      final file = File(filePath);
      final fingerprint = await BookFingerprint.generate(file);
      final actualLen = await file.length();

      String? fullContent;
      List<BookChapter>? rawChapters;
      int fileSize = actualLen;
      bool cacheHit = false;

      // 尝试命中基于文件指纹的解析缓存，实现超大书籍二次秒开
      File? cacheFile;
      if (cacheDirPath != null && cacheDirPath.isNotEmpty && fingerprint.isNotEmpty) {
        cacheFile = File('$cacheDirPath${Platform.pathSeparator}parsed_$fingerprint.json');
        if (await cacheFile.exists()) {
          try {
            final rawCache = await cacheFile.readAsString();
            final decoded = jsonDecode(rawCache);
            if (decoded is Map &&
                decoded['v'] == _cacheSchemaVersion &&
                decoded['fileSize'] == actualLen &&
                decoded['fullContent'] is String) {
              fullContent = decoded['fullContent'] as String;
              fileSize = actualLen;
              final chList = decoded['chapters'];
              if (chList is List) {
                rawChapters = chList
                    .whereType<Map>()
                    .map((e) => BookChapter.fromMap(Map<String, dynamic>.from(e)))
                    .toList();
              } else {
                rawChapters = [];
              }
              cacheHit = true;
              try {
                await cacheFile.setLastModified(DateTime.now());
              } catch (_) {}
            }
          } catch (_) {
            fullContent = null;
            rawChapters = null;
          }
        }
      }

      if (fullContent == null || rawChapters == null) {
        final parsed = await extractFullTextAndChapters(filePath, precomputedFingerprint: fingerprint);
        fullContent = parsed['fullContent'] as String;
        rawChapters = parsed['chapters'] as List<BookChapter>;
        fileSize = parsed['fileSize'] as int;

        if (cacheFile != null && fullContent.isNotEmpty) {
          try {
            final dir = cacheFile.parent;
            if (!await dir.exists()) await dir.create(recursive: true);
            await cacheFile.writeAsString(
              jsonEncode({
                'v': _cacheSchemaVersion,
                'fileSize': fileSize,
                'fullContent': fullContent,
                'chapters': rawChapters.map((c) => c.toMap()).toList(),
              }),
              flush: false,
            );
            await _pruneOldCacheFiles(dir);
          } catch (_) {}
        }
      }

      final sliced = parseParagraphsAndSlices(fullContent, rawChapters, splitMode, mergeMinChars);
      final List<BookParagraph> paragraphs = sliced['paragraphs'] as List<BookParagraph>;
      final List<TextSliceNode> nodes = sliced['nodes'] as List<TextSliceNode>;
      final List<BookChapter> alignedChapters = alignChapters(rawChapters, nodes);

      return {
        'fingerprint': fingerprint,
        'fullContent': fullContent,
        'fileSize': fileSize,
        'rawChapters': rawChapters,
        'alignedChapters': alignedChapters,
        'paragraphs': paragraphs,
        'nodes': nodes,
        'cacheHit': cacheHit,
      };
    });
  }

  static Future<void> _pruneOldCacheFiles(Directory dir) async {
    try {
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.split(Platform.pathSeparator).last.startsWith('parsed_')) {
          files.add(entity);
        }
      }
      if (files.length <= _maxCachedBooks) return;
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (int i = _maxCachedBooks; i < files.length; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 切换断句模式或短句智能合并阈值时在后台 Isolate 重切片
  static Future<Map<String, dynamic>> resliceInIsolate(
    String fullContent,
    List<BookChapter> rawChapters,
    String splitMode,
    int mergeMinChars,
  ) {
    return Isolate.run(() {
      final sliced = parseParagraphsAndSlices(fullContent, rawChapters, splitMode, mergeMinChars);
      final List<BookParagraph> paragraphs = sliced['paragraphs'] as List<BookParagraph>;
      final List<TextSliceNode> nodes = sliced['nodes'] as List<TextSliceNode>;
      final aligned = alignChapters(rawChapters, nodes);
      return {
        'paragraphs': paragraphs,
        'nodes': nodes,
        'alignedChapters': aligned,
      };
    });
  }

  /// 在独立 Isolate 执行全文搜索，支持跨句/跨段短语精准定位
  static Future<List<SearchHit>> searchInIsolate(
    String fullContent,
    String query,
    List<TextSliceNode> nodes,
    List<BookParagraph> paragraphs, {
    int maxHits = 2000,
  }) {
    return Isolate.run(() {
      final cleanQuery = query.trim().toLowerCase();
      if (cleanQuery.isEmpty || fullContent.isEmpty || nodes.isEmpty) return <SearchHit>[];

      final lowerFull = fullContent.toLowerCase();
      final qLen = cleanQuery.length;
      final hits = <SearchHit>[];

      int cursor = 0;
      while (hits.length < maxHits) {
        final idx = lowerFull.indexOf(cleanQuery, cursor);
        if (idx == -1) break;
        final sliceIdx = findIndexByCharOffset(nodes, idx);
        final paraIdx = findParagraphByCharOffset(paragraphs, idx);
        hits.add(SearchHit(charOffset: idx, sliceIndex: sliceIdx, paraIndex: paraIdx));
        cursor = idx + max(1, qLen);
      }
      return hits;
    });
  }

  /// 支持 UTF-8 BOM、UTF-16LE/BE、UTF-8 与 GBK 兜底解码
  static String safeDecode(Uint8List bytes) {
    if (bytes.isEmpty) return "";
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      try {
        return utf8.decode(bytes.sublist(3));
      } catch (_) {}
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }

    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return String.fromCharCodes(bytes);
      }
    }
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final len = bytes.length & ~1;
    final units = Uint16List(len ~/ 2);
    for (int i = 0; i < len; i += 2) {
      units[i ~/ 2] = littleEndian ? (bytes[i] | (bytes[i + 1] << 8)) : ((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static String _decodeHtmlEntities(String text) {
    var out = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', '　')
        .replaceAll('&thinsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '…')
        .replaceAll('&middot;', '·')
        .replaceAll('&bull;', '•')
        .replaceAll('&times;', '×')
        .replaceAll('&divide;', '÷')
        .replaceAll('&deg;', '°')
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        .replaceAll('&trade;', '™');

    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return (code != null && code > 0 && code <= 0x10FFFF) ? String.fromCharCode(code) : m.group(0)!;
    });
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      return (code != null && code > 0 && code <= 0x10FFFF) ? String.fromCharCode(code) : m.group(0)!;
    });
    return out;
  }

  /// 改进版 HTML 清洗：先折叠源码缩进换行，再处理块级标签换行，避免句中产生多余断行
  static String stripHtml(String html) {
    String text = html.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    text = text.replaceAll(RegExp(r'<(script|style|head|svg)\b[^>]*>[\s\S]*?<\/\1>', caseSensitive: false), '');
    // 规范化 HTML 源码自带的缩进和换行空白
    text = text.replaceAll(RegExp(r'[\r\n\t ]+'), ' ');
    // 块级标签与换行符转回真实换行
    text = text.replaceAll(RegExp(r'<(?:br|hr)\b[^>]*\/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<\/?(?:p|div|h[1-6]|tr|li|blockquote|section|article|dt|dd)\b[^>]*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = _decodeHtmlEntities(text);
    text = text.replaceAll(RegExp(r' *\n *'), '\n');
    text = text.replaceAll(RegExp(r'\n{2,}'), '\n');
    return text.trim();
  }

  static String cleanMarkdown(String line) {
    String t = line.replaceAll(RegExp(r'!\[.*?\]\(.*?\)'), '');
    t = t.replaceAllMapped(RegExp(r'\[(.*?)\]\(.*?\)'), (m) => m.group(1) ?? '');
    t = t.replaceAll(RegExp(r'^#{1,6}\s+'), '');
    t = t.replaceAll(RegExp(r'(\*\*|__|\*|_|~~|`)'), '');
    t = t.replaceAll(RegExp(r'^\s*>\s*'), '');
    t = t.replaceAll(RegExp(r'^\s*[-*+]\s+'), '');
    t = t.replaceAll(RegExp(r'^\s*\d+\.\s+'), '');
    return t.trim();
  }

  static String _normalizeZipPath(String baseDir, String relativeHref) {
    final cleanHref = Uri.decodeFull(relativeHref).split('#').first.replaceAll('\\', '/').trim();
    final combined = baseDir.isEmpty ? cleanHref : '$baseDir/$cleanHref';
    final parts = combined.split('/');
    final stack = <String>[];
    for (final p in parts) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') {
        if (stack.isNotEmpty) stack.removeLast();
      } else {
        stack.add(p);
      }
    }
    return stack.join('/');
  }

  static ArchiveFile? _findArchiveFile(Archive archive, String normalizedPath, String rawHref) {
    final targetLower = normalizedPath.toLowerCase();
    for (final f in archive) {
      if (f.name.replaceAll('\\', '/').toLowerCase() == targetLower) return f;
    }
    final fileName = rawHref.split('#').first.replaceAll('\\', '/').split('/').last.toLowerCase();
    for (final f in archive) {
      final fName = f.name.replaceAll('\\', '/').split('/').last.toLowerCase();
      if (fName == fileName) return f;
    }
    return null;
  }

  static Future<Map<String, dynamic>> extractFullTextAndChapters(
    String filePath, {
    String? precomputedFingerprint,
  }) async {
    final file = File(filePath);
    final fingerprint = precomputedFingerprint ?? await BookFingerprint.generate(file);
    final bytes = await file.readAsBytes();
    final fileSize = bytes.length;
    final ext = filePath.split('.').last.toLowerCase();

    List<BookChapter> chapters = [];
    String fullContent = "";

    if (ext == "epub") {
      final archive = ZipDecoder().decodeBytes(bytes);
      String opfPath = "";
      try {
        final container = archive.firstWhere((f) => f.name.replaceAll('\\', '/').toLowerCase() == 'meta-inf/container.xml');
        final xmlStr = safeDecode(Uint8List.fromList(container.content as List<int>));
        final match = RegExp(r'full-path=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(xmlStr);
        if (match != null) opfPath = match.group(1)!.replaceAll('\\', '/');
      } catch (_) {}

      if (opfPath.isEmpty) {
        for (var f in archive) {
          if (f.name.toLowerCase().endsWith('.opf')) {
            opfPath = f.name.replaceAll('\\', '/');
            break;
          }
        }
      }
      if (opfPath.isEmpty) throw Exception("未找到 EPUB 描述清单 (OPF)");

      final String opfDir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/')) : '';
      final opfFile = _findArchiveFile(archive, opfPath, opfPath);
      if (opfFile == null) throw Exception("无法读取 OPF 描述文件 ($opfPath)");
      final opfXml = safeDecode(Uint8List.fromList(opfFile.content as List<int>));

      final Map<String, String> manifest = {};
      String? ncxHref;
      String? navHref;

      for (var itemMatch in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opfXml)) {
        final tag = itemMatch.group(0)!;
        final idM = RegExp(r'id=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(tag);
        final hrefM = RegExp(r'href=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(tag);
        final mediaM = RegExp(r'media-type=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(tag);
        final propM = RegExp(r'properties=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(tag);

        if (idM != null && hrefM != null) {
          final id = idM.group(1)!;
          final href = Uri.decodeFull(hrefM.group(1)!);
          manifest[id] = href;
          if (id.toLowerCase() == 'ncx' || (mediaM != null && mediaM.group(1)!.contains('x-dtbncx+xml'))) {
            ncxHref = href;
          }
          if (propM != null && RegExp(r'\bnav\b', caseSensitive: false).hasMatch(propM.group(1)!)) {
            navHref = href;
          }
        }
      }

      final Map<String, List<_TocEntry>> tocByDocPath = {};

      if (ncxHref != null) {
        final ncxNorm = _normalizeZipPath(opfDir, ncxHref);
        final ncxDir = ncxNorm.contains('/') ? ncxNorm.substring(0, ncxNorm.lastIndexOf('/')) : '';
        final ncxFile = _findArchiveFile(archive, ncxNorm, ncxHref);
        if (ncxFile != null && ncxFile.content.isNotEmpty) {
          final ncxXml = safeDecode(Uint8List.fromList(ncxFile.content as List<int>));
          int depth = 0;
          String? currentTitle;

          final tokenReg = RegExp(
            r'(<navPoint\b[^>]*>)|(</navPoint>)|(<navLabel>[\s\S]*?<text>([\s\S]*?)</text>[\s\S]*?</navLabel>)|(<content\s+[^>]*src=["\x27]([^"\x27]+)["\x27])',
            caseSensitive: false,
          );
          for (var m in tokenReg.allMatches(ncxXml)) {
            if (m.group(1) != null) {
              depth++;
              currentTitle = null;
            } else if (m.group(2) != null) {
              if (depth > 0) depth--;
            } else if (m.group(3) != null) {
              currentTitle = stripHtml(m.group(4)!.trim());
            } else if (m.group(5) != null) {
              final rawSrc = Uri.decodeFull(m.group(6)!.trim());
              final parts = rawSrc.split('#');
              final srcNorm = _normalizeZipPath(ncxDir, parts.first).toLowerCase();
              final frag = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
              if (currentTitle != null && currentTitle.isNotEmpty) {
                tocByDocPath.putIfAbsent(srcNorm, () => []).add(
                      _TocEntry(title: currentTitle, level: max(0, depth - 1), fragmentId: frag),
                    );
              }
            }
          }
        }
      }

      if (tocByDocPath.isEmpty && navHref != null) {
        final navNorm = _normalizeZipPath(opfDir, navHref);
        final navDir = navNorm.contains('/') ? navNorm.substring(0, navNorm.lastIndexOf('/')) : '';
        final navFile = _findArchiveFile(archive, navNorm, navHref);
        if (navFile != null && navFile.content.isNotEmpty) {
          final navHtml = safeDecode(Uint8List.fromList(navFile.content as List<int>));
          final navBlockM =
              RegExp(r'<nav\b[^>]*epub:type=["\x27][^"\x27]*toc[^"\x27]*["\x27][^>]*>([\s\S]*?)</nav>', caseSensitive: false).firstMatch(navHtml) ??
                  RegExp(r'<nav\b[^>]*>([\s\S]*?)</nav>', caseSensitive: false).firstMatch(navHtml);
          final scope = navBlockM?.group(1) ?? navHtml;
          int olDepth = 0;
          final tokenReg = RegExp(r'(<ol\b[^>]*>)|(</ol>)|(<a\b[^>]*href=["\x27]([^"\x27]+)["\x27][^>]*>([\s\S]*?)</a>)', caseSensitive: false);
          for (var m in tokenReg.allMatches(scope)) {
            if (m.group(1) != null) {
              olDepth++;
            } else if (m.group(2) != null) {
              if (olDepth > 0) olDepth--;
            } else if (m.group(3) != null) {
              final rawHref = Uri.decodeFull(m.group(4)!.trim());
              final title = stripHtml(m.group(5)!).trim();
              if (title.isEmpty) continue;
              final parts = rawHref.split('#');
              final srcNorm = _normalizeZipPath(navDir, parts.first).toLowerCase();
              final frag = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
              tocByDocPath.putIfAbsent(srcNorm, () => []).add(
                    _TocEntry(title: title, level: max(0, olDepth - 1), fragmentId: frag),
                  );
            }
          }
        }
      }

      final List<String> linearSpineHrefs = [];
      final List<String> allSpineHrefs = [];
      for (var refMatch in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(opfXml)) {
        final tag = refMatch.group(0)!;
        final idrefM = RegExp(r'idref=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(tag);
        if (idrefM != null && manifest.containsKey(idrefM.group(1)!)) {
          final href = manifest[idrefM.group(1)!]!;
          allSpineHrefs.add(href);
          final isNonLinear = RegExp(r'\blinear\s*=\s*["\x27]no["\x27]', caseSensitive: false).hasMatch(tag);
          if (!isNonLinear) {
            linearSpineHrefs.add(href);
          }
        }
      }
      final spineHrefs = linearSpineHrefs.isNotEmpty ? linearSpineHrefs : allSpineHrefs;

      final buffer = StringBuffer();
      for (var href in spineHrefs) {
        final docNorm = _normalizeZipPath(opfDir, href);
        final docFile = _findArchiveFile(archive, docNorm, href);
        if (docFile == null || docFile.content.isEmpty) continue;

        final String rawHtml = safeDecode(Uint8List.fromList(docFile.content as List<int>));
        final String docKey = docNorm.toLowerCase();
        final tocEntries = tocByDocPath[docKey];

        if (tocEntries != null && tocEntries.length > 1 && tocEntries.any((e) => e.fragmentId != null)) {
          final docBaseOffset = buffer.length;
          final plainFull = stripHtml(rawHtml);
          if (plainFull.trim().isNotEmpty) {
            for (final entry in tocEntries) {
              int subOffset = 0;
              if (entry.fragmentId != null) {
                final idMatch = RegExp('id=["\x27]${RegExp.escape(entry.fragmentId!)}["\x27]', caseSensitive: false).firstMatch(rawHtml);
                if (idMatch != null) {
                  // 从完整标签起始 '<' 前截断，防止截断在 <h2 id="..."> 中间导致残留 <h2 污染偏移量
                  final tagStart = rawHtml.lastIndexOf('<', idMatch.start);
                  final cutPos = tagStart >= 0 ? tagStart : idMatch.start;
                  final prefixText = stripHtml(rawHtml.substring(0, cutPos));
                  subOffset = prefixText.isEmpty ? 0 : prefixText.length + 1;
                }
              }
              chapters.add(BookChapter(
                title: entry.title,
                paragraphIndex: 0,
                charOffset: min(docBaseOffset + subOffset, docBaseOffset + plainFull.length),
                level: entry.level,
              ));
            }
            buffer.writeln(plainFull);
            buffer.writeln();
          }
        } else {
          String chapterTitle = "";
          int chapterLevel = 0;
          if (tocEntries != null && tocEntries.isNotEmpty) {
            chapterTitle = tocEntries.first.title;
            chapterLevel = tocEntries.first.level;
          } else {
            final hMatch = RegExp(r'<(h[1-6]|title)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false).firstMatch(rawHtml);
            if (hMatch != null) {
              final tag = hMatch.group(1)!.toLowerCase();
              chapterTitle = stripHtml(hMatch.group(2)!).trim();
              if (tag == 'h1') {
                chapterLevel = 0;
              } else if (tag == 'h2') {
                chapterLevel = 1;
              } else if (tag == 'h3') {
                chapterLevel = 2;
              }
            }
          }

          final String plainText = stripHtml(rawHtml);
          if (plainText.trim().isNotEmpty) {
            final int offset = buffer.length;
            if (chapterTitle.isEmpty) {
              chapterTitle = plainText.trim().split('\n').first;
              if (chapterTitle.length > 25) chapterTitle = chapterTitle.substring(0, 25);
            }
            chapters.add(BookChapter(
              title: chapterTitle,
              paragraphIndex: 0,
              charOffset: offset,
              level: chapterLevel,
            ));
            buffer.writeln(plainText);
            buffer.writeln();
          }
        }
      }
      fullContent = buffer.toString();
    } else if (ext == "md" || ext == "markdown") {
      final raw = safeDecode(bytes);
      final mdHeadingReg = RegExp(r'^(#{1,4})\s+(.+)$');
      final traditionalChapReg = RegExp(r'^\s*(第[0-9一二三四五六七八九十百千两]+[章卷回节篇部](?:\s+[^\r\n]{0,35}|\s*$))');

      final buffer = StringBuffer();
      bool inCodeFence = false;
      String fenceMarker = '';

      for (var line in raw.split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        // 状态机跳过跨行 Markdown 代码块，防止代码语法和 # 注释干扰章节识别与朗读
        if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
          final marker = trimmed.substring(0, 3);
          if (!inCodeFence) {
            inCodeFence = true;
            fenceMarker = marker;
          } else if (marker == fenceMarker) {
            inCodeFence = false;
            fenceMarker = '';
          }
          continue;
        }
        if (inCodeFence) continue;

        final hMatch = mdHeadingReg.firstMatch(trimmed);
        if (hMatch != null) {
          final int level = (hMatch.group(1)!.length - 1).clamp(0, 3);
          chapters.add(BookChapter(
            title: cleanMarkdown(hMatch.group(2)!.trim()),
            paragraphIndex: 0,
            charOffset: buffer.length,
            level: level,
          ));
        } else {
          final cMatch = traditionalChapReg.firstMatch(trimmed);
          if (cMatch != null && !trimmed.endsWith('。')) {
            final titleStr = cMatch.group(1)!.trim();
            final int level = (titleStr.contains('卷') || titleStr.contains('部')) ? 0 : 1;
            chapters.add(BookChapter(
              title: titleStr,
              paragraphIndex: 0,
              charOffset: buffer.length,
              level: level,
            ));
          }
        }
        final cleanedLine = cleanMarkdown(trimmed);
        if (cleanedLine.isNotEmpty) {
          buffer.writeln(cleanedLine);
          buffer.writeln();
        }
      }
      fullContent = buffer.toString();
    } else {
      final raw = safeDecode(bytes);
      final volumeReg = RegExp(r'^\s*(第[0-9一二三四五六七八九十百千两]+[卷部集册分](?:$|[\s：:][^\r\n]{0,35}))');
      final chapterReg = RegExp(
        r'^\s*((?:第[0-9一二三四五六七八九十百千两]+[章回节篇](?:$|[\s：:][^\r\n]{0,35}))|(?:(?:序章|序言|楔子|引子|尾声|后记|番外(?:\s*[^\r\n]{0,25})?)$)|(?:Chapter\s+\d+[^\r\n]{0,35}))',
        caseSensitive: false,
      );

      final buffer = StringBuffer();
      for (var line in raw.split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final vMatch = volumeReg.firstMatch(trimmed);
        if (vMatch != null && trimmed.length <= 42) {
          chapters.add(BookChapter(title: vMatch.group(1)!.trim(), paragraphIndex: 0, charOffset: buffer.length, level: 0));
        } else {
          final cMatch = chapterReg.firstMatch(trimmed);
          if (cMatch != null && trimmed.length <= 45 && !RegExp(r'[。！？；,.，]$').hasMatch(trimmed)) {
            chapters.add(BookChapter(title: cMatch.group(1)!.trim(), paragraphIndex: 0, charOffset: buffer.length, level: 1));
          }
        }
        buffer.writeln(trimmed);
        buffer.writeln();
      }
      fullContent = buffer.toString();
    }

    if (chapters.isNotEmpty) {
      final minLevel = chapters.map((c) => c.level).fold<int>(99, (prev, elem) => min(prev, elem));
      if (minLevel > 0) {
        chapters = chapters
            .map((c) => BookChapter(
                  title: c.title,
                  paragraphIndex: c.paragraphIndex,
                  charOffset: c.charOffset,
                  level: max(0, c.level - minLevel),
                ))
            .toList();
      }
    }

    return {
      "fingerprint": fingerprint,
      "fullContent": fullContent,
      "chapters": chapters,
      "fileSize": fileSize,
    };
  }

  static void _emitSafeSlices(List<_SliceCandidate> out, String text, int baseStart) {
    if (text.length <= maxSliceChars) {
      out.add(_SliceCandidate(text: text, startOffset: baseStart, endOffset: baseStart + text.length));
      return;
    }

    int cursor = 0;
    while (cursor < text.length) {
      if (text.length - cursor <= maxSliceChars) {
        final tail = text.substring(cursor).trim();
        if (tail.isNotEmpty) {
          final leadSpaces = text.substring(cursor).length - text.substring(cursor).trimLeft().length;
          final trailSpaces = text.substring(cursor).length - text.substring(cursor).trimRight().length;
          out.add(_SliceCandidate(
            text: tail,
            startOffset: baseStart + cursor + leadSpaces,
            endOffset: baseStart + text.length - trailSpaces,
          ));
        }
        break;
      }

      int cut = -1;
      final searchLimit = min(text.length, cursor + maxSliceChars);
      final minAccept = cursor + (maxSliceChars ~/ 2);
      for (int i = searchLimit - 1; i >= minAccept; i--) {
        final ch = text[i];
        if ('，,、：:;； '.contains(ch)) {
          cut = i + 1;
          while (cut < text.length && '”’」』）)"\''.contains(text[cut])) {
            cut++;
          }
          break;
        }
      }
      if (cut == -1) cut = searchLimit;

      final rawPart = text.substring(cursor, cut);
      final part = rawPart.trim();
      if (part.isNotEmpty) {
        final leadSpaces = rawPart.length - rawPart.trimLeft().length;
        final trailSpaces = rawPart.length - rawPart.trimRight().length;
        out.add(_SliceCandidate(
          text: part,
          startOffset: baseStart + cursor + leadSpaces,
          endOffset: baseStart + cut - trailSpaces,
        ));
      }
      cursor = cut;
      while (cursor < text.length && text[cursor] == ' ') {
        cursor++;
      }
    }
  }

  static bool _isAsciiLetterOrDigit(int code) {
    return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  static bool _isDigit(int code) => code >= 48 && code <= 57;

  static bool _isEnglishSentenceEnd(String text, int dotIdx) {
    // 排除省略号内部点号 (如 "..." 的前两个点)
    if (dotIdx + 1 < text.length && text[dotIdx + 1] == '.') return false;
    final bool isEllipsisEnd = dotIdx >= 2 && text[dotIdx - 1] == '.' && text[dotIdx - 2] == '.';
    if (isEllipsisEnd) return true;

    // 排除小数 / IP / 版本号 (如 3.14)
    if (dotIdx > 0 && dotIdx + 1 < text.length && _isDigit(text.codeUnitAt(dotIdx - 1)) && _isDigit(text.codeUnitAt(dotIdx + 1))) {
      return false;
    }

    // 排除单个字母缩写或常见英文缩写词 (Mr. Dr. U.S.A. e.g.)
    int wordStart = dotIdx - 1;
    while (wordStart >= 0 && (_isAsciiLetterOrDigit(text.codeUnitAt(wordStart)) || text[wordStart] == '.')) {
      wordStart--;
    }
    final word = text.substring(wordStart + 1, dotIdx).toLowerCase();
    if (word.isNotEmpty) {
      if (word.length == 1 && RegExp(r'[a-z]').hasMatch(word)) return false;
      if (_enAbbreviations.contains(word)) return false;
    }

    // 点号后面若紧跟非空白且非引号/括号的字母数字，通常为域名/文件名
    if (dotIdx + 1 < text.length) {
      final nextChar = text[dotIdx + 1];
      if (!' \t”’」』）)"\''.contains(nextChar)) {
        return false;
      }
    }
    return true;
  }

  /// 国际化自然段内按句切分（支持中文句读、省略号、以及排除小数/缩写的英文句号）
  static void _splitParagraphIntoSentences(List<_SliceCandidate> out, String text, int baseOffset) {
    int start = 0;
    int i = 0;
    final len = text.length;

    while (i < len) {
      final ch = text[i];
      bool isBoundary = false;

      if ('。！？；?!;'.contains(ch)) {
        while (i + 1 < len && '。！？；?!;'.contains(text[i + 1])) {
          i++;
        }
        isBoundary = true;
      } else if (ch == '…') {
        while (i + 1 < len && text[i + 1] == '…') {
          i++;
        }
        isBoundary = true;
      } else if (ch == '.') {
        if (_isEnglishSentenceEnd(text, i)) {
          isBoundary = true;
        }
      }

      if (isBoundary) {
        int end = i + 1;
        while (end < len && '”’」』）)"\''.contains(text[end])) {
          end++;
        }
        final rawSeg = text.substring(start, end);
        final trimmed = rawSeg.trim();
        if (trimmed.isNotEmpty && _hasReadableReg.hasMatch(trimmed)) {
          final lead = rawSeg.length - rawSeg.trimLeft().length;
          final trail = rawSeg.length - rawSeg.trimRight().length;
          _emitSafeSlices(out, trimmed, baseOffset + start + lead);
          // 跳过 trailing
          start = end;
          while (start < len && text[start] == ' ') {
            start++;
          }
          i = start;
          if (trail > 0) {}
          continue;
        }
        start = end;
        i = start;
        continue;
      }
      i++;
    }

    if (start < len) {
      final rawTail = text.substring(start);
      final trimmed = rawTail.trim();
      if (trimmed.isNotEmpty && _hasReadableReg.hasMatch(trimmed)) {
        final lead = rawTail.length - rawTail.trimLeft().length;
        _emitSafeSlices(out, trimmed, baseOffset + start + lead);
      }
    }
  }

  /// 同时产出“自然段渲染列表”与“TTS切片列表（含智能合并 >= X 字）”
  static Map<String, dynamic> parseParagraphsAndSlices(
    String fullContent,
    List<BookChapter> rawChapters,
    String splitMode,
    int mergeMinChars,
  ) {
    final paragraphs = <BookParagraph>[];
    final rawUnits = <_SliceCandidate>[];

    if (fullContent.isEmpty) {
      return {'paragraphs': paragraphs, 'nodes': <TextSliceNode>[]};
    }

    // 1. 提取自然段用于微信读书式流畅排版
    final lineMatches = RegExp(r'[^\r\n]+').allMatches(fullContent);
    for (final m in lineMatches) {
      final raw = m.group(0) ?? '';
      final trimmed = raw.trim();
      if (trimmed.isEmpty || !_hasReadableReg.hasMatch(trimmed)) continue;

      final lead = raw.length - raw.trimLeft().length;
      final trail = raw.length - raw.trimRight().length;
      final pStart = m.start + lead;
      final pEnd = m.end - trail;
      if (pEnd <= pStart) continue;

      paragraphs.add(BookParagraph(text: trimmed, startOffset: pStart, endOffset: pEnd));

      if (splitMode == 'paragraph') {
        _emitSafeSlices(rawUnits, trimmed, pStart);
      } else {
        _splitParagraphIntoSentences(rawUnits, trimmed, pStart);
      }
    }

    // 2. 智能合并短句：将连续短句合并至 >= mergeMinChars 字再发 TTS 请求（绝不跨越章节边界或超过 maxSliceChars）
    final nodes = <TextSliceNode>[];
    if (rawUnits.isNotEmpty) {
      final chapterStarts = rawChapters.map((c) => c.charOffset).toList()..sort();
      final int threshold = mergeMinChars.clamp(0, 200);

      bool crossesChapterBoundary(int curStart, int nextStart) {
        if (chapterStarts.isEmpty) return false;
        int low = 0;
        int high = chapterStarts.length - 1;
        while (low <= high) {
          final mid = (low + high) ~/ 2;
          final cOff = chapterStarts[mid];
          if (cOff > curStart && cOff <= nextStart) {
            return true;
          } else if (cOff <= curStart) {
            low = mid + 1;
          } else {
            high = mid - 1;
          }
        }
        return false;
      }

      if (threshold <= 0) {
        for (final u in rawUnits) {
          nodes.add(TextSliceNode(text: u.text, startOffset: u.startOffset, endOffset: u.endOffset));
        }
      } else {
        final buf = StringBuffer(rawUnits.first.text);
        int curStart = rawUnits.first.startOffset;
        int curEnd = rawUnits.first.endOffset;

        for (int i = 1; i < rawUnits.length; i++) {
          final next = rawUnits[i];
          final hitChapter = crossesChapterBoundary(curStart, next.startOffset);
          final canMergeLen = buf.length < threshold && (buf.length + 1 + next.text.length) <= maxSliceChars;

          if (!hitChapter && canMergeLen) {
            buf.write(' ');
            buf.write(next.text);
            curEnd = next.endOffset;
          } else {
            nodes.add(TextSliceNode(text: buf.toString(), startOffset: curStart, endOffset: curEnd));
            buf.clear();
            buf.write(next.text);
            curStart = next.startOffset;
            curEnd = next.endOffset;
          }
        }
        if (buf.isNotEmpty) {
          nodes.add(TextSliceNode(text: buf.toString(), startOffset: curStart, endOffset: curEnd));
        }
      }
    }

    if (nodes.isEmpty && fullContent.trim().isNotEmpty) {
      final t = fullContent.trim();
      paragraphs.add(BookParagraph(text: t, startOffset: 0, endOffset: t.length));
      nodes.add(TextSliceNode(text: t, startOffset: 0, endOffset: t.length));
    }

    return {'paragraphs': paragraphs, 'nodes': nodes};
  }

  static int findIndexByCharOffset(List<TextSliceNode> nodes, int targetOffset) {
    if (nodes.isEmpty) return 0;
    if (targetOffset <= nodes.first.startOffset) return 0;
    if (targetOffset >= nodes.last.startOffset) return nodes.length - 1;

    int low = 0;
    int high = nodes.length - 1;
    int result = 0;

    while (low <= high) {
      final int mid = (low + high) ~/ 2;
      if (nodes[mid].startOffset <= targetOffset) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  static int findParagraphByCharOffset(List<BookParagraph> paragraphs, int targetOffset) {
    if (paragraphs.isEmpty) return 0;
    if (targetOffset <= paragraphs.first.startOffset) return 0;
    if (targetOffset >= paragraphs.last.startOffset) return paragraphs.length - 1;

    int low = 0;
    int high = paragraphs.length - 1;
    int result = 0;

    while (low <= high) {
      final int mid = (low + high) ~/ 2;
      if (paragraphs[mid].startOffset <= targetOffset) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  static List<BookChapter> alignChapters(List<BookChapter> chapters, List<TextSliceNode> nodes) {
    return chapters
        .map((c) => BookChapter(
              title: c.title,
              paragraphIndex: findIndexByCharOffset(nodes, c.charOffset),
              charOffset: c.charOffset,
              level: c.level,
            ))
        .toList();
  }
}
