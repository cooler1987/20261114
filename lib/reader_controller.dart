import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_parser.dart';
import 'models.dart';
import 'system_utils.dart';
import 'tts_engines.dart';

class ReaderController extends ChangeNotifier {
  final SharedPreferences prefs;
  final AudioPlayer audioPlayer = AudioPlayer();
  final TtsNetworkRouter networkRouter = TtsNetworkRouter();

  late FishAudioTTS fishTts;

  // ────────── 引擎与音色设置 ──────────
  String currentEngine = "ms";
  String apiKey = "";
  String fishModel = fishModelOptions.first;
  Map<String, String> userFishVoices = Map.from(defaultFishVoices);
  Map<String, String> userMsVoices = Map.from(defaultMsVoices46);
  List<CustomTtsEngineConfig> customEngines = [];
  List<String> pinnedVoiceIds = [];
  String selectedVoiceId = defaultMsVoices46.keys.first;

  // ────────── 播控与阅读设置 ──────────
  double speechRate = 1.0;
  int bitrate = 64;
  int timeoutSeconds = 60;
  int preloadCount = 3;
  int exportThreads = 6;
  int intervalPauseMs = 200;
  int maxCacheCount = 100;
  bool followAlong = true;
  String splitMode = 'sentence';
  int mergeMinChars = 30; // 短句智能合并最小字数阈值 (0 表示关闭)

  double fontSize = 14.0;
  double lineHeight = 1.85;
  double horizontalPadding = 16.0;
  String themeId = 'parchment';

  String lastBookDir = "";
  String lastBackupDir = StorageHelper.getDefaultBackupDir();
  String lastMp3Dir = "";

  // ────────── 书架、书签与当前书籍 ──────────
  Map<String, BookHistoryItem> history = {};
  List<BookBookmark> bookmarks = [];
  String? currentFingerprint;
  String? currentFilePath;
  String? currentBookName;
  String fullContent = "";
  int fileSize = 0;

  List<BookChapter> rawChapters = [];
  List<BookChapter> alignedChapters = [];
  List<BookParagraph> paragraphs = [];
  List<TextSliceNode> nodes = [];
  int currentIndex = 0;

  // ────────── 播放状态与 Peek-LRU 缓存 ──────────
  bool isPlaying = false;
  bool isBuffering = false;
  bool _pausedByInterruption = false;
  int _playSessionId = 0;
  int _cacheEpoch = 0;
  TtsCancelToken? _activeCancelToken;

  final LinkedHashMap<int, Uint8List> _audioCache = LinkedHashMap<int, Uint8List>();
  final Map<int, Future<Uint8List>> _inFlightPrefetch = {};

  StreamSubscription? _noisySub;
  StreamSubscription? _interruptionSub;
  Timer? _historyFlushTimer;
  Timer? _sleepTimer;
  int sleepTimeLeftSeconds = 0;
  bool sleepStopAfterChapter = false;

  // ────────── 异步搜索状态 ──────────
  bool isSearching = false;
  bool isSearchBusy = false;
  String activeSearchQuery = "";
  List<SearchHit> searchHits = [];
  Set<int> matchedParagraphIndices = {};
  int currentSearchMatchIndex = 0;
  int _searchSeq = 0;

  // ────────── UI 回调钩子 ──────────
  void Function(int paraIndex, {bool immediate, bool force})? onScrollToParaRequest;
  VoidCallback? onOpenBookmarksDrawer;

  ReaderController({required this.prefs}) {
    _loadSettingsAndHistory();
    _initAudioSession();
  }

  ReaderThemeConfig get theme => ReaderThemeConfig.byId(themeId);

  List<BookBookmark> get currentBookBookmarks =>
      bookmarks.where((b) => b.bookFingerprint == currentFingerprint).toList();

  List<BookHistoryItem> get sortedBookList =>
      history.values.toList()..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));

  int get activeParagraphIndex {
    if (paragraphs.isEmpty || nodes.isEmpty) return 0;
    final idx = currentIndex.clamp(0, nodes.length - 1);
    return BookParser.findParagraphIndexByCharOffset(paragraphs, nodes[idx].startOffset);
  }

  TextSliceNode? get activeSliceNode {
    if (nodes.isEmpty) return null;
    return nodes[currentIndex.clamp(0, nodes.length - 1)];
  }

  String get currentVoiceName => voicesForEngine(currentEngine)[selectedVoiceId] ?? selectedVoiceId;

  String get currentEngineLabel {
    if (currentEngine == 'ms') return '微软';
    if (currentEngine == 'fish') return 'Fish';
    for (final c in customEngines) {
      if (c.id == currentEngine) return c.name;
    }
    return currentEngine;
  }

  String get activeNetworkRoute => networkRouter.getEngineRoute(currentEngine, customEngines);

  Future<void> _initAudioSession() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        if (isPlaying) {
          AppLogger.log("检测到耳机拔出或音频输出切换，自动暂停朗读", null, null, true);
          stopTTS();
        }
      });
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          if (isPlaying) {
            _pausedByInterruption = true;
            stopTTS();
          }
        } else if (event.type == AudioInterruptionType.pause && _pausedByInterruption) {
          _pausedByInterruption = false;
          startTTS();
        }
      });
    }
  }

  void _loadSettingsAndHistory() {
    currentEngine = prefs.getString('engineType') ?? 'ms';
    apiKey = prefs.getString('fishApiKey') ?? '';
    fishModel = prefs.getString('fishModel') ?? fishModelOptions.first;
    if (!fishModelOptions.contains(fishModel)) fishModel = fishModelOptions.first;

    speechRate = (prefs.getDouble('speechRate') ?? 1.0).clamp(0.5, 2.5);
    bitrate = prefs.getInt('bitrate') == 128 ? 128 : 64;
    timeoutSeconds = (prefs.getInt('timeoutSeconds') ?? 60).clamp(20, 120);
    preloadCount = (prefs.getInt('preloadCount') ?? 3).clamp(1, 15);
    exportThreads = (prefs.getInt('exportThreads') ?? 6).clamp(1, 16);
    intervalPauseMs = (prefs.getInt('intervalPauseMs') ?? 200).clamp(0, 1500);
    maxCacheCount = (prefs.getInt('maxCacheCount') ?? 100).clamp(50, 300);
    followAlong = prefs.getBool('followAlong') ?? true;
    splitMode = prefs.getString('splitMode') ?? 'sentence';
    mergeMinChars = (prefs.getInt('merge_min_chars') ?? 30).clamp(0, 120);

    fontSize = (prefs.getDouble('font_size_v2') ?? 14.0).clamp(10.0, 20.0);
    lineHeight = (prefs.getDouble('line_height_v1') ?? 1.85).clamp(1.4, 2.2);
    horizontalPadding = (prefs.getDouble('horizontal_padding_v1') ?? 16.0).clamp(8.0, 40.0);
    themeId = prefs.getString('reader_theme_id') ?? 'parchment';
    networkRouter.setIgnoreBadCert(prefs.getBool('ignore_bad_cert') ?? false);
    AppLogger.logLevel = AppLogger.normalizeLevel(prefs.getString('log_level'));

    final rawRoutes = prefs.getString('engine_network_modes');
    if (rawRoutes != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawRoutes);
        decoded.forEach((k, v) => networkRouter.setEngineNetwork(k, v.toString()));
      } catch (_) {}
    }
    final rawProxies = prefs.getString('engine_custom_proxies');
    if (rawProxies != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawProxies);
        decoded.forEach((k, v) {
          networkRouter.setEngineNetwork(k, networkRouter.getEngineRoute(k), v.toString());
        });
      } catch (_) {}
    }

    final rawCustom = prefs.getString('custom_tts_engines_v1');
    if (rawCustom != null) {
      try {
        final List decoded = jsonDecode(rawCustom);
        customEngines = decoded.map((e) => CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (_) {}
    }

    final rawFish = prefs.getString('custom_user_fish_voices');
    if (rawFish != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawFish);
        if (decoded.isNotEmpty) userFishVoices = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    final rawMs = prefs.getString('custom_user_ms_voices');
    if (rawMs != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(rawMs);
        if (decoded.isNotEmpty) userMsVoices = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    pinnedVoiceIds = prefs.getStringList('pinned_voice_ids') ?? [];

    selectedVoiceId = prefs.getString('selectedVoice') ?? defaultVoiceForEngine(currentEngine);
    ensureValidSelectedEngineAndVoice();

    final rawBookmarks = prefs.getString('user_bookmarks_v1');
    if (rawBookmarks != null) {
      try {
        final List decoded = jsonDecode(rawBookmarks);
        bookmarks = decoded.map((e) => BookBookmark.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (_) {}
    }

    lastBookDir = prefs.getString('last_book_dir') ?? "";
    lastBackupDir = prefs.getString('last_backup_dir') ?? StorageHelper.getDefaultBackupDir();
    lastMp3Dir = prefs.getString('last_mp3_dir') ?? "$lastBackupDir${Platform.pathSeparator}MP3";

    final rawHistory = prefs.getString('history_librera_v4') ?? '{}';
    try {
      final decoded = jsonDecode(rawHistory);
      if (decoded is Map) {
        history = decoded.map((k, v) => MapEntry(k.toString(), BookHistoryItem.fromJson(Map<String, dynamic>.from(v as Map))));
      }
    } catch (_) {
      history = {};
    }

    networkRouter.refreshSystemProxy();
    fishTts = FishAudioTTS(apiKey: apiKey, voices: userFishVoices, model: fishModel);
  }

  String defaultVoiceForEngine(String engId) {
    if (engId == 'ms') return userMsVoices.keys.first;
    if (engId == 'fish') return userFishVoices.keys.first;
    for (final c in customEngines) {
      if (c.id == engId && c.voices.isNotEmpty) return c.voices.keys.first;
    }
    return userMsVoices.keys.first;
  }

  Map<String, String> voicesForEngine(String engId) {
    if (engId == 'ms') return userMsVoices;
    if (engId == 'fish') return userFishVoices;
    for (final c in customEngines) {
      if (c.id == engId) return c.voices;
    }
    return userMsVoices;
  }

  void ensureValidSelectedEngineAndVoice() {
    if (currentEngine != 'ms' && currentEngine != 'fish' && !customEngines.any((c) => c.id == currentEngine)) {
      currentEngine = 'ms';
    }
    final vMap = voicesForEngine(currentEngine);
    if (!vMap.containsKey(selectedVoiceId)) {
      selectedVoiceId = vMap.keys.first;
    }
  }

  Future<void> saveSettings() async {
    await prefs.setString('engineType', currentEngine);
    await prefs.setString('fishApiKey', apiKey);
    await prefs.setString('fishModel', fishModel);
    await prefs.setString('selectedVoice', selectedVoiceId);
    await prefs.setDouble('speechRate', speechRate);
    await prefs.setInt('bitrate', bitrate);
    await prefs.setInt('timeoutSeconds', timeoutSeconds);
    await prefs.setInt('preloadCount', preloadCount);
    await prefs.setInt('exportThreads', exportThreads);
    await prefs.setInt('intervalPauseMs', intervalPauseMs);
    await prefs.setInt('maxCacheCount', maxCacheCount);
    await prefs.setString('engine_network_modes', jsonEncode(networkRouter.engineNetworkModes));
    await prefs.setString('engine_custom_proxies', jsonEncode(networkRouter.engineCustomProxies));
    await prefs.setString('custom_tts_engines_v1', jsonEncode(customEngines.map((e) => e.toJson()).toList()));
    await prefs.setBool('followAlong', followAlong);
    await prefs.setString('splitMode', splitMode);
    await prefs.setInt('merge_min_chars', mergeMinChars);
    await prefs.setDouble('font_size_v2', fontSize);
    await prefs.setDouble('line_height_v1', lineHeight);
    await prefs.setDouble('horizontal_padding_v1', horizontalPadding);
    await prefs.setString('reader_theme_id', themeId);
    await prefs.setBool('ignore_bad_cert', networkRouter.ignoreBadCertificate);
    await prefs.setString('log_level', AppLogger.logLevel);

    await prefs.setString('custom_user_fish_voices', jsonEncode(userFishVoices));
    await prefs.setString('custom_user_ms_voices', jsonEncode(userMsVoices));
    await prefs.setStringList('pinned_voice_ids', pinnedVoiceIds);
    await prefs.setString('user_bookmarks_v1', jsonEncode(bookmarks.map((e) => e.toJson()).toList()));

    await prefs.setString('last_book_dir', lastBookDir);
    await prefs.setString('last_backup_dir', lastBackupDir);
    await prefs.setString('last_mp3_dir', lastMp3Dir);
  }

  Future<void> saveHistoryToPrefs({bool immediate = false}) async {
    if (currentFingerprint != null && currentFilePath != null && nodes.isNotEmpty) {
      final validIdx = currentIndex.clamp(0, nodes.length - 1);
      final node = nodes[validIdx];
      final snippet = node.text.length > 30 ? node.text.substring(0, 30) : node.text;

      history[currentFingerprint!] = BookHistoryItem(
        fingerprint: currentFingerprint!,
        lastKnownPath: currentFilePath!,
        bookName: currentBookName ?? currentFilePath!.split(Platform.pathSeparator).last,
        lastIndex: validIdx,
        charOffset: node.startOffset,
        textSnippet: snippet,
        percentage: (node.startOffset / max(1, fullContent.length)).clamp(0.0, 1.0),
        splitMode: splitMode,
        lastReadTime: DateTime.now().millisecondsSinceEpoch,
        fileSize: fileSize,
      );
    }

    if (immediate) {
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      await prefs.setString('history_librera_v4', jsonEncode(history.map((k, v) => MapEntry(k, v.toJson()))));
    } else {
      _historyFlushTimer ??= Timer(const Duration(seconds: 8), () async {
        _historyFlushTimer = null;
        await prefs.setString('history_librera_v4', jsonEncode(history.map((k, v) => MapEntry(k, v.toJson()))));
      });
    }
  }

  // ────────── Peek 式 LRU 音频缓存 (支持瞬时回听不重复计费) ──────────
  void invalidateAudioCache() {
    _cacheEpoch++;
    _audioCache.clear();
    _inFlightPrefetch.clear();
  }

  Uint8List? _peekAudioCache(int index) {
    final bytes = _audioCache.remove(index);
    if (bytes != null) {
      _audioCache[index] = bytes; // 刷新到 LRU 队尾，不移除！
    }
    return bytes;
  }

  void _putAudioCache(int index, Uint8List bytes) {
    _audioCache.remove(index);
    _audioCache[index] = bytes;
    while (_audioCache.length > maxCacheCount) {
      _audioCache.remove(_audioCache.keys.first);
    }
  }

  // ────────── 章节信息与余时预估 ──────────
  String currentChapterTitle() {
    if (alignedChapters.isEmpty || nodes.isEmpty) return "";
    for (int i = alignedChapters.length - 1; i >= 0; i--) {
      if (alignedChapters[i].paragraphIndex <= currentIndex) {
        return alignedChapters[i].title;
      }
    }
    return "";
  }

  String progressSubInfo() {
    if (nodes.isEmpty || fullContent.isEmpty) return "";
    final curOffset = nodes[currentIndex.clamp(0, nodes.length - 1)].startOffset;
    final remainingChars = max(0, fullContent.length - curOffset);
    // 估算中文/混排听书速度约 230 字/分钟 * 倍速
    final estMinutes = max(1, (remainingChars / (230.0 * speechRate)).round());
    final timeLabel = estMinutes >= 60 ? "${estMinutes ~/ 60}小时${estMinutes % 60}分" : "$estMinutes分钟";

    if (alignedChapters.isNotEmpty) {
      int chapIdx = 0;
      for (int i = alignedChapters.length - 1; i >= 0; i--) {
        if (alignedChapters[i].paragraphIndex <= currentIndex) {
          chapIdx = i;
          break;
        }
      }
      final chapStart = alignedChapters[chapIdx].paragraphIndex;
      final chapEnd = (chapIdx + 1 < alignedChapters.length) ? alignedChapters[chapIdx + 1].paragraphIndex : nodes.length;
      final chapLen = max(1, chapEnd - chapStart);
      final chapPct = (((currentIndex - chapStart) / chapLen) * 100).clamp(0.0, 100.0).toStringAsFixed(0);
      return "本章 $chapPct% · 全书约余 $timeLabel";
    }
    return "全书约余 $timeLabel";
  }

  Map<String, String> getChapterTextForParagraph(int paraIdx) {
    if (paragraphs.isEmpty || fullContent.isEmpty) return {'title': '正文', 'text': ''};
    final pIdx = paraIdx.clamp(0, paragraphs.length - 1);
    final pOffset = paragraphs[pIdx].startOffset;

    if (rawChapters.isEmpty) {
      return {'title': currentBookName ?? '全文', 'text': fullContent.trim()};
    }

    int chapIdx = 0;
    for (int i = rawChapters.length - 1; i >= 0; i--) {
      if (rawChapters[i].charOffset <= pOffset) {
        chapIdx = i;
        break;
      }
    }
    final chap = rawChapters[chapIdx];
    final start = chap.charOffset.clamp(0, fullContent.length);
    final end = (chapIdx + 1 < rawChapters.length)
        ? rawChapters[chapIdx + 1].charOffset.clamp(start, fullContent.length)
        : fullContent.length;
    return {
      'title': chap.title,
      'text': fullContent.substring(start, end).trim(),
    };
  }

  int getSliceIndexForParagraph(int paraIdx) {
    if (paragraphs.isEmpty || nodes.isEmpty) return 0;
    final p = paragraphs[paraIdx.clamp(0, paragraphs.length - 1)];
    return BookParser.findIndexByCharOffset(nodes, p.startOffset);
  }

  // ────────── 书签操作 ──────────
  void addBookmarkAtSlice(int sliceIndex) {
    if (nodes.isEmpty || sliceIndex < 0 || sliceIndex >= nodes.length || currentFingerprint == null) return;

    final node = nodes[sliceIndex];
    String snippet = node.text.trim();
    if (snippet.length > 60) snippet = "${snippet.substring(0, 60)}...";

    String chapTitle = "正文片段";
    for (int i = alignedChapters.length - 1; i >= 0; i--) {
      if (alignedChapters[i].paragraphIndex <= sliceIndex) {
        chapTitle = alignedChapters[i].title;
        break;
      }
    }

    final newBookmark = BookBookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookFingerprint: currentFingerprint!,
      paragraphIndex: sliceIndex,
      charOffset: node.startOffset,
      chapterTitle: chapTitle,
      content: snippet,
      createTime: DateTime.now().millisecondsSinceEpoch,
    );

    bookmarks.insert(0, newBookmark);
    notifyListeners();
    saveSettings();

    AppToast.show(
      "🔖 已在「$chapTitle」添加书签",
      duration: const Duration(seconds: 2),
      actionLabel: "查看书签",
      onAction: onOpenBookmarksDrawer,
    );
  }

  void updateBookmark(BookBookmark bm, String newContent, String newNote) {
    bm.content = newContent;
    bm.note = newNote;
    notifyListeners();
    saveSettings();
  }

  void deleteBookmark(BookBookmark bm) {
    bookmarks.removeWhere((b) => b.id == bm.id);
    notifyListeners();
    saveSettings();
    AppToast.show("书签已移除");
  }

  // ────────── 书籍加载与重切片 ──────────
  Future<void> switchSplitAndMerge(String newMode, int newMergeMinChars) async {
    final bool changed = (splitMode != newMode) || (mergeMinChars != newMergeMinChars);
    if (!changed) return;

    splitMode = newMode;
    mergeMinChars = newMergeMinChars.clamp(0, 120);

    if (fullContent.isEmpty) {
      await saveSettings();
      notifyListeners();
      return;
    }

    int currentAnchorOffset = 0;
    if (nodes.isNotEmpty && currentIndex < nodes.length) {
      currentAnchorOffset = nodes[currentIndex].startOffset;
    }

    final res = await BookParser.resliceInIsolate(fullContent, rawChapters, splitMode, mergeMinChars);
    final List<BookParagraph> newParas = res['paragraphs'];
    final List<TextSliceNode> newNodes = res['nodes'];
    final List<BookChapter> aligned = res['alignedChapters'];
    final int newIndex = BookParser.findIndexByCharOffset(newNodes, currentAnchorOffset);

    AppLogger.log("重切片完成 [模式:$splitMode, 合并:${mergeMinChars}字, 锚点:$currentAnchorOffset -> #$newIndex/${newNodes.length}]", null, null, true);

    paragraphs = newParas;
    nodes = newNodes;
    alignedChapters = aligned;
    currentIndex = newIndex;
    invalidateAudioCache();

    notifyListeners();
    await saveSettings();
    await saveHistoryToPrefs(immediate: true);
    onScrollToParaRequest?.call(activeParagraphIndex, immediate: true, force: true);
    if (isPlaying) startTTS();
  }

  Future<bool> openBook(
    String path, {
    required VoidCallback onStartLoading,
    required VoidCallback onEndLoading,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      AppToast.show('文件不存在或无法访问：\n$path', isError: true);
      return false;
    }

    lastBookDir = file.parent.path;
    saveSettings();
    await stopTTS();
    await saveHistoryToPrefs(immediate: true);

    onStartLoading();

    try {
      String? cacheDirPath;
      try {
        final tmp = await getTemporaryDirectory();
        cacheDirPath = '${tmp.path}${Platform.pathSeparator}parsed_books_cache';
      } catch (_) {}

      final res = await BookParser.openBookInIsolate(
        path,
        splitMode,
        mergeMinChars,
        cacheDirPath: cacheDirPath,
      );
      onEndLoading();

      final String fp = res['fingerprint'];
      final String full = res['fullContent'];
      final List<BookChapter> rawChaps = res['rawChapters'];
      final List<BookChapter> aligned = res['alignedChapters'];
      final List<BookParagraph> newParas = res['paragraphs'];
      final List<TextSliceNode> newNodes = res['nodes'];
      final int size = res['fileSize'];
      final bool fromCache = res['fromCache'] == true;
      final String name = path.split(Platform.pathSeparator).last;

      int startIdx = 0;
      if (history.containsKey(fp)) {
        final saved = history[fp]!;
        saved.lastKnownPath = path;
        startIdx = BookParser.findIndexByCharOffset(newNodes, saved.charOffset);
      }

      AppLogger.log(
        "电子书装载成功${fromCache ? ' (缓存秒开)' : ''}: $name [大小:${formatFileSize(size)}, 章节:${rawChaps.length}, 段落:${newParas.length}, TTS切片:${newNodes.length}, 断点:#$startIdx]",
        null,
        null,
        true,
      );

      currentFingerprint = fp;
      currentFilePath = path;
      currentBookName = name;
      fullContent = full;
      fileSize = size;
      rawChapters = rawChaps;
      alignedChapters = aligned;
      paragraphs = newParas;
      nodes = newNodes;
      currentIndex = startIdx;

      invalidateAudioCache();
      clearSearch(notify: false);
      notifyListeners();

      await saveHistoryToPrefs(immediate: true);
      if (followAlong) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onScrollToParaRequest?.call(activeParagraphIndex, immediate: true, force: true);
        });
      }
      return true;
    } catch (e, stack) {
      AppLogger.log("解析电子书失败: $path", e, stack);
      onEndLoading();
      AppToast.show('打开文件失败: $e', isError: true);
      return false;
    }
  }

  // ────────── 播放核心状态机 (即时 Abort + 3次退避重试 + Peek缓存) ──────────
  Future<Uint8List> _synthesize(String text, {TtsCancelToken? cancelToken}) {
    return synthesizeWithEngine(
      engineId: currentEngine,
      text: text,
      voiceId: selectedVoiceId,
      speed: speechRate,
      bitrate: bitrate,
      timeoutSeconds: timeoutSeconds,
      fishTts: fishTts,
      customEngines: customEngines,
      networkRouter: networkRouter,
      cancelToken: cancelToken,
    );
  }

  void _schedulePrefetchFrom(int startIndex, int epoch) {
    for (int i = 1; i <= preloadCount; i++) {
      final target = startIndex + i;
      if (target >= nodes.length) break;
      if (_audioCache.containsKey(target) || _inFlightPrefetch.containsKey(target)) continue;

      final future = _synthesize(nodes[target].text);
      _inFlightPrefetch[target] = future;
      future.then((bytes) {
        _inFlightPrefetch.remove(target);
        if (epoch == _cacheEpoch) {
          _putAudioCache(target, bytes);
          AppLogger.log("预读入池 [#$target, 缓存:${_audioCache.length}/$maxCacheCount]");
        }
      }).catchError((_) {
        _inFlightPrefetch.remove(target);
      });
    }
  }

  void startTTS() {
    if (nodes.isEmpty) return;
    _activeCancelToken?.cancel();
    _activeCancelToken = null;

    _playSessionId++;
    AppLogger.log("朗读启动 [会话:#$_playSessionId, 切片:#$currentIndex, 引擎:$currentEngine, 音色:$selectedVoiceId, 语速:${speechRate}x]", null, null, true);
    isPlaying = true;
    isBuffering = true;
    _pausedByInterruption = false;
    notifyListeners();
    _runTTSLoop(_playSessionId);
  }

  Future<void> stopTTS() async {
    _playSessionId++;
    _activeCancelToken?.cancel();
    _activeCancelToken = null;
    AppLogger.log("朗读停止 [会话:#$_playSessionId]", null, null, true);
    isPlaying = false;
    isBuffering = false;
    notifyListeners();
    await audioPlayer.stop();
    await saveHistoryToPrefs(immediate: true);
  }

  void togglePlayPause() {
    if (isPlaying) {
      stopTTS();
    } else {
      startTTS();
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

    sub = audioPlayer.playerStateStream.listen(
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
    while (myId == _playSessionId && currentIndex < nodes.length) {
      if (sleepStopAfterChapter && alignedChapters.isNotEmpty) {
        for (var c in alignedChapters) {
          if (c.paragraphIndex == currentIndex && currentIndex != 0) {
            AppLogger.log("已达章节末尾，触发章节定时停止: ${c.title}", null, null, true);
            await stopTTS();
            sleepStopAfterChapter = false;
            notifyListeners();
            AppToast.show('已达章节末尾，定时停止播放');
            return;
          }
        }
      }

      if (followAlong) {
        onScrollToParaRequest?.call(activeParagraphIndex, immediate: false, force: false);
      }

      final int epochAtStart = _cacheEpoch;
      Uint8List? audioBytes = _peekAudioCache(currentIndex);

      if (audioBytes == null) {
        if (!isBuffering) {
          isBuffering = true;
          notifyListeners();
        }

        Object? lastErr;
        for (int attempt = 0; attempt < 3; attempt++) {
          if (myId != _playSessionId || epochAtStart != _cacheEpoch) break;
          final token = TtsCancelToken();
          _activeCancelToken = token;

          try {
            final inFlight = (attempt == 0) ? _inFlightPrefetch[currentIndex] : null;
            if (inFlight != null) {
              audioBytes = await inFlight;
            } else {
              audioBytes = await _synthesize(nodes[currentIndex].text, cancelToken: token);
            }
            if (myId == _playSessionId && epochAtStart == _cacheEpoch && audioBytes != null) {
              _putAudioCache(currentIndex, audioBytes);
            }
            lastErr = null;
            break;
          } on TtsCancelledException {
            return;
          } catch (e) {
            lastErr = e;
            if (myId != _playSessionId) return;
            AppLogger.log("单句合成异常 [#$currentIndex, 第${attempt + 1}次]", e);
            if (attempt < 2) {
              await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
            }
          } finally {
            if (identical(_activeCancelToken, token)) {
              _activeCancelToken = null;
            }
          }
        }

        if (lastErr != null || audioBytes == null) {
          if (myId == _playSessionId) {
            await stopTTS();
            AppToast.show('合成中断（经重试仍失败）: $lastErr', isError: true);
          }
          break;
        }
      }

      if (myId != _playSessionId) break;
      if (epochAtStart != _cacheEpoch) continue;

      _schedulePrefetchFrom(currentIndex, _cacheEpoch);

      if (isBuffering) {
        isBuffering = false;
        notifyListeners();
      }

      try {
        await audioPlayer.stop();
        await audioPlayer.setAudioSource(MemoryAudioSource(audioBytes));
        await audioPlayer.play();
      } catch (_) {
        try {
          final tempDir = await getTemporaryDirectory();
          final bufferFile = File("${tempDir.path}${Platform.pathSeparator}single_play_buffer_${currentIndex % 2}.mp3");
          await bufferFile.writeAsBytes(audioBytes, flush: true);
          await audioPlayer.setFilePath(bufferFile.path);
          await audioPlayer.play();
        } catch (fileErr) {
          AppLogger.log("音频播放驱动失败", fileErr);
          if (myId == _playSessionId) {
            await stopTTS();
            AppToast.show('音频解码失败: $fileErr', isError: true);
          }
          break;
        }
      }

      if (myId != _playSessionId) break;
      await _waitPlayerCompletedOrCancelled(myId);
      if (myId != _playSessionId) break;

      if (currentIndex + 1 >= nodes.length) {
        AppLogger.log("全书朗读完毕", null, null, true);
        await stopTTS();
        AppToast.show('🎉 已读完全书');
        break;
      }

      currentIndex++;
      notifyListeners();
      saveHistoryToPrefs();

      if (intervalPauseMs > 0) {
        await Future.delayed(Duration(milliseconds: intervalPauseMs));
      }
    }
  }

  // ────────── 跳转、语速与定时控制 ──────────
  void seekTo(int target) {
    if (nodes.isEmpty) return;
    currentIndex = target.clamp(0, nodes.length - 1);
    notifyListeners();
    saveHistoryToPrefs();
    onScrollToParaRequest?.call(activeParagraphIndex, immediate: false, force: true);
    if (isPlaying) startTTS();
  }

  void jumpToSliceAndPlay(int target) {
    if (nodes.isEmpty) return;
    currentIndex = target.clamp(0, nodes.length - 1);
    notifyListeners();
    saveHistoryToPrefs();
    startTTS();
  }

  void jumpSentence(int step) {
    if (nodes.isEmpty) return;
    final int target = currentIndex + step;
    if (target >= 0 && target < nodes.length) {
      AppLogger.log("跳句 [#$currentIndex -> #$target]");
      currentIndex = target;
      notifyListeners();
      saveHistoryToPrefs();
      if (followAlong) {
        onScrollToParaRequest?.call(activeParagraphIndex, immediate: false, force: false);
      }
      if (isPlaying) startTTS();
    }
  }

  void jumpToPrevChapter() {
    if (alignedChapters.isEmpty) return;
    for (int i = alignedChapters.length - 1; i >= 0; i--) {
      if (alignedChapters[i].paragraphIndex < currentIndex - 1) {
        seekTo(alignedChapters[i].paragraphIndex);
        return;
      }
    }
    seekTo(0);
  }

  void jumpToNextChapter() {
    if (alignedChapters.isEmpty) return;
    for (int i = 0; i < alignedChapters.length; i++) {
      if (alignedChapters[i].paragraphIndex > currentIndex) {
        seekTo(alignedChapters[i].paragraphIndex);
        return;
      }
    }
  }

  void cycleSpeechRate() {
    final int nextIdx = (speedOptions.indexOf(speechRate) + 1) % speedOptions.length;
    speechRate = speedOptions[nextIdx];
    invalidateAudioCache();
    notifyListeners();
    saveSettings();
    if (isPlaying) startTTS();
  }

  void toggleFollowAlong() {
    followAlong = !followAlong;
    notifyListeners();
    saveSettings();
  }

  void startSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    sleepStopAfterChapter = false;
    sleepTimeLeftSeconds = minutes * 60;
    notifyListeners();
    AppLogger.log("启动睡眠定时: $minutes 分钟倒计时", null, null, true);
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (sleepTimeLeftSeconds > 0) {
        sleepTimeLeftSeconds--;
        notifyListeners();
      } else {
        t.cancel();
        AppLogger.log("睡眠定时倒计时归零，自动执行暂停", null, null, true);
        stopTTS();
      }
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    sleepStopAfterChapter = false;
    sleepTimeLeftSeconds = 0;
    notifyListeners();
  }

  void setStopAfterChapter() {
    _sleepTimer?.cancel();
    sleepStopAfterChapter = true;
    sleepTimeLeftSeconds = 0;
    notifyListeners();
    AppLogger.log("设定为: 读完本章后自动暂停", null, null, true);
  }

  // ────────── 后台 Isolate 全文搜索 (支持跨句匹配) ──────────
  Future<void> executeSearch(String q, {bool showEmptyTip = true}) async {
    final text = q.trim().toLowerCase();
    final mySeq = ++_searchSeq;

    if (text.isEmpty) {
      clearSearch();
      return;
    }

    isSearchBusy = true;
    notifyListeners();

    final hits = await BookParser.searchInIsolate(fullContent, text, nodes, paragraphs);
    if (mySeq != _searchSeq) return;

    isSearchBusy = false;
    activeSearchQuery = text;
    searchHits = hits;
    matchedParagraphIndices = hits.map((h) => h.paraIndex).toSet();
    currentSearchMatchIndex = 0;
    notifyListeners();

    if (hits.isNotEmpty) {
      navigateToMatch(0);
    } else if (showEmptyTip) {
      AppToast.show("未找到匹配文本", duration: const Duration(milliseconds: 1400));
    }
  }

  void navigateToMatch(int targetMatchIndex) {
    if (searchHits.isEmpty) return;
    int valid = targetMatchIndex % searchHits.length;
    if (valid < 0) valid += searchHits.length;

    final hit = searchHits[valid];
    currentSearchMatchIndex = valid;
    currentIndex = hit.sliceIndex;
    notifyListeners();

    onScrollToParaRequest?.call(hit.paraIndex, immediate: false, force: true);
    saveHistoryToPrefs();
  }

  void clearSearch({bool closeBar = false, bool notify = true}) {
    _searchSeq++;
    if (closeBar) isSearching = false;
    isSearchBusy = false;
    activeSearchQuery = "";
    searchHits = [];
    matchedParagraphIndices = {};
    currentSearchMatchIndex = 0;
    if (notify) notifyListeners();
  }

  // ────────── 容错型全量备份与恢复 ──────────
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
        if (k != null && v != null) result[k.toString()] = v.toString();
      });
    }
    return result;
  }

  Future<String?> exportBackup() async {
    try {
      if (!await StorageHelper.checkAndRequestManagePermission()) return null;
      final targetFolder = Directory(lastBackupDir);
      if (!await targetFolder.exists()) await targetFolder.create(recursive: true);

      final dateStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File('${targetFolder.path}${Platform.pathSeparator}fish_reader_backup_$dateStr.json');

      final data = {
        'version': 9,
        'engineType': currentEngine,
        'fishApiKey': apiKey,
        'fishModel': fishModel,
        'selectedVoice': selectedVoiceId,
        'speechRate': speechRate,
        'bitrate': bitrate,
        'timeoutSeconds': timeoutSeconds,
        'preloadCount': preloadCount,
        'exportThreads': exportThreads,
        'intervalPauseMs': intervalPauseMs,
        'maxCacheCount': maxCacheCount,
        'engineNetworkModes': networkRouter.engineNetworkModes,
        'engineCustomProxies': networkRouter.engineCustomProxies,
        'ignoreBadCert': networkRouter.ignoreBadCertificate,
        'customEngines': customEngines.map((e) => e.toJson()).toList(),
        'followAlong': followAlong,
        'splitMode': splitMode,
        'mergeMinChars': mergeMinChars,
        'font_size_v2': fontSize,
        'lineHeight': lineHeight,
        'horizontalPadding': horizontalPadding,
        'themeId': themeId,
        'log_level': AppLogger.logLevel,
        'lastBookDir': lastBookDir,
        'lastBackupDir': lastBackupDir,
        'lastMp3Dir': lastMp3Dir,
        'fishVoices': userFishVoices,
        'msVoices': userMsVoices,
        'pinnedVoices': pinnedVoiceIds,
        'bookmarks': bookmarks.map((e) => e.toJson()).toList(),
        'history': history.map((k, v) => MapEntry(k, v.toJson())),
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);

      AppLogger.log("全量备份落盘成功: ${file.path}", null, null, true);
      return file.path;
    } catch (e, stack) {
      AppLogger.log("导出备份失败", e, stack);
      AppToast.show('导出备份失败: $e', isError: true);
      return null;
    }
  }

  Future<Map<String, dynamic>?> restoreBackupFromFile(String path) async {
    try {
      await StorageHelper.checkAndRequestManagePermission(allowSettingsJump: false);
      final file = File(path);
      if (!await file.exists()) {
        AppToast.show('备份文件不存在: $path', isError: true);
        return null;
      }

      final parentPath = file.parent.path;
      if (!parentPath.contains('/cache/') && !parentPath.contains('file_picker')) {
        lastBackupDir = parentPath;
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        AppToast.show('无效的备份文件格式', isError: true);
        return null;
      }
      final data = Map<String, dynamic>.from(decoded);

      final String prevSplitMode = splitMode;
      final int prevMergeMinChars = mergeMinChars;

      final restoredFishVoices = _parseStringMap(data['fishVoices'] ?? data['custom_user_fish_voices']);
      final restoredMsVoices = _parseStringMap(data['msVoices'] ?? data['custom_user_ms_voices']);

      final List<CustomTtsEngineConfig> restoredCustomEngines = [];
      final rawCustom = data['customEngines'] ?? data['custom_tts_engines_v1'];
      if (rawCustom is List) {
        for (final item in rawCustom) {
          if (item is Map) restoredCustomEngines.add(CustomTtsEngineConfig.fromJson(Map<String, dynamic>.from(item)));
        }
      }

      final String restoredEngine = (data['engineType'] ?? currentEngine).toString();
      final String restoredApiKey = (data['fishApiKey'] ?? data['apiKey'] ?? data['fish_api_key'] ?? apiKey).toString().trim();
      final String rawFishModel = (data['fishModel'] ?? fishModel).toString();
      final String restoredFishModel = fishModelOptions.contains(rawFishModel) ? rawFishModel : fishModelOptions.first;
      final String restoredVoice = (data['selectedVoice'] ?? selectedVoiceId).toString();

      final double restoredRate = _parseDouble(data['speechRate'], speechRate).clamp(0.5, 2.5);
      final int restoredBitrate = _parseInt(data['bitrate'], bitrate) == 128 ? 128 : 64;
      final int restoredTimeout = _parseInt(data['timeoutSeconds'], timeoutSeconds).clamp(20, 120);
      final int restoredPreload = _parseInt(data['preloadCount'] ?? data['preload_count'], preloadCount).clamp(1, 15);
      final int restoredThreads = _parseInt(data['exportThreads'] ?? data['export_threads'], exportThreads).clamp(1, 16);
      final int restoredInterval = _parseInt(data['intervalPauseMs'], intervalPauseMs).clamp(0, 1500);
      final int restoredMaxCache = _parseInt(data['maxCacheCount'], maxCacheCount).clamp(50, 300);
      final bool restoredFollow = _parseBool(data['followAlong'], followAlong);
      final String restoredSplit = (data['splitMode'] ?? splitMode).toString() == 'paragraph' ? 'paragraph' : 'sentence';
      final int restoredMerge = _parseInt(data['mergeMinChars'] ?? data['merge_min_chars'], mergeMinChars).clamp(0, 120);

      final double restoredFont = _parseDouble(data['font_size_v2'] ?? data['font_size'] ?? data['fontSize'], fontSize).clamp(10.0, 20.0);
      final double restoredLineHeight = _parseDouble(data['lineHeight'] ?? data['line_height_v1'], lineHeight).clamp(1.4, 2.2);
      final double restoredPadding = _parseDouble(data['horizontalPadding'] ?? data['horizontal_padding_v1'], horizontalPadding).clamp(8.0, 40.0);
      final String restoredThemeId = ReaderThemeConfig.byId((data['themeId'] ?? themeId).toString()).id;
      final bool restoredIgnoreCert = _parseBool(data['ignoreBadCert'], networkRouter.ignoreBadCertificate);
      final String restoredLogLevel = AppLogger.normalizeLevel((data['log_level'] ?? data['logLevel'])?.toString());

      final Map<String, String> restoredRoutes = {'ms': 'direct', 'fish': 'direct'};
      final Map<String, String> restoredProxies = {};

      final rawNetModes = data['engineNetworkModes'] ?? data['engine_network_modes'];
      if (rawNetModes is Map) {
        rawNetModes.forEach((k, v) {
          restoredRoutes[k.toString()] = normalizeEngineNetworkMode(v?.toString());
        });
      }
      final rawCustomProxies = data['engineCustomProxies'] ?? data['engine_custom_proxies'];
      if (rawCustomProxies is Map) {
        rawCustomProxies.forEach((k, v) {
          final norm = normalizeProxyInput(v?.toString() ?? '');
          if (norm.isNotEmpty) restoredProxies[k.toString()] = norm;
        });
      }

      final String restoredBookDir = (data['lastBookDir'] ?? lastBookDir).toString();
      final String restoredBackupDir = (data['lastBackupDir'] ?? lastBackupDir).toString();
      final String restoredMp3Dir = (data['lastMp3Dir'] ?? lastMp3Dir).toString();

      final List<String> restoredPins = (data['pinnedVoices'] is List)
          ? (data['pinnedVoices'] as List).map((e) => e.toString()).toList()
          : pinnedVoiceIds;

      final List<BookBookmark> restoredBookmarks = [];
      if (data['bookmarks'] is List) {
        for (final item in (data['bookmarks'] as List)) {
          if (item is Map) restoredBookmarks.add(BookBookmark.fromJson(Map<String, dynamic>.from(item)));
        }
      }

      final Map<String, BookHistoryItem> restoredHistory = {};
      if (data['history'] is Map) {
        (data['history'] as Map).forEach((k, v) {
          if (v is Map) restoredHistory[k.toString()] = BookHistoryItem.fromJson(Map<String, dynamic>.from(v));
        });
      }

      if (restoredFishVoices.isNotEmpty) userFishVoices = restoredFishVoices;
      if (restoredMsVoices.isNotEmpty) userMsVoices = restoredMsVoices;
      customEngines = restoredCustomEngines;
      pinnedVoiceIds = restoredPins;

      currentEngine = restoredEngine;
      apiKey = restoredApiKey;
      fishModel = restoredFishModel;
      selectedVoiceId = restoredVoice;

      speechRate = restoredRate;
      bitrate = restoredBitrate;
      timeoutSeconds = restoredTimeout;
      preloadCount = restoredPreload;
      exportThreads = restoredThreads;
      intervalPauseMs = restoredInterval;
      maxCacheCount = restoredMaxCache;
      followAlong = restoredFollow;
      splitMode = restoredSplit;
      mergeMinChars = restoredMerge;

      fontSize = restoredFont;
      lineHeight = restoredLineHeight;
      horizontalPadding = restoredPadding;
      themeId = restoredThemeId;
      networkRouter.setIgnoreBadCert(restoredIgnoreCert);
      AppLogger.logLevel = restoredLogLevel;

      if (restoredBookDir.isNotEmpty) lastBookDir = restoredBookDir;
      if (restoredBackupDir.isNotEmpty && !restoredBackupDir.contains('/cache/')) lastBackupDir = restoredBackupDir;
      if (restoredMp3Dir.isNotEmpty) lastMp3Dir = restoredMp3Dir;

      bookmarks = restoredBookmarks;
      if (restoredHistory.isNotEmpty) history = restoredHistory;

      networkRouter.engineNetworkModes.clear();
      networkRouter.engineCustomProxies.clear();
      restoredRoutes.forEach((k, v) {
        networkRouter.setEngineNetwork(k, v, restoredProxies[k] ?? '');
      });
      for (final c in customEngines) {
        networkRouter.setEngineNetwork(c.id, c.networkMode, c.customProxy);
      }

      fishTts = FishAudioTTS(apiKey: apiKey, voices: userFishVoices, model: fishModel);
      ensureValidSelectedEngineAndVoice();
      invalidateAudioCache();

      await networkRouter.refreshSystemProxy();
      await saveSettings();
      await saveHistoryToPrefs(immediate: true);

      if (fullContent.isNotEmpty && (prevSplitMode != splitMode || prevMergeMinChars != mergeMinChars)) {
        final targetOffset = (nodes.isNotEmpty && currentIndex < nodes.length) ? nodes[currentIndex].startOffset : 0;
        final res = await BookParser.resliceInIsolate(fullContent, rawChapters, splitMode, mergeMinChars);
        paragraphs = res['paragraphs'];
        nodes = res['nodes'];
        alignedChapters = res['alignedChapters'];
        currentIndex = BookParser.findIndexByCharOffset(nodes, targetOffset);
        onScrollToParaRequest?.call(activeParagraphIndex, immediate: true, force: true);
      }

      notifyListeners();
      AppLogger.log("备份恢复完成 [书架:${history.length}本, 书签:${bookmarks.length}条]", null, null, true);

      return {
        'engine': currentEngine,
        'apiKey': apiKey,
        'preloadCount': preloadCount,
        'exportThreads': exportThreads,
        'fontSize': fontSize,
        'mergeMinChars': mergeMinChars,
        'logLevel': AppLogger.logLevel,
        'customCount': customEngines.length,
        'historyCount': history.length,
        'bookmarkCount': bookmarks.length,
      };
    } catch (e, stack) {
      AppLogger.log("恢复备份失败: $path", e, stack);
      AppToast.show('恢复失败: $e', isError: true);
      return null;
    }
  }

  @override
  void dispose() {
    _noisySub?.cancel();
    _interruptionSub?.cancel();
    _historyFlushTimer?.cancel();
    _sleepTimer?.cancel();
    _activeCancelToken?.cancel();
    saveHistoryToPrefs(immediate: true);
    networkRouter.dispose();
    audioPlayer.dispose();
    super.dispose();
  }
}
