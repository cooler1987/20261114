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
      title: '鱼听书 (微信读书质感版)',
      debugShowCheckedModeBanner: false,
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

class _ReaderHomeScreenState extends State<ReaderHomeScreen> with WidgetsBindingObserver {
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
  double _fontSize = 14.0; // 默认 14px，设置页 10-20px 可调

  String _lastBookDir = "";
  String _lastBackupDir = StorageHelper.getDefaultBackupDir();
  String _lastMp3Dir = "";

  Map<String, BookHistoryItem> _history = {};
  List<BookBookmark> _bookmarks = [];
  String? _currentFingerprint;
  String? _currentFilePath;
  String? _currentBookName;
  String _fullContent = "";
  int _fileSize = 0;
  List<BookChapter> _rawChapters = [];
  List<BookChapter> _alignedChapters = [];
  List<TextSliceNode> _nodes = [];
  int _currentIndex = 0;

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

  List<BookBookmark> get _currentBookBookmarks =>
      _bookmarks.where((b) => b.bookFingerprint == _currentFingerprint).toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettingsAndHistory();
    _initAudioSession();
    _exportController.addListener(() {
      if (mounted) setState(() {});
    });
    _itemPositionsListener.itemPositions.addListener(_onViewportPositionsChanged);
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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
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
          AppLogger.log("检测到耳机拔出或音频输出切换，自动暂停朗读");
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
    _networkRouter.proxyMode = prefs.getString('proxyMode') == 'manual' ? 'manual' : 'auto';
    _networkRouter.customProxy = prefs.getString('customProxy') ?? '';
    _followAlong = prefs.getBool('followAlong') ?? true;
    _splitMode = prefs.getString('splitMode') ?? 'sentence';
    _fontSize = (prefs.getDouble('font_size_v2') ?? 14.0).clamp(10.0, 20.0);
    AppLogger.logLevel = prefs.getString('log_level') ?? 'error';

    final rawRoutes = prefs.getString('engine_network_modes');
    if (rawRoutes != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawRoutes);
        decoded.forEach((k, v) => _networkRouter.setEngineRoute(k, v.toString()));
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

    _networkRouter.refreshProxy();
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
    await prefs.setString('proxyMode', _networkRouter.proxyMode);
    await prefs.setString('customProxy', _networkRouter.customProxy);
    await prefs.setString('engine_network_modes', jsonEncode(_networkRouter.engineNetworkModes));
    await prefs.setString('custom_tts_engines_v1', jsonEncode(_customEngines.map((e) => e.toJson()).toList()));
    await prefs.setBool('followAlong', _followAlong);
    await prefs.setString('splitMode', _splitMode);
    await prefs.setDouble('font_size_v2', _fontSize);
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
    if (_currentFingerprint != null && _currentFilePath != null && _nodes.isNotEmpty) {
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

  Future<void> _switchSplitMode(String newMode) async {
    if (_splitMode == newMode || _fullContent.isEmpty) return;

    int currentAnchorOffset = 0;
    if (_nodes.isNotEmpty && _currentIndex < _nodes.length) {
      currentAnchorOffset = _nodes[_currentIndex].startOffset;
    }

    _splitMode = newMode;
    final res = await BookParser.resliceInIsolate(_fullContent, _rawChapters, _splitMode);
    final List<TextSliceNode> newNodes = res['nodes'];
    final List<BookChapter> aligned = res['alignedChapters'];
    final int newIndex = BookParser.findIndexByCharOffset(newNodes, currentAnchorOffset);

    AppLogger.log("切换断句规则: $newMode [锚点: $currentAnchorOffset -> 新项: #$newIndex/${newNodes.length}]");

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
      final res = await BookParser.openBookInIsolate(path, _splitMode);
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

      AppLogger.log("电子书装载成功: $name [大小: ${formatFileSize(size)}, 章节: ${rawChapters.length}, 切片: ${nodes.length}, 断点: #$startIdx]");

      if (!mounted) return;
      setState(() {
        _currentFingerprint = fp;
        _currentFilePath = path;
        _currentBookName = name;
        _fullContent = full;
        _fileSize = size;
        _rawChapters = rawChapters;
        _alignedChapters = aligned;
        _nodes = nodes;
        _currentIndex = startIdx;
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
    AppLogger.log("朗读启动 [会话: #$_playSessionId, 项: #$_currentIndex, 引擎: $_currentEngine, 音色: $_selectedVoiceId, 语速: ${_speechRate}x]");
    setState(() {
      _isPlaying = true;
      _isBuffering = true;
      _pausedByInterruption = false;
    });
    _runTTSLoop(_playSessionId);
  }

  Future<void> _stopTTS() async {
    _playSessionId++;
    AppLogger.log("朗读停止 [会话: #$_playSessionId]");
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
            AppLogger.log("已达章节末尾，触发章节定时停止: ${c.title}");
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
      if (epochAtStart != _cacheEpoch) {
        continue;
      }

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
        AppLogger.log("全书朗读完毕");
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

  Future<void> _exportBackup() async {
    try {
      if (!await StorageHelper.checkAndRequestManagePermission()) return;
      final targetFolder = Directory(_lastBackupDir);
      if (!await targetFolder.exists()) await targetFolder.create(recursive: true);

      final dateStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File('${targetFolder.path}${Platform.pathSeparator}fish_reader_backup_$dateStr.json');

      final data = {
        'version': 7,
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
        'proxyMode': _networkRouter.proxyMode,
        'customProxy': _networkRouter.customProxy,
        'engineNetworkModes': _networkRouter.engineNetworkModes,
        'customEngines': _customEngines.map((e) => e.toJson()).toList(),
        'followAlong': _followAlong,
        'splitMode': _splitMode,
        'font_size_v2': _fontSize,
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
      await file.writeAsString(jsonEncode(data), flush: true);

      AppLogger.log("全量备份落盘成功: ${file.path}");
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('备份导出成功'),
            content: Text('全量配置、自定义引擎、书架与书签已成功写入：\n\n${file.path}'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
          ),
        );
      }
    } catch (e, stack) {
      AppLogger.log("导出备份失败", e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出备份失败: $e')));
    }
  }

  Future<void> _restoreBackupFromFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      _lastBackupDir = file.parent.path;

      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;

      setState(() {
        _currentEngine = data['engineType'] ?? _currentEngine;
        _apiKey = data['fishApiKey'] ?? _apiKey;
        _fishModel = data['fishModel'] ?? _fishModel;
        _selectedVoiceId = data['selectedVoice'] ?? _selectedVoiceId;
        _speechRate = (data['speechRate'] as num?)?.toDouble() ?? _speechRate;
        _bitrate = (data['bitrate'] as num?)?.toInt() ?? 64;
        _timeoutSeconds = (data['timeoutSeconds'] as num?)?.toInt() ?? 60;
        _preloadCount = (data['preloadCount'] as num?)?.toInt() ?? 3;
        _exportThreads = (data['exportThreads'] as num?)?.toInt() ?? 6;
        _intervalPauseMs = (data['intervalPauseMs'] as num?)?.toInt() ?? 200;
        _maxCacheCount = (data['maxCacheCount'] as num?)?.toInt() ?? 100;
        _networkRouter.proxyMode = data['proxyMode'] == 'manual' ? 'manual' : 'auto';
        _networkRouter.customProxy = data['customProxy'] ?? '';
        _followAlong = data['followAlong'] as bool? ?? true;
        _splitMode = data['splitMode'] ?? 'sentence';
        final loadedFont = (data['font_size_v2'] as num?)?.toDouble() ?? (data['font_size'] as num?)?.toDouble() ?? 14.0;
        _fontSize = loadedFont.clamp(10.0, 20.0);
        AppLogger.logLevel = data['log_level'] ?? 'error';
        _lastBookDir = data['lastBookDir'] ?? _lastBookDir;
        _lastMp3Dir = data['lastMp3Dir'] ?? _lastMp3Dir;

        if (data['engineNetworkModes'] is Map) {
          (data['engineNetworkModes'] as Map).forEach((k, v) => _networkRouter.setEngineRoute(k.toString(), v.toString()));
        }
        if (data['customEngines'] is List) {
          _customEngines = (data['customEngines'] as List)
              .map((e) => CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
        if (data['fishVoices'] != null) _userFishVoices = Map<String, String>.from(data['fishVoices']);
        if (data['msVoices'] != null) _userMsVoices = Map<String, String>.from(data['msVoices']);
        if (data['pinnedVoices'] != null) _pinnedVoiceIds = List<String>.from(data['pinnedVoices']);

        if (data['bookmarks'] is List) {
          _bookmarks = (data['bookmarks'] as List).map((e) => BookBookmark.fromJson(Map<String, dynamic>.from(e))).toList();
        }
        if (data['history'] is Map) {
          _history = (data['history'] as Map).map((k, v) => MapEntry(k.toString(), BookHistoryItem.fromJson(Map<String, dynamic>.from(v as Map))));
        }
        _ensureValidSelectedEngineAndVoice();
        _invalidateAudioCache();
      });

      await _networkRouter.refreshProxy();
      _fishTts = FishAudioTTS(apiKey: _apiKey, voices: _userFishVoices, model: _fishModel);
      await _saveSettings();
      await _saveHistoryToPrefs(immediate: true);

      AppLogger.log("备份恢复成功: ${_history.length} 本书架, ${_customEngines.length} 自定义引擎");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🎉 备份已成功恢复！')));
    } catch (e, stack) {
      AppLogger.log("恢复备份失败", e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
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

  void _showSettingsDialog() {
    ReaderDialogs.showSettingsDialog(
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
      proxyMode: _networkRouter.proxyMode,
      customProxy: _networkRouter.customProxy,
      engineNetworkModes: _networkRouter.engineNetworkModes,
      customEngines: _customEngines,
      followAlong: _followAlong,
      splitMode: _splitMode,
      fontSize: _fontSize,
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
        required proxyMode,
        required customProxy,
        required engineNetworkModes,
        required followAlong,
        required splitMode,
        required fontSize,
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
          _networkRouter.proxyMode = proxyMode;
          _networkRouter.customProxy = customProxy;
          engineNetworkModes.forEach((k, v) {
            _networkRouter.setEngineRoute(k, v);
            for (final c in _customEngines) {
              if (c.id == k) c.networkMode = v == 'proxy' ? 'proxy' : 'direct';
            }
          });
          _followAlong = followAlong;
          _fontSize = fontSize.clamp(10.0, 20.0);
          _ensureValidSelectedEngineAndVoice();
          if (audioParamsChanged) _invalidateAudioCache();
        });

        await _networkRouter.refreshProxy();
        await _saveSettings();

        if (splitChanged) {
          await _switchSplitMode(splitMode);
        } else if (audioParamsChanged && _isPlaying) {
          _startTTS();
        }
      },
    );
  }

  void _showVoiceManagerDialog() {
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
        AppLogger.log("启动睡眠定时: $minutes 分钟倒计时");
        _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (_sleepTimeLeftSeconds > 0) {
            setState(() => _sleepTimeLeftSeconds--);
          } else {
            t.cancel();
            AppLogger.log("睡眠定时倒计时归零，自动执行暂停");
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
        AppLogger.log("设定为: 读完本章后自动暂停");
      },
    );
  }

  void _openExportDialog() {
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

  Future<void> _runConnectivityDiagnostics() async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    await _networkRouter.refreshProxy();
    final msRes = await MicrosoftTranslatorTTS.testConnectivity(_networkRouter.getClientForEngine('ms', _customEngines));
    final fishRes = await _fishTts.testConnectivity(_networkRouter.getClientForEngine('fish', _customEngines));
    final customResults = <Map<String, dynamic>>[];
    for (final c in _customEngines) {
      final r = await CustomTtsRunner.testConnectivity(c, _networkRouter.getClientForEngine(c.id, _customEngines));
      customResults.add({'name': c.name, 'route': c.networkMode, ...r});
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
              Text("微软官方 [${_networkRouter.getEngineRoute('ms') == 'proxy' ? '走代理' : '直连'}]: ${msRes['success'] ? '✅ 畅通' : '❌ 异常'} (${msRes['latency']}ms)"),
              Text("详情: ${msRes['msg']}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              const Divider(),
              Text("Fish Audio [${_networkRouter.getEngineRoute('fish') == 'proxy' ? '走代理' : '直连'}]: ${fishRes['success'] ? '✅ 畅通' : '❌ 异常'} (${fishRes['latency']}ms)"),
              Text("详情: ${fishRes['msg']}", style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              for (final cr in customResults) ...[
                const Divider(),
                Text("🧩 ${cr['name']} [${cr['route'] == 'proxy' ? '走代理' : '直连'}]: ${cr['success'] ? '✅ 畅通' : '❌ 异常'} (${cr['latency']}ms)"),
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
    final bool isWide = MediaQuery.of(context).size.width >= 750;
    final String bookTitle = _currentBookName ?? "微信读书纯享版";
    final String chapSubTitle = _currentChapterTitle();
    final bookList = _history.values.toList()..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));

    final String currentVoiceName = _voicesForEngine(_currentEngine)[_selectedVoiceId] ?? _selectedVoiceId;
    final String currentEngineLabel = _currentEngine == 'ms'
        ? '微软'
        : (_currentEngine == 'fish' ? 'Fish' : ReaderDialogs.getEngineDisplayName(_currentEngine, _customEngines));
    final bool isDirectNet = _networkRouter.getEngineRoute(_currentEngine, _customEngines) == 'direct';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _activeSearchQuery = "";
            _searchResults.clear();
          });
          return;
        }
        if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.pop(context);
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
        if (now - _lastBackPressTime > 2000) {
          _lastBackPressTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('再按一次返回退出鱼听书'), duration: Duration(milliseconds: 1500)),
          );
          return;
        }

        await _saveHistoryToPrefs(immediate: true);
        await _saveSettings();
        SystemNavigator.pop();
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
            drawerEnableOpenDragGesture: true,
            drawerEdgeDragWidth: 42.0,
            drawer: Drawer(
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
            appBar: AppBar(
              leading: IconButton(icon: const Icon(Icons.menu), onPressed: () => _scaffoldKey.currentState?.openDrawer()),
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
                        _showSettingsDialog();
                        break;
                      case "custom_engines":
                        await _openCustomEnginesManager();
                        break;
                      case "network":
                        await _runConnectivityDiagnostics();
                        break;
                      case "logs":
                        ReaderDialogs.showLogViewerDialog(
                          context: context,
                          onLogLevelChanged: (newLevel) {
                            widget.prefs.setString('log_level', newLevel);
                          },
                        );
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: "settings", child: Row(children: [Icon(Icons.settings, color: Colors.blue), SizedBox(width: 8), Text("系统、字体与规则设置")])),
                    const PopupMenuItem(value: "custom_engines", child: Row(children: [Icon(Icons.extension, color: Color(0xFFC87D2E)), SizedBox(width: 8), Text("自定义 TTS 引擎管理")])),
                    const PopupMenuItem(value: "network", child: Row(children: [Icon(Icons.wifi_find, color: Colors.teal), SizedBox(width: 8), Text("全引擎连通性诊断")])),
                    const PopupMenuItem(value: "logs", child: Row(children: [Icon(Icons.terminal, color: Color(0xFFC87D2E)), SizedBox(width: 8), Text("运行日志管理")])),
                  ],
                ),
              ],
            ),
            body: Stack(
              children: [
                _nodes.isEmpty
                    ? EmptyBookshelfView(
                        bookList: bookList,
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
                        contextMenuBuilder: (context, selectableRegionState) => AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: selectableRegionState.contextMenuAnchors,
                          buttonItems: [
                            ...selectableRegionState.contextMenuButtonItems,
                            ContextMenuButtonItem(
                              label: '🔖 在此添加书签',
                              onPressed: () {
                                selectableRegionState.hideToolbar();
                                _addBookmarkAt(_currentIndex);
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
                        ),
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
                                  color: isCur ? const Color(0xFF743C00) : const Color(0xFF2D2E2F),
                                );

                                return GestureDetector(
                                  onDoubleTap: () {
                                    setState(() => _currentIndex = idx);
                                    _saveHistoryToPrefs();
                                    _startTTS();
                                  },
                                  onSecondaryTap: () => _addBookmarkAt(idx),
                                  onLongPress: () => _addBookmarkAt(idx),
                                  child: Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isCur ? const Color(0xFFEFE7D2) : (isMatch ? Colors.yellow.shade50 : Colors.transparent),
                                      borderRadius: BorderRadius.circular(6),
                                      border: isCur ? const Border(left: BorderSide(color: Color(0xFFC87D2E), width: 3.5)) : null,
                                    ),
                                    child: _buildHighlightedParagraph(_nodes[idx].text, baseStyle),
                                  ),
                                );
                              },
                            ),
                          ),
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
                        width: min(360.0, MediaQuery.of(context).size.width - 32),
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
              isDirectNetwork: isDirectNet,
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
              onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
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
