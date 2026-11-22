import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/models.dart';
import 'm3u8_ad_remover.dart';
import 'proxy_routing_service.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class ApiClient {
  ServerConfig _config;
  ProxyRoutingService? _proxyService;
  late http.Client _client;
  late HttpClient _rawHttpClient;
  HttpClient? _ioHttpClient;
  String _lastProxyConfigSignature = '';

  static final Map<String, List<LiveChannel>> _liveChannelCache = {};
  static final Map<String, ({VodListResponse data, DateTime expiresAt})>
      _vodListCache = {};
  static final Map<String, ({VodDetail data, DateTime expiresAt})>
      _vodDetailCache = {};
  static final Map<String, ({String url, DateTime expiresAt})>
      _redirectUrlCache = {};
  static final Map<String, ({String ip, int recordType, DateTime expiresAt})>
      _dohHostCache = {};

  ApiClient(this._config, {ProxyRoutingService? proxyService})
      : _proxyService = proxyService {
    _initHttpClients();
    if (_proxyService != null) {
      _lastProxyConfigSignature = _computeProxySignature(_proxyService!);
      _proxyService!.addListener(_onProxyServiceChanged);
    }
  }

  void _initHttpClients() {
    final ioHttpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 12
      ..findProxy = ((Uri uri) => _findProxyForUri(uri))
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    _ioHttpClient = ioHttpClient;
    _client = IOClient(ioHttpClient);

    _rawHttpClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 2500)
      ..idleTimeout = const Duration(seconds: 20)
      ..findProxy = ((Uri uri) =>
          _findProxyForUri(uri, scenarioHint: RequestScenario.liveStream))
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }

  String _computeProxySignature(ProxyRoutingService svc) {
    final rulesSig = svc.scenarioRules.entries
        .map((e) => '${e.key.name}:${e.value.mode.name}:${e.value.specificNodeId ?? ""}')
        .join('|');
    return '${svc.proxyEnabled}|${svc.selectionMode.name}|${svc.activeNode?.id ?? ""}|$rulesSig';
  }

  void _onProxyServiceChanged() {
    final svc = _proxyService;
    if (svc == null) return;
    final nextSig = _computeProxySignature(svc);
    if (nextSig == _lastProxyConfigSignature) return;
    _lastProxyConfigSignature = nextSig;
    resetHttpClientPool();
  }

  /// Closes pooled keep-alive sockets (so no requests linger on an old proxy node
  /// or stay proxied after turning off the proxy) and creates fresh [HttpClient]s.
  void resetHttpClientPool() {
    final oldIo = _ioHttpClient;
    final oldRaw = _rawHttpClient;
    _initHttpClients();
    try {
      oldIo?.close(force: false);
    } catch (_) {}
    try {
      oldRaw.close(force: false);
    } catch (_) {}
  }

  void attachProxyService(ProxyRoutingService service) {
    if (identical(_proxyService, service)) return;
    _proxyService?.removeListener(_onProxyServiceChanged);
    _proxyService = service;
    _lastProxyConfigSignature = _computeProxySignature(service);
    service.addListener(_onProxyServiceChanged);
  }

  String buildProxyDirectiveForUri(Uri uri, {RequestScenario? scenarioHint}) =>
      _findProxyForUri(uri, scenarioHint: scenarioHint);

  String _findProxyForUri(Uri uri, {RequestScenario? scenarioHint}) {
    final svc = _proxyService;
    if (svc == null || !svc.proxyEnabled) return 'DIRECT';
    final baseUri = Uri.tryParse(_config.normalizedBaseUrl);
    if (baseUri != null &&
        baseUri.host.isNotEmpty &&
        uri.host.toLowerCase() == baseUri.host.toLowerCase()) {
      return svc.resolveFindProxyDirective(RequestScenario.backendApi, uri);
    }
    final scenario = scenarioHint ?? _inferScenarioFromUri(uri);
    return svc.resolveFindProxyDirective(scenario, uri);
  }

  RequestScenario _inferScenarioFromUri(Uri uri) {
    final path = uri.path.toLowerCase();
    final host = uri.host.toLowerCase();
    final baseUri = Uri.tryParse(_config.normalizedBaseUrl);
    if (baseUri != null &&
        baseUri.host.isNotEmpty &&
        host == baseUri.host.toLowerCase()) {
      return RequestScenario.backendApi;
    }
    if (path.startsWith('/api/telegram') ||
        host.contains('telegram') ||
        host == 't.me') {
      return RequestScenario.telegram;
    }
    if (path.startsWith('/api/vod/proxy') ||
        path.endsWith('.m3u8') ||
        path.endsWith('.ts') ||
        path.endsWith('.mp4')) {
      return RequestScenario.vodStream;
    }
    if (path.startsWith('/api/vod/') ||
        path.startsWith('/api/tvbox/sites') ||
        uri.queryParameters.containsKey('ac')) {
      return RequestScenario.vodApi;
    }
    if (path.startsWith('/api/tvbox/live') ||
        host.contains('githubusercontent.com') ||
        host.contains('ghfast.top') ||
        host.contains('gh-proxy.com')) {
      return RequestScenario.liveStream;
    }
    if (path.startsWith('/api/web/extract') ||
        host == '223.5.5.5' ||
        host.contains('liangxin.xyz')) {
      return RequestScenario.externalWeb;
    }
    return RequestScenario.vodApi;
  }

  ServerConfig get config => _config;

  void updateConfig(ServerConfig newConfig) {
    _config = newConfig;
  }

  Map<String, String> get authHeaders {
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    final secret = _config.secret.trim();
    if (_config.authMode == AuthMode.password && secret.isNotEmpty) {
      final cookieVal = secret.startsWith('auth_') ? secret : 'auth_$secret';
      headers['Cookie'] = 'access_token=$cookieVal';
    } else if (_config.authMode == AuthMode.token && secret.isNotEmpty) {
      headers['Authorization'] = 'Bearer $secret';
      headers['Cookie'] = 'access_token=$secret';
    }
    return headers;
  }

  Uri _buildUri(String path, [Map<String, String>? queryParameters]) {
    final base = _config.normalizedBaseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$cleanPath');
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        ...queryParameters,
      },
    );
  }

  String resolveUrl(String pathOrUrl) {
    final trimmed = pathOrUrl.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final base = _config.normalizedBaseUrl;
    final cleanPath = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return '$base$cleanPath';
  }

  String buildProxiedImageUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('/api/vod/image')) {
      return resolveUrl(trimmed);
    }
    final uri = _buildUri('/api/vod/image', {'url': trimmed});
    return uri.toString();
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = _buildUri(path, query);
    final response = await _client
        .get(uri, headers: authHeaders)
        .timeout(timeout);
    return _decodeResponse(response);
  }

  Future<dynamic> _postJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final uri = _buildUri(path, query);
    final headers = {
      ...authHeaders,
      'Content-Type': 'application/json',
    };
    final response = await _client
        .post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(timeout);
    return _decodeResponse(response);
  }

  Future<dynamic> _putJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = _buildUri(path, query);
    final headers = {
      ...authHeaders,
      'Content-Type': 'application/json',
    };
    final response = await _client
        .put(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(timeout);
    return _decodeResponse(response);
  }

  Future<dynamic> _deleteJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = _buildUri(path, query);
    final headers = {
      ...authHeaders,
      if (body != null) 'Content-Type': 'application/json',
    };
    final request = http.Request('DELETE', uri)..headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final streamed = await _client.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    return _decodeResponse(response);
  }

  dynamic _decodeResponse(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ApiException('认证失败，请检查服务器地址与访问密码', statusCode: response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String errMsg = '请求失败 (HTTP ${response.statusCode})';
      if (text.isNotEmpty) {
        try {
          final parsed = jsonDecode(text);
          if (parsed is Map && parsed['error'] != null) {
            errMsg = parsed['error'].toString();
          } else {
            errMsg = text.length > 120 ? text.substring(0, 120) : text;
          }
        } catch (_) {
          errMsg = text.length > 120 ? text.substring(0, 120) : text;
        }
      }
      throw ApiException(errMsg, statusCode: response.statusCode);
    }
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  /// Verify login credentials against `/api/login` or `/api/settings`
  Future<bool> verifyConnection() async {
    if (_config.authMode == AuthMode.password) {
      final pwd = _config.secret.trim();
      if (pwd.isEmpty) {
        throw const ApiException('请输入访问密码', statusCode: 401);
      }
      final uri = _buildUri('/api/login');
      final resp = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'password': pwd}),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        return true;
      }
      throw ApiException(
        resp.statusCode == 401 ? '访问密码错误，请重新输入' : '登录验证失败 (HTTP ${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    final settings = await _getJson('/api/settings');
    return settings is Map;
  }

  /// Fetch all custom VOD sources + TVBox sites
  Future<List<VodSource>> fetchAllVodSources() async {
    final sources = <VodSource>[];

    // 1. Fetch settings for custom `vod_sources`
    try {
      final settingsData = await _getJson('/api/settings');
      if (settingsData is Map<String, dynamic>) {
        final rawVod = settingsData['vod_sources'];
        if (rawVod is List) {
          for (var i = 0; i < rawVod.length; i++) {
            final item = rawVod[i];
            if (item is Map<String, dynamic>) {
              final name = (item['name'] ?? '资源站 ${i + 1}').toString().trim();
              final api = (item['api'] ?? '').toString().trim();
              if (api.isNotEmpty) {
                sources.add(
                  VodSource(
                    id: 'custom_$i',
                    name: name,
                    api: api,
                    isTvBox: false,
                    customIndex: i,
                    searchable: true,
                  ),
                );
              }
            }
          }
        }
      }
    } catch (_) {
      // Fallback to TVBox sites if settings fails
    }

    // 2. Fetch TVBox sites from `/api/tvbox/sites`
    try {
      final tvboxData = await _getJson('/api/tvbox/sites');
      if (tvboxData is List) {
        for (final item in tvboxData) {
          if (item is Map<String, dynamic>) {
            final type = int.tryParse((item['type'] ?? 1).toString()) ?? 1;
            final api = (item['api'] ?? '').toString().trim();
            if (api.isEmpty) continue;
            // Browsable types: 0, 1, 3, 4
            if (type != 0 && type != 1 && type != 3 && type != 4) continue;

            final siteIdx =
                int.tryParse((item['site_index'] ?? 0).toString()) ?? 0;
            final srcIdx =
                int.tryParse((item['source_index'] ?? 0).toString()) ?? 0;
            final rawName = (item['name'] ?? 'TVBox 站点').toString().trim();
            final sourceName = (item['source_name'] ?? '').toString().trim();
            final searchable =
                int.tryParse((item['searchable'] ?? 1).toString()) != 0;

            sources.add(
              VodSource(
                id: 'tvbox_${srcIdx}_$siteIdx',
                name: rawName,
                api: api,
                isTvBox: true,
                tvboxType: type,
                tvboxSiteIndex: siteIdx,
                tvboxSourceIndex: srcIdx,
                tvboxSourceName: sourceName,
                searchable: searchable,
              ),
            );
          }
        }
      }
    } catch (_) {
      // Ignore TVBox sites error if not configured
    }

    return sources;
  }

  bool _canDirectQueryCms(VodSource source) {
    final route = _proxyService?.resolveEffectiveRoute(
      RequestScenario.vodApi,
      targetUri: Uri.tryParse(source.api.trim()),
    );
    if (route == ScenarioRouteMode.serverRelay) return false;
    if (!_config.preferDirectPlayback &&
        route != ScenarioRouteMode.direct &&
        route != ScenarioRouteMode.proxyNode) {
      return false;
    }
    // Always route TVBox sites through backend `/api/vod/*` first so server-side
    // TVBox site configs (jar, ext, playUrl, categories, spider bridge) work properly.
    if (source.isTvBox) return false;
    return _isStandardHttpCmsApi(source.api);
  }

  bool _isStandardHttpCmsApi(String rawApi) {
    final api = rawApi.trim();
    if (!api.startsWith('http://') && !api.startsWith('https://')) {
      return false;
    }
    if (api.contains('://127.0.0.1') || api.contains('://localhost')) {
      return false;
    }
    final lower = api.toLowerCase();
    if (lower.endsWith('.js') ||
        lower.endsWith('.py') ||
        lower.contains('/xml') ||
        lower.contains('/vod/at/xml')) {
      return false;
    }
    return true;
  }

  Future<Map<String, dynamic>?> _fetchDirectCmsJson(
    String baseApi,
    Map<String, String> params, {
    Duration timeout = const Duration(milliseconds: 5500),
  }) async {
    final uri = Uri.parse(baseApi.trim());
    final baseQuery = Map<String, String>.from(uri.queryParameters);
    if (params.containsKey('ac')) {
      baseQuery.remove('ac');
    }
    final mergedUri = uri.replace(
      queryParameters: {
        ...baseQuery,
        ...params,
      },
    );
    final res = await _client
        .get(
          mergedUri,
          headers: const {
            'Accept': 'application/json, text/plain, */*',
            'User-Agent':
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          },
        )
        .timeout(timeout);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final text = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
      final braceIdx = text.indexOf('{');
      if (braceIdx >= 0) {
        final jsonSlice = braceIdx == 0 ? text : text.substring(braceIdx);
        final decoded = jsonDecode(jsonSlice);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      }
    }
    return null;
  }

  /// Fetch VOD list for a source, category (`t`), and page (`pg`).
  /// Uses direct client-side CMS requests + memory cache when `preferDirectPlayback`
  /// is enabled to eliminate cross-border server proxy latency.
  Future<VodListResponse> fetchVodList(
    VodSource source, {
    String typeId = '',
    int page = 1,
    bool forceRefresh = false,
  }) async {
    final cacheKey = '${source.id}|$typeId|$page';
    final now = DateTime.now();
    if (!forceRefresh) {
      final cached = _vodListCache[cacheKey];
      if (cached != null && cached.expiresAt.isAfter(now)) {
        return cached.data;
      }
    }

    if (_canDirectQueryCms(source)) {
      try {
        final detailParams = <String, String>{
          'ac': 'detail',
          'pg': page.toString(),
          if (typeId.isNotEmpty) 't': typeId,
        };
        if (typeId.isEmpty && page == 1) {
          final results = await Future.wait([
            _fetchDirectCmsJson(source.api, detailParams),
            _fetchDirectCmsJson(
              source.api,
              const {'ac': 'list', 'pg': '1'},
              timeout: const Duration(milliseconds: 6000),
            ).catchError((_) => null),
          ]);
          final detailJson = results[0];
          var listJson = results[1];
          if ((listJson == null || listJson['class'] is! List) &&
              detailJson != null) {
            // Secondary quick fallback via backend `/api/vod/list` if direct `ac=list` timed out
            try {
              final backendData = await _getJson(
                '/api/vod/list',
                query: {
                  ...source.toQueryParameters(),
                  'pg': '1',
                },
                timeout: const Duration(milliseconds: 4500),
              );
              if (backendData is Map<String, dynamic> &&
                  backendData['class'] is List) {
                listJson = backendData;
              }
            } catch (_) {}
          }
          if (detailJson != null && detailJson['list'] is List) {
            final merged = <String, dynamic>{
              ...detailJson,
              if (listJson != null && listJson['class'] is List)
                'class': listJson['class'],
            };
            final parsed = VodListResponse.fromJson(merged, source: source);
            if (parsed.items.isNotEmpty) {
              _vodListCache[cacheKey] = (
                data: parsed,
                expiresAt: now.add(const Duration(minutes: 3)),
              );
              return parsed;
            }
          }
        } else {
          final detailJson = await _fetchDirectCmsJson(source.api, detailParams);
          if (detailJson != null && detailJson['list'] is List) {
            final parsed = VodListResponse.fromJson(detailJson, source: source);
            if (parsed.items.isNotEmpty) {
              _vodListCache[cacheKey] = (
                data: parsed,
                expiresAt: now.add(const Duration(minutes: 3)),
              );
              return parsed;
            }
          }
        }
      } catch (_) {
        // Fallback to server `/api/vod/list` below
      }
    }

    final query = <String, String>{
      ...source.toQueryParameters(),
      'pg': page.toString(),
    };
    if (typeId.isNotEmpty) {
      query['t'] = typeId;
    }

    dynamic data;
    Object? backendErr;
    try {
      data = await _getJson(
        '/api/vod/list',
        query: query,
        timeout: Duration(seconds: source.isTvBox ? 28 : 20),
      );
    } catch (e) {
      backendErr = e;
    }

    if (data is Map<String, dynamic>) {
      var parsed = VodListResponse.fromJson(data, source: source);

      // Many TVBox spider sources (e.g. `csp_*`) return `list: []` on home (`t=""`)
      // while providing `class` categories. Auto-fetch the first category so the
      // user immediately sees content instead of an empty screen.
      if (typeId.isEmpty &&
          page == 1 &&
          parsed.items.isEmpty &&
          parsed.categories.isNotEmpty) {
        final firstCatId = parsed.categories.first.typeId;
        if (firstCatId.isNotEmpty) {
          try {
            final catData = await _getJson(
              '/api/vod/list',
              query: {
                ...source.toQueryParameters(),
                'pg': '1',
                't': firstCatId,
              },
              timeout: Duration(seconds: source.isTvBox ? 28 : 20),
            );
            if (catData is Map<String, dynamic>) {
              final catParsed = VodListResponse.fromJson(
                catData,
                source: source,
              );
              if (catParsed.items.isNotEmpty) {
                parsed = catParsed.copyWith(
                  categories: parsed.categories,
                  resolvedTypeId: firstCatId,
                );
              }
            }
          } catch (_) {}
        }
      }

      if (parsed.items.isNotEmpty || parsed.categories.isNotEmpty) {
        _vodListCache[cacheKey] = (
          data: parsed,
          expiresAt: now.add(const Duration(minutes: 3)),
        );
        return parsed;
      }
    }

    // Fallback for TVBox type==1 (standard CMS JSON API) if backend failed or returned empty
    if (source.isTvBox &&
        source.tvboxType == 1 &&
        _isStandardHttpCmsApi(source.api)) {
      try {
        final detailParams = <String, String>{
          'ac': 'detail',
          'pg': page.toString(),
          if (typeId.isNotEmpty) 't': typeId,
        };
        final results = await Future.wait([
          _fetchDirectCmsJson(source.api, detailParams),
          if (typeId.isEmpty && page == 1)
            _fetchDirectCmsJson(
              source.api,
              const {'ac': 'list', 'pg': '1'},
              timeout: const Duration(milliseconds: 5000),
            ).catchError((_) => null),
        ]);
        final detailJson = results[0];
        final listJson = results.length > 1 ? results[1] : null;
        if (detailJson != null && detailJson['list'] is List) {
          final merged = <String, dynamic>{
            ...detailJson,
            if (listJson != null && listJson['class'] is List)
              'class': listJson['class'],
          };
          final parsed = VodListResponse.fromJson(merged, source: source);
          if (parsed.items.isNotEmpty || parsed.categories.isNotEmpty) {
            _vodListCache[cacheKey] = (
              data: parsed,
              expiresAt: now.add(const Duration(minutes: 3)),
            );
            return parsed;
          }
        }
      } catch (_) {}
    }

    if (backendErr != null) {
      if (backendErr is ApiException) throw backendErr;
      throw ApiException('加载站点失败：$backendErr');
    }
    if (data is Map<String, dynamic>) {
      return VodListResponse.fromJson(data, source: source);
    }
    throw const ApiException('数据源返回格式异常');
  }

  /// Search VOD items in a single source
  Future<List<VodItem>> searchVod(
    VodSource source,
    String keyword,
  ) async {
    final kw = keyword.trim();
    if (_canDirectQueryCms(source)) {
      try {
        final json = await _fetchDirectCmsJson(
          source.api,
          {'ac': 'detail', 'wd': kw},
          timeout: const Duration(seconds: 6),
        );
        if (json != null && json['list'] is List) {
          return VodListResponse.fromJson(json, source: source).items;
        }
      } catch (_) {}
    }

    final query = <String, String>{
      ...source.toQueryParameters(),
      'wd': kw,
    };
    try {
      final data = await _getJson(
        '/api/vod/search',
        query: query,
        timeout: Duration(seconds: source.isTvBox ? 22 : 15),
      );
      if (data is Map<String, dynamic>) {
        final resp = VodListResponse.fromJson(data, source: source);
        if (resp.items.isNotEmpty) {
          return resp.items;
        }
      }
    } catch (_) {
      if (!source.isTvBox || source.tvboxType != 1) rethrow;
    }

    if (source.isTvBox &&
        source.tvboxType == 1 &&
        _isStandardHttpCmsApi(source.api)) {
      try {
        final json = await _fetchDirectCmsJson(
          source.api,
          {'ac': 'detail', 'wd': kw},
          timeout: const Duration(seconds: 6),
        );
        if (json != null && json['list'] is List) {
          return VodListResponse.fromJson(json, source: source).items;
        }
      } catch (_) {}
    }
    return const [];
  }

  /// Fetch VOD detail for `vodId`
  Future<VodDetail> fetchVodDetail(
    VodSource source,
    String vodId,
  ) async {
    final cacheKey = '${source.id}|$vodId';
    final now = DateTime.now();
    final cached = _vodDetailCache[cacheKey];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      return cached.data;
    }

    final canDirectDetail = _canDirectQueryCms(source) ||
        (_config.preferDirectPlayback &&
            source.isTvBox &&
            source.tvboxType == 1 &&
            _isStandardHttpCmsApi(source.api) &&
            _proxyService?.resolveEffectiveRoute(
                  RequestScenario.vodApi,
                  targetUri: Uri.tryParse(source.api.trim()),
                ) !=
                ScenarioRouteMode.serverRelay);

    if (canDirectDetail) {
      try {
        final json = await _fetchDirectCmsJson(
          source.api,
          {'ac': 'detail', 'ids': vodId},
          timeout: const Duration(milliseconds: 3500),
        );
        if (json != null) {
          final list = json['list'];
          if (list is List &&
              list.isNotEmpty &&
              list.first is Map<String, dynamic>) {
            final detail =
                VodDetail.fromJson(list.first as Map<String, dynamic>);
            final hasDirectEpisodes = detail.playGroups.isNotEmpty &&
                detail.playGroups.any(
                  (g) =>
                      g.episodes.isNotEmpty &&
                      (!source.isTvBox ||
                          _isDirectPlayableVodUrl(g.episodes.first.rawUrl)),
                );
            if (hasDirectEpisodes) {
              _vodDetailCache[cacheKey] = (
                data: detail,
                expiresAt: now.add(const Duration(minutes: 5)),
              );
              return detail;
            }
          }
        }
      } catch (_) {}
    }

    final query = <String, String>{
      ...source.toQueryParameters(),
      'ids': vodId,
    };
    Object? backendErr;
    try {
      final data = await _getJson(
        '/api/vod/detail',
        query: query,
        timeout: Duration(seconds: source.isTvBox ? 28 : 20),
      );
      if (data is Map<String, dynamic>) {
        final list = data['list'];
        if (list is List &&
            list.isNotEmpty &&
            list.first is Map<String, dynamic>) {
          final detail = VodDetail.fromJson(list.first as Map<String, dynamic>);
          _vodDetailCache[cacheKey] = (
            data: detail,
            expiresAt: now.add(const Duration(minutes: 5)),
          );
          return detail;
        }
      }
    } catch (e) {
      backendErr = e;
    }

    if (source.isTvBox &&
        source.tvboxType == 1 &&
        _isStandardHttpCmsApi(source.api)) {
      try {
        final json = await _fetchDirectCmsJson(
          source.api,
          {'ac': 'detail', 'ids': vodId},
          timeout: const Duration(seconds: 6),
        );
        if (json != null) {
          final list = json['list'];
          if (list is List &&
              list.isNotEmpty &&
              list.first is Map<String, dynamic>) {
            final detail =
                VodDetail.fromJson(list.first as Map<String, dynamic>);
            _vodDetailCache[cacheKey] = (
              data: detail,
              expiresAt: now.add(const Duration(minutes: 5)),
            );
            return detail;
          }
        }
      } catch (_) {}
    }

    if (backendErr is ApiException) throw backendErr;
    throw const ApiException('未找到该视频的详情信息');
  }

  /// Unwraps player wrapper URLs such as `https://player.example.com/dp/?url=https://cdn.example.com/1.m3u8`
  /// when the outer URL is an HTML/PHP wrapper and its query parameter holds a direct media stream URL.
  ({String url, Map<String, String> headers}) _unwrapEmbeddedDirectStreamUrl(
    String rawUrl,
    Map<String, String> baseHeaders,
  ) {
    final split = _splitInlineStreamHeaders(rawUrl);
    final mergedHeaders = <String, String>{
      ...baseHeaders,
      ...split.headers,
    };
    final uri = Uri.tryParse(split.cleanUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return (url: split.cleanUrl, headers: mergedHeaders);
    }
    final pathLower = uri.path.toLowerCase();
    final outerIsMedia = pathLower.endsWith('.m3u8') ||
        pathLower.endsWith('.mp4') ||
        pathLower.endsWith('.flv') ||
        pathLower.endsWith('.ts') ||
        pathLower.endsWith('.mkv') ||
        pathLower.endsWith('.webm') ||
        pathLower.endsWith('.m4v') ||
        pathLower.contains('.m3u8/');
    if (!outerIsMedia && uri.queryParameters.isNotEmpty) {
      for (final qKey in const ['url', 'v', 'src', 'play', 'video']) {
        final candidate = (uri.queryParameters[qKey] ?? '').trim();
        if (candidate.isEmpty) continue;
        final innerSplit = _splitInlineStreamHeaders(candidate);
        final innerUri = Uri.tryParse(innerSplit.cleanUrl);
        if (innerUri == null ||
            (innerUri.scheme != 'http' && innerUri.scheme != 'https')) {
          continue;
        }
        final innerPath = innerUri.path.toLowerCase();
        final innerIsMedia = innerPath.endsWith('.m3u8') ||
            innerPath.endsWith('.mp4') ||
            innerPath.endsWith('.flv') ||
            innerPath.endsWith('.ts') ||
            innerPath.endsWith('.mkv') ||
            innerPath.endsWith('.webm') ||
            innerPath.endsWith('.m4v') ||
            innerPath.contains('.m3u8/');
        if (innerIsMedia) {
          mergedHeaders.addAll(innerSplit.headers);
          if (!mergedHeaders.containsKey('Referer')) {
            mergedHeaders['Referer'] = '${uri.scheme}://${uri.authority}/';
          }
          return (url: innerSplit.cleanUrl, headers: mergedHeaders);
        }
      }
    }
    return (url: split.cleanUrl, headers: mergedHeaders);
  }

  bool _isDirectPlayableVodUrl(String rawUrl) {
    final unwrapped = _unwrapEmbeddedDirectStreamUrl(rawUrl, const {});
    final uri = Uri.tryParse(unwrapped.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final pathLower = uri.path.toLowerCase();
    // Exclude HTML pages that require server-side sniffer/parser
    if (pathLower.endsWith('.html') ||
        pathLower.endsWith('.htm') ||
        pathLower.endsWith('.shtml')) {
      return false;
    }
    return pathLower.endsWith('.m3u8') ||
        pathLower.endsWith('.mp4') ||
        pathLower.endsWith('.flv') ||
        pathLower.endsWith('.ts') ||
        pathLower.endsWith('.mkv') ||
        pathLower.endsWith('.webm') ||
        pathLower.endsWith('.m4v') ||
        pathLower.contains('.m3u8/');
  }

  static String? _tryDecryptMacCmsPlayerAaaaUrl(String html) {
    final match = RegExp(
      r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*(?:;|</script>)',
      caseSensitive: false,
    ).firstMatch(html);
    if (match != null) {
      try {
        final obj = jsonDecode(match.group(1)!);
        if (obj is Map) {
          var rawUrl = (obj['url'] ?? '').toString().trim();
          final encrypt = int.tryParse((obj['encrypt'] ?? 0).toString()) ?? 0;
          if (rawUrl.isNotEmpty) {
            if (encrypt == 1) {
              rawUrl = Uri.decodeComponent(rawUrl);
            } else if (encrypt == 2) {
              final decodedB64 =
                  utf8.decode(base64.decode(base64.normalize(rawUrl)), allowMalformed: true);
              rawUrl = Uri.decodeComponent(decodedB64);
            }
            rawUrl = rawUrl.replaceAll(r'\/', '/').trim();
            if (rawUrl.startsWith('http://') ||
                rawUrl.startsWith('https://') ||
                rawUrl.startsWith('//')) {
              return VodDetail.normalizeTvboxEpisodeUrl(rawUrl);
            }
          }
        }
      } catch (_) {}
    }
    final normalizedHtml = html.replaceAll(r'\/', '/');
    final directMediaMatch = RegExp(
      r'''(https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv)(?:\?[^\s"'<>\\]*)?)''',
      caseSensitive: false,
    ).firstMatch(normalizedHtml);
    if (directMediaMatch != null) {
      return VodDetail.normalizeTvboxEpisodeUrl(directMediaMatch.group(1)!);
    }
    return null;
  }

  /// Client-side fallback sniffer/resolver for TVBox URLs:
  /// - Unwraps query-embedded direct media URLs (`?url=https://...m3u8`)
  /// - Follows HTTP 301/302/303/307/308 redirects to direct streams
  /// - Parses JSON `jx` responses (`{"url": "https://..."}` / `{"data": {"url": "..."}}`)
  /// - Extracts and decrypts MacCMS `player_aaaa` (`encrypt: 0, 1, 2`) or embedded `.m3u8`/`.mp4` from HTML pages
  Future<({String url, Map<String, String> headers})?>
      _tryClientSideResolveTvboxStream(
    String rawUrl,
    Map<String, String> baseHeaders, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final unwrapped = _unwrapEmbeddedDirectStreamUrl(rawUrl, baseHeaders);
    var currentUrl = unwrapped.url;
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      ...unwrapped.headers,
    };
    if (_isDirectPlayableVodUrl(currentUrl)) {
      return (url: currentUrl, headers: headers);
    }
    var uri = Uri.tryParse(currentUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final hc = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = ((Uri u) =>
          _findProxyForUri(u, scenarioHint: RequestScenario.vodStream))
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      for (var hop = 0; hop < 4; hop++) {
        final req = await hc.getUrl(uri!).timeout(timeout);
        req.followRedirects = false;
        headers.forEach((k, v) {
          if (k.toLowerCase() != 'host' && v.trim().isNotEmpty) {
            req.headers.set(k, v.trim());
          }
        });
        final resp = await req.close().timeout(timeout);
        final code = resp.statusCode;
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        if ((code == 301 ||
                code == 302 ||
                code == 303 ||
                code == 307 ||
                code == 308) &&
            loc != null &&
            loc.trim().isNotEmpty) {
          try {
            final sock = await resp.detachSocket();
            sock.destroy();
          } catch (_) {}
          final nextUri = uri.resolve(loc.trim());
          currentUrl = nextUri.toString();
          if (_isDirectPlayableVodUrl(currentUrl)) {
            return (url: currentUrl, headers: headers);
          }
          uri = nextUri;
          continue;
        }
        if (code < 200 || code >= 400) {
          try {
            final sock = await resp.detachSocket();
            sock.destroy();
          } catch (_) {}
          return null;
        }
        final mime = resp.headers.contentType?.mimeType.toLowerCase() ?? '';
        if (mime.contains('video/') ||
            mime.contains('mpegurl') ||
            mime.contains('m3u')) {
          try {
            final sock = await resp.detachSocket();
            sock.destroy();
          } catch (_) {}
          return (url: uri.toString(), headers: headers);
        }

        // Read up to 96 KB to inspect for #EXTM3U, JSON parser payload, or HTML player_aaaa
        final buf = BytesBuilder(copy: false);
        await for (final chunk in resp.timeout(timeout)) {
          if (chunk.isEmpty) continue;
          buf.add(chunk);
          if (buf.length >= 96 * 1024) break;
        }
        try {
          final sock = await resp.detachSocket();
          sock.destroy();
        } catch (_) {}

        final bytes = buf.takeBytes();
        if (bytes.isEmpty) return null;
        // Check MPEG-TS sync byte or MP4 ftyp box or FLV magic
        if ((bytes.length >= 189 && bytes[0] == 0x47 && bytes[188] == 0x47) ||
            (bytes.length >= 8 &&
                bytes[4] == 0x66 &&
                bytes[5] == 0x74 &&
                bytes[6] == 0x79 &&
                bytes[7] == 0x70) ||
            (bytes.length >= 3 &&
                bytes[0] == 0x46 &&
                bytes[1] == 0x4C &&
                bytes[2] == 0x56)) {
          return (url: uri.toString(), headers: headers);
        }

        final text = utf8
            .decode(bytes, allowMalformed: true)
            .replaceFirst('\uFEFF', '')
            .trimLeft();
        if (text.startsWith('#EXTM3U') || text.startsWith('#EXT')) {
          return (url: uri.toString(), headers: headers);
        }
        if (text.startsWith('{')) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map<String, dynamic>) {
              final parsed = ResolvedPlayback.fromJson(decoded);
              if (parsed.directUrl.isNotEmpty) {
                final innerSplit = _splitInlineStreamHeaders(parsed.directUrl);
                final resolvedUri = uri.resolve(innerSplit.cleanUrl);
                final nextHeaders = <String, String>{
                  ...headers,
                  ...parsed.headers,
                  ...innerSplit.headers,
                };
                return (url: resolvedUri.toString(), headers: nextHeaders);
              }
            }
          } catch (_) {}
        }
        final extractedFromHtml = _tryDecryptMacCmsPlayerAaaaUrl(text);
        if (extractedFromHtml != null && extractedFromHtml.isNotEmpty) {
          final innerSplit = _splitInlineStreamHeaders(extractedFromHtml);
          final nextHeaders = <String, String>{
            ...headers,
            'Referer': '${uri.scheme}://${uri.authority}/',
            ...innerSplit.headers,
          };
          return (url: innerSplit.cleanUrl, headers: nextHeaders);
        }
        break;
      }
    } catch (_) {
      return null;
    } finally {
      hc.close(force: true);
    }
    return null;
  }

  /// Resolve playback URL for an episode.
  /// If `preferDirectPlayback` is enabled and `episodeUrl` is already a direct
  /// `.m3u8`/`.mp4` stream URL (including TVBox sources whose detail already
  /// yields direct stream URLs), resolves locally in 0ms so playback starts immediately.
  Future<ResolvedPlayback> resolveVodPlayback(
    VodSource source, {
    required String playGroup,
    required String episodeUrl,
    bool forceServerResolve = false,
  }) async {
    final unwrappedEpisode = _unwrapEmbeddedDirectStreamUrl(episodeUrl, const {});
    final route = _proxyService?.resolveEffectiveRoute(
      RequestScenario.vodStream,
      targetUri: Uri.tryParse(unwrappedEpisode.url.trim()),
    );
    final forceRelay = route == ScenarioRouteMode.serverRelay;

    if (!forceServerResolve &&
        !forceRelay &&
        _config.preferDirectPlayback &&
        _isDirectPlayableVodUrl(unwrappedEpisode.url)) {
      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        ...unwrappedEpisode.headers,
      };
      final proxyUrl = buildServerVodProxyUrl(unwrappedEpisode.url, headers);
      return ResolvedPlayback(
        directUrl: unwrappedEpisode.url,
        proxyUrl: proxyUrl,
        serverProxyUrl: proxyUrl,
        headers: headers,
        parseVia: route == ScenarioRouteMode.proxyNode
            ? '代理节点加速 (${_proxyService?.resolveNodeForScenario(RequestScenario.vodStream)?.displayTitle ?? "Proxy"})'
            : '客户端零延迟直连',
        backendProxyPlayback: false,
      );
    }

    final query = <String, String>{
      ...source.toQueryParameters(),
      'flag': playGroup,
      'id': episodeUrl,
    };
    try {
      final data = await _getJson(
        '/api/vod/play',
        query: query,
        timeout: Duration(seconds: source.isTvBox ? 24 : 12),
      );
      if (data is Map<String, dynamic>) {
        final rawResolved = ResolvedPlayback.fromJson(data);
        final unwrappedDirect = _unwrapEmbeddedDirectStreamUrl(
          rawResolved.directUrl,
          rawResolved.headers,
        );
        var cleanDirect = unwrappedDirect.url;
        var mergedHeaders = <String, String>{
          ...unwrappedDirect.headers,
        };
        final needSniffOrParse = data['parse'] == 1 ||
            data['parse'] == '1' ||
            data['jx'] == 1 ||
            data['jx'] == '1' ||
            (cleanDirect.isNotEmpty && !_isDirectPlayableVodUrl(cleanDirect));
        if (needSniffOrParse &&
            cleanDirect.startsWith('http') &&
            !cleanDirect.contains('/api/vod/proxy')) {
          final clientSniffed = await _tryClientSideResolveTvboxStream(
            cleanDirect,
            mergedHeaders,
          );
          if (clientSniffed != null && clientSniffed.url.isNotEmpty) {
            cleanDirect = clientSniffed.url;
            mergedHeaders = clientSniffed.headers;
          } else if (!_isDirectPlayableVodUrl(cleanDirect)) {
            try {
              final extracted = await extractWebVideo(cleanDirect);
              if (extracted.isNotEmpty) {
                final best = extracted.first;
                final s = _splitInlineStreamHeaders(best.url);
                if (s.cleanUrl.isNotEmpty) {
                  cleanDirect = s.cleanUrl;
                  mergedHeaders = {
                    ...mergedHeaders,
                    ...best.headers,
                    ...s.headers,
                  };
                }
              }
            } catch (_) {}
          }
        }
        final proxyUrl = (cleanDirect.isNotEmpty &&
                cleanDirect != rawResolved.directUrl &&
                _isDirectPlayableVodUrl(cleanDirect))
            ? buildServerVodProxyUrl(cleanDirect, mergedHeaders)
            : (rawResolved.proxyUrl.isNotEmpty
                ? rawResolved.proxyUrl
                : (cleanDirect.isNotEmpty
                    ? buildServerVodProxyUrl(cleanDirect, mergedHeaders)
                    : ''));
        final serverProxyUrl = (cleanDirect.isNotEmpty &&
                cleanDirect != rawResolved.directUrl &&
                _isDirectPlayableVodUrl(cleanDirect))
            ? proxyUrl
            : (rawResolved.serverProxyUrl.isNotEmpty
                ? rawResolved.serverProxyUrl
                : proxyUrl);
        final resolved = ResolvedPlayback(
          directUrl: cleanDirect,
          proxyUrl: proxyUrl,
          serverProxyUrl: serverProxyUrl,
          headers: mergedHeaders,
          parseVia: forceRelay ? '服务端代理中转' : rawResolved.parseVia,
          backendProxyPlayback:
              forceRelay ? true : rawResolved.backendProxyPlayback,
          proxyBufferSeconds: rawResolved.proxyBufferSeconds,
        );
        return resolved;
      }
    } catch (_) {
      // Fallback 1: if `/api/vod/play` failed but `episodeUrl` is itself a direct stream URL
      if (_isDirectPlayableVodUrl(unwrappedEpisode.url)) {
        final headers = <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          ...unwrappedEpisode.headers,
        };
        final proxyUrl = buildServerVodProxyUrl(unwrappedEpisode.url, headers);
        return ResolvedPlayback(
          directUrl: unwrappedEpisode.url,
          proxyUrl: proxyUrl,
          serverProxyUrl: proxyUrl,
          headers: headers,
          parseVia: '客户端直连回退',
          backendProxyPlayback: false,
        );
      }
      // Fallback 2: try client-side TVBox stream sniffer / JSON parser / MacCMS player_aaaa extractor
      if (unwrappedEpisode.url.startsWith('http://') ||
          unwrappedEpisode.url.startsWith('https://')) {
        final clientSniffed = await _tryClientSideResolveTvboxStream(
          unwrappedEpisode.url,
          unwrappedEpisode.headers,
        );
        if (clientSniffed != null && clientSniffed.url.isNotEmpty) {
          final proxyUrl = buildServerVodProxyUrl(
            clientSniffed.url,
            clientSniffed.headers,
          );
          return ResolvedPlayback(
            directUrl: clientSniffed.url,
            proxyUrl: proxyUrl,
            serverProxyUrl: proxyUrl,
            headers: clientSniffed.headers,
            parseVia: '客户端智能嗅探解析',
            backendProxyPlayback: false,
          );
        }
      }
      rethrow;
    }
    throw const ApiException('解析播放地址失败');
  }

  /// Ultra-fast stream playability probe: verifies within [timeout] whether
  /// [rawUrl] is reachable and returns valid HTTP 200/206 stream/playlist headers.
  Future<({bool ok, int latencyMs})> probeVodStreamPlayableFast(
    String rawUrl,
    Map<String, String> baseHeaders, {
    Duration timeout = const Duration(milliseconds: 2400),
  }) async {
    final split = _splitInlineStreamHeaders(rawUrl);
    final uri = Uri.tryParse(split.cleanUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return (ok: false, latencyMs: 99999);
    }
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      ...baseHeaders,
      ...split.headers,
    };

    final sw = Stopwatch()..start();
    final hc = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = ((Uri u) =>
          _findProxyForUri(u, scenarioHint: RequestScenario.vodStream))
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await hc.getUrl(uri).timeout(timeout);
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'host' && v.trim().isNotEmpty) {
          req.headers.set(k, v.trim());
        }
      });
      final resp = await req.close().timeout(timeout);
      sw.stop();
      final ok = resp.statusCode >= 200 && resp.statusCode < 400;
      try {
        final sock = await resp.detachSocket();
        sock.destroy();
      } catch (_) {}
      return (ok: ok, latencyMs: sw.elapsedMilliseconds);
    } catch (_) {
      return (ok: false, latencyMs: 99999);
    } finally {
      hc.close(force: true);
    }
  }

  /// Cleans a VOD `.m3u8` stream by stripping `#EXT-X-DISCONTINUITY` ad blocks
  /// and known ad segments, returning a local ad-free `.m3u8` file when ads are detected.
  Future<M3u8CleanResult> cleanVodM3u8Stream(
    String url,
    Map<String, String> headers,
  ) {
    return M3u8AdRemover.cleanVodM3u8(
      url: url,
      headers: headers,
      client: _client,
    );
  }

  /// Fetch TVBox library (favorites & watch history)
  Future<({List<LibraryItem> favorites, List<LibraryItem> history})>
      fetchLibrary() async {
    final data = await _getJson('/api/tvbox/library');
    final favorites = <LibraryItem>[];
    final history = <LibraryItem>[];
    if (data is Map<String, dynamic>) {
      final rawFav = data['favorites'];
      if (rawFav is List) {
        for (final item in rawFav) {
          if (item is Map<String, dynamic>) {
            favorites.add(LibraryItem.fromJson(item));
          }
        }
      }
      final rawHist = data['history'];
      if (rawHist is List) {
        for (final item in rawHist) {
          if (item is Map<String, dynamic>) {
            history.add(LibraryItem.fromJson(item));
          }
        }
      }
    }
    return (favorites: favorites, history: history);
  }

  /// Upsert item into favorites or history
  Future<void> upsertLibraryItem(String kind, LibraryItem item) async {
    await _putJson(
      '/api/tvbox/library',
      body: {
        'kind': kind,
        'item': item.toJson(),
      },
    );
  }

  /// Delete item from favorites or history
  Future<void> deleteLibraryItem(
    String kind, {
    String? source,
    String? vodId,
  }) async {
    final query = <String, String>{'kind': kind};
    final body = <String, dynamic>{'kind': kind};
    if (source != null && source.isNotEmpty) {
      query['source'] = source;
      body['source'] = source;
    }
    if (vodId != null && vodId.isNotEmpty) {
      query['vod_id'] = vodId;
      body['vod_id'] = vodId;
    }
    if ((source == null || source.isEmpty) &&
        (vodId == null || vodId.isEmpty)) {
      query['clear'] = '1';
      body['clear'] = true;
    }
    await _deleteJson('/api/tvbox/library', query: query, body: body);
  }

  /// Fetch Live TV sources
  Future<List<LiveSource>> fetchLiveSources() async {
    final data = await _getJson(
      '/api/tvbox/lives',
      timeout: const Duration(seconds: 25),
    );
    final list = <LiveSource>[];
    if (data is List) {
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          list.add(LiveSource.fromJson(item));
        }
      }
    }
    return list;
  }

  /// Build candidate URLs for a live playlist, including fast GitHub mirrors
  /// so we can race them in parallel and avoid waiting on slow/blocked nodes.
  List<String> _buildCandidateLivePlaylistUrls(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return const [];
    final candidates = <String>[];

    void addUnique(String u) {
      final clean = u.trim();
      if (clean.isNotEmpty && !candidates.contains(clean)) {
        candidates.add(clean);
      }
    }

    String? canonicalRawGhUrl;

    // Check if URL wraps raw.githubusercontent.com via ghfast / ghproxy
    final rawGhMatch = RegExp(
      r'^https?://[^/]+/(https?://raw\.githubusercontent\.com/.+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (rawGhMatch != null) {
      canonicalRawGhUrl = rawGhMatch.group(1)!;
    }

    final rawGhNoSchemeMatch = RegExp(
      r'^https?://[^/]+/(raw\.githubusercontent\.com/.+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (rawGhNoSchemeMatch != null) {
      canonicalRawGhUrl = 'https://${rawGhNoSchemeMatch.group(1)!}';
    }

    if (canonicalRawGhUrl == null &&
        trimmed.toLowerCase().startsWith('https://raw.githubusercontent.com/')) {
      canonicalRawGhUrl = trimmed;
    }

    addUnique(trimmed);
    if (canonicalRawGhUrl != null) {
      addUnique(canonicalRawGhUrl);
      addUnique('https://ghfast.top/$canonicalRawGhUrl');
      addUnique('https://gh-proxy.com/$canonicalRawGhUrl');
    }
    return candidates;
  }

  /// Race multiple candidate playlist URLs in parallel and return the first
  /// non-empty HTTP 200 playlist body that arrives.
  Future<String?> _fetchPlaylistTextFastest(
    List<String> candidateUrls,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (candidateUrls.isEmpty) return null;
    if (candidateUrls.length == 1) {
      final res = await _client
          .get(Uri.parse(candidateUrls.first), headers: headers)
          .timeout(timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
        if (body.isNotEmpty &&
            !body.startsWith('<!DOCTYPE') &&
            !body.toLowerCase().startsWith('<html')) {
          return body;
        }
      }
      return null;
    }

    final completer = Completer<String?>();
    var remaining = candidateUrls.length;

    for (final url in candidateUrls) {
      () async {
        try {
          final res = await _client
              .get(Uri.parse(url), headers: headers)
              .timeout(timeout);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            final body =
                utf8.decode(res.bodyBytes, allowMalformed: true).trim();
            if (body.isNotEmpty &&
                !body.startsWith('<!DOCTYPE') &&
                !body.toLowerCase().startsWith('<html')) {
              if (!completer.isCompleted) {
                completer.complete(body);
              }
              return;
            }
          }
        } catch (_) {}
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }();
    }

    return completer.future;
  }

  /// Parse M3U (`#EXTM3U` / `#EXTINF`) or TVBox `.txt` (`分组,#genre#`) playlist
  /// content directly on the client.
  List<LiveChannel> parseLivePlaylistText(
    String content, {
    Map<String, String> defaultHeaders = const {},
  }) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return const [];

    // If JSON array was returned
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded
              .whereType<Map<String, dynamic>>()
              .map(LiveChannel.fromJson)
              .where((c) => c.urls.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }

    // Reject HTML error pages (e.g. 403/404 nginx pages)
    if (trimmed.startsWith('<!DOCTYPE') ||
        trimmed.toLowerCase().startsWith('<html')) {
      return const [];
    }

    final lines = const LineSplitter().convert(trimmed);
    final isM3u = trimmed.startsWith('#EXTM3U') ||
        lines.any((l) => l.trimLeft().startsWith('#EXTINF'));

    final groupedMap = <String, LiveChannel>{};
    final orderedKeys = <String>[];

    String sanitizeRawStreamUrl(String raw) {
      var u = raw.trim();
      if (u.isEmpty) return '';
      // Split inline pipe headers if present so we only clean the URL portion
      String pipeSuffix = '';
      final pipeIdx = u.indexOf('|');
      if (pipeIdx > 0) {
        pipeSuffix = u.substring(pipeIdx);
        u = u.substring(0, pipeIdx).trim();
      }
      // Strip TVBox $label suffix (e.g. http://[2409:...]/1.m3u8$IPV6)
      final dollarIdx = u.indexOf(r'$');
      if (dollarIdx > 0) {
        u = u.substring(0, dollarIdx).trim();
      }
      // Strip trailing bare '?' with empty query so media_kit URI cache matches mpv path
      if (u.endsWith('?')) {
        u = u.substring(0, u.length - 1);
      }
      return '$u$pipeSuffix';
    }

    String normalizeChannelMatchKey(String name) {
      var s = name.toUpperCase().replaceAll(' ', '').replaceAll('-', '');
      final cctvMatch = RegExp(r'^CCTV(\d+\+?)').firstMatch(s);
      if (cctvMatch != null) {
        return 'CCTV${cctvMatch.group(1)}';
      }
      return s;
    }

    final matchKeyToOrderedKey = <String, String>{};

    void addChannelEntry({
      required String name,
      required String group,
      required List<String> urls,
      String logo = '',
      Map<String, String> headers = const {},
    }) {
      final cleanName = name.trim().isEmpty ? '未知频道' : name.trim();
      final cleanGroup = group.trim().isEmpty ? '默认分组' : group.trim();
      final validUrls = urls
          .map(sanitizeRawStreamUrl)
          .where(
            (u) =>
                u.startsWith('http://') ||
                u.startsWith('https://') ||
                u.startsWith('rtmp://') ||
                u.startsWith('rtsp://') ||
                u.startsWith('mms://') ||
                u.startsWith('rtp://') ||
                u.startsWith('udp://'),
          )
          .toList();
      if (validUrls.isEmpty) return;

      final matchKey = normalizeChannelMatchKey(cleanName);
      final key = matchKeyToOrderedKey[matchKey] ?? '$cleanGroup@@$cleanName';
      matchKeyToOrderedKey.putIfAbsent(matchKey, () => key);

      final existing = groupedMap[key];
      if (existing != null) {
        final mergedUrls = [...existing.urls];
        for (final u in validUrls) {
          if (!mergedUrls.contains(u)) mergedUrls.add(u);
        }
        // Sort known dead archived [2409:8087:8:21::18]:6610 URLs after active URLs
        mergedUrls.sort((a, b) {
          final aDead = a.contains('[2409:8087:8:21::18]:6610') ? 1 : 0;
          final bDead = b.contains('[2409:8087:8:21::18]:6610') ? 1 : 0;
          return aDead.compareTo(bDead);
        });
        groupedMap[key] = LiveChannel(
          name: existing.name,
          group: existing.group,
          urls: mergedUrls,
          logo: existing.logo.isNotEmpty ? existing.logo : logo,
          headers: {...existing.headers, ...headers},
        );
      } else {
        orderedKeys.add(key);
        groupedMap[key] = LiveChannel(
          name: cleanName,
          group: cleanGroup,
          urls: validUrls,
          logo: logo,
          headers: headers,
        );
      }
    }

    if (isM3u) {
      String pendingName = '';
      String pendingGroup = '默认分组';
      String pendingLogo = '';
      final pendingHeaders = <String, String>{...defaultHeaders};

      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;

        if (line.startsWith('#EXTINF')) {
          final groupMatch =
              RegExp(r'group-title="([^"]*)"', caseSensitive: false)
                  .firstMatch(line);
          final logoMatch =
              RegExp(r'tvg-logo="([^"]*)"', caseSensitive: false)
                  .firstMatch(line);
          final nameMatch =
              RegExp(r'tvg-name="([^"]*)"', caseSensitive: false)
                  .firstMatch(line);
          final uaMatch = RegExp(
            r'(?:http-user-agent|user-agent)="([^"]*)"',
            caseSensitive: false,
          ).firstMatch(line);
          final refMatch = RegExp(
            r'(?:http-referrer|http-referer|referer)="([^"]*)"',
            caseSensitive: false,
          ).firstMatch(line);

          pendingGroup = groupMatch?.group(1)?.trim().isNotEmpty == true
              ? groupMatch!.group(1)!.trim()
              : '默认分组';
          pendingLogo = logoMatch?.group(1)?.trim() ?? '';
          if (uaMatch?.group(1)?.trim().isNotEmpty == true) {
            pendingHeaders['User-Agent'] = uaMatch!.group(1)!.trim();
          }
          if (refMatch?.group(1)?.trim().isNotEmpty == true) {
            pendingHeaders['Referer'] = refMatch!.group(1)!.trim();
          }

          final commaIdx = line.lastIndexOf(',');
          if (commaIdx >= 0 && commaIdx + 1 < line.length) {
            pendingName = line.substring(commaIdx + 1).trim();
          } else {
            pendingName = nameMatch?.group(1)?.trim() ?? '直播频道';
          }
        } else if (line.startsWith('#EXTVLCOPT:')) {
          final opt = line.substring('#EXTVLCOPT:'.length).trim();
          final eq = opt.indexOf('=');
          if (eq > 0) {
            final k = opt.substring(0, eq).trim().toLowerCase();
            final v = opt.substring(eq + 1).trim();
            if (k == 'http-user-agent' && v.isNotEmpty) {
              pendingHeaders['User-Agent'] = v;
            } else if ((k == 'http-referrer' || k == 'http-referer') &&
                v.isNotEmpty) {
              pendingHeaders['Referer'] = v;
            } else if (k == 'http-origin' && v.isNotEmpty) {
              pendingHeaders['Origin'] = v;
            }
          }
        } else if (!line.startsWith('#')) {
          addChannelEntry(
            name: pendingName.isNotEmpty ? pendingName : '直播频道',
            group: pendingGroup,
            urls: [line],
            logo: pendingLogo,
            headers: {...pendingHeaders},
          );
          pendingName = '';
          pendingLogo = '';
          pendingHeaders
            ..clear()
            ..addAll(defaultHeaders);
        }
      }
    } else {
      // TVBox TXT format: `Group Name,#genre#` and `Channel Name,url1#url2`
      String currentGroup = '默认分组';
      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
          continue;
        }
        final commaIdx = line.indexOf(',');
        if (commaIdx <= 0) continue;
        final left = line.substring(0, commaIdx).trim();
        final right = line.substring(commaIdx + 1).trim();
        if (right.toLowerCase().contains('#genre#')) {
          currentGroup = left.isNotEmpty ? left : '默认分组';
          continue;
        }
        final rawUrls = right
            .split('#')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        addChannelEntry(
          name: left,
          group: currentGroup,
          urls: rawUrls,
          headers: {...defaultHeaders},
        );
      }
    }

    return orderedKeys.map((k) => groupedMap[k]!).toList();
  }

  /// Fetch Live TV channels for a live source.
  /// Defaults to fetching and parsing the playlist directly on the client
  /// by racing candidate mirrors in parallel and caching parsed channels.
  Future<List<LiveChannel>> fetchLiveChannels(
    LiveSource source, {
    bool preferClientDirect = true,
    bool forceRefresh = false,
  }) async {
    final route = _proxyService?.resolveEffectiveRoute(
      RequestScenario.liveStream,
      targetUri: Uri.tryParse(source.url.trim()),
    );
    final effectiveDirect =
        route == ScenarioRouteMode.serverRelay ? false : preferClientDirect;
    final cacheKey = '${source.key}|$effectiveDirect';
    if (!forceRefresh) {
      final cached = _liveChannelCache[cacheKey];
      if (cached != null && cached.isNotEmpty) {
        return cached;
      }
    }

    final sourceUrl = source.url.trim();
    final isLocalLoopback = sourceUrl.contains('://127.0.0.1') ||
        sourceUrl.contains('://localhost');

    if (effectiveDirect && sourceUrl.isNotEmpty && !isLocalLoopback) {
      final candidates = _buildCandidateLivePlaylistUrls(sourceUrl);
      try {
        var text = await _fetchPlaylistTextFastest(
          candidates,
          source.defaultHeaders,
          timeout: const Duration(seconds: 7),
        );
        if (text != null && text.isNotEmpty) {
          if (sourceUrl.toLowerCase().contains('fanmingming/live')) {
            const supplementUrls = [
              'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv6/result.m3u',
              'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
            ];
            final supResults = await Future.wait(
              supplementUrls.map(
                (supUrl) => _fetchPlaylistTextFastest(
                  _buildCandidateLivePlaylistUrls(supUrl),
                  source.defaultHeaders,
                  timeout: const Duration(seconds: 4),
                ),
              ),
            );
            final validSup = supResults
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .toList();
            if (validSup.isNotEmpty) {
              text = '${validSup.join('\n')}\n$text';
            }
          }

          final parsed = parseLivePlaylistText(
            text,
            defaultHeaders: source.defaultHeaders,
          );
          if (parsed.isNotEmpty) {
            _liveChannelCache[cacheKey] = parsed;
            return parsed;
          }
        }
      } catch (e) {
        if (source.isCustom) {
          throw ApiException('直接加载直播源失败：$e');
        }
      }
    }

    if (source.isCustom) {
      throw const ApiException('该自定义直播源无法解析出有效频道');
    }

    // Fallback to server-side channel parsing
    final data = await _getJson(
      '/api/tvbox/live/channels',
      query: {
        'tvbox_source': source.sourceIndex.toString(),
        'tvbox_live': source.liveIndex.toString(),
      },
      timeout: const Duration(seconds: 15),
    );
    final list = <LiveChannel>[];
    if (data is List) {
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          final ch = LiveChannel.fromJson(item);
          if (ch.urls.isNotEmpty) list.add(ch);
        }
      }
    }
    if (list.isNotEmpty) {
      _liveChannelCache[cacheKey] = list;
    }
    return list;
  }

  static String _stripTvboxUrlDollarSuffixStatic(String raw) {
    var u = raw.trim().replaceAll('&amp;', '&');
    if (u.isEmpty) return '';
    if (u.startsWith('//') && u.length > 4) {
      u = 'https:$u';
    }
    String pipeSuffix = '';
    final pipeIdx = u.indexOf('|');
    if (pipeIdx > 0) {
      pipeSuffix = u.substring(pipeIdx);
      u = u.substring(0, pipeIdx).trim();
    }
    var schemeIdx = u.indexOf('://');
    final firstDollar = u.indexOf(r'$');
    // 1. If `$` appears BEFORE `://` (e.g. `正片$https://example.com/1.m3u8`),
    // strip the episode title prefix before `$` instead of truncating the URL!
    if (firstDollar >= 0 && schemeIdx > firstDollar) {
      u = u.substring(firstDollar + 1).trim();
      if (u.startsWith('//') && u.length > 4) {
        u = 'https:$u';
      }
      schemeIdx = u.indexOf('://');
    }
    // 2. If `$` appears AFTER `://`, only strip it if it is a TVBox live line
    // comment label (e.g. `http://.../1.m3u8$IPV6`, `http://.../live$高清`),
    // and NEVER truncate URLs where `$` is part of the path or query string
    // (such as `https://cdn.example.com/v1/play$hd.m3u8` or `?token=a$b`).
    final tailDollar = u.lastIndexOf(r'$');
    if (tailDollar > 0 && (schemeIdx < 0 || tailDollar > schemeIdx + 3)) {
      final before = u.substring(0, tailDollar).trim();
      final after = u.substring(tailDollar + 1).trim();
      final isCommentLabel = !after.contains('/') &&
          !after.contains('.') &&
          !after.contains('=') &&
          !after.contains('&') &&
          !after.contains('?') &&
          (before.toLowerCase().endsWith('.m3u8') ||
              before.toLowerCase().endsWith('.flv') ||
              before.toLowerCase().endsWith('.ts') ||
              before.toLowerCase().endsWith('.mp4') ||
              RegExp(r'[^\x00-\x7F]').hasMatch(after) ||
              RegExp(
                r'^(ipv[46]|hd|fhd|uhd|sd|4k|1080p|720p|line\d*)$',
                caseSensitive: false,
              ).hasMatch(after));
      if (isCommentLabel) {
        u = before;
      }
    }
    while (u.endsWith('?')) {
      u = u.substring(0, u.length - 1);
    }
    return '$u$pipeSuffix';
  }

  /// Extract inline headers from TVBox pipe (`|Key=Val&...`), JSON (`#{"User-Agent":...}` / `|{"Referer":...}`),
  /// or `@Key=Val` URLs such as:
  /// - `https://example.com/live.flv|User-Agent=okhttp/3.15&Referer=https://example.com/`
  /// - `https://img3.doubanio.com/...jpg@Referer=https://api.douban.com/@User-Agent=Mozilla/5.0...`
  static ({String cleanUrl, Map<String, String> headers})
      splitTvboxUrlAndHeaders(String rawUrl) {
    var working = _stripTvboxUrlDollarSuffixStatic(rawUrl.trim());
    if (working.isEmpty) {
      return (cleanUrl: '', headers: const {});
    }
    final headers = <String, String>{};

    void putNormalizedHeader(String rawKey, String rawVal) {
      final k = rawKey.trim();
      var v = rawVal.trim();
      try {
        v = Uri.decodeComponent(v);
      } catch (_) {}
      if (k.isEmpty || v.isEmpty) return;
      final lower = k.toLowerCase();
      if (lower == 'user-agent' || lower == 'ua') {
        headers['User-Agent'] = v;
      } else if (lower == 'referer' || lower == 'referrer') {
        headers['Referer'] = v;
      } else if (lower == 'origin') {
        headers['Origin'] = v;
      } else if (lower == 'cookie') {
        headers['Cookie'] = v;
      } else {
        headers[k] = v;
      }
    }

    // 0. Handle trailing `#{"User-Agent":"...","Referer":"..."}` JSON header fragment
    final hashJsonIdx = working.indexOf('#{');
    if (hashJsonIdx > 0) {
      final jsonPart = working.substring(hashJsonIdx + 1).trim();
      try {
        final decoded = jsonDecode(jsonPart);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k != null && v != null) {
              putNormalizedHeader(k.toString(), v.toString());
            }
          });
          working = _stripTvboxUrlDollarSuffixStatic(
            working.substring(0, hashJsonIdx).trim(),
          );
        }
      } catch (_) {}
    }

    // 1. Handle TVBox `@Referer=...` / `@User-Agent=...` / `@Cookie=...` suffixes
    final atHeaderRegex = RegExp(
      r'@(Referer|Referrer|User-Agent|UA|Cookie|Origin|Authorization|Accept)=',
      caseSensitive: false,
    );
    final atMatches = atHeaderRegex.allMatches(working).toList();
    if (atMatches.isNotEmpty) {
      final firstStart = atMatches.first.start;
      for (var i = 0; i < atMatches.length; i++) {
        final m = atMatches[i];
        final key = m.group(1) ?? '';
        final valStart = m.end;
        final valEnd = (i + 1 < atMatches.length)
            ? atMatches[i + 1].start
            : working.length;
        var val = working.substring(valStart, valEnd).trim();
        final pipeInVal = val.indexOf('|');
        if (pipeInVal >= 0) {
          val = val.substring(0, pipeInVal).trim();
        }
        putNormalizedHeader(key, val);
      }
      working = _stripTvboxUrlDollarSuffixStatic(
        working.substring(0, firstStart).trim(),
      );
    }

    // 2. Handle `|Key=Val&Key2=Val2` or `|{"User-Agent":"..."}` pipe suffixes
    final pipeIdx = working.indexOf('|');
    if (pipeIdx >= 0) {
      final headerPart = working.substring(pipeIdx + 1).trim();
      working = _stripTvboxUrlDollarSuffixStatic(
        working.substring(0, pipeIdx).trim(),
      );
      if (headerPart.startsWith('{')) {
        try {
          final decoded = jsonDecode(headerPart);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (k != null && v != null) {
                putNormalizedHeader(k.toString(), v.toString());
              }
            });
          }
        } catch (_) {}
      } else {
        for (final pair in headerPart.split('&')) {
          final eq = pair.indexOf('=');
          if (eq <= 0) continue;
          putNormalizedHeader(
            pair.substring(0, eq),
            pair.substring(eq + 1),
          );
        }
      }
    }

    return (cleanUrl: working, headers: headers);
  }

  String _stripTvboxUrlDollarSuffix(String raw) =>
      _stripTvboxUrlDollarSuffixStatic(raw);

  ({String cleanUrl, Map<String, String> headers}) _splitInlineStreamHeaders(
    String rawUrl,
  ) =>
      splitTvboxUrlAndHeaders(rawUrl);

  bool _isDirectStreamMediaUri(Uri uri) {
    final host = uri.host.toLowerCase();
    // IPv6 literals or raw IPv4 OTT paths should be opened directly by libmpv
    if (host.contains(':')) return true;
    final pathLower = uri.path.toLowerCase();
    // Douyu / Huya / YY redirect gateways (e.g. live.ottiptv.cc/douyu/123456) must NOT pre-open
    // a dummy HTTP connection because their 302 CDN tickets are single-use; let libmpv follow the 302 directly!
    if (pathLower.contains('/douyu/') ||
        pathLower.contains('/huya/') ||
        pathLower.contains('/yy/') ||
        host.contains('ottiptv.cc') ||
        host.contains('douyucdn')) {
      return true;
    }
    if (pathLower.endsWith('.m3u8') ||
        pathLower.endsWith('.flv') ||
        pathLower.endsWith('.ts') ||
        pathLower.endsWith('.mp4') ||
        pathLower.endsWith('.mkv') ||
        pathLower.endsWith('.aac') ||
        pathLower.contains('.m3u8/') ||
        pathLower.contains('/pltv/') ||
        pathLower.contains('/00000000') ||
        pathLower.contains('/rtp/') ||
        pathLower.contains('/udp/')) {
      return true;
    }
    return false;
  }

  /// Resolve HTTP 301/302/303/307/308 on gateway/redirector URLs (such as
  /// `live.ottiptv.cc/douyu/...` or `.../huya/...`) WITHOUT pre-connecting to
  /// the resulting `.flv` / `.m3u8` stream URL.
  Future<String> _resolveLiveStreamRedirectClient(
    String initialUrl,
    Map<String, String> headers,
  ) async {
    Uri currentUri;
    try {
      currentUri = Uri.parse(initialUrl);
    } catch (_) {
      return initialUrl;
    }
    if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
      return initialUrl;
    }

    // If the URL already points to a media stream or IPv6 literal, let libmpv
    // open it directly in a single session (0ms overhead).
    if (_isDirectStreamMediaUri(currentUri)) {
      return _stripTvboxUrlDollarSuffix(currentUri.toString());
    }

    final now = DateTime.now();
    final cached = _redirectUrlCache[initialUrl];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      return cached.url;
    }

    try {
      for (var hop = 0; hop < 2; hop++) {
        if (_isDirectStreamMediaUri(currentUri)) {
          break;
        }
        final request = await _rawHttpClient
            .getUrl(currentUri)
            .timeout(const Duration(milliseconds: 2200));
        request.followRedirects = false;
        headers.forEach((k, v) {
          if (v.trim().isNotEmpty) {
            request.headers.set(k, v.trim());
          }
        });

        final response = await request
            .close()
            .timeout(const Duration(milliseconds: 2200));
        final code = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);

        // Immediately abort socket body so we don't stream video data here
        try {
          final socket = await response.detachSocket();
          socket.destroy();
        } catch (_) {}

        if ((code == 301 ||
                code == 302 ||
                code == 303 ||
                code == 307 ||
                code == 308) &&
            location != null &&
            location.trim().isNotEmpty) {
          currentUri = currentUri.resolve(location.trim());
          if (_isDirectStreamMediaUri(currentUri)) {
            break;
          }
          continue;
        }
        break;
      }
    } catch (_) {
      // If pre-resolution times out or fails, let native libmpv open currentUri directly
    }

    final result = _stripTvboxUrlDollarSuffix(currentUri.toString());
    if (result != initialUrl) {
      _redirectUrlCache[initialUrl] = (
        url: result,
        expiresAt: now.add(const Duration(seconds: 75)),
      );
    }
    return result;
  }

  bool _isFakeIpAddress(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4) return false;
    final raw = addr.rawAddress;
    return raw.length == 4 && raw[0] == 198 && (raw[1] >= 18 && raw[1] <= 21);
  }

  /// Resolve IPv6-only domains or bypass router Fake-IP DNS hijacking via DoH
  /// (`223.5.5.5`) when needed, with in-memory host caching for 0ms repeat lookups.
  Future<({String url, Map<String, String> headers})>
      _resolveIpv6OrFakeIpIfNeeded(
    String rawUrl,
    Map<String, String> headers, {
    bool forceDohLookup = false,
  }) async {
    Uri uri;
    try {
      uri = Uri.parse(rawUrl);
    } catch (_) {
      return (url: rawUrl, headers: headers);
    }
    if (uri.scheme != 'http') {
      return (url: rawUrl, headers: headers);
    }

    final host = uri.host.toLowerCase();
    if (host.isEmpty ||
        host.contains(':') ||
        InternetAddress.tryParse(host) != null) {
      return (url: rawUrl, headers: headers);
    }

    // Fast path: do not block normal domain playback on DNS/DoH unless the
    // domain is an explicit IPv6/CERNET host or `forceDohLookup` is requested.
    final isLikelyIpv6Domain =
        host.contains('ipv6') || host.endsWith('.edu.cn');
    if (!forceDohLookup && !isLikelyIpv6Domain) {
      return (url: rawUrl, headers: headers);
    }

    final now = DateTime.now();
    final cached = _dohHostCache[host];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      final newHost = cached.recordType == 28 ? '[${cached.ip}]' : cached.ip;
      final originalAuthority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      return (
        url: uri.replace(host: newHost).toString(),
        headers: <String, String>{...headers, 'Host': originalAuthority},
      );
    }

    bool needsDohLookup = forceDohLookup;
    if (!needsDohLookup) {
      try {
        final addrs = await InternetAddress.lookup(host)
            .timeout(const Duration(milliseconds: 900));
        if (addrs.isEmpty || addrs.every(_isFakeIpAddress)) {
          needsDohLookup = true;
        }
      } catch (_) {
        needsDohLookup = true;
      }
    }

    if (!needsDohLookup) {
      return (url: rawUrl, headers: headers);
    }

    // Query AliDNS DoH for AAAA (28) and A (1) records
    for (final recordType in const [28, 1]) {
      try {
        final dohUri = Uri.parse(
          'https://223.5.5.5/resolve?name=${Uri.encodeQueryComponent(host)}&type=$recordType',
        );
        final res = await _client
            .get(dohUri, headers: const {'Accept': 'application/dns-json'})
            .timeout(const Duration(milliseconds: 1500));
        if (res.statusCode == 200) {
          final body = jsonDecode(utf8.decode(res.bodyBytes));
          if (body is Map<String, dynamic> && body['Answer'] is List) {
            for (final ans in body['Answer'] as List) {
              if (ans is Map &&
                  ans['type'] == recordType &&
                  ans['data'] is String) {
                final ip = (ans['data'] as String).trim();
                if (ip.isNotEmpty) {
                  _dohHostCache[host] = (
                    ip: ip,
                    recordType: recordType,
                    expiresAt: now.add(const Duration(minutes: 10)),
                  );
                  final newHost = recordType == 28 ? '[$ip]' : ip;
                  final originalAuthority =
                      uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
                  final rewrittenUri = uri.replace(host: newHost);
                  return (
                    url: rewrittenUri.toString(),
                    headers: <String, String>{
                      ...headers,
                      'Host': originalAuthority,
                    },
                  );
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    return (url: rawUrl, headers: headers);
  }

  /// Build server `/api/vod/proxy` URL for a given stream URL and headers
  String buildServerVodProxyUrl(
    String streamUrl,
    Map<String, String> headers,
  ) {
    final query = <String, String>{'url': streamUrl};
    if (headers.isNotEmpty) {
      final encodedHeaders = base64Url
          .encode(utf8.encode(jsonEncode(headers)))
          .replaceAll('=', '');
      query['headers'] = encodedHeaders;
    }
    return _buildUri('/api/vod/proxy', query).toString();
  }

  /// Resolve Live TV stream URL.
  /// By default (`preferClientDirect: true`), resolves gateway redirects and
  /// headers directly on the client device to avoid browser CORS, Mixed Content,
  /// and server datacenter IP blocking.
  Future<ResolvedPlayback> resolveLivePlayback(
    LiveSource source,
    String rawChannelUrl, {
    Map<String, String>? channelHeaders,
    bool preferClientDirect = true,
  }) async {
    final split = _splitInlineStreamHeaders(rawChannelUrl);
    final route = _proxyService?.resolveEffectiveRoute(
      RequestScenario.liveStream,
      targetUri: Uri.tryParse(split.cleanUrl),
    );
    final effectiveDirect =
        route == ScenarioRouteMode.serverRelay ? false : preferClientDirect;
    final lowerClean = split.cleanUrl.toLowerCase();
    final isFlvGateway = lowerClean.contains('ottiptv.cc') ||
        lowerClean.contains('/douyu/') ||
        lowerClean.contains('/huya/') ||
        lowerClean.contains('/yy/') ||
        lowerClean.contains('douyucdn');
    final mergedHeaders = <String, String>{
      ...source.defaultHeaders,
      if (channelHeaders != null) ...channelHeaders,
      ...split.headers,
    };
    if (isFlvGateway) {
      final curUa = (mergedHeaders['User-Agent'] ?? '').trim().toLowerCase();
      if (curUa.isEmpty || curUa == 'okhttp/3.15') {
        mergedHeaders['User-Agent'] = 'okHttp/Mod-1.5.0.0';
      }
    }

    if (effectiveDirect) {
      var targetDirectUrl = split.cleanUrl;
      final lowerPath = (Uri.tryParse(targetDirectUrl)?.path ?? '').toLowerCase();
      final isStandardStream = lowerPath.endsWith('.m3u8') ||
          lowerPath.endsWith('.ts') ||
          lowerPath.contains('.m3u8/') ||
          lowerPath.contains('/pltv/') ||
          targetDirectUrl.contains('://[');
      if (!source.isCustom && (!isStandardStream || isFlvGateway)) {
        try {
          final data = await _getJson(
            '/api/tvbox/live/play',
            query: {
              'tvbox_source': source.sourceIndex.toString(),
              'tvbox_live': source.liveIndex.toString(),
              'url': split.cleanUrl,
            },
            timeout: const Duration(seconds: 5),
          );
          if (data is Map<String, dynamic>) {
            final srvResolved = ResolvedPlayback.fromJson(data);
            if (srvResolved.directUrl.isNotEmpty &&
                !srvResolved.directUrl.contains('/api/vod/proxy')) {
              final s2 = _splitInlineStreamHeaders(srvResolved.directUrl);
              if (s2.cleanUrl.isNotEmpty) {
                targetDirectUrl = s2.cleanUrl;
              }
              mergedHeaders.addAll(s2.headers);
            }
            srvResolved.headers.forEach((k, v) {
              if (v.trim().isNotEmpty) {
                mergedHeaders[k] = v.trim();
              }
            });
          }
        } catch (_) {}
      }

      final redirectedUrl = await _resolveLiveStreamRedirectClient(
        targetDirectUrl,
        mergedHeaders,
      );
      final dohResolved = await _resolveIpv6OrFakeIpIfNeeded(
        redirectedUrl,
        mergedHeaders,
      );
      final proxyUrl = buildServerVodProxyUrl(
        targetDirectUrl,
        dohResolved.headers,
      );
      return ResolvedPlayback(
        directUrl: dohResolved.url,
        proxyUrl: proxyUrl,
        serverProxyUrl: proxyUrl,
        headers: dohResolved.headers,
        parseVia: route == ScenarioRouteMode.proxyNode
            ? '代理节点加速 (${_proxyService?.resolveNodeForScenario(RequestScenario.liveStream)?.displayTitle ?? "Proxy"})'
            : '客户端直连',
        backendProxyPlayback: false,
      );
    }

    if (!source.isCustom) {
      try {
        final data = await _getJson(
          '/api/tvbox/live/play',
          query: {
            'tvbox_source': source.sourceIndex.toString(),
            'tvbox_live': source.liveIndex.toString(),
            'url': split.cleanUrl,
          },
        );
        if (data is Map<String, dynamic>) {
          return ResolvedPlayback.fromJson(data);
        }
      } catch (_) {}
    }

    final proxyUrl = buildServerVodProxyUrl(split.cleanUrl, mergedHeaders);
    return ResolvedPlayback(
      directUrl: split.cleanUrl,
      proxyUrl: proxyUrl,
      serverProxyUrl: proxyUrl,
      headers: mergedHeaders,
      parseVia: '服务端代理',
      backendProxyPlayback: true,
    );
  }

  Future<bool> _probeSingleLiveUrlClient(
    String rawUrl,
    Map<String, String> baseHeaders,
  ) async {
    final split = _splitInlineStreamHeaders(rawUrl);
    final headers = <String, String>{...baseHeaders, ...split.headers};
    Uri currentUri;
    try {
      currentUri = Uri.parse(split.cleanUrl);
    } catch (_) {
      return false;
    }
    if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
      return true;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = ((Uri uri) =>
          _findProxyForUri(uri, scenarioHint: RequestScenario.liveStream))
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;

    try {
      for (var hop = 0; hop < 4; hop++) {
        final req = await client
            .getUrl(currentUri)
            .timeout(const Duration(seconds: 4));
        req.followRedirects = false;
        headers.forEach((k, v) {
          if (v.trim().isNotEmpty) req.headers.set(k, v.trim());
        });

        final resp = await req.close().timeout(const Duration(seconds: 4));
        final code = resp.statusCode;
        final location = resp.headers.value(HttpHeaders.locationHeader);

        try {
          final socket = await resp.detachSocket();
          socket.destroy();
        } catch (_) {}

        if ((code == 301 ||
                code == 302 ||
                code == 303 ||
                code == 307 ||
                code == 308) &&
            location != null &&
            location.trim().isNotEmpty) {
          currentUri = currentUri.resolve(location.trim());
          continue;
        }
        return code >= 200 && code < 400;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Check Live TV URLs health directly from the client device (default) or via server
  Future<Map<String, bool>> checkLiveHealth(
    LiveSource source,
    List<String> urls, {
    bool preferClientDirect = true,
  }) async {
    if (preferClientDirect) {
      final result = <String, bool>{};
      final baseHeaders = source.defaultHeaders;
      const batchSize = 6;
      for (var i = 0; i < urls.length; i += batchSize) {
        final batch = urls.skip(i).take(batchSize).toList();
        final checks = await Future.wait(
          batch.map((u) async => MapEntry(u, await _probeSingleLiveUrlClient(u, baseHeaders))),
        );
        for (final entry in checks) {
          result[entry.key] = entry.value;
        }
      }
      return result;
    }

    final data = await _postJson(
      '/api/tvbox/live/health',
      body: {
        'tvbox_source': source.sourceIndex,
        'tvbox_live': source.liveIndex,
        'urls': urls,
      },
    );
    final result = <String, bool>{};
    if (data is List) {
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          final url = (item['url'] ?? '').toString();
          if (url.isNotEmpty) {
            result[url] = item['ok'] == true;
          }
        }
      }
    }
    return result;
  }

  /// Fetch download tasks
  Future<List<DownloadTask>> fetchDownloadTasks() async {
    final data = await _getJson('/api/tasks');
    final tasks = <DownloadTask>[];
    if (data is List) {
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          tasks.add(DownloadTask.fromJson(item));
        }
      }
    }
    return tasks;
  }

  /// Create a download task and return its task ID (or `duplicate_of_task_id` if deduplicated)
  Future<String?> createDownloadTask({
    required String url,
    required String name,
    Map<String, String>? headers,
    Map<String, dynamic>? videoContext,
    String? telegramAccountId,
    bool forceDuplicate = false,
  }) async {
    final data = await _postJson(
      '/api/download',
      body: {
        'url': url.trim(),
        'name': name.trim(),
        if (headers != null && headers.isNotEmpty) 'headers': headers,
        if (videoContext != null) 'video_context': videoContext,
        if (telegramAccountId != null && telegramAccountId.isNotEmpty)
          'telegram_account_id': telegramAccountId,
        if (forceDuplicate) 'force_duplicate': true,
      },
    );
    if (data is Map<String, dynamic>) {
      final dupId = (data['duplicate_of_task_id'] ?? '').toString().trim();
      if (dupId.isNotEmpty) return dupId;
      final id = (data['id'] ?? '').toString().trim();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  /// Retry a download task
  Future<void> retryDownloadTask(String id) async {
    await _postJson('/api/tasks/$id/retry');
  }

  /// Delete a single download task
  Future<void> deleteDownloadTask(String id, {bool deleteFiles = false}) async {
    await _deleteJson(
      '/api/tasks/$id',
      query: {'delete_files': deleteFiles ? 'true' : 'false'},
    );
  }

  /// Batch delete download tasks
  Future<void> batchDeleteDownloadTasks(List<String> ids) async {
    await _deleteJson('/api/tasks', body: {'ids': ids});
  }

  /// Manually trigger 115 upload for a completed task
  Future<void> uploadTaskTo115(String id) async {
    await _postJson('/api/115/upload/$id');
  }

  /// Extract playable/downloadable video URLs from webpage URL or share text
  Future<List<ExtractedVideoCandidate>> extractWebVideo(String urlOrText) async {
    final data = await _postJson(
      '/api/web/extract',
      body: {'url': urlOrText.trim()},
      timeout: const Duration(seconds: 40),
    );
    final list = <ExtractedVideoCandidate>[];
    if (data is Map<String, dynamic>) {
      final rawCandidates =
          data['candidates'] ?? data['items'] ?? data['videos'] ?? data['list'];
      if (rawCandidates is List) {
        for (final item in rawCandidates) {
          if (item is Map<String, dynamic>) {
            final c = ExtractedVideoCandidate.fromJson(item);
            if (c.url.isNotEmpty) list.add(c);
          }
        }
      }
      if (list.isEmpty && data['url'] != null) {
        final c = ExtractedVideoCandidate.fromJson(data);
        if (c.url.isNotEmpty) list.add(c);
      }
    }
    return list;
  }

  /// Browse server media library files
  Future<FileDirectoryListing> fetchFiles({String path = ''}) async {
    final query = <String, String>{};
    if (path.isNotEmpty) query['path'] = path;
    final data = await _getJson('/api/files', query: query);
    if (data is Map<String, dynamic>) {
      return FileDirectoryListing.fromJson(data);
    }
    if (data is List) {
      final entries = <FileEntry>[];
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          final name = (item['name'] ?? '').toString().trim();
          final rawPath = (item['path'] ?? '').toString().trim();
          final dot = name.lastIndexOf('.');
          final ext = (item['ext'] ??
                  (dot > 0 && dot < name.length - 1 ? name.substring(dot) : ''))
              .toString();
          entries.add(
            FileEntry.fromJson({
              ...item,
              'path': rawPath.isNotEmpty ? rawPath : name,
              'ext': ext,
            }),
          );
        }
      }
      return FileDirectoryListing(
        path: path,
        parent: '',
        root: '/',
        entries: entries,
      );
    }
    throw const ApiException('读取媒体库目录失败');
  }

  /// Build direct streaming URL for a file in the server media library
  String buildFileStreamUrl(String filePath) {
    return _buildUri('/api/files/open', {'path': filePath}).toString();
  }

  /// Build direct download URL for a file in the server media library
  String buildFileDownloadUrl(String filePath) {
    return _buildUri('/api/files/download', {'path': filePath}).toString();
  }

  /// Convert a TS video file to MP4 on the server
  Future<void> convertFileToMp4(String filePath) async {
    final cleanPath = filePath.trim();
    try {
      await _postJson('/api/files/convert', body: {'path': cleanPath});
    } on ApiException catch (e) {
      if (e.statusCode != HttpStatus.notFound &&
          e.statusCode != HttpStatus.methodNotAllowed) {
        rethrow;
      }
      final baseName = cleanPath.replaceAll('\\', '/').split('/').last;
      if (baseName.isEmpty) rethrow;
      await _postJson(
        '/api/files/${Uri.encodeComponent(baseName)}/convert',
        body: const {},
      );
    }
  }

  /// Upload a server file to 115 Cloud Drive
  Future<void> uploadFileTo115(String filePath) async {
    final cleanPath = filePath.trim();
    try {
      await _postJson('/api/files/upload-115', body: {'path': cleanPath});
    } on ApiException catch (e) {
      if (e.statusCode != HttpStatus.notFound &&
          e.statusCode != HttpStatus.methodNotAllowed) {
        rethrow;
      }
      final baseName = cleanPath.replaceAll('\\', '/').split('/').last;
      if (baseName.isEmpty) rethrow;
      await _postJson(
        '/api/files/${Uri.encodeComponent(baseName)}/upload',
        body: const {},
      );
    }
  }

  /// Fetch active file conversion/upload operations (`/api/file-ops`) on the server
  Future<List<Map<String, dynamic>>> fetchServerFileOps() async {
    try {
      final data = await _getJson('/api/file-ops');
      if (data is List) {
        return data.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Rename a file or directory on the server
  Future<void> renameFile(String filePath, String newName) async {
    await _postJson(
      '/api/files/rename',
      body: {
        'path': filePath,
        'new_name': newName.trim(),
      },
    );
  }

  /// Create a new directory on the server
  Future<void> createDirectory(String parentPath, String dirName) async {
    await _postJson(
      '/api/files/mkdir',
      body: {
        'path': parentPath,
        'name': dirName.trim(),
      },
    );
  }

  /// Delete a file or directory on the server
  Future<void> deleteFile(String filePath) async {
    await _deleteJson('/api/files', query: {'path': filePath});
  }

  /// Fetch full server settings
  Future<ServerSettings> fetchServerSettings() async {
    final data = await _getJson('/api/settings');
    if (data is Map<String, dynamic>) {
      return ServerSettings(data);
    }
    throw const ApiException('获取服务器设置失败');
  }

  /// Save full server settings
  Future<void> saveServerSettings(Map<String, dynamic> settings) async {
    await _postJson('/api/settings', body: settings);
  }

  /// Restart backend service
  Future<void> restartServerService() async {
    await _postJson('/api/system/restart');
  }

  /// Check 115 Cloud Drive login status
  Future<Map<String, dynamic>> fetch115Status() async {
    final data = await _getJson('/api/115/status');
    if (data is Map<String, dynamic>) return data;
    return const {};
  }

  /// Login 115 Cloud Drive via Cookie
  Future<void> login115WithCookie(String cookie) async {
    final trimmed = cookie.trim();
    await _postJson(
      '/api/115/login',
      body: {'cookies': trimmed, 'cookie': trimmed},
    );
  }

  /// Request 115 QR Code for login
  Future<Map<String, dynamic>> fetch115QrCode() async {
    final data = await _getJson('/api/115/qrcode');
    if (data is Map<String, dynamic>) return data;
    throw const ApiException('获取 115 二维码失败');
  }

  /// Check 115 QR Code scan status
  Future<Map<String, dynamic>> check115QrCode(String token) async {
    final data = await _getJson('/api/115/check-qrcode', query: {'token': token});
    if (data is Map<String, dynamic>) return data;
    return const {};
  }

  /// Logout 115 Cloud Drive
  Future<void> logout115() async {
    await _postJson('/api/115/logout');
  }

  // ---------------------------------------------------------------------------
  // Proxy Server Management (/api/proxy)
  // ---------------------------------------------------------------------------

  Future<({List<ProxyServiceConfig> services, List<ProxyRuntimeStatus> statuses})>
      fetchProxyConfig() async {
    final data = await _getJson('/api/proxy');
    final services = <ProxyServiceConfig>[];
    final statuses = <ProxyRuntimeStatus>[];
    if (data is Map<String, dynamic>) {
      final rawServices = data['services'];
      if (rawServices is List) {
        for (final item in rawServices) {
          if (item is Map<String, dynamic>) {
            services.add(ProxyServiceConfig.fromJson(item));
          }
        }
      }
      final rawStatuses = data['statuses'];
      if (rawStatuses is List) {
        for (final item in rawStatuses) {
          if (item is Map<String, dynamic>) {
            statuses.add(ProxyRuntimeStatus.fromJson(item));
          }
        }
      }
    }
    return (services: services, statuses: statuses);
  }

  Future<({List<ProxyServiceConfig> services, List<ProxyRuntimeStatus> statuses})>
      saveProxyConfig(List<ProxyServiceConfig> services) async {
    final data = await _putJson(
      '/api/proxy',
      body: {
        'services': services.map((s) => s.toJson()).toList(),
      },
    );
    final updatedServices = <ProxyServiceConfig>[];
    final updatedStatuses = <ProxyRuntimeStatus>[];
    if (data is Map<String, dynamic>) {
      final rawServices = data['services'];
      if (rawServices is List) {
        for (final item in rawServices) {
          if (item is Map<String, dynamic>) {
            updatedServices.add(ProxyServiceConfig.fromJson(item));
          }
        }
      }
      final rawStatuses = data['statuses'];
      if (rawStatuses is List) {
        for (final item in rawStatuses) {
          if (item is Map<String, dynamic>) {
            updatedStatuses.add(ProxyRuntimeStatus.fromJson(item));
          }
        }
      }
    }
    return (
      services: updatedServices.isNotEmpty ? updatedServices : services,
      statuses: updatedStatuses,
    );
  }

  Future<ProxyRuntimeStatus> testProxyService(String id) async {
    final data = await _postJson('/api/proxy/test', body: {'id': id});
    if (data is Map<String, dynamic>) {
      final st = data['status'];
      if (st is Map<String, dynamic>) {
        return ProxyRuntimeStatus.fromJson({...st, 'id': id});
      }
      return ProxyRuntimeStatus.fromJson({...data, 'id': id});
    }
    throw const ApiException('测试代理服务状态失败');
  }

  // ---------------------------------------------------------------------------
  // Interactive Terminal WebSocket (/api/terminal/ws)
  // ---------------------------------------------------------------------------

  Future<WebSocket> connectTerminalWebSocket() async {
    final httpUri = _buildUri('/api/terminal/ws');
    final wsScheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = httpUri.replace(scheme: wsScheme);

    final customHttpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;

    return WebSocket.connect(
      wsUri.toString(),
      headers: authHeaders,
      customClient: customHttpClient,
    );
  }

  // ---------------------------------------------------------------------------
  // Telegram Session & Multi-Account Browser (/api/telegram/*)
  // ---------------------------------------------------------------------------

  Future<({String activeId, List<TelegramAccount> accounts})>
      fetchTelegramAccounts() async {
    final data = await _getJson('/api/telegram/accounts');
    final accounts = <TelegramAccount>[];
    String activeId = 'default';
    if (data is Map<String, dynamic>) {
      activeId = (data['active_id'] ?? 'default').toString();
      final rawList = data['accounts'];
      if (rawList is List) {
        for (final item in rawList) {
          if (item is Map<String, dynamic>) {
            accounts.add(TelegramAccount.fromJson(item));
          }
        }
      }
    }
    return (activeId: activeId, accounts: accounts);
  }

  Future<TelegramAccount> createTelegramAccount(String name) async {
    final data = await _postJson(
      '/api/telegram/accounts',
      body: {'name': name.trim()},
    );
    if (data is Map<String, dynamic>) {
      return TelegramAccount.fromJson(data);
    }
    throw const ApiException('创建 Telegram 账号失败');
  }

  Future<void> setActiveTelegramAccount(String accountId) async {
    await _postJson(
      '/api/telegram/accounts/active',
      body: {'account_id': accountId},
    );
  }

  Future<String> deleteTelegramAccount(String accountId) async {
    final data = await _deleteJson('/api/telegram/accounts/$accountId');
    if (data is Map<String, dynamic>) {
      return (data['active_id'] ?? 'default').toString();
    }
    return 'default';
  }

  Future<TelegramAuthStatus> fetchTelegramStatus(String accountId) async {
    final data = await _getJson(
      '/api/telegram/status',
      query: {'account_id': accountId},
      timeout: const Duration(seconds: 35),
    );
    if (data is Map<String, dynamic>) {
      return TelegramAuthStatus.fromJson(data);
    }
    return const TelegramAuthStatus();
  }

  Future<Map<String, dynamic>> fetchTelegramCacheConfig(String accountId) async {
    final data = await _getJson(
      '/api/telegram/cache-config',
      query: {'account_id': accountId},
    );
    if (data is Map<String, dynamic>) return data;
    return const {};
  }

  Future<Map<String, dynamic>> saveTelegramCacheConfig(
    String accountId,
    String cacheDir,
  ) async {
    final data = await _postJson(
      '/api/telegram/cache-config',
      query: {'account_id': accountId},
      body: {'cache_dir': cacheDir.trim()},
    );
    if (data is Map<String, dynamic>) return data;
    return const {};
  }

  Future<void> saveTelegramApiConfig({
    required String accountId,
    required int apiId,
    required String apiHash,
    String proxyUrl = '',
  }) async {
    await _postJson(
      '/api/telegram/config',
      query: {'account_id': accountId},
      body: {
        'api_id': apiId,
        'api_hash': apiHash.trim(),
        'proxy_url': proxyUrl.trim(),
      },
    );
  }

  Future<void> sendTelegramLoginCode({
    required String accountId,
    required String phone,
  }) async {
    await _postJson(
      '/api/telegram/send-code',
      query: {'account_id': accountId},
      body: {'phone': phone.trim()},
      timeout: const Duration(seconds: 45),
    );
  }

  Future<TelegramAuthStatus> submitTelegramLogin({
    required String accountId,
    required String code,
    String password = '',
  }) async {
    final data = await _postJson(
      '/api/telegram/login',
      query: {'account_id': accountId},
      body: {
        'code': code.trim(),
        'password': password,
      },
      timeout: const Duration(seconds: 45),
    );
    if (data is Map<String, dynamic>) {
      return TelegramAuthStatus.fromJson(data);
    }
    return const TelegramAuthStatus(authorized: true);
  }

  Future<void> logoutTelegram(String accountId) async {
    await _postJson(
      '/api/telegram/logout',
      query: {'account_id': accountId},
      body: const {},
    );
  }

  Future<String> exportTelegramAccountsJson() async {
    final uri = _buildUri('/api/telegram/accounts/export');
    final resp = await _client.get(uri, headers: authHeaders);
    if (resp.statusCode != 200) {
      throw ApiException('导出账号失败 (HTTP ${resp.statusCode})');
    }
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  Future<Map<String, dynamic>> importTelegramAccountsJson(
    Object decodedBackupJson,
  ) async {
    final data = await _postJson(
      '/api/telegram/accounts/import',
      body: decodedBackupJson,
    );
    if (data is Map<String, dynamic>) return data;
    return const {};
  }

  Future<List<TelegramFolder>> fetchTelegramFolders(String accountId) async {
    final data = await _getJson(
      '/api/telegram/folders',
      query: {'account_id': accountId},
      timeout: const Duration(seconds: 30),
    );
    final folders = <TelegramFolder>[];
    if (data is Map<String, dynamic>) {
      final raw = data['folders'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            folders.add(TelegramFolder.fromJson(item));
          }
        }
      }
    }
    if (folders.isEmpty) {
      return const [
        TelegramFolder(key: '0', title: '全部会话'),
        TelegramFolder(key: '1', title: '已归档'),
      ];
    }
    return folders;
  }

  Future<({List<TelegramChat> chats, String nextCursor})> fetchTelegramChats({
    required String accountId,
    String folder = '0',
    String cursor = '',
    int limit = 50,
  }) async {
    final query = <String, String>{
      'account_id': accountId,
      'limit': limit.toString(),
    };
    if (folder.startsWith('filter:')) {
      query['folder'] = '0';
      query['filter_id'] = folder.substring(7);
    } else {
      query['folder'] = folder;
    }
    if (cursor.isNotEmpty) query['cursor'] = cursor;

    final data = await _getJson(
      '/api/telegram/chats',
      query: query,
      timeout: const Duration(seconds: 40),
    );
    final chats = <TelegramChat>[];
    String nextCursor = '';
    if (data is Map<String, dynamic>) {
      nextCursor = (data['next_cursor'] ?? '').toString();
      final raw = data['chats'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            chats.add(TelegramChat.fromJson(item));
          }
        }
      }
    }
    return (chats: chats, nextCursor: nextCursor);
  }

  Future<({List<TelegramMessage> messages, int nextOffset})>
      fetchTelegramMessages({
    required String accountId,
    required String peer,
    int offsetId = 0,
    int limit = 50,
  }) async {
    final data = await _getJson(
      '/api/telegram/messages',
      query: {
        'account_id': accountId,
        'peer': peer,
        'offset_id': offsetId.toString(),
        'limit': limit.toString(),
        'mark_read': '1',
      },
      timeout: const Duration(seconds: 40),
    );
    final messages = <TelegramMessage>[];
    int nextOffset = 0;
    if (data is Map<String, dynamic>) {
      nextOffset = int.tryParse((data['next_offset'] ?? 0).toString()) ?? 0;
      final raw = data['messages'];
      if (raw is List) {
        if (raw.isEmpty) {
          nextOffset = 0;
        }
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            final msg = TelegramMessage.fromJson(item);
            if (msg.hasRenderableContent) {
              messages.add(msg);
            }
          }
        }
      }
    }
    messages.sort((a, b) => a.id.compareTo(b.id));
    return (messages: messages, nextOffset: nextOffset);
  }

  /// Acknowledge / mark a Telegram chat as read on the server if supported.
  Future<void> markTelegramChatRead({
    required String accountId,
    required String peer,
    int maxId = 0,
  }) async {
    try {
      await _postJson(
        '/api/telegram/read',
        query: {'account_id': accountId},
        body: {
          'peer': peer,
          if (maxId > 0) 'max_id': maxId,
        },
        timeout: const Duration(seconds: 6),
      );
    } catch (_) {
      // Ignore if server does not expose a dedicated `/api/telegram/read` endpoint
    }
  }

  String generateTelegramRandomId() => _generateRandomId16Hex();

  String _generateRandomId16Hex() {
    final rng = Random.secure();
    final sb = StringBuffer();
    for (int i = 0; i < 8; i++) {
      sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    final hex = sb.toString();
    return RegExp(r'^0+$').hasMatch(hex) ? '0000000000000001' : hex;
  }

  Future<TelegramMessage?> sendTelegramTextMessage({
    required String accountId,
    required String peer,
    required String text,
    int replyTo = 0,
  }) async {
    final randomId = _generateRandomId16Hex();
    final data = await _postJson(
      '/api/telegram/send',
      query: {'account_id': accountId},
      body: {
        'peer': peer,
        'text': text,
        'reply_to': replyTo,
        'random_id': randomId,
      },
      timeout: const Duration(seconds: 35),
    );
    if (data is Map<String, dynamic>) {
      final msgJson = data['message'];
      if (msgJson is Map<String, dynamic>) {
        final parsed = TelegramMessage.fromJson(msgJson);
        return msgJson.containsKey('outgoing')
            ? parsed
            : parsed.copyWith(outgoing: true);
      }
    }
    return null;
  }

  /// Press a callback or text choice button on a Telegram message (`/api/telegram/button`).
  Future<TelegramButtonActionResult> pressTelegramMessageButton({
    required String accountId,
    required String peer,
    required int messageId,
    required int row,
    required int column,
    required String token,
    String? randomId,
  }) async {
    final reqRandomId = (randomId != null && randomId.isNotEmpty)
        ? randomId
        : _generateRandomId16Hex();
    try {
      final data = await _postJson(
        '/api/telegram/button',
        query: {'account_id': accountId},
        body: {
          'peer': peer,
          'message_id': messageId,
          'row': row,
          'column': column,
          'token': token,
          'random_id': reqRandomId,
        },
        timeout: const Duration(seconds: 30),
      );
      if (data is Map<String, dynamic>) {
        return TelegramButtonActionResult.fromJson(data);
      }
      return const TelegramButtonActionResult();
    } on ApiException catch (e) {
      final upper = e.message.toUpperCase();
      if (upper.contains('BOT_RESPONSE_TIMEOUT') ||
          upper.contains('QUERY_ID_INVALID') ||
          upper.contains('MESSAGE_NOT_MODIFIED') ||
          upper.contains('DATA_INVALID')) {
        // Official Telegram clients ignore BOT_RESPONSE_TIMEOUT on messages.GetBotCallbackAnswer:
        // the callback was already delivered to the bot, which either sent a message/audio or
        // edited the keyboard directly without calling answerCallbackQuery within 10s.
        return const TelegramButtonActionResult();
      }
      rethrow;
    } on TimeoutException {
      return const TelegramButtonActionResult();
    }
  }

  /// Upload and send 1..10 files/screenshots/photos/videos to a Telegram chat
  /// using `/api/telegram/send-files` (`multipart/form-data` + SSE progress stream).
  Future<List<TelegramMessage>> sendTelegramFiles({
    required String accountId,
    required String peer,
    required List<TelegramOutgoingFile> files,
    String text = '',
    int replyTo = 0,
    bool asFile = false,
    void Function(int percent, String statusText)? onProgress,
  }) async {
    if (files.isEmpty) return const [];
    final uri = _buildUri('/api/telegram/send-files', {
      'account_id': accountId,
    });
    final request = http.MultipartRequest('POST', uri);
    authHeaders.forEach((k, v) {
      if (k.toLowerCase() != 'content-type') {
        request.headers[k] = v;
      }
    });

    final metadata = files
        .map((_) => <String, dynamic>{'random_id': _generateRandomId16Hex()})
        .toList();
    request.fields['request'] = jsonEncode({
      'peer': peer,
      'text': text,
      'reply_to': replyTo,
      'as_file': asFile,
      'files': metadata,
    });

    for (final f in files) {
      if (f.bytes.isEmpty && f.filePath != null && f.filePath!.isNotEmpty) {
        request.files.add(
          await http.MultipartFile.fromPath(
            'files',
            f.filePath!,
            filename: f.name,
          ),
        );
      } else {
        request.files.add(
          http.MultipartFile.fromBytes(
            'files',
            f.bytes,
            filename: f.name,
          ),
        );
      }
    }

    final streamed = await _client
        .send(request)
        .timeout(const Duration(minutes: 25));

    if (streamed.statusCode >= 400) {
      final errBody = await streamed.stream.bytesToString();
      String msg = '文件上传失败 (HTTP ${streamed.statusCode})';
      try {
        final decoded = jsonDecode(errBody);
        if (decoded is Map && decoded['error'] != null) {
          msg = decoded['error'].toString();
        }
      } catch (_) {}
      throw ApiException(msg, statusCode: streamed.statusCode);
    }

    final confirmedMessages = <TelegramMessage>[];
    bool receivedConfirmation = false;
    String? sseError;

    void consumeLine(String rawLine) {
      final line = rawLine.trim();
      if (line.isEmpty) return;
      final payload = line.startsWith('data:')
          ? line.substring(5).trim()
          : line;
      if (!payload.startsWith('{')) return;
      try {
        final event = jsonDecode(payload);
        if (event is! Map<String, dynamic>) return;
        final phase = (event['phase'] ?? '').toString();
        if (phase == 'error') {
          sseError = (event['error'] ?? '文件发送失败').toString();
          return;
        }
        final progress = event['progress'];
        if (progress is Map<String, dynamic> && onProgress != null) {
          final uploaded =
              int.tryParse((progress['uploaded'] ?? 0).toString()) ?? 0;
          final total =
              int.tryParse((progress['total'] ?? 1).toString()) ?? 1;
          final index =
              int.tryParse((progress['index'] ?? 1).toString()) ?? 1;
          final count =
              int.tryParse((progress['count'] ?? files.length).toString()) ??
                  files.length;
          final fileName = (progress['file'] ?? '').toString();
          final percent = (uploaded * 100 ~/ (total > 0 ? total : 1)).clamp(
            0,
            100,
          );
          final statusText = percent >= 100
              ? '上传完成，正在确认发送…'
              : '上传到 Telegram：$percent% · $index/$count · $fileName';
          onProgress(percent, statusText);
        }
        if (phase == 'done' || event['sent'] == true) {
          receivedConfirmation = event['sent'] == true;
          final rawMsgs = event['messages'];
          if (rawMsgs is List) {
            for (final item in rawMsgs) {
              if (item is Map<String, dynamic>) {
                final parsed = TelegramMessage.fromJson(item);
                confirmedMessages.add(
                  item.containsKey('outgoing')
                      ? parsed
                      : parsed.copyWith(outgoing: true),
                );
              }
            }
          }
          final singleMsg = event['message'];
          if (singleMsg is Map<String, dynamic>) {
            final parsed = TelegramMessage.fromJson(singleMsg);
            confirmedMessages.add(
              singleMsg.containsKey('outgoing')
                  ? parsed
                  : parsed.copyWith(outgoing: true),
            );
          }
        }
      } catch (_) {}
    }

    await for (final line in streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      consumeLine(line);
      if (sseError != null) {
        throw ApiException(sseError!);
      }
    }

    if (sseError != null) {
      throw ApiException(sseError!);
    }
    if (!receivedConfirmation && confirmedMessages.isEmpty) {
      throw const ApiException('上传连接中断，未收到服务器发送确认');
    }
    return confirmedMessages;
  }

  /// Send or cancel typing indicator in a Telegram chat (`/api/telegram/typing`).
  Future<void> sendTelegramTyping({
    required String accountId,
    required String peer,
    required bool active,
  }) async {
    try {
      await _postJson(
        '/api/telegram/typing',
        query: {'account_id': accountId},
        body: {
          'peer': peer,
          'active': active,
        },
        timeout: const Duration(seconds: 6),
      );
    } catch (_) {}
  }

  /// Fetch inline file preview (`/api/telegram/file-preview`) for text/code/archive/doc files.
  Future<TelegramFilePreview> fetchTelegramFilePreview({
    required String accountId,
    required String peer,
    required int messageId,
    String? entry,
  }) async {
    final query = <String, String>{
      'account_id': accountId,
      'peer': peer,
      'message_id': messageId.toString(),
      if (entry != null && entry.isNotEmpty) 'entry': entry,
    };
    final data = await _getJson(
      '/api/telegram/file-preview',
      query: query,
      timeout: const Duration(seconds: 30),
    );
    if (data is Map<String, dynamic>) {
      return TelegramFilePreview.fromJson(data);
    }
    throw const ApiException('无法加载文件预览');
  }

  /// Resolve a `t.me/...` or `tg://...` link (`/api/telegram/resolve-link`).
  Future<
      ({
        TelegramChat chat,
        int messageId,
        List<TelegramMessage> messages,
        int nextOffset,
      })> resolveTelegramLink({
    required String accountId,
    required String url,
  }) async {
    final data = await _getJson(
      '/api/telegram/resolve-link',
      query: {
        'account_id': accountId,
        'url': url,
      },
      timeout: const Duration(seconds: 30),
    );
    if (data is! Map<String, dynamic>) {
      throw const ApiException('无法解析 Telegram 链接');
    }
    final chatJson = data['chat'];
    final chat = chatJson is Map<String, dynamic>
        ? TelegramChat.fromJson(chatJson)
        : const TelegramChat(peer: '', title: '会话');
    final messageId = int.tryParse((data['message_id'] ?? 0).toString()) ?? 0;
    final messages = <TelegramMessage>[];
    int nextOffset = 0;
    final page = data['page'];
    if (page is Map<String, dynamic>) {
      nextOffset = int.tryParse((page['next_offset'] ?? 0).toString()) ?? 0;
      final rawMsgs = page['messages'];
      if (rawMsgs is List) {
        if (rawMsgs.isEmpty) {
          nextOffset = 0;
        }
        for (final item in rawMsgs) {
          if (item is Map<String, dynamic>) {
            final msg = TelegramMessage.fromJson(item);
            if (msg.hasRenderableContent) {
              messages.add(msg);
            }
          }
        }
      }
    }
    messages.sort((a, b) => a.id.compareTo(b.id));
    return (
      chat: chat,
      messageId: messageId,
      messages: messages,
      nextOffset: nextOffset,
    );
  }

  /// Download raw bytes of a Telegram file or photo with auth headers.
  Future<Uint8List> downloadTelegramBytes(String fullUrl) async {
    final res = await _client
        .get(Uri.parse(fullUrl), headers: authHeaders)
        .timeout(const Duration(minutes: 5));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('下载失败 (HTTP ${res.statusCode})');
    }
    return res.bodyBytes;
  }

  Future<void> deleteTelegramMessages({
    required String accountId,
    required String peer,
    required List<int> messageIds,
    bool revoke = true,
  }) async {
    await _postJson(
      '/api/telegram/delete-messages',
      query: {'account_id': accountId},
      body: {
        'peer': peer,
        'ids': messageIds,
        'revoke': revoke,
      },
    );
  }

  /// Leave a Telegram channel/supergroup/group (`action = 'leave'`) or
  /// delete a Telegram contact (`action = 'delete_contact'`).
  Future<void> performTelegramConversationAction({
    required String accountId,
    required String peer,
    required String action,
  }) async {
    await _postJson(
      '/api/telegram/conversation-action',
      query: {'account_id': accountId},
      body: {
        'peer': peer,
        'action': action,
      },
      timeout: const Duration(seconds: 30),
    );
  }

  String buildTelegramVideoStreamUrl({
    required String accountId,
    required String peer,
    required int messageId,
  }) {
    return _buildUri('/api/telegram/video', {
      'account_id': accountId,
      'peer': peer,
      'message_id': messageId.toString(),
    }).toString();
  }

  String buildTelegramAvatarUrl({
    required String accountId,
    required String peer,
    required String photoId,
    required int dcId,
  }) {
    return _buildUri('/api/telegram/avatar', {
      'account_id': accountId,
      'peer': peer,
      'photo_id': photoId,
      'dc_id': dcId.toString(),
    }).toString();
  }

  String buildTelegramThumbnailUrl({
    required String accountId,
    required String peer,
    required int messageId,
  }) {
    return _buildUri('/api/telegram/thumbnail', {
      'account_id': accountId,
      'peer': peer,
      'message_id': messageId.toString(),
    }).toString();
  }

  String buildTelegramFileContentUrl({
    required String accountId,
    required String peer,
    required int messageId,
  }) {
    return _buildUri('/api/telegram/file-content', {
      'account_id': accountId,
      'peer': peer,
      'message_id': messageId.toString(),
    }).toString();
  }

  String buildTelegramFileDownloadUrl({
    required String accountId,
    required String peer,
    required int messageId,
    bool local = true,
  }) {
    return _buildUri('/api/telegram/file', {
      'account_id': accountId,
      'peer': peer,
      'message_id': messageId.toString(),
      if (local) 'local': '1',
    }).toString();
  }

  Uri buildTelegramNotificationStreamUri(List<String> accountIds) {
    final sortedIds = [...accountIds]..sort();
    return _buildUri('/api/telegram/notification-stream', {
      'account_ids': sortedIds.join(','),
    });
  }

  Uri buildTelegramLiveStreamUri(String accountId) {
    return _buildUri('/api/telegram/stream', {
      'account_id': accountId,
    });
  }
}
