import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models.dart';

class _StorageEntry {
  final FileSystemEntity entity;
  final bool isDir;
  final String name;
  final String ext;
  final String metaText;

  _StorageEntry({
    required this.entity,
    required this.isDir,
    required this.name,
    required this.ext,
    required this.metaText,
  });
}

// ────────────────── Android 原生网络与边缘手势桥接 ──────────────────
class AndroidNetworkState {
  final String? systemProxy;
  final bool hasVpn;
  final bool hasBypassNetwork;
  final String summary;

  const AndroidNetworkState({
    this.systemProxy,
    this.hasVpn = false,
    this.hasBypassNetwork = false,
    this.summary = '',
  });
}

class NativeHttpResult {
  final int statusCode;
  final Uint8List bodyBytes;
  final Map<String, String> headers;

  const NativeHttpResult({
    required this.statusCode,
    required this.bodyBytes,
    required this.headers,
  });
}

class AndroidNativeBridge {
  static const MethodChannel _channel = MethodChannel('fish_reader/native');
  static bool _handlerRegistered = false;
  static void Function(String edge)? _onEdgeBackCallback;

  static void registerEdgeBackListener(void Function(String edge) callback) {
    _onEdgeBackCallback = callback;
    if (_handlerRegistered || !Platform.isAndroid) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onEdgeBack') {
        final edge = (call.arguments is Map ? call.arguments['edge'] : null)?.toString() ?? 'unknown';
        _onEdgeBackCallback?.call(edge);
      }
      return null;
    });
  }

  static Future<void> updateEdgeGestureConfig({
    required bool interceptHomeBack,
    required bool excludeEdges,
    required double screenWidthDp,
    required double screenHeightDp,
    required double devicePixelRatio,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setEdgeGestureConfig', {
        'interceptHomeBack': interceptHomeBack,
        'excludeEdges': excludeEdges,
        'screenWidthDp': screenWidthDp,
        'screenHeightDp': screenHeightDp,
        'density': devicePixelRatio,
      });
    } catch (_) {}
  }

  static Future<AndroidNetworkState> getNetworkState() async {
    if (!Platform.isAndroid) {
      return const AndroidNetworkState();
    }
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getNetworkState');
      if (raw == null) return const AndroidNetworkState();
      final proxyRaw = raw['systemProxy']?.toString() ?? '';
      final proxyNorm = normalizeProxyInput(proxyRaw);
      return AndroidNetworkState(
        systemProxy: proxyNorm.isEmpty ? null : proxyNorm,
        hasVpn: raw['hasVpn'] == true,
        hasBypassNetwork: raw['hasBypassNetwork'] == true,
        summary: raw['summary']?.toString() ?? '',
      );
    } catch (_) {
      return const AndroidNetworkState();
    }
  }

  static Future<NativeHttpResult> nativeHttpRequest({
    required String method,
    required String url,
    required Map<String, String> headers,
    Uint8List? bodyBytes,
    int timeoutMs = 60000,
    bool bypassVpn = true,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('nativeHttpRequest', {
      'method': method,
      'url': url,
      'headers': headers,
      'bodyBytes': bodyBytes,
      'timeoutMs': timeoutMs,
      'bypassVpn': bypassVpn,
    });
    if (raw == null) {
      throw const SocketException('原生网络桥接未返回响应');
    }
    final statusCode = (raw['statusCode'] as num?)?.toInt() ?? 0;
    final dynamic rawBody = raw['bodyBytes'];
    final Uint8List bytes = rawBody is Uint8List
        ? rawBody
        : (rawBody is List ? Uint8List.fromList(rawBody.cast<int>()) : Uint8List(0));
    final respHeaders = <String, String>{};
    final rawHeaders = raw['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null) respHeaders[k.toString().toLowerCase()] = v.toString();
      });
    }
    return NativeHttpResult(statusCode: statusCode, bodyBytes: bytes, headers: respHeaders);
  }
}

// ────────────────── 存储权限与专业物理路径文件管理器 (完整文件名防截断) ──────────────────
class StorageHelper {
  static Future<bool> checkAndRequestManagePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    final status2 = await Permission.storage.request();
    if (status2.isGranted) return true;
    await openAppSettings();
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
            ],
          ),
          content: SizedBox(
            width: dialogWidth,
            height: dialogHeight,
            child: FutureBuilder<List<_StorageEntry>>(
              key: ValueKey(current.path),
              future: _listStorageSafe(current, chooseDirectory, extensions),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = snapshot.data ?? [];
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
                    const Divider(height: 12),
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
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
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
                                    padding: const EdgeInsets.only(top: 4),
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
      raw.sort((a, b) {
        final ad = a is Directory;
        final bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    } catch (_) {}

    final entries = <_StorageEntry>[];
    for (final entity in raw) {
      final isDir = entity is Directory;
      final name = entity.path.split(Platform.pathSeparator).last;
      final ext = isDir ? "DIR" : name.split('.').last.toUpperCase();
      String metaText = "文件夹";
      if (entity is File) {
        try {
          final stat = await entity.stat();
          final sizeStr = formatFileSize(stat.size);
          final dateStr = "${stat.modified.year}-${stat.modified.month.toString().padLeft(2, '0')}-${stat.modified.day.toString().padLeft(2, '0')} ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}";
          metaText = "$sizeStr · $dateStr";
        } catch (_) {
          metaText = "文件";
        }
      }
      entries.add(_StorageEntry(entity: entity, isDir: isDir, name: name, ext: ext, metaText: metaText));
    }
    return entries;
  }
}

// ────────────────── 真分级高可用日志系统 (支持 3 层级: error / info / all) ──────────────────
class AppLogger {
  static File? _logFile;
  static String logLevel = "error"; // 'error' | 'info' | 'all'
  static const int _maxLogBytes = 2 * 1024 * 1024;

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
    try {
      final sb = StringBuffer()..writeln(line);
      if (stack != null) {
        sb.writeln("堆栈追踪:\n$stack");
      }
      _logFile?.writeAsStringSync(sb.toString(), mode: FileMode.append, flush: isErr || isImportant);
    } catch (_) {}
  }

  static Future<List<String>> readLogLines({int maxLines = 800}) async {
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
    try {
      if (_logFile != null && await _logFile!.exists()) return await _logFile!.length();
    } catch (_) {}
    return 0;
  }

  static Future<void> clearLogs() async {
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

  // 2. Windows 读取 Internet Settings 注册表
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

  // 3. Android 优先通过 ConnectivityManager 获取真实系统代理，失败再尝试 settings
  if (Platform.isAndroid) {
    final state = await AndroidNativeBridge.getNetworkState();
    if (state.systemProxy != null && state.systemProxy!.isNotEmpty) {
      return state.systemProxy;
    }
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
