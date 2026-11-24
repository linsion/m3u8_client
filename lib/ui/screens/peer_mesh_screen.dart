import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/peer_mesh_service.dart';
import '../../services/tv_platform_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';

class PeerMeshScreen extends StatefulWidget {
  final AppState appState;

  const PeerMeshScreen({
    super.key,
    required this.appState,
  });

  @override
  State<PeerMeshScreen> createState() => _PeerMeshScreenState();
}

class _PeerMeshScreenState extends State<PeerMeshScreen> {
  final PeerMeshService _mesh = PeerMeshService.instance;

  String? _selectedPeerId;
  int _workspaceTabIndex = 0; // 0: 远程桌面, 1: 远程控制, 2: 文件互传, 3: 即时消息

  // Remote Desktop Streaming State
  bool _isStreamingDesktop = false;
  bool _isDesktopFullscreen = false;
  String _captureMode = 'auto'; // 'auto', 'desktop', 'app'
  String _activeRemoteMode = 'app';
  int _streamFps = 5;
  int _streamMaxWidth = 1280;
  int _streamQuality = 72;
  String _pointerTool = 'tap'; // 'tap', 'double_tap', 'right_click', 'drag'
  Uint8List? _latestFrameBytes;
  int _remoteScreenWidth = 1280;
  int _remoteScreenHeight = 720;
  bool _fetchingFrame = false;
  Timer? _pollingTimer;
  WebSocket? _activeWs;
  String? _desktopError;
  Offset? _lastTapNormalized;

  final TextEditingController _remoteInputController = TextEditingController();
  final TextEditingController _castUrlController = TextEditingController();
  final TextEditingController _castTitleController = TextEditingController();
  final TextEditingController _chatInputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  // Remote Shared Files State
  List<PeerSharedFileItem> _remoteFiles = const [];
  bool _loadingRemoteFiles = false;
  String _localSaveDirPath = '';
  bool _isDraggingFiles = false;

  // macOS permissions state
  bool _macHasScreenCapture = true;
  bool _macHasAccessibility = true;

  @override
  void initState() {
    super.initState();
    _mesh.setPeerScreenActive(true);
    _mesh.addListener(_onMeshChanged);
    NativeUtilsChannelHub.addListener(_handleNativeDropCall);
    unawaited(_initAsync());
  }

  Future<void> _initAsync() async {
    await _mesh.ensureInitialized();
    final dir = await _mesh.getPeerDownloadsDirectory();
    if (!kIsWeb && Platform.isMacOS) {
      final perms = await _mesh.checkMacDesktopPermissions(prompt: false);
      _macHasScreenCapture = perms['screenCapture'] == true;
      _macHasAccessibility = perms['accessibility'] == true;
    }
    if (!mounted) return;
    setState(() {
      _localSaveDirPath = dir.path;
      if (_selectedPeerId == null && _mesh.peers.isNotEmpty) {
        _selectedPeerId = _mesh.peers.first.deviceId;
      }
    });
    if (selectedPeer != null) {
      unawaited(_refreshRemoteSharedFiles());
    }
  }

  @override
  void dispose() {
    _stopDesktopStream(notify: false);
    _mesh.setPeerScreenActive(false);
    _mesh.removeListener(_onMeshChanged);
    NativeUtilsChannelHub.removeListener(_handleNativeDropCall);
    _remoteInputController.dispose();
    _castUrlController.dispose();
    _castTitleController.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  void _onMeshChanged() {
    if (!mounted) return;
    if (_selectedPeerId == null && _mesh.peers.isNotEmpty) {
      _selectedPeerId = _mesh.peers.first.deviceId;
    }
    setState(() {});
  }

  PeerDeviceNode? get selectedPeer {
    final peers = _mesh.peers;
    if (peers.isEmpty) return null;
    if (_selectedPeerId != null) {
      for (final p in peers) {
        if (p.deviceId == _selectedPeerId) return p;
      }
    }
    return peers.first;
  }

  void _selectPeer(PeerDeviceNode peer) {
    final changed = _selectedPeerId != peer.deviceId;
    setState(() {
      _selectedPeerId = peer.deviceId;
    });
    if (changed) {
      if (_isStreamingDesktop) {
        _startDesktopStream();
      }
      unawaited(_refreshRemoteSharedFiles());
    }
  }

  Future<dynamic> _handleNativeDropCall(MethodCall call) async {
    if (!mounted) return null;
    if (call.method == 'onFileDragUpdated') {
      final args = call.arguments;
      final active = args is Map && args['active'] == true;
      if (_isDraggingFiles != active) {
        setState(() => _isDraggingFiles = active);
      }
      return null;
    }
    if (call.method == 'onFilesDropped') {
      if (_isDraggingFiles) {
        setState(() => _isDraggingFiles = false);
      }
      final peer = selectedPeer;
      if (peer == null) return null;
      final rawList = call.arguments;
      if (rawList is List) {
        for (final item in rawList) {
          if (item is Map) {
            final name = (item['name'] ?? '传输文件').toString();
            final path = item['path']?.toString();
            final rawB = item['bytes'];
            final bytes =
                (rawB is Uint8List && rawB.isNotEmpty) ? rawB : null;
            if ((path != null && path.isNotEmpty) || bytes != null) {
              unawaited(
                _mesh.sendFileToPeer(
                  peer: peer,
                  fileName: name,
                  localFilePath: path,
                  rawBytes: bytes,
                ),
              );
            }
          }
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已开始向「${peer.deviceName}」发送拖拽文件')),
          );
        }
      }
    }
    return null;
  }

  // ===========================================================================
  // Remote Desktop Stream Management (WebSocket + HTTP Fallback)
  // ===========================================================================

  Future<void> _startDesktopStream() async {
    _stopDesktopStream(notify: false);
    final peer = selectedPeer;
    if (peer == null) return;

    setState(() {
      _isStreamingDesktop = true;
      _desktopError = null;
    });

    // If peer is across a different network (WAN Cloud Tunnel), stream via WAN RPC polling immediately
    if (!peer.isLanReachable) {
      _startHttpPollingFallback();
      return;
    }

    // Try WebSocket real-time stream first, with HTTP polling fallback
    try {
      final ws = await WebSocket.connect(peer.wsUrl)
          .timeout(const Duration(seconds: 3));
      if (!mounted || !_isStreamingDesktop) {
        await ws.close();
        return;
      }
      _activeWs = ws;
      ws.add(jsonEncode({
        'cmd': 'start_stream',
        'mode': _captureMode,
        'maxWidth': _streamMaxWidth,
        'quality': _streamQuality,
        'fps': _streamFps,
      }));
      ws.listen(
        (data) {
          if (!mounted || !_isStreamingDesktop) return;
          if (data is String) {
            try {
              final map = jsonDecode(data);
              if (map is Map<String, dynamic> &&
                  map['event'] == 'screen_frame') {
                final b64 = (map['data'] ?? '').toString();
                if (b64.isNotEmpty) {
                  final bytes = base64Decode(b64);
                  setState(() {
                    _latestFrameBytes = bytes;
                    _activeRemoteMode =
                        (map['mode'] ?? _captureMode).toString();
                    _remoteScreenWidth =
                        int.tryParse((map['width'] ?? 1280).toString()) ?? 1280;
                    _remoteScreenHeight =
                        int.tryParse((map['height'] ?? 720).toString()) ?? 720;
                    _desktopError = null;
                  });
                }
              }
            } catch (_) {}
          }
        },
        onDone: () {
          if (mounted && _isStreamingDesktop && _activeWs == ws) {
            _activeWs = null;
            _startHttpPollingFallback();
          }
        },
        onError: (_) {
          if (mounted && _isStreamingDesktop && _activeWs == ws) {
            _activeWs = null;
            _startHttpPollingFallback();
          }
        },
      );
    } catch (_) {
      if (mounted && _isStreamingDesktop) {
        _startHttpPollingFallback();
      }
    }
  }

  void _startHttpPollingFallback() {
    _pollingTimer?.cancel();
    unawaited(_pollSingleFrame());
    final intervalMs = (1000 ~/ _streamFps.clamp(1, 12)).clamp(110, 1000);
    _pollingTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => unawaited(_pollSingleFrame()),
    );
  }

  Future<void> _pollSingleFrame() async {
    if (_fetchingFrame || !_isStreamingDesktop) return;
    final peer = selectedPeer;
    if (peer == null) return;
    _fetchingFrame = true;
    try {
      final frame = await _mesh.fetchRemoteScreenFrame(
        peer,
        mode: _captureMode,
        maxWidth: _streamMaxWidth,
        quality: _streamQuality,
      );
      if (!mounted || !_isStreamingDesktop) return;
      if (frame != null) {
        setState(() {
          _latestFrameBytes = frame.bytes;
          _activeRemoteMode = frame.captureMode;
          _remoteScreenWidth = frame.width;
          _remoteScreenHeight = frame.height;
          _desktopError = null;
        });
      } else if (_latestFrameBytes == null) {
        setState(() {
          _desktopError = '暂未获取到「${peer.deviceName}」的远程画面，请确认对方在线';
        });
      }
    } finally {
      _fetchingFrame = false;
    }
  }

  void _stopDesktopStream({bool notify = true}) {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    final ws = _activeWs;
    _activeWs = null;
    if (ws != null) {
      try {
        ws.add(jsonEncode({'cmd': 'stop_stream'}));
        ws.close();
      } catch (_) {}
    }
    _isStreamingDesktop = false;
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _updateStreamParams() {
    final ws = _activeWs;
    if (ws != null && ws.readyState == WebSocket.open) {
      ws.add(jsonEncode({
        'cmd': 'start_stream',
        'mode': _captureMode,
        'maxWidth': _streamMaxWidth,
        'quality': _streamQuality,
        'fps': _streamFps,
      }));
    } else if (_isStreamingDesktop) {
      _startHttpPollingFallback();
    }
  }

  Future<void> _sendRemotePointer({
    required String type,
    required double nx,
    required double ny,
    double deltaX = 0,
    double deltaY = 0,
  }) async {
    final peer = selectedPeer;
    if (peer == null) return;
    setState(() {
      _lastTapNormalized = Offset(nx, ny);
    });
    final payload = {
      'action': 'mouse',
      'type': type,
      'nx': nx,
      'ny': ny,
      'deltaX': deltaX,
      'deltaY': deltaY,
      'targetMode': _activeRemoteMode,
    };
    final ws = _activeWs;
    if (ws != null && ws.readyState == WebSocket.open) {
      ws.add(jsonEncode(payload));
    } else {
      await _mesh.sendRemoteControlCommand(peer, payload);
      if (_isStreamingDesktop) {
        Future<void>.delayed(
          const Duration(milliseconds: 90),
          _pollSingleFrame,
        );
      }
    }
  }

  Future<void> _sendRemoteKey(String keyName) async {
    final peer = selectedPeer;
    if (peer == null) return;
    final payload = {
      'action': 'key',
      'key': keyName,
      'targetMode': _activeRemoteMode,
    };
    final ws = _activeWs;
    if (ws != null && ws.readyState == WebSocket.open) {
      ws.add(jsonEncode(payload));
    } else {
      await _mesh.sendRemoteControlCommand(peer, payload);
      if (_isStreamingDesktop) {
        Future<void>.delayed(
          const Duration(milliseconds: 90),
          _pollSingleFrame,
        );
      }
    }
  }

  Future<void> _sendRemoteText({required bool submit}) async {
    final peer = selectedPeer;
    final text = _remoteInputController.text;
    if (peer == null || text.isEmpty) return;
    final payload = {
      'action': 'text',
      'text': text,
      'submit': submit,
      'targetMode': _activeRemoteMode,
    };
    final ws = _activeWs;
    if (ws != null && ws.readyState == WebSocket.open) {
      ws.add(jsonEncode(payload));
    } else {
      await _mesh.sendRemoteControlCommand(peer, payload);
    }
    if (submit) {
      _remoteInputController.clear();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('已发送文字到「${peer.deviceName}」'),
        ),
      );
    }
  }

  Future<void> _refreshRemoteSharedFiles() async {
    final peer = selectedPeer;
    if (peer == null) return;
    setState(() => _loadingRemoteFiles = true);
    final files = await _mesh.fetchRemoteSharedFiles(peer);
    if (!mounted) return;
    setState(() {
      _remoteFiles = files;
      _loadingRemoteFiles = false;
    });
  }

  Future<void> _pickAndSendFilesToPeer({required bool mediaOnly}) async {
    final peer = selectedPeer;
    if (peer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择或添加一台目标客户端设备')),
      );
      return;
    }
    try {
      final res = await NativeUtilsChannelHub.channel.invokeMethod<dynamic>(
        'pickFiles',
        {'mediaOnly': mediaOnly},
      );
      if (res is List && res.isNotEmpty) {
        for (final item in res) {
          if (item is Map) {
            final name = (item['name'] ?? '传输文件').toString();
            final path = item['path']?.toString();
            final rawB = item['bytes'];
            final bytes =
                (rawB is Uint8List && rawB.isNotEmpty) ? rawB : null;
            if ((path != null && path.isNotEmpty) || bytes != null) {
              unawaited(
                _mesh.sendFileToPeer(
                  peer: peer,
                  fileName: name,
                  localFilePath: path,
                  rawBytes: bytes,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败：$e')),
        );
      }
    }
  }

  Future<void> _saveCurrentDesktopSnapshot() async {
    final bytes = _latestFrameBytes;
    final peer = selectedPeer;
    if (bytes == null || bytes.isEmpty) return;
    try {
      final dir = await _mesh.getPeerDownloadsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final safePeer = (peer?.deviceName ?? 'remote')
          .replaceAll(RegExp(r'[/\\:\s]'), '_');
      final file = File(
        '${dir.path}${Platform.pathSeparator}远程桌面截图_${safePeer}_$ts.jpg',
      );
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存远程桌面截图：${file.path}'),
          action: (!kIsWeb && Platform.isMacOS)
              ? SnackBarAction(
                  label: '在访达中查看',
                  onPressed: () {
                    NativeUtilsChannelHub.channel.invokeMethod(
                      'revealFileInFinder',
                      {'path': file.path},
                    );
                  },
                )
              : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存截图失败：$e')),
      );
    }
  }

  Future<void> _showAddPeerDialog() async {
    final ctrl = TextEditingController();
    final hostInput = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Row(
          children: [
            Icon(
              Icons.add_link_rounded,
              color: VideoPlatformTheme.accent,
              size: 20,
            ),
            const SizedBox(width: 8),
            const Text(
              '手动连接远程客户端',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '输入对方客户端显示的局域网 IP、Tailscale/ZeroTier 虚拟局域网 IP 或 IP:端口（默认端口 ${PeerMeshService.defaultHttpPort}）：',
                style: TextStyle(
                  fontSize: 12.5,
                  color: VideoPlatformTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
                decoration: const InputDecoration(
                  labelText: '对方设备 IP 或 IP:端口',
                  hintText: '例如 192.168.1.88 或 192.168.1.88:18190',
                  prefixIcon: Icon(Icons.lan_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            icon: const Icon(Icons.link_rounded, size: 16),
            label: const Text('立即连接'),
          ),
        ],
      ),
    );
    if (hostInput == null || hostInput.trim().isEmpty) return;
    final node = await _mesh.addManualPeer(hostInput);
    if (!mounted) return;
    if (node != null) {
      _selectPeer(node);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已成功连接「${node.deviceName} (${node.host}:${node.port})」！'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法连接到 $hostInput，请确认对方客户端已打开且网络互通'),
        ),
      );
    }
  }

  Future<void> _showRenameDeviceDialog() async {
    final ctrl = TextEditingController(text: _mesh.deviceName);
    final nextName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text(
          '修改本机显示名称',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
            decoration: const InputDecoration(
              labelText: '本机设备名称',
              hintText: '例如：书房 Mac mini / 客厅电视 / 我的 iPhone',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (nextName != null && nextName.trim().isNotEmpty) {
      await _mesh.setDeviceName(nextName);
    }
  }

  Future<void> _showWanPairingCodeDialog() async {
    final ctrl = TextEditingController(text: _mesh.pairingCode);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: Row(
                children: [
                  Icon(
                    Icons.public_rounded,
                    color: VideoPlatformTheme.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '跨网络云端互通设置（异地 / 4G/5G / 不同 Wi-Fi）',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '启用跨网络云端加密互通',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        _mesh.isWanConnected
                            ? '当前状态：已连通云端中继 (${_mesh.activeWanBroker})'
                            : (_mesh.wanEnabled
                                ? '当前状态：正在连接云端通道...'
                                : '当前状态：已关闭（仅局域网直连）'),
                        style: TextStyle(
                          fontSize: 12,
                          color: _mesh.isWanConnected
                              ? const Color(0xFF22C55E)
                              : VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      value: _mesh.wanEnabled,
                      onChanged: (v) async {
                        await _mesh.setWanEnabled(v);
                        setDialogState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '只要两台或多台客户端处于相同「跨网配对码」（默认根据您登录的流光服务端账号自动生成，无需手动配置），即使分别在手机 5G、家里 Wi-Fi、公司网络，也能自动发现彼此并进行远程桌面控制、互传文件与发送消息。所有跨网数据均采用 SHA-256 端到端加密。',
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textSecondary,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctrl,
                      decoration: const InputDecoration(
                        labelText: '跨网互联配对码（房间密钥）',
                        hintText: '例如：LG-888888 或自定义密码',
                        prefixIcon: Icon(Icons.vpn_key_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _mesh.resetPairingCodeToAccountDefault(
                      serverBaseUrl: widget.appState.serverConfig.baseUrl,
                      serverSecret: widget.appState.serverConfig.secret,
                    );
                    ctrl.text = _mesh.pairingCode;
                    setDialogState(() {});
                  },
                  child: const Text('恢复当前账号默认配对码'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    final code = ctrl.text.trim();
                    if (code.isNotEmpty) {
                      await _mesh.setPairingCode(code);
                    }
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop();
                    }
                  },
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('保存并重连'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showLocalQrDialog() async {
    final qrBytes = await TvLanInputService.generateQrPng(
      _mesh.localHttpUrl,
      size: 320,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Row(
          children: [
            Icon(
              Icons.qr_code_2_rounded,
              color: VideoPlatformTheme.accent,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '扫码远程控制本机 (${_mesh.deviceName})',
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (qrBytes != null && qrBytes.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.memory(
                  qrBytes,
                  width: 200,
                  height: 200,
                  fit: BoxFit.contain,
                ),
              ),
            const SizedBox(height: 12),
            SelectableText(
              _mesh.localHttpUrl,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: VideoPlatformTheme.accent,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '其它客户端可自动发现本机或手动输入上方 IP:端口；\n手机/电脑浏览器扫码也可直接打开网页端远程桌面与控制台。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: VideoPlatformTheme.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _mesh.localEndpoint));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已复制本机地址：${_mesh.localEndpoint}')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const Text('复制地址'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static IconData _platformIcon(String platform, {bool isTv = false}) {
    if (isTv) return Icons.tv_rounded;
    switch (platform.toLowerCase()) {
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'ios':
        return Icons.phone_iphone_rounded;
      case 'android':
        return Icons.phone_android_rounded;
      case 'windows':
        return Icons.desktop_windows_rounded;
      case 'linux':
        return Icons.computer_rounded;
      case 'tvos':
        return Icons.connected_tv_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isDesktopFullscreen) {
      return _buildFullscreenDesktopOverlay();
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= 900;

    return Scaffold(
      backgroundColor: VideoPlatformTheme.bgPrimary,
      body: Column(
        children: [
          _buildTopIdentityBar(isWide: isWide),
          if (!isWide) _buildMobilePeerHorizontalStrip(),
          Expanded(
            child: Row(
              children: [
                if (isWide)
                  SizedBox(
                    width: 280,
                    child: _buildDesktopPeersSidebar(),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      _buildWorkspaceTabBar(),
                      Expanded(
                        child: _buildActiveWorkspacePane(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopIdentityBar({required bool isWide}) {
    final onlineCount = _mesh.peers.where((p) => p.isOnline).length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: VideoPlatformTheme.accent.withValues(alpha: 0.4),
                  ),
                ),
                child: Icon(
                  Icons.hub_rounded,
                  size: 20,
                  color: VideoPlatformTheme.accent,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '本机：${_mesh.deviceName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: _showRenameDeviceDialog,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              Icons.edit_outlined,
                              size: 14,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '本机：${_mesh.localEndpoint} · 跨网配对码：${_mesh.pairingCode} (${_mesh.isWanConnected ? "跨网云端已连通" : (_mesh.wanEnabled ? "跨网连接中..." : "仅局域网")}) · 在线：$onlineCount 台',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ActionChip(
                avatar: Icon(
                  _mesh.isWanConnected
                      ? Icons.public_rounded
                      : Icons.vpn_key_rounded,
                  size: 15,
                  color: _mesh.isWanConnected
                      ? const Color(0xFF22C55E)
                      : VideoPlatformTheme.accent,
                ),
                label: Text(
                  '跨网配对码: ${_mesh.pairingCode}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: _showWanPairingCodeDialog,
              ),
              if (!kIsWeb &&
                  Platform.isMacOS &&
                  (!_macHasScreenCapture || !_macHasAccessibility))
                ActionChip(
                  avatar: const Icon(
                    Icons.security_rounded,
                    size: 15,
                    color: Color(0xFFF59E0B),
                  ),
                  label: const Text(
                    '授权系统桌面与键鼠控制',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () async {
                    final perms =
                        await _mesh.checkMacDesktopPermissions(prompt: true);
                    if (!mounted) return;
                    setState(() {
                      _macHasScreenCapture = perms['screenCapture'] == true;
                      _macHasAccessibility = perms['accessibility'] == true;
                    });
                  },
                ),
              FilterChip(
                selected: _mesh.allowRemoteControl,
                label: const Text(
                  '允许被控',
                  style: TextStyle(fontSize: 11.5),
                ),
                onSelected: (v) => _mesh.setAllowRemoteControl(v),
              ),
              if (_mesh.supportsNativeDesktopCapture)
                FilterChip(
                  selected: _mesh.allowDesktopCapture,
                  label: const Text(
                    '共享全桌面',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  onSelected: (v) => _mesh.setAllowDesktopCapture(v),
                ),
              OutlinedButton.icon(
                onPressed: _showLocalQrDialog,
                icon: const Icon(Icons.qr_code_rounded, size: 15),
                label: const Text('本机二维码', style: TextStyle(fontSize: 12)),
              ),
              OutlinedButton.icon(
                onPressed: _showAddPeerDialog,
                icon: const Icon(Icons.add_link_rounded, size: 15),
                label: const Text('添加设备 IP', style: TextStyle(fontSize: 12)),
              ),
              FilledButton.tonalIcon(
                onPressed: () async {
                  await _mesh.refreshDiscoveryNow();
                  if (selectedPeer != null) {
                    unawaited(_refreshRemoteSharedFiles());
                  }
                },
                icon: const Icon(Icons.radar_rounded, size: 15),
                label: const Text('扫描局域网', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobilePeerHorizontalStrip() {
    final peers = _mesh.peers;
    if (peers.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: VideoPlatformTheme.bgCard,
        child: Row(
          children: [
            Icon(
              Icons.wifi_find_rounded,
              size: 16,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在自动扫描同一局域网下的流光客户端，也可点击右上角「添加设备 IP」手动连接',
                style: TextStyle(
                  fontSize: 11.5,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: peers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, idx) {
          final p = peers[idx];
          final isSel = selectedPeer?.deviceId == p.deviceId;
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _selectPeer(p),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isSel
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                    : VideoPlatformTheme.bgElevated,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSel
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.borderSubtle,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: p.isOnline
                          ? const Color(0xFF22C55E)
                          : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _platformIcon(p.platform, isTv: p.isTv),
                    size: 15,
                    color: isSel
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    p.deviceName,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSel ? FontWeight.w800 : FontWeight.w600,
                      color: isSel
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDesktopPeersSidebar() {
    final peers = _mesh.peers;
    return Container(
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          right: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 8),
            child: Row(
              children: [
                Icon(
                  Icons.devices_other_rounded,
                  size: 16,
                  color: VideoPlatformTheme.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  '发现的客户端 (${peers.length})',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '手动添加设备 IP',
                  onPressed: _showAddPeerDialog,
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 17),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: peers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.radar_rounded,
                            size: 40,
                            color: VideoPlatformTheme.textMuted,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '暂未发现在线客户端',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '在同一局域网打开其它平台的「流光视频」即可自动发现；跨网段或 VPN 可点击「添加设备 IP」手动连接。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: VideoPlatformTheme.textSecondary,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: _showAddPeerDialog,
                            icon: const Icon(Icons.add_link_rounded, size: 15),
                            label: const Text('手动输入 IP 连接'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: peers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      final peer = peers[idx];
                      final isSel = selectedPeer?.deviceId == peer.deviceId;
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _selectPeer(peer),
                        child: Container(
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: isSel
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.15)
                                : VideoPlatformTheme.bgCard,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSel
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.borderSubtle,
                              width: isSel ? 1.6 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _platformIcon(
                                      peer.platform,
                                      isTv: peer.isTv,
                                    ),
                                    size: 18,
                                    color: isSel
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.textPrimary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      peer.deviceName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w800,
                                        color: VideoPlatformTheme.textPrimary,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: peer.isOnline
                                          ? const Color(0xFF22C55E)
                                              .withValues(alpha: 0.16)
                                          : Colors.grey.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      peer.isOnline ? '在线' : '离线',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: peer.isOnline
                                            ? const Color(0xFF22C55E)
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: peer.isLanReachable
                                          ? const Color(0xFF22C55E)
                                              .withValues(alpha: 0.14)
                                          : VideoPlatformTheme.accent
                                              .withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      peer.connectionModeLabel,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: peer.isLanReachable
                                            ? const Color(0xFF22C55E)
                                            : VideoPlatformTheme.accent,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '${peer.platformLabel} · ${peer.host}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: VideoPlatformTheme.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                peer.nowPlayingTitle.isNotEmpty
                                    ? '🎬 正在播放：${peer.nowPlayingTitle}'
                                    : '📍 当前页面：${peer.activeTabName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: peer.nowPlayingTitle.isNotEmpty
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textSecondary,
                                  fontWeight: peer.nowPlayingTitle.isNotEmpty
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkspaceTabBar() {
    final peer = selectedPeer;
    final tabs = const [
      (icon: Icons.desktop_windows_rounded, label: '显示桌面 & 远控画面'),
      (icon: Icons.gamepad_rounded, label: '遥控播控 & 投屏'),
      (icon: Icons.folder_shared_rounded, label: '传输文件 & 远端库'),
      (icon: Icons.forum_rounded, label: '发送消息 & 聊天'),
    ];

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          if (peer != null) ...[
            Icon(
              _platformIcon(peer.platform, isTv: peer.isTv),
              size: 16,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                peer.deviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(tabs.length, (idx) {
                  final item = tabs[idx];
                  final selected = _workspaceTabIndex == idx;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        setState(() => _workspaceTabIndex = idx);
                        if (idx == 0 &&
                            !_isStreamingDesktop &&
                            selectedPeer != null) {
                          _startDesktopStream();
                        } else if (idx != 0 && _isStreamingDesktop) {
                          _stopDesktopStream();
                        }
                        if (idx == 2 && selectedPeer != null) {
                          unawaited(_refreshRemoteSharedFiles());
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.bgElevated,
                          borderRadius: BorderRadius.circular(18),
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
                              item.icon,
                              size: 15,
                              color: selected
                                  ? Colors.black
                                  : VideoPlatformTheme.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              item.label,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: selected
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: selected
                                    ? Colors.black
                                    : VideoPlatformTheme.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveWorkspacePane() {
    switch (_workspaceTabIndex) {
      case 0:
        return _buildRemoteDesktopPane();
      case 1:
        return _buildRemoteControlPadPane();
      case 2:
        return _buildFileTransferPane();
      case 3:
        return _buildChatMessagingPane();
      default:
        return _buildRemoteDesktopPane();
    }
  }

  // ===========================================================================
  // Tab 0: Remote Desktop & Screen Viewer (`显示桌面`)
  // ===========================================================================

  Widget _buildRemoteDesktopPane() {
    final peer = selectedPeer;
    if (peer == null) {
      return _buildNoPeerSelectedPlaceholder(
        title: '选择或添加一台客户端以查看远程桌面',
        subtitle:
            '支持实时查看 macOS / Windows / Linux 系统全桌面，或查看 iOS / Android / 电视端的应用实时画面，并直接通过鼠标点击、拖拽、滚轮和键盘远程操控。',
      );
    }

    return Column(
      children: [
        // Top desktop stream controls toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgElevated,
            border: Border(
              bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _isStreamingDesktop
                          ? const Color(0xFFEF4444)
                          : VideoPlatformTheme.accent,
                      foregroundColor:
                          _isStreamingDesktop ? Colors.white : Colors.black,
                    ),
                    onPressed: () {
                      if (_isStreamingDesktop) {
                        _stopDesktopStream();
                      } else {
                        _startDesktopStream();
                      }
                    },
                    icon: Icon(
                      _isStreamingDesktop
                          ? Icons.stop_circle_outlined
                          : Icons.play_arrow_rounded,
                      size: 17,
                    ),
                    label: Text(
                      _isStreamingDesktop ? '停止画面同步' : '开启实时桌面',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Capture mode selector
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'auto',
                        label: Text('自动', style: TextStyle(fontSize: 11.5)),
                      ),
                      ButtonSegment(
                        value: 'desktop',
                        label: Text('系统全桌面', style: TextStyle(fontSize: 11.5)),
                      ),
                      ButtonSegment(
                        value: 'app',
                        label: Text('应用画面', style: TextStyle(fontSize: 11.5)),
                      ),
                    ],
                    selected: {_captureMode},
                    onSelectionChanged: (sel) {
                      setState(() => _captureMode = sel.first);
                      _updateStreamParams();
                    },
                  ),
                  // Pointer click mode selector
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'tap',
                        label: Text('左键/单击', style: TextStyle(fontSize: 11.5)),
                      ),
                      ButtonSegment(
                        value: 'double_tap',
                        label: Text('双击', style: TextStyle(fontSize: 11.5)),
                      ),
                      ButtonSegment(
                        value: 'right_click',
                        label: Text('右键', style: TextStyle(fontSize: 11.5)),
                      ),
                      ButtonSegment(
                        value: 'drag',
                        label: Text('拖拽/滑动', style: TextStyle(fontSize: 11.5)),
                      ),
                    ],
                    selected: {_pointerTool},
                    onSelectionChanged: (sel) {
                      setState(() => _pointerTool = sel.first);
                    },
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: _streamFps,
                      isDense: true,
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(value: 2, child: Text('2 FPS (省流)')),
                        DropdownMenuItem(value: 5, child: Text('5 FPS (均衡)')),
                        DropdownMenuItem(value: 10, child: Text('10 FPS (流畅)')),
                        DropdownMenuItem(value: 15, child: Text('15 FPS (极速)')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _streamFps = v);
                        _updateStreamParams();
                      },
                    ),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: _streamMaxWidth,
                      isDense: true,
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(value: 960, child: Text('标清 960P')),
                        DropdownMenuItem(value: 1280, child: Text('高清 1280P')),
                        DropdownMenuItem(value: 1920, child: Text('超清 1920P')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _streamMaxWidth = v);
                        _updateStreamParams();
                      },
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '保存当前远程桌面截图',
                    onPressed: _latestFrameBytes != null
                        ? _saveCurrentDesktopSnapshot
                        : null,
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '全屏显示远程桌面',
                    onPressed: () {
                      setState(() => _isDesktopFullscreen = true);
                    },
                    icon: const Icon(Icons.fullscreen_rounded, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Interactive Remote Desktop Canvas
        Expanded(
          child: Container(
            width: double.infinity,
            color: const Color(0xFF050608),
            child: _buildInteractiveDesktopViewport(peer),
          ),
        ),

        // Bottom Remote Keyboard & Quick Key Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgElevated,
            border: Border(
              top: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildQuickKeyChip('Esc / 返回', 'back', Icons.keyboard_return_rounded),
                    _buildQuickKeyChip('确定 Enter', 'enter', Icons.check_circle_outline_rounded),
                    _buildQuickKeyChip('播放/暂停 Space', 'space', Icons.play_circle_outline_rounded),
                    _buildQuickKeyChip('上 ⬆️', 'up', Icons.keyboard_arrow_up_rounded),
                    _buildQuickKeyChip('下 ⬇️', 'down', Icons.keyboard_arrow_down_rounded),
                    _buildQuickKeyChip('左 ⬅️', 'left', Icons.keyboard_arrow_left_rounded),
                    _buildQuickKeyChip('右 ➡️', 'right', Icons.keyboard_arrow_right_rounded),
                    _buildQuickKeyChip('退格 ⌫', 'backspace', Icons.backspace_outlined),
                    _buildQuickKeyChip('主界面', 'home', Icons.home_outlined),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _remoteInputController,
                        onSubmitted: (_) => _sendRemoteText(submit: true),
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: '在此输入文字，一键填入对方正在输入的文本框或远程键盘...',
                          prefixIcon: Icon(Icons.keyboard_alt_outlined, size: 17),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _sendRemoteText(submit: false),
                    child: const Text('仅填入', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    onPressed: () => _sendRemoteText(submit: true),
                    icon: const Icon(Icons.send_rounded, size: 14),
                    label: const Text('填入并回车', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuickKeyChip(String label, String keyName, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(icon, size: 14, color: VideoPlatformTheme.accent),
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        onPressed: () => _sendRemoteKey(keyName),
      ),
    );
  }

  Widget _buildInteractiveDesktopViewport(PeerDeviceNode peer) {
    if (_latestFrameBytes == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.desktop_windows_rounded,
                size: 54,
                color: VideoPlatformTheme.accent.withValues(alpha: 0.7),
              ),
              const SizedBox(height: 14),
              Text(
                _isStreamingDesktop
                    ? (_desktopError ?? '正在连接「${peer.deviceName}」的实时远程画面...')
                    : '点击上方「开启实时桌面」查看并操控「${peer.deviceName}」',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '支持系统级全桌面显示（macOS）与应用内实时画面（全平台 iOS / Android / TV / 桌面），画面内直接点击、拖拽、滚轮即可远程操控对方设备。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              if (!_isStreamingDesktop)
                FilledButton.icon(
                  onPressed: _startDesktopStream,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('立即开启远程桌面画面'),
                ),
            ],
          ),
        ),
      );
    }

    final aspect = (_remoteScreenWidth > 0 && _remoteScreenHeight > 0)
        ? (_remoteScreenWidth / _remoteScreenHeight)
        : (16.0 / 9.0);

    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            final boxW = constraints.maxWidth;
            final boxH = constraints.maxHeight;

            Offset normalizeOffset(Offset local) {
              return Offset(
                (local.dx / (boxW > 0 ? boxW : 1)).clamp(0.0, 1.0),
                (local.dy / (boxH > 0 ? boxH : 1)).clamp(0.0, 1.0),
              );
            }

            return Listener(
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  final norm = normalizeOffset(signal.localPosition);
                  _sendRemotePointer(
                    type: 'scroll',
                    nx: norm.dx,
                    ny: norm.dy,
                    deltaX: -signal.scrollDelta.dx,
                    deltaY: -signal.scrollDelta.dy,
                  );
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final norm = normalizeOffset(details.localPosition);
                  final effectiveType =
                      _pointerTool == 'drag' ? 'tap' : _pointerTool;
                  _sendRemotePointer(
                    type: effectiveType,
                    nx: norm.dx,
                    ny: norm.dy,
                  );
                },
                onSecondaryTapUp: (details) {
                  final norm = normalizeOffset(details.localPosition);
                  _sendRemotePointer(
                    type: 'right_click',
                    nx: norm.dx,
                    ny: norm.dy,
                  );
                },
                onDoubleTapDown: (details) {
                  final norm = normalizeOffset(details.localPosition);
                  _sendRemotePointer(
                    type: 'double_tap',
                    nx: norm.dx,
                    ny: norm.dy,
                  );
                },
                onPanStart: (details) {
                  final norm = normalizeOffset(details.localPosition);
                  _sendRemotePointer(
                    type: 'down',
                    nx: norm.dx,
                    ny: norm.dy,
                  );
                },
                onPanUpdate: (details) {
                  final norm = normalizeOffset(details.localPosition);
                  _sendRemotePointer(
                    type: 'drag',
                    nx: norm.dx,
                    ny: norm.dy,
                    deltaX: details.delta.dx,
                    deltaY: details.delta.dy,
                  );
                },
                onPanEnd: (_) {
                  final last = _lastTapNormalized ?? const Offset(0.5, 0.5);
                  _sendRemotePointer(
                    type: 'up',
                    nx: last.dx,
                    ny: last.dy,
                  );
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      _latestFrameBytes!,
                      gaplessPlayback: true,
                      fit: BoxFit.fill,
                    ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Text(
                          '${peer.deviceName} · ${_activeRemoteMode == 'desktop' ? '系统全桌面' : '应用内画面'} (${_remoteScreenWidth}x$_remoteScreenHeight)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    if (_lastTapNormalized != null)
                      Positioned(
                        left: (_lastTapNormalized!.dx * boxW) - 10,
                        top: (_lastTapNormalized!.dy * boxH) - 10,
                        child: IgnorePointer(
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.35),
                              border: Border.all(
                                color: Colors.white,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFullscreenDesktopOverlay() {
    final peer = selectedPeer;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (peer != null) _buildInteractiveDesktopViewport(peer),
            Positioned(
              right: 16,
              top: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _sendRemoteKey('back'),
                    icon: const Icon(Icons.arrow_back_rounded, size: 16),
                    label: const Text('远程返回'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() => _isDesktopFullscreen = false);
                    },
                    icon: const Icon(Icons.fullscreen_exit_rounded, size: 18),
                    label: const Text('退出全屏'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // Tab 1: Remote Control Pad & Media Casting (`远程控制`)
  // ===========================================================================

  Widget _buildRemoteControlPadPane() {
    final peer = selectedPeer;
    if (peer == null) {
      return _buildNoPeerSelectedPlaceholder(
        title: '选择一台客户端进行远程遥控与投屏',
        subtitle:
            '可远程切换对方客户端的导航标签页、模拟遥控器方向键/确定/返回、同步双方剪贴板，或将当前视频/直播流一键推送到对方客户端播放。',
      );
    }

    final currentMini = widget.appState.miniPlayerSession;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          // 1. Virtual D-Pad Remote Controller Card
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 300, maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.gamepad_rounded,
                        color: VideoPlatformTheme.accent,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '虚拟遥控器 (${peer.deviceName})',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Top row: Back, Home, Menu/PlayPause
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildRemotePadButton(
                        icon: Icons.arrow_back_rounded,
                        label: '返回',
                        onTap: () => _sendRemoteKey('back'),
                      ),
                      _buildRemotePadButton(
                        icon: Icons.home_rounded,
                        label: '首页',
                        onTap: () => _sendRemoteKey('home'),
                      ),
                      _buildRemotePadButton(
                        icon: Icons.play_arrow_rounded,
                        label: '播放/暂停',
                        onTap: () => _sendRemoteKey('space'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  // D-Pad Cross
                  SizedBox(
                    width: 210,
                    height: 210,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned(
                          top: 0,
                          child: _buildDpadDirButton(
                            Icons.keyboard_arrow_up_rounded,
                            () => _sendRemoteKey('up'),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          child: _buildDpadDirButton(
                            Icons.keyboard_arrow_down_rounded,
                            () => _sendRemoteKey('down'),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          child: _buildDpadDirButton(
                            Icons.keyboard_arrow_left_rounded,
                            () => _sendRemoteKey('left'),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          child: _buildDpadDirButton(
                            Icons.keyboard_arrow_right_rounded,
                            () => _sendRemoteKey('right'),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(40),
                          onTap: () => _sendRemoteKey('enter'),
                          child: Container(
                            width: 74,
                            height: 74,
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.accent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: VideoPlatformTheme.accent
                                      .withValues(alpha: 0.4),
                                  blurRadius: 14,
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'OK',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Media control row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildRemotePadButton(
                        icon: Icons.replay_10_rounded,
                        label: '快退',
                        onTap: () => _mesh.sendRemoteControlCommand(peer, {
                          'action': 'media_command',
                          'cmd': 'seek_backward',
                        }),
                      ),
                      _buildRemotePadButton(
                        icon: Icons.forward_10_rounded,
                        label: '快进',
                        onTap: () => _mesh.sendRemoteControlCommand(peer, {
                          'action': 'media_command',
                          'cmd': 'seek_forward',
                        }),
                      ),
                      _buildRemotePadButton(
                        icon: Icons.stop_rounded,
                        label: '关闭播放',
                        onTap: () => _mesh.sendRemoteControlCommand(peer, {
                          'action': 'media_command',
                          'cmd': 'stop',
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 2. Remote Page Navigation & Media Push / Clipboard Sync Card
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 320, maxWidth: 540),
            child: Column(
              children: [
                // Remote Tab Switcher
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: VideoPlatformTheme.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.tab_rounded,
                            color: VideoPlatformTheme.accent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '远程切换对方客户端页面',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in const [
                            (idx: 0, label: '影视片库', icon: Icons.home_filled),
                            (idx: 1, label: '电视直播', icon: Icons.live_tv_rounded),
                            (idx: 3, label: '视频资料库', icon: Icons.folder_copy_outlined),
                            (idx: 5, label: 'Telegram', icon: Icons.send_rounded),
                            (idx: 9, label: '流光音乐', icon: Icons.album_rounded),
                            (idx: 2, label: '下载工作台', icon: Icons.downloading_rounded),
                            (idx: 4, label: '历史与收藏', icon: Icons.bookmarks_outlined),
                            (idx: 6, label: '代理服务器', icon: Icons.bolt_rounded),
                            (idx: 8, label: '偏好设置', icon: Icons.settings_outlined),
                          ])
                            ActionChip(
                              avatar: Icon(
                                entry.icon,
                                size: 15,
                                color: VideoPlatformTheme.accent,
                              ),
                              label: Text(
                                entry.label,
                                style: const TextStyle(fontSize: 12),
                              ),
                              onPressed: () async {
                                await _mesh.sendRemoteControlCommand(peer, {
                                  'action': 'switch_tab',
                                  'tabIndex': entry.idx,
                                });
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(seconds: 2),
                                    content: Text(
                                      '已将「${peer.deviceName}」切换到「${entry.label}」',
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // One-Click Video / Stream Push (Cast to Peer)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: VideoPlatformTheme.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.cast_connected_rounded,
                            color: VideoPlatformTheme.accent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '一键投屏 / 推送视频到对方客户端播放',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      if (currentMini != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.bgCard,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.play_circle_fill_rounded,
                                color: VideoPlatformTheme.accent,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '本机当前播放：${currentMini.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              FilledButton.icon(
                                onPressed: () async {
                                  await _mesh.sendRemoteControlCommand(peer, {
                                    'action': 'cast_media',
                                    'url': currentMini.streamUrl,
                                    'title': currentMini.title,
                                    'headers': currentMini.headers,
                                    'positionSec':
                                        currentMini.initialPositionSeconds,
                                  });
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已推送「${currentMini.title}」到「${peer.deviceName}」播放',
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.cast_rounded, size: 15),
                                label: const Text('推送播放'),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: _castTitleController,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: '视频标题（选填）',
                          hintText: '例如：电影 / 直播频道名称',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _castUrlController,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: '视频流地址 (M3U8 / MP4 / HTTP 直链)',
                                hintText: 'https://.../index.m3u8',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () async {
                              final url = _castUrlController.text.trim();
                              if (url.isEmpty) return;
                              final title = _castTitleController.text
                                      .trim()
                                      .isNotEmpty
                                  ? _castTitleController.text.trim()
                                  : '远程投屏视频';
                              await _mesh.sendRemoteControlCommand(peer, {
                                'action': 'cast_media',
                                'url': url,
                                'title': title,
                              });
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '已推送视频链接到「${peer.deviceName}」开始播放',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.send_to_mobile_rounded, size: 16),
                            label: const Text('投屏播放'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Remote Clipboard Sync
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: VideoPlatformTheme.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.content_paste_go_rounded,
                            color: VideoPlatformTheme.accent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '跨客户端剪贴板同步',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              final data = await Clipboard.getData(
                                Clipboard.kTextPlain,
                              );
                              final text = data?.text ?? '';
                              if (text.isEmpty) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('本机剪贴板为空')),
                                );
                                return;
                              }
                              await _mesh.sendRemoteControlCommand(peer, {
                                'action': 'set_clipboard',
                                'text': text,
                              });
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '已将本机剪贴板发送到「${peer.deviceName}」',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.upload_rounded, size: 16),
                            label: const Text('发送本机剪贴板到对方'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final remoteText =
                                  await _mesh.fetchRemoteClipboardText(peer);
                              if (!mounted) return;
                              if (remoteText == null || remoteText.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('对方剪贴板为空或未开启权限'),
                                  ),
                                );
                                return;
                              }
                              await Clipboard.setData(
                                ClipboardData(text: remoteText),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '已读取「${peer.deviceName}」的剪贴板并复制到本机：${remoteText.length > 40 ? '${remoteText.substring(0, 40)}...' : remoteText}',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.download_rounded, size: 16),
                            label: const Text('读取对方剪贴板到本机'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemotePadButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VideoPlatformTheme.borderSubtle),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: VideoPlatformTheme.textPrimary),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: VideoPlatformTheme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDpadDirButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: VideoPlatformTheme.bgCard,
          shape: BoxShape.circle,
          border: Border.all(color: VideoPlatformTheme.borderStrong),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 28, color: VideoPlatformTheme.textPrimary),
      ),
    );
  }

  // ===========================================================================
  // Tab 2: File Transfer & Remote Shared Files (`传输文件`)
  // ===========================================================================

  Widget _buildFileTransferPane() {
    final peer = selectedPeer;
    final transfers = _mesh.transfers;

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top action bar
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _isDraggingFiles
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                  : VideoPlatformTheme.bgElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isDraggingFiles
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.borderSubtle,
                width: _isDraggingFiles ? 2 : 1,
              ),
            ),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer != null
                          ? '向「${peer.deviceName}」高速直连传文件（支持直接拖拽文件到窗口）'
                          : '请先在左侧选择目标客户端设备',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '本机接收目录：$_localSaveDirPath',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.icon(
                      onPressed: peer == null
                          ? null
                          : () => _pickAndSendFilesToPeer(mediaOnly: false),
                      icon: const Icon(Icons.upload_file_rounded, size: 16),
                      label: const Text('选择文件发送'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: peer == null
                          ? null
                          : () => _pickAndSendFilesToPeer(mediaOnly: true),
                      icon: const Icon(Icons.perm_media_rounded, size: 16),
                      label: const Text('发送视频/图片'),
                    ),
                    if (!kIsWeb && Platform.isMacOS && _localSaveDirPath.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () {
                          NativeUtilsChannelHub.channel.invokeMethod(
                            'revealFileInFinder',
                            {'path': _localSaveDirPath},
                          );
                        },
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('打开接收文件夹'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Transfer Queue (Active & Completed)
                Expanded(
                  flex: 5,
                  child: Container(
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgElevated,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: VideoPlatformTheme.borderSubtle,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Icon(
                                Icons.swap_vert_circle_outlined,
                                size: 18,
                                color: VideoPlatformTheme.accent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '文件传输队列 (${transfers.length})',
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: transfers.isEmpty
                              ? Center(
                                  child: Text(
                                    '暂无文件传输记录\n支持大文件局域网满速直传',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: VideoPlatformTheme.textMuted,
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.all(10),
                                  itemCount: transfers.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (_, idx) {
                                    final t = transfers[idx];
                                    final pct = (t.progress * 100)
                                        .toStringAsFixed(1);
                                    return Container(
                                      padding: const EdgeInsets.all(11),
                                      decoration: BoxDecoration(
                                        color: VideoPlatformTheme.bgCard,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: VideoPlatformTheme.borderSubtle,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                t.isUpload
                                                    ? Icons.arrow_upward_rounded
                                                    : Icons.arrow_downward_rounded,
                                                size: 16,
                                                color: t.status == 'failed'
                                                    ? const Color(0xFFEF4444)
                                                    : VideoPlatformTheme.accent,
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  '[${t.isUpload ? '发送' : '接收'}] ${t.fileName}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                t.status == 'transferring'
                                                    ? '$pct% · ${_formatBytes(t.speedBytesPerSec.round())}/s'
                                                    : (t.status == 'completed'
                                                        ? '已完成'
                                                        : '失败'),
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: t.status == 'completed'
                                                      ? const Color(0xFF22C55E)
                                                      : (t.status == 'failed'
                                                          ? const Color(0xFFEF4444)
                                                          : VideoPlatformTheme.accent),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          LinearProgressIndicator(
                                            value: t.progress,
                                            minHeight: 5,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '${t.isUpload ? '目标' : '来源'}：${t.peerName} · ${_formatBytes(t.transferredBytes)} / ${_formatBytes(t.totalBytes)}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: VideoPlatformTheme
                                                        .textSecondary,
                                                  ),
                                                ),
                                              ),
                                              if (t.status == 'transferring')
                                                TextButton(
                                                  onPressed: () {
                                                    setState(() {
                                                      t.isCancelled = true;
                                                    });
                                                  },
                                                  child: const Text(
                                                    '取消',
                                                    style:
                                                        TextStyle(fontSize: 11),
                                                  ),
                                                ),
                                              if (t.status == 'completed' &&
                                                  t.savedPath.isNotEmpty) ...[
                                                if (!kIsWeb &&
                                                    Platform.isMacOS)
                                                  TextButton(
                                                    onPressed: () {
                                                      NativeUtilsChannelHub
                                                          .channel
                                                          .invokeMethod(
                                                        'revealFileInFinder',
                                                        {'path': t.savedPath},
                                                      );
                                                    },
                                                    child: const Text(
                                                      '在访达中显示',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Right: Remote Peer Shared Files Browser (`拉取与直接播放远端文件`)
                Expanded(
                  flex: 5,
                  child: Container(
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgElevated,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: VideoPlatformTheme.borderSubtle,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.cloud_download_outlined,
                                size: 18,
                                color: VideoPlatformTheme.accent,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  peer != null
                                      ? '「${peer.deviceName}」共享文件 (${_remoteFiles.length})'
                                      : '远端共享文件库',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: '刷新远端共享文件',
                                onPressed: peer == null
                                    ? null
                                    : _refreshRemoteSharedFiles,
                                icon: const Icon(Icons.refresh_rounded, size: 17),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: _loadingRemoteFiles
                              ? const Center(child: CircularProgressIndicator())
                              : (_remoteFiles.isEmpty
                                  ? Center(
                                      child: Text(
                                        peer == null
                                            ? '请先选择一台客户端'
                                            : '对方「流光互联接收」目录暂无文件',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: VideoPlatformTheme.textMuted,
                                        ),
                                      ),
                                    )
                                  : ListView.separated(
                                      padding: const EdgeInsets.all(10),
                                      itemCount: _remoteFiles.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 6),
                                      itemBuilder: (_, idx) {
                                        final item = _remoteFiles[idx];
                                        return Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: VideoPlatformTheme.bgCard,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                              color: VideoPlatformTheme
                                                  .borderSubtle,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                item.isVideo
                                                    ? Icons.movie_creation_outlined
                                                    : (item.isAudio
                                                        ? Icons.music_note_rounded
                                                        : Icons.insert_drive_file_outlined),
                                                size: 18,
                                                color: VideoPlatformTheme.accent,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      item.name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    Text(
                                                      _formatBytes(item.size),
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: VideoPlatformTheme
                                                            .textMuted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (item.isVideo || item.isAudio)
                                                IconButton(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  tooltip: '直接串流播放该远端文件',
                                                  onPressed: () {
                                                    if (peer == null) return;
                                                    final url = _mesh
                                                        .buildRemoteFileStreamUrl(
                                                      peer,
                                                      item,
                                                    );
                                                    widget.appState
                                                        .startMiniPlayer(
                                                      MiniPlayerSession(
                                                        title: item.name,
                                                        subtitle:
                                                            '来自 ${peer.deviceName}',
                                                        streamUrl: url,
                                                      ),
                                                    );
                                                  },
                                                  icon: Icon(
                                                    Icons.play_circle_fill_rounded,
                                                    color: VideoPlatformTheme
                                                        .accent,
                                                    size: 20,
                                                  ),
                                                ),
                                              IconButton(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                tooltip: '下载到本机',
                                                onPressed: () {
                                                  if (peer == null) return;
                                                  unawaited(
                                                    _mesh.downloadFileFromPeer(
                                                      peer: peer,
                                                      item: item,
                                                    ),
                                                  );
                                                },
                                                icon: const Icon(
                                                  Icons.download_rounded,
                                                  size: 18,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    )),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Tab 3: Instant Messaging & Chat (`发送消息`)
  // ===========================================================================

  Widget _buildChatMessagingPane() {
    final peer = selectedPeer;
    final allMessages = _mesh.messages;

    return Column(
      children: [
        // Top chat target banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgElevated,
            border: Border(
              bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 16,
                color: VideoPlatformTheme.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  peer != null
                      ? '当前对话：${peer.deviceName} (${peer.host}:${peer.port}) · 支持发送文字、链接、剪贴板与文件'
                      : '局域网广播消息（发送给所有在线客户端）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _mesh.messages.isEmpty
                    ? null
                    : () => _mesh.clearChatHistory(),
                icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                label: const Text('清空记录', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ),

        // Chat message history list
        Expanded(
          child: allMessages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.forum_outlined,
                        size: 46,
                        color: VideoPlatformTheme.textMuted,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '暂无互联消息',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '在下方输入文字、视频链接或点击发送文件，对方客户端将实时收到弹窗通知。',
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.all(14),
                  itemCount: allMessages.length,
                  itemBuilder: (_, idx) {
                    final msg = allMessages[idx];
                    return _buildChatMessageBubble(msg);
                  },
                ),
        ),

        // Bottom Compose Bar
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgElevated,
            border: Border(
              top: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: '发送文件附件',
                onPressed: peer == null
                    ? null
                    : () => _pickAndSendFilesToPeer(mediaOnly: false),
                icon: const Icon(Icons.attach_file_rounded, size: 20),
              ),
              IconButton(
                tooltip: '一键发送本机剪贴板内容',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final clip = data?.text?.trim() ?? '';
                  if (clip.isEmpty) return;
                  await _mesh.sendChatMessage(
                    targetPeer: peer,
                    text: clip,
                    type: 'clipboard',
                  );
                },
                icon: const Icon(Icons.content_paste_rounded, size: 19),
              ),
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _chatInputController,
                    onSubmitted: (_) => _submitChatMessage(peer),
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: peer != null
                          ? '发送消息给「${peer.deviceName}」...'
                          : '发送局域网广播消息...',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _submitChatMessage(peer),
                icon: const Icon(Icons.send_rounded, size: 15),
                label: const Text('发送'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _submitChatMessage(PeerDeviceNode? peer) async {
    final text = _chatInputController.text.trim();
    if (text.isEmpty) return;
    _chatInputController.clear();
    await _mesh.sendChatMessage(
      targetPeer: peer,
      text: text,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildChatMessageBubble(PeerChatMessage msg) {
    final isMe = msg.isOutgoing;
    final timeStr =
        '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}:${msg.timestamp.second.toString().padLeft(2, '0')}';
    final hasHttpLink = RegExp(r'https?://\S+').hasMatch(msg.text);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: isMe
              ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isMe
                ? VideoPlatformTheme.accent.withValues(alpha: 0.45)
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isMe ? '我 (${msg.senderName})' : msg.senderName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            SelectableText(
              msg.text,
              style: TextStyle(
                fontSize: 13.5,
                color: VideoPlatformTheme.textPrimary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: msg.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        duration: Duration(seconds: 1),
                        content: Text('已复制消息内容'),
                      ),
                    );
                  },
                  child: Text(
                    '复制内容',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ),
                if (hasHttpLink)
                  InkWell(
                    onTap: () {
                      final m =
                          RegExp(r'https?://\S+').firstMatch(msg.text);
                      final url = m?.group(0) ?? '';
                      if (url.isNotEmpty) {
                        widget.appState.startMiniPlayer(
                          MiniPlayerSession(
                            title: '互联消息视频',
                            subtitle: '来自 ${msg.senderName}',
                            streamUrl: url,
                          ),
                        );
                      }
                    },
                    child: Text(
                      '▶️ 用播放器打开链接',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
                if (msg.localFilePath.isNotEmpty &&
                    !kIsWeb &&
                    Platform.isMacOS)
                  InkWell(
                    onTap: () {
                      NativeUtilsChannelHub.channel.invokeMethod(
                        'revealFileInFinder',
                        {'path': msg.localFilePath},
                      );
                    },
                    child: Text(
                      '📂 在访达中显示',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoPeerSelectedPlaceholder({
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.devices_rounded,
                size: 52,
                color: VideoPlatformTheme.accent.withValues(alpha: 0.75),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: VideoPlatformTheme.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _showAddPeerDialog,
                    icon: const Icon(Icons.add_link_rounded, size: 16),
                    label: const Text('手动输入设备 IP 连接'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _mesh.refreshDiscoveryNow,
                    icon: const Icon(Icons.radar_rounded, size: 16),
                    label: const Text('重新扫描局域网'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
