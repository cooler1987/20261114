import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'system_utils.dart';
import 'tts_engines.dart';

// ────────────────── 离线 MP3 导出状态控制器 (滑动并发池 + 自动重试 + 流式落盘合并) ──────────────────
class ExportController extends ChangeNotifier {
  bool isExporting = false;
  double progress = 0.0;
  int done = 0;
  int successCount = 0;
  int failedCount = 0;
  int total = 0;
  String status = "";
  bool cancelFlag = false;
  int elapsedSeconds = 0;

  Stopwatch? _stopwatch;
  Timer? _ticker;

  void cancel() {
    cancelFlag = true;
    AppLogger.log("用户主动取消了 MP3 导出任务", null, null, true);
    notifyListeners();
  }

  Future<void> startBackgroundExport({
    required BuildContext hostContext,
    required List<TextSliceNode> nodes,
    required int sIdx,
    required int eIdx,
    required String outDir,
    required String fileNamePrefix,
    required String exportEngine,
    required String exportVoiceId,
    required double exportSpeed,
    required int exportBitrate,
    required int exportThreads,
    required int timeoutSeconds,
    required FishAudioTTS fishTts,
    required List<CustomTtsEngineConfig> customEngines,
    required TtsNetworkRouter networkRouter,
  }) async {
    if (isExporting) return;
    if (!await StorageHelper.checkAndRequestManagePermission()) return;

    final int count = eIdx - sIdx;
    if (count <= 0) return;

    AppLogger.log("启动 MP3 批量导出 [范围: ${sIdx + 1}..$eIdx (共 $count 单元), 引擎: $exportEngine, 并发: $exportThreads]");

    _stopwatch = Stopwatch()..start();
    _ticker?.cancel();
    elapsedSeconds = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedSeconds = _stopwatch?.elapsed.inSeconds ?? 0;
      notifyListeners();
    });

    isExporting = true;
    progress = 0.0;
    done = 0;
    successCount = 0;
    failedCount = 0;
    total = count;
    status = "正在准备临时目录与并发池...";
    cancelFlag = false;
    notifyListeners();

    final tempRoot = await getTemporaryDirectory();
    final chunkDir = Directory("${tempRoot.path}${Platform.pathSeparator}mp3_export_${DateTime.now().millisecondsSinceEpoch}");
    await chunkDir.create(recursive: true);

    final List<bool> chunkOk = List.filled(count, false);
    int nextCursor = 0;
    final int workerCount = min(exportThreads.clamp(1, 16), count);

    Future<void> runWorker() async {
      while (!cancelFlag) {
        final int taskIdx = nextCursor++;
        if (taskIdx >= count) break;
        final int pIdx = sIdx + taskIdx;

        Uint8List? audioBytes;
        for (int attempt = 0; attempt < 3; attempt++) {
          if (cancelFlag) break;
          try {
            audioBytes = await synthesizeWithEngine(
              engineId: exportEngine,
              text: nodes[pIdx].text,
              voiceId: exportVoiceId,
              speed: exportSpeed,
              bitrate: exportBitrate,
              timeoutSeconds: timeoutSeconds,
              fishTts: fishTts,
              customEngines: customEngines,
              networkRouter: networkRouter,
            );
            break;
          } catch (e) {
            if (attempt == 2) {
              AppLogger.log("导出切片 #${pIdx + 1} 经 3 次尝试后失败", e);
            } else {
              await Future.delayed(Duration(milliseconds: 350 * (attempt + 1)));
            }
          }
        }

        if (audioBytes != null && audioBytes.isNotEmpty && !cancelFlag) {
          final cleaned = stripId3Tags(audioBytes);
          final chunkFile = File("${chunkDir.path}${Platform.pathSeparator}${taskIdx.toString().padLeft(6, '0')}.mp3");
          await chunkFile.writeAsBytes(cleaned, flush: false);
          chunkOk[taskIdx] = true;
          successCount++;
        } else if (!cancelFlag) {
          failedCount++;
        }

        done++;
        progress = done / count;
        status = "已完成 $done/$count (成功:$successCount 失败:$failedCount)";
        notifyListeners();
      }
    }

    await Future.wait(List.generate(workerCount, (_) => runWorker()));

    _stopwatch?.stop();
    _ticker?.cancel();

    if (cancelFlag) {
      try {
        if (await chunkDir.exists()) await chunkDir.delete(recursive: true);
      } catch (_) {}
      isExporting = false;
      notifyListeners();
      if (hostContext.mounted) {
        ScaffoldMessenger.of(hostContext).showSnackBar(const SnackBar(content: Text("导出任务已取消")));
      }
      return;
    }

    if (successCount == 0) {
      try {
        if (await chunkDir.exists()) await chunkDir.delete(recursive: true);
      } catch (_) {}
      isExporting = false;
      notifyListeners();
      if (hostContext.mounted) {
        ScaffoldMessenger.of(hostContext).showSnackBar(const SnackBar(content: Text("导出失败：所有音频单元均合成失败，请检查网络或配置")));
      }
      return;
    }

    final Directory targetDir = Directory(outDir.trim());
    if (!await targetDir.exists()) await targetDir.create(recursive: true);

    final int totalSec = _stopwatch?.elapsed.inSeconds ?? 0;
    final String timeStr = totalSec >= 60 ? "${totalSec ~/ 60}分${totalSec % 60}秒" : "${totalSec}秒";
    String safePrefix = fileNamePrefix.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (safePrefix.length > 80) safePrefix = safePrefix.substring(0, 80);
    final String finalFileName = "${safePrefix}_耗时$timeStr.mp3";

    final outFile = File("${targetDir.path}${Platform.pathSeparator}$finalFileName");
    final sink = outFile.openWrite();
    for (int i = 0; i < count; i++) {
      if (!chunkOk[i]) continue;
      final f = File("${chunkDir.path}${Platform.pathSeparator}${i.toString().padLeft(6, '0')}.mp3");
      if (await f.exists()) {
        await sink.addStream(f.openRead());
      }
    }
    await sink.flush();
    await sink.close();

    try {
      if (await chunkDir.exists()) await chunkDir.delete(recursive: true);
    } catch (_) {}

    AppLogger.log("MP3 导出合并完成: ${outFile.path} [耗时: $timeStr, 成功: $successCount/$count, 失败: $failedCount]", null, null, true);

    isExporting = false;
    notifyListeners();

    if (hostContext.mounted) {
      final failTip = failedCount > 0 ? "\n⚠️ 有 $failedCount 句合成失败已跳过（详见运行日志）" : "";
      ScaffoldMessenger.of(hostContext).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text("🎉 合并完成！成功 $successCount/$count 单元 (耗时: $timeStr)$failTip\n保存至: ${outFile.path}"),
          action: SnackBarAction(
            label: "打开",
            textColor: Colors.amber,
            onPressed: () => OpenFilex.open(outFile.path),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stopwatch?.stop();
    super.dispose();
  }
}

// ────────────────── 弹窗集合门面 ──────────────────
class ReaderDialogs {
  static String getEngineDisplayName(String engineId, List<CustomTtsEngineConfig> customEngines) {
    if (engineId == 'ms') return '微软官方 (免Key)';
    if (engineId == 'fish') return 'Fish Audio';
    for (final c in customEngines) {
      if (c.id == engineId) return c.name;
    }
    return engineId;
  }

  // 1. 系统设置弹窗 (整合 10-20px 字体调节 + 引擎管理入口 + 分引擎直连/代理设置)
  static void showSettingsDialog({
    required BuildContext context,
    required String currentEngine,
    required String apiKey,
    required String fishModel,
    required int bitrate,
    required int timeoutSeconds,
    required int preloadCount,
    required int exportThreads,
    required int intervalPauseMs,
    required int maxCacheCount,
    required String proxyMode,
    required String customProxy,
    required Map<String, String> engineNetworkModes,
    required List<CustomTtsEngineConfig> customEngines,
    required bool followAlong,
    required String splitMode,
    required double fontSize,
    required String lastBackupDir,
    required VoidCallback onExportBackup,
    required Function(String newBackupDir) onBackupDirChanged,
    required VoidCallback onShowRestorePicker,
    required Future<void> Function() onOpenCustomEnginesManager,
    required Function({
      required String engine,
      required String apiKey,
      required String fishModel,
      required int bitrate,
      required int timeoutSeconds,
      required int preloadCount,
      required int exportThreads,
      required int intervalPauseMs,
      required int maxCacheCount,
      required String proxyMode,
      required String customProxy,
      required Map<String, String> engineNetworkModes,
      required bool followAlong,
      required String splitMode,
      required double fontSize,
    }) onSave,
  }) {
    final keyCtrl = TextEditingController(text: apiKey);
    final proxyCtrl = TextEditingController(text: customProxy);
    int tempPreload = preloadCount;
    int tempExportThreads = exportThreads;
    int tempBitrate = bitrate;
    int tempTimeout = timeoutSeconds;
    int tempIntervalPause = intervalPauseMs;
    int tempMaxCache = maxCacheCount;
    String tempEngine = currentEngine;
    String tempFishModel = fishModelOptions.contains(fishModel) ? fishModel : fishModelOptions.first;
    String tempSplit = splitMode;
    double tempFontSize = fontSize.clamp(10.0, 20.0);
    String tempProxyMode = (proxyMode == 'manual') ? 'manual' : 'auto';
    final Map<String, String> tempRoutes = Map<String, String>.from(engineNetworkModes);
    tempRoutes.putIfAbsent('ms', () => 'direct');
    tempRoutes.putIfAbsent('fish', () => 'direct');
    for (final c in customEngines) {
      tempRoutes[c.id] = c.networkMode;
    }
    bool tempAutoScroll = followAlong;
    String tempBackupDir = lastBackupDir;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final allEngineIds = <String>{'ms', 'fish', ...customEngines.map((e) => e.id)};
          if (!allEngineIds.contains(tempEngine)) tempEngine = 'ms';

          return AlertDialog(
            title: const Text('系统与引擎设置'),
            content: SizedBox(
              width: min(560.0, MediaQuery.of(ctx).size.width * 0.92),
              height: min(560.0, MediaQuery.of(ctx).size.height * 0.78),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 引擎与品质 ──
                    Card(
                      color: const Color(0xFFFCFBF7),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("🔊 TTS 引擎与品质", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
                                TextButton.icon(
                                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                  icon: const Icon(Icons.extension_outlined, size: 16),
                                  label: Text("自定义引擎 (${customEngines.length})", style: const TextStyle(fontSize: 12)),
                                  onPressed: () async {
                                    await onOpenCustomEnginesManager();
                                    for (final c in customEngines) {
                                      tempRoutes[c.id] = c.networkMode;
                                    }
                                    setDlgState(() {});
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: tempEngine,
                              decoration: const InputDecoration(labelText: '当前朗读引擎', isDense: true),
                              items: [
                                const DropdownMenuItem(value: 'ms', child: Text('微软官方 (免Key)')),
                                const DropdownMenuItem(value: 'fish', child: Text('Fish Audio 官方引擎')),
                                ...customEngines.map((c) => DropdownMenuItem(value: c.id, child: Text('🧩 ${c.name}', overflow: TextOverflow.ellipsis))),
                              ],
                              onChanged: (v) {
                                if (v != null) setDlgState(() => tempEngine = v);
                              },
                            ),
                            if (tempEngine == 'fish') ...[
                              const SizedBox(height: 8),
                              TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: 'Fish Audio API Key', isDense: true)),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                value: tempFishModel,
                                decoration: const InputDecoration(labelText: 'Fish 模型版本', isDense: true),
                                items: fishModelOptions.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                                onChanged: (v) {
                                  if (v != null) setDlgState(() => tempFishModel = v);
                                },
                              ),
                            ],
                            const SizedBox(height: 8),
                            DropdownButtonFormField<int>(
                              value: tempBitrate,
                              decoration: const InputDecoration(labelText: '音频合成质量', isDense: true),
                              items: const [
                                DropdownMenuItem(value: 64, child: Text('64 kbps (默认 · 极速省流)')),
                                DropdownMenuItem(value: 128, child: Text('128 kbps (高品质清晰)')),
                              ],
                              onChanged: (v) => setDlgState(() => tempBitrate = v ?? 64),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("单句合成超时等待上限:"),
                                Text("$tempTimeout 秒", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Slider(
                              value: tempTimeout.toDouble(),
                              min: 20,
                              max: 120,
                              divisions: 100,
                              label: "$tempTimeout 秒",
                              onChanged: (v) => setDlgState(() => tempTimeout = v.toInt()),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── 阅读字体与朗读规则 ──
                    Card(
                      color: const Color(0xFFFCFBF7),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("📖 排版字体与朗读规则", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("正文字体大小 (10–20 px):"),
                                Row(
                                  children: [
                                    Text(
                                      "${tempFontSize.toStringAsFixed(1).replaceAll('.0', '')} px",
                                      style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                                      onPressed: () => setDlgState(() => tempFontSize = 14.0),
                                      child: const Text("默认14", style: TextStyle(fontSize: 11)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            Slider(
                              value: tempFontSize,
                              min: 10.0,
                              max: 20.0,
                              divisions: 20,
                              label: "${tempFontSize.toStringAsFixed(1).replaceAll('.0', '')} px",
                              onChanged: (v) => setDlgState(() => tempFontSize = double.parse(v.toStringAsFixed(1))),
                            ),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(color: const Color(0xFFF6F4EC), borderRadius: BorderRadius.circular(6)),
                              child: Text(
                                "字体预览：春风拂槛露华浓，静听书声伴晚钟。",
                                style: TextStyle(fontSize: tempFontSize, color: const Color(0xFF2D2E2F), height: 1.6),
                              ),
                            ),
                            DropdownButtonFormField<String>(
                              value: tempSplit,
                              decoration: const InputDecoration(labelText: '朗读断句规则 (CharOffset 无缝定位)', isDense: true),
                              items: const [
                                DropdownMenuItem(value: 'sentence', child: Text('按标点断句朗读 (推荐)')),
                                DropdownMenuItem(value: 'paragraph', child: Text('按自然段落朗读')),
                              ],
                              onChanged: (v) {
                                if (v != null) setDlgState(() => tempSplit = v);
                              },
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("句/段朗读间隔停顿:"),
                                Text("$tempIntervalPause ms", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Slider(
                              value: tempIntervalPause.toDouble(),
                              min: 0,
                              max: 1500,
                              divisions: 15,
                              label: "$tempIntervalPause ms",
                              onChanged: (v) => setDlgState(() => tempIntervalPause = (v / 50).round() * 50),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── 性能与缓存 ──
                    Card(
                      color: const Color(0xFFFCFBF7),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("⚡ 性能、缓存与并发", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("朗读后台预读缓存:"),
                                Text("$tempPreload 句", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Slider(
                              value: tempPreload.toDouble(),
                              min: 1,
                              max: 15,
                              divisions: 14,
                              label: "$tempPreload 句",
                              onChanged: (v) => setDlgState(() => tempPreload = v.toInt()),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("导出 MP3 默认线程数:"),
                                Text("$tempExportThreads 线程", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Slider(
                              value: tempExportThreads.toDouble(),
                              min: 1,
                              max: 16,
                              divisions: 15,
                              label: "$tempExportThreads 线程",
                              onChanged: (v) => setDlgState(() => tempExportThreads = v.toInt()),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text("朗读时正文视线平滑居中", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                              value: tempAutoScroll,
                              onChanged: (v) => setDlgState(() => tempAutoScroll = v),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("音频内存最大缓存上限:"),
                                Text("$tempMaxCache 句", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Slider(
                              value: tempMaxCache.toDouble(),
                              min: 50,
                              max: 300,
                              divisions: 25,
                              label: "$tempMaxCache",
                              onChanged: (v) => setDlgState(() => tempMaxCache = v.toInt()),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── 分引擎独立网络路由 + 全局代理参数 ──
                    Card(
                      color: const Color(0xFFFCFBF7),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("🌐 分引擎网络通道 (默认直连)", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
                            const SizedBox(height: 6),
                            for (final entry in [
                              const MapEntry('ms', '微软官方引擎'),
                              const MapEntry('fish', 'Fish Audio 引擎'),
                              ...customEngines.map((c) => MapEntry(c.id, '🧩 ${c.name}')),
                            ])
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(entry.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                                    ),
                                    SegmentedButton<String>(
                                      style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                                      segments: const [
                                        ButtonSegment(value: 'direct', label: Text('直连', style: TextStyle(fontSize: 11))),
                                        ButtonSegment(value: 'proxy', label: Text('走代理', style: TextStyle(fontSize: 11))),
                                      ],
                                      selected: {tempRoutes[entry.key] == 'proxy' ? 'proxy' : 'direct'},
                                      onSelectionChanged: (v) => setDlgState(() => tempRoutes[entry.key] = v.first),
                                    ),
                                  ],
                                ),
                              ),
                            const Divider(height: 18),
                            const Text("代理服务器地址 (仅当引擎设为「走代理」时使用):", style: TextStyle(fontSize: 12, color: Colors.blueGrey)),
                            RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text("自动读取系统/Clash 代理"),
                              value: "auto",
                              groupValue: tempProxyMode,
                              onChanged: (v) => setDlgState(() => tempProxyMode = v!),
                            ),
                            RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text("手动指定代理地址"),
                              value: "manual",
                              groupValue: tempProxyMode,
                              onChanged: (v) => setDlgState(() => tempProxyMode = v!),
                            ),
                            if (tempProxyMode == "manual")
                              TextField(
                                controller: proxyCtrl,
                                decoration: const InputDecoration(labelText: "代理地址与端口 (如 127.0.0.1:7890)", isDense: true),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // ── 备份与恢复 ──
                    Card(
                      color: const Color(0xFFFCFBF7),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("💾 备份与恢复", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
                            const SizedBox(height: 6),
                            Text("当前备份目录: $tempBackupDir", style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.folder_open, size: 16),
                                  label: const Text("更改目录"),
                                  onPressed: () async {
                                    String? newDir;
                                    if (Platform.isAndroid) {
                                      newDir = await StorageHelper.browseSharedStorage(
                                        ctx,
                                        chooseDirectory: true,
                                        extensions: [],
                                        initialPath: tempBackupDir,
                                      );
                                    } else {
                                      newDir = await FilePicker.platform.getDirectoryPath();
                                    }
                                    if (newDir != null) {
                                      setDlgState(() => tempBackupDir = newDir!);
                                      onBackupDirChanged(newDir);
                                    }
                                  },
                                ),
                                FilledButton.icon(
                                  icon: const Icon(Icons.file_upload, size: 16),
                                  label: const Text("一键导出备份"),
                                  onPressed: onExportBackup,
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.restore, size: 16),
                                  label: const Text("选择恢复"),
                                  onPressed: onShowRestorePicker,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
              FilledButton(
                onPressed: () {
                  onSave(
                    engine: tempEngine,
                    apiKey: keyCtrl.text.trim(),
                    fishModel: tempFishModel,
                    bitrate: tempBitrate,
                    timeoutSeconds: tempTimeout,
                    preloadCount: tempPreload,
                    exportThreads: tempExportThreads,
                    intervalPauseMs: tempIntervalPause,
                    maxCacheCount: tempMaxCache,
                    proxyMode: tempProxyMode,
                    customProxy: proxyCtrl.text.trim(),
                    engineNetworkModes: tempRoutes,
                    followAlong: tempAutoScroll,
                    splitMode: tempSplit,
                    fontSize: tempFontSize,
                  );
                  Navigator.pop(dialogContext);
                },
                child: const Text('保存配置'),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      keyCtrl.dispose();
      proxyCtrl.dispose();
    });
  }

  // 2. 自定义 TTS 引擎管理中心 (增删改、模板、cURL导入、JSON代码直编、分引擎直连/代理)
  static Future<void> showCustomEnginesDialog({
    required BuildContext context,
    required List<CustomTtsEngineConfig> customEngines,
    required String activeEngineId,
    required TtsNetworkRouter networkRouter,
    required int timeoutSeconds,
    required Function(List<CustomTtsEngineConfig> updated) onCustomEnginesChanged,
    required Function(String engineId) onSelectEngine,
  }) {
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    Future<void> openEngineEditor(BuildContext parentCtx, VoidCallback refreshParent, [CustomTtsEngineConfig? editing]) async {
      final isNew = editing == null;
      CustomTtsEngineConfig draft = editing?.copyWith() ??
          CustomTtsEngineConfig(
            id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
            name: '新建自定义 TTS',
            method: 'POST',
            url: 'https://api.example.com/v1/tts',
            headers: {'Authorization': 'Bearer {{api_key}}', 'Content-Type': 'application/json'},
            bodyTemplate: '{\n  "text": "{{text_json}}",\n  "voice": "{{voice}}",\n  "speed": {{speed}}\n}',
            responseType: 'raw_bytes',
            voices: {'default': '默认音色'},
            networkMode: 'direct',
          );

      final nameCtrl = TextEditingController(text: draft.name);
      final urlCtrl = TextEditingController(text: draft.url);
      final keyCtrl = TextEditingController(text: draft.apiKey);
      final headersCtrl = TextEditingController(text: const JsonEncoder.withIndent('  ').convert(draft.headers));
      final bodyCtrl = TextEditingController(text: draft.bodyTemplate);
      final jsonPathCtrl = TextEditingController(text: draft.jsonPath);
      final voicesCtrl = TextEditingController(
        text: draft.voices.entries.map((e) => '${e.key}=${e.value}').join('\n'),
      );
      final rawCodeCtrl = TextEditingController(text: draft.toPrettyCode());
      final curlCtrl = TextEditingController();

      String method = draft.method;
      String responseType = draft.responseType;
      String networkMode = draft.networkMode;
      int editorMode = 0; // 0: 表单配置  1: JSON 代码直编
      String testResultMsg = "";
      bool isTesting = false;
      bool disposed = false;

      CustomTtsEngineConfig? buildFromForm() {
        Map<String, String> parsedHeaders = {};
        try {
          final hDec = jsonDecode(headersCtrl.text.trim().isEmpty ? '{}' : headersCtrl.text);
          if (hDec is Map) {
            hDec.forEach((k, v) => parsedHeaders[k.toString()] = v.toString());
          }
        } catch (e) {
          testResultMsg = "❌ Headers JSON 格式错误: $e";
          return null;
        }

        final parsedVoices = <String, String>{};
        for (final line in voicesCtrl.text.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          final idx = trimmed.indexOf('=');
          if (idx > 0) {
            parsedVoices[trimmed.substring(0, idx).trim()] = trimmed.substring(idx + 1).trim();
          } else {
            parsedVoices[trimmed] = trimmed;
          }
        }
        if (parsedVoices.isEmpty) parsedVoices['default'] = '默认音色';

        return CustomTtsEngineConfig(
          id: draft.id,
          name: nameCtrl.text.trim().isEmpty ? '自定义引擎' : nameCtrl.text.trim(),
          method: method,
          url: urlCtrl.text.trim(),
          headers: parsedHeaders,
          bodyTemplate: bodyCtrl.text,
          responseType: responseType,
          jsonPath: jsonPathCtrl.text.trim(),
          apiKey: keyCtrl.text.trim(),
          voices: parsedVoices,
          networkMode: networkMode,
        );
      }

      void syncFormToFields(CustomTtsEngineConfig cfg) {
        draft = cfg;
        nameCtrl.text = cfg.name;
        urlCtrl.text = cfg.url;
        keyCtrl.text = cfg.apiKey;
        headersCtrl.text = const JsonEncoder.withIndent('  ').convert(cfg.headers);
        bodyCtrl.text = cfg.bodyTemplate;
        jsonPathCtrl.text = cfg.jsonPath;
        voicesCtrl.text = cfg.voices.entries.map((e) => '${e.key}=${e.value}').join('\n');
        method = cfg.method;
        responseType = cfg.responseType;
        networkMode = cfg.networkMode;
        rawCodeCtrl.text = cfg.toPrettyCode();
      }

      await showDialog(
        context: parentCtx,
        builder: (editCtx) => StatefulBuilder(
          builder: (ctx, setEditState) {
            final templates = CustomTtsRunner.presetTemplates();

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.code, color: Color(0xFFC87D2E)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(isNew ? "新增自定义 TTS 引擎" : "编辑引擎: ${draft.name}", style: const TextStyle(fontSize: 16))),
                ],
              ),
              content: SizedBox(
                width: min(620.0, screenW * 0.94),
                height: min(600.0, screenH * 0.8),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 模式切换 + 快速导入预设模板 / cURL
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SegmentedButton<int>(
                            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                            segments: const [
                              ButtonSegment(value: 0, label: Text("可视化表单", style: TextStyle(fontSize: 12))),
                              ButtonSegment(value: 1, label: Text("JSON 代码直编", style: TextStyle(fontSize: 12))),
                            ],
                            selected: {editorMode},
                            onSelectionChanged: (v) {
                              if (v.first == 1) {
                                final built = buildFromForm();
                                if (built != null) rawCodeCtrl.text = built.toPrettyCode();
                              } else {
                                try {
                                  final parsed = CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(jsonDecode(rawCodeCtrl.text)));
                                  syncFormToFields(parsed.copyWith(id: draft.id));
                                  testResultMsg = "";
                                } catch (e) {
                                  testResultMsg = "❌ 代码 JSON 解析失败: $e";
                                }
                              }
                              setEditState(() => editorMode = v.first);
                            },
                          ),
                          PopupMenuButton<String>(
                            tooltip: "从常用 TTS 模板快速填充",
                            onSelected: (tplKey) {
                              final tpl = templates[tplKey];
                              if (tpl != null) {
                                syncFormToFields(tpl.copyWith(id: draft.id));
                                setEditState(() => testResultMsg = "已载入模板「${tpl.name}」，请填入您的 API Key/地址");
                              }
                            },
                            itemBuilder: (_) => templates.entries
                                .map((e) => PopupMenuItem(value: e.key, child: Text("载入模板：${e.value.name}")))
                                .toList(),
                            child: Chip(
                              avatar: const Icon(Icons.auto_fix_high, size: 16, color: Color(0xFFC87D2E)),
                              label: const Text("插入预设模板", style: TextStyle(fontSize: 11.5)),
                            ),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.terminal, size: 16, color: Color(0xFFC87D2E)),
                            label: const Text("导入 cURL", style: TextStyle(fontSize: 11.5)),
                            onPressed: () {
                              showDialog(
                                context: ctx,
                                builder: (cCtx) => AlertDialog(
                                  title: const Text("粘贴 cURL 命令导入"),
                                  content: TextField(
                                    controller: curlCtrl,
                                    maxLines: 7,
                                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                                    decoration: const InputDecoration(
                                      hintText: "curl -X POST https://... -H 'Authorization: Bearer ...' -d '{\"text\":\"{{text_json}}\"}'",
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(cCtx), child: const Text("取消")),
                                    FilledButton(
                                      onPressed: () {
                                        final parsed = CustomTtsRunner.parseCurl(
                                          curlCtrl.text,
                                          name: nameCtrl.text.trim().isEmpty ? 'cURL 引擎' : nameCtrl.text.trim(),
                                        );
                                        if (parsed != null) {
                                          syncFormToFields(parsed.copyWith(id: draft.id));
                                          Navigator.pop(cCtx);
                                          setEditState(() => testResultMsg = "✅ 已从 cURL 解析，可进一步替换正文变量 {{text_json}}");
                                        }
                                      },
                                      child: const Text("解析填入"),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFFEFE7D2), borderRadius: BorderRadius.circular(6)),
                        child: const Text(
                          "可用模板变量：{{text_json}} (JSON安全正文)、{{text_url}} (URL编码)、{{text}}、{{voice}}、{{speed}}、{{rate_percent}}、{{bitrate}}、{{api_key}}",
                          style: TextStyle(fontSize: 10.5, color: Color(0xFF743C00)),
                        ),
                      ),
                      const SizedBox(height: 10),

                      if (editorMode == 0) ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "引擎名称", isDense: true)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: networkMode,
                                decoration: const InputDecoration(labelText: "网络连接", isDense: true),
                                items: const [
                                  DropdownMenuItem(value: 'direct', child: Text("直连 (默认)")),
                                  DropdownMenuItem(value: 'proxy', child: Text("走代理")),
                                ],
                                onChanged: (v) {
                                  if (v != null) setEditState(() => networkMode = v);
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 96,
                              child: DropdownButtonFormField<String>(
                                value: method,
                                decoration: const InputDecoration(labelText: "方法", isDense: true),
                                items: const [
                                  DropdownMenuItem(value: 'POST', child: Text("POST")),
                                  DropdownMenuItem(value: 'GET', child: Text("GET")),
                                ],
                                onChanged: (v) {
                                  if (v != null) setEditState(() => method = v);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: "接口 URL", isDense: true)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: "API Key (对应 {{api_key}}，可选)", isDense: true)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: headersCtrl,
                          maxLines: 3,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                          decoration: const InputDecoration(labelText: "Headers (JSON 对象)", isDense: true, border: OutlineInputBorder()),
                        ),
                        if (method == 'POST') ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: bodyCtrl,
                            maxLines: 5,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                            decoration: const InputDecoration(labelText: "Body 请求体模板", isDense: true, border: OutlineInputBorder()),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: responseType,
                                decoration: const InputDecoration(labelText: "返回音频格式", isDense: true),
                                items: const [
                                  DropdownMenuItem(value: 'raw_bytes', child: Text("直接返回 MP3/音频裸流")),
                                  DropdownMenuItem(value: 'json_base64', child: Text("JSON 含 Base64 字段")),
                                  DropdownMenuItem(value: 'json_url', child: Text("JSON 含音频下载 URL")),
                                ],
                                onChanged: (v) {
                                  if (v != null) setEditState(() => responseType = v);
                                },
                              ),
                            ),
                            if (responseType != 'raw_bytes') ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: jsonPathCtrl,
                                  decoration: const InputDecoration(labelText: "JSON 提取路径 (如 data.audio)", isDense: true),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: voicesCtrl,
                          maxLines: 3,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                          decoration: const InputDecoration(
                            labelText: "音色列表 (每行一条：音色ID=显示名称)",
                            hintText: "alloy=Alloy 男声\nnova=Nova 女声",
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ] else ...[
                        TextField(
                          controller: rawCodeCtrl,
                          maxLines: 17,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35),
                          decoration: const InputDecoration(
                            labelText: "完整引擎配置代码 (JSON)",
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],

                      if (testResultMsg.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            testResultMsg,
                            style: TextStyle(fontSize: 11.5, color: testResultMsg.startsWith('❌') ? Colors.redAccent : Colors.green.shade700),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton.icon(
                  icon: isTesting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: const Text("测试合成"),
                  onPressed: isTesting
                      ? null
                      : () async {
                          CustomTtsEngineConfig? candidate;
                          if (editorMode == 0) {
                            candidate = buildFromForm();
                          } else {
                            try {
                              candidate = CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(jsonDecode(rawCodeCtrl.text))).copyWith(id: draft.id);
                            } catch (e) {
                              setEditState(() => testResultMsg = "❌ JSON 格式错误: $e");
                            }
                          }
                          if (candidate == null) {
                            setEditState(() {});
                            return;
                          }
                          setEditState(() {
                            isTesting = true;
                            testResultMsg = "正在发起测试请求 (${candidate!.networkMode == 'proxy' ? '代理' : '直连'})...";
                          });
                          final client = networkRouter.getClientForEngine(candidate.id, [candidate]);
                          final res = await CustomTtsRunner.testConnectivity(candidate, client);
                          if (!disposed) {
                            setEditState(() {
                              isTesting = false;
                              testResultMsg = res['success'] == true
                                  ? "✅ 测试通过 (${res['latency']}ms): ${res['msg']}"
                                  : "❌ 测试失败: ${res['msg']}";
                            });
                          }
                        },
                ),
                TextButton(onPressed: () => Navigator.pop(editCtx), child: const Text("取消")),
                FilledButton(
                  onPressed: () {
                    CustomTtsEngineConfig? finalCfg;
                    if (editorMode == 0) {
                      finalCfg = buildFromForm();
                    } else {
                      try {
                        finalCfg = CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(jsonDecode(rawCodeCtrl.text))).copyWith(id: draft.id);
                      } catch (e) {
                        setEditState(() => testResultMsg = "❌ JSON 格式错误: $e");
                      }
                    }
                    if (finalCfg == null) {
                      setEditState(() {});
                      return;
                    }
                    if (isNew) {
                      customEngines.add(finalCfg);
                    } else {
                      final idx = customEngines.indexWhere((e) => e.id == finalCfg!.id);
                      if (idx >= 0) {
                        customEngines[idx] = finalCfg;
                      } else {
                        customEngines.add(finalCfg);
                      }
                    }
                    onCustomEnginesChanged(List<CustomTtsEngineConfig>.from(customEngines));
                    Navigator.pop(editCtx);
                    refreshParent();
                  },
                  child: const Text("保存引擎"),
                ),
              ],
            );
          },
        ),
      ).then((_) {
        disposed = true;
        nameCtrl.dispose();
        urlCtrl.dispose();
        keyCtrl.dispose();
        headersCtrl.dispose();
        bodyCtrl.dispose();
        jsonPathCtrl.dispose();
        voicesCtrl.dispose();
        rawCodeCtrl.dispose();
        curlCtrl.dispose();
      });
    }

    return showDialog(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(children: [
                Icon(Icons.extension, color: Color(0xFFC87D2E)),
                SizedBox(width: 8),
                Text("自定义 TTS 引擎", style: TextStyle(fontSize: 16)),
              ]),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text("新增引擎", style: TextStyle(fontSize: 12)),
                onPressed: () => openEngineEditor(ctx, () => setDlgState(() {})),
              ),
            ],
          ),
          content: SizedBox(
            width: min(560.0, screenW * 0.92),
            height: min(460.0, screenH * 0.68),
            child: customEngines.isEmpty
                ? const Center(
                    child: Text(
                      "暂未添加自定义 TTS 引擎\n点击右上角「新增引擎」可配置小米 MiMo、\n中转 Fish Audio、Edge HTTP 或任意 REST 接口",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.5),
                    ),
                  )
                : ListView.separated(
                    itemCount: customEngines.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, idx) {
                      final cfg = customEngines[idx];
                      final isCur = cfg.id == activeEngineId;
                      return ListTile(
                        dense: true,
                        selected: isCur,
                        selectedTileColor: const Color(0xFFEFE7D2),
                        leading: Icon(
                          cfg.networkMode == 'proxy' ? Icons.vpn_lock : Icons.public,
                          color: isCur ? const Color(0xFFC87D2E) : Colors.blueGrey,
                          size: 20,
                        ),
                        title: Text(cfg.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                        subtitle: Text(
                          "${cfg.method} · ${cfg.networkMode == 'proxy' ? '走代理' : '直连'} · ${cfg.voices.length} 音色\n${cfg.url}",
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10.5, color: Colors.blueGrey),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isCur)
                              TextButton(
                                onPressed: () {
                                  onSelectEngine(cfg.id);
                                  Navigator.pop(dlgCtx);
                                },
                                child: const Text("启用", style: TextStyle(fontSize: 12)),
                              ),
                            IconButton(
                              tooltip: "编辑引擎与代码",
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => openEngineEditor(ctx, () => setDlgState(() {}), cfg),
                            ),
                            IconButton(
                              tooltip: "删除引擎",
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                              onPressed: () {
                                showDialog(
                                  context: ctx,
                                  builder: (delCtx) => AlertDialog(
                                    title: const Text("确认删除引擎"),
                                    content: Text("确定要删除自定义引擎「${cfg.name}」吗？"),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text("取消")),
                                      FilledButton(
                                        style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                                        onPressed: () {
                                          customEngines.removeAt(idx);
                                          onCustomEnginesChanged(List<CustomTtsEngineConfig>.from(customEngines));
                                          Navigator.pop(delCtx);
                                          setDlgState(() {});
                                        },
                                        child: const Text("删除"),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text("完成")),
          ],
        ),
      ),
    );
  }

  // 3. 发音人管理与试听中心 (支持微软 / Fish / 所有自定义引擎，Tab 切换不污染主界面)
  static void showVoiceManagerDialog({
    required BuildContext context,
    required String currentEngine,
    required String selectedVoiceId,
    required Map<String, String> userMsVoices,
    required Map<String, String> userFishVoices,
    required List<CustomTtsEngineConfig> customEngines,
    required List<String> pinnedVoiceIds,
    required double speechRate,
    required int bitrate,
    required int timeoutSeconds,
    required FishAudioTTS fishTts,
    required TtsNetworkRouter networkRouter,
    required Function(String engine, String voiceId) onVoiceSelected,
    required Function(String engine, Map<String, String> updatedMap) onVoicesUpdated,
    required Function(String engine) onVoicesReset,
    required VoidCallback onPinToggled,
  }) {
    final AudioPlayer previewPlayer = AudioPlayer();
    String browsingEngine = currentEngine;
    String activeEngine = currentEngine;
    String activeVoiceId = selectedVoiceId;
    bool isDisposed = false;
    int previewSeq = 0;

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final dialogWidth = min(580.0, screenWidth * 0.94);
    final dialogHeight = min(660.0, screenHeight * 0.85);

    Map<String, String> getMapFor(String engId) {
      if (engId == 'ms') return userMsVoices;
      if (engId == 'fish') return userFishVoices;
      for (final c in customEngines) {
        if (c.id == engId) return c.voices;
      }
      return userMsVoices;
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final activeMap = getMapFor(browsingEngine);
          final entries = activeMap.entries.toList()
            ..sort((a, b) {
              final aPinned = pinnedVoiceIds.contains(a.key);
              final bPinned = pinnedVoiceIds.contains(b.key);
              if (aPinned && !bPinned) return -1;
              if (!aPinned && bPinned) return 1;
              return 0;
            });

          void openEditOrAddDialog([String? editKey, String? editName]) {
            final idCtrl = TextEditingController(text: editKey ?? '');
            final nameCtrl = TextEditingController(text: editName ?? '');
            bool isFetching = false;
            String fetchStatus = "";

            showDialog(
              context: ctx,
              builder: (subCtx) => StatefulBuilder(
                builder: (subCtx, setSubState) => AlertDialog(
                  title: Text(editKey == null ? "添加发音人" : "修改发音人名称"),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (browsingEngine == 'fish') ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: idCtrl,
                                enabled: editKey == null,
                                decoration: const InputDecoration(
                                  labelText: "Fish 模型 ID 或分享链接",
                                  hintText: "输入模型ID，点击右侧拉取",
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonalIcon(
                              icon: isFetching
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.cloud_download, size: 16),
                              label: const Text("拉取"),
                              onPressed: isFetching
                                  ? null
                                  : () async {
                                      final rawId = idCtrl.text.trim();
                                      if (rawId.isEmpty) return;
                                      setSubState(() {
                                        isFetching = true;
                                        fetchStatus = "正在查询模型信息...";
                                      });
                                      final client = networkRouter.getClientForEngine('fish', customEngines);
                                      final details = await fishTts.fetchModelDetails(rawId, client);
                                      if (subCtx.mounted) {
                                        setSubState(() {
                                          isFetching = false;
                                          if (details != null) {
                                            idCtrl.text = details['cleanId'] ?? rawId;
                                            final tagSuffix = details['tags']!.isNotEmpty ? " (${details['tags']})" : "";
                                            nameCtrl.text = "${details['title']}$tagSuffix";
                                            fetchStatus = "✅ 已自动获取: ${details['title']}";
                                          } else {
                                            fetchStatus = "❌ 未查询到该模型，请检查 ID 或网络";
                                          }
                                        });
                                      }
                                    },
                            ),
                          ],
                        ),
                        if (fetchStatus.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(fetchStatus, style: TextStyle(fontSize: 11, color: fetchStatus.startsWith('✅') ? Colors.green : Colors.redAccent)),
                          ),
                      ] else ...[
                        TextField(
                          controller: idCtrl,
                          enabled: editKey == null,
                          decoration: InputDecoration(
                            labelText: browsingEngine == 'ms' ? "微软 VoiceName" : "音色参数 ID",
                            hintText: browsingEngine == 'ms' ? "如 zh-CN-YunxiNeural" : "如 alloy / mimo_default",
                            isDense: true,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(labelText: "显示名称 (用于界面标识)", hintText: "如 阳光清朗叙事", isDense: true),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(subCtx), child: const Text("取消")),
                    FilledButton(
                      onPressed: () {
                        final finalId = idCtrl.text.trim();
                        final finalName = nameCtrl.text.trim();
                        if (finalId.isEmpty || finalName.isEmpty) return;
                        activeMap[finalId] = finalName;
                        onVoicesUpdated(browsingEngine, activeMap);
                        Navigator.pop(subCtx);
                        setDlgState(() {});
                      },
                      child: const Text("保存"),
                    ),
                  ],
                ),
              ),
            ).then((_) {
              idCtrl.dispose();
              nameCtrl.dispose();
            });
          }

          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
            contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(children: [
                  Icon(Icons.record_voice_over, color: Color(0xFFC87D2E)),
                  SizedBox(width: 8),
                  Text("发音人与试听中心", style: TextStyle(fontSize: 16)),
                ]),
                Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text("添加", style: TextStyle(fontSize: 12)),
                      onPressed: () => openEditOrAddDialog(),
                    ),
                    if (browsingEngine == 'ms' || browsingEngine == 'fish')
                      TextButton.icon(
                        icon: const Icon(Icons.restore, size: 16),
                        label: const Text("恢复预设", style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          onVoicesReset(browsingEngine);
                          setDlgState(() {});
                        },
                      ),
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
                  // 水平引擎切换 Chip 栏（点击仅切换预览列表，不篡改正在朗读的引擎）
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text("微软 (${userMsVoices.length})", style: const TextStyle(fontSize: 12)),
                            selected: browsingEngine == 'ms',
                            onSelected: (_) => setDlgState(() => browsingEngine = 'ms'),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text("Fish (${userFishVoices.length})", style: const TextStyle(fontSize: 12)),
                            selected: browsingEngine == 'fish',
                            onSelected: (_) => setDlgState(() => browsingEngine = 'fish'),
                          ),
                        ),
                        ...customEngines.map((c) => Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text("🧩 ${c.name} (${c.voices.length})", style: const TextStyle(fontSize: 12)),
                                selected: browsingEngine == c.id,
                                onSelected: (_) => setDlgState(() => browsingEngine = c.id),
                              ),
                            )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFECE7D9)),
                      itemBuilder: (c, idx) {
                        final e = entries[idx];
                        final isSelected = (activeEngine == browsingEngine && activeVoiceId == e.key);
                        final isPinned = pinnedVoiceIds.contains(e.key);

                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          selectedTileColor: const Color(0xFFEFE7D2),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          leading: Icon(
                            isPinned ? Icons.push_pin : (browsingEngine == 'ms' ? Icons.cloud_outlined : Icons.mic_none),
                            color: isPinned ? const Color(0xFFC87D2E) : Colors.blueGrey,
                            size: 20,
                          ),
                          title: Text(
                            e.value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? const Color(0xFF743C00) : const Color(0xFF2C3238),
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              e.key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: Colors.blueGrey),
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.play_circle_fill, color: Color(0xFFC87D2E), size: 26),
                                tooltip: "试听效果",
                                onPressed: () async {
                                  final mySeq = ++previewSeq;
                                  try {
                                    const sample = "您好，欢迎使用听书阅读器，这是当前发音人的试听效果。";
                                    final bytes = await synthesizeWithEngine(
                                      engineId: browsingEngine,
                                      text: sample,
                                      voiceId: e.key,
                                      speed: speechRate,
                                      bitrate: bitrate,
                                      timeoutSeconds: timeoutSeconds,
                                      fishTts: fishTts,
                                      customEngines: customEngines,
                                      networkRouter: networkRouter,
                                    );
                                    if (isDisposed || mySeq != previewSeq) return;
                                    try {
                                      await previewPlayer.stop();
                                      await previewPlayer.setAudioSource(MemoryAudioSource(bytes));
                                      await previewPlayer.play();
                                    } catch (_) {
                                      if (isDisposed || mySeq != previewSeq) return;
                                      final tempDir = await getTemporaryDirectory();
                                      final bufferFile = File("${tempDir.path}${Platform.pathSeparator}preview_buffer_${mySeq % 2}.mp3");
                                      await bufferFile.writeAsBytes(bytes, flush: true);
                                      await previewPlayer.setFilePath(bufferFile.path);
                                      await previewPlayer.play();
                                    }
                                  } catch (err) {
                                    if (!isDisposed && context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("试听失败: $err")));
                                    }
                                  }
                                },
                              ),
                              PopupMenuButton<String>(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: const Icon(Icons.more_vert, size: 20, color: Colors.blueGrey),
                                tooltip: "管理操作",
                                onSelected: (action) {
                                  switch (action) {
                                    case 'pin':
                                      if (isPinned) {
                                        pinnedVoiceIds.remove(e.key);
                                      } else {
                                        pinnedVoiceIds.insert(0, e.key);
                                      }
                                      onPinToggled();
                                      setDlgState(() {});
                                      break;
                                    case 'edit':
                                      openEditOrAddDialog(e.key, e.value);
                                      break;
                                    case 'copy_id':
                                      Clipboard.setData(ClipboardData(text: e.key));
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("发音人 ID 已复制")));
                                      break;
                                    case 'delete':
                                      if (activeMap.length <= 1) {
                                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("必须保留至少一个发音人")));
                                        return;
                                      }
                                      showDialog(
                                        context: ctx,
                                        builder: (delCtx) => AlertDialog(
                                          title: const Text("确认移除发音人"),
                                          content: Text("确定要从列表中移除「${e.value}」吗？"),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text("取消")),
                                            FilledButton(
                                              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                                              onPressed: () {
                                                activeMap.remove(e.key);
                                                pinnedVoiceIds.remove(e.key);
                                                if (activeEngine == browsingEngine && activeVoiceId == e.key) {
                                                  activeVoiceId = activeMap.keys.first;
                                                  onVoiceSelected(browsingEngine, activeVoiceId);
                                                }
                                                onVoicesUpdated(browsingEngine, activeMap);
                                                Navigator.pop(delCtx);
                                                setDlgState(() {});
                                              },
                                              child: const Text("删除"),
                                            ),
                                          ],
                                        ),
                                      );
                                      break;
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'pin',
                                    child: Row(children: [
                                      Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin, size: 18, color: const Color(0xFFC87D2E)),
                                      const SizedBox(width: 8),
                                      Text(isPinned ? "取消置顶" : "置顶发音人"),
                                    ]),
                                  ),
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(children: [
                                      Icon(Icons.edit_outlined, size: 18, color: Colors.blueGrey),
                                      const SizedBox(width: 8),
                                      Text("修改显示名称"),
                                    ]),
                                  ),
                                  const PopupMenuItem(
                                    value: 'copy_id',
                                    child: Row(children: [
                                      Icon(Icons.copy, size: 18, color: Colors.blueGrey),
                                      const SizedBox(width: 8),
                                      Text("复制模型 ID"),
                                    ]),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(children: [
                                      Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                      const SizedBox(width: 8),
                                      Text("从列表删除", style: TextStyle(color: Colors.redAccent)),
                                    ]),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () {
                            activeEngine = browsingEngine;
                            activeVoiceId = e.key;
                            onVoiceSelected(browsingEngine, activeVoiceId);
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("完成")),
            ],
          );
        },
      ),
    ).then((_) {
      isDisposed = true;
      previewPlayer.dispose();
    });
  }

  // 4. 睡眠定时器弹窗
  static void showSleepTimerDialog({
    required BuildContext context,
    required int sleepTimeLeftSeconds,
    required bool sleepStopAfterChapter,
    required Function(int minutes) onStartTimer,
    required VoidCallback onCancelTimer,
    required VoidCallback onStopAfterChapter,
  }) {
    int selectedMinutes = sleepTimeLeftSeconds > 0 ? max(1, sleepTimeLeftSeconds ~/ 60) : 30;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          title: const Row(children: [Icon(Icons.bedtime_outlined, color: Color(0xFFC87D2E)), SizedBox(width: 8), Text("听书定时关闭")]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sleepTimeLeftSeconds > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    "倒计时剩余：${sleepTimeLeftSeconds ~/ 60}分${(sleepTimeLeftSeconds % 60).toString().padLeft(2, '0')}秒",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFC87D2E), fontSize: 16),
                  ),
                ),
              if (sleepStopAfterChapter)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text("当前状态：读完本章后自动暂停", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFC87D2E))),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("设定时长:"),
                  Text("$selectedMinutes 分钟", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                ],
              ),
              Slider(
                value: selectedMinutes.toDouble(),
                min: 1,
                max: 180,
                divisions: 179,
                label: "$selectedMinutes 分钟",
                onChanged: (v) => setDlgState(() => selectedMinutes = v.toInt()),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [15, 30, 45, 60, 90, 120]
                    .map((m) => ActionChip(label: Text("$m分"), onPressed: () => setDlgState(() => selectedMinutes = m)))
                    .toList(),
              ),
              const Divider(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.menu_book, size: 16),
                label: const Text("读完本章后停止"),
                onPressed: () {
                  onStopAfterChapter();
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
          actions: [
            if (sleepTimeLeftSeconds > 0 || sleepStopAfterChapter)
              TextButton(
                onPressed: () {
                  onCancelTimer();
                  Navigator.pop(ctx);
                },
                child: const Text("取消定时", style: TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭")),
            FilledButton(
              onPressed: () {
                onStartTimer(selectedMinutes);
                Navigator.pop(ctx);
              },
              child: const Text("启动定时"),
            ),
          ],
        ),
      ),
    );
  }

  // 5. 运行日志管理界面 (懒加载 ListView.builder，适配 2MB 轮转机制)
  static void showLogViewerDialog({
    required BuildContext context,
    required Function(String newLevel) onLogLevelChanged,
  }) async {
    List<String> logLines = await AppLogger.readLogLines(maxLines: 800);
    int logSizeBytes = await AppLogger.getLogSizeBytes();
    if (!context.mounted) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final dialogWidth = min(740.0, screenWidth * 0.94);
    final dialogHeight = min(620.0, screenHeight * 0.85);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          title: Row(
            children: [
              const Icon(Icons.terminal, color: Color(0xFFC87D2E)),
              const SizedBox(width: 8),
              const Text("运行日志管理", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text("占用: ${formatFileSize(logSizeBytes)}", style: const TextStyle(fontSize: 11, color: Colors.blueGrey, fontWeight: FontWeight.normal)),
            ],
          ),
          content: SizedBox(
            width: dialogWidth,
            height: dialogHeight,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFFEFE7D2), borderRadius: BorderRadius.circular(8)),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text("记录模式: ", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          SegmentedButton<String>(
                            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                            segments: const [
                              ButtonSegment(value: 'error', label: Text('仅错误', style: TextStyle(fontSize: 11))),
                              ButtonSegment(value: 'all', label: Text('详细流水', style: TextStyle(fontSize: 11))),
                            ],
                            selected: {AppLogger.logLevel},
                            onSelectionChanged: (val) async {
                              final newLevel = val.first;
                              AppLogger.logLevel = newLevel;
                              onLogLevelChanged(newLevel);
                              AppLogger.log("日志记录模式已切换为: ${newLevel == 'all' ? '详细流水' : '仅记录错误'}", null, null, true);
                              logLines = await AppLogger.readLogLines(maxLines: 800);
                              logSizeBytes = await AppLogger.getLogSizeBytes();
                              setDlg(() {});
                            },
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                            icon: const Icon(Icons.refresh, size: 15),
                            label: const Text("刷新", style: TextStyle(fontSize: 11)),
                            onPressed: () async {
                              logLines = await AppLogger.readLogLines(maxLines: 800);
                              logSizeBytes = await AppLogger.getLogSizeBytes();
                              setDlg(() {});
                            },
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                            icon: const Icon(Icons.copy, size: 15),
                            label: const Text("复制", style: TextStyle(fontSize: 11)),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: logLines.join('\n')));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("日志已复制到剪贴板")));
                            },
                          ),
                          const SizedBox(width: 6),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.red.shade50,
                              foregroundColor: Colors.redAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            icon: const Icon(Icons.delete_sweep, size: 16),
                            label: const Text("清空日志", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              showDialog(
                                context: ctx,
                                builder: (confirmCtx) => AlertDialog(
                                  title: const Text("确认彻底清空日志？"),
                                  content: const Text("清空后所有运行排错流水将彻底清除，无法找回。"),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(confirmCtx), child: const Text("取消")),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                                      onPressed: () async {
                                        Navigator.pop(confirmCtx);
                                        await AppLogger.clearLogs();
                                        logLines = [];
                                        logSizeBytes = 0;
                                        setDlg(() {});
                                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("日志已彻底清空")));
                                      },
                                      child: const Text("确认清空"),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(6)),
                    child: logLines.isEmpty
                        ? const Center(
                            child: Text(
                              "(当前日志为空，可将模式切换为「详细流水」查看实时运转记录)",
                              style: TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          )
                        : SelectionArea(
                            child: ListView.builder(
                              itemCount: logLines.length,
                              itemBuilder: (_, i) {
                                final line = logLines[i];
                                Color textColor = const Color(0xFFD4D4D4);
                                if (line.contains('[ERROR]')) {
                                  textColor = const Color(0xFFFF6B6B);
                                } else if (line.contains('[INFO]')) {
                                  textColor = const Color(0xFF69DB7C);
                                }
                                return Text(
                                  line,
                                  style: TextStyle(color: textColor, fontFamily: 'monospace', fontSize: 11.5, height: 1.45),
                                );
                              },
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭")),
          ],
        ),
      ),
    );
  }

  // 6. 备份文件历史恢复选择器
  static void showRestorePicker({
    required BuildContext context,
    required String lastBackupDir,
    required Function(String path) onRestoreFile,
  }) {
    showDialog(
      context: context,
      builder: (pickerCtx) => FutureBuilder<List<File>>(
        future: _getAvailableBackups(lastBackupDir),
        builder: (context, snapshot) {
          final files = snapshot.data ?? [];
          return AlertDialog(
            title: const Text('选择备份文件恢复'),
            content: SizedBox(
              width: 440,
              height: 380,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前备份目录: $lastBackupDir', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  Expanded(
                    child: snapshot.connectionState != ConnectionState.done
                        ? const Center(child: CircularProgressIndicator())
                        : files.isEmpty
                            ? const Center(child: Text('当前备份目录中没有发现 .json 备份\n可点击下方从其他路径选择', textAlign: TextAlign.center))
                            : ListView.builder(
                                itemCount: files.length,
                                itemBuilder: (ctx, index) {
                                  final f = files[index];
                                  final name = f.path.split(Platform.pathSeparator).last;
                                  final sizeKb = (f.lengthSync() / 1024).toStringAsFixed(1);
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.settings_backup_restore, color: Color(0xFFC87D2E)),
                                    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text('大小：$sizeKb KB'),
                                    onTap: () {
                                      Navigator.pop(pickerCtx);
                                      onRestoreFile(f.path);
                                    },
                                  );
                                },
                              ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.folder_open),
                        label: const Text('物理浏览选择'),
                        onPressed: () async {
                          Navigator.pop(pickerCtx);
                          final path = await StorageHelper.browseSharedStorage(
                            context,
                            chooseDirectory: false,
                            extensions: ['json'],
                            initialPath: lastBackupDir,
                          );
                          if (path != null) onRestoreFile(path);
                        },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.file_open),
                        label: const Text('系统选择器'),
                        onPressed: () async {
                          Navigator.pop(pickerCtx);
                          final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
                          final p = res?.files.single.path;
                          if (p != null) onRestoreFile(p);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(pickerCtx), child: const Text('取消'))],
          );
        },
      ),
    );
  }

  static Future<List<File>> _getAvailableBackups(String backupFolderPath) async {
    try {
      final dir = Directory(backupFolderPath);
      if (!await dir.exists()) return [];
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false).handleError((_) {})) {
        if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return files;
    } catch (_) {
      return [];
    }
  }

  // 7. 批量合并 MP3 导出弹窗 (修复 hostContext 遮蔽，支持自定义引擎)
  static void openExportDialog({
    required BuildContext hostContext,
    required ExportController exportController,
    required List<TextSliceNode> nodes,
    required List<BookChapter> alignedChapters,
    required int currentIndex,
    required String? currentBookName,
    required String lastMp3Dir,
    required int defaultThreads,
    required String currentEngine,
    required String selectedVoiceId,
    required Map<String, String> userMsVoices,
    required Map<String, String> userFishVoices,
    required List<CustomTtsEngineConfig> customEngines,
    required double speechRate,
    required int bitrate,
    required int timeoutSeconds,
    required FishAudioTTS fishTts,
    required TtsNetworkRouter networkRouter,
    required Function(String newDir) onSaveMp3Dir,
    required Function(int newThreads) onSaveThreads,
  }) {
    if (nodes.isEmpty) return;

    int exportMode = alignedChapters.isEmpty ? 1 : 0;
    int selectedChapterIdx = 0;
    if (alignedChapters.isNotEmpty) {
      for (int i = 0; i < alignedChapters.length; i++) {
        if (alignedChapters[i].paragraphIndex <= currentIndex) {
          selectedChapterIdx = i;
        } else {
          break;
        }
      }
    }

    final startCtrl = TextEditingController(text: "${currentIndex + 1}");
    final endCtrl = TextEditingController(text: "${min(currentIndex + 100, nodes.length)}");
    final String baseName = currentBookName?.split('.').first ?? "有声书";
    final dirCtrl = TextEditingController(text: lastMp3Dir);
    int dialogThreads = defaultThreads;

    String tempExportEngine = currentEngine;
    String tempExportVoiceId = selectedVoiceId;
    double tempExportSpeed = speechRate;
    int tempExportBitrate = bitrate;

    Map<String, String> voicesFor(String eng) {
      if (eng == 'ms') return userMsVoices;
      if (eng == 'fish') return userFishVoices;
      for (final c in customEngines) {
        if (c.id == eng) return c.voices;
      }
      return userMsVoices;
    }

    showDialog(
      context: hostContext,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (innerCtx, setDlgState) {
          final activeVoices = voicesFor(tempExportEngine);
          if (!activeVoices.containsKey(tempExportVoiceId)) {
            tempExportVoiceId = activeVoices.keys.first;
          }

          return ListenableBuilder(
            listenable: exportController,
            builder: (listCtx, _) => AlertDialog(
              title: const Row(children: [
                Icon(Icons.audio_file_outlined, color: Color(0xFFC87D2E)),
                SizedBox(width: 8),
                Text("批量合并导出 MP3"),
              ]),
              content: SizedBox(
                width: min(520.0, MediaQuery.of(innerCtx).size.width * 0.9),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!exportController.isExporting) ...[
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 0, label: Text("按章节导出"), icon: Icon(Icons.bookmark_outline)),
                            ButtonSegment(value: 1, label: Text("自定义范围"), icon: Icon(Icons.pin_outlined)),
                          ],
                          selected: {exportMode},
                          onSelectionChanged: (val) => setDlgState(() => exportMode = val.first),
                        ),
                        const SizedBox(height: 16),
                        if (exportMode == 0 && alignedChapters.isNotEmpty) ...[
                          DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              isExpanded: true,
                              value: selectedChapterIdx,
                              items: List.generate(alignedChapters.length, (i) {
                                final c = alignedChapters[i];
                                final int nextPIdx = (i + 1 < alignedChapters.length) ? alignedChapters[i + 1].paragraphIndex : nodes.length;
                                return DropdownMenuItem(
                                  value: i,
                                  child: Text("${c.title} (共 ${max(0, nextPIdx - c.paragraphIndex)} 项)", overflow: TextOverflow.ellipsis),
                                );
                              }),
                              onChanged: (val) {
                                if (val != null) setDlgState(() => selectedChapterIdx = val);
                              },
                            ),
                          ),
                        ] else ...[
                          Row(
                            children: [
                              Expanded(child: TextField(controller: startCtrl, decoration: const InputDecoration(labelText: "起始序号", isDense: true))),
                              const SizedBox(width: 15),
                              Expanded(child: TextField(controller: endCtrl, decoration: const InputDecoration(labelText: "结束序号", isDense: true))),
                            ],
                          ),
                        ],
                        const Divider(height: 24),
                        const Text("🎧 导出音频参数:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: tempExportEngine,
                                  items: [
                                    const DropdownMenuItem(value: "ms", child: Text("微软官方")),
                                    const DropdownMenuItem(value: "fish", child: Text("Fish Audio")),
                                    ...customEngines.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) setDlgState(() => tempExportEngine = val);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 3,
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: tempExportVoiceId,
                                  items: activeVoices.entries
                                      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) setDlgState(() => tempExportVoiceId = val);
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Text("语速: "),
                            Text("${tempExportSpeed}x", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFC87D2E))),
                            Expanded(
                              child: Slider(
                                value: tempExportSpeed,
                                min: 0.75,
                                max: 2.0,
                                divisions: 5,
                                label: "${tempExportSpeed}x",
                                onChanged: (v) => setDlgState(() => tempExportSpeed = v),
                              ),
                            ),
                            DropdownButton<int>(
                              value: tempExportBitrate,
                              items: const [DropdownMenuItem(value: 64, child: Text("64k 推荐")), DropdownMenuItem(value: 128, child: Text("128k 标准"))],
                              onChanged: (v) => setDlgState(() => tempExportBitrate = v ?? 64),
                            ),
                          ],
                        ),
                        const Divider(height: 20),
                        Row(
                          children: [
                            Expanded(child: TextField(controller: dirCtrl, decoration: const InputDecoration(labelText: "保存目录", isDense: true))),
                            IconButton(
                              icon: const Icon(Icons.folder_open, color: Color(0xFFC87D2E)),
                              onPressed: () async {
                                String? chosen;
                                if (Platform.isAndroid) {
                                  chosen = await StorageHelper.browseSharedStorage(innerCtx, chooseDirectory: true, extensions: [], initialPath: dirCtrl.text);
                                } else {
                                  chosen = await FilePicker.platform.getDirectoryPath();
                                }
                                if (chosen != null && chosen.isNotEmpty) {
                                  setDlgState(() => dirCtrl.text = chosen!);
                                  onSaveMp3Dir(chosen);
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("并发抓取线程数:"),
                            Text("$dialogThreads 线程", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: dialogThreads.toDouble(),
                          min: 1,
                          max: 16,
                          divisions: 15,
                          label: "$dialogThreads 线程",
                          onChanged: (v) => setDlgState(() => dialogThreads = v.toInt()),
                        ),
                      ] else ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("当前进度: ${exportController.done} / ${exportController.total} 单元"),
                            Text(
                              "已耗时: ${exportController.elapsedSeconds ~/ 60}分${(exportController.elapsedSeconds % 60).toString().padLeft(2, '0')}秒",
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFC87D2E)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(value: exportController.progress),
                        const SizedBox(height: 8),
                        Text(exportController.status, style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
                      ]
                    ],
                  ),
                ),
              ),
              actions: [
                if (exportController.isExporting) ...[
                  TextButton(
                    onPressed: () {
                      exportController.cancel();
                      Navigator.pop(dlgCtx);
                    },
                    child: const Text("取消任务", style: TextStyle(color: Colors.red)),
                  ),
                  FilledButton.tonal(
                    onPressed: () => Navigator.pop(dlgCtx),
                    child: const Text("最小化到主屏"),
                  ),
                ] else ...[
                  TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text("取消")),
                  FilledButton(
                    onPressed: () {
                      int s = 0;
                      int e = 0;
                      String prefix = "";
                      if (exportMode == 0 && alignedChapters.isNotEmpty) {
                        final c = alignedChapters[selectedChapterIdx];
                        s = c.paragraphIndex;
                        e = (selectedChapterIdx + 1 < alignedChapters.length) ? alignedChapters[selectedChapterIdx + 1].paragraphIndex : nodes.length;
                        final cleanTitle = c.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
                        prefix = "${baseName}_$cleanTitle";
                      } else {
                        s = (int.tryParse(startCtrl.text) ?? 1) - 1;
                        e = int.tryParse(endCtrl.text) ?? nodes.length;
                        prefix = "${baseName}_第${startCtrl.text}-${endCtrl.text}项";
                      }
                      s = s.clamp(0, nodes.length);
                      e = e.clamp(s, nodes.length);

                      final outPath = dirCtrl.text.trim();
                      onSaveThreads(dialogThreads);
                      onSaveMp3Dir(outPath);
                      Navigator.pop(dlgCtx);

                      exportController.startBackgroundExport(
                        hostContext: hostContext,
                        nodes: nodes,
                        sIdx: s,
                        eIdx: e,
                        outDir: outPath,
                        fileNamePrefix: prefix,
                        exportEngine: tempExportEngine,
                        exportVoiceId: tempExportVoiceId,
                        exportSpeed: tempExportSpeed,
                        exportBitrate: tempExportBitrate,
                        exportThreads: dialogThreads,
                        timeoutSeconds: timeoutSeconds,
                        fishTts: fishTts,
                        customEngines: customEngines,
                        networkRouter: networkRouter,
                      );
                    },
                    child: const Text("开始导出"),
                  ),
                ]
              ],
            ),
          );
        },
      ),
    ).then((_) {
      startCtrl.dispose();
      endCtrl.dispose();
      dirCtrl.dispose();
    });
  }

  // 8. 书签编辑与备注弹窗
  static void showEditBookmarkDialog({
    required BuildContext context,
    required BookBookmark bookmark,
    required Function(String newContent, String newNote) onSave,
  }) {
    final contentCtrl = TextEditingController(text: bookmark.content);
    final noteCtrl = TextEditingController(text: bookmark.note);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.bookmark, color: Color(0xFFC87D2E), size: 22),
          SizedBox(width: 8),
          Text("编辑书签", style: TextStyle(fontSize: 16)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("章节: ${bookmark.chapterTitle}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: contentCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: "摘录正文", isDense: true, border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              maxLines: 2,
              decoration: const InputDecoration(labelText: "我的读书备注", hintText: "写点感想或标记...", isDense: true, border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(
            onPressed: () {
              onSave(contentCtrl.text.trim(), noteCtrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text("保存书签"),
          ),
        ],
      ),
    ).then((_) {
      contentCtrl.dispose();
      noteCtrl.dispose();
    });
  }
}
