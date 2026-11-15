import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models.dart';
import 'system_utils.dart';

// ────────────────── 请求级取消令牌 (切句/停止时立即 Abort 底层 Socket) ──────────────────
class TtsCancelledException implements Exception {
  @override
  String toString() => '请求已取消';
}

class TtsCancelToken {
  bool _cancelled = false;
  final List<VoidCallback> _abortHooks = [];

  bool get isCancelled => _cancelled;

  void registerAbort(VoidCallback hook) {
    if (_cancelled) {
      try {
        hook();
      } catch (_) {}
      return;
    }
    _abortHooks.add(hook);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final hook in List<VoidCallback>.from(_abortHooks)) {
      try {
        hook();
      } catch (_) {}
    }
    _abortHooks.clear();
  }
}

// ────────────────── 分引擎连接池与 3 态网络路由器 ──────────────────
class TtsNetworkRouter {
  String? detectedSystemProxy;
  Map<String, String> engineNetworkModes = {'ms': 'direct', 'fish': 'direct'};
  Map<String, String> engineCustomProxies = {};
  bool ignoreBadCertificate = false;

  HttpClient? _directRawClient;
  IOClient? _directIoClient;
  final Map<String, HttpClient> _proxyRawClients = {};
  final Map<String, IOClient> _proxyIoClients = {};

  Future<String?> refreshSystemProxy() async {
    detectedSystemProxy = await detectSystemProxy();
    AppLogger.log("系统代理探测完成: ${detectedSystemProxy ?? '未检测到系统代理'}", null, null, true);
    return detectedSystemProxy;
  }

  void setIgnoreBadCert(bool value) {
    if (ignoreBadCertificate == value) return;
    ignoreBadCertificate = value;
    _rebuildProxyClients();
  }

  void _rebuildProxyClients() {
    for (final c in _proxyIoClients.values) {
      c.close();
    }
    _proxyIoClients.clear();
    for (final c in _proxyRawClients.values) {
      c.close(force: true);
    }
    _proxyRawClients.clear();
  }

  String getEngineRoute(String engineId, [List<CustomTtsEngineConfig>? customEngines]) {
    if (customEngines != null) {
      for (final c in customEngines) {
        if (c.id == engineId) return normalizeEngineNetworkMode(c.networkMode);
      }
    }
    return normalizeEngineNetworkMode(engineNetworkModes[engineId]);
  }

  String getEngineCustomProxy(String engineId, [List<CustomTtsEngineConfig>? customEngines]) {
    if (customEngines != null) {
      for (final c in customEngines) {
        if (c.id == engineId) return normalizeProxyInput(c.customProxy);
      }
    }
    return normalizeProxyInput(engineCustomProxies[engineId] ?? '');
  }

  void setEngineNetwork(String engineId, String mode, [String customProxy = '']) {
    engineNetworkModes[engineId] = normalizeEngineNetworkMode(mode);
    final normProxy = normalizeProxyInput(customProxy);
    if (normProxy.isNotEmpty) {
      engineCustomProxies[engineId] = normProxy;
    } else if (customProxy.trim().isEmpty) {
      engineCustomProxies.remove(engineId);
    }
  }

  HttpClient _getRawProxyClient(String addr, {bool? forceIgnoreCert}) {
    final allowBad = forceIgnoreCert ?? ignoreBadCertificate;
    final key = '$addr|$allowBad';
    return _proxyRawClients.putIfAbsent(key, () {
      final raw = HttpClient();
      raw.findProxy = (_) => "PROXY $addr; DIRECT";
      raw.connectionTimeout = const Duration(seconds: 15);
      raw.idleTimeout = const Duration(seconds: 30);
      if (allowBad) {
        raw.badCertificateCallback = (_, __, ___) => true;
      }
      return raw;
    });
  }

  HttpClient _getRawDirectClient({bool forceIgnoreCert = false}) {
    if (forceIgnoreCert) {
      return _proxyRawClients.putIfAbsent('DIRECT|true', () {
        final raw = HttpClient()
          ..findProxy = ((_) => "DIRECT")
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30)
          ..badCertificateCallback = (_, __, ___) => true;
        return raw;
      });
    }
    _directRawClient ??= HttpClient()
      ..findProxy = ((_) => "DIRECT")
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    return _directRawClient!;
  }

  HttpClient getRawClientForEngine(String engineId, [List<CustomTtsEngineConfig>? customEngines]) {
    bool? engineIgnoreCert;
    if (customEngines != null) {
      for (final c in customEngines) {
        if (c.id == engineId) {
          engineIgnoreCert = c.ignoreBadCert;
          break;
        }
      }
    }

    final route = getEngineRoute(engineId, customEngines);
    if (route == 'system') {
      if (detectedSystemProxy != null && detectedSystemProxy!.isNotEmpty) {
        return _getRawProxyClient(detectedSystemProxy!, forceIgnoreCert: engineIgnoreCert);
      }
    } else if (route == 'custom') {
      final customAddr = getEngineCustomProxy(engineId, customEngines);
      if (customAddr.isNotEmpty) {
        return _getRawProxyClient(customAddr, forceIgnoreCert: engineIgnoreCert);
      }
    }
    return _getRawDirectClient(forceIgnoreCert: engineIgnoreCert ?? false);
  }

  http.Client getClientForEngine(String engineId, [List<CustomTtsEngineConfig>? customEngines]) {
    final raw = getRawClientForEngine(engineId, customEngines);
    if (identical(raw, _directRawClient)) {
      _directIoClient ??= IOClient(raw);
      return _directIoClient!;
    }
    final key = raw.hashCode.toString();
    return _proxyIoClients.putIfAbsent(key, () => IOClient(raw));
  }

  /// 支持即时中断底层连接的请求发送器
  Future<http.Response> sendRequest({
    required HttpClient rawClient,
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    List<int>? bodyBytes,
    required Duration timeout,
    TtsCancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) throw TtsCancelledException();

    HttpClientRequest? req;
    StreamSubscription<List<int>>? bodySub;
    bool aborted = false;

    final completer = Completer<http.Response>();

    void doAbort() {
      if (aborted) return;
      aborted = true;
      try {
        req?.abort();
      } catch (_) {}
      try {
        bodySub?.cancel();
      } catch (_) {}
      if (!completer.isCompleted) {
        completer.completeError(TtsCancelledException());
      }
    }

    cancelToken?.registerAbort(doAbort);

    () async {
      try {
        req = await rawClient.openUrl(method, uri).timeout(timeout);
        if (aborted || cancelToken?.isCancelled == true) {
          doAbort();
          return;
        }
        headers?.forEach((k, v) => req!.headers.set(k, v));
        if (bodyBytes != null && bodyBytes.isNotEmpty) {
          req!.contentLength = bodyBytes.length;
          req!.add(bodyBytes);
        }
        final res = await req!.close().timeout(timeout);
        if (aborted || cancelToken?.isCancelled == true) {
          doAbort();
          return;
        }

        final builder = BytesBuilder(copy: false);
        bodySub = res.listen(
          (chunk) {
            if (aborted || cancelToken?.isCancelled == true) {
              doAbort();
              return;
            }
            builder.add(chunk);
          },
          onDone: () {
            if (!completer.isCompleted) {
              final resHeaders = <String, String>{};
              res.headers.forEach((name, values) {
                resHeaders[name] = values.join(', ');
              });
              completer.complete(http.Response.bytes(builder.takeBytes(), res.statusCode, headers: resHeaders));
            }
          },
          onError: (e, st) {
            if (!completer.isCompleted) {
              completer.completeError(aborted ? TtsCancelledException() : e, st);
            }
          },
          cancelOnError: true,
        );
      } catch (e, st) {
        if (!completer.isCompleted) {
          completer.completeError(aborted ? TtsCancelledException() : e, st);
        }
      }
    }();

    return completer.future.timeout(timeout, onTimeout: () {
      doAbort();
      throw TimeoutException('请求超时 (${timeout.inSeconds}s)');
    });
  }

  void dispose() {
    _directIoClient?.close();
    _directIoClient = null;
    _directRawClient?.close(force: true);
    _directRawClient = null;
    _rebuildProxyClients();
  }
}

// ────────────────── TTS 微软官方引擎 (XML清洗 + 动态Lang + 429退避) ──────────────────
class MicrosoftTranslatorTTS {
  static const authUrl = 'https://dev.microsofttranslator.com/apps/endpoint?api-version=1.0';
  static const clientConstant = 'oik6PdDdMnOXemTbwvMn9de/h9lFnfBaCWbGMMZqqoSaQaqUOqjVGm5NqsmjcBI1x+sS9ugjB55HEJWRiFXYFw==';
  static String? _token;
  static String? _region;
  static int _expires = 0;
  static Future<Map<String, String>>? _inFlightAuth;

  static void invalidateToken() {
    _token = null;
    _region = null;
    _expires = 0;
  }

  static String sanitizeXmlText(String text) {
    // 剔除 TXT 电子书常见的非法 XML 控制字符，避免微软接口返回 HTTP 400
    final cleaned = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
    return cleaned
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String extractXmlLang(String voice) {
    final m = RegExp(r'^([a-zA-Z]{2,3}-[A-Za-z0-9]{2,4})').firstMatch(voice.trim());
    return m != null ? m.group(1)! : 'zh-CN';
  }

  static String _stamp(DateTime value) {
    const days = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
    const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    String two(int v) => v < 10 ? '0$v' : '$v';
    final d = value.toUtc();
    return '${days[d.weekday % 7]}, ${two(d.day)} ${months[d.month - 1]} ${d.year} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}gmt';
  }

  static String _signature(String stamp, String nonce) {
    final url = Uri.encodeComponent(authUrl.split('://')[1]);
    final data = ('MSTranslatorAndroidApp$url$stamp$nonce').toLowerCase();
    final mac = Hmac(sha256, base64Decode(clientConstant)).convert(utf8.encode(data));
    return 'MSTranslatorAndroidApp::${base64Encode(mac.bytes)}::$stamp::$nonce';
  }

  static Future<Map<String, String>> getEndpoint(http.Client client) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_token != null && _region != null && _expires > now + 60000) {
      return {'token': _token!, 'region': _region!};
    }
    if (_inFlightAuth != null) return _inFlightAuth!;

    _inFlightAuth = () async {
      try {
        final stamp = _stamp(DateTime.now());
        final nonce = DateTime.now().microsecondsSinceEpoch.toString().padLeft(32, '0');
        final res = await client.post(Uri.parse(authUrl), headers: {
          'X-MT-Signature': _signature(stamp, nonce),
          'X-ClientVersion': '4.0.530a 5fe1dc6c',
          'X-UserId': nonce.substring(0, 16),
          'X-HomeGeographicRegion': 'zh-Hans-CN',
          'X-ClientTraceId': nonce,
          'Accept-Language': 'zh-Hans',
          'User-Agent': 'okhttp/4.5.0',
          'Content-Type': 'application/json; charset=utf-8',
        }).timeout(const Duration(seconds: 15));

        if (res.statusCode != 200) {
          AppLogger.log("微软鉴权接口异常 [HTTP ${res.statusCode}]", res.body);
          throw Exception('微软认证失败：HTTP ${res.statusCode}');
        }
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final token = data['t'] as String;
        final region = data['r'] as String;
        var expires = DateTime.now().millisecondsSinceEpoch + 600000;
        try {
          final parts = token.split('.');
          if (parts.length == 3) {
            var payloadPart = parts[1].replaceAll('-', '+').replaceAll('_', '/');
            while (payloadPart.length % 4 != 0) {
              payloadPart += '=';
            }
            final payload = jsonDecode(utf8.decode(base64Decode(payloadPart)));
            if (payload['exp'] is num) expires = (payload['exp'] as num).toInt() * 1000;
          }
        } catch (_) {}
        _token = token;
        _region = region;
        _expires = expires;
        AppLogger.log("微软Token换取成功 [区域: $region]");
        return {'token': token, 'region': region};
      } finally {
        _inFlightAuth = null;
      }
    }();
    return _inFlightAuth!;
  }

  static Future<Uint8List> synthesize(
    String text,
    String voice, {
    required TtsNetworkRouter router,
    double speed = 1,
    int bitrate = 64,
    int timeoutSeconds = 60,
    TtsCancelToken? cancelToken,
  }) async {
    final watch = Stopwatch()..start();
    final rateValue = ((speed - 1) * 100).round();
    final rate = rateValue >= 0 ? '+$rateValue%' : '$rateValue%';
    final escaped = sanitizeXmlText(text);
    final xmlLang = extractXmlLang(voice);
    final ssml =
        '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="$xmlLang"><voice name="$voice"><prosody rate="$rate" pitch="+0%" volume="+0%">$escaped</prosody></voice></speak>';
    final format = bitrate == 128 ? 'audio-16khz-128kbitrate-mono-mp3' : 'audio-16khz-64kbitrate-mono-mp3';

    final ioClient = router.getClientForEngine('ms');
    final rawClient = router.getRawClientForEngine('ms');

    for (int attempt = 0; attempt < 3; attempt++) {
      if (cancelToken?.isCancelled == true) throw TtsCancelledException();
      final endpoint = await getEndpoint(ioClient);
      final url = Uri.parse('https://${endpoint['region']}.tts.speech.microsoft.com/cognitiveservices/v1');
      final res = await router.sendRequest(
        rawClient: rawClient,
        method: 'POST',
        uri: url,
        headers: {
          'Authorization': endpoint['token']!,
          'X-Microsoft-OutputFormat': format,
          'User-Agent': 'okhttp/4.5.0',
          'Content-Type': 'application/ssml+xml',
        },
        bodyBytes: utf8.encode(ssml),
        timeout: Duration(seconds: timeoutSeconds),
        cancelToken: cancelToken,
      );

      if ((res.statusCode == 401 || res.statusCode == 403) && attempt == 0) {
        invalidateToken();
        continue;
      }
      if (res.statusCode == 429 && attempt < 2) {
        final retryAfterSec = int.tryParse(res.headers['retry-after'] ?? '') ?? (attempt + 1) * 2;
        AppLogger.log("微软触发 429 限流，退避 ${retryAfterSec}s 后重试...", null, null, true);
        await Future.delayed(Duration(seconds: retryAfterSec.clamp(1, 10)));
        continue;
      }
      if (res.statusCode != 200) {
        AppLogger.log("微软合成失败 [HTTP ${res.statusCode}]", res.body);
        throw Exception('微软合成失败：HTTP ${res.statusCode}');
      }
      watch.stop();
      AppLogger.log("微软合成完成 [耗时: ${watch.elapsedMilliseconds}ms, 大小: ${formatFileSize(res.bodyBytes.length)}]");
      return res.bodyBytes;
    }
    throw Exception('微软认证或限流重试耗尽');
  }

  static Future<Map<String, dynamic>> testConnectivity(http.Client client) async {
    final watch = Stopwatch()..start();
    try {
      invalidateToken();
      final endpoint = await getEndpoint(client);
      watch.stop();
      return {'success': true, 'latency': watch.elapsedMilliseconds, 'msg': '认证成功 (区域: ${endpoint['region']})'};
    } catch (e) {
      watch.stop();
      return {'success': false, 'latency': 0, 'msg': '$e'};
    }
  }
}

// ────────────────── TTS Fish Audio 引擎 ──────────────────
class FishAudioTTS {
  FishAudioTTS({required this.apiKey, required this.voices, this.model = 's2.1-pro-free'});
  String apiKey;
  String model;
  Map<String, String> voices;

  Future<Map<String, String>?> fetchModelDetails(String modelId, http.Client client) async {
    try {
      String cleanId = modelId.trim();
      final parsed = Uri.tryParse(cleanId);
      if (parsed != null && parsed.pathSegments.isNotEmpty) {
        final nonEmpty = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
        if (nonEmpty.isNotEmpty) cleanId = nonEmpty.last;
      }
      if (cleanId.isEmpty) return null;
      final url = Uri.parse('https://api.fish.audio/model/$cleanId');
      final headers = <String, String>{};
      if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
      final res = await client.get(url, headers: headers).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        String title = data['title'] ?? data['name'] ?? '';
        List tagsList = data['tags'] ?? [];
        String tags = tagsList.take(3).join(', ');
        return {'title': title, 'tags': tags, 'cleanId': cleanId};
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> testConnectivity(http.Client client) async {
    final watch = Stopwatch()..start();
    try {
      final response = await client.get(Uri.parse('https://api.fish.audio/model?page_size=1')).timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) throw Exception('HTTP ${response.statusCode}');
      if (apiKey.isEmpty) {
        watch.stop();
        return {'success': true, 'latency': watch.elapsedMilliseconds, 'msg': '网络连通，但未填写 API Key'};
      }
      final auth = await client
          .get(Uri.parse('https://api.fish.audio/model?self=true&page_size=1'), headers: {'Authorization': 'Bearer $apiKey'})
          .timeout(const Duration(seconds: 10));
      watch.stop();
      bool valid = auth.statusCode == 200;
      return {'success': valid, 'latency': watch.elapsedMilliseconds, 'msg': valid ? '网络连通，API Key 校验通过' : 'API Key 校验失败 (${auth.statusCode})'};
    } catch (e) {
      watch.stop();
      return {'success': false, 'latency': 0, 'msg': '$e'};
    }
  }

  Future<Uint8List> textToSpeech(
    String text,
    String voice, {
    required TtsNetworkRouter router,
    double speed = 1,
    int bitrate = 64,
    int timeoutSeconds = 60,
    TtsCancelToken? cancelToken,
  }) async {
    if (apiKey.isEmpty) throw Exception('请先配置 Fish Audio API Key');
    final watch = Stopwatch()..start();
    final ref = voices.containsKey(voice) ? voice : (voice.isNotEmpty ? voice : voices.keys.first);
    final body = <String, dynamic>{'text': text, 'format': 'mp3', 'reference_id': ref, 'normalize': true, 'mp3_bitrate': bitrate};
    if ((speed - 1).abs() >= 0.05) body['prosody'] = {'speed': double.parse(speed.toStringAsFixed(2))};

    final rawClient = router.getRawClientForEngine('fish');
    final response = await router.sendRequest(
      rawClient: rawClient,
      method: 'POST',
      uri: Uri.parse('https://api.fish.audio/v1/tts'),
      headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json', 'model': model},
      bodyBytes: utf8.encode(jsonEncode(body)),
      timeout: Duration(seconds: timeoutSeconds),
      cancelToken: cancelToken,
    );
    watch.stop();

    if (response.statusCode != 200) {
      AppLogger.log("Fish合成失败 [HTTP ${response.statusCode}]", response.body);
      throw Exception('Fish 合成失败：HTTP ${response.statusCode}');
    }
    AppLogger.log("Fish合成完成 [模型: $model, 耗时: ${watch.elapsedMilliseconds}ms, 大小: ${formatFileSize(response.bodyBytes.length)}]");
    return response.bodyBytes;
  }
}

// ────────────────── 用户自定义 TTS 引擎执行器与代码/cURL 模板解析 ──────────────────
class CustomTtsRunner {
  static String renderTemplate(String template, Map<String, String> vars) {
    String out = template;
    vars.forEach((k, v) {
      out = out.replaceAll('{{$k}}', v);
    });
    return out;
  }

  static dynamic extractJsonPath(dynamic root, String path) {
    if (path.trim().isEmpty) return root;
    dynamic cur = root;
    final tokens = RegExp(r'[^.\[\]]+|\[\d+\]').allMatches(path.trim()).map((m) => m.group(0)!).toList();
    for (final tk in tokens) {
      if (tk.startsWith('[') && tk.endsWith(']')) {
        final idx = int.tryParse(tk.substring(1, tk.length - 1));
        if (cur is List && idx != null && idx >= 0 && idx < cur.length) {
          cur = cur[idx];
        } else {
          return null;
        }
      } else {
        if (cur is Map && cur.containsKey(tk)) {
          cur = cur[tk];
        } else {
          return null;
        }
      }
    }
    return cur;
  }

  static Future<Uint8List> synthesize(
    CustomTtsEngineConfig cfg,
    String text,
    String voice, {
    required TtsNetworkRouter router,
    double speed = 1.0,
    int bitrate = 64,
    int timeoutSeconds = 60,
    TtsCancelToken? cancelToken,
  }) async {
    if (cfg.url.trim().isEmpty) throw Exception('自定义引擎 [${cfg.name}] 未配置请求 URL');
    final watch = Stopwatch()..start();

    final encodedJsonText = jsonEncode(text);
    final jsonInnerText = encodedJsonText.substring(1, encodedJsonText.length - 1);
    final rateVal = ((speed - 1.0) * 100).round();
    final ratePercent = rateVal >= 0 ? '+$rateVal%' : '$rateVal%';

    final vars = <String, String>{
      'text': text,
      'text_json': jsonInnerText,
      'text_xml': MicrosoftTranslatorTTS.sanitizeXmlText(text),
      'text_url': Uri.encodeQueryComponent(text),
      'voice': voice,
      'speed': speed.toStringAsFixed(2),
      'rate_percent': ratePercent,
      'bitrate': bitrate.toString(),
      'api_key': cfg.apiKey,
    };

    final resolvedUrl = renderTemplate(cfg.url.trim(), vars);
    final uri = Uri.tryParse(resolvedUrl);
    if (uri == null || !uri.hasScheme) throw Exception('无效的请求 URL: $resolvedUrl');

    final resolvedHeaders = <String, String>{};
    cfg.headers.forEach((k, v) {
      resolvedHeaders[k] = renderTemplate(v, vars);
    });

    final rawClient = router.getRawClientForEngine(cfg.id, [cfg]);
    final isGet = cfg.method.toUpperCase() == 'GET';
    final List<int>? reqBody = isGet ? null : utf8.encode(renderTemplate(cfg.bodyTemplate, vars));

    final res = await router.sendRequest(
      rawClient: rawClient,
      method: isGet ? 'GET' : 'POST',
      uri: uri,
      headers: resolvedHeaders,
      bodyBytes: reqBody,
      timeout: Duration(seconds: timeoutSeconds),
      cancelToken: cancelToken,
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errBody = utf8.decode(res.bodyBytes, allowMalformed: true);
      AppLogger.log("自定义引擎[${cfg.name}]合成失败 [HTTP ${res.statusCode}]", errBody);
      throw Exception('${cfg.name} 失败：HTTP ${res.statusCode}');
    }

    Uint8List audioBytes;
    if (cfg.responseType == 'json_base64') {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final val = extractJsonPath(decoded, cfg.jsonPath);
      if (val is! String || val.isEmpty) {
        throw Exception('未在 JSON 路径 "${cfg.jsonPath}" 找到 Base64 音频字段');
      }
      final cleaned = val.contains(',') ? val.split(',').last : val;
      audioBytes = base64Decode(cleaned.replaceAll(RegExp(r'\s+'), ''));
    } else if (cfg.responseType == 'json_url') {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final val = extractJsonPath(decoded, cfg.jsonPath);
      if (val is! String || val.trim().isEmpty) {
        throw Exception('未在 JSON 路径 "${cfg.jsonPath}" 找到有效音频 URL');
      }
      final audioUri = uri.resolve(val.trim());
      final dl = await router.sendRequest(
        rawClient: rawClient,
        method: 'GET',
        uri: audioUri,
        timeout: Duration(seconds: timeoutSeconds),
        cancelToken: cancelToken,
      );
      if (dl.statusCode < 200 || dl.statusCode >= 300) throw Exception('拉取音频地址失败: HTTP ${dl.statusCode}');
      audioBytes = dl.bodyBytes;
    } else {
      audioBytes = res.bodyBytes;
    }

    watch.stop();
    AppLogger.log("自定义引擎[${cfg.name}]合成完成 [耗时: ${watch.elapsedMilliseconds}ms, 大小: ${formatFileSize(audioBytes.length)}]");
    return audioBytes;
  }

  static Future<Map<String, dynamic>> testConnectivity(CustomTtsEngineConfig cfg, TtsNetworkRouter router) async {
    final watch = Stopwatch()..start();
    try {
      final voiceId = cfg.voices.keys.isNotEmpty ? cfg.voices.keys.first : 'default';
      final sample = cfg.testText.trim().isNotEmpty ? cfg.testText.trim() : '测试语音连通性。';
      final bytes = await synthesize(cfg, sample, voiceId, router: router, timeoutSeconds: 15);
      watch.stop();
      return {'success': true, 'latency': watch.elapsedMilliseconds, 'msg': '合成测试成功 (${formatFileSize(bytes.length)})'};
    } catch (e) {
      watch.stop();
      return {'success': false, 'latency': 0, 'msg': '$e'};
    }
  }

  static Map<String, CustomTtsEngineConfig> presetTemplates() => {
        'fish_relay': CustomTtsEngineConfig(
          id: 'tpl_fish_relay',
          name: 'Fish Audio 中转服务',
          method: 'POST',
          url: 'https://your-relay.example.com/v1/tts',
          headers: {
            'Authorization': 'Bearer {{api_key}}',
            'Content-Type': 'application/json',
            'model': 's2.1-pro',
          },
          bodyTemplate: '{\n  "text": "{{text_json}}",\n  "reference_id": "{{voice}}",\n  "format": "mp3",\n  "mp3_bitrate": {{bitrate}},\n  "normalize": true,\n  "prosody": {"speed": {{speed}}}\n}',
          responseType: 'raw_bytes',
          voices: {'cf71d823861b4e0eadff1672d646da36': '几何女声'},
          networkMode: 'direct',
        ),
        'xiaomi_mimo': CustomTtsEngineConfig(
          id: 'tpl_xiaomi_mimo',
          name: '小米 MiMo TTS',
          method: 'POST',
          url: 'https://api.xiaomimimo.com/v1/chat/completions',
          headers: {
            'Authorization': 'Bearer {{api_key}}',
            'Content-Type': 'application/json',
          },
          bodyTemplate:
              '{\n  "model": "mimo-v2-tts",\n  "messages": [\n    {"role": "assistant", "content": "{{text_json}}"}\n  ],\n  "audio": {\n    "format": "mp3",\n    "voice": "{{voice}}"\n  }\n}',
          responseType: 'json_base64',
          jsonPath: 'choices[0].message.audio.data',
          voices: {'mimo_default': 'MiMo 默认音色', 'default_zh': '中文标准'},
          networkMode: 'direct',
        ),
        'openai_speech': CustomTtsEngineConfig(
          id: 'tpl_openai_tts',
          name: 'OpenAI 兼容 /v1/audio/speech',
          method: 'POST',
          url: 'https://api.openai.com/v1/audio/speech',
          headers: {
            'Authorization': 'Bearer {{api_key}}',
            'Content-Type': 'application/json',
          },
          bodyTemplate: '{\n  "model": "tts-1",\n  "input": "{{text_json}}",\n  "voice": "{{voice}}",\n  "speed": {{speed}},\n  "response_format": "mp3"\n}',
          responseType: 'raw_bytes',
          voices: {'alloy': 'Alloy', 'nova': 'Nova', 'shimmer': 'Shimmer', 'echo': 'Echo'},
          networkMode: 'direct',
        ),
        'edge_http': CustomTtsEngineConfig(
          id: 'tpl_edge_http',
          name: '微软 Edge HTTP 转发网关',
          method: 'POST',
          url: 'http://127.0.0.1:5050/v1/audio/speech',
          headers: {
            'Authorization': 'Bearer {{api_key}}',
            'Content-Type': 'application/json',
          },
          bodyTemplate: '{\n  "input": "{{text_json}}",\n  "voice": "{{voice}}",\n  "speed": {{speed}}\n}',
          responseType: 'raw_bytes',
          voices: {'zh-CN-XiaoxiaoNeural': '晓晓', 'zh-CN-YunxiNeural': '云希'},
          networkMode: 'direct',
        ),
      };

  static List<String> _tokenizeShellArgs(String input) {
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;
    bool escaped = false;
    bool hasToken = false;

    for (int i = 0; i < input.length; i++) {
      final ch = input[i];
      if (escaped) {
        buf.write(ch);
        escaped = false;
        hasToken = true;
        continue;
      }
      if (ch == r'\' && quote != "'") {
        escaped = true;
        hasToken = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
        hasToken = true;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        hasToken = true;
        continue;
      }
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        if (hasToken) {
          tokens.add(buf.toString());
          buf.clear();
          hasToken = false;
        }
        continue;
      }
      buf.write(ch);
      hasToken = true;
    }
    if (hasToken) tokens.add(buf.toString());
    return tokens;
  }

  static CustomTtsEngineConfig? parseCurl(String rawCurl, {String name = 'cURL 导入引擎'}) {
    final cleaned = rawCurl.replaceAll('\\\r\n', ' ').replaceAll('\\\n', ' ').trim();
    if (!cleaned.toLowerCase().startsWith('curl')) return null;

    final args = _tokenizeShellArgs(cleaned);
    String url = '';
    String method = '';
    final headers = <String, String>{};
    final bodyParts = <String>[];

    for (int i = 1; i < args.length; i++) {
      final arg = args[i];
      if ((arg == '-X' || arg == '--request') && i + 1 < args.length) {
        method = args[++i].toUpperCase();
      } else if (arg.startsWith('-X') && arg.length > 2) {
        method = arg.substring(2).toUpperCase();
      } else if ((arg == '-H' || arg == '--header') && i + 1 < args.length) {
        final kv = args[++i];
        final idx = kv.indexOf(':');
        if (idx > 0) headers[kv.substring(0, idx).trim()] = kv.substring(idx + 1).trim();
      } else if ((arg == '-d' || arg == '--data' || arg == '--data-raw' || arg == '--data-binary' || arg == '--data-urlencode') &&
          i + 1 < args.length) {
        bodyParts.add(args[++i]);
      } else if (arg == '--url' && i + 1 < args.length) {
        url = args[++i];
      } else if (!arg.startsWith('-') && (arg.startsWith('http://') || arg.startsWith('https://')) && url.isEmpty) {
        url = arg;
      }
    }

    if (url.isEmpty) {
      final urlM = RegExp(r'''(https?://[^\s'"]+)''').firstMatch(cleaned);
      if (urlM == null) return null;
      url = urlM.group(1)!;
    }

    final body = bodyParts.join('&');
    if (method.isEmpty) {
      method = body.isNotEmpty ? 'POST' : 'GET';
    }

    return CustomTtsEngineConfig(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      method: method == 'GET' ? 'GET' : 'POST',
      url: url,
      headers: headers.isEmpty ? {'Content-Type': 'application/json'} : headers,
      bodyTemplate: body,
      responseType: 'raw_bytes',
      networkMode: 'direct',
    );
  }
}

// ────────────────── 统一 TTS 调用入口 ──────────────────
Future<Uint8List> synthesizeWithEngine({
  required String engineId,
  required String text,
  required String voiceId,
  required double speed,
  required int bitrate,
  required int timeoutSeconds,
  required FishAudioTTS fishTts,
  required List<CustomTtsEngineConfig> customEngines,
  required TtsNetworkRouter networkRouter,
  TtsCancelToken? cancelToken,
}) async {
  if (engineId == 'ms') {
    return MicrosoftTranslatorTTS.synthesize(
      text,
      voiceId,
      router: networkRouter,
      speed: speed,
      bitrate: bitrate,
      timeoutSeconds: timeoutSeconds,
      cancelToken: cancelToken,
    );
  }
  if (engineId == 'fish') {
    return fishTts.textToSpeech(
      text,
      voiceId,
      router: networkRouter,
      speed: speed,
      bitrate: bitrate,
      timeoutSeconds: timeoutSeconds,
      cancelToken: cancelToken,
    );
  }
  final custom = customEngines.cast<CustomTtsEngineConfig?>().firstWhere((e) => e?.id == engineId, orElse: () => null);
  if (custom == null) {
    throw Exception('找不到 TTS 引擎 ($engineId)，可能已被删除');
  }
  return CustomTtsRunner.synthesize(
    custom,
    text,
    voiceId,
    router: networkRouter,
    speed: speed,
    bitrate: bitrate,
    timeoutSeconds: timeoutSeconds,
    cancelToken: cancelToken,
  );
}
