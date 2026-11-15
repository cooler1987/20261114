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

class BookParser {
  static const int maxSliceChars = 280;

  /// 在独立 Isolate 中完成文件读取、解码、目录抽提、切片与章节对齐，彻底避免主线程卡顿
  static Future<Map<String, dynamic>> openBookInIsolate(String filePath, String splitMode) {
    return Isolate.run(() async {
      final parsed = await extractFullTextAndChapters(filePath);
      final String fullContent = parsed['fullContent'] as String;
      final List<BookChapter> rawChapters = parsed['chapters'] as List<BookChapter>;
      final List<TextSliceNode> nodes = sliceContent(fullContent, splitMode);
      final List<BookChapter> alignedChapters = alignChapters(rawChapters, nodes);
      return {
        'fingerprint': parsed['fingerprint'],
        'fullContent': fullContent,
        'fileSize': parsed['fileSize'],
        'rawChapters': rawChapters,
        'alignedChapters': alignedChapters,
        'nodes': nodes,
      };
    });
  }

  /// 切换断句模式时在后台 Isolate 重切片
  static Future<Map<String, dynamic>> resliceInIsolate(
    String fullContent,
    List<BookChapter> rawChapters,
    String splitMode,
  ) {
    return Isolate.run(() {
      final nodes = sliceContent(fullContent, splitMode);
      final aligned = alignChapters(rawChapters, nodes);
      return {'nodes': nodes, 'alignedChapters': aligned};
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
        .replaceAll('&copy;', '©');

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

  static String stripHtml(String html) {
    String text = html.replaceAll(RegExp(r'<(script|style|head)\b[^>]*>[\s\S]*?<\/\1>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<(?:p|div|br|h[1-6]|tr|li|blockquote)\b[^>]*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    return _decodeHtmlEntities(text);
  }

  static String cleanMarkdown(String line) {
    String t = line.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    t = t.replaceAll(RegExp(r'!\[.*?\]\(.*?\)'), '');
    t = t.replaceAllMapped(RegExp(r'\[(.*?)\]\(.*?\)'), (m) => m.group(1) ?? '');
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

  static Future<Map<String, dynamic>> extractFullTextAndChapters(String filePath) async {
    final file = File(filePath);
    final fingerprint = await BookFingerprint.generate(file);
    final bytes = await file.readAsBytes();
    final fileSize = bytes.length;
    final ext = filePath.split('.').last.toLowerCase();

    List<BookChapter> chapters = [];
    String fullContent = "";

    if (ext == "epub") {
      final archive = ZipDecoder().decodeBytes(bytes);
      String opfPath = "";
      try {
        final container = archive.firstWhere((f) => f.name.toLowerCase() == 'meta-inf/container.xml');
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
      final opfFile = archive.firstWhere((f) => f.name.replaceAll('\\', '/') == opfPath);
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
          final navBlockM = RegExp(r'<nav\b[^>]*epub:type=["\x27][^"\x27]*toc[^"\x27]*["\x27][^>]*>([\s\S]*?)</nav>', caseSensitive: false).firstMatch(navHtml) ??
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

      final List<String> spineHrefs = [];
      for (var refMatch in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(opfXml)) {
        final tag = refMatch.group(0)!;
        final idrefM = RegExp(r'idref=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(tag);
        if (idrefM != null && manifest.containsKey(idrefM.group(1)!)) {
          spineHrefs.add(manifest[idrefM.group(1)!]!);
        }
      }

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
                  subOffset = stripHtml(rawHtml.substring(0, idMatch.start)).length;
                }
              }
              chapters.add(BookChapter(
                title: entry.title,
                paragraphIndex: 0,
                charOffset: docBaseOffset + subOffset,
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
      for (var line in raw.split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) continue;

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
        buffer.writeln(cleanMarkdown(trimmed));
        buffer.writeln();
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

  static void _emitSafeSlices(List<TextSliceNode> out, String text, int baseStart) {
    if (text.length <= maxSliceChars) {
      out.add(TextSliceNode(text: text, startOffset: baseStart, endOffset: baseStart + text.length));
      return;
    }

    int cursor = 0;
    while (cursor < text.length) {
      if (text.length - cursor <= maxSliceChars) {
        final tail = text.substring(cursor).trim();
        if (tail.isNotEmpty) {
          out.add(TextSliceNode(text: tail, startOffset: baseStart + cursor, endOffset: baseStart + text.length));
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
          while (cut < text.length && '”’」』）)'.contains(text[cut])) {
            cut++;
          }
          break;
        }
      }
      if (cut == -1) cut = searchLimit;

      final part = text.substring(cursor, cut).trim();
      if (part.isNotEmpty) {
        out.add(TextSliceNode(text: part, startOffset: baseStart + cursor, endOffset: baseStart + cut));
      }
      cursor = cut;
      while (cursor < text.length && text[cursor] == ' ') {
        cursor++;
      }
    }
  }

  static List<TextSliceNode> sliceContent(String fullContent, String splitMode) {
    final nodes = <TextSliceNode>[];
    if (fullContent.isEmpty) return nodes;

    final hasReadable = RegExp(r'[\w\u4e00-\u9fa5]');

    if (splitMode == 'paragraph') {
      final matches = RegExp(r'[^\r\n]+(?:\r?\n[^\r\n]+)*').allMatches(fullContent);
      for (final m in matches) {
        final raw = m.group(0) ?? '';
        final trimmed = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join(' ');
        if (trimmed.isNotEmpty && hasReadable.hasMatch(trimmed)) {
          _emitSafeSlices(nodes, trimmed, m.start);
        }
      }
    } else {
      final matches = RegExp(r'[^。！？；?!;\r\n]+(?:[。！？；?!;]+[”’」』）\)]*|\r?\n+)?').allMatches(fullContent);
      for (final m in matches) {
        final trimmed = m.group(0)?.trim() ?? '';
        if (trimmed.isNotEmpty && hasReadable.hasMatch(trimmed)) {
          _emitSafeSlices(nodes, trimmed, m.start);
        }
      }
    }

    if (nodes.isEmpty && fullContent.trim().isNotEmpty) {
      nodes.add(TextSliceNode(text: fullContent.trim(), startOffset: 0, endOffset: fullContent.length));
    }
    return nodes;
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
