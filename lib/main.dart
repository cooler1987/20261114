import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dialogs.dart';
import 'models.dart';
import 'reader_controller.dart';
import 'reader_widgets.dart';
import 'system_utils.dart';
import 'tts_engines.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();

  FlutterError.onError = (details) {
    AppLogger.log("Flutter 未捕获异常: ${details.exceptionAsString()}", details.exception, details.stack);
  };

  final prefs = await SharedPreferences.getInstance();
  runApp(FishAudioReaderApp(prefs: prefs));
}

class FishAudioReaderApp extends StatefulWidget {
  final SharedPreferences prefs;
  const FishAudioReaderApp({super.key, required this.prefs});

  @override
  State<FishAudioReaderApp> createState() => _FishAudioReaderAppState();
}

class _FishAudioReaderAppState extends State<FishAudioReaderApp> {
  late final ReaderController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ReaderController(prefs: widget.prefs);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (ctx, _) {
        final themeCfg = _controller.theme;
        return MaterialApp(
          title: '鱼听书 (微信读书质感版)',
          navigatorKey: AppToast.navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: themeCfg.brightness,
            colorScheme: ColorScheme.fromSeed(
              seedColor: themeCfg.accent,
              brightness: themeCfg.brightness,
              surface: themeCfg.surfaceBg,
            ),
            scaffoldBackgroundColor: themeCfg.scaffoldBg,
            appBarTheme: AppBarTheme(
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: themeCfg.scaffoldBg,
              foregroundColor: themeCfg.primaryText,
              titleTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: themeCfg.primaryText),
            ),
          ),
          home: ReaderHomeScreen(controller: _controller),
        );
      },
    );
  }
}

class ReaderHomeScreen extends StatefulWidget {
  final ReaderController controller;
  const ReaderHomeScreen({super.key, required this.controller});

  @override
  State<ReaderHomeScreen> createState() => _ReaderHomeScreenState();
}

class _ReaderHomeScreenState extends State<ReaderHomeScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final FocusNode _keyboardFocusNode = FocusNode();
  final ExportController _exportController = ExportController();
  final TextEditingController _searchCtrl = TextEditingController();

  Timer? _searchDebounce;

  int _sidebarTab = 0;
  bool _isSelectionMode = false;
  final Set<String> _selectedFingerprints = {};
  bool _showBackToCurrent = false;

  // 被动指针记录：确保长按弹出右键菜单、添加书签、从此朗读精确指向当前触摸段落且不干扰 SelectionArea
  int? _interactedParaIdx;
  int? _interactedSliceIdx;

  // 边缘滑动手势 & 二次确认退出追踪
  double _pointerDownX = -1;
  double _pointerDownY = -1;
  int _pointerDownTimeMs = 0;
  bool _edgeSwipeHandled = false;
  int _edgeHandledTimeMs = 0;
  int _lastExitPromptTimeMs = 0;
  bool _isVoiceManagerOpen = false;

  ReaderController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ctrl.onScrollToParaRequest = _scrollToPara;
    _ctrl.onOpenBookmarksDrawer = () {
      setState(() => _sidebarTab = 2);
      _scaffoldKey.currentState?.openDrawer();
    };
    _ctrl.addListener(_onControllerChanged);
    _exportController.addListener(_onExportChanged);
    _itemPositionsListener.itemPositions.addListener(_onViewportPositionsChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onExportChanged() {
    if (mounted) setState(() {});
  }

  void _onViewportPositionsChanged() {
    if (_ctrl.paragraphs.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final activePara = _ctrl.activeParagraphIndex;
    final visible = positions.any((p) => p.index == activePara);
    if (_showBackToCurrent == visible && mounted) {
      setState(() => _showBackToCurrent = !visible);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.removeListener(_onControllerChanged);
    _exportController.removeListener(_onExportChanged);
    _itemPositionsListener.itemPositions.removeListener(_onViewportPositionsChanged);
    _searchDebounce?.cancel();
    _exportController.dispose();
    _keyboardFocusNode.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _ctrl.saveHistoryToPrefs(immediate: true);
      _ctrl.saveSettings();
      AppLogger.flush();
    }
  }

  void _scrollToPara(int paraIdx, {bool immediate = false, bool force = false}) {
    if (!force && !_ctrl.followAlong) return;
    if (!_itemScrollController.isAttached || _ctrl.paragraphs.isEmpty) return;
    final safeIdx = paraIdx.clamp(0, _ctrl.paragraphs.length - 1);
    if (immediate) {
      _itemScrollController.jumpTo(index: safeIdx, alignment: 0.30);
    } else {
      _itemScrollController.scrollTo(
        index: safeIdx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.30,
      );
    }
    if (mounted && _showBackToCurrent) {
      setState(() => _showBackToCurrent = false);
    }
  }

  void _scrollToCurrentCenter({bool immediate = false, bool force = false}) {
    _scrollToPara(_ctrl.activeParagraphIndex, immediate: immediate, force: force);
  }

  Future<void> _openBookWithLoading(String path) async {
    await _ctrl.openBook(
      path,
      onStartLoading: () {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: Card(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))),
        );
      },
      onEndLoading: () {
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      },
    );
  }

  Future<void> _importFile() async {
    String? path;
    if (Platform.isAndroid) {
      path = await StorageHelper.browseSharedStorage(
        context,
        chooseDirectory: false,
        extensions: ['txt', 'epub', 'md', 'markdown'],
        initialPath: _ctrl.lastBookDir.isNotEmpty ? _ctrl.lastBookDir : null,
      );
    }
    if (path == null) {
      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'epub', 'md', 'markdown']);
      path = res?.files.single.path;
    }
    if (path != null) await _openBookWithLoading(path);
  }

  // ────────── 边缘划动与退出确认逻辑 ──────────
  Future<void> _promptOrExitApp() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastExitPromptTimeMs > 2200) {
      _lastExitPromptTimeMs = now;
      AppToast.show('再划或再按一次退出鱼听书', duration: const Duration(milliseconds: 1800));
      return;
    }
    await _ctrl.saveHistoryToPrefs(immediate: true);
    await _ctrl.saveSettings();
    await AppLogger.flush();
    SystemNavigator.pop();
  }

  void _handleLeftEdgeSwipeRight() {
    final isDrawerOpen = _scaffoldKey.currentState?.isDrawerOpen == true;
    if (!isDrawerOpen) {
      setState(() => _sidebarTab = 0);
      _scaffoldKey.currentState?.openDrawer();
    } else {
      // 第二划：弹出退出提示，再划则退出
      _promptOrExitApp();
    }
  }

  void _handleRightEdgeSwipeLeft() {
    if (_isVoiceManagerOpen) return;
    _showVoiceManagerDialog();
  }

  // ────────── 弹窗与页面编排 ──────────
  Future<void> _showVoiceManagerDialog() async {
    if (_isVoiceManagerOpen) return;
    _isVoiceManagerOpen = true;
    try {
      await ReaderDialogs.showVoiceManagerDialog(
        context: context,
        currentEngine: _ctrl.currentEngine,
        selectedVoiceId: _ctrl.selectedVoiceId,
        userMsVoices: _ctrl.userMsVoices,
        userFishVoices: _ctrl.userFishVoices,
        customEngines: _ctrl.customEngines,
        pinnedVoiceIds: _ctrl.pinnedVoiceIds,
        speechRate: _ctrl.speechRate,
        bitrate: _ctrl.bitrate,
        timeoutSeconds: _ctrl.timeoutSeconds,
        fishTts: _ctrl.fishTts,
        networkRouter: _ctrl.networkRouter,
        onVoiceSelected: (eng, vId) {
          _ctrl.currentEngine = eng;
          _ctrl.selectedVoiceId = vId;
          _ctrl.invalidateAudioCache();
          _ctrl.saveSettings();
          setState(() {});
          if (_ctrl.isPlaying) _ctrl.startTTS();
        },
        onVoicesUpdated: (eng, updatedMap) {
          if (eng == "ms") {
            _ctrl.userMsVoices = Map.from(updatedMap);
          } else if (eng == "fish") {
            _ctrl.userFishVoices = Map.from(updatedMap);
            _ctrl.fishTts.voices = _ctrl.userFishVoices;
          } else {
            for (final c in _ctrl.customEngines) {
              if (c.id == eng) {
                c.voices = Map.from(updatedMap);
                break;
              }
            }
          }
          _ctrl.ensureValidSelectedEngineAndVoice();
          _ctrl.saveSettings();
          setState(() {});
        },
        onVoicesReset: (eng) {
          if (eng == "ms") {
            _ctrl.userMsVoices = Map.from(defaultMsVoices46);
          } else if (eng == "fish") {
            _ctrl.userFishVoices = Map.from(defaultFishVoices);
            _ctrl.fishTts.voices = _ctrl.userFishVoices;
          }
          _ctrl.ensureValidSelectedEngineAndVoice();
          _ctrl.saveSettings();
          setState(() {});
        },
        onPinToggled: () => _ctrl.saveSettings(),
      );
    } finally {
      _isVoiceManagerOpen = false;
    }
  }

  Future<void> _openCustomEnginesManager() {
    return ReaderDialogs.showCustomEnginesDialog(
      context: context,
      customEngines: _ctrl.customEngines,
      activeEngineId: _ctrl.currentEngine,
      networkRouter: _ctrl.networkRouter,
      timeoutSeconds: _ctrl.timeoutSeconds,
      onCustomEnginesChanged: (updated) {
        _ctrl.customEngines = updated;
        for (final c in _ctrl.customEngines) {
          _ctrl.networkRouter.setEngineNetwork(c.id, c.networkMode, c.customProxy);
        }
        _ctrl.ensureValidSelectedEngineAndVoice();
        _ctrl.invalidateAudioCache();
        _ctrl.saveSettings();
        setState(() {});
      },
      onSelectEngine: (engineId) {
        _ctrl.currentEngine = engineId;
        _ctrl.selectedVoiceId = _ctrl.defaultVoiceForEngine(engineId);
        _ctrl.invalidateAudioCache();
        _ctrl.saveSettings();
        setState(() {});
        if (_ctrl.isPlaying) _ctrl.startTTS();
      },
    );
  }

  Future<bool> _handleRestoreFromFile(String path) async {
    final summary = await _ctrl.restoreBackupFromFile(path);
    if (summary == null || !mounted) return false;

    final keyStr = summary['apiKey'].toString();
    final maskedKey = keyStr.isEmpty
        ? '未配置'
        : (keyStr.length <= 8 ? '已恢复 (${keyStr.length}位)' : '${keyStr.substring(0, 4)}****${keyStr.substring(keyStr.length - 4)}');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('备份恢复成功'),
          ],
        ),
        content: Text(
          '已同步应用并写入本地持久化：\n'
          '• 当前引擎：${ReaderDialogs.getEngineDisplayName(_ctrl.currentEngine, _ctrl.customEngines)}\n'
          '• Fish API Key：$maskedKey\n'
          '• 预读缓存：${_ctrl.preloadCount} 句 | 智能合并：${_ctrl.mergeMinChars == 0 ? "关闭" : "≥${_ctrl.mergeMinChars}字"}\n'
          '• 正文字号：${_ctrl.fontSize.toStringAsFixed(1).replaceAll(".0", "")} px | 日志层级：${AppLogger.logLevel}\n'
          '• 自定义引擎：${_ctrl.customEngines.length} 个\n'
          '• 书架记录：${_ctrl.history.length} 本 | 书签：${_ctrl.bookmarks.length} 条',
          style: const TextStyle(height: 1.5, fontSize: 13),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定'))],
      ),
    );
    return true;
  }

  void _openSettingsPage() {
    ReaderDialogs.openSettingsPage(
      context: context,
      currentEngine: _ctrl.currentEngine,
      apiKey: _ctrl.apiKey,
      fishModel: _ctrl.fishModel,
      bitrate: _ctrl.bitrate,
      timeoutSeconds: _ctrl.timeoutSeconds,
      preloadCount: _ctrl.preloadCount,
      exportThreads: _ctrl.exportThreads,
      intervalPauseMs: _ctrl.intervalPauseMs,
      maxCacheCount: _ctrl.maxCacheCount,
      networkRouter: _ctrl.networkRouter,
      customEngines: _ctrl.customEngines,
      followAlong: _ctrl.followAlong,
      splitMode: _ctrl.splitMode,
      mergeMinChars: _ctrl.mergeMinChars,
      fontSize: _ctrl.fontSize,
      lineHeight: _ctrl.lineHeight,
      horizontalPadding: _ctrl.horizontalPadding,
      themeId: _ctrl.themeId,
      ignoreBadCert: _ctrl.networkRouter.ignoreBadCertificate,
      logLevel: AppLogger.logLevel,
      lastBackupDir: _ctrl.lastBackupDir,
      onExportBackup: () async {
        final filePath = await _ctrl.exportBackup();
        if (filePath != null && mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('备份导出成功'),
              content: Text('全量配置、自定义引擎、网络策略、书架与书签已成功写入：\n\n$filePath'),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
            ),
          );
        }
      },
      onBackupDirChanged: (d) {
        _ctrl.lastBackupDir = d;
        _ctrl.saveSettings();
      },
      onShowRestorePicker: () => ReaderDialogs.showRestorePicker(
        context: context,
        lastBackupDir: _ctrl.lastBackupDir,
        onRestoreFile: _handleRestoreFromFile,
      ),
      onOpenCustomEnginesManager: _openCustomEnginesManager,
      onSave: ({
        required engine,
        required apiKey,
        required fishModel,
        required bitrate,
        required timeoutSeconds,
        required preloadCount,
        required exportThreads,
        required intervalPauseMs,
        required maxCacheCount,
        required engineNetworkModes,
        required engineCustomProxies,
        required ignoreBadCert,
        required followAlong,
        required splitMode,
        required mergeMinChars,
        required fontSize,
        required lineHeight,
        required horizontalPadding,
        required themeId,
        required logLevel,
      }) async {
        final bool resliceNeeded = (_ctrl.splitMode != splitMode) || (_ctrl.mergeMinChars != mergeMinChars);
        final bool audioParamsChanged = (_ctrl.currentEngine != engine || _ctrl.bitrate != bitrate || _ctrl.fishModel != fishModel || _ctrl.apiKey != apiKey);

        _ctrl.currentEngine = engine;
        _ctrl.apiKey = apiKey;
        _ctrl.fishModel = fishModel;
        _ctrl.fishTts.apiKey = apiKey;
        _ctrl.fishTts.model = fishModel;
        _ctrl.bitrate = bitrate;
        _ctrl.timeoutSeconds = timeoutSeconds;
        _ctrl.preloadCount = preloadCount;
        _ctrl.exportThreads = exportThreads;
        _ctrl.intervalPauseMs = intervalPauseMs;
        _ctrl.maxCacheCount = maxCacheCount;
        AppLogger.logLevel = AppLogger.normalizeLevel(logLevel);

        _ctrl.networkRouter.setIgnoreBadCert(ignoreBadCert);
        engineNetworkModes.forEach((k, mode) {
          final customAddr = engineCustomProxies[k] ?? '';
          _ctrl.networkRouter.setEngineNetwork(k, mode, customAddr);
          for (final c in _ctrl.customEngines) {
            if (c.id == k) {
              c.networkMode = normalizeEngineNetworkMode(mode);
              c.customProxy = normalizeProxyInput(customAddr);
            }
          }
        });

        _ctrl.followAlong = followAlong;
        _ctrl.fontSize = fontSize.clamp(10.0, 20.0);
        _ctrl.lineHeight = lineHeight.clamp(1.4, 2.2);
        _ctrl.horizontalPadding = horizontalPadding.clamp(8.0, 40.0);
        _ctrl.themeId = ReaderThemeConfig.byId(themeId).id;
        _ctrl.ensureValidSelectedEngineAndVoice();
        if (audioParamsChanged) _ctrl.invalidateAudioCache();

        await _ctrl.networkRouter.refreshSystemProxy();
        await _ctrl.saveSettings();
        AppLogger.log("系统设置已保存 [主题:${_ctrl.themeId}, 合并:${mergeMinChars}字, 字号:${_ctrl.fontSize}px]", null, null, true);

        if (resliceNeeded) {
          await _ctrl.switchSplitAndMerge(splitMode, mergeMinChars);
        } else {
          setState(() {});
          if (audioParamsChanged && _ctrl.isPlaying) _ctrl.startTTS();
        }
      },
    );
  }

  void _showSleepTimerDialog() {
    ReaderDialogs.showSleepTimerDialog(
      context: context,
      sleepTimeLeftSeconds: _ctrl.sleepTimeLeftSeconds,
      sleepStopAfterChapter: _ctrl.sleepStopAfterChapter,
      onStartTimer: _ctrl.startSleepTimer,
      onCancelTimer: _ctrl.cancelSleepTimer,
      onStopAfterChapter: _ctrl.setStopAfterChapter,
    );
  }

  void _openExportDialog() {
    ReaderDialogs.openExportDialog(
      hostContext: context,
      exportController: _exportController,
      nodes: _ctrl.nodes,
      alignedChapters: _ctrl.alignedChapters,
      currentIndex: _ctrl.currentIndex,
      currentBookName: _ctrl.currentBookName,
      lastMp3Dir: _ctrl.lastMp3Dir,
      defaultThreads: _ctrl.exportThreads,
      currentEngine: _ctrl.currentEngine,
      selectedVoiceId: _ctrl.selectedVoiceId,
      userMsVoices: _ctrl.userMsVoices,
      userFishVoices: _ctrl.userFishVoices,
      customEngines: _ctrl.customEngines,
      speechRate: _ctrl.speechRate,
      bitrate: _ctrl.bitrate,
      timeoutSeconds: _ctrl.timeoutSeconds,
      fishTts: _ctrl.fishTts,
      networkRouter: _ctrl.networkRouter,
      onSaveMp3Dir: (d) {
        _ctrl.lastMp3Dir = d;
        _ctrl.saveSettings();
      },
      onSaveThreads: (th) {
        _ctrl.exportThreads = th;
        _ctrl.saveSettings();
      },
    );
  }

  String _describeEngineRoute(String engId) {
    final route = _ctrl.networkRouter.getEngineRoute(engId, _ctrl.customEngines);
    if (route == 'system') {
      final sys = _ctrl.networkRouter.detectedSystemProxy;
      return sys != null && sys.isNotEmpty ? '系统代理($sys)' : '系统代理(未检测到-回退直连)';
    }
    if (route == 'custom') {
      final custom = _ctrl.networkRouter.getEngineCustomProxy(engId, _ctrl.customEngines);
      return custom.isNotEmpty ? '自定义代理($custom)' : '自定义代理(未填写-回退直连)';
    }
    return '直连';
  }

  Future<void> _runConnectivityDiagnostics() async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    await _ctrl.networkRouter.refreshSystemProxy();
    final msRes = await MicrosoftTranslatorTTS.testConnectivity(_ctrl.networkRouter.getClientForEngine('ms', _ctrl.customEngines));
    final fishRes = await _ctrl.fishTts.testConnectivity(_ctrl.networkRouter.getClientForEngine('fish', _ctrl.customEngines));
    final customResults = <Map<String, dynamic>>[];
    for (final c in _ctrl.customEngines) {
      final r = await CustomTtsRunner.testConnectivity(c, _ctrl.networkRouter);
      customResults.add({'id': c.id, 'name': c.name, ...r});
    }
    if (!mounted) return;
    Navigator.pop(context);

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("TTS 引擎连通性报告"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("微软官方 [${_describeEngineRoute('ms')}]: ${msRes['success'] ? '✅ 畅通' : '❌ 异常'} (${msRes['latency']}ms)"),
              Text("详情: ${msRes['msg']}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              const Divider(),
              Text("Fish Audio [${_describeEngineRoute('fish')}]: ${fishRes['success'] ? '✅ 畅通' : '❌ 异常'} (${fishRes['latency']}ms)"),
              Text("详情: ${fishRes['msg']}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              for (final cr in customResults) ...[
                const Divider(),
                Text("🧩 ${cr['name']} [${_describeEngineRoute(cr['id'])}]: ${cr['success'] ? '✅ 畅通' : '❌ 异常'} (${cr['latency']}ms)"),
                Text("详情: ${cr['msg']}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text("好"))],
      ),
    );
  }

  // ────────── 自然段内联富文本高亮 (合并 TTS 当前句与全书搜索高亮) ──────────
  Widget _buildRichParagraph(BookParagraph para, int paraIdx, ReaderThemeConfig theme) {
    final text = para.text;
    final activeSlice = _ctrl.activeSliceNode;

    int ttsStart = -1;
    int ttsEnd = -1;
    if (activeSlice != null) {
      final overlapS = max(para.startOffset, activeSlice.startOffset);
      final overlapE = min(para.endOffset, activeSlice.endOffset);
      if (overlapS < overlapE) {
        ttsStart = (overlapS - para.startOffset).clamp(0, text.length);
        ttsEnd = (overlapE - para.startOffset).clamp(0, text.length);
      }
    }

    final searchRanges = <List<int>>[];
    if (_ctrl.isSearching && _ctrl.activeSearchQuery.isNotEmpty) {
      final q = _ctrl.activeSearchQuery;
      final lower = text.toLowerCase();
      int pos = 0;
      while (true) {
        final idx = lower.indexOf(q, pos);
        if (idx == -1) break;
        searchRanges.add([idx, idx + q.length]);
        pos = idx + max(1, q.length);
      }
    }

    final baseStyle = TextStyle(
      fontSize: _ctrl.fontSize,
      height: _ctrl.lineHeight,
      letterSpacing: 0.3,
      color: theme.primaryText,
    );

    if (ttsStart < 0 && searchRanges.isEmpty) {
      return Text(text, style: baseStyle);
    }

    // 收集所有区间切割点
    final cuts = <int>{0, text.length};
    if (ttsStart >= 0 && ttsEnd > ttsStart) {
      cuts.add(ttsStart);
      cuts.add(ttsEnd);
    }
    for (final r in searchRanges) {
      cuts.add(r[0].clamp(0, text.length));
      cuts.add(r[1].clamp(0, text.length));
    }
    final sortedCuts = cuts.toList()..sort();

    final spans = <TextSpan>[];
    for (int i = 0; i < sortedCuts.length - 1; i++) {
      final s = sortedCuts[i];
      final e = sortedCuts[i + 1];
      if (s >= e) continue;

      final bool inTts = ttsStart >= 0 && s >= ttsStart && e <= ttsEnd;
      final bool inSearch = searchRanges.any((r) => s >= r[0] && e <= r[1]);

      TextStyle? segStyle;
      if (inSearch && inTts) {
        segStyle = TextStyle(
          backgroundColor: theme.searchMatchBg,
          color: theme.searchMatchText,
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.underline,
          decorationColor: theme.accent,
        );
      } else if (inSearch) {
        segStyle = TextStyle(
          backgroundColor: theme.searchMatchBg,
          color: theme.searchMatchText,
          fontWeight: FontWeight.bold,
        );
      } else if (inTts) {
        segStyle = TextStyle(
          backgroundColor: theme.highlightBg,
          color: theme.highlightText,
          fontWeight: FontWeight.w600,
        );
      }
      spans.add(TextSpan(text: text.substring(s, e), style: segStyle));
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  @override
  Widget build(BuildContext context) {
    final theme = _ctrl.theme;
    final bool isWide = MediaQuery.of(context).size.width >= 750;
    final String bookTitle = _ctrl.currentBookName ?? "微信读书纯享版";
    final String chapSubTitle = _ctrl.currentChapterTitle();
    final bookList = _ctrl.sortedBookList;
    final activeParaIdx = _ctrl.activeParagraphIndex;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (_ctrl.isSearching) {
          _ctrl.clearSearch(closeBar: true);
          return;
        }
        if (_isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedFingerprints.clear();
          });
          return;
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        // 若刚在应用内处理过边缘手势（< 650ms），避免 OS 同次返回重复触发
        if (now - _edgeHandledTimeMs < 650) {
          return;
        }

        // 若是 Android 系统级侧滑返回接管了边缘滑动，根据起始触摸 X 坐标分流
        final screenW = MediaQuery.of(context).size.width;
        final isRecentEdgePointer = (now - _pointerDownTimeMs) < 1200 && _pointerDownX >= 0;

        if (isRecentEdgePointer && _pointerDownX >= screenW - 48) {
          _handleRightEdgeSwipeLeft();
          return;
        }
        if (isRecentEdgePointer && _pointerDownX <= 48) {
          _handleLeftEdgeSwipeRight();
          return;
        }

        // 常规物理/底部返回键逻辑
        if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.pop(context);
          return;
        }

        await _promptOrExitApp();
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _pointerDownX = event.position.dx;
          _pointerDownY = event.position.dy;
          _pointerDownTimeMs = DateTime.now().millisecondsSinceEpoch;
          _edgeSwipeHandled = false;
        },
        onPointerMove: (event) {
          if (_edgeSwipeHandled || _pointerDownX < 0) return;
          final screenW = MediaQuery.of(context).size.width;
          final dx = event.position.dx - _pointerDownX;
          final dy = (event.position.dy - _pointerDownY).abs();

          if (dy > 52) return;

          // 1. 左边缘向右划：第一划弹目录区，第二划提示退出
          if (_pointerDownX <= 36 && dx >= 32) {
            _edgeSwipeHandled = true;
            _edgeHandledTimeMs = DateTime.now().millisecondsSinceEpoch;
            _handleLeftEdgeSwipeRight();
          }
          // 2. 右边缘向左划：直接弹出发音人管理中心
          else if (_pointerDownX >= screenW - 36 && dx <= -32) {
            _edgeSwipeHandled = true;
            _edgeHandledTimeMs = DateTime.now().millisecondsSinceEpoch;
            _handleRightEdgeSwipeLeft();
          }
        },
        onPointerUp: (_) {
          _edgeSwipeHandled = false;
        },
        child: Focus(
          focusNode: _keyboardFocusNode,
          autofocus: true,
          onKeyEvent: (node, event) {
            if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) return KeyEventResult.ignored;
            if (event is KeyDownEvent) {
              final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
              if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyF) {
                setState(() => _ctrl.isSearching = true);
                return KeyEventResult.handled;
              } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyO) {
                _importFile();
                return KeyEventResult.handled;
              } else if (!isCtrl && event.logicalKey == LogicalKeyboardKey.space) {
                _ctrl.togglePlayPause();
                return KeyEventResult.handled;
              } else if (!isCtrl && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _ctrl.jumpSentence(-1);
                return KeyEventResult.handled;
              } else if (!isCtrl && event.logicalKey == LogicalKeyboardKey.arrowRight) {
                _ctrl.jumpSentence(1);
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: DropTarget(
            onDragDone: (details) {
              if (details.files.isNotEmpty) _openBookWithLoading(details.files.first.path);
            },
            child: Scaffold(
              key: _scaffoldKey,
              drawerEnableOpenDragGesture: true,
              drawerEdgeDragWidth: 36.0,
              drawer: Drawer(
                child: ReaderSidebar(
                  theme: theme,
                  sidebarTab: _sidebarTab,
                  isSelectionMode: _isSelectionMode,
                  selectedFingerprints: _selectedFingerprints,
                  chapters: _ctrl.alignedChapters,
                  currentIndex: _ctrl.currentIndex,
                  bookList: bookList,
                  bookmarks: _ctrl.currentBookBookmarks,
                  hasBookLoaded: _ctrl.nodes.isNotEmpty,
                  onTabChanged: (t) => setState(() {
                    _sidebarTab = t;
                    if (t == 0) {
                      _isSelectionMode = false;
                      _selectedFingerprints.clear();
                    }
                  }),
                  onToggleSelectionMode: () => setState(() {
                    _isSelectionMode = !_isSelectionMode;
                    _selectedFingerprints.clear();
                  }),
                  onChapterSelected: (pIdx) => _ctrl.seekTo(pIdx),
                  onBookSelected: (item) => _openBookWithLoading(item.lastKnownPath),
                  onBookRelink: (item) async {
                    String? newPath;
                    if (Platform.isAndroid) {
                      newPath = await StorageHelper.browseSharedStorage(
                        context,
                        chooseDirectory: false,
                        extensions: ['txt', 'epub', 'md', 'markdown'],
                        initialPath: _ctrl.lastBookDir,
                      );
                    }
                    if (newPath == null) {
                      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'epub', 'md', 'markdown']);
                      newPath = res?.files.single.path;
                    }
                    if (newPath != null) _openBookWithLoading(newPath);
                  },
                  onToggleBookSelection: (fp, selected) => setState(() {
                    if (selected) {
                      _selectedFingerprints.add(fp);
                    } else {
                      _selectedFingerprints.remove(fp);
                    }
                  }),
                  onSelectAllToggle: () => setState(() {
                    if (_selectedFingerprints.length == bookList.length) {
                      _selectedFingerprints.clear();
                    } else {
                      _selectedFingerprints.addAll(bookList.map((e) => e.fingerprint));
                    }
                  }),
                  onDeleteSelected: () {
                    for (var fp in _selectedFingerprints) {
                      _ctrl.history.remove(fp);
                    }
                    _isSelectionMode = false;
                    _selectedFingerprints.clear();
                    _ctrl.saveHistoryToPrefs(immediate: true);
                    setState(() {});
                  },
                  onExportMp3Tap: _openExportDialog,
                  onBookmarkSelected: (bm) => _ctrl.seekTo(bm.paragraphIndex),
                  onBookmarkEdit: (bm) {
                    ReaderDialogs.showEditBookmarkDialog(
                      context: context,
                      bookmark: bm,
                      onSave: (newContent, newNote) => _ctrl.updateBookmark(bm, newContent, newNote),
                    );
                  },
                  onBookmarkDelete: _ctrl.deleteBookmark,
                ),
              ),
              appBar: AppBar(
                leading: IconButton(icon: const Icon(Icons.menu), onPressed: () => _scaffoldKey.currentState?.openDrawer()),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(bookTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: theme.primaryText)),
                    if (chapSubTitle.isNotEmpty)
                      Text(chapSubTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: theme.secondaryText, fontWeight: FontWeight.normal)),
                  ],
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.search, size: 21),
                    tooltip: "全文搜索",
                    onPressed: () {
                      setState(() {
                        _ctrl.isSearching = !_ctrl.isSearching;
                        if (!_ctrl.isSearching) _ctrl.clearSearch(closeBar: true);
                      });
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_open_outlined, size: 21),
                    tooltip: "打开电子书",
                    onPressed: _importFile,
                  ),
                  PopupMenuButton<String>(
                    onSelected: (val) async {
                      switch (val) {
                        case "export_mp3":
                          _openExportDialog();
                          break;
                        case "settings":
                          _openSettingsPage();
                          break;
                        case "custom_engines":
                          await _openCustomEnginesManager();
                          break;
                        case "restore":
                          await ReaderDialogs.showRestorePicker(
                            context: context,
                            lastBackupDir: _ctrl.lastBackupDir,
                            onRestoreFile: _handleRestoreFromFile,
                          );
                          break;
                        case "network":
                          await _runConnectivityDiagnostics();
                          break;
                        case "logs":
                          ReaderDialogs.showLogViewerDialog(
                            context: context,
                            onLogLevelChanged: (newLevel) {
                              _ctrl.prefs.setString('log_level', AppLogger.normalizeLevel(newLevel));
                            },
                          );
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: "export_mp3",
                        child: Row(children: [Icon(Icons.audio_file_outlined, color: theme.accent), const SizedBox(width: 8), const Text("批量合成导出 MP3")]),
                      ),
                      const PopupMenuItem(value: "settings", child: Row(children: [Icon(Icons.settings, color: Colors.blue), SizedBox(width: 8), Text("系统、主题与网络设置")])),
                      PopupMenuItem(
                        value: "custom_engines",
                        child: Row(children: [Icon(Icons.extension, color: theme.accent), const SizedBox(width: 8), const Text("自定义 TTS 引擎管理")]),
                      ),
                      const PopupMenuItem(value: "restore", child: Row(children: [Icon(Icons.settings_backup_restore, color: Colors.deepOrange), SizedBox(width: 8), Text("从备份文件恢复")])),
                      const PopupMenuItem(value: "network", child: Row(children: [Icon(Icons.wifi_find, color: Colors.teal), SizedBox(width: 8), Text("全引擎连通性诊断")])),
                      PopupMenuItem(
                        value: "logs",
                        child: Row(children: [Icon(Icons.terminal, color: theme.accent), const SizedBox(width: 8), const Text("运行日志管理")]),
                      ),
                    ],
                  ),
                ],
              ),
              body: Stack(
                children: [
                  _ctrl.paragraphs.isEmpty
                      ? EmptyBookshelfView(
                          theme: theme,
                          bookList: bookList,
                          onImportFile: _importFile,
                          onOpenBook: _openBookWithLoading,
                          onRelinkBook: (item) async {
                            String? newPath;
                            if (Platform.isAndroid) {
                              newPath = await StorageHelper.browseSharedStorage(
                                context,
                                chooseDirectory: false,
                                extensions: ['txt', 'epub', 'md', 'markdown'],
                                initialPath: _ctrl.lastBookDir,
                              );
                            }
                            if (newPath == null) {
                              final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'epub', 'md', 'markdown']);
                              newPath = res?.files.single.path;
                            }
                            if (newPath != null) _openBookWithLoading(newPath);
                          },
                        )
                      : SelectionArea(
                          contextMenuBuilder: (context, selectableRegionState) {
                            final int targetPara = _interactedParaIdx ?? activeParaIdx;
                            final int targetSlice = _interactedSliceIdx ?? _ctrl.currentIndex;
                            final existingItems = List<ContextMenuButtonItem>.from(selectableRegionState.contextMenuButtonItems);
                            final hasSelectAll = existingItems.any((item) => item.type == ContextMenuButtonType.selectAll);

                            return AdaptiveTextSelectionToolbar.buttonItems(
                              anchors: selectableRegionState.contextMenuAnchors,
                              buttonItems: [
                                ...existingItems,
                                if (!hasSelectAll)
                                  ContextMenuButtonItem(
                                    label: '全选',
                                    onPressed: () {
                                      selectableRegionState.selectAll(SelectionChangedCause.toolbar);
                                    },
                                  ),
                                ContextMenuButtonItem(
                                  label: '📄 选择本章节',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    final chapData = _ctrl.getChapterTextForParagraph(targetPara);
                                    ReaderDialogs.showChapterTextDialog(
                                      context: this.context,
                                      title: chapData['title'] ?? '本章节',
                                      text: chapData['text'] ?? '',
                                      theme: theme,
                                    );
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '🔖 添加书签',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _ctrl.addBookmarkAtSlice(targetSlice);
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '▶ 从此朗读',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _ctrl.jumpToSliceAndPlay(targetSlice);
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '🎯 跳转到朗读位置',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _scrollToCurrentCenter(force: true);
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '⏮️ 上一章',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _ctrl.jumpToPrevChapter();
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '⏭️ 下一章',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _ctrl.jumpToNextChapter();
                                  },
                                ),
                              ],
                            );
                          },
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 820),
                              child: ScrollablePositionedList.builder(
                                itemCount: _ctrl.paragraphs.length,
                                itemScrollController: _itemScrollController,
                                itemPositionsListener: _itemPositionsListener,
                                initialScrollIndex: activeParaIdx.clamp(0, max(0, _ctrl.paragraphs.length - 1)),
                                initialAlignment: 0.30,
                                padding: EdgeInsets.symmetric(horizontal: _ctrl.horizontalPadding, vertical: 18),
                                itemBuilder: (ctx, paraIdx) {
                                  final para = _ctrl.paragraphs[paraIdx];
                                  final bool isActivePara = paraIdx == activeParaIdx;

                                  return Listener(
                                    behavior: HitTestBehavior.translucent,
                                    onPointerDown: (_) {
                                      _interactedParaIdx = paraIdx;
                                      _interactedSliceIdx = _ctrl.getSliceIndexForParagraph(paraIdx);
                                    },
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.only(left: 8, right: 4, top: 6, bottom: 10),
                                      decoration: BoxDecoration(
                                        border: isActivePara
                                            ? Border(left: BorderSide(color: theme.accent, width: 3))
                                            : const Border(left: BorderSide(color: Colors.transparent, width: 3)),
                                      ),
                                      child: _buildRichParagraph(para, paraIdx, theme),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                  if (_ctrl.isSearching)
                    Positioned(
                      top: 10,
                      right: 16,
                      child: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(22),
                        color: theme.surfaceBg,
                        child: Container(
                          width: min(360.0, MediaQuery.of(context).size.width - 32),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: theme.accent, width: 1.5),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.search, size: 18, color: theme.accent),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextField(
                                  controller: _searchCtrl,
                                  autofocus: true,
                                  style: TextStyle(fontSize: 13, color: theme.primaryText),
                                  decoration: InputDecoration(
                                    hintText: "输入关键字搜索 (支持跨句)...",
                                    hintStyle: TextStyle(fontSize: 12, color: theme.secondaryText),
                                    isDense: true,
                                    border: InputBorder.none,
                                  ),
                                  onChanged: (val) {
                                    _searchDebounce?.cancel();
                                    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
                                      if (mounted) _ctrl.executeSearch(val, showEmptyTip: false);
                                    });
                                  },
                                  onSubmitted: (q) => _ctrl.executeSearch(q, showEmptyTip: true),
                                ),
                              ),
                              if (_ctrl.isSearchBusy)
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6),
                                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                )
                              else if (_ctrl.searchHits.isNotEmpty) ...[
                                Text(
                                  "${_ctrl.currentSearchMatchIndex + 1}/${_ctrl.searchHits.length}",
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.accent),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(Icons.keyboard_arrow_up_rounded, size: 20, color: theme.primaryText),
                                  tooltip: "上一处",
                                  onPressed: () => _ctrl.navigateToMatch(_ctrl.currentSearchMatchIndex - 1),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: theme.primaryText),
                                  tooltip: "下一处",
                                  onPressed: () => _ctrl.navigateToMatch(_ctrl.currentSearchMatchIndex + 1),
                                ),
                              ] else
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(Icons.arrow_forward_rounded, size: 18, color: theme.accent),
                                  tooltip: "查找",
                                  onPressed: () => _ctrl.executeSearch(_searchCtrl.text, showEmptyTip: true),
                                ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: Icon(Icons.close, size: 18, color: theme.secondaryText),
                                onPressed: () => _ctrl.clearSearch(closeBar: true),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_showBackToCurrent && _ctrl.paragraphs.isNotEmpty)
                    Positioned(
                      bottom: 14,
                      right: 18,
                      child: FloatingActionButton.small(
                        heroTag: 'back_to_current_tts',
                        backgroundColor: theme.surfaceBg,
                        foregroundColor: theme.accent,
                        tooltip: "回到当前朗读位置",
                        onPressed: () => _scrollToCurrentCenter(force: true),
                        child: const Icon(Icons.my_location),
                      ),
                    ),
                  if (_exportController.isExporting)
                    MinimizedExportBadge(
                      theme: theme,
                      done: _exportController.done,
                      total: _exportController.total,
                      elapsedSeconds: _exportController.elapsedSeconds,
                      onTap: _openExportDialog,
                    ),
                ],
              ),
              bottomNavigationBar: WeReadPlayerBar(
                isWide: isWide,
                theme: theme,
                engineLabel: _ctrl.currentEngineLabel,
                voiceName: _ctrl.currentVoiceName,
                speechRate: _ctrl.speechRate,
                sleepTimeLeftSeconds: _ctrl.sleepTimeLeftSeconds,
                sleepStopAfterChapter: _ctrl.sleepStopAfterChapter,
                currentIndex: _ctrl.currentIndex,
                totalNodes: _ctrl.nodes.length,
                progressSubInfo: _ctrl.progressSubInfo(),
                isPlaying: _ctrl.isPlaying,
                isBuffering: _ctrl.isBuffering,
                followAlong: _ctrl.followAlong,
                networkRoute: _ctrl.activeNetworkRoute,
                onVoiceTap: _showVoiceManagerDialog,
                onSpeedTap: _ctrl.cycleSpeechRate,
                onSleepTimerTap: _showSleepTimerDialog,
                onSeek: _ctrl.seekTo,
                onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
                onPlayPause: _ctrl.togglePlayPause,
                onToggleFollowAlong: _ctrl.toggleFollowAlong,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
