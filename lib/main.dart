import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_parser.dart';
import 'dialogs.dart';
import 'models.dart';
import 'reader_widgets.dart';
import 'system_utils.dart';
import 'tts_engines.dart';

final RouteObserver<ModalRoute<void>> appRouteObserver = RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();

  FlutterError.onError = (details) {
    AppLogger.log("Flutter 未捕获异常: ${details.exceptionAsString()}", details.exception, details.stack);
  };

  final prefs = await SharedPreferences.getInstance();
  runApp(FishAudioReaderApp(prefs: prefs));
}

class FishAudioReaderApp extends StatelessWidget {
  final SharedPreferences prefs;
  const FishAudioReaderApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鱼听书',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [appRouteObserver],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2C3238), surface: const Color(0xFFFCFBF7)),
        scaffoldBackgroundColor: const Color(0xFFF6F4EC),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Color(0xFFF6F4EC),
          foregroundColor: Color(0xFF2C3238),
          titleTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2C3238)),
        ),
      ),
      home: ReaderHomeScreen(prefs: prefs),
    );
  }
}

class ReaderHomeScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const ReaderHomeScreen({super.key, required this.prefs});
  @override
  State<ReaderHomeScreen> createState() => _ReaderHomeScreenState();
}

class _ReaderHomeScreenState extends State<ReaderHomeScreen> with WidgetsBindingObserver, RouteAware {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final FocusNode _keyboardFocusNode = FocusNode();
  final ExportController _exportController = ExportController();
  final TtsNetworkRouter _networkRouter = TtsNetworkRouter();

  late FishAudioTTS _fishTts;
  String _currentEngine = "ms";
  String _apiKey = "";
  String _fishModel = fishModelOptions.first;
  Map<String, String> _userFishVoices = Map.from(defaultFishVoices);
  Map<String, String> _userMsVoices = Map.from(defaultMsVoices46);
  List<CustomTtsEngineConfig> _customEngines = [];
  List<String> _pinnedVoiceIds = [];
  String _selectedVoiceId = defaultMsVoices46.keys.first;

  double _speechRate = 1.0;
  int _bitrate = 64;
  int _timeoutSeconds = 60;
  int _preloadCount = 3;
  int _exportThreads = 6;
  int _intervalPauseMs = 200;
  int _maxCacheCount = 100;
  bool _followAlong = true;
  String _splitMode = 'sentence';
  double _fontSize = 14.0;
  int _readingBgColorValue = defaultReadingBgColorValue; // 默认羊皮纸色 #D2B48C
  int _readingHighlightColorValue = defaultReadingHighlightColorValue;

  String _lastBookDir = "";
  String _lastBackupDir = StorageHelper.getDefaultBackupDir();
  String _lastMp3Dir = "";

  Map<String, BookHistoryItem> _history = {};
  List<BookBookmark> _bookmarks = [];
  String? _currentFingerprint;
  String? _currentFilePath;
  String? _currentBookName;
  bool _isTemporaryClipboardBook = false;
  String _fullContent = "";
  int _fileSize = 0;
  List<BookChapter> _rawChapters = [];
  List<BookChapter> _alignedChapters = [];
  List<TextSliceNode> _nodes = [];
  int _currentIndex = 0;
  int _contextTargetSliceIndex = 0;

  // 播放状态机与代际去重缓存
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _pausedByInterruption = false;
  int _playSessionId = 0;
  int _cacheEpoch = 0;
  final LinkedHashMap<int, Uint8List> _audioCache = LinkedHashMap<int, Uint8List>();
  final Map<int, Future<Uint8List>> _inFlightPrefetch = {};

  StreamSubscription? _noisySub;
  StreamSubscription? _interruptionSub;
  Timer? _historyFlushTimer;
  Timer? _searchDebounce;
  Timer? _sleepTimer;
  int _sleepTimeLeftSeconds = 0;
  bool _sleepStopAfterChapter = false;

  bool _isSearching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  List<int> _searchResults = [];
  int _currentSearchMatchIndex = 0;
  String _activeSearchQuery = "";

  int _sidebarTab = 0;
  bool _isSelectionMode = false;
  final Set<String> _selectedFingerprints = {};
  int _lastBackPressTime = 0;
  bool _showBackToCurrent = false;
  bool _isTopRoute = true;
  bool _isVoiceDialogOpen = false;
  bool _isDrawerOpen = false;

  // 边缘滑动检测状态
  double? _edgeDragStartX;
  double _edgeDragAccumDx = 0;
  bool _edgeDragHandled = false;

  List<BookBookmark> get _currentBookBookmarks {
    if (_isTemporaryClipboardBook || _currentFingerprint == null) return const [];
    return _bookmarks.where((b) => b.bookFingerprint == _currentFingerprint).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettingsAndHistory();
    _initAudioSession();
    AndroidNativeBridge.registerEdgeBackListener(_handleNativeEdgeBack);
    _exportController.addListener(() {
      if (mounted) setState(() {});
    });
    _itemPositionsListener.itemPositions.addListener(_onViewportPositionsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAndroidEdgeGestureConfig());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
    _syncAndroidEdgeGestureConfig();
  }

  @override
  void didPushNext() {
    _isTopRoute = false;
    _syncAndroidEdgeGestureConfig();
  }

  @override
  void didPopNext() {
    _isTopRoute = true;
    _syncAndroidEdgeGestureConfig();
  }

  void _syncAndroidEdgeGestureConfig() {
    if (!Platform.isAndroid || !mounted) return;
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return;
    AndroidNativeBridge.updateEdgeGestureConfig(
      interceptHomeBack: _isTopRoute,
      excludeEdges: _isTopRoute,
      screenWidthDp: mq.size.width,
      screenHeightDp: mq.size.height,
      devicePixelRatio: mq.devicePixelRatio,
    );
  }

  void _onViewportPositionsChanged() {
    if (_nodes.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final visible = positions.any((p) => p.index == _currentIndex);
    if (_showBackToCurrent == visible && mounted) {
      setState(() => _showBackToCurrent = !visible);
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _itemPositionsListener.itemPositions.removeListener(_onViewportPositionsChanged);
    _noisySub?.cancel();
    _interruptionSub?.cancel();
    _historyFlushTimer?.cancel();
    _searchDebounce?.cancel();
    _sleepTimer?.cancel();
    _exportController.dispose();
    _saveHistoryToPrefs(immediate: true);
    _networkRouter.dispose();
    _audioPlayer.dispose();
    _keyboardFocusNode.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _networkRouter.refreshSystemProxy();
      _syncAndroidEdgeGestureConfig();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _saveHistoryToPrefs(immediate: true);
      _saveSettings();
    }
  }

  Future<void> _initAudioSession() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        if (_isPlaying) {
          AppLogger.log("检测到耳机拔出或音频输出切换，自动暂停朗读", null, null, true);
          _stopTTS();
        }
      });
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          if (_isPlaying) {
            _pausedByInterruption = true;
            _stopTTS();
          }
        } else if (event.type == AudioInterruptionType.pause && _pausedByInterruption) {
          _pausedByInterruption = false;
          _startTTS();
        }
      });
    }
  }

  void _loadSettingsAndHistory() {
    final prefs = widget.prefs;
    _currentEngine = prefs.getString('engineType') ?? 'ms';
    _apiKey = prefs.getString('fishApiKey') ?? '';
    _fishModel = prefs.getString('fishModel') ?? fishModelOptions.first;
    if (!fishModelOptions.contains(_fishModel)) _fishModel = fishModelOptions.first;

    _speechRate = (prefs.getDouble('speechRate') ?? 1.0).clamp(0.5, 2.5);
    _bitrate = prefs.getInt('bitrate') == 128 ? 128 : 64;
    _timeoutSeconds = (prefs.getInt('timeoutSeconds') ?? 60).clamp(20, 120);
    _preloadCount = (prefs.getInt('preloadCount') ?? 3).clamp(1, 15);
    _exportThreads = (prefs.getInt('exportThreads') ?? 6).clamp(1, 16);
    _intervalPauseMs = (prefs.getInt('intervalPauseMs') ?? 200).clamp(0, 1500);
    _maxCacheCount = (prefs.getInt('maxCacheCount') ?? 100).clamp(50, 300);
    _followAlong = prefs.getBool('followAlong') ?? true;
    _splitMode = prefs.getString('splitMode') ?? 'sentence';
    _fontSize = (prefs.getDouble('font_size_v2') ?? 14.0).clamp(10.0, 20.0);
    _readingBgColorValue = prefs.getInt('reading_bg_color_v1') ?? defaultReadingBgColorValue;
    _readingHighlightColorValue = prefs.getInt('reading_highlight_color_v1') ?? defaultReadingHighlightColorValue;
    AppLogger.logLevel = AppLogger.normalizeLevel(prefs.getString('log_level'));

    final rawRoutes = prefs.getString('engine_network_modes');
    if (rawRoutes != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawRoutes);
        decoded.forEach((k, v) => _networkRouter.setEngineNetwork(k, v.toString()));
      } catch (_) {}
    }
    final rawProxies = prefs.getString('engine_custom_proxies');
    if (rawProxies != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawProxies);
        decoded.forEach((k, v) {
          _networkRouter.setEngineNetwork(k, _networkRouter.getEngineRoute(k), v.toString());
        });
      } catch (_) {}
    }

    final rawCustom = prefs.getString('custom_tts_engines_v1');
    if (rawCustom != null) {
      try {
        final List decoded = jsonDecode(rawCustom);
        _customEngines = decoded.map((e) => CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (_) {}
    }

    final rawFish = prefs.getString('custom_user_fish_voices');
    if (rawFish != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawFish);
        if (decoded.isNotEmpty) _userFishVoices = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    final rawMs = prefs.getString('custom_user_ms_voices');
    if (rawMs != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawMs);
        if (decoded.isNotEmpty) _userMsVoices = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    _pinnedVoiceIds = prefs.getStringList('pinned_voice_ids') ?? [];

    _selectedVoiceId = prefs.getString('selectedVoice') ?? _defaultVoiceForEngine(_currentEngine);
    _ensureValidSelectedEngineAndVoice();

    final rawBookmarks = prefs.getString('user_bookmarks_v1');
    if (rawBookmarks != null) {
      try {
        final List decoded = jsonDecode(rawBookmarks);
        _bookmarks = decoded.map((e) => BookBookmark.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (_) {}
    }

    _lastBookDir = prefs.getString('last_book_dir') ?? "";
    _lastBackupDir = prefs.getString('last_backup_dir') ?? StorageHelper.getDefaultBackupDir();
    _lastMp3Dir = prefs.getString('last_mp3_dir') ?? "$_lastBackupDir${Platform.pathSeparator}MP3";

    final rawHistory = prefs.getString('history_librera_v4') ?? '{}';
    try {
      final decoded = jsonDecode(rawHistory);
      if (decoded is Map) {
        _history = decoded.map((k, v) => MapEntry(k.toString(), BookHistoryItem.fromJson(Map<String, dynamic>.from(v as Map))));
      }
    } catch (_) {
      _history = {};
    }

    _networkRouter.refreshSystemProxy();
    _fishTts = FishAudioTTS(apiKey: _apiKey, voices: _userFishVoices, model: _fishModel);
  }

  String _defaultVoiceForEngine(String engId) {
    if (engId == 'ms') return _userMsVoices.keys.first;
    if (engId == 'fish') return _userFishVoices.keys.first;
    for (final c in _customEngines) {
      if (c.id == engId && c.voices.isNotEmpty) return c.voices.keys.first;
    }
    return _userMsVoices.keys.first;
  }

  Map<String, String> _voicesForEngine(String engId) {
    if (engId == 'ms') return _userMsVoices;
    if (engId == 'fish') return _userFishVoices;
    for (final c in _customEngines) {
      if (c.id == engId) return c.voices;
    }
    return _userMsVoices;
  }

  void _ensureValidSelectedEngineAndVoice() {
    if (_currentEngine != 'ms' && _currentEngine != 'fish' && !_customEngines.any((c) => c.id == _currentEngine)) {
      _currentEngine = 'ms';
    }
    final vMap = _voicesForEngine(_currentEngine);
    if (!vMap.containsKey(_selectedVoiceId)) {
      _selectedVoiceId = vMap.keys.first;
    }
  }

  Future<void> _saveSettings() async {
    final prefs = widget.prefs;
    await prefs.setString('engineType', _currentEngine);
    await prefs.setString('fishApiKey', _apiKey);
    await prefs.setString('fishModel', _fishModel);
    await prefs.setString('selectedVoice', _selectedVoiceId);
    await prefs.setDouble('speechRate', _speechRate);
    await prefs.setInt('bitrate', _bitrate);
    await prefs.setInt('timeoutSeconds', _timeoutSeconds);
    await prefs.setInt('preloadCount', _preloadCount);
    await prefs.setInt('exportThreads', _exportThreads);
    await prefs.setInt('intervalPauseMs', _intervalPauseMs);
    await prefs.setInt('maxCacheCount', _maxCacheCount);
    await prefs.setString('engine_network_modes', jsonEncode(_networkRouter.engineNetworkModes));
    await prefs.setString('engine_custom_proxies', jsonEncode(_networkRouter.engineCustomProxies));
    await prefs.setString('custom_tts_engines_v1', jsonEncode(_customEngines.map((e) => e.toJson()).toList()));
    await prefs.setBool('followAlong', _followAlong);
    await prefs.setString('splitMode', _splitMode);
    await prefs.setDouble('font_size_v2', _fontSize);
    await prefs.setInt('reading_bg_color_v1', _readingBgColorValue);
    await prefs.setInt('reading_highlight_color_v1', _readingHighlightColorValue);
    await prefs.setString('log_level', AppLogger.logLevel);

    await prefs.setString('custom_user_fish_voices', jsonEncode(_userFishVoices));
    await prefs.setString('custom_user_ms_voices', jsonEncode(_userMsVoices));
    await prefs.setStringList('pinned_voice_ids', _pinnedVoiceIds);
    await prefs.setString('user_bookmarks_v1', jsonEncode(_bookmarks.map((e) => e.toJson()).toList()));

    await prefs.setString('last_book_dir', _lastBookDir);
    await prefs.setString('last_backup_dir', _lastBackupDir);
    await prefs.setString('last_mp3_dir', _lastMp3Dir);
  }

  Future<void> _saveHistoryToPrefs({bool immediate = false}) async {
    // 临时剪贴板导入文本绝不进入历史记录
    if (!_isTemporaryClipboardBook && _currentFingerprint != null && _currentFilePath != null && _nodes.isNotEmpty) {
      final validIdx = _currentIndex.clamp(0, _nodes.length - 1);
      final node = _nodes[validIdx];
      final snippet = node.text.length > 30 ? node.text.substring(0, 30) : node.text;

      _history[_currentFingerprint!] = BookHistoryItem(
        fingerprint: _currentFingerprint!,
        lastKnownPath: _currentFilePath!,
        bookName: _currentBookName ?? _currentFilePath!.split(Platform.pathSeparator).last,
        lastIndex: validIdx,
        charOffset: node.startOffset,
        textSnippet: snippet,
        percentage: (node.startOffset / max(1, _fullContent.length)).clamp(0.0, 1.0),
        splitMode: _splitMode,
        lastReadTime: DateTime.now().millisecondsSinceEpoch,
        fileSize: _fileSize,
      );
    }

    if (immediate) {
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      await widget.prefs.setString('history_librera_v4', jsonEncode(_history.map((k, v) => MapEntry(k, v.toJson()))));
    } else {
      _historyFlushTimer ??= Timer(const Duration(seconds: 8), () async {
        _historyFlushTimer = null;
        await widget.prefs.setString('history_librera_v4', jsonEncode(_history.map((k, v) => MapEntry(k, v.toJson()))));
      });
    }
  }

  void _invalidateAudioCache() {
    _cacheEpoch++;
    _audioCache.clear();
    _inFlightPrefetch.clear();
  }

  void _putAudioCache(int index, Uint8List bytes) {
    _audioCache.remove(index);
    _audioCache[index] = bytes;
    while (_audioCache.length > _maxCacheCount) {
      _audioCache.remove(_audioCache.keys.first);
    }
  }

  String _currentChapterTitle() {
    if (_alignedChapters.isEmpty || _nodes.isEmpty) return "";
    for (int i = _alignedChapters.length - 1; i >= 0; i--) {
      if (_alignedChapters[i].paragraphIndex <= _currentIndex) {
        return _alignedChapters[i].title;
      }
    }
    return "";
  }

  void _addBookmarkAt(int paragraphIndex) {
    if (_isTemporaryClipboardBook) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("临时剪贴板文本不支持保存书签"), duration: Duration(seconds: 2)),
      );
      return;
    }
    if (_nodes.isEmpty || paragraphIndex < 0 || paragraphIndex >= _nodes.length || _currentFingerprint == null) return;

    final node = _nodes[paragraphIndex];
    String snippet = node.text.trim();
    if (snippet.length > 60) snippet = "${snippet.substring(0, 60)}...";

    String chapTitle = "正文片段";
    for (int i = _alignedChapters.length - 1; i >= 0; i--) {
      if (_alignedChapters[i].paragraphIndex <= paragraphIndex) {
        chapTitle = _alignedChapters[i].title;
        break;
      }
    }

    final newBookmark = BookBookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookFingerprint: _currentFingerprint!,
      paragraphIndex: paragraphIndex,
      charOffset: node.startOffset,
      chapterTitle: chapTitle,
      content: snippet,
      createTime: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() => _bookmarks.insert(0, newBookmark));
    _saveSettings();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("🔖 已在「$chapTitle」标定书签"),
        duration: const Duration(seconds: 2),
        action: SnackBarAction(
          label: "查看书签",
          textColor: Colors.amber,
          onPressed: () {
            setState(() => _sidebarTab = 2);
            _scaffoldKey.currentState?.openDrawer();
          },
        ),
      ),
    );
  }

  // ────────── 剪贴板写入与复制本章节 / 复制全文（防卡死，不弹窗） ──────────
  Future<void> _copyToClipboardSafely(String text, String successMsg) async {
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("没有可复制的文本内容")));
      }
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMsg), duration: const Duration(seconds: 2)),
        );
      }
    } catch (e) {
      AppLogger.log("写入系统剪贴板失败", e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("复制失败：文本过大超出系统剪贴板单次上限，建议改用「复制本章节」")),
        );
      }
    }
  }

  Future<void> _copyChapterAt(int targetSliceIdx) async {
    if (_fullContent.isEmpty || _nodes.isEmpty) return;
    if (_alignedChapters.isEmpty) {
      await _copyToClipboardSafely(_fullContent.trim(), "当前文本无章节目录，已复制全部内容（共 ${_fullContent.trim().length} 字）");
      return;
    }

    final safeIdx = targetSliceIdx.clamp(0, _nodes.length - 1);
    int chapIdx = 0;
    for (int i = _alignedChapters.length - 1; i >= 0; i--) {
      if (_alignedChapters[i].paragraphIndex <= safeIdx) {
        chapIdx = i;
        break;
      }
    }

    final startOffset = _alignedChapters[chapIdx].charOffset.clamp(0, _fullContent.length);
    final endOffset = (chapIdx + 1 < _alignedChapters.length)
        ? _alignedChapters[chapIdx + 1].charOffset.clamp(startOffset, _fullContent.length)
        : _fullContent.length;
    final chapterText = _fullContent.substring(startOffset, endOffset).trim();

    await _copyToClipboardSafely(
      chapterText,
      "已复制「${_alignedChapters[chapIdx].title}」（共 ${chapterText.length} 字）",
    );
  }

  Future<void> _copyFullText() async {
    final full = _fullContent.trim();
    await _copyToClipboardSafely(full, "已复制全文（共 ${full.length} 字）");
  }

  // ────────── 剪贴板导入（临时文本，不写历史、不进备份、退出清除） ──────────
  Future<void> _importFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final rawText = data?.text ?? "";
      if (rawText.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("剪贴板暂无可导入的文本内容")));
        }
        return;
      }

      await _stopTTS();
      await _saveHistoryToPrefs(immediate: true);

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: Card(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))),
      );

      final res = await BookParser.parseRawTextInIsolate(rawText, _splitMode);
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);

      final String full = res['fullContent'] as String;
      final List<BookChapter> rawChapters = res['rawChapters'] as List<BookChapter>;
      final List<BookChapter> aligned = res['alignedChapters'] as List<BookChapter>;
      final List<TextSliceNode> nodes = res['nodes'] as List<TextSliceNode>;

      if (nodes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("剪贴板内容无可朗读文字")));
        }
        return;
      }

      AppLogger.log("剪贴板临时文本导入成功 [切片: ${nodes.length}, 章节: ${rawChapters.length}]", null, null, true);

      if (!mounted) return;
      setState(() {
        _isTemporaryClipboardBook = true;
        _currentFingerprint = null;
        _currentFilePath = null;
        _currentBookName = "📋 剪贴板临时阅读";
        _fullContent = full;
        _fileSize = utf8.encode(rawText).length;
        _rawChapters = rawChapters;
        _alignedChapters = aligned;
        _nodes = nodes;
        _currentIndex = 0;
        _contextTargetSliceIndex = 0;
        _invalidateAudioCache();
        _searchResults.clear();
        _activeSearchQuery = "";
        _showBackToCurrent = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentCenter(immediate: true, force: true));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("已导入剪贴板文本（共 ${nodes.length} 朗读单元 · 退出后自动清除）")),
        );
      }
    } catch (e, stack) {
      AppLogger.log("剪贴板导入失败", e, stack);
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("剪贴板导入失败: $e")));
    }
  }

  Future<void> _switchSplitMode(String newMode) async {
    if (_splitMode == newMode || _fullContent.isEmpty) return;

    int currentAnchorOffset = 0;
    if (_nodes.isNotEmpty && _currentIndex < _nodes.length) {
      currentAnchorOffset = _nodes[_currentIndex].startOffset;
    }

    _splitMode = newMode;
    final res = await BookParser.resliceInIsolate(_fullContent, _rawChapters, _splitMode, 0);
    final List<TextSliceNode> newNodes = res['nodes'];
    final List<BookChapter> aligned = res['alignedChapters'];
    final int newIndex = BookParser.findIndexByCharOffset(newNodes, currentAnchorOffset);

    AppLogger.log("切换断句规则: $newMode [锚点: $currentAnchorOffset -> 新项: #$newIndex/${newNodes.length}]", null, null, true);

    if (!mounted) return;
    setState(() {
      _nodes = newNodes;
      _alignedChapters = aligned;
      _currentIndex = newIndex;
      _invalidateAudioCache();
    });

    await _saveSettings();
    await _saveHistoryToPrefs(immediate: true);
    _scrollToCurrentCenter(immediate: true);
    if (_isPlaying) _startTTS();
  }

  Future<void> _openBook(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('文件不存在或无法访问：\n$path')));
      return;
    }

    _lastBookDir = file.parent.path;
    _saveSettings();
    await _stopTTS();
    await _saveHistoryToPrefs(immediate: true);

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: Card(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))),
    );

    try {
      String? cacheDir;
      try {
        cacheDir = (await getTemporaryDirectory()).path;
      } catch (_) {}
      final res = await BookParser.openBookInIsolate(path, _splitMode, 0, cacheDir);
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);

      final String fp = res['fingerprint'];
      final String full = res['fullContent'];
      final List<BookChapter> rawChapters = res['rawChapters'];
      final List<BookChapter> aligned = res['alignedChapters'];
      final List<TextSliceNode> nodes = res['nodes'];
      final int size = res['fileSize'];
      final String name = path.split(Platform.pathSeparator).last;

      int startIdx = 0;
      if (_history.containsKey(fp)) {
        final saved = _history[fp]!;
        saved.lastKnownPath = path;
        startIdx = BookParser.findIndexByCharOffset(nodes, saved.charOffset);
      }

      AppLogger.log("电子书装载成功: $name [大小: ${formatFileSize(size)}, 章节: ${rawChapters.length}, 切片: ${nodes.length}, 断点: #$startIdx]", null, null, true);

      if (!mounted) return;
      setState(() {
        _isTemporaryClipboardBook = false;
        _currentFingerprint = fp;
        _currentFilePath = path;
        _currentBookName = name;
        _fullContent = full;
        _fileSize = size;
        _rawChapters = rawChapters;
        _alignedChapters = aligned;
        _nodes = nodes;
        _currentIndex = startIdx;
        _contextTargetSliceIndex = startIdx;
        _invalidateAudioCache();
        _searchResults.clear();
        _activeSearchQuery = "";
        _showBackToCurrent = false;
      });

      await _saveHistoryToPrefs(immediate: true);
      if (_followAlong) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentCenter(immediate: true));
      }
    } catch (e, stack) {
      AppLogger.log("解析电子书失败: $path", e, stack);
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开文件失败: $e')));
    }
  }

  Future<void> _importFile() async {
    String? path;
    if (Platform.isAndroid) {
      path = await StorageHelper.browseSharedStorage(
        context,
        chooseDirectory: false,
        extensions: ['txt', 'epub', 'md', 'markdown'],
        initialPath: _lastBookDir.isNotEmpty ? _lastBookDir : null,
      );
    } else {
      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'epub', 'md']);
      path = res?.files.single.path;
    }
    if (path != null) await _openBook(path);
  }

  void _scrollToCurrentCenter({bool immediate = false, bool force = false}) {
    if (!force && !_followAlong) return;
    if (!_itemScrollController.isAttached || _nodes.isEmpty) return;
    if (immediate) {
      _itemScrollController.jumpTo(index: _currentIndex, alignment: 0.32);
    } else {
      _itemScrollController.scrollTo(
        index: _currentIndex,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.32,
      );
    }
    if (mounted && _showBackToCurrent) {
      setState(() => _showBackToCurrent = false);
    }
  }

  Future<Uint8List> _synthesize(String text) {
    return synthesizeWithEngine(
      engineId: _currentEngine,
      text: text,
      voiceId: _selectedVoiceId,
      speed: _speechRate,
      bitrate: _bitrate,
      timeoutSeconds: _timeoutSeconds,
      fishTts: _fishTts,
      customEngines: _customEngines,
      networkRouter: _networkRouter,
    );
  }

  void _schedulePrefetchFrom(int startIndex, int epoch) {
    for (int i = 1; i <= _preloadCount; i++) {
      final target = startIndex + i;
      if (target >= _nodes.length) break;
      if (_audioCache.containsKey(target) || _inFlightPrefetch.containsKey(target)) continue;

      final future = _synthesize(_nodes[target].text);
      _inFlightPrefetch[target] = future;
      future.then((bytes) {
        _inFlightPrefetch.remove(target);
        if (epoch == _cacheEpoch) {
          _putAudioCache(target, bytes);
          AppLogger.log("预读入池 [#$target, 缓存: ${_audioCache.length}/$_maxCacheCount]");
        }
      }).catchError((_) {
        _inFlightPrefetch.remove(target);
      });
    }
  }

  void _startTTS() {
    if (_nodes.isEmpty) return;
    _playSessionId++;
    AppLogger.log("朗读启动 [会话: #$_playSessionId, 项: #$_currentIndex, 引擎: $_currentEngine, 音色: $_selectedVoiceId, 语速: ${_speechRate}x]", null, null, true);
    setState(() {
      _isPlaying = true;
      _isBuffering = true;
      _pausedByInterruption = false;
    });
    _runTTSLoop(_playSessionId);
  }

  Future<void> _stopTTS() async {
    _playSessionId++;
    AppLogger.log("朗读停止 [会话: #$_playSessionId]", null, null, true);
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isBuffering = false;
      });
    }
    await _audioPlayer.stop();
    await _saveHistoryToPrefs(immediate: true);
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _stopTTS();
    } else {
      _startTTS();
    }
  }

  Future<void> _waitPlayerCompletedOrCancelled(int myId) async {
    final completer = Completer<void>();
    late StreamSubscription<PlayerState> sub;
    Timer? checkTimer;

    void done() {
      if (!completer.isCompleted) {
        sub.cancel();
        checkTimer?.cancel();
        completer.complete();
      }
    }

    sub = _audioPlayer.playerStateStream.listen(
      (st) {
        if (st.processingState == ProcessingState.completed || myId != _playSessionId) {
          done();
        }
      },
      onError: (_) => done(),
    );

    checkTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (myId != _playSessionId) done();
    });

    return completer.future;
  }

  Future<void> _runTTSLoop(int myId) async {
    while (myId == _playSessionId && _currentIndex < _nodes.length) {
      if (_sleepStopAfterChapter && _alignedChapters.isNotEmpty) {
        for (var c in _alignedChapters) {
          if (c.paragraphIndex == _currentIndex && _currentIndex != 0) {
            AppLogger.log("已达章节末尾，触发章节定时停止: ${c.title}", null, null, true);
            await _stopTTS();
            if (mounted) {
              setState(() => _sleepStopAfterChapter = false);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已达章节末尾，定时停止播放')));
            }
            return;
          }
        }
      }

      if (_followAlong) _scrollToCurrentCenter();

      final int epochAtStart = _cacheEpoch;
      Uint8List? audioBytes = _audioCache.remove(_currentIndex);

      if (audioBytes == null) {
        if (mounted && !_isBuffering) setState(() => _isBuffering = true);
        try {
          final inFlight = _inFlightPrefetch[_currentIndex];
          if (inFlight != null) {
            audioBytes = await inFlight;
          } else {
            audioBytes = await _synthesize(_nodes[_currentIndex].text);
          }
        } catch (e) {
          if (myId == _playSessionId && mounted) {
            AppLogger.log("合成中断异常 [#$_currentIndex]", e);
            await _stopTTS();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('合成中断: $e')));
          }
          break;
        }
      }

      if (myId != _playSessionId) break;
      if (epochAtStart != _cacheEpoch) continue;

      _schedulePrefetchFrom(_currentIndex, _cacheEpoch);

      if (mounted && _isBuffering) setState(() => _isBuffering = false);

      try {
        await _audioPlayer.stop();
        await _audioPlayer.setAudioSource(MemoryAudioSource(audioBytes));
        await _audioPlayer.play();
      } catch (_) {
        try {
          final tempDir = await getTemporaryDirectory();
          final bufferFile = File("${tempDir.path}${Platform.pathSeparator}single_play_buffer_${_currentIndex % 2}.mp3");
          await bufferFile.writeAsBytes(audioBytes, flush: true);
          await _audioPlayer.setFilePath(bufferFile.path);
          await _audioPlayer.play();
        } catch (fileErr) {
          AppLogger.log("音频播放驱动失败", fileErr);
          if (myId == _playSessionId) await _stopTTS();
          break;
        }
      }

      if (myId != _playSessionId) break;
      await _waitPlayerCompletedOrCancelled(myId);
      if (myId != _playSessionId) break;

      if (_currentIndex + 1 >= _nodes.length) {
        AppLogger.log("全书朗读完毕", null, null, true);
        await _stopTTS();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🎉 已读完全书')));
        break;
      }

      if (mounted) setState(() => _currentIndex++);
      _saveHistoryToPrefs();

      if (_intervalPauseMs > 0) {
        await Future.delayed(Duration(milliseconds: _intervalPauseMs));
      }
    }
  }

  void _jumpSentence(int step) {
    final int target = _currentIndex + step;
    if (target >= 0 && target < _nodes.length) {
      AppLogger.log("手动跳句 [#$_currentIndex -> #$target]");
      setState(() => _currentIndex = target);
      _saveHistoryToPrefs();
      if (_followAlong) _scrollToCurrentCenter();
      if (_isPlaying) _startTTS();
    }
  }

  void _executeSearch(String q, {bool showEmptyTip = true}) {
    final text = q.trim().toLowerCase();
    if (text.isEmpty) {
      setState(() {
        _activeSearchQuery = "";
        _searchResults.clear();
        _currentSearchMatchIndex = 0;
      });
      return;
    }
    final List<int> matches = [];
    for (int i = 0; i < _nodes.length; i++) {
      if (_nodes[i].text.toLowerCase().contains(text)) {
        matches.add(i);
      }
    }
    setState(() {
      _activeSearchQuery = text;
      _searchResults = matches;
      _currentSearchMatchIndex = 0;
    });

    if (matches.isNotEmpty) {
      _navigateToMatch(0);
    } else if (showEmptyTip) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("未找到匹配文本"), duration: Duration(milliseconds: 1200)));
    }
  }

  void _navigateToMatch(int targetMatchIndex) {
    if (_searchResults.isEmpty) return;
    int validMatchIndex = targetMatchIndex % _searchResults.length;
    if (validMatchIndex < 0) validMatchIndex += _searchResults.length;

    setState(() {
      _currentSearchMatchIndex = validMatchIndex;
      _currentIndex = _searchResults[validMatchIndex];
    });

    _scrollToCurrentCenter(force: true);
    _saveHistoryToPrefs();
  }

  Widget _buildHighlightedParagraph(String text, TextStyle baseStyle) {
    if (!_isSearching || _activeSearchQuery.isEmpty) {
      return Text(text, style: baseStyle);
    }
    final lower = text.toLowerCase();
    final qLen = _activeSearchQuery.length;
    if (!lower.contains(_activeSearchQuery)) {
      return Text(text, style: baseStyle);
    }

    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = lower.indexOf(_activeSearchQuery, start);
      if (idx == -1) {
        if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + qLen),
        style: TextStyle(backgroundColor: Colors.amber.shade300, color: const Color(0xFF4A2500), fontWeight: FontWeight.bold),
      ));
      start = idx + qLen;
    }
    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  // ────────── 手机端左右边缘手势与 3 步退出状态机 ──────────
  Future<void> _exitApplication() async {
    await _saveHistoryToPrefs(immediate: true);
    await _saveSettings();
    SystemNavigator.pop();
  }

  void _handleRightEdgeSwipeAction() {
    if (!_isTopRoute || _isVoiceDialogOpen) return;
    _showVoiceManagerDialog();
  }

  Future<void> _handleLeftEdgeSwipeAction() async {
    if (!_isTopRoute) return;

    if (_isSearching) {
      setState(() {
        _isSearching = false;
        _activeSearchQuery = "";
        _searchResults.clear();
      });
      return;
    }
    if (_isSelectionMode) {
      setState(() {
        _isSelectionMode = false;
        _selectedFingerprints.clear();
      });
      return;
    }

    final drawerCurrentlyOpen = _isDrawerOpen || (_scaffoldKey.currentState?.isDrawerOpen ?? false);
    if (!drawerCurrentlyOpen) {
      // 第 1 划：弹出大纲页
      _lastBackPressTime = 0;
      setState(() => _sidebarTab = 0);
      _scaffoldKey.currentState?.openDrawer();
      return;
    }

    // 第 2 划（大纲页已展开，保持大纲不关闭并提示退出） & 第 3 划（真正退出）
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBackPressTime > 2500) {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('再划一次退出鱼听书'), duration: Duration(milliseconds: 1800)),
      );
      return;
    }

    await _exitApplication();
  }

  void _handleNativeEdgeBack(String edge) {
    if (!mounted || !_isTopRoute) return;
    if (edge == 'right') {
      _handleRightEdgeSwipeAction();
    } else {
      _handleLeftEdgeSwipeAction();
    }
  }

  // ────────── 容错类型解析工具 ──────────
  int _parseInt(dynamic val, int fallback) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val.trim()) ?? double.tryParse(val.trim())?.toInt() ?? fallback;
    return fallback;
  }

  double _parseDouble(dynamic val, double fallback) {
    if (val is double) return val;
    if (val is num) return val.toDouble();
    if (val is String) return double.tryParse(val.trim()) ?? fallback;
    return fallback;
  }

  bool _parseBool(dynamic val, bool fallback) {
    if (val is bool) return val;
    if (val is String) {
      final l = val.trim().toLowerCase();
      if (l == 'true' || l == '1') return true;
      if (l == 'false' || l == '0') return false;
    }
    if (val is num) return val != 0;
    return fallback;
  }

  Map<String, String> _parseStringMap(dynamic raw) {
    final result = <String, String>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k != null && v != null) {
          result[k.toString()] = v.toString();
        }
      });
    }
    return result;
  }

  // ────────── 完整备份导出 ──────────
  Future<void> _exportBackup() async {
    try {
      if (!await StorageHelper.checkAndRequestManagePermission()) return;
      final targetFolder = Directory(_lastBackupDir);
      if (!await targetFolder.exists()) await targetFolder.create(recursive: true);

      final dateStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File('${targetFolder.path}${Platform.pathSeparator}fish_reader_backup_$dateStr.json');

      final data = {
        'version': 9,
        'engineType': _currentEngine,
        'fishApiKey': _apiKey,
        'fishModel': _fishModel,
        'selectedVoice': _selectedVoiceId,
        'speechRate': _speechRate,
        'bitrate': _bitrate,
        'timeoutSeconds': _timeoutSeconds,
        'preloadCount': _preloadCount,
        'exportThreads': _exportThreads,
        'intervalPauseMs': _intervalPauseMs,
        'maxCacheCount': _maxCacheCount,
        'engineNetworkModes': _networkRouter.engineNetworkModes,
        'engineCustomProxies': _networkRouter.engineCustomProxies,
        'customEngines': _customEngines.map((e) => e.toJson()).toList(),
        'followAlong': _followAlong,
        'splitMode': _splitMode,
        'font_size_v2': _fontSize,
        'reading_bg_color_v1': _readingBgColorValue,
        'reading_highlight_color_v1': _readingHighlightColorValue,
        'log_level': AppLogger.logLevel,
        'lastBookDir': _lastBookDir,
        'lastBackupDir': _lastBackupDir,
        'lastMp3Dir': _lastMp3Dir,
        'fishVoices': _userFishVoices,
        'msVoices': _userMsVoices,
        'pinnedVoices': _pinnedVoiceIds,
        'bookmarks': _bookmarks.map((e) => e.toJson()).toList(),
        'history': _history.map((k, v) => MapEntry(k, v.toJson())),
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);

      AppLogger.log("全量备份落盘成功: ${file.path} [APIKey:${_apiKey.isNotEmpty}, 预读:$_preloadCount, 书架:${_history.length}]", null, null, true);
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('备份导出成功'),
            content: Text('全量配置、自定义引擎、网络策略、阅读配色、书架与书签已成功写入：\n\n${file.path}'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
          ),
        );
      }
    } catch (e, stack) {
      AppLogger.log("导出备份失败", e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出备份失败: $e')));
    }
  }

  // ────────── 完整备份恢复 ──────────
  Future<bool> _restoreBackupFromFile(String path) async {
    try {
      await StorageHelper.checkAndRequestManagePermission();
      final file = File(path);
      if (!await file.exists()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('备份文件不存在: $path')));
        return false;
      }

      final parentPath = file.parent.path;
      if (!parentPath.contains('/cache/') && !parentPath.contains('file_picker')) {
        _lastBackupDir = parentPath;
      }

      final rawJson = await file.readAsString();
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无效的备份文件格式')));
        return false;
      }
      final data = Map<String, dynamic>.from(decoded);
      final String prevSplitMode = _splitMode;

      final restoredFishVoices = _parseStringMap(data['fishVoices'] ?? data['custom_user_fish_voices']);
      final restoredMsVoices = _parseStringMap(data['msVoices'] ?? data['custom_user_ms_voices']);

      final List<CustomTtsEngineConfig> restoredCustomEngines = [];
      final rawCustom = data['customEngines'] ?? data['custom_tts_engines_v1'];
      if (rawCustom is List) {
        for (final item in rawCustom) {
          if (item is Map) {
            restoredCustomEngines.add(CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      final String restoredEngine = (data['engineType'] ?? _currentEngine).toString();
      final String restoredApiKey = (data['fishApiKey'] ?? data['apiKey'] ?? data['fish_api_key'] ?? _apiKey).toString().trim();
      final String rawFishModel = (data['fishModel'] ?? _fishModel).toString();
      final String restoredFishModel = fishModelOptions.contains(rawFishModel) ? rawFishModel : fishModelOptions.first;
      final String restoredVoice = (data['selectedVoice'] ?? _selectedVoiceId).toString();

      final double restoredRate = _parseDouble(data['speechRate'], _speechRate).clamp(0.5, 2.5);
      final int restoredBitrate = _parseInt(data['bitrate'], _bitrate) == 128 ? 128 : 64;
      final int restoredTimeout = _parseInt(data['timeoutSeconds'], _timeoutSeconds).clamp(20, 120);
      final int restoredPreload = _parseInt(data['preloadCount'] ?? data['preload_count'], _preloadCount).clamp(1, 15);
      final int restoredThreads = _parseInt(data['exportThreads'] ?? data['export_threads'], _exportThreads).clamp(1, 16);
      final int restoredInterval = _parseInt(data['intervalPauseMs'], _intervalPauseMs).clamp(0, 1500);
      final int restoredMaxCache = _parseInt(data['maxCacheCount'], _maxCacheCount).clamp(50, 300);
      final bool restoredFollow = _parseBool(data['followAlong'], _followAlong);
      final String restoredSplit = (data['splitMode'] ?? _splitMode).toString() == 'paragraph' ? 'paragraph' : 'sentence';
      final double restoredFont = _parseDouble(data['font_size_v2'] ?? data['font_size'] ?? data['fontSize'], _fontSize).clamp(10.0, 20.0);
      final int restoredBgColor = _parseInt(data['reading_bg_color_v1'], _readingBgColorValue);
      final int restoredHlColor = _parseInt(data['reading_highlight_color_v1'], _readingHighlightColorValue);
      final String restoredLogLevel = AppLogger.normalizeLevel((data['log_level'] ?? data['logLevel'])?.toString());

      final Map<String, String> restoredRoutes = {'ms': 'direct', 'fish': 'direct'};
      final Map<String, String> restoredProxies = {};

      final rawNetModes = data['engineNetworkModes'] ?? data['engine_network_modes'];
      if (rawNetModes is Map) {
        rawNetModes.forEach((k, v) {
          restoredRoutes[k.toString()] = normalizeEngineNetworkMode(v?.toString());
        });
      } else if (data.containsKey('proxyMode')) {
        final oldMode = data['proxyMode']?.toString();
        final oldCustom = normalizeProxyInput(data['customProxy']?.toString() ?? '');
        if (oldMode == 'manual' && oldCustom.isNotEmpty) {
          restoredRoutes['ms'] = 'custom';
          restoredRoutes['fish'] = 'custom';
          restoredProxies['ms'] = oldCustom;
          restoredProxies['fish'] = oldCustom;
        } else if (oldMode == 'auto') {
          restoredRoutes['ms'] = 'system';
          restoredRoutes['fish'] = 'system';
        }
      }

      final rawCustomProxies = data['engineCustomProxies'] ?? data['engine_custom_proxies'];
      if (rawCustomProxies is Map) {
        rawCustomProxies.forEach((k, v) {
          final norm = normalizeProxyInput(v?.toString() ?? '');
          if (norm.isNotEmpty) restoredProxies[k.toString()] = norm;
        });
      }

      final String restoredBookDir = (data['lastBookDir'] ?? _lastBookDir).toString();
      final String restoredBackupDir = (data['lastBackupDir'] ?? _lastBackupDir).toString();
      final String restoredMp3Dir = (data['lastMp3Dir'] ?? _lastMp3Dir).toString();

      final List<String> restoredPins = (data['pinnedVoices'] is List)
          ? (data['pinnedVoices'] as List).map((e) => e.toString()).toList()
          : _pinnedVoiceIds;

      final List<BookBookmark> restoredBookmarks = [];
      if (data['bookmarks'] is List) {
        for (final item in (data['bookmarks'] as List)) {
          if (item is Map) restoredBookmarks.add(BookBookmark.fromJson(Map<String, dynamic>.from(item)));
        }
      }

      final Map<String, BookHistoryItem> restoredHistory = {};
      if (data['history'] is Map) {
        (data['history'] as Map).forEach((k, v) {
          if (v is Map) {
            restoredHistory[k.toString()] = BookHistoryItem.fromJson(Map<String, dynamic>.from(v));
          }
        });
      }

      setState(() {
        if (restoredFishVoices.isNotEmpty) _userFishVoices = restoredFishVoices;
        if (restoredMsVoices.isNotEmpty) _userMsVoices = restoredMsVoices;
        _customEngines = restoredCustomEngines;
        _pinnedVoiceIds = restoredPins;

        _currentEngine = restoredEngine;
        _apiKey = restoredApiKey;
        _fishModel = restoredFishModel;
        _selectedVoiceId = restoredVoice;

        _speechRate = restoredRate;
        _bitrate = restoredBitrate;
        _timeoutSeconds = restoredTimeout;
        _preloadCount = restoredPreload;
        _exportThreads = restoredThreads;
        _intervalPauseMs = restoredInterval;
        _maxCacheCount = restoredMaxCache;
        _followAlong = restoredFollow;
        _splitMode = restoredSplit;
        _fontSize = restoredFont;
        _readingBgColorValue = restoredBgColor;
        _readingHighlightColorValue = restoredHlColor;
        AppLogger.logLevel = restoredLogLevel;

        if (restoredBookDir.isNotEmpty) _lastBookDir = restoredBookDir;
        if (restoredBackupDir.isNotEmpty && !restoredBackupDir.contains('/cache/')) _lastBackupDir = restoredBackupDir;
        if (restoredMp3Dir.isNotEmpty) _lastMp3Dir = restoredMp3Dir;

        _bookmarks = restoredBookmarks;
        if (restoredHistory.isNotEmpty) _history = restoredHistory;

        _networkRouter.engineNetworkModes.clear();
        _networkRouter.engineCustomProxies.clear();
        restoredRoutes.forEach((k, v) {
          _networkRouter.setEngineNetwork(k, v, restoredProxies[k] ?? '');
        });
        for (final c in _customEngines) {
          _networkRouter.setEngineNetwork(c.id, c.networkMode, c.customProxy);
        }

        _fishTts = FishAudioTTS(apiKey: _apiKey, voices: _userFishVoices, model: _fishModel);
        _ensureValidSelectedEngineAndVoice();
        _invalidateAudioCache();
      });

      await _networkRouter.refreshSystemProxy();
      await _saveSettings();
      await _saveHistoryToPrefs(immediate: true);

      if (_fullContent.isNotEmpty && prevSplitMode != _splitMode) {
        final targetOffset = (_nodes.isNotEmpty && _currentIndex < _nodes.length) ? _nodes[_currentIndex].startOffset : 0;
        final res = await BookParser.resliceInIsolate(_fullContent, _rawChapters, _splitMode, 0);
        if (mounted) {
          setState(() {
            _nodes = res['nodes'];
            _alignedChapters = res['alignedChapters'];
            _currentIndex = BookParser.findIndexByCharOffset(_nodes, targetOffset);
          });
          _scrollToCurrentCenter(immediate: true, force: true);
        }
      }

      AppLogger.log(
        "备份恢复完成 [引擎:$_currentEngine, APIKey:${_apiKey.isEmpty ? '空' : '已恢复(${_apiKey.length}位)'}, 预读:$_preloadCount句, 字体:${_fontSize}px, 书架:${_history.length}本, 自定义引擎:${_customEngines.length}个, 日志:${AppLogger.logLevel}]",
        null,
        null,
        true,
      );

      if (mounted) {
        final maskedKey = _apiKey.isEmpty
            ? '未配置'
            : (_apiKey.length <= 8 ? '已恢复 (${_apiKey.length}位)' : '${_apiKey.substring(0, 4)}****${_apiKey.substring(_apiKey.length - 4)}');
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
              '• 当前引擎：${ReaderDialogs.getEngineDisplayName(_currentEngine, _customEngines)}\n'
              '• Fish API Key：$maskedKey\n'
              '• 预读缓存：$_preloadCount 句 | 导出线程：$_exportThreads\n'
              '• 正文字号：${_fontSize.toStringAsFixed(1).replaceAll(".0", "")} px | 背景：${colorToHex(Color(_readingBgColorValue))}\n'
              '• 自定义引擎：${_customEngines.length} 个 | 日志层级：${AppLogger.logLevel}\n'
              '• 书架记录：${_history.length} 本 | 书签：${_bookmarks.length} 条',
              style: const TextStyle(height: 1.5, fontSize: 13),
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定'))],
          ),
        );
      }
      return true;
    } catch (e, stack) {
      AppLogger.log("恢复备份失败: $path", e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
      return false;
    }
  }

  Future<void> _openCustomEnginesManager() {
    return ReaderDialogs.showCustomEnginesDialog(
      context: context,
      customEngines: _customEngines,
      activeEngineId: _currentEngine,
      networkRouter: _networkRouter,
      timeoutSeconds: _timeoutSeconds,
      onCustomEnginesChanged: (updated) {
        setState(() {
          _customEngines = updated;
          for (final c in _customEngines) {
            _networkRouter.setEngineNetwork(c.id, c.networkMode, c.customProxy);
          }
          _ensureValidSelectedEngineAndVoice();
          _invalidateAudioCache();
        });
        _saveSettings();
      },
      onSelectEngine: (engineId) {
        setState(() {
          _currentEngine = engineId;
          _selectedVoiceId = _defaultVoiceForEngine(engineId);
          _invalidateAudioCache();
        });
        _saveSettings();
        if (_isPlaying) _startTTS();
      },
    );
  }

  void _openSettingsPage() {
    ReaderDialogs.openSettingsPage(
      context: context,
      currentEngine: _currentEngine,
      apiKey: _apiKey,
      fishModel: _fishModel,
      bitrate: _bitrate,
      timeoutSeconds: _timeoutSeconds,
      preloadCount: _preloadCount,
      exportThreads: _exportThreads,
      intervalPauseMs: _intervalPauseMs,
      maxCacheCount: _maxCacheCount,
      networkRouter: _networkRouter,
      customEngines: _customEngines,
      followAlong: _followAlong,
      splitMode: _splitMode,
      fontSize: _fontSize,
      readingBgColor: _readingBgColorValue,
      readingHighlightColor: _readingHighlightColorValue,
      logLevel: AppLogger.logLevel,
      lastBackupDir: _lastBackupDir,
      onExportBackup: _exportBackup,
      onBackupDirChanged: (d) {
        _lastBackupDir = d;
        _saveSettings();
      },
      onShowRestorePicker: () => ReaderDialogs.showRestorePicker(
        context: context,
        lastBackupDir: _lastBackupDir,
        onRestoreFile: _restoreBackupFromFile,
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
        required followAlong,
        required splitMode,
        required fontSize,
        required readingBgColor,
        required readingHighlightColor,
        required logLevel,
      }) async {
        final bool splitChanged = (_splitMode != splitMode);
        final bool audioParamsChanged = (_currentEngine != engine || _bitrate != bitrate || _fishModel != fishModel || _apiKey != apiKey);

        setState(() {
          _currentEngine = engine;
          _apiKey = apiKey;
          _fishModel = fishModel;
          _fishTts.apiKey = _apiKey;
          _fishTts.model = _fishModel;
          _bitrate = bitrate;
          _timeoutSeconds = timeoutSeconds;
          _preloadCount = preloadCount;
          _exportThreads = exportThreads;
          _intervalPauseMs = intervalPauseMs;
          _maxCacheCount = maxCacheCount;
          AppLogger.logLevel = AppLogger.normalizeLevel(logLevel);

          engineNetworkModes.forEach((k, mode) {
            final customAddr = engineCustomProxies[k] ?? '';
            _networkRouter.setEngineNetwork(k, mode, customAddr);
            for (final c in _customEngines) {
              if (c.id == k) {
                c.networkMode = normalizeEngineNetworkMode(mode);
                c.customProxy = normalizeProxyInput(customAddr);
              }
            }
          });

          _followAlong = followAlong;
          _fontSize = fontSize.clamp(10.0, 20.0);
          _readingBgColorValue = readingBgColor;
          _readingHighlightColorValue = readingHighlightColor;
          _ensureValidSelectedEngineAndVoice();
          if (audioParamsChanged) _invalidateAudioCache();
        });

        await _networkRouter.refreshSystemProxy();
        await _saveSettings();
        AppLogger.log("系统设置已保存 [引擎:$_currentEngine, 预读:$_preloadCount, 字号:${_fontSize}px, 背景:${colorToHex(Color(_readingBgColorValue))}, 日志:${AppLogger.logLevel}]", null, null, true);

        if (splitChanged) {
          await _switchSplitMode(splitMode);
        } else if (audioParamsChanged && _isPlaying) {
          _startTTS();
        }
      },
    );
  }

  void _showVoiceManagerDialog() {
    if (_isVoiceDialogOpen) return;
    _isVoiceDialogOpen = true;
    ReaderDialogs.showVoiceManagerDialog(
      context: context,
      currentEngine: _currentEngine,
      selectedVoiceId: _selectedVoiceId,
      userMsVoices: _userMsVoices,
      userFishVoices: _userFishVoices,
      customEngines: _customEngines,
      pinnedVoiceIds: _pinnedVoiceIds,
      speechRate: _speechRate,
      bitrate: _bitrate,
      timeoutSeconds: _timeoutSeconds,
      fishTts: _fishTts,
      networkRouter: _networkRouter,
      onVoiceSelected: (eng, vId) {
        setState(() {
          _currentEngine = eng;
          _selectedVoiceId = vId;
          _invalidateAudioCache();
        });
        _saveSettings();
        if (_isPlaying) _startTTS();
      },
      onVoicesUpdated: (eng, updatedMap) {
        setState(() {
          if (eng == "ms") {
            _userMsVoices = Map.from(updatedMap);
          } else if (eng == "fish") {
            _userFishVoices = Map.from(updatedMap);
            _fishTts.voices = _userFishVoices;
          } else {
            for (final c in _customEngines) {
              if (c.id == eng) {
                c.voices = Map.from(updatedMap);
                break;
              }
            }
          }
          _ensureValidSelectedEngineAndVoice();
        });
        _saveSettings();
      },
      onVoicesReset: (eng) {
        setState(() {
          if (eng == "ms") {
            _userMsVoices = Map.from(defaultMsVoices46);
          } else if (eng == "fish") {
            _userFishVoices = Map.from(defaultFishVoices);
            _fishTts.voices = _userFishVoices;
          }
          _ensureValidSelectedEngineAndVoice();
        });
        _saveSettings();
      },
      onPinToggled: () => _saveSettings(),
      onClosed: () {
        _isVoiceDialogOpen = false;
      },
    );
  }

  void _showSleepTimerDialog() {
    ReaderDialogs.showSleepTimerDialog(
      context: context,
      sleepTimeLeftSeconds: _sleepTimeLeftSeconds,
      sleepStopAfterChapter: _sleepStopAfterChapter,
      onStartTimer: (minutes) {
        _sleepTimer?.cancel();
        setState(() {
          _sleepStopAfterChapter = false;
          _sleepTimeLeftSeconds = minutes * 60;
        });
        AppLogger.log("启动睡眠定时: $minutes 分钟倒计时", null, null, true);
        _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (_sleepTimeLeftSeconds > 0) {
            setState(() => _sleepTimeLeftSeconds--);
          } else {
            t.cancel();
            AppLogger.log("睡眠定时倒计时归零，自动执行暂停", null, null, true);
            _stopTTS();
          }
        });
      },
      onCancelTimer: () {
        _sleepTimer?.cancel();
        setState(() {
          _sleepStopAfterChapter = false;
          _sleepTimeLeftSeconds = 0;
        });
      },
      onStopAfterChapter: () {
        _sleepTimer?.cancel();
        setState(() {
          _sleepStopAfterChapter = true;
          _sleepTimeLeftSeconds = 0;
        });
        AppLogger.log("设定为: 读完本章后自动暂停", null, null, true);
      },
    );
  }

  void _openExportDialog() {
    if (_nodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("请先打开电子书或从剪贴板导入文本后再导出 MP3")),
      );
      return;
    }
    ReaderDialogs.openExportDialog(
      hostContext: context,
      exportController: _exportController,
      nodes: _nodes,
      alignedChapters: _alignedChapters,
      currentIndex: _currentIndex,
      currentBookName: _currentBookName,
      lastMp3Dir: _lastMp3Dir,
      defaultThreads: _exportThreads,
      currentEngine: _currentEngine,
      selectedVoiceId: _selectedVoiceId,
      userMsVoices: _userMsVoices,
      userFishVoices: _userFishVoices,
      customEngines: _customEngines,
      speechRate: _speechRate,
      bitrate: _bitrate,
      timeoutSeconds: _timeoutSeconds,
      fishTts: _fishTts,
      networkRouter: _networkRouter,
      onSaveMp3Dir: (d) {
        _lastMp3Dir = d;
        _saveSettings();
      },
      onSaveThreads: (th) {
        _exportThreads = th;
        _saveSettings();
      },
    );
  }

  String _describeEngineRoute(String engId) {
    final route = _networkRouter.getEngineRoute(engId, _customEngines);
    if (route == 'system') {
      final sys = _networkRouter.detectedSystemProxy;
      if (sys != null && sys.isNotEmpty) return '系统代理($sys)';
      if (Platform.isAndroid && _networkRouter.hasActiveVpn) return '系统VPN隧道(Exclave等)';
      return '系统代理(未检测到-回退直连)';
    }
    if (route == 'custom') {
      final custom = _networkRouter.getEngineCustomProxy(engId, _customEngines);
      return custom.isNotEmpty ? '自定义代理($custom)' : '自定义代理(未填写-回退直连)';
    }
    if (Platform.isAndroid && _networkRouter.hasActiveVpn) {
      return _networkRouter.hasBypassPhysicalNetwork ? '物理网卡直连(已绕过VPN)' : '直连(未检测到可绕过物理网卡)';
    }
    return '直连';
  }

  Future<void> _runConnectivityDiagnostics() async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    await _networkRouter.refreshSystemProxy();
    final msRes = await MicrosoftTranslatorTTS.testConnectivity(_networkRouter.getClientForEngine('ms', _customEngines));
    final fishRes = await _fishTts.testConnectivity(_networkRouter.getClientForEngine('fish', _customEngines));
    final customResults = <Map<String, dynamic>>[];
    for (final c in _customEngines) {
      final r = await CustomTtsRunner.testConnectivity(c, _networkRouter.getClientForEngine(c.id, _customEngines));
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(color: const Color(0xFFEFE7D2), borderRadius: BorderRadius.circular(6)),
                child: Text(
                  _networkRouter.describeNetworkBanner(),
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF743C00)),
                ),
              ),
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bool isWide = media.size.width >= 750;
    final double screenW = media.size.width;
    final String bookTitle = _currentBookName ?? "鱼听书";
    final String chapSubTitle = _currentChapterTitle();
    final bookList = _history.values.toList()..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));

    final Color readingBg = Color(_readingBgColorValue);
    final Color readingHlBg = Color(_readingHighlightColorValue);
    final Color normalTextColor = getContrastTextColor(readingBg);
    final Color hlTextColor = getHighlightTextColor(readingHlBg);
    final Color hlAccentColor = getHighlightAccentColor(readingHlBg);

    final String currentVoiceName = _voicesForEngine(_currentEngine)[_selectedVoiceId] ?? _selectedVoiceId;
    final String currentEngineLabel = _currentEngine == 'ms'
        ? '微软'
        : (_currentEngine == 'fish' ? 'Fish' : ReaderDialogs.getEngineDisplayName(_currentEngine, _customEngines));
    final String activeRoute = _networkRouter.getEngineRoute(_currentEngine, _customEngines);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleLeftEdgeSwipeAction();
      },
      child: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) return KeyEventResult.ignored;
          if (event is KeyDownEvent) {
            final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
            if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyF) {
              setState(() => _isSearching = true);
              return KeyEventResult.handled;
            } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyO) {
              _importFile();
              return KeyEventResult.handled;
            } else if (!isCtrl && event.logicalKey == LogicalKeyboardKey.space) {
              _togglePlayPause();
              return KeyEventResult.handled;
            } else if (!isCtrl && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _jumpSentence(-1);
              return KeyEventResult.handled;
            } else if (!isCtrl && event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _jumpSentence(1);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: DropTarget(
          onDragDone: (details) {
            if (details.files.isNotEmpty) _openBook(details.files.first.path);
          },
          child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: readingBg,
            drawerEnableOpenDragGesture: true,
            drawerEdgeDragWidth: 32.0,
            onDrawerChanged: (isOpened) {
              _isDrawerOpen = isOpened;
              if (isOpened) {
                // 打开抽屉时归零返回退出计数
                _lastBackPressTime = 0;
              } else {
                _lastBackPressTime = 0;
              }
            },
            drawer: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (d) {
                if (d.globalPosition.dx <= 36) {
                  _edgeDragStartX = d.globalPosition.dx;
                  _edgeDragAccumDx = 0;
                  _edgeDragHandled = false;
                } else {
                  _edgeDragStartX = null;
                }
              },
              onHorizontalDragUpdate: (d) {
                if (_edgeDragStartX != null && !_edgeDragHandled) {
                  _edgeDragAccumDx += d.delta.dx;
                  if (_edgeDragAccumDx > 36) {
                    _edgeDragHandled = true;
                    _handleLeftEdgeSwipeAction();
                  }
                }
              },
              onHorizontalDragEnd: (_) => _edgeDragStartX = null,
              child: Drawer(
                child: ReaderSidebar(
                  sidebarTab: _sidebarTab,
                  isSelectionMode: _isSelectionMode,
                  selectedFingerprints: _selectedFingerprints,
                  chapters: _alignedChapters,
                  currentIndex: _currentIndex,
                  bookList: bookList,
                  bookmarks: _currentBookBookmarks,
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
                  onChapterSelected: (pIdx) {
                    setState(() => _currentIndex = pIdx);
                    _saveHistoryToPrefs();
                    _scrollToCurrentCenter(force: true);
                    if (_isPlaying) _startTTS();
                  },
                  onBookSelected: (item) => _openBook(item.lastKnownPath),
                  onBookRelink: (item) async {
                    String? newPath;
                    if (Platform.isAndroid) {
                      newPath = await StorageHelper.browseSharedStorage(context, chooseDirectory: false, extensions: ['txt', 'epub', 'md', 'markdown'], initialPath: _lastBookDir);
                    } else {
                      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'epub', 'md']);
                      newPath = res?.files.single.path;
                    }
                    if (newPath != null) _openBook(newPath);
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
                    setState(() {
                      for (var fp in _selectedFingerprints) {
                        _history.remove(fp);
                      }
                      _isSelectionMode = false;
                      _selectedFingerprints.clear();
                    });
                    _saveHistoryToPrefs(immediate: true);
                  },
                  onBookmarkSelected: (bm) {
                    setState(() => _currentIndex = bm.paragraphIndex);
                    _scrollToCurrentCenter(force: true);
                  },
                  onBookmarkEdit: (bm) {
                    ReaderDialogs.showEditBookmarkDialog(
                      context: context,
                      bookmark: bm,
                      onSave: (newContent, newNote) {
                        setState(() {
                          bm.content = newContent;
                          bm.note = newNote;
                        });
                        _saveSettings();
                      },
                    );
                  },
                  onBookmarkDelete: (bm) {
                    setState(() => _bookmarks.removeWhere((b) => b.id == bm.id));
                    _saveSettings();
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("书签已移除")));
                  },
                ),
              ),
            ),
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () {
                  setState(() => _sidebarTab = 0);
                  _scaffoldKey.currentState?.openDrawer();
                },
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(bookTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  if (chapSubTitle.isNotEmpty)
                    Text(chapSubTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.blueGrey, fontWeight: FontWeight.normal)),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.search, size: 21),
                  tooltip: "全文搜索",
                  onPressed: () => setState(() => _isSearching = !_isSearching),
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open_outlined, size: 21),
                  tooltip: "打开电子书",
                  onPressed: _importFile,
                ),
                PopupMenuButton<String>(
                  onSelected: (val) async {
                    switch (val) {
                      case "settings":
                        _openSettingsPage();
                        break;
                      case "custom_engines":
                        await _openCustomEnginesManager();
                        break;
                      case "export_mp3":
                        _openExportDialog();
                        break;
                      case "network":
                        await _runConnectivityDiagnostics();
                        break;
                      case "logs":
                        ReaderDialogs.showLogViewerDialog(
                          context: context,
                          onLogLevelChanged: (newLevel) {
                            widget.prefs.setString('log_level', AppLogger.normalizeLevel(newLevel));
                          },
                        );
                        break;
                      case "clipboard_import":
                        await _importFromClipboard();
                        break;
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: "settings", child: Row(children: [Icon(Icons.settings, color: Colors.blue), SizedBox(width: 8), Text("系统设置")])),
                    PopupMenuItem(value: "custom_engines", child: Row(children: [Icon(Icons.extension, color: Color(0xFFC87D2E)), SizedBox(width: 8), Text("TTS引擎管理")])),
                    PopupMenuItem(value: "export_mp3", child: Row(children: [Icon(Icons.audio_file_outlined, color: Colors.deepOrange), SizedBox(width: 8), Text("合成导出MP3")])),
                    PopupMenuItem(value: "network", child: Row(children: [Icon(Icons.wifi_find, color: Colors.teal), SizedBox(width: 8), Text("TTS引擎连通测试")])),
                    PopupMenuItem(value: "logs", child: Row(children: [Icon(Icons.terminal, color: Color(0xFFC87D2E)), SizedBox(width: 8), Text("运行日志管理")])),
                    PopupMenuItem(value: "clipboard_import", child: Row(children: [Icon(Icons.content_paste_go, color: Colors.indigo), SizedBox(width: 8), Text("剪贴板导入")])),
                  ],
                ),
              ],
            ),
            body: Stack(
              children: [
                Container(
                  color: readingBg,
                  child: _nodes.isEmpty
                      ? EmptyBookshelfView(
                          bookList: bookList,
                          readingBgColor: readingBg,
                          onImportFile: _importFile,
                          onOpenBook: _openBook,
                          onRelinkBook: (item) async {
                            String? newPath;
                            if (Platform.isAndroid) {
                              newPath = await StorageHelper.browseSharedStorage(context, chooseDirectory: false, extensions: ['txt', 'epub', 'md', 'markdown'], initialPath: _lastBookDir);
                            } else {
                              final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'epub', 'md']);
                              newPath = res?.files.single.path;
                            }
                            if (newPath != null) _openBook(newPath);
                          },
                        )
                      : SelectionArea(
                          contextMenuBuilder: (context, selectableRegionState) {
                            // 严格白名单：仅保留纯本地“复制”与“全选”，彻底屏蔽系统注入的分享、文件传输助手、浏览器搜索等外部项
                            final allowedSystemItems = selectableRegionState.contextMenuButtonItems
                                .where((item) => item.type == ContextMenuButtonType.copy || item.type == ContextMenuButtonType.selectAll)
                                .toList();

                            return AdaptiveTextSelectionToolbar.buttonItems(
                              anchors: selectableRegionState.contextMenuAnchors,
                              buttonItems: [
                                ...allowedSystemItems,
                                ContextMenuButtonItem(
                                  label: '📋 复制本章节',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _copyChapterAt(_contextTargetSliceIndex);
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '📄 复制全文',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _copyFullText();
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '🔖 在此添加书签',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _addBookmarkAt(_contextTargetSliceIndex);
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '🎯 视线对齐当前项',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    _scrollToCurrentCenter(force: true);
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '⏮️ 上一章',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    for (int i = _alignedChapters.length - 1; i >= 0; i--) {
                                      if (_alignedChapters[i].paragraphIndex < _currentIndex - 1) {
                                        setState(() => _currentIndex = _alignedChapters[i].paragraphIndex);
                                        _saveHistoryToPrefs();
                                        _scrollToCurrentCenter(force: true);
                                        if (_isPlaying) _startTTS();
                                        return;
                                      }
                                    }
                                  },
                                ),
                                ContextMenuButtonItem(
                                  label: '⏭️ 下一章',
                                  onPressed: () {
                                    selectableRegionState.hideToolbar();
                                    for (int i = 0; i < _alignedChapters.length; i++) {
                                      if (_alignedChapters[i].paragraphIndex > _currentIndex) {
                                        setState(() => _currentIndex = _alignedChapters[i].paragraphIndex);
                                        _saveHistoryToPrefs();
                                        _scrollToCurrentCenter(force: true);
                                        if (_isPlaying) _startTTS();
                                        return;
                                      }
                                    }
                                  },
                                ),
                              ],
                            );
                          },
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 820),
                              child: ScrollablePositionedList.builder(
                                itemCount: _nodes.length,
                                itemScrollController: _itemScrollController,
                                itemPositionsListener: _itemPositionsListener,
                                initialScrollIndex: _currentIndex,
                                initialAlignment: 0.32,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                                itemBuilder: (ctx, idx) {
                                  final isCur = idx == _currentIndex;
                                  final isMatch = _searchResults.contains(idx);
                                  final baseStyle = TextStyle(
                                    fontSize: _fontSize,
                                    height: 1.88,
                                    letterSpacing: 0.3,
                                    fontWeight: isCur ? FontWeight.w600 : FontWeight.normal,
                                    color: isCur ? hlTextColor : normalTextColor,
                                  );

                                  return Listener(
                                    onPointerDown: (_) => _contextTargetSliceIndex = idx,
                                    child: GestureDetector(
                                      onDoubleTap: () {
                                        setState(() => _currentIndex = idx);
                                        _saveHistoryToPrefs();
                                        _startTTS();
                                      },
                                      child: Container(
                                        width: double.infinity,
                                        margin: const EdgeInsets.symmetric(vertical: 4),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: isCur ? readingHlBg : (isMatch ? Colors.yellow.shade200.withOpacity(0.7) : Colors.transparent),
                                          borderRadius: BorderRadius.circular(6),
                                          border: isCur ? Border(left: BorderSide(color: hlAccentColor, width: 3.5)) : null,
                                        ),
                                        child: _buildHighlightedParagraph(_nodes[idx].text, baseStyle),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                ),

                // 手机端左边缘向内划热区：第 1 划确保切换到大纲目录弹出
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 24,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (d) {
                      _edgeDragStartX = d.globalPosition.dx;
                      _edgeDragAccumDx = 0;
                      _edgeDragHandled = false;
                    },
                    onHorizontalDragUpdate: (d) {
                      if (_edgeDragStartX != null && !_edgeDragHandled) {
                        _edgeDragAccumDx += d.delta.dx;
                        if (_edgeDragAccumDx > 24) {
                          _edgeDragHandled = true;
                          _handleLeftEdgeSwipeAction();
                        }
                      }
                    },
                    onHorizontalDragEnd: (_) => _edgeDragStartX = null,
                  ),
                ),

                // 手机端右边缘向内划热区：弹出发音人管理区，不触发退出
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: 24,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (d) {
                      if (d.globalPosition.dx >= screenW - 36) {
                        _edgeDragStartX = d.globalPosition.dx;
                        _edgeDragAccumDx = 0;
                        _edgeDragHandled = false;
                      } else {
                        _edgeDragStartX = null;
                      }
                    },
                    onHorizontalDragUpdate: (d) {
                      if (_edgeDragStartX != null && !_edgeDragHandled) {
                        _edgeDragAccumDx += d.delta.dx;
                        if (_edgeDragAccumDx < -24) {
                          _edgeDragHandled = true;
                          _handleRightEdgeSwipeAction();
                        }
                      }
                    },
                    onHorizontalDragEnd: (_) => _edgeDragStartX = null,
                  ),
                ),

                if (_isSearching)
                  Positioned(
                    top: 10,
                    right: 16,
                    child: Material(
                      elevation: 8,
                      borderRadius: BorderRadius.circular(22),
                      color: const Color(0xFFFCFBF7),
                      child: Container(
                        width: min(360.0, screenW - 32),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0xFFC87D2E), width: 1.5),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.search, size: 18, color: Color(0xFFC87D2E)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: _searchCtrl,
                                autofocus: true,
                                style: const TextStyle(fontSize: 13),
                                decoration: const InputDecoration(
                                  hintText: "输入关键字搜索...",
                                  hintStyle: TextStyle(fontSize: 12),
                                  isDense: true,
                                  border: InputBorder.none,
                                ),
                                onChanged: (val) {
                                  _searchDebounce?.cancel();
                                  _searchDebounce = Timer(const Duration(milliseconds: 280), () {
                                    if (mounted) _executeSearch(val, showEmptyTip: false);
                                  });
                                },
                                onSubmitted: (q) => _executeSearch(q, showEmptyTip: true),
                              ),
                            ),
                            if (_searchResults.isNotEmpty) ...[
                              Text(
                                "${_currentSearchMatchIndex + 1}/${_searchResults.length}",
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFC87D2E)),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
                                tooltip: "上一处",
                                onPressed: () => _navigateToMatch(_currentSearchMatchIndex - 1),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                                tooltip: "下一处",
                                onPressed: () => _navigateToMatch(_currentSearchMatchIndex + 1),
                              ),
                            ] else
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.arrow_forward_rounded, size: 18, color: Color(0xFFC87D2E)),
                                tooltip: "查找",
                                onPressed: () => _executeSearch(_searchCtrl.text, showEmptyTip: true),
                              ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                              onPressed: () => setState(() {
                                _isSearching = false;
                                _activeSearchQuery = "";
                                _searchResults.clear();
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_showBackToCurrent && _nodes.isNotEmpty)
                  Positioned(
                    bottom: 14,
                    right: 18,
                    child: FloatingActionButton.small(
                      heroTag: 'back_to_current_tts',
                      backgroundColor: const Color(0xFFFCFBF7),
                      foregroundColor: const Color(0xFFC87D2E),
                      tooltip: "回到当前朗读位置",
                      onPressed: () => _scrollToCurrentCenter(force: true),
                      child: const Icon(Icons.my_location),
                    ),
                  ),
                if (_exportController.isExporting)
                  MinimizedExportBadge(
                    done: _exportController.done,
                    total: _exportController.total,
                    elapsedSeconds: _exportController.elapsedSeconds,
                    onTap: _openExportDialog,
                  ),
              ],
            ),
            bottomNavigationBar: WeReadPlayerBar(
              isWide: isWide,
              engineLabel: currentEngineLabel,
              voiceName: currentVoiceName,
              speechRate: _speechRate,
              sleepTimeLeftSeconds: _sleepTimeLeftSeconds,
              sleepStopAfterChapter: _sleepStopAfterChapter,
              currentIndex: _currentIndex,
              totalNodes: _nodes.length,
              isPlaying: _isPlaying,
              isBuffering: _isBuffering,
              followAlong: _followAlong,
              networkRoute: activeRoute,
              onVoiceTap: _showVoiceManagerDialog,
              onSpeedTap: () {
                final int nextIdx = (speedOptions.indexOf(_speechRate) + 1) % speedOptions.length;
                setState(() {
                  _speechRate = speedOptions[nextIdx];
                  _invalidateAudioCache();
                });
                _saveSettings();
                if (_isPlaying) _startTTS();
              },
              onSleepTimerTap: _showSleepTimerDialog,
              onSeek: (target) {
                setState(() => _currentIndex = target);
                _saveHistoryToPrefs();
                _scrollToCurrentCenter(force: true);
                if (_isPlaying) _startTTS();
              },
              onOpenDrawer: () {
                setState(() => _sidebarTab = 0);
                _scaffoldKey.currentState?.openDrawer();
              },
              onPrev: () => _jumpSentence(-1),
              onPlayPause: _togglePlayPause,
              onNext: () => _jumpSentence(1),
              onToggleFollowAlong: () {
                setState(() => _followAlong = !_followAlong);
                _saveSettings();
              },
              onExportTap: _openExportDialog,
            ),
          ),
        ),
      ),
    );
  }
}
