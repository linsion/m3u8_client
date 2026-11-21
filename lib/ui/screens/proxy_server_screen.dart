import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../services/proxy_routing_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';

const MethodChannel _qrScannerChannel =
    MethodChannel('com.linsion.m3u8_client/qr_scanner');

({String url, String name})? _tryParseSubscriptionFromQrText(String rawInput) {
  final raw = rawInput.trim();
  if (raw.isEmpty) return null;

  // 1. Direct http:// or https:// subscription URL
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty) {
      final fragName =
          uri.fragment.isNotEmpty ? Uri.decodeComponent(uri.fragment) : '';
      final cleanUrl = raw.split('#').first.trim();
      final name = fragName.isNotEmpty ? fragName : '扫码订阅 (${uri.host})';
      return (url: cleanUrl, name: name);
    }
  }

  // 2. clash://install-config?url=... or sing-box://import-remote-profile?url=...
  final lower = raw.toLowerCase();
  if (lower.startsWith('clash://') ||
      lower.startsWith('sing-box://') ||
      lower.startsWith('shadowrocket://')) {
    final uri = Uri.tryParse(raw);
    if (uri != null) {
      final embeddedUrl = uri.queryParameters['url'] ?? '';
      if (embeddedUrl.startsWith('http://') ||
          embeddedUrl.startsWith('https://')) {
        final embeddedUri = Uri.tryParse(embeddedUrl);
        final name = uri.queryParameters['name']?.trim().isNotEmpty == true
            ? uri.queryParameters['name']!.trim()
            : (uri.fragment.isNotEmpty
                ? Uri.decodeComponent(uri.fragment)
                : '扫码订阅 (${embeddedUri?.host ?? "Clash"})');
        return (url: embeddedUrl.trim(), name: name);
      }
    }
  }

  // 3. sub://base64_url#name or sub://https://...
  if (lower.startsWith('sub://')) {
    var body = raw.substring(6).trim();
    String subName = '';
    final hashIdx = body.indexOf('#');
    if (hashIdx >= 0) {
      subName = Uri.decodeComponent(body.substring(hashIdx + 1).trim());
      body = body.substring(0, hashIdx).trim();
    }
    if (body.startsWith('http://') || body.startsWith('https://')) {
      final uri = Uri.tryParse(body);
      return (
        url: body,
        name: subName.isNotEmpty ? subName : '扫码订阅 (${uri?.host ?? "sub"})',
      );
    }
    try {
      final normalized = base64Url.normalize(
        body.replaceAll('-', '+').replaceAll('_', '/'),
      );
      final decoded = utf8.decode(base64.decode(normalized)).trim();
      if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
        final uri = Uri.tryParse(decoded);
        return (
          url: decoded.split('#').first.trim(),
          name: subName.isNotEmpty ? subName : '扫码订阅 (${uri?.host ?? "sub"})',
        );
      }
    } catch (_) {}
  }

  return null;
}

class ProxyServerScreen extends StatefulWidget {
  final AppState appState;

  const ProxyServerScreen({
    super.key,
    required this.appState,
  });

  @override
  State<ProxyServerScreen> createState() => _ProxyServerScreenState();
}

class _ProxyServerScreenState extends State<ProxyServerScreen> {
  // Top-level sub-navigation tab:
  // 0 = 订阅与代理节点, 1 = 分场景路由策略, 2 = 服务端代理监听 (/api/proxy)
  int _activeTab = 0;

  // Node filtering & sorting state
  final TextEditingController _nodeSearchCtrl = TextEditingController();
  String _nodeSearchQuery = '';
  String _protocolFilter = 'all'; // all, ss, trojan, vmess, vless, socks5, http
  String _nodeSortBy = 'latency'; // default, latency, name

  // Server listener (/api/proxy) state
  static const Map<String, int> _defaultPorts = {
    'http': 3128,
    'socks5': 1080,
    'ss': 8388,
    'trojan': 443,
  };

  static const List<String> _ssCiphers = [
    'aes-128-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
  ];

  List<ProxyServiceConfig> _services = [];
  Map<String, ProxyRuntimeStatus> _statuses = {};
  Set<String> _persistedIds = {};

  bool _isLoadingServer = false;
  bool _isSavingServer = false;
  bool _isServerDirty = false;
  String _serverStatusMessage = '可同时运行 HTTP、SOCKS5、Shadowsocks 与 Trojan 代理服务';
  bool _serverStatusIsError = false;

  // Server listener editor form state
  String _editingId = '';
  final TextEditingController _nameCtrl = TextEditingController();
  String _protocol = 'http';
  final TextEditingController _listenHostCtrl =
      TextEditingController(text: '127.0.0.1');
  final TextEditingController _portCtrl = TextEditingController(text: '3128');
  bool _enabled = true;
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  String _cipher = 'aes-256-gcm';
  final TextEditingController _certFileCtrl =
      TextEditingController(text: 'certs/origin.pem');
  final TextEditingController _keyFileCtrl =
      TextEditingController(text: 'certs/origin.key');
  bool _obscurePassword = true;
  String? _testingServiceId;

  ProxyRoutingService get _proxySvc => widget.appState.proxyService;

  @override
  void initState() {
    super.initState();
    _loadServerProxyConfig();
  }

  @override
  void dispose() {
    _nodeSearchCtrl.dispose();
    _nameCtrl.dispose();
    _listenHostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _certFileCtrl.dispose();
    _keyFileCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Server-side Proxy Listeners (/api/proxy)
  // ---------------------------------------------------------------------------

  Future<void> _loadServerProxyConfig({bool syncToClient = false}) async {
    setState(() {
      _isLoadingServer = true;
      _serverStatusMessage = '正在加载服务端代理配置...';
      _serverStatusIsError = false;
    });
    try {
      final res = await widget.appState.api.fetchProxyConfig();
      if (!mounted) return;
      final statusMap = <String, ProxyRuntimeStatus>{};
      for (final st in res.statuses) {
        statusMap[st.id] = st;
      }
      setState(() {
        _services = res.services;
        _statuses = statusMap;
        _persistedIds = res.services.map((s) => s.id).toSet();
        _isServerDirty = false;
        _isLoadingServer = false;
        _serverStatusMessage = res.services.isNotEmpty
            ? '已加载 ${res.services.length} 个服务端代理监听'
            : '尚未配置服务端代理监听';
        _applyEditorFields(null);
      });

      // If client has no nodes yet or user requested sync, import enabled server listeners
      if (syncToClient || (_proxySvc.nodes.isEmpty && res.services.isNotEmpty)) {
        await _proxySvc.syncNodesFromServerServices(
          res.services,
          widget.appState.serverConfig.normalizedBaseUrl,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingServer = false;
        _serverStatusIsError = true;
        _serverStatusMessage = '加载服务端代理配置失败：$e';
      });
    }
  }

  String _resolvePublicHost(ProxyServiceConfig s) {
    final lh = s.listenHost.trim();
    if (lh.isNotEmpty &&
        lh != '0.0.0.0' &&
        lh != '::' &&
        lh != '127.0.0.1' &&
        lh != 'localhost') {
      return lh;
    }
    final uri = Uri.tryParse(widget.appState.serverConfig.normalizedBaseUrl);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }
    return lh.isEmpty ? '127.0.0.1' : lh;
  }

  String _buildShareUri(ProxyServiceConfig s) {
    final host = _resolvePublicHost(s);
    final tag = Uri.encodeComponent(s.name.isEmpty ? s.protocolLabel : s.name);
    switch (s.protocol) {
      case 'ss':
        final rawUserInfo = '${s.cipher}:${s.password}';
        final b64 = base64Url
            .encode(utf8.encode(rawUserInfo))
            .replaceAll('=', '');
        return 'ss://$b64@$host:${s.port}#$tag';
      case 'trojan':
        final pwd = Uri.encodeComponent(s.password);
        return 'trojan://$pwd@$host:${s.port}?sni=$host&allowInsecure=1#$tag';
      case 'socks5':
        final auth = s.username.isNotEmpty
            ? '${Uri.encodeComponent(s.username)}:${Uri.encodeComponent(s.password)}@'
            : '';
        return 'socks5://$auth$host:${s.port}#$tag';
      case 'http':
      default:
        final auth = s.username.isNotEmpty
            ? '${Uri.encodeComponent(s.username)}:${Uri.encodeComponent(s.password)}@'
            : '';
        return 'http://$auth$host:${s.port}#$tag';
    }
  }

  String _buildClashYaml(ProxyServiceConfig s) {
    final host = _resolvePublicHost(s);
    switch (s.protocol) {
      case 'ss':
        return '- { name: "${s.name}", type: ss, server: $host, port: ${s.port}, cipher: ${s.cipher}, password: "${s.password}", udp: true }';
      case 'trojan':
        return '- { name: "${s.name}", type: trojan, server: $host, port: ${s.port}, password: "${s.password}", sni: $host, skip-cert-verify: true, udp: true }';
      case 'socks5':
        return '- { name: "${s.name}", type: socks5, server: $host, port: ${s.port}${s.username.isNotEmpty ? ', username: "${s.username}", password: "${s.password}"' : ''}, udp: true }';
      case 'http':
      default:
        return '- { name: "${s.name}", type: http, server: $host, port: ${s.port}${s.username.isNotEmpty ? ', username: "${s.username}", password: "${s.password}"' : ''} }';
    }
  }

  // ---------------------------------------------------------------------------
  // Subscription & Node Dialogs
  // ---------------------------------------------------------------------------

  Future<void> _showUpsertSubscriptionDialog([ProxySubscription? existing]) async {
    final result = await showDialog<_UpsertSubscriptionResult>(
      context: context,
      builder: (ctx) => _UpsertSubscriptionDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;

    final sub = await _proxySvc.upsertSubscription(
      id: existing?.id,
      name: result.name,
      url: result.url,
      enabled: result.enabled,
      autoUpdateHours: result.autoUpdateHours,
      customUserAgent: result.customUserAgent,
    );
    if (!mounted) return;
    unawaited(_proxySvc.refreshSubscription(sub.id));
  }

  Future<void> _showQrScanAddSubscriptionSheet() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前桌面环境请使用「新增订阅链接」或「粘贴导入节点」'),
        ),
      );
      return;
    }

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: VideoPlatformTheme.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.qr_code_scanner_rounded,
                      size: 20,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '扫码添加代理订阅 / 节点',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '支持识别机场订阅链接二维码 (HTTP/HTTPS、sub://、clash://) 以及单节点二维码 (ss://、trojan://、vmess://、vless://、socks5://)',
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  tileColor: VideoPlatformTheme.bgCard,
                  leading: Icon(
                    Icons.camera_alt_rounded,
                    color: VideoPlatformTheme.accent,
                  ),
                  title: Text(
                    '摄像头实时扫码添加',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '打开手机相机对准订阅或节点二维码自动添加',
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.textSecondary,
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('scanCamera'),
                ),
                const SizedBox(height: 8),
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  tileColor: VideoPlatformTheme.bgCard,
                  leading: Icon(
                    Icons.photo_library_rounded,
                    color: VideoPlatformTheme.accent,
                  ),
                  title: Text(
                    '从手机相册选择二维码图片识别',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '选择保存在相册中的订阅二维码截图直接导入',
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.textSecondary,
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('scanGallery'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == null || !mounted) return;
    await _scanQrCodeAndImport(choice);
  }

  Future<void> _scanQrCodeAndImport(String method) async {
    try {
      final scanned = await _qrScannerChannel.invokeMethod<String>(method);
      if (!mounted || scanned == null) return;
      final trimmed = scanned.trim();
      final messenger = ScaffoldMessenger.of(context);
      if (trimmed.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('未在图片中识别到有效二维码，请重试')),
        );
        return;
      }

      // Check if it's a subscription URL QR code
      final parsedSub = _tryParseSubscriptionFromQrText(trimmed);
      if (parsedSub != null) {
        final sub = await _proxySvc.upsertSubscription(
          name: parsedSub.name,
          url: parsedSub.url,
          enabled: true,
          autoUpdateHours: 12,
        );
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text('扫码成功：已添加订阅「${sub.name}」，正在自动拉取节点...'),
          ),
        );
        unawaited(_proxySvc.refreshSubscription(sub.id));
        return;
      }

      // Otherwise treat as proxy node URI(s) or Base64 node list
      final count = await _proxySvc.importNodesFromRawText(trimmed);
      if (!mounted) return;
      if (count > 0) {
        messenger.showSnackBar(
          SnackBar(content: Text('扫码成功：已解析并导入 $count 个代理节点')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '未能识别该二维码为代理订阅或节点：${trimmed.length > 60 ? "${trimmed.substring(0, 60)}..." : trimmed}',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('调用扫码失败：$e')),
      );
    }
  }

  Future<void> _showPasteImportDialog() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => const _PasteImportNodesDialog(),
    );
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final count = await _proxySvc.importNodesFromRawText(raw.trim());
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count > 0 ? '已成功解析并导入 $count 个代理节点' : '未识别到有效节点，请检查格式',
        ),
      ),
    );
  }

  Future<void> _showManualNodeDialog([ProxyNode? existing]) async {
    final node = await showDialog<ProxyNode>(
      context: context,
      builder: (ctx) => _ManualProxyNodeDialog(
        existing: existing,
        ssCiphers: _ssCiphers,
      ),
    );
    if (node == null || !mounted) return;
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;
    await _proxySvc.upsertManualNode(node);
  }

  // ---------------------------------------------------------------------------
  // Build Root UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _proxySvc,
      builder: (context, _) {
        return Column(
          children: [
            _buildTopMasterControlHeader(),
            _buildSubNavigationBar(),
            Expanded(
              child: _buildActiveTabBody(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActiveTabBody() {
    switch (_activeTab) {
      case 1:
        return _buildScenarioRoutingTab();
      case 2:
        return _buildServerListenersTab();
      case 0:
      default:
        return _buildSubscriptionsAndNodesTab();
    }
  }

  /// Top master control header:
  /// - Global Proxy ON/OFF toggle switch
  /// - Manual vs Auto-Fastest switcher
  /// - Active node & real-time latency pill
  Widget _buildTopMasterControlHeader() {
    final enabled = _proxySvc.proxyEnabled;
    final mode = _proxySvc.selectionMode;
    final active = _proxySvc.activeNode;
    final statusMsg = _proxySvc.lastStatusMessage;
    final isErr = _proxySvc.lastStatusIsError;
    final isCompact = MediaQuery.sizeOf(context).width < 680;

    final switchBadge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 10,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: enabled
            ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
            : VideoPlatformTheme.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: enabled
              ? VideoPlatformTheme.accent
              : VideoPlatformTheme.borderSubtle,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 24,
            child: Switch(
              value: enabled,
              activeColor: VideoPlatformTheme.accent,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => _proxySvc.setProxyEnabled(v),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            enabled ? '代理已开启' : '代理已关闭',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: enabled
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
          ),
        ],
      ),
    );

    final modeSegmented = Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeSegmentButton(
            selected: mode == ProxySelectionMode.autoFastest,
            icon: Icons.flash_on_rounded,
            label: isCompact ? '自动最快' : '自动切换最快',
            onTap: () => _proxySvc.setSelectionMode(
              ProxySelectionMode.autoFastest,
            ),
          ),
          _buildModeSegmentButton(
            selected: mode == ProxySelectionMode.manual,
            icon: Icons.touch_app_rounded,
            label: isCompact ? '手动指定' : '手动指定代理',
            onTap: () => _proxySvc.setSelectionMode(
              ProxySelectionMode.manual,
            ),
          ),
        ],
      ),
    );

    final activeNodeWidget = active != null
        ? Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: VideoPlatformTheme.borderSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  mode == ProxySelectionMode.autoFastest
                      ? Icons.bolt_rounded
                      : Icons.lock_outline_rounded,
                  size: 15,
                  color: enabled
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textMuted,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '${mode == ProxySelectionMode.autoFastest ? "智能防抖" : "手动锁定"}：${active.displayTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _buildLatencyBadge(
                  active.latencyMs,
                  speedLabel: active.speedLabel,
                ),
              ],
            ),
          )
        : Text(
            statusMsg.isNotEmpty
                ? statusMsg
                : '点击下方「立即更新」获取良心云节点并自动选出最快代理',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isErr
                  ? VideoPlatformTheme.danger
                  : VideoPlatformTheme.textSecondary,
            ),
          );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 12 : 18,
        vertical: isCompact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            enabled
                ? VideoPlatformTheme.accent.withValues(alpha: 0.14)
                : VideoPlatformTheme.bgElevated,
            VideoPlatformTheme.bgElevated,
          ],
        ),
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    switchBadge,
                    modeSegmented,
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: activeNodeWidget),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _proxySvc.isTestingNodes || _proxySvc.nodes.isEmpty
                              ? null
                              : () => _proxySvc.testAllNodesLatency(),
                      icon: _proxySvc.isTestingNodes
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.speed_rounded, size: 15),
                      label: Text(_proxySvc.isTestingNodes ? '测速中' : '测速'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton.icon(
                      onPressed: _proxySvc.isUpdatingSubscriptions
                          ? null
                          : () => _proxySvc.refreshAllSubscriptions(),
                      icon: _proxySvc.isUpdatingSubscriptions
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.sync_rounded, size: 15),
                      label: Text(
                        _proxySvc.isUpdatingSubscriptions ? '更新中' : '更新订阅',
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Wrap(
              spacing: 14,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    switchBadge,
                    const SizedBox(width: 12),
                    Flexible(child: activeNodeWidget),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    modeSegmented,
                    OutlinedButton.icon(
                      onPressed:
                          _proxySvc.isTestingNodes || _proxySvc.nodes.isEmpty
                              ? null
                              : () => _proxySvc.testAllNodesLatency(),
                      icon: _proxySvc.isTestingNodes
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.speed_rounded, size: 16),
                      label: Text(_proxySvc.isTestingNodes ? '测速中...' : '测速选优'),
                    ),
                    FilledButton.icon(
                      onPressed: _proxySvc.isUpdatingSubscriptions
                          ? null
                          : () => _proxySvc.refreshAllSubscriptions(),
                      icon: _proxySvc.isUpdatingSubscriptions
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.sync_rounded, size: 16),
                      label: Text(
                        _proxySvc.isUpdatingSubscriptions ? '更新中...' : '更新订阅',
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildModeSegmentButton({
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? VideoPlatformTheme.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected ? Colors.white : VideoPlatformTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color:
                    selected ? Colors.white : VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubNavigationBar() {
    final statusMsg = _proxySvc.lastStatusMessage;
    final isErr = _proxySvc.lastStatusIsError;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildSubNavTab(
              index: 0,
              icon: Icons.hub_rounded,
              label: '订阅与代理节点 (${_proxySvc.nodes.length})',
            ),
            const SizedBox(width: 8),
            _buildSubNavTab(
              index: 1,
              icon: Icons.alt_route_rounded,
              label: '分场景路由策略 (${RequestScenario.values.length})',
            ),
            const SizedBox(width: 8),
            _buildSubNavTab(
              index: 2,
              icon: Icons.dns_outlined,
              label: '服务端代理监听 (${_services.length})',
            ),
            if (statusMsg.isNotEmpty) ...[
              const SizedBox(width: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  statusMsg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isErr
                        ? VideoPlatformTheme.danger
                        : VideoPlatformTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSubNavTab({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final selected = _activeTab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _activeTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 0: Subscriptions & Proxy Nodes Management
  // ---------------------------------------------------------------------------

  Widget _buildSubscriptionsAndNodesTab() {
    final isCompact = MediaQuery.sizeOf(context).width < 680;
    return SingleChildScrollView(
      padding: EdgeInsets.all(isCompact ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSubscriptionsSectionCard(),
          SizedBox(height: isCompact ? 12 : 18),
          _buildNodesSectionCard(),
        ],
      ),
    );
  }

  Widget _buildSubscriptionsSectionCard() {
    final subs = _proxySvc.subscriptions;
    final isCompact = MediaQuery.sizeOf(context).width < 680;

    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.rss_feed_rounded,
          size: 18,
          color: VideoPlatformTheme.accent,
        ),
        const SizedBox(width: 8),
        Text(
          '代理订阅源管理',
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: VideoPlatformTheme.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 7,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${subs.length} 个订阅',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.accent,
            ),
          ),
        ),
      ],
    );

    final actionButtons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (Platform.isAndroid || Platform.isIOS)
          FilledButton.tonalIcon(
            onPressed: _showQrScanAddSubscriptionSheet,
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 15),
            label: const Text('扫码添加'),
          ),
        OutlinedButton.icon(
          onPressed: () => _showUpsertSubscriptionDialog(),
          icon: const Icon(Icons.add_link_rounded, size: 15),
          label: const Text('新增订阅链接'),
        ),
        OutlinedButton.icon(
          onPressed: _showPasteImportDialog,
          icon: const Icon(Icons.content_paste_go_rounded, size: 15),
          label: const Text('粘贴导入节点'),
        ),
        OutlinedButton.icon(
          onPressed: () => _loadServerProxyConfig(syncToClient: true),
          icon: const Icon(Icons.dns_outlined, size: 15),
          label: const Text('同步服务端节点'),
        ),
      ],
    );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isCompact ? 12 : 16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isCompact) ...[
            titleRow,
            const SizedBox(height: 10),
            actionButtons,
          ] else
            Row(
              children: [
                titleRow,
                const Spacer(),
                Flexible(child: actionButtons),
              ],
            ),
          const SizedBox(height: 12),
          if (subs.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.isDark
                    ? VideoPlatformTheme.bgCard
                    : VideoPlatformTheme.bgPrimary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: Column(
                children: [
                  Text(
                    '尚未添加任何订阅源',
                    style: TextStyle(color: VideoPlatformTheme.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (Platform.isAndroid || Platform.isIOS)
                        FilledButton.icon(
                          onPressed: _showQrScanAddSubscriptionSheet,
                          icon: const Icon(
                            Icons.qr_code_scanner_rounded,
                            size: 16,
                          ),
                          label: const Text('扫码添加订阅'),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: () => _showUpsertSubscriptionDialog(),
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('添加良心云默认订阅'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: subs.map(_buildSubscriptionItemTile).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionItemTile(ProxySubscription sub) {
    final isUpdatingThis = _proxySvc.updatingSubscriptionId == sub.id;
    final ratio = sub.usedTrafficRatio;
    final trafficText = sub.formattedTrafficSummary;
    final updatedStr = sub.lastUpdatedAtMs > 0
        ? _formatRelativeTime(sub.lastUpdatedAtMs)
        : '尚未拉取';
    final tileBgColor = VideoPlatformTheme.isDark
        ? VideoPlatformTheme.bgCard
        : VideoPlatformTheme.bgPrimary;
    final badgeBgColor = VideoPlatformTheme.isDark
        ? VideoPlatformTheme.bgElevated
        : VideoPlatformTheme.bgHover;
    final isCompact = MediaQuery.sizeOf(context).width < 680;

    return Container(
      key: ValueKey('sub_tile_${sub.id}'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(isCompact ? 12 : 14),
      decoration: BoxDecoration(
        color: tileBgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: sub.lastError.isNotEmpty
              ? VideoPlatformTheme.danger.withValues(alpha: 0.45)
              : VideoPlatformTheme.borderStrong,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: sub.enabled
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                      : badgeBgColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  sub.enabled ? '已启用' : '已停用',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: sub.enabled
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sub.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeBgColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${sub.nodeCount} 节点 · $updatedStr',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: isUpdatingThis
                      ? null
                      : () => _proxySvc.refreshSubscription(sub.id),
                  icon: isUpdatingThis
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 15),
                  label: Text(isUpdatingThis ? '拉取中' : '立即更新'),
                ),
                IconButton(
                  tooltip: '编辑订阅',
                  onPressed: () => _showUpsertSubscriptionDialog(sub),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                ),
                IconButton(
                  tooltip: '删除订阅',
                  onPressed: () => _proxySvc.deleteSubscription(sub.id),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.link_rounded,
                size: 14,
                color: VideoPlatformTheme.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sub.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: sub.url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已复制订阅地址：${sub.name}'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.copy_rounded,
                        size: 12,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '复制地址',
                        style: TextStyle(
                          fontSize: 11,
                          color: VideoPlatformTheme.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (isCompact) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: isUpdatingThis
                      ? null
                      : () => _proxySvc.refreshSubscription(sub.id),
                  icon: isUpdatingThis
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 15),
                  label: Text(isUpdatingThis ? '拉取中...' : '立即更新'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showUpsertSubscriptionDialog(sub),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('编辑订阅'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: VideoPlatformTheme.danger,
                  ),
                  onPressed: () => _proxySvc.deleteSubscription(sub.id),
                  icon: const Icon(Icons.delete_outline_rounded, size: 15),
                  label: const Text('删除'),
                ),
              ],
            ),
          ],
          if (ratio != null && trafficText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 5,
                      backgroundColor: badgeBgColor,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '已用流量：$trafficText',
                  style: TextStyle(
                    fontSize: 11,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ],
          if (sub.lastError.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: VideoPlatformTheme.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '提示：${sub.lastError}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: VideoPlatformTheme.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNodesSectionCard() {
    final allNodes = _proxySvc.nodes;
    final isCompact = MediaQuery.sizeOf(context).width < 680;
    final filtered = allNodes.where((n) {
      if (_protocolFilter != 'all' &&
          n.protocol.toLowerCase() != _protocolFilter) {
        return false;
      }
      if (_nodeSearchQuery.isNotEmpty) {
        final q = _nodeSearchQuery.toLowerCase();
        final hay = '${n.name} ${n.server} ${n.protocol} ${n.regionCategory}'
            .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      if (_nodeSortBy == 'latency') {
        return a.effectiveScore.compareTo(b.effectiveScore);
      }
      if (_nodeSortBy == 'name') {
        return a.name.compareTo(b.name);
      }
      return 0;
    });

    final activeNodeId = _proxySvc.activeNode?.id;
    final fastestNodeId = _proxySvc.fastestNode?.id;

    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.public_rounded,
          size: 18,
          color: VideoPlatformTheme.accent,
        ),
        const SizedBox(width: 8),
        Text(
          '代理节点列表',
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: VideoPlatformTheme.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '(${filtered.length} / ${allNodes.length})',
          style: TextStyle(
            fontSize: 12,
            color: VideoPlatformTheme.textMuted,
          ),
        ),
      ],
    );

    final actionButtons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _proxySvc.isTestingNodes || allNodes.isEmpty
              ? null
              : () => _proxySvc.testAllNodesLatency(),
          icon: const Icon(Icons.bolt_rounded, size: 15),
          label: const Text('全部测速'),
        ),
        OutlinedButton.icon(
          onPressed: allNodes.any((n) => n.isTimeout)
              ? () => _proxySvc.removeUnreachableNodes()
              : null,
          icon: const Icon(Icons.cleaning_services_outlined, size: 15),
          label: const Text('清理超时'),
        ),
        FilledButton.tonalIcon(
          onPressed: () => _showManualNodeDialog(),
          icon: const Icon(Icons.add_rounded, size: 15),
          label: const Text('手动新增节点'),
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(isCompact ? 12 : 16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header + Action Buttons
          if (isCompact) ...[
            titleRow,
            const SizedBox(height: 10),
            actionButtons,
          ] else
            Row(
              children: [
                titleRow,
                const Spacer(),
                Flexible(child: actionButtons),
              ],
            ),
          const SizedBox(height: 12),

          // Filter & Search Bar
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: isCompact ? double.infinity : 240,
                height: 36,
                child: TextField(
                  controller: _nodeSearchCtrl,
                  onChanged: (v) => setState(() => _nodeSearchQuery = v.trim()),
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: '搜索节点名称、地区或域名...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 16),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 0,
                    ),
                    suffixIcon: _nodeSearchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close_rounded, size: 14),
                            onPressed: () {
                              _nodeSearchCtrl.clear();
                              setState(() => _nodeSearchQuery = '');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              ...const [
                ('all', '全部协议'),
                ('ss', 'SS'),
                ('trojan', 'Trojan'),
                ('vmess', 'VMess'),
                ('vless', 'VLESS'),
                ('socks5', 'SOCKS5'),
                ('http', 'HTTP'),
              ].map((pair) {
                final sel = _protocolFilter == pair.$1;
                return ChoiceChip(
                  label: Text(pair.$2, style: const TextStyle(fontSize: 11.5)),
                  selected: sel,
                  onSelected: (_) => setState(() => _protocolFilter = pair.$1),
                );
              }),
              const SizedBox(width: 6),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _nodeSortBy,
                  dropdownColor: VideoPlatformTheme.bgElevated,
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'latency',
                      child: Text('排序：延迟从低到高'),
                    ),
                    DropdownMenuItem(
                      value: 'default',
                      child: Text('排序：默认顺序'),
                    ),
                    DropdownMenuItem(
                      value: 'name',
                      child: Text('排序：按名称'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _nodeSortBy = v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          if (filtered.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 36,
                    color: VideoPlatformTheme.textMuted,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    allNodes.isEmpty
                        ? '当前暂无代理节点，请点击上方「立即更新」拉取订阅、或点击「粘贴导入节点」/「同步服务端节点」'
                        : '没有符合筛选条件的代理节点',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: VideoPlatformTheme.textSecondary,
                    ),
                  ),
                  if (allNodes.isEmpty) ...[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _proxySvc.refreshAllSubscriptions(),
                          icon: const Icon(Icons.sync_rounded, size: 16),
                          label: const Text('拉取订阅节点'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _showPasteImportDialog,
                          icon: const Icon(
                            Icons.content_paste_go_rounded,
                            size: 16,
                          ),
                          label: const Text('粘贴导入节点'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              _loadServerProxyConfig(syncToClient: true),
                          icon: const Icon(Icons.dns_outlined, size: 16),
                          label: const Text('导入服务端自建节点'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = constraints.maxWidth >= 1080
                    ? 3
                    : (constraints.maxWidth >= 680 ? 2 : 1);
                final spacing = 10.0;
                final itemWidth =
                    (constraints.maxWidth - spacing * (cols - 1)) / cols;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: filtered.map((node) {
                    return SizedBox(
                      width: itemWidth,
                      child: _buildProxyNodeCard(
                        node,
                        isActive: node.id == activeNodeId,
                        isFastest: node.id == fastestNodeId,
                      ),
                    );
                  }).toList(),
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _activateNodeFromCard(String nodeId) async {
    if (!_proxySvc.proxyEnabled) {
      await _proxySvc.setProxyEnabled(true);
    }
    for (final s in const [
      RequestScenario.vodApi,
      RequestScenario.vodStream,
      RequestScenario.liveStream,
      RequestScenario.telegram,
    ]) {
      final cur = _proxySvc.scenarioRules[s];
      if (cur != null && cur.mode == ScenarioRouteMode.direct) {
        await _proxySvc.updateScenarioRule(
          s,
          mode: ScenarioRouteMode.followGlobal,
          clearSpecificNode: true,
        );
      }
    }
    await _proxySvc.selectNode(
      nodeId,
      switchToManual: true,
    );
  }

  Widget _buildProxyNodeCard(
    ProxyNode node, {
    required bool isActive,
    required bool isFastest,
  }) {
    final isTestingThis = _proxySvc.testingNodeId == node.id;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _activateNodeFromCard(node.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isActive
              ? VideoPlatformTheme.accent.withValues(alpha: 0.11)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgElevated,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: VideoPlatformTheme.borderStrong),
                  ),
                  child: Text(
                    node.protocolBadge,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    node.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ),
                if (isFastest)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.success.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '⚡ 最快',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.success,
                      ),
                    ),
                  ),
                _buildLatencyBadge(
                  node.latencyMs,
                  speedLabel: node.speedLabel,
                  isInfoNode: node.isInfoNode,
                  isTesting: isTestingThis,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${node.server}:${node.port}${node.tcpPingMs != null && node.tcpPingMs! > 0 ? " · 入口TCP ${node.tcpPingMs}ms" : ""}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                      color: VideoPlatformTheme.textSecondary,
                    ),
                  ),
                ),
                if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '当前生效',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                InkWell(
                  onTap: () => _proxySvc.toggleNodeFavorite(node.id),
                  child: Icon(
                    node.favorite
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    size: 17,
                    color: node.favorite
                        ? Colors.amber
                        : VideoPlatformTheme.textMuted,
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: isTestingThis
                      ? null
                      : () => _proxySvc.testSingleNodeLatency(node.id),
                  child: Text(
                    '测速',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: node.toShareUri()));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已复制「${node.name}」分享链接'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Text(
                    '复制链接',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: VideoPlatformTheme.textSecondary,
                    ),
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => _showManualNodeDialog(node),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 15,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _proxySvc.deleteNode(node.id),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 15,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLatencyBadge(
    int? latencyMs, {
    String speedLabel = '',
    bool isInfoNode = false,
    bool isTesting = false,
  }) {
    if (isTesting) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (isInfoNode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.textMuted.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '信息节点',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: VideoPlatformTheme.textMuted,
          ),
        ),
      );
    }
    Color color;
    String text;
    if (latencyMs == null) {
      color = VideoPlatformTheme.textMuted;
      text = '未测速';
    } else if (latencyMs < 0) {
      color = VideoPlatformTheme.danger;
      text = '不可用';
    } else if (latencyMs <= 380) {
      color = VideoPlatformTheme.success;
      text = speedLabel.isNotEmpty
          ? '$latencyMs ms · $speedLabel'
          : '$latencyMs ms';
    } else if (latencyMs <= 900) {
      color = VideoPlatformTheme.warning;
      text = speedLabel.isNotEmpty
          ? '$latencyMs ms · $speedLabel'
          : '$latencyMs ms';
    } else {
      color = VideoPlatformTheme.danger;
      text = speedLabel.isNotEmpty
          ? '$latencyMs ms · $speedLabel'
          : '$latencyMs ms';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: Scenario-Based Request Routing Rules
  // ---------------------------------------------------------------------------

  Widget _buildScenarioRoutingTab() {
    final rules = _proxySvc.scenarioRules;
    final allNodes = _proxySvc.nodes.where((n) => n.enabled).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quick Preset Bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.bgElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: VideoPlatformTheme.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_fix_high_rounded,
                      size: 18,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '分场景智能分流预设方案',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '为不同业务场景（点播接口、点播视频流、电视直播、Telegram、主控服务器、外部嗅探）定制请求走法，并支持为特定场景单独锁定专属节点',
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          _proxySvc.applyScenarioPreset('smart_recommended'),
                      icon: const Icon(Icons.rocket_launch_rounded, size: 15),
                      label: const Text('🚀 推荐智能分流 (海外/TG代理 · 国内直连)'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _proxySvc.applyScenarioPreset('follow_global'),
                      icon: const Icon(Icons.sync_alt_rounded, size: 15),
                      label: const Text('🔄 全部跟随全局开关'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _proxySvc.applyScenarioPreset('telegram_only'),
                      icon: const Icon(Icons.send_rounded, size: 15),
                      label: const Text('✈️ 仅 Telegram 与订阅走代理'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _proxySvc.applyScenarioPreset('all_proxy'),
                      icon: const Icon(Icons.public_rounded, size: 15),
                      label: const Text('🌐 全场景走代理节点'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _proxySvc.applyScenarioPreset('server_relay'),
                      icon: const Icon(Icons.dns_rounded, size: 15),
                      label: const Text('🛡️ 点播与直播走服务端中转'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Individual Scenario Cards
          ...RequestScenario.values.map((scenario) {
            final rule =
                rules[scenario] ?? ScenarioRuleConfig(scenario: scenario);
            return _buildScenarioRuleCard(scenario, rule, allNodes);
          }),
        ],
      ),
    );
  }

  IconData _scenarioIcon(RequestScenario scenario) {
    switch (scenario) {
      case RequestScenario.vodApi:
        return Icons.movie_filter_rounded;
      case RequestScenario.vodStream:
        return Icons.play_circle_outline_rounded;
      case RequestScenario.liveStream:
        return Icons.live_tv_rounded;
      case RequestScenario.telegram:
        return Icons.send_rounded;
      case RequestScenario.backendApi:
        return Icons.storage_rounded;
      case RequestScenario.externalWeb:
        return Icons.travel_explore_rounded;
    }
  }

  Widget _buildScenarioRuleCard(
    RequestScenario scenario,
    ScenarioRuleConfig rule,
    List<ProxyNode> allNodes,
  ) {
    final effective = _proxySvc.resolveEffectiveRoute(scenario);
    final targetNode = _proxySvc.resolveNodeForScenario(scenario);
    final isCompact = MediaQuery.sizeOf(context).width < 680;

    String effectiveLabel;
    Color effectiveColor;
    switch (effective) {
      case ScenarioRouteMode.proxyNode:
        effectiveLabel =
            '当前生效：代理节点 (${targetNode?.displayTitle ?? "未选节点"})';
        effectiveColor = VideoPlatformTheme.accent;
        break;
      case ScenarioRouteMode.serverRelay:
        effectiveLabel = '当前生效：服务端代理中转';
        effectiveColor = VideoPlatformTheme.warning;
        break;
      default:
        effectiveLabel = '当前生效：客户端直连 (Direct)';
        effectiveColor = VideoPlatformTheme.success;
        break;
    }

    final effectiveBadge = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 9,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        effectiveLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: effectiveColor,
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(isCompact ? 12 : 16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _scenarioIcon(scenario),
                  size: 19,
                  color: VideoPlatformTheme.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      scenario.label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      scenario.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(width: 8),
                Flexible(child: effectiveBadge),
              ],
            ],
          ),
          if (isCompact) ...[
            const SizedBox(height: 8),
            effectiveBadge,
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...ScenarioRouteMode.values.map((m) {
                final selected = rule.mode == m;
                return ChoiceChip(
                  label: Text(
                    m.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  selected: selected,
                  onSelected: (_) => _proxySvc.updateScenarioRule(
                    scenario,
                    mode: m,
                  ),
                );
              }),
              if (rule.mode != ScenarioRouteMode.direct &&
                  rule.mode != ScenarioRouteMode.serverRelay &&
                  allNodes.isNotEmpty) ...[
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isCompact ? 310 : 380,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgCard,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: VideoPlatformTheme.borderSubtle),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: (rule.specificNodeId != null &&
                                allNodes
                                    .any((n) => n.id == rule.specificNodeId))
                            ? rule.specificNodeId!
                            : '__global__',
                        dropdownColor: VideoPlatformTheme.bgElevated,
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '__global__',
                            child: Text(
                              '节点：跟随全局 (${_proxySvc.selectionMode == ProxySelectionMode.autoFastest ? "自动最快" : (_proxySvc.activeNode?.displayTitle ?? "默认")})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ...allNodes.map(
                            (n) => DropdownMenuItem(
                              value: n.id,
                              child: Text(
                                '专属节点：${n.displayTitle} (${n.latencyLabel})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) {
                          if (val == null) return;
                          if (val == '__global__') {
                            _proxySvc.updateScenarioRule(
                              scenario,
                              clearSpecificNode: true,
                            );
                          } else {
                            _proxySvc.updateScenarioRule(
                              scenario,
                              specificNodeId: val,
                            );
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 2: Server-Side Proxy Listeners (/api/proxy)
  // ---------------------------------------------------------------------------

  Widget _buildServerListenersTab() {
    if (_isLoadingServer) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: VideoPlatformTheme.accent,
        ),
      );
    }

    final isCompact = MediaQuery.sizeOf(context).width < 680;

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 12 : 18,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgCard,
            border: Border(
              bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isCompact ? 340 : 480,
                ),
                child: Text(
                  _serverStatusMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: _serverStatusIsError
                        ? VideoPlatformTheme.danger
                        : (_isServerDirty
                            ? VideoPlatformTheme.warning
                            : VideoPlatformTheme.textSecondary),
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _loadServerProxyConfig(syncToClient: true),
                    icon: const Icon(Icons.download_done_rounded, size: 15),
                    label: const Text('导入到客户端节点池'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isLoadingServer ? null : _loadServerProxyConfig,
                    icon: const Icon(Icons.refresh, size: 15),
                    label: const Text('刷新状态'),
                  ),
                  FilledButton.icon(
                    onPressed: _isSavingServer ? null : _saveAndApplyAll,
                    icon: const Icon(Icons.save_outlined, size: 15),
                    label: Text(_isSavingServer ? '正在应用...' : '保存并应用'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = constraints.maxWidth >= 900;
              if (isDesktop) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _buildServicesListPanel(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 5,
                      child: _buildEditorPanel(),
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                child: Column(
                  children: [
                    _buildServicesListPanel(shrinkWrap: true),
                    const Divider(height: 1),
                    _buildEditorPanel(shrinkWrap: true),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showShareProxyDialog(ProxyServiceConfig s) async {
    final shareUri = _buildShareUri(s);
    final clashYaml = _buildClashYaml(s);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Row(
          children: [
            const Icon(Icons.share_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '节点分享与导出 · ${s.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '标准协议分享链接 (Shadowrocket / v2rayN / NekoBox)：',
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: VideoPlatformTheme.borderSubtle),
                ),
                child: Text(
                  shareUri,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: shareUri));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制节点分享链接')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('复制节点链接'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: clashYaml));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制 Clash YAML 节点配置')),
                      );
                    },
                    icon: const Icon(Icons.code_rounded, size: 15),
                    label: const Text('复制 Clash 配置'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Clash / Mihomo 节点配置片段：',
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: VideoPlatformTheme.borderSubtle),
                ),
                child: Text(
                  clashYaml,
                  style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _applyEditorFields([ProxyServiceConfig? service]) {
    if (service != null) {
      _editingId = service.id;
      _nameCtrl.text = service.name;
      _protocol = service.protocol;
      _listenHostCtrl.text = service.listenHost;
      _portCtrl.text = service.port.toString();
      _enabled = service.enabled;
      _usernameCtrl.text = service.username;
      _passwordCtrl.text = service.password;
      _cipher = _ssCiphers.contains(service.cipher)
          ? service.cipher
          : 'aes-256-gcm';
      _certFileCtrl.text =
          service.certFile.isNotEmpty ? service.certFile : 'certs/origin.pem';
      _keyFileCtrl.text =
          service.keyFile.isNotEmpty ? service.keyFile : 'certs/origin.key';
    } else {
      _editingId = '';
      _nameCtrl.clear();
      _protocol = 'http';
      _listenHostCtrl.text = '127.0.0.1';
      _portCtrl.text = '3128';
      _enabled = true;
      _usernameCtrl.clear();
      _passwordCtrl.clear();
      _cipher = 'aes-256-gcm';
      _certFileCtrl.text = 'certs/origin.pem';
      _keyFileCtrl.text = 'certs/origin.key';
    }
  }

  void _resetEditor([ProxyServiceConfig? service]) {
    _applyEditorFields(service);
    setState(() {});
  }

  bool _isLoopbackHost(String host) {
    final h = host.trim().toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    return h == 'localhost' ||
        h == '::1' ||
        RegExp(r'^127(?:\.\d{1,3}){3}$').hasMatch(h);
  }

  String? _validateService(ProxyServiceConfig s) {
    if (s.name.trim().isEmpty) return '请填写服务名称';
    if (s.listenHost.trim().isEmpty) return '请填写监听地址';
    if (s.port < 1 || s.port > 65535) return '监听端口必须在 1 到 65535 之间';
    if (s.protocol == 'http' || s.protocol == 'socks5') {
      if (s.username.isNotEmpty != s.password.isNotEmpty) {
        return '用户名和密码必须同时填写或同时留空';
      }
      if (!_isLoopbackHost(s.listenHost) &&
          (s.username.isEmpty || s.password.isEmpty)) {
        return '监听非本机回环地址 (如 0.0.0.0) 时必须设置用户名和密码';
      }
    }
    if ((s.protocol == 'ss' || s.protocol == 'trojan') && s.password.isEmpty) {
      return '${s.protocolLabel} 协议必须设置连接密码';
    }
    if (s.protocol == 'trojan' &&
        (s.certFile.trim().isEmpty || s.keyFile.trim().isEmpty)) {
      return 'Trojan 协议必须填写 TLS 证书与私钥文件路径';
    }
    return null;
  }

  bool _commitEditorToList() {
    final port = int.tryParse(_portCtrl.text.trim()) ?? 0;
    final id = _editingId.isNotEmpty
        ? _editingId
        : 'proxy-service-${DateTime.now().millisecondsSinceEpoch}';
    final candidate = ProxyServiceConfig(
      id: id,
      name: _nameCtrl.text.trim(),
      protocol: _protocol,
      listenHost: _listenHostCtrl.text.trim(),
      port: port,
      enabled: _enabled,
      username: (_protocol == 'http' || _protocol == 'socks5')
          ? _usernameCtrl.text.trim()
          : '',
      password: _passwordCtrl.text,
      cipher: _protocol == 'ss' ? _cipher : '',
      certFile: _protocol == 'trojan' ? _certFileCtrl.text.trim() : '',
      keyFile: _protocol == 'trojan' ? _keyFileCtrl.text.trim() : '',
    );

    final err = _validateService(candidate);
    if (err != null) {
      setState(() {
        _serverStatusIsError = true;
        _serverStatusMessage = err;
      });
      return false;
    }

    setState(() {
      final idx = _services.indexWhere((s) => s.id == candidate.id);
      if (idx >= 0) {
        _services[idx] = candidate;
      } else {
        _services = [..._services, candidate];
      }
      _isServerDirty = true;
      _serverStatusIsError = false;
      _serverStatusMessage = '已将“${candidate.name}”更新到列表，请点击“保存并应用”使其生效';
    });
    _resetEditor(candidate);
    return true;
  }

  Future<void> _saveAndApplyAll() async {
    for (final s in _services) {
      final err = _validateService(s);
      if (err != null) {
        setState(() {
          _serverStatusIsError = true;
          _serverStatusMessage = '“${s.name}”配置有误：$err';
        });
        _resetEditor(s);
        return;
      }
    }

    final seenListeners = <String>{};
    for (final s in _services) {
      if (!s.enabled) continue;
      final key = '${s.listenHost.toLowerCase()}:${s.port}';
      if (seenListeners.contains(key)) {
        setState(() {
          _serverStatusIsError = true;
          _serverStatusMessage =
              '“${s.name}”与其他已启用服务使用了相同的监听地址和端口 ($key)';
        });
        return;
      }
      seenListeners.add(key);
    }

    setState(() {
      _isSavingServer = true;
      _serverStatusIsError = false;
      _serverStatusMessage = '正在保存配置并启动/更新监听服务...';
    });

    try {
      final res = await widget.appState.api.saveProxyConfig(_services);
      if (!mounted) return;
      final statusMap = <String, ProxyRuntimeStatus>{};
      for (final st in res.statuses) {
        statusMap[st.id] = st;
      }
      final runningCount = res.statuses.where((st) => st.running).length;
      final failedCount =
          res.statuses.where((st) => st.error.isNotEmpty).length;

      setState(() {
        _services = res.services;
        _statuses = statusMap;
        _persistedIds = res.services.map((s) => s.id).toSet();
        _isServerDirty = false;
        _isSavingServer = false;
        _serverStatusIsError = failedCount > 0;
        _serverStatusMessage =
            '配置已应用：$runningCount 个服务运行中${failedCount > 0 ? "，$failedCount 个启动失败" : ""}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSavingServer = false;
        _serverStatusIsError = true;
        _serverStatusMessage = '保存代理配置失败：$e';
      });
    }
  }

  Future<void> _testSingleService(ProxyServiceConfig service) async {
    if (_isServerDirty || !_persistedIds.contains(service.id)) {
      setState(() {
        _serverStatusIsError = true;
        _serverStatusMessage = '请先点击“保存并应用”，再检查服务运行状态';
      });
      return;
    }

    setState(() {
      _testingServiceId = service.id;
      _serverStatusIsError = false;
      _serverStatusMessage = '正在检查“${service.name}”运行状态...';
    });

    try {
      final runtime = await widget.appState.api.testProxyService(service.id);
      if (!mounted) return;
      setState(() {
        _testingServiceId = null;
        _statuses[service.id] = runtime;
        _serverStatusIsError = !runtime.running && service.enabled;
        _serverStatusMessage =
            '“${service.name}”：${_formatRuntimeStatus(service, runtime)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testingServiceId = null;
        _serverStatusIsError = true;
        _serverStatusMessage = '检查状态失败：$e';
      });
    }
  }

  String _formatRuntimeStatus(
    ProxyServiceConfig service,
    ProxyRuntimeStatus? runtime,
  ) {
    if (!service.enabled) return '已停用';
    if (runtime == null) return '等待启动';
    if (runtime.running) {
      final parts = <String>['运行中'];
      if (runtime.address.isNotEmpty) parts.add(runtime.address);
      if (runtime.activeConnections > 0) {
        parts.add('${runtime.activeConnections} 个活动连接');
      }
      return parts.join(' · ');
    }
    if (runtime.error.isNotEmpty) {
      return '启动失败 · ${runtime.error}';
    }
    return '等待启动';
  }

  Widget _buildServicesListPanel({bool shrinkWrap = false}) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [
          Text(
            '监听服务列表',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '(${_services.length})',
            style: TextStyle(
              fontSize: 12,
              color: VideoPlatformTheme.textMuted,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () => _resetEditor(),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('新增服务'),
          ),
        ],
      ),
    );

    if (_services.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
        children: [
          header,
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                '暂无服务端代理服务，可在右侧表单中新增并保存应用',
                style: TextStyle(
                  color: VideoPlatformTheme.textMuted,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final listWidget = ListView.separated(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(16),
      itemCount: _services.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final s = _services[index];
        final runtime = _statuses[s.id];
        final isRunning = runtime?.running == true && s.enabled;
        final hasError = (runtime?.error.isNotEmpty == true) && s.enabled;
        final isEditing = _editingId == s.id;

        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _resetEditor(s),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.bgElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isEditing
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.borderSubtle,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Switch(
                      value: s.enabled,
                      activeColor: VideoPlatformTheme.accent,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (val) {
                        setState(() {
                          _services[index] = s.copyWith(enabled: val);
                          if (_editingId == s.id) _enabled = val;
                          _isServerDirty = true;
                          _serverStatusMessage =
                              '“${s.name}”将在点击“保存并应用”后${val ? "启动" : "停止"}';
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: VideoPlatformTheme.bgCard,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: VideoPlatformTheme.borderStrong,
                                  ),
                                ),
                                child: Text(
                                  s.protocolLabel,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: VideoPlatformTheme.accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: VideoPlatformTheme.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '监听地址：${s.listenHost}:${s.port}',
                            style: TextStyle(
                              fontSize: 12,
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatRuntimeStatus(s, runtime),
                            style: TextStyle(
                              fontSize: 11,
                              color: hasError
                                  ? VideoPlatformTheme.danger
                                  : (isRunning
                                      ? VideoPlatformTheme.success
                                      : VideoPlatformTheme.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: _testingServiceId == s.id
                          ? null
                          : () => _testSingleService(s),
                      child: Text(_testingServiceId == s.id ? '检测中...' : '检测状态'),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.qr_code_rounded, size: 15),
                      label: const Text('分享'),
                      onPressed: () => _showShareProxyDialog(s),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.edit_outlined, size: 15),
                      label: const Text('编辑'),
                      onPressed: () => _resetEditor(s),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: VideoPlatformTheme.danger,
                      ),
                      icon: const Icon(Icons.delete_outline, size: 15),
                      label: const Text('删除'),
                      onPressed: () {
                        setState(() {
                          _services.removeWhere((item) => item.id == s.id);
                          _statuses.remove(s.id);
                          if (_editingId == s.id) _applyEditorFields(null);
                          _isServerDirty = true;
                          _serverStatusMessage =
                              '已从列表移除“${s.name}”，请点击“保存并应用”停止监听';
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (shrinkWrap) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const Divider(height: 1),
          listWidget,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const Divider(height: 1),
        Expanded(child: listWidget),
      ],
    );
  }

  Widget _buildEditorPanel({bool shrinkWrap = false}) {
    final isHttpOrSocks = _protocol == 'http' || _protocol == 'socks5';
    final isSs = _protocol == 'ss';
    final isTrojan = _protocol == 'trojan';

    final formContent = Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _editingId.isEmpty ? '新增服务端代理服务' : '编辑服务端代理服务',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '支持 HTTP (含 CONNECT)、SOCKS5、Shadowsocks (AEAD) 和 Trojan (TCP/TLS)',
            style: TextStyle(
              fontSize: 12,
              color: VideoPlatformTheme.textMuted,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '服务名称',
                    hintText: '例如：家庭 SOCKS5',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _protocol,
                  dropdownColor: VideoPlatformTheme.bgElevated,
                  decoration: const InputDecoration(labelText: '代理协议'),
                  items: const [
                    DropdownMenuItem(
                      value: 'http',
                      child: Text(
                        'HTTP (支持 CONNECT)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'socks5',
                      child: Text(
                        'SOCKS5 (兼容 HTTP)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'ss',
                      child: Text(
                        'Shadowsocks (SS)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'trojan',
                      child: Text(
                        'Trojan (TCP/TLS)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (val) {
                    if (val == null) return;
                    setState(() {
                      _protocol = val;
                      _portCtrl.text = (_defaultPorts[val] ?? 1080).toString();
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _listenHostCtrl,
                  decoration: const InputDecoration(
                    labelText: '监听地址',
                    hintText: '127.0.0.1 或 0.0.0.0',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '监听端口',
                    hintText: '1080',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              '保存后立即启动此服务',
              style: TextStyle(fontSize: 13),
            ),
            value: _enabled,
            activeColor: VideoPlatformTheme.accent,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          if (isHttpOrSocks) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: '认证用户名 (监听公网必填)',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _passwordCtrl,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: '认证密码 (回环监听可选)',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            TextField(
              controller: _passwordCtrl,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '${isSs ? "Shadowsocks" : "Trojan"} 连接密码 (必填)',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(
                    () => _obscurePassword = !_obscurePassword,
                  ),
                ),
              ),
            ),
          ],
          if (isSs) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _cipher,
              dropdownColor: VideoPlatformTheme.bgElevated,
              decoration: const InputDecoration(
                labelText: 'Shadowsocks AEAD 加密算法',
              ),
              items: _ssCiphers
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _cipher = v);
              },
            ),
          ],
          if (isTrojan) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _certFileCtrl,
                    decoration: const InputDecoration(
                      labelText: 'TLS 证书文件路径',
                      hintText: 'certs/origin.pem',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _keyFileCtrl,
                    decoration: const InputDecoration(
                      labelText: 'TLS 私钥文件路径',
                      hintText: 'certs/origin.key',
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _commitEditorToList,
                icon: Icon(
                  _editingId.isEmpty ? Icons.add : Icons.check,
                  size: 16,
                ),
                label: Text(_editingId.isEmpty ? '添加到列表' : '更新到列表'),
              ),
              OutlinedButton(
                onPressed: () => _resetEditor(),
                child: const Text('清空表单'),
              ),
            ],
          ),
        ],
      ),
    );

    if (shrinkWrap) return formContent;
    return SingleChildScrollView(child: formContent);
  }

  String _formatRelativeTime(int timestampMs) {
    final diff = DateTime.now().millisecondsSinceEpoch - timestampMs;
    if (diff < 60000) return '刚刚更新';
    final mins = diff ~/ 60000;
    if (mins < 60) return '$mins 分钟前更新';
    final hours = mins ~/ 60;
    if (hours < 24) return '$hours 小时前更新';
    return '${hours ~/ 24} 天前更新';
  }
}

class _UpsertSubscriptionResult {
  final String name;
  final String url;
  final bool enabled;
  final int autoUpdateHours;
  final String customUserAgent;

  const _UpsertSubscriptionResult({
    required this.name,
    required this.url,
    required this.enabled,
    required this.autoUpdateHours,
    required this.customUserAgent,
  });
}

class _UpsertSubscriptionDialog extends StatefulWidget {
  final ProxySubscription? existing;

  const _UpsertSubscriptionDialog({this.existing});

  @override
  State<_UpsertSubscriptionDialog> createState() =>
      _UpsertSubscriptionDialogState();
}

class _UpsertSubscriptionDialogState extends State<_UpsertSubscriptionDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _uaCtrl;
  late int _autoHours;
  late bool _enabled;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameCtrl = TextEditingController(
      text: existing?.name ?? '良心云订阅 (liangxin.xyz)',
    );
    _urlCtrl = TextEditingController(
      text: existing?.url ?? kDefaultLiangxinSubscriptionUrl,
    );
    _uaCtrl = TextEditingController(
      text: existing?.customUserAgent ?? '',
    );
    _autoHours = existing?.autoUpdateHours ?? 12;
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _uaCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final u = _urlCtrl.text.trim();
    if (u.isEmpty) {
      setState(() => _validationError = '请输入有效的订阅地址 URL');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(
      _UpsertSubscriptionResult(
        name: _nameCtrl.text.trim().isEmpty
            ? '代理订阅'
            : _nameCtrl.text.trim(),
        url: u,
        enabled: _enabled,
        autoUpdateHours: _autoHours,
        customUserAgent: _uaCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final isCompact = MediaQuery.sizeOf(context).width < 560;
    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      title: Row(
        children: [
          Icon(
            Icons.rss_feed_rounded,
            size: 19,
            color: VideoPlatformTheme.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              existing == null ? '新增代理订阅链接' : '编辑代理订阅链接',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '订阅名称',
                  hintText: '例如：良心云订阅 (liangxin.xyz)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlCtrl,
                maxLines: 2,
                onChanged: (_) {
                  if (_validationError != null) {
                    setState(() => _validationError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: '订阅地址 URL (支持 V2Board / Clash / Base64 / SIP008)',
                  hintText: kDefaultLiangxinSubscriptionUrl,
                  errorText: _validationError,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (Platform.isAndroid || Platform.isIOS) ...[
                    ActionChip(
                      avatar: const Icon(
                        Icons.qr_code_scanner_rounded,
                        size: 15,
                      ),
                      label: const Text(
                        '摄像头扫码填入',
                        style: TextStyle(fontSize: 11.5),
                      ),
                      onPressed: () async {
                        FocusManager.instance.primaryFocus?.unfocus();
                        final raw = await _qrScannerChannel
                            .invokeMethod<String>('scanCamera');
                        if (!mounted || raw == null || raw.trim().isEmpty) {
                          return;
                        }
                        final parsed = _tryParseSubscriptionFromQrText(raw);
                        if (parsed != null) {
                          _urlCtrl.text = parsed.url;
                          if (_nameCtrl.text.trim().isEmpty) {
                            _nameCtrl.text = parsed.name;
                          }
                        } else {
                          _urlCtrl.text = raw.trim();
                        }
                        if (_validationError != null) {
                          setState(() => _validationError = null);
                        }
                      },
                    ),
                    ActionChip(
                      avatar: const Icon(
                        Icons.photo_library_outlined,
                        size: 15,
                      ),
                      label: const Text(
                        '相册选图识别二维码',
                        style: TextStyle(fontSize: 11.5),
                      ),
                      onPressed: () async {
                        FocusManager.instance.primaryFocus?.unfocus();
                        final raw = await _qrScannerChannel
                            .invokeMethod<String>('scanGallery');
                        if (!mounted || raw == null || raw.trim().isEmpty) {
                          return;
                        }
                        final parsed = _tryParseSubscriptionFromQrText(raw);
                        if (parsed != null) {
                          _urlCtrl.text = parsed.url;
                          if (_nameCtrl.text.trim().isEmpty) {
                            _nameCtrl.text = parsed.name;
                          }
                        } else {
                          _urlCtrl.text = raw.trim();
                        }
                        if (_validationError != null) {
                          setState(() => _validationError = null);
                        }
                      },
                    ),
                  ],
                  ActionChip(
                    avatar: const Icon(Icons.bolt_rounded, size: 15),
                    label: const Text(
                      '一键填入良心云默认订阅地址',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    onPressed: () {
                      _nameCtrl.text = '良心云订阅 (liangxin.xyz)';
                      _urlCtrl.text = kDefaultLiangxinSubscriptionUrl;
                      if (_validationError != null) {
                        setState(() => _validationError = null);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (isCompact) ...[
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  value: [0, 6, 12, 24, 72].contains(_autoHours)
                      ? _autoHours
                      : 12,
                  dropdownColor: VideoPlatformTheme.bgElevated,
                  decoration: const InputDecoration(
                    labelText: '自动更新周期',
                  ),
                  items: const [
                    DropdownMenuItem(value: 6, child: Text('每 6 小时更新')),
                    DropdownMenuItem(value: 12, child: Text('每 12 小时更新')),
                    DropdownMenuItem(value: 24, child: Text('每 24 小时更新')),
                    DropdownMenuItem(value: 72, child: Text('每 3 天更新')),
                    DropdownMenuItem(value: 0, child: Text('仅手动更新')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _autoHours = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _uaCtrl,
                  decoration: const InputDecoration(
                    labelText: '自定义 User-Agent (可选)',
                    hintText: '默认自动轮询 Clash / v2rayNG',
                  ),
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        value: [0, 6, 12, 24, 72].contains(_autoHours)
                            ? _autoHours
                            : 12,
                        dropdownColor: VideoPlatformTheme.bgElevated,
                        decoration: const InputDecoration(
                          labelText: '自动更新周期',
                        ),
                        items: const [
                          DropdownMenuItem(value: 6, child: Text('每 6 小时更新')),
                          DropdownMenuItem(value: 12, child: Text('每 12 小时更新')),
                          DropdownMenuItem(value: 24, child: Text('每 24 小时更新')),
                          DropdownMenuItem(value: 72, child: Text('每 3 天更新')),
                          DropdownMenuItem(value: 0, child: Text('仅手动更新')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _autoHours = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _uaCtrl,
                        decoration: const InputDecoration(
                          labelText: '自定义 User-Agent (可选)',
                          hintText: '默认自动轮询 Clash / v2rayNG',
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _enabled,
                activeColor: VideoPlatformTheme.accent,
                title: const Text(
                  '启用该订阅源',
                  style: TextStyle(fontSize: 13),
                ),
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.cloud_download_outlined, size: 16),
          label: const Text('保存并拉取订阅'),
        ),
      ],
    );
  }
}

class _PasteImportNodesDialog extends StatefulWidget {
  const _PasteImportNodesDialog();

  @override
  State<_PasteImportNodesDialog> createState() =>
      _PasteImportNodesDialogState();
}

class _PasteImportNodesDialogState extends State<_PasteImportNodesDialog> {
  final TextEditingController _textCtrl = TextEditingController();

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      title: Row(
        children: [
          Icon(
            Icons.content_paste_go_rounded,
            size: 19,
            color: VideoPlatformTheme.accent,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '粘贴导入订阅内容 / 节点链接 / Clash YAML',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '支持直接粘贴：Base64 订阅全文、Clash 配置 (含 proxies:)、或多行 ss:// / trojan:// / vmess:// / vless:// / socks5:// / http:// 节点分享链接',
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _textCtrl,
                maxLines: 7,
                decoration: InputDecoration(
                  hintText:
                      'ss://...\ntrojan://...\nvmess://...\n或粘贴 Clash proxies: 配置片段',
                  filled: true,
                  fillColor: VideoPlatformTheme.bgCard,
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            final clip = await Clipboard.getData(Clipboard.kTextPlain);
            if (!mounted) return;
            if (clip?.text != null) {
              _textCtrl.text = clip!.text!;
            }
          },
          icon: const Icon(Icons.paste_rounded, size: 15),
          label: const Text('粘贴剪贴板'),
        ),
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () {
            final raw = _textCtrl.text.trim();
            if (raw.isEmpty) return;
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop(raw);
          },
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('解析导入'),
        ),
      ],
    );
  }
}

class _ManualProxyNodeDialog extends StatefulWidget {
  final ProxyNode? existing;
  final List<String> ssCiphers;

  const _ManualProxyNodeDialog({
    this.existing,
    required this.ssCiphers,
  });

  @override
  State<_ManualProxyNodeDialog> createState() => _ManualProxyNodeDialogState();
}

class _ManualProxyNodeDialogState extends State<_ManualProxyNodeDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _sniCtrl;
  late String _proto;
  late String _cipher;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameCtrl = TextEditingController(text: existing?.name ?? '');
    _serverCtrl = TextEditingController(text: existing?.server ?? '');
    _portCtrl = TextEditingController(
      text: (existing?.port ?? 1080).toString(),
    );
    _userCtrl = TextEditingController(text: existing?.username ?? '');
    _passCtrl = TextEditingController(text: existing?.password ?? '');
    _sniCtrl = TextEditingController(text: existing?.sni ?? '');
    _proto = existing?.protocol ?? 'socks5';
    _cipher = existing?.cipher.isNotEmpty == true
        ? existing!.cipher
        : 'aes-256-gcm';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _serverCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _sniCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final isSs = _proto == 'ss';
    final isTrojanOrVless =
        _proto == 'trojan' || _proto == 'vless' || _proto == 'vmess';
    final isHttpOrSocks =
        _proto == 'http' || _proto == 'https' || _proto == 'socks5';

    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      title: Text(
        existing == null ? '手动新增代理节点' : '编辑代理节点 · ${existing.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '节点名称',
                        hintText: '例如：香港 BGP 01',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: [
                        'socks5',
                        'http',
                        'https',
                        'ss',
                        'trojan',
                        'vmess',
                        'vless',
                      ].contains(_proto)
                          ? _proto
                          : 'socks5',
                      dropdownColor: VideoPlatformTheme.bgElevated,
                      decoration: const InputDecoration(
                        labelText: '协议类型',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'socks5',
                          child: Text('SOCKS5', overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'http',
                          child: Text('HTTP', overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'https',
                          child: Text('HTTPS', overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'ss',
                          child: Text('SS', overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'trojan',
                          child: Text('Trojan', overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'vmess',
                          child: Text('VMess', overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'vless',
                          child: Text('VLESS', overflow: TextOverflow.ellipsis),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _proto = v);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _serverCtrl,
                      decoration: const InputDecoration(
                        labelText: '服务器地址 (Host / IP)',
                        hintText: 'hk1.example.com',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        hintText: '443',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (isHttpOrSocks) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _userCtrl,
                        decoration: const InputDecoration(
                          labelText: '用户名 (可选)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _passCtrl,
                        decoration: const InputDecoration(
                          labelText: '密码 (可选)',
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                TextField(
                  controller: _passCtrl,
                  decoration: InputDecoration(
                    labelText: isTrojanOrVless
                        ? '密码 / UUID'
                        : '连接密码 (Password)',
                  ),
                ),
              ],
              if (isSs) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: widget.ssCiphers.contains(_cipher)
                      ? _cipher
                      : 'aes-256-gcm',
                  dropdownColor: VideoPlatformTheme.bgElevated,
                  decoration: const InputDecoration(
                    labelText: '加密算法 (Cipher)',
                  ),
                  items: widget.ssCiphers
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _cipher = v);
                  },
                ),
              ],
              if (isTrojanOrVless) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _sniCtrl,
                  decoration: const InputDecoration(
                    labelText: 'SNI / ServerName (可选)',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final srv = _serverCtrl.text.trim();
            final prt = int.tryParse(_portCtrl.text.trim()) ?? 0;
            if (srv.isEmpty || prt <= 0) return;
            FocusManager.instance.primaryFocus?.unfocus();
            final node = ProxyNode(
              id: existing?.id ??
                  'manual_${DateTime.now().millisecondsSinceEpoch}',
              subscriptionId: existing?.subscriptionId ?? 'manual',
              name: _nameCtrl.text.trim().isEmpty
                  ? '${_proto.toUpperCase()} $srv:$prt'
                  : _nameCtrl.text.trim(),
              protocol: _proto,
              server: srv,
              port: prt,
              username: _userCtrl.text.trim(),
              password: _passCtrl.text.trim(),
              cipher: _cipher,
              sni: _sniCtrl.text.trim(),
              tls: _proto == 'trojan' || _proto == 'https',
              favorite: existing?.favorite ?? false,
            );
            Navigator.of(context).pop(node);
          },
          child: const Text('保存节点'),
        ),
      ],
    );
  }
}
