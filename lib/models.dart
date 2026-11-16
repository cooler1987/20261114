import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

// ────────────────── 基础常数与发音人字典 ──────────────────
const List<double> speedOptions = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
const List<String> fishModelOptions = ['s2.1-pro-free', 's2.1-pro', 's2-pro', 'drama-3'];

// ────────────────── 默认阅读配色与调色工具 (默认羊皮纸色 #D2B48C) ──────────────────
const int defaultReadingBgColorValue = 0xFFD2B48C;
const int defaultReadingHighlightColorValue = 0xFFE6CFAF;

const List<int> presetReadingBgColors = [
  0xFFD2B48C, // 经典羊皮纸 (默认)
  0xFFCDB084, // 深羊皮纸
  0xFFF6F4EC, // 象牙暖白
  0xFFE3EDCD, // 豆沙护眼绿
  0xFFDCE2F1, // 海天蓝灰
  0xFF232629, // 深夜护眼黑
];

const List<int> presetReadingHighlightColors = [
  0xFFE6CFAF, // 柔金羊皮高光 (默认)
  0xFFC29B66, // 琥珀深棕高亮
  0xFFEFE7D2, // 浅米纸高光
  0xFFCDE6C7, // 青草淡绿高亮
  0xFFFFE082, // 暖黄荧光
  0xFF3A414A, // 夜间深灰高亮
];

Color getContrastTextColor(Color background) {
  return background.computeLuminance() > 0.32
      ? const Color(0xFF241C14)
      : const Color(0xFFE6E0D6);
}

Color getHighlightTextColor(Color highlightBg) {
  return highlightBg.computeLuminance() > 0.35
      ? const Color(0xFF5A2D00)
      : const Color(0xFFFFD699);
}

Color getHighlightAccentColor(Color highlightBg) {
  return highlightBg.computeLuminance() > 0.35
      ? const Color(0xFF9C5408)
      : const Color(0xFFE09F4F);
}

String colorToHex(Color color) {
  final rgb = color.value & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color parseHexColor(String input, int fallbackValue) {
  var hex = input.trim().replaceAll('#', '').toUpperCase();
  if (hex.length == 6) {
    hex = 'FF$hex';
  }
  if (hex.length == 8) {
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed != null) return Color(parsed);
  }
  return Color(fallbackValue);
}

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

// ────────────────── 自定义 TTS 引擎模型 ──────────────────
class CustomTtsEngineConfig {
  final String id;
  String name;
  String method; // POST / GET
  String url;
  Map<String, String> headers;
  String bodyTemplate;
  String responseType; // 'raw_bytes' | 'json_base64' | 'json_url'
  String jsonPath;
  String apiKey;
  Map<String, String> voices;
  String networkMode; // 'direct' (默认) | 'system' | 'custom'
  String customProxy;

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
    final netMode = normalizeEngineNetworkMode(json['networkMode']?.toString());
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
      networkMode: netMode,
      customProxy: json['customProxy'] as String? ?? '',
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
    );
  }
}

// ────────────────── 核心历史模型 (CharOffset 锚点) ──────────────────
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

class BookParagraph {
  final String text;
  final int startOffset;
  final int endOffset;
  const BookParagraph({required this.text, required this.startOffset, required this.endOffset});
}

class TextSliceNode {
  final String text;
  final int startOffset;
  final int endOffset;
  const TextSliceNode({required this.text, required this.startOffset, required this.endOffset});
}

class SearchHit {
  final int charOffset;
  final int sliceIndex;
  final int paraIndex;
  const SearchHit({required this.charOffset, required this.sliceIndex, required this.paraIndex});
}

// ────────────────── 大纲章节模型 (支持层级缩进树) ──────────────────
class BookChapter {
  final String title;
  final int paragraphIndex;
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
        paragraphIndex: map['pIdx'] ?? 0,
        charOffset: map['charOffset'] ?? 0,
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
    if (totalHeader < end) {
      start = totalHeader;
    }
  }

  if (end - start > 128 && data[end - 128] == 0x54 && data[end - 127] == 0x41 && data[end - 126] == 0x47) {
    end -= 128;
  }

  if (start == 0 && end == data.length) return data;
  return data.sublist(start, end);
}
