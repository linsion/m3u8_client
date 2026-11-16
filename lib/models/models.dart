import 'dart:convert';
import 'dart:typed_data';

enum AuthMode {
  password,
  token,
  none,
}

class ServerConfig {
  final String baseUrl;
  final AuthMode authMode;
  final String secret;
  final bool preferDirectPlayback;

  const ServerConfig({
    this.baseUrl = 'https://jp2.linsionwinwin.top:8081',
    this.authMode = AuthMode.password,
    this.secret = '',
    this.preferDirectPlayback = true,
  });

  String get normalizedBaseUrl {
    var trimmed = baseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  ServerConfig copyWith({
    String? baseUrl,
    AuthMode? authMode,
    String? secret,
    bool? preferDirectPlayback,
  }) {
    return ServerConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      authMode: authMode ?? this.authMode,
      secret: secret ?? this.secret,
      preferDirectPlayback: preferDirectPlayback ?? this.preferDirectPlayback,
    );
  }

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'authMode': authMode.name,
        'secret': secret,
        'preferDirectPlayback': preferDirectPlayback,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final modeStr = (json['authMode'] ?? 'password').toString();
    final mode = AuthMode.values.firstWhere(
      (e) => e.name == modeStr,
      orElse: () => AuthMode.password,
    );
    return ServerConfig(
      baseUrl: (json['baseUrl'] ?? 'https://jp2.linsionwinwin.top:8081').toString(),
      authMode: mode,
      secret: (json['secret'] ?? '').toString(),
      preferDirectPlayback: json['preferDirectPlayback'] != false,
    );
  }
}

class VodSource {
  final String id; // e.g., "custom_0" or "tvbox_0_10"
  final String name;
  final String api;
  final bool isTvBox;
  final int customIndex;
  final int tvboxType;
  final int tvboxSiteIndex;
  final int tvboxSourceIndex;
  final String tvboxSourceName;
  final bool searchable;

  const VodSource({
    required this.id,
    required this.name,
    required this.api,
    this.isTvBox = false,
    this.customIndex = 0,
    this.tvboxType = 1,
    this.tvboxSiteIndex = -1,
    this.tvboxSourceIndex = -1,
    this.tvboxSourceName = '',
    this.searchable = true,
  });

  String get displayName {
    if (isTvBox && tvboxSourceName.isNotEmpty) {
      return '$name ($tvboxSourceName)';
    }
    return name;
  }

  String get groupLabel => isTvBox ? (tvboxSourceName.isNotEmpty ? 'TVBox · $tvboxSourceName' : 'TVBox 聚合') : '资源站';

  Map<String, String> toQueryParameters() {
    if (isTvBox) {
      return {
        'api': api,
        'tvbox_type': tvboxType.toString(),
        'tvbox_site': tvboxSiteIndex.toString(),
        'tvbox_source': tvboxSourceIndex.toString(),
      };
    }
    return {
      'src': customIndex.toString(),
    };
  }

  /// Key used by `/api/tvbox/library` (`custom_0` or `tvbox_10`)
  String get librarySourceKey {
    if (isTvBox) {
      return 'tvbox_$tvboxSiteIndex';
    }
    return 'custom_$customIndex';
  }
}

class VodCategory {
  final String typeId;
  final String typeName;

  const VodCategory({
    required this.typeId,
    required this.typeName,
  });

  factory VodCategory.fromJson(Map<String, dynamic> json) {
    final rawId = json['type_id'] ?? json['id'] ?? json['tid'] ?? '';
    final rawName =
        json['type_name'] ?? json['name'] ?? json['title'] ?? '未分类';
    var idStr = rawId.toString().trim();
    if (idStr.toLowerCase() == 'null') idStr = '';
    return VodCategory(
      typeId: idStr,
      typeName: rawName.toString().trim(),
    );
  }
}

class VodItem {
  final String vodId;
  final String vodName;
  final String vodPic;
  final String vodRemarks;
  final String vodYear;
  final String typeName;
  final String vodClass;
  final VodSource? source;

  const VodItem({
    required this.vodId,
    required this.vodName,
    this.vodPic = '',
    this.vodRemarks = '',
    this.vodYear = '',
    this.typeName = '',
    this.vodClass = '',
    this.source,
  });

  bool get isAlistDirectory => vodId.startsWith('alistdir:');

  /// True when a TVBox recommendation spider (e.g. `csp_DouDouGuard`) returns an
  /// item without a direct `vod_id` that should jump to aggregated search by title.
  bool get isSearchJumpItem => vodId.startsWith('msearch:');

  VodItem withSource(VodSource src) => VodItem(
        vodId: vodId,
        vodName: vodName,
        vodPic: vodPic,
        vodRemarks: vodRemarks,
        vodYear: vodYear,
        typeName: typeName,
        vodClass: vodClass,
        source: src,
      );

  factory VodItem.fromJson(Map<String, dynamic> json, {VodSource? source}) {
    final rawIdObj = json['vod_id'] ?? json['id'];
    var rawId = rawIdObj == null ? '' : rawIdObj.toString().trim();
    if (rawId.toLowerCase() == 'null') {
      rawId = '';
    }
    final rawNameObj = json['vod_name'] ?? json['name'] ?? json['title'];
    final vodName = (rawNameObj ?? '未知视频').toString().trim();
    if (rawId.isEmpty && vodName.isNotEmpty && vodName != '未知视频') {
      rawId = 'msearch:$vodName';
    }
    return VodItem(
      vodId: rawId,
      vodName: vodName,
      vodPic: (json['vod_pic'] ?? json['pic'] ?? '').toString().trim(),
      vodRemarks:
          (json['vod_remarks'] ?? json['remarks'] ?? '').toString().trim(),
      vodYear: (json['vod_year'] ?? json['year'] ?? '').toString().trim(),
      typeName: (json['type_name'] ?? '').toString().trim(),
      vodClass: (json['vod_class'] ?? '').toString().trim(),
      source: source,
    );
  }
}

class VodListResponse {
  final int page;
  final int pageCount;
  final int total;
  final List<VodCategory> categories;
  final List<VodItem> items;
  final String? resolvedTypeId;

  const VodListResponse({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.categories,
    required this.items,
    this.resolvedTypeId,
  });

  VodListResponse copyWith({
    int? page,
    int? pageCount,
    int? total,
    List<VodCategory>? categories,
    List<VodItem>? items,
    String? resolvedTypeId,
  }) {
    return VodListResponse(
      page: page ?? this.page,
      pageCount: pageCount ?? this.pageCount,
      total: total ?? this.total,
      categories: categories ?? this.categories,
      items: items ?? this.items,
      resolvedTypeId: resolvedTypeId ?? this.resolvedTypeId,
    );
  }

  factory VodListResponse.fromJson(
    Map<String, dynamic> json, {
    VodSource? source,
  }) {
    final rawClass = json['class'] ?? json['categories'] ?? json['typelist'];
    final categories = <VodCategory>[];
    final seenCatIds = <String>{};
    if (rawClass is List) {
      for (final c in rawClass) {
        if (c is Map<String, dynamic>) {
          final cat = VodCategory.fromJson(c);
          if (cat.typeId.isNotEmpty &&
              cat.typeName.isNotEmpty &&
              seenCatIds.add(cat.typeId)) {
            categories.add(cat);
          }
        }
      }
    }

    final rawList = json['list'];
    final items = <VodItem>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          final parsed = VodItem.fromJson(item, source: source);
          if (parsed.vodId.isNotEmpty) {
            items.add(parsed);
          }
          // Fallback: if `class` was omitted or timed out on `ac=detail`,
          // synthesize categories from item `type_id` + `type_name`.
          if (rawClass == null || (rawClass is List && rawClass.isEmpty)) {
            final itemTypeId = (item['type_id'] ?? '').toString().trim();
            final itemTypeName = (item['type_name'] ?? '').toString().trim();
            if (itemTypeId.isNotEmpty &&
                itemTypeId.toLowerCase() != 'null' &&
                itemTypeName.isNotEmpty &&
                seenCatIds.add(itemTypeId)) {
              categories.add(
                VodCategory(typeId: itemTypeId, typeName: itemTypeName),
              );
            }
          }
        }
      }
    }

    final page = int.tryParse((json['page'] ?? json['pg'] ?? 1).toString()) ?? 1;
    final total =
        int.tryParse((json['total'] ?? items.length).toString()) ?? items.length;
    final rawPageCount =
        json['pagecount'] ?? json['page_count'] ?? json['totalpage'];
    int pageCount = int.tryParse((rawPageCount ?? '').toString()) ?? 0;

    if (pageCount <= 1) {
      if (total > items.length && items.isNotEmpty) {
        final limit =
            int.tryParse((json['limit'] ?? items.length).toString()) ??
                items.length;
        final safeLimit = limit > 0 ? limit : items.length;
        pageCount = ((total + safeLimit - 1) ~/ safeLimit).clamp(page, 9999);
      } else if (rawPageCount == null && items.length >= 15) {
        // Many TVBox spider sources omit `pagecount` when more pages exist
        pageCount = page + 1;
      } else if (pageCount <= 0) {
        pageCount = 1;
      }
    }

    return VodListResponse(
      page: page,
      pageCount: pageCount,
      total: total,
      categories: categories,
      items: items,
    );
  }
}

class Episode {
  final String title;
  final String rawUrl;
  final String groupName;
  final int index;

  const Episode({
    required this.title,
    required this.rawUrl,
    required this.groupName,
    required this.index,
  });
}

class PlayGroup {
  final String name;
  final List<Episode> episodes;

  const PlayGroup({
    required this.name,
    required this.episodes,
  });
}

class VodDetail {
  final String vodId;
  final String vodName;
  final String vodPic;
  final String typeName;
  final String vodYear;
  final String vodArea;
  final String vodRemarks;
  final String vodActor;
  final String vodDirector;
  final String vodContent;
  final List<PlayGroup> playGroups;

  const VodDetail({
    required this.vodId,
    required this.vodName,
    this.vodPic = '',
    this.typeName = '',
    this.vodYear = '',
    this.vodArea = '',
    this.vodRemarks = '',
    this.vodActor = '',
    this.vodDirector = '',
    this.vodContent = '',
    this.playGroups = const [],
  });

  static String _stripHtml(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
  }

  static List<PlayGroup> parsePlayGroups(String playFrom, String playUrl) {
    if (playUrl.trim().isEmpty) return const [];
    final fromParts = playFrom.isEmpty
        ? <String>['默认线路']
        : playFrom.split(r'$$$').map((e) => e.trim()).toList();
    final urlParts = playUrl.split(r'$$$');

    final groups = <PlayGroup>[];
    for (var i = 0; i < urlParts.length; i++) {
      final groupName = (i < fromParts.length && fromParts[i].isNotEmpty)
          ? fromParts[i]
          : '线路 ${i + 1}';
      final groupRaw = urlParts[i].trim();
      if (groupRaw.isEmpty) continue;

      final epStrings = groupRaw.split('#');
      final episodes = <Episode>[];
      for (var j = 0; j < epStrings.length; j++) {
        final seg = epStrings[j].trim();
        if (seg.isEmpty) continue;
        final dollarIdx = seg.indexOf(r'$');
        final schemeIdx = seg.indexOf('://');
        String title;
        String url;
        if (dollarIdx >= 0 && (schemeIdx < 0 || dollarIdx < schemeIdx)) {
          title = seg.substring(0, dollarIdx).trim();
          url = seg.substring(dollarIdx + 1).trim();
        } else {
          title = '第 ${j + 1} 集';
          url = seg;
        }
        if (title.isEmpty) title = '第 ${j + 1} 集';
        if (url.isNotEmpty) {
          episodes.add(
            Episode(
              title: title,
              rawUrl: url,
              groupName: groupName,
              index: episodes.length,
            ),
          );
        }
      }
      if (episodes.isNotEmpty) {
        groups.add(PlayGroup(name: groupName, episodes: episodes));
      }
    }

    // Prefer direct m3u8 groups first (just like web app does)
    groups.sort((a, b) {
      final aM3u8 = a.name.toLowerCase().contains('m3u8') ||
          a.episodes.any((e) => e.rawUrl.toLowerCase().contains('.m3u8'));
      final bM3u8 = b.name.toLowerCase().contains('m3u8') ||
          b.episodes.any((e) => e.rawUrl.toLowerCase().contains('.m3u8'));
      if (aM3u8 && !bM3u8) return -1;
      if (!aM3u8 && bM3u8) return 1;
      return 0;
    });

    return groups;
  }

  factory VodDetail.fromJson(Map<String, dynamic> json) {
    final playFrom =
        (json['vod_play_from'] ?? json['play_from'] ?? '').toString();
    final playUrl = (json['vod_play_url'] ??
            json['vod_url'] ??
            json['play_url'] ??
            '')
        .toString();
    final vodId = (json['vod_id'] ?? json['id'] ?? '').toString().trim();
    var groups = parsePlayGroups(playFrom, playUrl);
    if (groups.isEmpty &&
        (vodId.startsWith('http://') ||
            vodId.startsWith('https://') ||
            vodId.startsWith('push://'))) {
      groups = [
        PlayGroup(
          name: playFrom.trim().isNotEmpty ? playFrom.trim() : '默认线路',
          episodes: [
            Episode(
              title: '正片',
              rawUrl: vodId,
              groupName: playFrom.trim().isNotEmpty ? playFrom.trim() : '默认线路',
              index: 0,
            ),
          ],
        ),
      ];
    }
    return VodDetail(
      vodId: vodId,
      vodName: (json['vod_name'] ?? json['name'] ?? '未知视频').toString().trim(),
      vodPic: (json['vod_pic'] ?? json['pic'] ?? '').toString().trim(),
      typeName: (json['vod_type'] ?? json['type_name'] ?? '').toString().trim(),
      vodYear: (json['vod_year'] ?? '').toString().trim(),
      vodArea: (json['vod_area'] ?? '').toString().trim(),
      vodRemarks: (json['vod_remarks'] ?? '').toString().trim(),
      vodActor: (json['vod_actor'] ?? '').toString().trim(),
      vodDirector: (json['vod_director'] ?? '').toString().trim(),
      vodContent:
          _stripHtml((json['vod_content'] ?? json['vod_blurb'] ?? '').toString()),
      playGroups: groups,
    );
  }
}

class ResolvedPlayback {
  final String directUrl;
  final String proxyUrl;
  final String serverProxyUrl;
  final Map<String, String> headers;
  final String parseVia;
  final bool backendProxyPlayback;
  final int proxyBufferSeconds;

  const ResolvedPlayback({
    required this.directUrl,
    required this.proxyUrl,
    required this.serverProxyUrl,
    this.headers = const {},
    this.parseVia = '',
    this.backendProxyPlayback = false,
    this.proxyBufferSeconds = 120,
  });

  factory ResolvedPlayback.fromJson(Map<String, dynamic> json) {
    final headers = <String, String>{};
    final rawHeader = json['header'];
    if (rawHeader is Map) {
      rawHeader.forEach((key, value) {
        if (value != null && value.toString().isNotEmpty) {
          headers[key.toString()] = value.toString();
        }
      });
    }
    final cfg = json['player_config'];
    bool backendProxy = json['force_proxy'] == true;
    int bufferSec = 120;
    if (cfg is Map) {
      if (cfg['backend_proxy_playback'] == true) {
        backendProxy = true;
      }
      final b = int.tryParse((cfg['proxy_buffer_seconds'] ?? '120').toString());
      if (b != null && b > 0) bufferSec = b;
    }

    return ResolvedPlayback(
      directUrl: (json['direct_url'] ?? json['url'] ?? '').toString().trim(),
      proxyUrl: (json['proxy_url'] ?? '').toString().trim(),
      serverProxyUrl: (json['server_proxy_url'] ?? json['proxy_url'] ?? '').toString().trim(),
      headers: headers,
      parseVia: (json['parse_via'] ?? '').toString(),
      backendProxyPlayback: backendProxy,
      proxyBufferSeconds: bufferSec,
    );
  }
}

class LibraryItem {
  final String source;
  final String vodId;
  final String title;
  final String poster;
  final String remark;
  final String episode;
  final String line;
  final double position;
  final double duration;
  final int updated;

  const LibraryItem({
    required this.source,
    required this.vodId,
    required this.title,
    this.poster = '',
    this.remark = '',
    this.episode = '',
    this.line = '',
    this.position = 0,
    this.duration = 0,
    this.updated = 0,
  });

  factory LibraryItem.fromJson(Map<String, dynamic> json) {
    return LibraryItem(
      source: (json['source'] ?? '').toString(),
      vodId: (json['vod_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      poster: (json['poster'] ?? '').toString(),
      remark: (json['remark'] ?? '').toString(),
      episode: (json['episode'] ?? '').toString(),
      line: (json['line'] ?? '').toString(),
      position: double.tryParse((json['position'] ?? 0).toString()) ?? 0,
      duration: double.tryParse((json['duration'] ?? 0).toString()) ?? 0,
      updated: int.tryParse((json['updated'] ?? 0).toString()) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'vod_id': vodId,
        'title': title,
        'poster': poster,
        'remark': remark,
        'episode': episode,
        'line': line,
        'position': position,
        'duration': duration,
        'updated': updated,
      };
}

class LiveSource {
  final String name;
  final String url;
  final int sourceIndex;
  final int liveIndex;
  final String sourceName;
  final String ua;
  final String origin;
  final String referer;
  final int playerType;
  final bool isCustom;

  const LiveSource({
    required this.name,
    this.url = '',
    required this.sourceIndex,
    required this.liveIndex,
    this.sourceName = '',
    this.ua = '',
    this.origin = '',
    this.referer = '',
    this.playerType = 1,
    this.isCustom = false,
  });

  String get key => isCustom ? 'custom_live_$url' : 'tvbox_${sourceIndex}_$liveIndex';

  String get displayName =>
      sourceName.isNotEmpty ? '$name ($sourceName)' : name;

  Map<String, String> get defaultHeaders {
    final headers = <String, String>{
      'User-Agent': ua.trim().isNotEmpty ? ua.trim() : 'okhttp/3.15',
    };
    if (origin.trim().isNotEmpty) {
      headers['Origin'] = origin.trim();
    }
    if (referer.trim().isNotEmpty) {
      headers['Referer'] = referer.trim();
    }
    return headers;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'source_index': sourceIndex,
        'live_index': liveIndex,
        'source_name': sourceName,
        'ua': ua,
        'origin': origin,
        'referer': referer,
        'playerType': playerType,
        'is_custom': isCustom,
      };

  factory LiveSource.fromJson(Map<String, dynamic> json) {
    return LiveSource(
      name: (json['name'] ?? '直播源').toString().trim(),
      url: (json['url'] ?? '').toString().trim(),
      sourceIndex: int.tryParse((json['source_index'] ?? 0).toString()) ?? 0,
      liveIndex: int.tryParse((json['live_index'] ?? 0).toString()) ?? 0,
      sourceName: (json['source_name'] ?? '').toString().trim(),
      ua: (json['ua'] ?? '').toString().trim(),
      origin: (json['origin'] ?? '').toString().trim(),
      referer: (json['referer'] ?? '').toString().trim(),
      playerType: int.tryParse((json['playerType'] ?? 1).toString()) ?? 1,
      isCustom: json['is_custom'] == true,
    );
  }
}

class LiveChannel {
  final String name;
  final String group;
  final List<String> urls;
  final String logo;
  final Map<String, String> headers;

  const LiveChannel({
    required this.name,
    required this.group,
    required this.urls,
    this.logo = '',
    this.headers = const {},
  });

  factory LiveChannel.fromJson(Map<String, dynamic> json) {
    final rawUrls = json['urls'];
    final urls = <String>[];
    if (rawUrls is List) {
      for (final u in rawUrls) {
        final s = u?.toString().trim() ?? '';
        if (s.isNotEmpty) urls.add(s);
      }
    }
    final headers = <String, String>{};
    if (json['headers'] is Map) {
      (json['headers'] as Map).forEach((k, v) {
        if (v != null && v.toString().isNotEmpty) {
          headers[k.toString()] = v.toString();
        }
      });
    }
    return LiveChannel(
      name: (json['name'] ?? '未知频道').toString().trim(),
      group: (json['group'] ?? '默认分组').toString().trim(),
      urls: urls,
      logo: (json['logo'] ?? '').toString().trim(),
      headers: headers,
    );
  }
}

class DownloadTask {
  final String id;
  final String url;
  final String name;
  final String status;
  final double progress;
  final double speed; // bytes per second
  final int totalSegments;
  final int downloadedSegments;
  final String urlType;
  final String outputFile;
  final String error;
  final String duplicateOfTaskId;
  final DateTime? createdAt;

  const DownloadTask({
    required this.id,
    required this.url,
    required this.name,
    required this.status,
    this.progress = 0,
    this.speed = 0,
    this.totalSegments = 0,
    this.downloadedSegments = 0,
    this.urlType = 'm3u8',
    this.outputFile = '',
    this.error = '',
    this.duplicateOfTaskId = '',
    this.createdAt,
  });

  bool get isActive =>
      status == 'Pending' ||
      status == 'Downloading' ||
      status == 'Converting' ||
      status == 'Uploading';

  bool get isCompleted => status == 'Completed';
  bool get isFailed => status == 'Failed' || status == 'Duplicate';

  String get statusLabel {
    switch (status) {
      case 'Pending':
        return '等待中';
      case 'Downloading':
        return '下载中';
      case 'Converting':
        return '转码封装中';
      case 'Uploading':
        return '上传 115 中';
      case 'Completed':
        return '已完成';
      case 'Failed':
        return '失败';
      case 'Duplicate':
        return '重复任务';
      default:
        return status;
    }
  }

  String get formattedSpeed {
    if (speed <= 0) return '0 B/s';
    if (speed < 1024) return '${speed.toStringAsFixed(0)} B/s';
    if (speed < 1024 * 1024) {
      return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(speed / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: (json['id'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      name: (json['name'] ?? '未命名任务').toString(),
      status: (json['status'] ?? 'Pending').toString(),
      progress: double.tryParse((json['progress'] ?? 0).toString()) ?? 0,
      speed: double.tryParse((json['speed'] ?? 0).toString()) ?? 0,
      totalSegments: int.tryParse((json['total_segments'] ?? 0).toString()) ?? 0,
      downloadedSegments:
          int.tryParse((json['downloaded_segments'] ?? 0).toString()) ?? 0,
      urlType: (json['url_type'] ?? 'm3u8').toString(),
      outputFile: (json['output_file'] ?? '').toString(),
      error: (json['error'] ?? '').toString(),
      duplicateOfTaskId: (json['duplicate_of_task_id'] ?? '').toString(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
    );
  }
}

class FileEntry {
  final String name;
  final String path;
  final int size;
  final String modTime;
  final bool isDir;
  final bool isMp4;
  final String ext;

  const FileEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.modTime,
    required this.isDir,
    required this.isMp4,
    required this.ext,
  });

  bool get isPlayableVideo {
    final lower = ext.toLowerCase();
    return isMp4 ||
        lower == '.mp4' ||
        lower == '.mkv' ||
        lower == '.ts' ||
        lower == '.m3u8' ||
        lower == '.mov' ||
        lower == '.flv' ||
        lower == '.webm' ||
        lower == '.avi';
  }

  String get formattedSize {
    if (isDir) return '文件夹';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  factory FileEntry.fromJson(Map<String, dynamic> json) {
    return FileEntry(
      name: (json['name'] ?? '').toString(),
      path: (json['path'] ?? '').toString(),
      size: int.tryParse((json['size'] ?? 0).toString()) ?? 0,
      modTime: (json['mod_time'] ?? '').toString(),
      isDir: json['is_dir'] == true,
      isMp4: json['is_mp4'] == true,
      ext: (json['ext'] ?? '').toString(),
    );
  }
}

class FileDirectoryListing {
  final String path;
  final String parent;
  final String root;
  final List<FileEntry> entries;

  const FileDirectoryListing({
    required this.path,
    required this.parent,
    required this.root,
    required this.entries,
  });

  factory FileDirectoryListing.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    final entries = <FileEntry>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map<String, dynamic>) {
          entries.add(FileEntry.fromJson(item));
        }
      }
    }
    return FileDirectoryListing(
      path: (json['path'] ?? '').toString(),
      parent: (json['parent'] ?? '').toString(),
      root: (json['root'] ?? '/').toString(),
      entries: entries,
    );
  }
}

class ExtractedVideoCandidate {
  final String url;
  final String title;
  final String type;
  final Map<String, String> headers;

  const ExtractedVideoCandidate({
    required this.url,
    this.title = '',
    this.type = '',
    this.headers = const {},
  });

  factory ExtractedVideoCandidate.fromJson(Map<String, dynamic> json) {
    final headers = <String, String>{};
    final rawHeaders = json['headers'] ?? json['header'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (v != null && v.toString().isNotEmpty) {
          headers[k.toString()] = v.toString();
        }
      });
    }
    return ExtractedVideoCandidate(
      url: (json['url'] ?? '').toString(),
      title: (json['title'] ?? json['name'] ?? '').toString(),
      type: (json['type'] ?? json['url_type'] ?? '').toString(),
      headers: headers,
    );
  }
}

class ServerSettings {
  final Map<String, dynamic> raw;

  const ServerSettings(this.raw);

  int get maxConcurrentTasks =>
      int.tryParse((raw['max_concurrent_tasks'] ?? 3).toString()) ?? 3;
  int get maxSegmentWorkers =>
      int.tryParse((raw['max_segment_workers'] ?? 16).toString()) ?? 16;
  bool get convertToMp4 => raw['convert_to_mp4'] == true;
  bool get autoMove => raw['auto_move'] == true;
  bool get vodBackendProxyPlayback => raw['vod_backend_proxy_playback'] == true;
  int get vodProxyBufferSeconds =>
      int.tryParse((raw['vod_proxy_buffer_seconds'] ?? 120).toString()) ?? 120;
  String get mountPath => (raw['mount_path'] ?? '').toString();
  String get fileManagerRoot => (raw['file_manager_root'] ?? '').toString();
  bool get disable115Api => raw['disable_115_api'] == true;
  String get elevenDirId => (raw['eleven_dir_id'] ?? '0').toString();

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(raw);
}

class ProxyServiceConfig {
  final String id;
  final String name;
  final String protocol; // http, socks5, ss, trojan
  final String listenHost;
  final int port;
  final bool enabled;
  final String username;
  final String password;
  final String cipher;
  final String certFile;
  final String keyFile;

  const ProxyServiceConfig({
    required this.id,
    required this.name,
    this.protocol = 'http',
    this.listenHost = '127.0.0.1',
    this.port = 3128,
    this.enabled = true,
    this.username = '',
    this.password = '',
    this.cipher = 'aes-256-gcm',
    this.certFile = 'certs/origin.pem',
    this.keyFile = 'certs/origin.key',
  });

  String get protocolLabel {
    switch (protocol) {
      case 'socks5':
        return 'SOCKS5';
      case 'ss':
        return 'Shadowsocks';
      case 'trojan':
        return 'Trojan';
      default:
        return 'HTTP';
    }
  }

  ProxyServiceConfig copyWith({
    String? id,
    String? name,
    String? protocol,
    String? listenHost,
    int? port,
    bool? enabled,
    String? username,
    String? password,
    String? cipher,
    String? certFile,
    String? keyFile,
  }) {
    return ProxyServiceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      listenHost: listenHost ?? this.listenHost,
      port: port ?? this.port,
      enabled: enabled ?? this.enabled,
      username: username ?? this.username,
      password: password ?? this.password,
      cipher: cipher ?? this.cipher,
      certFile: certFile ?? this.certFile,
      keyFile: keyFile ?? this.keyFile,
    );
  }

  factory ProxyServiceConfig.fromJson(Map<String, dynamic> json) {
    final rawProto = (json['protocol'] ?? 'http').toString().toLowerCase();
    String proto = rawProto;
    if (rawProto == 'socket5' || rawProto == 'socks') proto = 'socks5';
    if (rawProto == 'shadowsocks') proto = 'ss';
    if (rawProto == 'tronjan') proto = 'trojan';

    return ProxyServiceConfig(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      protocol: proto,
      listenHost: (json['listen_host'] ?? '127.0.0.1').toString(),
      port: int.tryParse((json['port'] ?? 1080).toString()) ?? 1080,
      enabled: json['enabled'] == true,
      username: (json['username'] ?? '').toString(),
      password: (json['password'] ?? '').toString(),
      cipher: (json['cipher'] ?? 'aes-256-gcm').toString(),
      certFile: (json['cert_file'] ?? 'certs/origin.pem').toString(),
      keyFile: (json['key_file'] ?? 'certs/origin.key').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol,
        'listen_host': listenHost,
        'port': port,
        'enabled': enabled,
        'username': username,
        'password': password,
        'cipher': cipher,
        'cert_file': certFile,
        'key_file': keyFile,
      };
}

class ProxyRuntimeStatus {
  final String id;
  final bool running;
  final String address;
  final String error;
  final int activeConnections;
  final int totalConnections;

  const ProxyRuntimeStatus({
    required this.id,
    this.running = false,
    this.address = '',
    this.error = '',
    this.activeConnections = 0,
    this.totalConnections = 0,
  });

  factory ProxyRuntimeStatus.fromJson(Map<String, dynamic> json) {
    return ProxyRuntimeStatus(
      id: (json['id'] ?? '').toString(),
      running: json['running'] == true || json['status'] == 'running',
      address: (json['address'] ?? json['listen_address'] ?? '').toString(),
      error: (json['error'] ?? json['last_error'] ?? '').toString(),
      activeConnections:
          int.tryParse((json['active_connections'] ?? 0).toString()) ?? 0,
      totalConnections:
          int.tryParse((json['total_connections'] ?? 0).toString()) ?? 0,
    );
  }
}

class TelegramAccount {
  final String id;
  final String name;
  final String username;
  final String userId;
  final String avatar;

  const TelegramAccount({
    required this.id,
    required this.name,
    this.username = '',
    this.userId = '',
    this.avatar = '',
  });

  String get displayLabel {
    if (username.isNotEmpty) return '$name (@$username)';
    if (userId.isNotEmpty && userId != '0') return '$name ($userId)';
    return name;
  }

  factory TelegramAccount.fromJson(Map<String, dynamic> json) {
    return TelegramAccount(
      id: (json['id'] ?? 'default').toString(),
      name: (json['name'] ?? '默认账号').toString(),
      username: (json['username'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      avatar: (json['avatar'] ?? json['photo'] ?? json['icon'] ?? '')
          .toString()
          .trim(),
    );
  }
}

class TelegramAuthStatus {
  final bool configured;
  final bool authorized;
  final bool codeSent;
  final bool passwordRequired;

  const TelegramAuthStatus({
    this.configured = false,
    this.authorized = false,
    this.codeSent = false,
    this.passwordRequired = false,
  });

  factory TelegramAuthStatus.fromJson(Map<String, dynamic> json) {
    return TelegramAuthStatus(
      configured: json['configured'] == true,
      authorized: json['authorized'] == true,
      codeSent: json['code_sent'] == true,
      passwordRequired: json['password_required'] == true,
    );
  }
}

class TelegramFolder {
  final String key;
  final String title;
  final String emoji;

  const TelegramFolder({
    required this.key,
    required this.title,
    this.emoji = '',
  });

  String get displayTitle => emoji.isNotEmpty ? '$emoji $title' : title;

  factory TelegramFolder.fromJson(Map<String, dynamic> json) {
    return TelegramFolder(
      key: (json['key'] ?? '0').toString(),
      title: (json['title'] ?? '全部会话').toString(),
      emoji: (json['emoji'] ?? '').toString(),
    );
  }
}

class TelegramChat {
  static final RegExp _positiveIntRegex = RegExp(r'^[1-9][0-9]*$');

  final String peer;
  final String title;
  final String kind;
  final String preview;
  final String avatar;
  final String avatarPhotoId;
  final int avatarDcId;
  final int date;
  final int unread;
  final bool readOnly;
  final bool broadcast;
  final bool self;
  final bool contact;
  final bool muted;
  final int topMessageId;
  final int readOutboxMaxId;

  const TelegramChat({
    required this.peer,
    required this.title,
    this.kind = '',
    this.preview = '',
    this.avatar = '',
    this.avatarPhotoId = '',
    this.avatarDcId = 0,
    this.date = 0,
    this.unread = 0,
    this.readOnly = false,
    this.broadcast = false,
    this.self = false,
    this.contact = false,
    this.muted = false,
    this.topMessageId = 0,
    this.readOutboxMaxId = 0,
  });

  bool get hasSharpAvatar =>
      _positiveIntRegex.hasMatch(avatarPhotoId) &&
      avatarDcId > 0 &&
      avatarDcId <= 10;

  /// Action type supported for `/api/telegram/conversation-action` (`'leave'` or `'delete_contact'`).
  String get conversationActionType {
    if (peer.startsWith('channel:') || peer.startsWith('chat:')) {
      return 'leave';
    }
    if (peer.startsWith('user:') && !self) {
      return 'delete_contact';
    }
    return '';
  }

  /// Human-readable label for the conversation action (`退出频道` / `退出超级群` / `退出群组` / `删除好友`).
  String get conversationActionLabel {
    if (peer.startsWith('channel:')) {
      return (broadcast || kind.contains('频道')) ? '退出频道' : '退出超级群';
    }
    if (peer.startsWith('chat:')) {
      return '退出群组';
    }
    if (peer.startsWith('user:') && !self) {
      return '删除好友';
    }
    return '';
  }

  TelegramChat copyWith({
    String? peer,
    String? title,
    String? kind,
    String? preview,
    String? avatar,
    String? avatarPhotoId,
    int? avatarDcId,
    int? date,
    int? unread,
    bool? readOnly,
    bool? broadcast,
    bool? self,
    bool? contact,
    bool? muted,
    int? topMessageId,
    int? readOutboxMaxId,
  }) {
    return TelegramChat(
      peer: peer ?? this.peer,
      title: title ?? this.title,
      kind: kind ?? this.kind,
      preview: preview ?? this.preview,
      avatar: avatar ?? this.avatar,
      avatarPhotoId: avatarPhotoId ?? this.avatarPhotoId,
      avatarDcId: avatarDcId ?? this.avatarDcId,
      date: date ?? this.date,
      unread: unread ?? this.unread,
      readOnly: readOnly ?? this.readOnly,
      broadcast: broadcast ?? this.broadcast,
      self: self ?? this.self,
      contact: contact ?? this.contact,
      muted: muted ?? this.muted,
      topMessageId: topMessageId ?? this.topMessageId,
      readOutboxMaxId: readOutboxMaxId ?? this.readOutboxMaxId,
    );
  }

  factory TelegramChat.fromJson(Map<String, dynamic> json) {
    return TelegramChat(
      peer: (json['peer'] ?? '').toString(),
      title: (json['title'] ?? '未命名会话').toString(),
      kind: (json['kind'] ?? '').toString(),
      preview: (json['preview'] ?? '').toString(),
      avatar: (json['avatar'] ??
              json['photo'] ??
              json['icon'] ??
              json['avatar_url'] ??
              '')
          .toString()
          .trim(),
      avatarPhotoId: (json['avatar_photo_id'] ?? '').toString().trim(),
      avatarDcId: int.tryParse((json['avatar_dc_id'] ?? 0).toString()) ?? 0,
      date: int.tryParse((json['date'] ?? 0).toString()) ?? 0,
      unread: int.tryParse((json['unread'] ?? 0).toString()) ?? 0,
      readOnly: json['read_only'] == true,
      broadcast: json['broadcast'] == true,
      self: json['self'] == true,
      contact: json['contact'] == true,
      muted: json['muted'] == true ||
          json['notification_muted'] == true ||
          json['silent'] == true,
      topMessageId: int.tryParse((json['top_message_id'] ?? 0).toString()) ?? 0,
      readOutboxMaxId:
          int.tryParse((json['read_outbox_max_id'] ?? 0).toString()) ?? 0,
    );
  }
}

class TelegramAttachment {
  final String kind; // video, photo, file, audio
  final String name;
  final String fileName;
  final String title;
  final String performer;
  final bool voice;
  final int size;
  final String mimeType;
  final int duration;
  final int width;
  final int height;
  final String url;
  final String thumbnail;
  final bool hasThumbnail;

  const TelegramAttachment({
    required this.kind,
    this.name = '',
    this.fileName = '',
    this.title = '',
    this.performer = '',
    this.voice = false,
    this.size = 0,
    this.mimeType = '',
    this.duration = 0,
    this.width = 0,
    this.height = 0,
    this.url = '',
    this.thumbnail = '',
    this.hasThumbnail = false,
  });

  String get displayName =>
      fileName.isNotEmpty
          ? fileName
          : (name.isNotEmpty
              ? name
              : (title.isNotEmpty ? title : '媒体文件'));

  bool get isVideo {
    final k = kind.toLowerCase();
    if (k == 'video') return true;
    final m = mimeType.toLowerCase();
    if (m.startsWith('video/')) return true;
    final lowerName = displayName.toLowerCase();
    return RegExp(
      r'\.(mp4|mkv|mov|webm|m4v|avi|flv|ts)$',
    ).hasMatch(lowerName);
  }

  bool get isPhoto {
    final k = kind.toLowerCase();
    if (k == 'photo' || k == 'image') return true;
    final m = mimeType.toLowerCase();
    if (m.startsWith('image/')) return true;
    final lowerName = displayName.toLowerCase();
    return RegExp(
      r'\.(jpg|jpeg|png|webp|gif|bmp)$',
    ).hasMatch(lowerName);
  }

  bool get isAudio {
    final k = kind.toLowerCase();
    if (k == 'audio' || k == 'voice') return true;
    final m = mimeType.toLowerCase();
    if (m.startsWith('audio/')) return true;
    final lowerName = displayName.toLowerCase();
    return RegExp(
      r'\.(mp3|m4a|aac|ogg|oga|opus|wav|flac|wma|ape|alac)$',
    ).hasMatch(lowerName);
  }

  /// True for voice notes (Telegram voice messages: `.ogg`/`.oga`/`.opus` without ID3 track title/performer, or `voice == true`).
  bool get isVoiceMessage {
    if (!isAudio) return false;
    if (voice || kind.toLowerCase() == 'voice') return true;
    if (title.trim().isNotEmpty || performer.trim().isNotEmpty) return false;
    final m = mimeType.toLowerCase();
    final lowerName = displayName.toLowerCase();
    if (m.contains('ogg') ||
        m.contains('opus') ||
        RegExp(r'\.(ogg|oga|opus)$').hasMatch(lowerName)) {
      // Official Telegram names voice messages `audio_YYYY-MM-DD_HH-MM-SS.ogg` or leaves fileName empty
      if (fileName.isEmpty ||
          lowerName.startsWith('audio_') ||
          lowerName.startsWith('voice')) {
        return true;
      }
    }
    return false;
  }

  /// True for music tracks (songs / audio files with ID3 metadata or standard music formats like MP3/FLAC/M4A/WAV).
  bool get isMusic => isAudio && !isVoiceMessage;

  /// Official Telegram music title resolution:
  /// 1. ID3 `title` if present
  /// 2. Parsed track title from `"Performer - Title.ext"` filename pattern
  /// 3. Filename with extension stripped
  String get musicTitle {
    final cleanTitle = title.trim();
    if (cleanTitle.isNotEmpty) return cleanTitle;
    final raw = fileName.trim().isNotEmpty ? fileName.trim() : name.trim();
    if (raw.isEmpty) return isVoiceMessage ? '语音消息' : '未知曲目';
    final withoutExt = raw.replaceFirst(
      RegExp(r'\.[a-zA-Z0-9]{2,5}$'),
      '',
    );
    final dashIdx = withoutExt.indexOf(' - ');
    if (dashIdx > 0 && dashIdx + 3 < withoutExt.length) {
      return withoutExt.substring(dashIdx + 3).trim();
    }
    return withoutExt.trim().isNotEmpty ? withoutExt.trim() : raw;
  }

  /// Official Telegram music performer/artist resolution:
  /// 1. ID3 `performer` if present
  /// 2. Parsed artist from `"Performer - Title.ext"` filename pattern
  /// 3. Fallback `'未知艺术家'` (or `'语音消息'` for voice notes)
  String get musicPerformer {
    final cleanPerformer = performer.trim();
    if (cleanPerformer.isNotEmpty) return cleanPerformer;
    final raw = fileName.trim().isNotEmpty ? fileName.trim() : name.trim();
    if (raw.isNotEmpty) {
      final withoutExt = raw.replaceFirst(
        RegExp(r'\.[a-zA-Z0-9]{2,5}$'),
        '',
      );
      final dashIdx = withoutExt.indexOf(' - ');
      if (dashIdx > 0 && dashIdx + 3 < withoutExt.length) {
        final artist = withoutExt.substring(0, dashIdx).trim();
        if (artist.isNotEmpty) return artist;
      }
    }
    return isVoiceMessage ? '语音消息' : '未知艺术家';
  }

  bool get isVisualMedia => isVideo || isPhoto;

  bool get isValid =>
      url.trim().isNotEmpty ||
      thumbnail.trim().isNotEmpty ||
      hasThumbnail ||
      size > 0 ||
      name.trim().isNotEmpty ||
      fileName.trim().isNotEmpty ||
      title.trim().isNotEmpty ||
      duration > 0;

  String get formattedSize {
    if (size <= 0) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  factory TelegramAttachment.fromJson(Map<String, dynamic> json) {
    return TelegramAttachment(
      kind: (json['kind'] ?? 'file').toString(),
      name: (json['name'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      performer: (json['performer'] ?? '').toString(),
      voice: json['voice'] == true,
      size: int.tryParse((json['size'] ?? 0).toString()) ?? 0,
      mimeType: (json['mime_type'] ?? '').toString(),
      duration: int.tryParse((json['duration'] ?? 0).toString()) ?? 0,
      width: int.tryParse((json['width'] ?? 0).toString()) ?? 0,
      height: int.tryParse((json['height'] ?? 0).toString()) ?? 0,
      url: (json['url'] ?? '').toString(),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      hasThumbnail: json['has_thumbnail'] == true,
    );
  }
}

class TelegramMessageButton {
  final String text;
  final String kind; // 'callback', 'url', 'text', or unsupported
  final String url;
  final String token;

  const TelegramMessageButton({
    required this.text,
    this.kind = 'callback',
    this.url = '',
    this.token = '',
  });

  bool get isUrl => kind == 'url' && url.isNotEmpty;
  bool get isInteractive => kind == 'callback' || kind == 'text';
  bool get isSupported => isUrl || isInteractive;

  factory TelegramMessageButton.fromJson(Map<String, dynamic> json) {
    final rawUrl = (json['url'] ?? '').toString().trim();
    final rawKind = (json['kind'] ??
            json['type'] ??
            (rawUrl.isNotEmpty ? 'url' : 'callback'))
        .toString()
        .trim()
        .toLowerCase();
    return TelegramMessageButton(
      text: (json['text'] ?? json['label'] ?? '').toString(),
      kind: rawKind,
      url: rawUrl,
      token:
          (json['token'] ?? json['data'] ?? json['callback_data'] ?? '').toString(),
    );
  }
}

class TelegramButtonActionResult {
  final String notice;
  final bool alert;
  final String url;
  final TelegramMessage? message;

  const TelegramButtonActionResult({
    this.notice = '',
    this.alert = false,
    this.url = '',
    this.message,
  });

  factory TelegramButtonActionResult.fromJson(Map<String, dynamic> json) {
    final rawMsg = json['message'];
    return TelegramButtonActionResult(
      notice: (json['notice'] ?? json['message_text'] ?? '').toString(),
      alert: json['alert'] == true,
      url: (json['url'] ?? '').toString().trim(),
      message: rawMsg is Map<String, dynamic>
          ? TelegramMessage.fromJson(rawMsg)
          : null,
    );
  }
}

class TelegramMessage {
  final int id;
  final int date;
  final String sender;
  final String senderAvatar;
  final String text;
  final bool outgoing;
  final bool silent;
  final String groupedId;
  final int replyToId;
  final List<String> links;
  final List<List<TelegramMessageButton>> buttons;
  final TelegramAttachment? attachment;

  const TelegramMessage({
    required this.id,
    this.date = 0,
    this.sender = '',
    this.senderAvatar = '',
    this.text = '',
    this.outgoing = false,
    this.silent = false,
    this.groupedId = '',
    this.replyToId = 0,
    this.links = const [],
    this.buttons = const [],
    this.attachment,
  });

  bool get hasButtons => buttons.any((row) => row.isNotEmpty);

  bool get hasRenderableContent =>
      text.trim().isNotEmpty ||
      (attachment != null && attachment!.isValid) ||
      hasButtons ||
      links.isNotEmpty;

  TelegramMessage copyWith({
    int? id,
    int? date,
    String? sender,
    String? senderAvatar,
    String? text,
    bool? outgoing,
    bool? silent,
    String? groupedId,
    int? replyToId,
    List<String>? links,
    List<List<TelegramMessageButton>>? buttons,
    TelegramAttachment? attachment,
  }) {
    return TelegramMessage(
      id: id ?? this.id,
      date: date ?? this.date,
      sender: sender ?? this.sender,
      senderAvatar: senderAvatar ?? this.senderAvatar,
      text: text ?? this.text,
      outgoing: outgoing ?? this.outgoing,
      silent: silent ?? this.silent,
      groupedId: groupedId ?? this.groupedId,
      replyToId: replyToId ?? this.replyToId,
      links: links ?? this.links,
      buttons: buttons ?? this.buttons,
      attachment: attachment ?? this.attachment,
    );
  }

  static List<List<TelegramMessageButton>> _parseButtonRows(dynamic rawButtons) {
    if (rawButtons == null) return const [];
    final rows = <List<TelegramMessageButton>>[];
    if (rawButtons is List) {
      final flatRow = <TelegramMessageButton>[];
      for (final rowItem in rawButtons) {
        if (rowItem is List) {
          final parsedRow = <TelegramMessageButton>[];
          for (final cell in rowItem) {
            if (cell is Map<String, dynamic>) {
              final btn = TelegramMessageButton.fromJson(cell);
              if (btn.text.isNotEmpty) parsedRow.add(btn);
            } else if (cell is Map) {
              final btn = TelegramMessageButton.fromJson(
                Map<String, dynamic>.from(cell),
              );
              if (btn.text.isNotEmpty) parsedRow.add(btn);
            }
          }
          if (parsedRow.isNotEmpty) rows.add(parsedRow);
        } else if (rowItem is Map) {
          final map = Map<String, dynamic>.from(rowItem);
          final nested = map['buttons'];
          if (nested is List) {
            final parsedRow = <TelegramMessageButton>[];
            for (final cell in nested) {
              if (cell is Map) {
                final btn = TelegramMessageButton.fromJson(
                  Map<String, dynamic>.from(cell),
                );
                if (btn.text.isNotEmpty) parsedRow.add(btn);
              }
            }
            if (parsedRow.isNotEmpty) rows.add(parsedRow);
          } else {
            final btn = TelegramMessageButton.fromJson(map);
            if (btn.text.isNotEmpty) flatRow.add(btn);
          }
        }
      }
      if (flatRow.isNotEmpty) {
        rows.add(flatRow);
      }
    } else if (rawButtons is Map) {
      final map = Map<String, dynamic>.from(rawButtons);
      return _parseButtonRows(
        map['rows'] ?? map['inline_keyboard'] ?? map['buttons'],
      );
    }
    return rows;
  }

  factory TelegramMessage.fromJson(Map<String, dynamic> json) {
    final links = <String>[];
    final rawLinks = json['links'];
    if (rawLinks is List) {
      for (final l in rawLinks) {
        final s = l?.toString().trim() ?? '';
        if (s.isNotEmpty && !links.contains(s)) links.add(s);
      }
    }
    final rawTextLinks = json['text_links'];
    if (rawTextLinks is List) {
      for (final item in rawTextLinks) {
        if (item is Map) {
          final u = (item['url'] ?? '').toString().trim();
          if (u.isNotEmpty && !links.contains(u)) links.add(u);
        }
      }
    }
    final rawAtt = json['attachment'];
    final parsedAtt = rawAtt is Map<String, dynamic>
        ? TelegramAttachment.fromJson(rawAtt)
        : (rawAtt is Map
            ? TelegramAttachment.fromJson(Map<String, dynamic>.from(rawAtt))
            : null);
    final buttons = _parseButtonRows(
      json['buttons'] ?? json['reply_markup'] ?? json['inline_keyboard'],
    );
    return TelegramMessage(
      id: int.tryParse((json['id'] ?? 0).toString()) ?? 0,
      date: int.tryParse((json['date'] ?? 0).toString()) ?? 0,
      sender: (json['sender'] ?? '').toString(),
      senderAvatar: (json['sender_avatar'] ?? json['avatar'] ?? '')
          .toString()
          .trim(),
      text: (json['text'] ?? '').toString(),
      outgoing: json['outgoing'] == true,
      silent: json['silent'] == true,
      groupedId: (json['grouped_id'] ?? '').toString(),
      replyToId: int.tryParse((json['reply_to_id'] ?? 0).toString()) ?? 0,
      links: links,
      buttons: buttons,
      attachment: (parsedAtt != null && parsedAtt.isValid) ? parsedAtt : null,
    );
  }
}

class TelegramOutgoingFile {
  final String name;
  final Uint8List bytes;
  final String mimeType;
  final String? filePath;

  const TelegramOutgoingFile({
    required this.name,
    required this.bytes,
    this.mimeType = 'application/octet-stream',
    this.filePath,
  });

  int get size => bytes.length;

  bool get isImage {
    final lower = name.toLowerCase();
    return mimeType.startsWith('image/') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool get isVideo {
    final lower = name.toLowerCase();
    return mimeType.startsWith('video/') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.webm');
  }

  bool get isAudio {
    final lower = name.toLowerCase();
    return mimeType.startsWith('audio/') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.opus');
  }

  String get formattedSize {
    final s = size;
    if (s <= 0) return '0 B';
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    if (s < 1024 * 1024 * 1024) {
      return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(s / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class TelegramFilePreview {
  final String name;
  final int size;
  final String encoding;
  final bool truncated;
  final String kind;
  final String text;
  final List<String> entries;

  const TelegramFilePreview({
    required this.name,
    this.size = 0,
    this.encoding = '',
    this.truncated = false,
    this.kind = 'text',
    this.text = '',
    this.entries = const [],
  });

  factory TelegramFilePreview.fromJson(Map<String, dynamic> json) {
    final entriesList = <String>[];
    final rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final e in rawEntries) {
        if (e is Map) {
          final n = (e['name'] ?? e['path'] ?? '').toString().trim();
          if (n.isNotEmpty) entriesList.add(n);
        } else if (e != null) {
          final s = e.toString().trim();
          if (s.isNotEmpty) entriesList.add(s);
        }
      }
    }
    return TelegramFilePreview(
      name: (json['name'] ?? '预览文件').toString(),
      size: int.tryParse((json['size'] ?? 0).toString()) ?? 0,
      encoding: (json['encoding'] ?? '').toString(),
      truncated: json['truncated'] == true,
      kind: (json['kind'] ?? 'text').toString(),
      text: (json['text'] ?? '').toString(),
      entries: entriesList,
    );
  }
}

class TelegramNotificationEvent {
  final String accountId;
  final String peer;
  final String chatTitle;
  final bool newMessage;
  final bool notificationMuted;
  final bool notificationSettingsChanged;
  final bool foldersChanged;
  final int readMaxId;
  final int readOutboxMaxId;
  final bool refresh;
  final List<int> deletedIds;
  final TelegramMessage? message;

  const TelegramNotificationEvent({
    required this.accountId,
    this.peer = '',
    this.chatTitle = '',
    this.newMessage = false,
    this.notificationMuted = false,
    this.notificationSettingsChanged = false,
    this.foldersChanged = false,
    this.readMaxId = 0,
    this.readOutboxMaxId = 0,
    this.refresh = false,
    this.deletedIds = const [],
    this.message,
  });

  factory TelegramNotificationEvent.fromJson(Map<String, dynamic> json) {
    final deleted = <int>[];
    final rawDeleted = json['deleted_ids'];
    if (rawDeleted is List) {
      for (final item in rawDeleted) {
        final id = int.tryParse(item.toString());
        if (id != null && id > 0) deleted.add(id);
      }
    }
    final rawMsg = json['message'];
    return TelegramNotificationEvent(
      accountId: (json['account_id'] ?? 'default').toString(),
      peer: (json['peer'] ?? '').toString(),
      chatTitle: (json['chat_title'] ?? '').toString(),
      newMessage: json['new_message'] == true,
      notificationMuted: json['notification_muted'] == true,
      notificationSettingsChanged:
          json['notification_settings_changed'] == true,
      foldersChanged: json['folders_changed'] == true,
      readMaxId: int.tryParse((json['read_max_id'] ?? 0).toString()) ?? 0,
      readOutboxMaxId:
          int.tryParse((json['read_outbox_max_id'] ?? 0).toString()) ?? 0,
      refresh: json['refresh'] == true,
      deletedIds: deleted,
      message: rawMsg is Map<String, dynamic>
          ? TelegramMessage.fromJson(rawMsg)
          : null,
    );
  }
}

class TelegramNotificationItem {
  final String key;
  final String accountId;
  final String accountName;
  final String peer;
  final String title;
  final String preview;
  final TelegramMessage message;
  final int count;
  final int updatedAtMs;

  const TelegramNotificationItem({
    required this.key,
    required this.accountId,
    required this.accountName,
    required this.peer,
    required this.title,
    required this.preview,
    required this.message,
    this.count = 1,
    required this.updatedAtMs,
  });
}

