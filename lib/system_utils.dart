import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models.dart';

// ────────────────── 全局顶层提示浮条 (始终位于 Dialog / Drawer / 设置页之上) ──────────────────
class AppToast {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;

  static void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    try {
      _currentEntry?.remove();
    } catch (_) {}
    _currentEntry = null;
  }

  static void show(
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
    bool isError = false,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;

    dismiss();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topPad = MediaQuery.of(ctx).padding.top + 10;
        return Positioned(
          top: topPad,
          left: 16,
          right: 16,
          child: IgnorePointer(
            ignoring: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Material(
                  elevation: 14,
                  borderRadius: BorderRadius.circular(14),
                  color: isError ? const Color(0xFF8E2424) : const Color(0xFF2B2D30),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isError ? Icons.error_outline : Icons.info_outline,
                          color: isError ? Colors.amberAccent : const Color(0xFFFFCA6C),
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            message,
                            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
                          ),
                        ),
                        if (actionLabel != null && onAction != null) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFFFCA6C),
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: () {
                              dismiss();
                              onAction();
                            },
                            child: Text(actionLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                        InkWell(
                          onTap: dismiss,
                          borderRadius: BorderRadius.circular(12),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close, size: 15, color: Colors.white60),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _currentEntry = entry;
    overlay.insert(entry);
    _dismissTimer = Timer(duration, () {
      if (_currentEntry == entry) dismiss();
    });
  }
}

class _StorageEntry {
  final FileSystemEntity entity;
  final bool isDir;
  final String name;
  final String ext;
  final int sizeBytes;
  final DateTime modified;
  final String metaText;

  _StorageEntry({
    required this.entity,
    required this.isDir,
    required this.name,
    required this.ext,
    required this.sizeBytes,
    required this.modified,
    required this.metaText,
  });
}

// ────────────────── A 存储权限与专业物理路径文件管理器 (并发stat + 搜索 + 排序 + 新建目录) ──────────────────
class StorageHelper {
  static bool _alreadyOpenedSettingsOnce = false;

  static Future<bool> checkAndRequestManagePermission({bool allowSettingsJump = true}) async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    final status2 = await Permission.storage.request();
    if (status2.isGranted) return true;

    if (allowSettingsJump && !_alreadyOpenedSettingsOnce) {
      _alreadyOpenedSettingsOnce = true;
      await openAppSettings();
    } else {
      AppToast.show("未授予存储管理权限，已切换至系统文件选择器或受限访问", isError: true);
    }
    return false;
  }

  static String getDefaultBackupDir() {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/FishReader';
    } else if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent;
      return '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}Backup';
    } else {
      return '${Directory.current.path}${Platform.pathSeparator}FishReaderBackup';
    }
  }

  static Future<String?> browseSharedStorage(
    BuildContext context, {
    required bool chooseDirectory,
    required List<String> extensions,
    String? initialPath,
  }) async {
    if (!await checkAndRequestManagePermission()) return null;

    Directory current;
    if (initialPath != null && Directory(initialPath).existsSync()) {
      current = Directory(initialPath);
    } else {
      current = Directory('/storage/emulated/0');
      if (!await current.exists()) current = Directory('/storage');
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final dialogWidth = min(660.0, screenWidth - 20);
    final dialogHeight = min(680.0, screenHeight * 0.85);

    String filterQuery = '';
    String sortBy = 'name'; // 'name' | 'time' | 'size'
    bool sortAsc = true;
    int refreshTick = 0;

    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          title: Row(
            children: [
              Icon(chooseDirectory ? Icons.folder : Icons.folder_special, color: const Color(0xFFC87D2E), size: 22),
              const SizedBox(width: 8),
              Text(chooseDirectory ? '选择目录' : '选择文件', style: const TextStyle(fontSize: 16)),
              const Spacer(),
              IconButton(
                tooltip: "新建文件夹",
                icon: const Icon(Icons.create_new_folder_outlined, color: Color(0xFFC87D2E), size: 21),
                onPressed: () async {
                  final folderCtrl = TextEditingController();
                  final created = await showDialog<String>(
                    context: ctx,
                    builder: (mkCtx) => AlertDialog(
                      title: const Text("新建文件夹"),
                      content: TextField(
                        controller: folderCtrl,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: "文件夹名称", isDense: true),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(mkCtx), child: const Text("取消")),
                        FilledButton(
                          onPressed: () => Navigator.pop(mkCtx, folderCtrl.text.trim()),
                          child: const Text("创建"),
                        ),
                      ],
                    ),
                  );
                  folderCtrl.dispose();
                  if (created != null && created.isNotEmpty) {
                    try {
                      final newDir = Directory('${current.path}${Platform.pathSeparator}$created');
                      await newDir.create(recursive: true);
                      current = newDir;
                      setDialogState(() => refreshTick++);
                    } catch (e) {
                      AppToast.show("创建文件夹失败: $e", isError: true);
                    }
                  }
                },
              ),
              PopupMenuButton<String>(
                tooltip: "排序方式",
                icon: const Icon(Icons.sort, size: 20),
                onSelected: (v) {
                  setDialogState(() {
                    if (sortBy == v) {
                      sortAsc = !sortAsc;
                    } else {
                      sortBy = v;
                      sortAsc = v == 'name';
                    }
                  });
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'name', child: Text('按名称 ${sortBy == 'name' ? (sortAsc ? '↑' : '↓') : ''}')),
                  PopupMenuItem(value: 'time', child: Text('按修改时间 ${sortBy == 'time' ? (sortAsc ? '↑' : '↓') : ''}')),
                  PopupMenuItem(value: 'size', child: Text('按大小 ${sortBy == 'size' ? (sortAsc ? '↑' : '↓') : ''}')),
                ],
              ),
            ],
          ),
          content: SizedBox(
            width: dialogWidth,
            height: dialogHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  decoration: InputDecoration(
                    hintText: '过滤当前目录文件名...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) => setDialogState(() => filterQuery = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: FutureBuilder<List<_StorageEntry>>(
                    key: ValueKey('${current.path}#$refreshTick'),
                    future: _listStorageSafe(current, chooseDirectory, extensions),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final rawEntries = snapshot.data ?? [];
                      final entries = rawEntries.where((e) {
                        if (filterQuery.isEmpty) return true;
                        return e.name.toLowerCase().contains(filterQuery);
                      }).toList();

                      entries.sort((a, b) {
                        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
                        int cmp = 0;
                        if (sortBy == 'time') {
                          cmp = a.modified.compareTo(b.modified);
                        } else if (sortBy == 'size') {
                          cmp = a.sizeBytes.compareTo(b.sizeBytes);
                        } else {
                          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                        }
                        return sortAsc ? cmp : -cmp;
                      });

                      final isRoot = current.path == '/storage' || current.path == '/storage/emulated/0';

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: const Color(0xFFEFE7D2), borderRadius: BorderRadius.circular(6)),
                            child: Row(
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: '上一级',
                                  onPressed: isRoot
                                      ? null
                                      : () {
                                          current = current.parent;
                                          setDialogState(() {});
                                        },
                                  icon: const Icon(Icons.arrow_upward, size: 20),
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    reverse: true,
                                    child: Text(
                                      current.path,
                                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                                if (chooseDirectory) ...[
                                  const SizedBox(width: 4),
                                  FilledButton.tonal(
                                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
                                    onPressed: () => Navigator.pop(dialogContext, current.path),
                                    child: const Text('选此目录', style: TextStyle(fontSize: 12)),
                                  ),
                                ]
                              ],
                            ),
                          ),
                          const Divider(height: 10),
                          Expanded(
                            child: entries.isEmpty
                                ? const Center(
                                    child: Text('此目录下无匹配项\n（可点击左侧向上箭头返回上级）', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)),
                                  )
                                : ListView.separated(
                                    itemCount: entries.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFECE7D9)),
                                    itemBuilder: (context, index) {
                                      final item = entries[index];
                                      return ListTile(
                                        dense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                        leading: Icon(
                                          item.isDir ? Icons.folder : Icons.insert_drive_file,
                                          color: item.isDir ? Colors.amber[700] : const Color(0xFFC87D2E),
                                          size: 26,
                                        ),
                                        title: Text(
                                          item.name,
                                          softWrap: true,
                                          style: const TextStyle(fontSize: 13, height: 1.35, fontWeight: FontWeight.w500),
                                        ),
                                        subtitle: Padding(
                                          padding: const EdgeInsets.only(top: 3),
                                          child: Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: item.isDir ? Colors.amber.shade100 : const Color(0xFFEFE7D2),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  item.ext,
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: item.isDir ? Colors.brown : const Color(0xFFC87D2E),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(item.metaText, style: const TextStyle(fontSize: 10.5, color: Colors.blueGrey)),
                                              ),
                                            ],
                                          ),
                                        ),
                                        onTap: () {
                                          if (item.isDir) {
                                            current = item.entity as Directory;
                                            setDialogState(() {});
                                          } else if (!chooseDirectory) {
                                            Navigator.pop(dialogContext, item.entity.path);
                                          }
                                        },
                                      );
                                    },
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          ],
        ),
      ),
    );
  }

  static Future<List<_StorageEntry>> _listStorageSafe(
    Directory dir,
    bool foldersOnly,
    List<String> extensions,
  ) async {
    final raw = <FileSystemEntity>[];
    try {
      await for (final entity in dir.list(followLinks: false).handleError((_) {})) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.') && name != '.nomedia') continue;

        if (entity is Directory) {
          raw.add(entity);
        } else if (!foldersOnly) {
          final ext = name.split('.').last.toLowerCase();
          if (extensions.isEmpty || extensions.contains(ext)) {
            raw.add(entity);
          }
        }
      }
    } catch (_) {}

    // 并发批处理 stat，消除千级文件目录的串行卡顿
    final entries = <_StorageEntry>[];
    const batchSize = 32;
    for (int i = 0; i < raw.length; i += batchSize) {
      final chunk = raw.sublist(i, min(i + batchSize, raw.length));
      final results = await Future.wait(chunk.map((entity) async {
        final isDir = entity is Directory;
        final name = entity.path.split(Platform.pathSeparator).last;
        final ext = isDir ? "DIR" : name.split('.').last.toUpperCase();
        int sizeBytes = 0;
        DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
        String metaText = "文件夹";
        try {
          final stat = await entity.stat();
          modified = stat.modified;
          if (!isDir) {
            sizeBytes = stat.size;
            final sizeStr = formatFileSize(sizeBytes);
            final dateStr =
                "${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} ${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}";
            metaText = "$sizeStr · $dateStr";
          }
        } catch (_) {
          if (!isDir) metaText = "文件";
        }
        return _StorageEntry(
          entity: entity,
          isDir: isDir,
          name: name,
          ext: ext,
          sizeBytes: sizeBytes,
          modified: modified,
          metaText: metaText,
        );
      }));
      entries.addAll(results);
    }
    return entries;
  }
}

// ────────────────── 异步缓冲日志系统 (避免主线程同步写阻塞 UI) ──────────────────
class AppLogger {
  static File? _logFile;
  static String logLevel = "error"; // 'error' | 'info' | 'all'
  static const int _maxLogBytes = 2 * 1024 * 1024;

  static final List<String> _pendingLines = [];
  static Timer? _flushTimer;
  static bool _isFlushing = false;

  static String normalizeLevel(String? raw) {
    if (raw == 'all') return 'all';
    if (raw == 'info') return 'info';
    return 'error';
  }

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}${Platform.pathSeparator}app_debug.log');
      await _rotateIfNeeded();
    } catch (_) {}
  }

  static Future<void> _rotateIfNeeded() async {
    if (_logFile == null || !await _logFile!.exists()) return;
    final len = await _logFile!.length();
    if (len > _maxLogBytes) {
      final content = await _logFile!.readAsString();
      final lines = content.split('\n');
      final kept = lines.length > 600 ? lines.sublist(lines.length - 600).join('\n') : content;
      await _logFile!.writeAsString("[INFO] 日志超过 2MB 已自动截断保留最近 600 行\n$kept", flush: true);
    }
  }

  static void log(String message, [dynamic error, StackTrace? stack, bool isImportant = false]) {
    final bool isErr = error != null;
    if (logLevel == "error" && !isErr) return;
    if (logLevel == "info" && !isErr && !isImportant) return;

    final now = DateTime.now().toIso8601String().substring(11, 23);
    final tag = isErr ? '[ERROR]' : (isImportant ? '[EVENT]' : '[DEBUG]');
    final line = "[$now] $tag $message${isErr ? ' | 异常: $error' : ''}";
    debugPrint(line);

    final sb = StringBuffer()..writeln(line);
    if (stack != null) {
      sb.writeln("堆栈追踪:\n$stack");
    }
    _pendingLines.add(sb.toString());

    if (_pendingLines.length >= 20 || isErr || isImportant) {
      flush();
    } else {
      _flushTimer ??= Timer(const Duration(milliseconds: 500), () {
        _flushTimer = null;
        flush();
      });
    }
  }

  static Future<void> flush() async {
    if (_isFlushing || _pendingLines.isEmpty || _logFile == null) return;
    _isFlushing = true;
    try {
      while (_pendingLines.isNotEmpty) {
        final batch = _pendingLines.join();
        _pendingLines.clear();
        await _logFile!.writeAsString(batch, mode: FileMode.append, flush: false);
      }
    } catch (_) {
    } finally {
      _isFlushing = false;
    }
  }

  static Future<List<String>> readLogLines({int maxLines = 800}) async {
    await flush();
    try {
      if (_logFile != null && await _logFile!.exists()) {
        final content = await _logFile!.readAsString();
        if (content.isEmpty) return [];
        final lines = content.split('\n').where((l) => l.isNotEmpty).toList();
        if (lines.length > maxLines) {
          return lines.sublist(lines.length - maxLines);
        }
        return lines;
      }
    } catch (_) {}
    return [];
  }

  static Future<int> getLogSizeBytes() async {
    await flush();
    try {
      if (_logFile != null && await _logFile!.exists()) return await _logFile!.length();
    } catch (_) {}
    return 0;
  }

  static Future<void> clearLogs() async {
    _pendingLines.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.writeAsString("", flush: true);
      }
    } catch (_) {}
  }
}

// ────────────────── 代理规范化与系统代理探测 ──────────────────
String normalizeProxyInput(String raw) {
  var cleaned = raw.trim().replaceAll(RegExp(r'^https?://', caseSensitive: false), '').replaceAll(RegExp(r'/$'), '');
  if (cleaned.isEmpty) return '';
  if (RegExp(r'^\d{1,5}$').hasMatch(cleaned)) {
    return '127.0.0.1:$cleaned';
  }
  return cleaned;
}

Future<String?> detectSystemProxy() async {
  // 1. 环境变量
  final envProxy = Platform.environment['https_proxy'] ??
      Platform.environment['HTTPS_PROXY'] ??
      Platform.environment['http_proxy'] ??
      Platform.environment['HTTP_PROXY'];
  if (envProxy != null && envProxy.trim().isNotEmpty) {
    final norm = normalizeProxyInput(envProxy);
    if (norm.isNotEmpty) return norm;
  }

  // 2. Dart 内置环境代理探测
  try {
    final found = HttpClient.findProxyFromEnvironment(Uri.parse('https://api.fish.audio'));
    final m = RegExp(r'PROXY\s+([^;\s]+)', caseSensitive: false).firstMatch(found);
    if (m != null) {
      final norm = normalizeProxyInput(m.group(1)!);
      if (norm.isNotEmpty) return norm;
    }
  } catch (_) {}

  // 3. Windows 注册表
  if (Platform.isWindows) {
    try {
      final enableRes = await Process.run(
        'reg',
        ['query', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'ProxyEnable'],
      );
      if (enableRes.exitCode == 0 && enableRes.stdout.toString().contains('0x1')) {
        final serverRes = await Process.run(
          'reg',
          ['query', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'ProxyServer'],
        );
        if (serverRes.exitCode == 0) {
          final match = RegExp(r'ProxyServer\s+REG_SZ\s+([^\r\n]+)').firstMatch(serverRes.stdout.toString());
          if (match != null) {
            String raw = match.group(1)!.trim();
            if (raw.contains('=')) {
              final parts = raw.split(';');
              final pick = parts.firstWhere((p) => p.startsWith('https='), orElse: () => parts.first);
              raw = pick.split('=').last.trim();
            }
            final norm = normalizeProxyInput(raw);
            if (norm.isNotEmpty) return norm;
          }
        }
      }
    } catch (_) {}
  }

  // 4. macOS scutil
  if (Platform.isMacOS) {
    try {
      final res = await Process.run('scutil', ['--proxy']);
      if (res.exitCode == 0) {
        final out = res.stdout.toString();
        final enabled = RegExp(r'HTTPSEnable\s*:\s*1|HTTPEnable\s*:\s*1').hasMatch(out);
        if (enabled) {
          final hostM = RegExp(r'(?:HTTPSProxy|HTTPProxy)\s*:\s*(\S+)').firstMatch(out);
          final portM = RegExp(r'(?:HTTPSPort|HTTPPort)\s*:\s*(\d+)').firstMatch(out);
          if (hostM != null && portM != null) {
            return normalizeProxyInput('${hostM.group(1)}:${portM.group(1)}');
          }
        }
      }
    } catch (_) {}
  }

  // 5. Android 系统全局代理尝试（受沙盒限制，若无法获取建议配合“自定端口”）
  if (Platform.isAndroid) {
    try {
      final res = await Process.run('settings', ['get', 'global', 'http_proxy']);
      if (res.exitCode == 0) {
        final out = res.stdout.toString().trim();
        if (out.isNotEmpty && out != 'null' && out != ':0') {
          final norm = normalizeProxyInput(out);
          if (norm.isNotEmpty) return norm;
        }
      }
    } catch (_) {}
  }
  return null;
}
