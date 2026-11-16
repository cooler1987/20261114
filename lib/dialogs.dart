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

    AppLogger.log("启动 MP3 批量导出 [范围: ${sIdx + 1}..$eIdx (共 $count 单元), 引擎: $exportEngine, 并发: $exportThreads]", null, null, true);

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

// ────────────────── 全屏自适应系统设置页 ──────────────────
class ReaderSettingsPage extends StatefulWidget {
  final String currentEngine;
  final String apiKey;
  final String fishModel;
  final int bitrate;
  final int timeoutSeconds;
  final int preloadCount;
  final int exportThreads;
  final int intervalPauseMs;
  final int maxCacheCount;
  final TtsNetworkRouter networkRouter;
  final List<CustomTtsEngineConfig> customEngines;
  final bool followAlong;
  final String splitMode;
  final double fontSize;
  final int readingBgColor;
  final int readingHighlightColor;
  final String logLevel;
  final String lastBackupDir;

  final Future<void> Function() onExportBackup;
  final Function(String newBackupDir) onBackupDirChanged;
  final Future<bool> Function() onShowRestorePicker;
  final Future<void> Function() onOpenCustomEnginesManager;
  final Future<void> Function({
    required String engine,
    required String apiKey,
    required String fishModel,
    required int bitrate,
    required int timeoutSeconds,
    required int preloadCount,
    required int exportThreads,
    required int intervalPauseMs,
    required int maxCacheCount,
    required Map<String, String> engineNetworkModes,
    required Map<String, String> engineCustomProxies,
    required bool followAlong,
    required String splitMode,
    required double fontSize,
    required int readingBgColor,
    required int readingHighlightColor,
    required String logLevel,
  }) onSave;

  const ReaderSettingsPage({
    super.key,
    required this.currentEngine,
    required this.apiKey,
    required this.fishModel,
    required this.bitrate,
    required this.timeoutSeconds,
    required this.preloadCount,
    required this.exportThreads,
    required this.intervalPauseMs,
    required this.maxCacheCount,
    required this.networkRouter,
    required this.customEngines,
    required this.followAlong,
    required this.splitMode,
    required this.fontSize,
    required this.readingBgColor,
    required this.readingHighlightColor,
    required this.logLevel,
    required this.lastBackupDir,
    required this.onExportBackup,
    required this.onBackupDirChanged,
    required this.onShowRestorePicker,
    required this.onOpenCustomEnginesManager,
    required this.onSave,
  });

  @override
  State<ReaderSettingsPage> createState() => _ReaderSettingsPageState();
}

class _ReaderSettingsPageState extends State<ReaderSettingsPage> {
  late TextEditingController _keyCtrl;
  late TextEditingController _bgHexCtrl;
  late TextEditingController _hlHexCtrl;

  late String _tempEngine;
  late String _tempFishModel;
  late int _tempBitrate;
  late int _tempTimeout;
  late int _tempPreload;
  late int _tempExportThreads;
  late int _tempIntervalPause;
  late int _tempMaxCache;
  late bool _tempAutoScroll;
  late String _tempSplit;
  late double _tempFontSize;
  late Color _tempBgColor;
  late Color _tempHighlightColor;
  late String _tempLogLevel;
  late String _tempBackupDir;

  late Map<String, String> _tempRoutes;
  final Map<String, TextEditingController> _customProxyCtrls = {};
  bool _probingProxy = false;
  bool _showFishConfigAlways = false;
  bool _showBgRgbSliders = false;
  bool _showHlRgbSliders = false;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController(text: widget.apiKey);
    _tempEngine = widget.currentEngine;
    _tempFishModel = fishModelOptions.contains(widget.fishModel) ? widget.fishModel : fishModelOptions.first;
    _tempBitrate = widget.bitrate;
    _tempTimeout = widget.timeoutSeconds;
    _tempPreload = widget.preloadCount;
    _tempExportThreads = widget.exportThreads;
    _tempIntervalPause = widget.intervalPauseMs;
    _tempMaxCache = widget.maxCacheCount;
    _tempAutoScroll = widget.followAlong;
    _tempSplit = widget.splitMode;
    _tempFontSize = widget.fontSize.clamp(10.0, 20.0);
    _tempBgColor = Color(widget.readingBgColor);
    _tempHighlightColor = Color(widget.readingHighlightColor);
    _bgHexCtrl = TextEditingController(text: colorToHex(_tempBgColor));
    _hlHexCtrl = TextEditingController(text: colorToHex(_tempHighlightColor));
    _tempLogLevel = AppLogger.normalizeLevel(widget.logLevel);
    _tempBackupDir = widget.lastBackupDir;
    _showFishConfigAlways = _tempEngine == 'fish' || widget.apiKey.isNotEmpty;

    _tempRoutes = Map<String, String>.from(widget.networkRouter.engineNetworkModes);
    _syncEngineNetworkState();
  }

  void _syncEngineNetworkState() {
    _tempRoutes['ms'] = normalizeEngineNetworkMode(_tempRoutes['ms']);
    _tempRoutes['fish'] = normalizeEngineNetworkMode(_tempRoutes['fish']);
    _customProxyCtrls.putIfAbsent('ms', () => TextEditingController(text: widget.networkRouter.engineCustomProxies['ms'] ?? ''));
    _customProxyCtrls.putIfAbsent('fish', () => TextEditingController(text: widget.networkRouter.engineCustomProxies['fish'] ?? ''));

    for (final c in widget.customEngines) {
      _tempRoutes[c.id] = normalizeEngineNetworkMode(c.networkMode);
      _customProxyCtrls.putIfAbsent(c.id, () => TextEditingController(text: c.customProxy));
    }
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _bgHexCtrl.dispose();
    _hlHexCtrl.dispose();
    for (final ctrl in _customProxyCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF743C00))),
    );
  }

  Widget _buildColorEditor({
    required String title,
    required Color currentColor,
    required int defaultColorValue,
    required List<int> presets,
    required TextEditingController hexController,
    required bool showSliders,
    required VoidCallback onToggleSliders,
    required ValueChanged<Color> onColorChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F4EC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E1D5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: currentColor,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.black26),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "$title (${colorToHex(currentColor)})",
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3238)),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                onPressed: () {
                  final def = Color(defaultColorValue);
                  hexController.text = colorToHex(def);
                  onColorChanged(def);
                },
                child: Text("恢复${colorToHex(Color(defaultColorValue))}", style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...presets.map((val) {
                final c = Color(val);
                final selected = c.value == currentColor.value;
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    hexController.text = colorToHex(c);
                    onColorChanged(c);
                  },
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? const Color(0xFFC87D2E) : Colors.black26,
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                    child: selected ? Icon(Icons.check, size: 15, color: getContrastTextColor(c)) : null,
                  ),
                );
              }),
              ActionChip(
                avatar: Icon(showSliders ? Icons.expand_less : Icons.tune, size: 15, color: const Color(0xFFC87D2E)),
                label: Text(showSliders ? "收起自由调色" : "自由调色 / Hex", style: const TextStyle(fontSize: 11.5)),
                onPressed: onToggleSliders,
              ),
            ],
          ),
          if (showSliders) ...[
            const SizedBox(height: 10),
            TextField(
              controller: hexController,
              decoration: const InputDecoration(
                labelText: "十六进制色值 (Hex)",
                hintText: "#D2B48C",
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                final clean = val.trim().replaceAll('#', '');
                if (clean.length == 6 && int.tryParse(clean, radix: 16) != null) {
                  onColorChanged(parseHexColor(clean, currentColor.value));
                }
              },
            ),
            const SizedBox(height: 6),
            _buildRgbChannelSlider("红 R", currentColor.red, Colors.red, (r) {
              final next = Color.fromARGB(255, r, currentColor.green, currentColor.blue);
              hexController.text = colorToHex(next);
              onColorChanged(next);
            }),
            _buildRgbChannelSlider("绿 G", currentColor.green, Colors.green, (g) {
              final next = Color.fromARGB(255, currentColor.red, g, currentColor.blue);
              hexController.text = colorToHex(next);
              onColorChanged(next);
            }),
            _buildRgbChannelSlider("蓝 B", currentColor.blue, Colors.blue, (b) {
              final next = Color.fromARGB(255, currentColor.red, currentColor.green, b);
              hexController.text = colorToHex(next);
              onColorChanged(next);
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildRgbChannelSlider(String label, int value, Color activeColor, ValueChanged<int> onChanged) {
    return Row(
      children: [
        SizedBox(width: 36, child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600))),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 2.5, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 255,
              activeColor: activeColor,
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(width: 30, child: Text("$value", textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
      ],
    );
  }

  Widget _buildEngineRouteRow(String engineId, String displayName) {
    final mode = normalizeEngineNetworkMode(_tempRoutes[engineId]);
    final proxyCtrl = _customProxyCtrls.putIfAbsent(engineId, () => TextEditingController());

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F4EC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E1D5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(displayName, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF2C3238))),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              segments: const [
                ButtonSegment(value: 'direct', label: Text('直连', style: TextStyle(fontSize: 12)), icon: Icon(Icons.public, size: 15)),
                ButtonSegment(value: 'system', label: Text('系统代理', style: TextStyle(fontSize: 12)), icon: Icon(Icons.laptop_windows_outlined, size: 15)),
                ButtonSegment(value: 'custom', label: Text('自定端口', style: TextStyle(fontSize: 12)), icon: Icon(Icons.vpn_lock, size: 15)),
              ],
              selected: {mode},
              onSelectionChanged: (v) => setState(() => _tempRoutes[engineId] = v.first),
            ),
          ),
          if (mode == 'custom') ...[
            const SizedBox(height: 8),
            TextField(
              controller: proxyCtrl,
              decoration: InputDecoration(
                labelText: '自定义代理地址 / 端口',
                hintText: '如 127.0.0.1:7890 或直接填 7890',
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: const OutlineInputBorder(),
                suffixIcon: proxyCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () => setState(() => proxyCtrl.clear()),
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ] else if (mode == 'system') ...[
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                widget.networkRouter.detectedSystemProxy?.isNotEmpty == true
                    ? "将使用系统代理: ${widget.networkRouter.detectedSystemProxy}"
                    : (Platform.isAndroid && widget.networkRouter.hasActiveVpn
                        ? "当前 Android 已开启 VPN，将随系统 VPN 路由转发"
                        : "⚠️ 当前未检测到系统代理，将自动回退直连"),
                style: TextStyle(
                  fontSize: 11.5,
                  color: (widget.networkRouter.detectedSystemProxy?.isNotEmpty == true || (Platform.isAndroid && widget.networkRouter.hasActiveVpn))
                      ? Colors.teal.shade700
                      : Colors.orange.shade800,
                ),
              ),
            ),
          ] else if (Platform.isAndroid && widget.networkRouter.hasActiveVpn) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                widget.networkRouter.hasBypassPhysicalNetwork
                    ? "已启用物理网卡直连：将绕过当前 VPN 直接连接"
                    : "⚠️ 检测到 VPN 接管且未找到可绕过物理网卡",
                style: TextStyle(
                  fontSize: 11.5,
                  color: widget.networkRouter.hasBypassPhysicalNetwork ? Colors.teal.shade700 : Colors.orange.shade800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleSave() async {
    final customProxies = <String, String>{};
    _customProxyCtrls.forEach((k, ctrl) {
      customProxies[k] = normalizeProxyInput(ctrl.text);
    });

    await widget.onSave(
      engine: _tempEngine,
      apiKey: _keyCtrl.text.trim(),
      fishModel: _tempFishModel,
      bitrate: _tempBitrate,
      timeoutSeconds: _tempTimeout,
      preloadCount: _tempPreload,
      exportThreads: _tempExportThreads,
      intervalPauseMs: _tempIntervalPause,
      maxCacheCount: _tempMaxCache,
      engineNetworkModes: _tempRoutes,
      engineCustomProxies: customProxies,
      followAlong: _tempAutoScroll,
      splitMode: _tempSplit,
      fontSize: _tempFontSize,
      readingBgColor: _tempBgColor.value,
      readingHighlightColor: _tempHighlightColor.value,
      logLevel: _tempLogLevel,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final allEngineIds = <String>{'ms', 'fish', ...widget.customEngines.map((e) => e.id)};
    if (!allEngineIds.contains(_tempEngine)) _tempEngine = 'ms';

    final previewBodyColor = getContrastTextColor(_tempBgColor);
    final previewHlTextColor = getHighlightTextColor(_tempHighlightColor);
    final previewHlAccent = getHighlightAccentColor(_tempHighlightColor);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: "取消", onPressed: () => Navigator.pop(context)),
        title: const Text("系统与引擎设置"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              icon: const Icon(Icons.check, size: 18),
              label: const Text("保存配置"),
              onPressed: _handleSave,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 32),
              children: [
                Card(
                  color: const Color(0xFFFCFBF7),
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE7E2D5))),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildSectionTitle("🔊 TTS 引擎与品质"),
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                              icon: const Icon(Icons.extension_outlined, size: 16),
                              label: Text("自定义引擎 (${widget.customEngines.length})", style: const TextStyle(fontSize: 12)),
                              onPressed: () async {
                                await widget.onOpenCustomEnginesManager();
                                _syncEngineNetworkState();
                                if (mounted) setState(() {});
                              },
                            ),
                          ],
                        ),
                        DropdownButtonFormField<String>(
                          value: _tempEngine,
                          decoration: const InputDecoration(labelText: '当前朗读引擎', isDense: true, border: OutlineInputBorder()),
                          items: [
                            const DropdownMenuItem(value: 'ms', child: Text('微软官方 (免Key)')),
                            const DropdownMenuItem(value: 'fish', child: Text('Fish Audio 官方引擎')),
                            ...widget.customEngines.map((c) => DropdownMenuItem(value: c.id, child: Text('🧩 ${c.name}', overflow: TextOverflow.ellipsis))),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              setState(() {
                                _tempEngine = v;
                                if (v == 'fish') _showFishConfigAlways = true;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 10),
                        if (_tempEngine == 'fish' || _showFishConfigAlways) ...[
                          TextField(
                            controller: _keyCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Fish Audio API Key',
                              hintText: '填入 Fish Audio 官方 Key',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            value: _tempFishModel,
                            decoration: const InputDecoration(labelText: 'Fish 模型版本', isDense: true, border: OutlineInputBorder()),
                            items: fishModelOptions.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                            onChanged: (v) {
                              if (v != null) setState(() => _tempFishModel = v);
                            },
                          ),
                          const SizedBox(height: 10),
                        ] else ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                              icon: const Icon(Icons.key, size: 16),
                              label: const Text("展开 Fish Audio Key 与模型设置", style: TextStyle(fontSize: 12)),
                              onPressed: () => setState(() => _showFishConfigAlways = true),
                            ),
                          ),
                        ],
                        DropdownButtonFormField<int>(
                          value: _tempBitrate,
                          decoration: const InputDecoration(labelText: '音频合成质量', isDense: true, border: OutlineInputBorder()),
                          items: const [
                            DropdownMenuItem(value: 64, child: Text('64 kbps (默认 · 极速省流)')),
                            DropdownMenuItem(value: 128, child: Text('128 kbps (高品质清晰)')),
                          ],
                          onChanged: (v) => setState(() => _tempBitrate = v ?? 64),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("单句合成超时等待上限:"),
                            Text("$_tempTimeout 秒", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: _tempTimeout.toDouble(),
                          min: 20,
                          max: 120,
                          divisions: 100,
                          label: "$_tempTimeout 秒",
                          onChanged: (v) => setState(() => _tempTimeout = v.toInt()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: const Color(0xFFFCFBF7),
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE7E2D5))),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildSectionTitle("🌐 分引擎网络通道 (默认直连)"),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                              icon: _probingProxy
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.refresh, size: 15),
                              label: const Text("探测网络环境", style: TextStyle(fontSize: 11.5)),
                              onPressed: _probingProxy
                                  ? null
                                  : () async {
                                      setState(() => _probingProxy = true);
                                      await widget.networkRouter.refreshSystemProxy();
                                      if (mounted) setState(() => _probingProxy = false);
                                    },
                            ),
                          ],
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(color: const Color(0xFFEFE7D2), borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            widget.networkRouter.describeNetworkBanner(),
                            style: const TextStyle(fontSize: 12, color: Color(0xFF743C00)),
                          ),
                        ),
                        _buildEngineRouteRow('ms', '微软官方引擎'),
                        _buildEngineRouteRow('fish', 'Fish Audio 官方引擎'),
                        for (final c in widget.customEngines) _buildEngineRouteRow(c.id, '🧩 ${c.name}'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: const Color(0xFFFCFBF7),
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE7E2D5))),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionTitle("📖 阅读外观与朗读规则"),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("正文字体大小 (10–20 px):"),
                            Row(
                              children: [
                                Text(
                                  "${_tempFontSize.toStringAsFixed(1).replaceAll('.0', '')} px",
                                  style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                                  onPressed: () => setState(() => _tempFontSize = 14.0),
                                  child: const Text("恢复14px", style: TextStyle(fontSize: 11.5)),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Slider(
                          value: _tempFontSize,
                          min: 10.0,
                          max: 20.0,
                          divisions: 20,
                          label: "${_tempFontSize.toStringAsFixed(1).replaceAll('.0', '')} px",
                          onChanged: (v) => setState(() => _tempFontSize = double.parse(v.toStringAsFixed(1))),
                        ),
                        _buildColorEditor(
                          title: "阅读背景色",
                          currentColor: _tempBgColor,
                          defaultColorValue: defaultReadingBgColorValue,
                          presets: presetReadingBgColors,
                          hexController: _bgHexCtrl,
                          showSliders: _showBgRgbSliders,
                          onToggleSliders: () => setState(() => _showBgRgbSliders = !_showBgRgbSliders),
                          onColorChanged: (c) => setState(() => _tempBgColor = c),
                        ),
                        const SizedBox(height: 10),
                        _buildColorEditor(
                          title: "正在朗读文本高亮色",
                          currentColor: _tempHighlightColor,
                          defaultColorValue: defaultReadingHighlightColorValue,
                          presets: presetReadingHighlightColors,
                          hexController: _hlHexCtrl,
                          showSliders: _showHlRgbSliders,
                          onToggleSliders: () => setState(() => _showHlRgbSliders = !_showHlRgbSliders),
                          onColorChanged: (c) => setState(() => _tempHighlightColor = c),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: _tempBgColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.black12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _tempHighlightColor,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border(left: BorderSide(color: previewHlAccent, width: 3.5)),
                                ),
                                child: Text(
                                  "正在朗读：春风拂槛露华浓，静听书声伴晚钟。",
                                  style: TextStyle(fontSize: _tempFontSize, color: previewHlTextColor, fontWeight: FontWeight.w600, height: 1.6),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Text(
                                  "普通正文：长夜漫漫，翻开书页即是远方。",
                                  style: TextStyle(fontSize: _tempFontSize, color: previewBodyColor, height: 1.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          value: _tempSplit,
                          decoration: const InputDecoration(labelText: '朗读断句规则 (CharOffset 无缝定位)', isDense: true, border: OutlineInputBorder()),
                          items: const [
                            DropdownMenuItem(value: 'sentence', child: Text('按标点断句朗读 (推荐)')),
                            DropdownMenuItem(value: 'paragraph', child: Text('按自然段落朗读')),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _tempSplit = v);
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("句/段朗读间隔停顿:"),
                            Text("$_tempIntervalPause ms", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: _tempIntervalPause.toDouble(),
                          min: 0,
                          max: 1500,
                          divisions: 15,
                          label: "$_tempIntervalPause ms",
                          onChanged: (v) => setState(() => _tempIntervalPause = (v / 50).round() * 50),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text("朗读时正文视线平滑居中", style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                          value: _tempAutoScroll,
                          onChanged: (v) => setState(() => _tempAutoScroll = v),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: const Color(0xFFFCFBF7),
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE7E2D5))),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionTitle("⚡ 性能、预读与缓存"),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("朗读后台预读缓存:"),
                            Text("$_tempPreload 句", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: _tempPreload.toDouble(),
                          min: 1,
                          max: 15,
                          divisions: 14,
                          label: "$_tempPreload 句",
                          onChanged: (v) => setState(() => _tempPreload = v.toInt()),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("导出 MP3 默认并发线程:"),
                            Text("$_tempExportThreads 线程", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: _tempExportThreads.toDouble(),
                          min: 1,
                          max: 16,
                          divisions: 15,
                          label: "$_tempExportThreads 线程",
                          onChanged: (v) => setState(() => _tempExportThreads = v.toInt()),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("音频内存最大缓存上限:"),
                            Text("$_tempMaxCache 句", style: const TextStyle(color: Color(0xFFC87D2E), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: _tempMaxCache.toDouble(),
                          min: 50,
                          max: 300,
                          divisions: 25,
                          label: "$_tempMaxCache",
                          onChanged: (v) => setState(() => _tempMaxCache = v.toInt()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: const Color(0xFFFCFBF7),
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE7E2D5))),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionTitle("💾 备份、恢复与日志层级"),
                        const Text("运行日志记录层级:", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                            segments: const [
                              ButtonSegment(value: 'error', label: Text('仅错误', style: TextStyle(fontSize: 12))),
                              ButtonSegment(value: 'info', label: Text('重要事件', style: TextStyle(fontSize: 12))),
                              ButtonSegment(value: 'all', label: Text('全量调试', style: TextStyle(fontSize: 12))),
                            ],
                            selected: {_tempLogLevel},
                            onSelectionChanged: (v) => setState(() => _tempLogLevel = v.first),
                          ),
                        ),
                        const Divider(height: 22),
                        Text("当前备份目录:\n$_tempBackupDir", style: const TextStyle(fontSize: 11.5, color: Colors.blueGrey, height: 1.4)),
                        const SizedBox(height: 10),
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
                                    context,
                                    chooseDirectory: true,
                                    extensions: [],
                                    initialPath: _tempBackupDir,
                                  );
                                } else {
                                  newDir = await FilePicker.platform.getDirectoryPath();
                                }
                                if (newDir != null) {
                                  setState(() => _tempBackupDir = newDir!);
                                  widget.onBackupDirChanged(newDir);
                                }
                              },
                            ),
                            FilledButton.icon(
                              icon: const Icon(Icons.file_upload, size: 16),
                              label: const Text("一键导出备份"),
                              onPressed: () async {
                                await widget.onExportBackup();
                              },
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.restore, size: 16),
                              label: const Text("选择文件恢复"),
                              onPressed: () async {
                                final restored = await widget.onShowRestorePicker();
                                if (restored && mounted) {
                                  Navigator.pop(context);
                                }
                              },
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
      ),
    );
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

  // 1. 打开全屏设置页
  static Future<void> openSettingsPage({
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
    required TtsNetworkRouter networkRouter,
    required List<CustomTtsEngineConfig> customEngines,
    required bool followAlong,
    required String splitMode,
    required double fontSize,
    required int readingBgColor,
    required int readingHighlightColor,
    required String logLevel,
    required String lastBackupDir,
    required Future<void> Function() onExportBackup,
    required Function(String newBackupDir) onBackupDirChanged,
    required Future<bool> Function() onShowRestorePicker,
    required Future<void> Function() onOpenCustomEnginesManager,
    required Future<void> Function({
      required String engine,
      required String apiKey,
      required String fishModel,
      required int bitrate,
      required int timeoutSeconds,
      required int preloadCount,
      required int exportThreads,
      required int intervalPauseMs,
      required int maxCacheCount,
      required Map<String, String> engineNetworkModes,
      required Map<String, String> engineCustomProxies,
      required bool followAlong,
      required String splitMode,
      required double fontSize,
      required int readingBgColor,
      required int readingHighlightColor,
      required String logLevel,
    }) onSave,
  }) {
    return Navigator.push<void>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ReaderSettingsPage(
          currentEngine: currentEngine,
          apiKey: apiKey,
          fishModel: fishModel,
          bitrate: bitrate,
          timeoutSeconds: timeoutSeconds,
          preloadCount: preloadCount,
          exportThreads: exportThreads,
          intervalPauseMs: intervalPauseMs,
          maxCacheCount: maxCacheCount,
          networkRouter: networkRouter,
          customEngines: customEngines,
          followAlong: followAlong,
          splitMode: splitMode,
          fontSize: fontSize,
          readingBgColor: readingBgColor,
          readingHighlightColor: readingHighlightColor,
          logLevel: logLevel,
          lastBackupDir: lastBackupDir,
          onExportBackup: onExportBackup,
          onBackupDirChanged: onBackupDirChanged,
          onShowRestorePicker: onShowRestorePicker,
          onOpenCustomEnginesManager: onOpenCustomEnginesManager,
          onSave: onSave,
        ),
      ),
    );
  }
  
