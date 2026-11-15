import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

// ────────────────── 基础常数与发音人字典 ──────────────────
const List<double> speedOptions = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
const List<String> fishModelOptions = ['s2.1-pro-free', 's2.1-pro', 's2-pro', 'drama-3'];

const Map<String, String> defaultFishVoices = {
  'cf71d823861b4e0eadff1672d646da36': '几何女声 (知性自然)',
  'b445c7474b504a39b26f5578dd20be0e': '郭德纲 响沉',
  '188fedbaa43e40508a8fefdaddac66c6': '女播音腔 (慢速中音)',
  'a688f2129bea41d1ae6042462892ecf8': '说书人 男老 袁阔成',
  '25c485bfedd84344a8952a38813b3906': '中年男声 (速度自然)',
  'fbe02f8306fc4d3d915e9871722a39d5': '女清新明亮 (嘉岚3.0)',
  'b7daab7a1ba2481f81f8f5d0e0d0c819': '女热情快读 (广告社交)',
};

const Map<String, String> defaultMsVoices46 = {
  'zh-CN-XiaoxiaoMultilingualNeural': '晓晓多语 (双语温柔女声)',
  'zh-CN-YunxiNeural': '云希 (阳光青年·叙事主力)',
  'zh-CN-XiaoxiaoNeural': '晓晓 (温柔少女·多情感)',
  'zh-CN-YunyeNeural': '云野 (沉稳大叔·角色小说)',
  'zh-CN-YunjianNeural': '云健 (热血解说·低沉质感)',
  'zh-CN-XiaomoNeural': '晓墨 (多角色变换·细腻)',
  'zh-CN-YunzeNeural': '云泽 (纪录片·厚重长辈)',
  'zh-CN-XiaohanNeural': '晓涵 (高亮温柔·抒情女声)',
  'zh-CN-YunyangNeural': '云扬 (专业男主播·新闻质感)',
  'zh-CN-XiaoyiNeural': '晓伊 (甜亮活泼·少女校园)',
  'zh-CN-YunfengNeural': '云枫 (清朗书生·自然叙事)',
  'zh-CN-XiaoruiNeural': '晓睿 (睿智沉稳·长者播报)',
  'zh-CN-XiaoxuanNeural': '晓萱 (温婉自然·书卷质感)',
  'zh-CN-XiaoyanNeural': '晓颜 (清亮活泼·日常播读)',
  'zh-CN-XiaozhenNeural': '晓甄 (温柔亲和·故事旁白)',
  'zh-CN-YunhaoNeural': '云浩 (磁性成熟·故事旁白)',
  'zh-CN-YunxiaNeural': '云夏 (青春少年·朝气蓬勃)',
  'zh-CN-YunjieNeural': '云杰 (从容淡定·社科解说)',
  'zh-CN-XiaochenNeural': '晓辰 (清新自然·电台女声)',
  'zh-CN-XiaomengNeural': '晓梦 (梦幻柔美·睡前故事)',
  'zh-CN-XiaoshuangNeural': '晓双 (活泼萌趣·儿童角色)',
  'zh-CN-XiaozhiNeural': '晓芷 (恬静雅致·文艺叙事)',
  'zh-CN-XiaofeiNeural': '晓菲 (生动亲切·情感电台)',
  'zh-CN-XiaonuoNeural': '晓诺 (童声稚嫩·儿童故事)',
  'zh-CN-XiaoyouNeural': '晓悠 (轻快纯真·少儿读物)',
  'zh-CN-XiaolinNeural': '晓霖 (温厚大方·知识讲解)',
  'zh-CN-XiaoyuNeural': '晓羽 (轻柔治愈·抒情旁白)',
  'zh-CN-YunfengMultilingualNeural': '云枫多语 (双语小说推荐)',
  'zh-CN-liaoning-XiaobeiNeural': '晓北 (辽宁东北话)',
  'zh-CN-liaoning-YunbiaoNeural': '云彪 (辽宁东北话·男声)',
  'zh-CN-shaanxi-XiaoniNeural': '晓妮 (陕西关中方言)',
  'zh-CN-shaanxi-YunxiangNeural': '云翔 (陕西话·男声)',
  'zh-CN-sichuan-YunxiNeural': '云希 (四川话·男声)',
  'zh-CN-sichuan-XiaobaoNeural': '晓宝 (四川话·女声)',
  'zh-CN-shandong-YunxiangNeural': '云翔 (山东话·男声)',
  'zh-CN-henan-YundengNeural': '云登 (中原官话·河南话)',
  'wuu-CN-XiaotongNeural': '晓彤 (吴语上海话·女声)',
  'wuu-CN-YunzheNeural': '云哲 (吴语上海话·男声)',
  'yue-CN-XiaoMinNeural': '晓敏 (粤语广州话·女声)',
  'yue-CN-YunSongNeural': '云松 (粤语广州话·男声)',
  'zh-HK-HiuMaanNeural': '晓曼 (粤语香港话·女声)',
  'zh-HK-WanLungNeural': '云龙 (粤语香港话·男声)',
  'zh-HK-HiuGaaiNeural': '晓佳 (粤语香港话·活泼)',
  'zh-TW-HsiaoChenNeural': '曉臻 (台湾普通话)',
  'zh-TW-YunJheNeural': '雲哲 (台湾普通话·男声)',
  'zh-TW-HsiaoYuNeural': '曉雨 (台湾普通话·甜美)',
};

String formatFileSize(int bytes) {
  if (bytes <= 0) return "0 B";
  const suffixes = ["B", "KB", "MB", "GB"];
  var i = (log(bytes) / log(1024)).floor().clamp(0, suffixes.length - 1);
  return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
}

String normalizeEngineNetworkMode(String? raw) {
  if (raw == 'system' || raw == 'proxy') return 'system';
  if (raw == 'custom') return 'custom';
  return 'direct';
}

// ────────────────── 阅读器主题配置 ──────────────────
class ReaderThemeConfig {
  final String id;
  final String name;
  final Brightness brightness;
  final Color scaffoldBg;
  final Color surfaceBg;
  final Color sidebarBg;
  final Color cardBorder;
  final Color chipBg;
  final Color primaryText;
  final Color secondaryText;
  final Color accent;
  final Color highlightBg;
  final Color highlightText;
  final Color searchMatchBg;
  final Color searchMatchText;

  const ReaderThemeConfig({
    required this.id,
    required this.name,
    required this.brightness,
    required this.scaffoldBg,
    required this.surfaceBg,
    required this.sidebarBg,
    required this.cardBorder,
    required this.chipBg,
    required this.primaryText,
    required this.secondaryText,
    required this.accent,
    required this.highlightBg,
    required this.highlightText,
    required this.searchMatchBg,
    required this.searchMatchText,
  });

  static const ReaderThemeConfig parchment = ReaderThemeConfig(
    id: 'parchment',
    name: '羊皮纸',
    brightness: Brightness.light,
    scaffoldBg: Color(0xFFF6F4EC),
    surfaceBg: Color(0xFFFCFBF7),
    sidebarBg: Color(0xFFF0EDE4),
    cardBorder: Color(0xFFE5E2D9),
    chipBg: Color(0xFFF3EEE1),
    primaryText: Color(0xFF2D2E2F),
    secondaryText: Color(0xFF607D8B),
    accent: Color(0xFFC87D2E),
    highlightBg: Color(0xFFEFE2C3),
    highlightText: Color(0xFF743C00),
    searchMatchBg: Color(0xFFFFD54F),
    searchMatchText: Color(0xFF4A2500),
  );

  static const ReaderThemeConfig green = ReaderThemeConfig(
    id: 'green',
    name: '护眼绿',
    brightness: Brightness.light,
    scaffoldBg: Color(0xFFE3EDCD),
    surfaceBg: Color(0xFFECF4DC),
    sidebarBg: Color(0xFFDCE8C4),
    cardBorder: Color(0xFFC9D9AE),
    chipBg: Color(0xFFD9E6BE),
    primaryText: Color(0xFF24331E),
    secondaryText: Color(0xFF53694D),
    accent: Color(0xFF3E7B38),
    highlightBg: Color(0xFFC8DFA6),
    highlightText: Color(0xFF1D4D18),
    searchMatchBg: Color(0xFFFFE082),
    searchMatchText: Color(0xFF3B2800),
  );

  static const ReaderThemeConfig dark = ReaderThemeConfig(
    id: 'dark',
    name: '深邃夜',
    brightness: Brightness.dark,
    scaffoldBg: Color(0xFF16181A),
    surfaceBg: Color(0xFF1F2226),
    sidebarBg: Color(0xFF1A1C1F),
    cardBorder: Color(0xFF2E3238),
    chipBg: Color(0xFF282C32),
    primaryText: Color(0xFFD2D5D9),
    secondaryText: Color(0xFF8B949E),
    accent: Color(0xFFDF9B4F),
    highlightBg: Color(0xFF3D301C),
    highlightText: Color(0xFFFFD79A),
    searchMatchBg: Color(0xFF7D5D00),
    searchMatchText: Color(0xFFFFF3CC),
  );

  static const ReaderThemeConfig white = ReaderThemeConfig(
    id: 'white',
    name: '极简白',
    brightness: Brightness.light,
    scaffoldBg: Color(0xFFFFFFFF),
    surfaceBg: Color(0xFFF9F9FB),
    sidebarBg: Color(0xFFF3F4F6),
    cardBorder: Color(0xFFE5E7EB),
    chipBg: Color(0xFFF1F3F5),
    primaryText: Color(0xFF1F2328),
    secondaryText: Color(0xFF656D76),
    accent: Color(0xFFB56A1E),
    highlightBg: Color(0xFFFFF0D4),
    highlightText: Color(0xFF6B3700),
    searchMatchBg: Color(0xFFFFD54F),
    searchMatchText: Color(0xFF4A2500),
  );

  static const List<ReaderThemeConfig> presets = [parchment, green, dark, white];

  static ReaderThemeConfig byId(String? id) {
    for (final t in presets) {
      if (t.id == id) return t;
    }
    return parchment;
  }
}

// ────────────────── 自定义 TTS 引擎模型 ──────────────────
class CustomTtsEngineConfig {
  final String id;
  String name;
  String method; // POST / GET
  String url; // 支持模板变量 {{text_url}}, {{voice}}, {{speed}}, {{bitrate}}, {{api_key}}
  Map<String, String> headers;
  String bodyTemplate; // 支持 {{text_json}}, {{text_xml}}, {{text}}, {{voice}}, {{speed}}, {{rate_percent}}, {{bitrate}}, {{api_key}}
  String responseType; // 'raw_bytes' | 'json_base64' | 'json_url'
  String jsonPath; // 例: choices[0].message.audio.data
  String apiKey;
  Map<String, String> voices; // voiceId -> displayName
  String networkMode; // 'direct' | 'system' | 'custom'
  String customProxy;
  bool ignoreBadCert;
  String testText;

  CustomTtsEngineConfig({
    required this.id,
    required this.name,
    this.method = 'POST',
    required this.url,
    Map<String, String>? headers,
    this.bodyTemplate = '',
    this.responseType = 'raw_bytes',
    this.jsonPath = '',
    this.apiKey = '',
    Map<String, String>? voices,
    this.networkMode = 'direct',
    this.customProxy = '',
    this.ignoreBadCert = false,
    this.testText = '',
  })  : headers = headers ?? {'Content-Type': 'application/json'},
        voices = (voices == null || voices.isEmpty) ? {'default': '默认音色'} : voices;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'method': method,
        'url': url,
        'headers': headers,
        'bodyTemplate': bodyTemplate,
        'responseType': responseType,
        'jsonPath': jsonPath,
        'apiKey': apiKey,
        'voices': voices,
        'networkMode': networkMode,
        'customProxy': customProxy,
        'ignoreBadCert': ignoreBadCert,
        'testText': testText,
      };

  factory CustomTtsEngineConfig.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    final headersMap = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headersMap[k.toString()] = v.toString());
    }
    final rawVoices = json['voices'];
    final voicesMap = <String, String>{};
    if (rawVoices is Map) {
      rawVoices.forEach((k, v) => voicesMap[k.toString()] = v.toString());
    }
    return CustomTtsEngineConfig(
      id: (json['id'] as String?)?.isNotEmpty == true ? json['id'] as String : 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: (json['name'] as String?)?.isNotEmpty == true ? json['name'] as String : '自定义TTS引擎',
      method: (json['method'] as String?)?.toUpperCase() == 'GET' ? 'GET' : 'POST',
      url: json['url'] as String? ?? '',
      headers: headersMap,
      bodyTemplate: json['bodyTemplate'] as String? ?? '',
      responseType: json['responseType'] as String? ?? 'raw_bytes',
      jsonPath: json['jsonPath'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      voices: voicesMap.isEmpty ? {'default': '默认音色'} : voicesMap,
      networkMode: normalizeEngineNetworkMode(json['networkMode']?.toString()),
      customProxy: json['customProxy'] as String? ?? '',
      ignoreBadCert: json['ignoreBadCert'] == true,
      testText: json['testText'] as String? ?? '',
    );
  }

  String toPrettyCode() => const JsonEncoder.withIndent('  ').convert(toJson());

  CustomTtsEngineConfig copyWith({String? id}) {
    return CustomTtsEngineConfig(
      id: id ?? this.id,
      name: name,
      method: method,
      url: url,
      headers: Map<String, String>.from(headers),
      bodyTemplate: bodyTemplate,
      responseType: responseType,
      jsonPath: jsonPath,
      apiKey: apiKey,
      voices: Map<String, String>.from(voices),
      networkMode: networkMode,
      customProxy: customProxy,
      ignoreBadCert: ignoreBadCert,
      testText: testText,
    );
  }
}

// ────────────────── 核心历史与文本结构模型 ──────────────────
class BookHistoryItem {
  final String fingerprint;
  String lastKnownPath;
  String bookName;
  int lastIndex;
  int charOffset;
  String textSnippet;
  double percentage;
  String splitMode;
  int lastReadTime;
  int fileSize;

  BookHistoryItem({
    required this.fingerprint,
    required this.lastKnownPath,
    required this.bookName,
    required this.lastIndex,
    required this.charOffset,
    required this.textSnippet,
    required this.percentage,
    required this.splitMode,
    required this.lastReadTime,
    this.fileSize = 0,
  });

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'lastKnownPath': lastKnownPath,
        'bookName': bookName,
        'lastIndex': lastIndex,
        'charOffset': charOffset,
        'textSnippet': textSnippet,
        'percentage': percentage,
        'splitMode': splitMode,
        'lastReadTime': lastReadTime,
        'fileSize': fileSize,
      };

  factory BookHistoryItem.fromJson(Map<String, dynamic> json) => BookHistoryItem(
        fingerprint: json['fingerprint'] as String? ?? '',
        lastKnownPath: json['lastKnownPath'] as String? ?? '',
        bookName: json['bookName'] as String? ?? '未命名书籍',
        lastIndex: (json['lastIndex'] as num?)?.toInt() ?? 0,
        charOffset: (json['charOffset'] as num?)?.toInt() ?? 0,
        textSnippet: json['textSnippet'] as String? ?? '',
        percentage: ((json['percentage'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
        splitMode: json['splitMode'] as String? ?? 'sentence',
        lastReadTime: (json['lastReadTime'] as num?)?.toInt() ?? 0,
        fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      );
}

/// 自然段渲染单元（彻底告别“一句一框”割裂感）
class BookParagraph {
  final String text;
  final int startOffset;
  final int endOffset;

  const BookParagraph({
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}

/// TTS 听书切片单元（支持智能合并短句 >= X 字）
class TextSliceNode {
  final String text;
  final int startOffset;
  final int endOffset;

  const TextSliceNode({
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}

class SearchHit {
  final int charOffset;
  final int sliceIndex;
  final int paraIndex;

  const SearchHit({
    required this.charOffset,
    required this.sliceIndex,
    required this.paraIndex,
  });
}

// ────────────────── 大纲章节模型 (支持层级缩进树) ──────────────────
class BookChapter {
  final String title;
  final int paragraphIndex; // 对齐到 TextSliceNode 索引
  final int charOffset;
  final int level;

  const BookChapter({
    required this.title,
    required this.paragraphIndex,
    this.charOffset = 0,
    this.level = 0,
  });

  Map<String, dynamic> toMap() => {
        'title': title,
        'pIdx': paragraphIndex,
        'charOffset': charOffset,
        'level': level,
      };

  factory BookChapter.fromMap(Map<String, dynamic> map) => BookChapter(
        title: map['title'] ?? '',
        paragraphIndex: (map['pIdx'] as num?)?.toInt() ?? 0,
        charOffset: (map['charOffset'] as num?)?.toInt() ?? 0,
        level: (map['level'] as num?)?.toInt() ?? 0,
      );
}

// ────────────────── 精准书签模型 ──────────────────
class BookBookmark {
  final String id;
  final String bookFingerprint;
  final int paragraphIndex;
  final int charOffset;
  final String chapterTitle;
  String content;
  String note;
  final int createTime;

  BookBookmark({
    required this.id,
    required this.bookFingerprint,
    required this.paragraphIndex,
    required this.charOffset,
    required this.chapterTitle,
    required this.content,
    this.note = "",
    required this.createTime,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fp': bookFingerprint,
        'pIdx': paragraphIndex,
        'charOffset': charOffset,
        'chapterTitle': chapterTitle,
        'content': content,
        'note': note,
        'createTime': createTime,
      };

  factory BookBookmark.fromJson(Map<String, dynamic> json) => BookBookmark(
        id: json['id'] as String? ?? '',
        bookFingerprint: json['fp'] as String? ?? '',
        paragraphIndex: (json['pIdx'] as num?)?.toInt() ?? 0,
        charOffset: (json['charOffset'] as num?)?.toInt() ?? 0,
        chapterTitle: json['chapterTitle'] as String? ?? '正文片段',
        content: json['content'] as String? ?? '',
        note: json['note'] as String? ?? '',
        createTime: (json['createTime'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      );
}

class MemoryAudioSource extends StreamAudioSource {
  final Uint8List _buffer;
  MemoryAudioSource(this._buffer) : super(tag: 'MemoryAudioSource');

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _buffer.length;
    int s = start.clamp(0, _buffer.length);
    int e = end.clamp(s, _buffer.length);
    return StreamAudioResponse(
      sourceLength: _buffer.length,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(_buffer.sublist(s, e)),
      contentType: 'audio/mpeg',
    );
  }
}

Uint8List stripId3Tags(Uint8List data) {
  int start = 0;
  int end = data.length;

  if (end >= 10 && data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33) {
    int tagSize = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) | ((data[8] & 0x7F) << 7) | (data[9] & 0x7F);
    int totalHeader = 10 + tagSize;
    if (totalHeader < end) start = totalHeader;
  }

  if (end - start > 128 && data[end - 128] == 0x54 && data[end - 127] == 0x41 && data[end - 126] == 0x47) {
    end -= 128;
  }

  if (start == 0 && end == data.length) return data;
  return data.sublist(start, end);
}

// ────────────────── MP3/WAV 安全拼接清洗工具 (解决 VBR Xing 时长错乱) ──────────────────
class Mp3MergeHelper {
  static bool isWavData(Uint8List data) {
    return data.length >= 12 &&
        data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
        data[8] == 0x57 && data[9] == 0x41 && data[10] == 0x56 && data[11] == 0x45;
  }

  /// 剥离 ID3v2 / ID3v1 及首帧可能附带的 Xing / Info VBR 元数据帧，防止合并后播放器误判总时长
  static Uint8List cleanMp3Chunk(Uint8List raw) {
    final cleaned = stripId3Tags(raw);
    if (cleaned.length < 48) return cleaned;

    // 定位第一个有效的 MPEG Sync 帧头 (11 个连续 1 bit: 0xFF 0xE0)
    int frameStart = -1;
    final scanLimit = min(cleaned.length - 4, 2048);
    for (int i = 0; i < scanLimit; i++) {
      if (cleaned[i] == 0xFF && (cleaned[i + 1] & 0xE0) == 0xE0) {
        final layer = (cleaned[i + 1] >> 1) & 0x03;
        final bitrateIdx = (cleaned[i + 2] >> 4) & 0x0F;
        final srIdx = (cleaned[i + 2] >> 2) & 0x03;
        if (layer != 0 && bitrateIdx != 0x0F && srIdx != 0x03) {
          frameStart = i;
          break;
        }
      }
    }
    if (frameStart < 0) return cleaned;

    final frameLen = _calcMpegFrameSize(cleaned, frameStart);
    if (frameLen <= 0 || frameStart + frameLen > cleaned.length) {
      return frameStart > 0 ? cleaned.sublist(frameStart) : cleaned;
    }

    // 检查该首帧内是否包含 "Xing" 或 "Info" 标记
    final inspectEnd = min(frameStart + frameLen, frameStart + 64);
    bool isXingOrInfo = false;
    for (int i = frameStart + 4; i <= inspectEnd - 4; i++) {
      final b0 = cleaned[i], b1 = cleaned[i + 1], b2 = cleaned[i + 2], b3 = cleaned[i + 3];
      if ((b0 == 0x58 && b1 == 0x69 && b2 == 0x6E && b3 == 0x67) || // Xing
          (b0 == 0x49 && b1 == 0x6E && b2 == 0x66 && b3 == 0x6F)) { // Info
        isXingOrInfo = true;
        break;
      }
    }

    if (isXingOrInfo) {
      final afterXing = frameStart + frameLen;
      return afterXing < cleaned.length ? cleaned.sublist(afterXing) : Uint8List(0);
    }
    return frameStart > 0 ? cleaned.sublist(frameStart) : cleaned;
  }

  static int _calcMpegFrameSize(Uint8List b, int off) {
    if (off + 4 > b.length) return -1;
    final h1 = b[off + 1];
    final h2 = b[off + 2];
    final versionBits = (h1 >> 3) & 0x03; // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
    final layerBits = (h1 >> 1) & 0x03;   // 1=Layer III
    final bitrateIdx = (h2 >> 4) & 0x0F;
    final srIdx = (h2 >> 2) & 0x03;
    final padding = (h2 >> 1) & 0x01;

    if (versionBits == 1 || layerBits != 1 || bitrateIdx == 0 || bitrateIdx == 15 || srIdx == 3) {
      return -1;
    }

    const mpeg1Rates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
    const mpeg2Rates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
    const srTableMPEG1 = [44100, 48000, 32000];
    const srTableMPEG2 = [22050, 24000, 16000];
    const srTableMPEG25 = [11025, 12000, 8000];

    final isMpeg1 = versionBits == 3;
    final bitrate = (isMpeg1 ? mpeg1Rates[bitrateIdx] : mpeg2Rates[bitrateIdx]) * 1000;
    final sr = isMpeg1
        ? srTableMPEG1[srIdx]
        : (versionBits == 2 ? srTableMPEG2[srIdx] : srTableMPEG25[srIdx]);

    if (bitrate == 0 || sr == 0) return -1;
    final coeff = isMpeg1 ? 144 : 72;
    return (coeff * bitrate) ~/ sr + padding;
  }

  /// 兼容部分自定义引擎返回 WAV 音频的情况
  static Uint8List cleanWavChunk(Uint8List data, {required bool keepHeader}) {
    if (!isWavData(data)) return data;
    int pos = 12;
    while (pos + 8 <= data.length) {
      final isData = data[pos] == 0x64 && data[pos + 1] == 0x61 && data[pos + 2] == 0x74 && data[pos + 3] == 0x61; // 'data'
      if (isData) {
        final audioStart = pos + 8;
        return keepHeader ? data : (audioStart < data.length ? data.sublist(audioStart) : Uint8List(0));
      }
      final chunkSize = data[pos + 4] | (data[pos + 5] << 8) | (data[pos + 6] << 16) | (data[pos + 7] << 24);
      pos += 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    return keepHeader ? data : (data.length > 44 ? data.sublist(44) : Uint8List(0));
  }
}
