import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  final AppState appState;

  const SettingsScreen({
    super.key,
    required this.appState,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _secretCtrl;
  late AuthMode _authMode;
  late bool _preferDirectPlayback;
  bool _obscureSecret = true;
  bool _isSavingConnection = false;

  // Editable backend settings
  final TextEditingController _mountPathCtrl = TextEditingController();
  final TextEditingController _fileRootCtrl = TextEditingController();
  final TextEditingController _maxTasksCtrl = TextEditingController(text: '3');
  final TextEditingController _maxWorkersCtrl =
      TextEditingController(text: '16');
  final TextEditingController _elevenDirIdCtrl =
      TextEditingController(text: '0');
  bool _autoMove = false;
  bool _convertToMp4 = true;
  bool _vodBackendProxy = false;
  bool _disable115Api = false;
  bool _isSavingServerSettings = false;

  // 115 Cloud Drive state
  bool _is115LoggedIn = false;
  String _user115Info = '未登录';
  final TextEditingController _cookie115Ctrl = TextEditingController();
  bool _isBusy115 = false;

  final ScrollController _settingsScrollController = ScrollController();
  final Map<String, FocusNode> _themeCardFocusNodes = {
    for (final p in VideoPlatformTheme.presets)
      p.id: FocusNode(debugLabel: 'ThemeCard_${p.id}'),
  };

  @override
  void initState() {
    super.initState();
    final cfg = widget.appState.serverConfig;
    _baseUrlCtrl = TextEditingController(text: cfg.baseUrl);
    _secretCtrl = TextEditingController(text: cfg.secret);
    _authMode = cfg.authMode;
    _preferDirectPlayback = cfg.preferDirectPlayback;
    widget.appState.activeChildDownFromHeaderHandler = _focusActiveThemeCard;
    _loadBackendSettingsAnd115();
  }

  bool _focusActiveThemeCard() {
    if (!mounted) return false;
    if (_settingsScrollController.hasClients) {
      _settingsScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    }
    final activeId = widget.appState.themeId;
    final targetNode =
        _themeCardFocusNodes[activeId] ?? _themeCardFocusNodes.values.first;
    targetNode.requestFocus();
    return true;
  }

  @override
  void dispose() {
    if (widget.appState.activeChildDownFromHeaderHandler ==
        _focusActiveThemeCard) {
      widget.appState.activeChildDownFromHeaderHandler = null;
    }
    for (final node in _themeCardFocusNodes.values) {
      node.dispose();
    }
    _settingsScrollController.dispose();
    _baseUrlCtrl.dispose();
    _secretCtrl.dispose();
    _mountPathCtrl.dispose();
    _fileRootCtrl.dispose();
    _maxTasksCtrl.dispose();
    _maxWorkersCtrl.dispose();
    _elevenDirIdCtrl.dispose();
    _cookie115Ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadBackendSettingsAnd115() async {
    await widget.appState.refreshServerSettings();
    final srv = widget.appState.serverSettings;
    if (srv != null && mounted) {
      setState(() {
        _mountPathCtrl.text = srv.mountPath;
        _fileRootCtrl.text = srv.fileManagerRoot;
        _maxTasksCtrl.text = srv.maxConcurrentTasks.toString();
        _maxWorkersCtrl.text = srv.maxSegmentWorkers.toString();
        _elevenDirIdCtrl.text = srv.elevenDirId;
        _autoMove = srv.autoMove;
        _convertToMp4 = srv.convertToMp4;
        _vodBackendProxy = srv.vodBackendProxyPlayback;
        _disable115Api = srv.disable115Api;
      });
    }
    try {
      final st115 = await widget.appState.api.fetch115Status();
      if (mounted) {
        setState(() {
          _is115LoggedIn = st115['logged_in'] == true;
          _user115Info = (st115['user_name'] ??
                  st115['user_id'] ??
                  (_is115LoggedIn ? '已登录 115 网盘' : '未登录'))
              .toString();
        });
      }
    } catch (_) {}
  }

  Future<void> _show115QrCodeDialog() async {
    Uint8List? qrImageBytes;
    String statusText = '正在请求 115 登录二维码...';
    Timer? pollTimer;
    bool isLoading = true;

    Future<void> startQrFlow(
      StateSetter setDialogState,
      VoidCallback onSuccessClose,
    ) async {
      pollTimer?.cancel();
      setDialogState(() {
        isLoading = true;
        statusText = '正在获取 115 二维码...';
      });
      try {
        final data = await widget.appState.api.fetch115QrCode();
        final b64 = (data['image'] ?? '').toString().trim();
        final token = (data['token'] ?? '').toString().trim();
        if (b64.isEmpty || token.isEmpty) {
          setDialogState(() {
            isLoading = false;
            statusText = '未能获取到有效二维码数据';
          });
          return;
        }
        final cleanB64 = b64.contains(',') ? b64.split(',').last : b64;
        qrImageBytes = base64Decode(cleanB64);
        setDialogState(() {
          isLoading = false;
          statusText = '请使用手机 115 网盘 App 扫描二维码并确认登录';
        });

        pollTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
          try {
            final res = await widget.appState.api.check115QrCode(token);
            final status = int.tryParse((res['status'] ?? 0).toString()) ?? 0;
            if (status == 1 || res['logged_in'] == true) {
              t.cancel();
              onSuccessClose();
            }
          } catch (_) {}
        });
      } catch (e) {
        setDialogState(() {
          isLoading = false;
          statusText = '获取二维码失败：$e';
        });
      }
    }

    bool initialized = false;
    final loggedIn = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void closeSuccess() {
            if (ctx.mounted) {
              Navigator.of(ctx).pop(true);
            }
          }

          if (!initialized) {
            initialized = true;
            Future.microtask(() => startQrFlow(setDialogState, closeSuccess));
          }
          return AlertDialog(
            backgroundColor: VideoPlatformTheme.bgElevated,
            title: const Row(
              children: [
                Icon(Icons.qr_code_scanner_rounded, size: 19),
                SizedBox(width: 8),
                Text(
                  '115 网盘手机扫码登录',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 210,
                    height: 210,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : (qrImageBytes != null
                            ? Image.memory(
                                qrImageBytes!,
                                fit: BoxFit.contain,
                              )
                            : const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 42,
                                  color: Colors.black45,
                                ),
                              )),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    statusText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: VideoPlatformTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () => startQrFlow(setDialogState, closeSuccess),
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('刷新二维码'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    pollTimer?.cancel();
    if (loggedIn == true && mounted) {
      await _loadBackendSettingsAnd115();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('115 网盘扫码登录成功！')),
        );
      }
    }
  }

  Future<void> _saveConnectionConfig() async {
    setState(() => _isSavingConnection = true);
    final newCfg = ServerConfig(
      baseUrl: _baseUrlCtrl.text.trim(),
      authMode: _authMode,
      secret: _secretCtrl.text.trim(),
      preferDirectPlayback: _preferDirectPlayback,
    );
    final ok = await widget.appState.updateServerConfig(newCfg);
    if (!mounted) return;
    setState(() => _isSavingConnection = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '服务端连接成功，已加载 ${widget.appState.sources.length} 个片源站点'
              : '连接失败：${widget.appState.connectionError ?? "未知错误"}',
        ),
      ),
    );
  }

  Future<void> _saveBackendSettings() async {
    final currentRaw = widget.appState.serverSettings?.raw ?? {};
    final payload = <String, dynamic>{
      ...currentRaw,
      'mount_path': _mountPathCtrl.text.trim(),
      'file_manager_root': _fileRootCtrl.text.trim(),
      'max_concurrent_tasks':
          int.tryParse(_maxTasksCtrl.text.trim()) ?? 3,
      'max_segment_workers':
          int.tryParse(_maxWorkersCtrl.text.trim()) ?? 16,
      'eleven_dir_id': _elevenDirIdCtrl.text.trim(),
      'auto_move': _autoMove,
      'convert_to_mp4': _convertToMp4,
      'vod_backend_proxy_playback': _vodBackendProxy,
      'disable_115_api': _disable115Api,
    };

    setState(() => _isSavingServerSettings = true);
    try {
      await widget.appState.api.saveServerSettings(payload);
      await widget.appState.refreshServerSettings();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务端运行设置已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存服务端设置失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _isSavingServerSettings = false);
    }
  }

  Widget _buildThemePresetCard(
    AppState state,
    AppThemePalette p,
    int index, {
    double? width,
  }) {
    final presets = VideoPlatformTheme.presets;
    final selected = p.id == state.themeId;
    final focusNode = _themeCardFocusNodes[p.id];

    return Focus(
      focusNode: focusNode,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowRight) {
          final nextPreset = presets[(index + 1) % presets.length];
          _themeCardFocusNodes[nextPreset.id]?.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          final prevPreset =
              presets[(index - 1 + presets.length) % presets.length];
          _themeCardFocusNodes[prevPreset.id]?.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          if (_settingsScrollController.hasClients &&
              _settingsScrollController.position.pixels > 0) {
            _settingsScrollController.jumpTo(0);
          }
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent &&
            (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA)) {
          state.setThemeId(p.id);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _themeCardFocusNodes[p.id]?.requestFocus();
            }
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return GestureDetector(
            onTap: () {
              state.setThemeId(p.id);
              _themeCardFocusNodes[p.id]?.requestFocus();
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedScale(
                scale: isFocused ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 140),
                child: Container(
                  width: width,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? p.accent.withValues(alpha: 0.16)
                        : VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isFocused
                          ? const Color(0xFFFFE066)
                          : (selected
                              ? p.accent
                              : VideoPlatformTheme.borderSubtle),
                      width: isFocused ? 2.4 : (selected ? 1.6 : 1.0),
                    ),
                    boxShadow: isFocused
                        ? [
                            BoxShadow(
                              color: p.accent.withValues(alpha: 0.45),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Mini UI preview swatch
                      Container(
                        height: 38,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: p.bgPrimary,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: p.borderSubtle),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 18,
                              height: double.infinity,
                              decoration: BoxDecoration(
                                color: p.bgElevated,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 34,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: p.accent,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    width: 52,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: p.textSecondary
                                          .withValues(alpha: 0.5),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: (selected || isFocused)
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isFocused
                                    ? VideoPlatformTheme.textPrimary
                                    : (selected
                                        ? p.accent
                                        : VideoPlatformTheme.textPrimary),
                              ),
                            ),
                          ),
                          if (selected)
                            Icon(
                              Icons.check_circle,
                              size: 15,
                              color: p.accent,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isFocused && !selected ? '按确定键切换此主题' : p.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: isFocused
                              ? p.accent
                              : VideoPlatformTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final state = widget.appState;
        final activePreset = VideoPlatformTheme.presets.firstWhere(
          (p) => p.id == state.themeId,
          orElse: () => VideoPlatformTheme.presets.first,
        );

        return SingleChildScrollView(
          controller: _settingsScrollController,
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Version & Runtime Info Banner
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgElevated,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: VideoPlatformTheme.accent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.verified_rounded,
                              size: 20,
                              color: VideoPlatformTheme.accent,
                            ),
                            const SizedBox(width: 10),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '流光视频客户端',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: VideoPlatformTheme.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: VideoPlatformTheme.accent
                                            .withValues(alpha: 0.18),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: VideoPlatformTheme.accent,
                                        ),
                                      ),
                                      child: Text(
                                        AppState.appFullVersion,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          color: VideoPlatformTheme.accent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '当前主题：${activePreset.name} · 交互模式：${state.tvMode ? "TV 大屏遥控器模式" : "标准桌面/触屏模式"}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: VideoPlatformTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 0. UI Theme Appearance Settings
                  _buildSectionCard(
                    title: '界面主题外观',
                    subtitle: state.tvMode
                        ? '使用遥控器左右方向键选择主题，按确定/OK键立即切换并自动保存'
                        : '选择符合视频平台视觉习惯的暗色或日间主题配色，立即生效并自动保存',
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final presets = VideoPlatformTheme.presets;
                        if (constraints.maxWidth >= 640) {
                          return Row(
                            children: [
                              for (var i = 0; i < presets.length; i++) ...[
                                if (i > 0) const SizedBox(width: 10),
                                Expanded(
                                  child: _buildThemePresetCard(
                                    state,
                                    presets[i],
                                    i,
                                  ),
                                ),
                              ],
                            ],
                          );
                        }
                        return Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (var i = 0; i < presets.length; i++)
                              _buildThemePresetCard(
                                state,
                                presets[i],
                                i,
                                width: 142,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),

              // 1. Client Connection Settings
              _buildSectionCard(
                title: '客户端连接与认证',
                subtitle: '配置远程服务端地址、访问密码及客户端播放策略',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _baseUrlCtrl,
                      decoration: const InputDecoration(
                        labelText: '服务器地址 (URL)',
                        hintText: 'https://jp2.linsionwinwin.top:8081',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<AuthMode>(
                            value: _authMode,
                            decoration: const InputDecoration(
                              labelText: '认证方式',
                            ),
                            dropdownColor: VideoPlatformTheme.bgElevated,
                            items: const [
                              DropdownMenuItem(
                                value: AuthMode.password,
                                child: Text('访问密码 (Cookie)'),
                              ),
                              DropdownMenuItem(
                                value: AuthMode.token,
                                child: Text('API Token (Bearer)'),
                              ),
                              DropdownMenuItem(
                                value: AuthMode.none,
                                child: Text('免密访问'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _authMode = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_authMode != AuthMode.none)
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _secretCtrl,
                              obscureText: _obscureSecret,
                              decoration: InputDecoration(
                                labelText: _authMode == AuthMode.password
                                    ? '访问密码'
                                    : 'Bearer Token',
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscureSecret
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    size: 18,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscureSecret = !_obscureSecret,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        '优先客户端直连播放流媒体',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '开启后优先由本地播放器直连源站，失败时自动回退至服务端代理中转',
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      ),
                      value: _preferDirectPlayback,
                      activeColor: VideoPlatformTheme.accent,
                      onChanged: (v) =>
                          setState(() => _preferDirectPlayback = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        '全网多源聚合搜索',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '搜索影视时并发检索多个采集源与 TVBox 站点，汇总展示全部结果',
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      ),
                      value: state.aggregatedSearch,
                      activeColor: VideoPlatformTheme.accent,
                      onChanged: state.setAggregatedSearch,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed:
                              _isSavingConnection ? null : _saveConnectionConfig,
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: Text(
                            _isSavingConnection ? '正在验证连接...' : '保存并重新连接',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: state.logout,
                          icon: const Icon(Icons.logout_rounded, size: 16),
                          label: const Text('退出登录'),
                        ),
                        if (state.connectionError == null &&
                            state.sources.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: VideoPlatformTheme.success,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '已连接 · ${state.sources.length} 个片源可用',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: VideoPlatformTheme.success,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 2. Backend General & Download Settings
              _buildSectionCard(
                title: '服务端下载与转码设置',
                subtitle: '直接同步修改远程服务端的并发数、目录及自动转封装配置',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _maxTasksCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '同时下载任务数 (1-20)',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _maxWorkersCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '单任务 M3U8 分片并发数 (1-64)',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _fileRootCtrl,
                            decoration: const InputDecoration(
                              labelText: '视频资料库根目录',
                              hintText: 'downloads 或 /',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _mountPathCtrl,
                            decoration: const InputDecoration(
                              labelText: '115 本地挂载路径 (可选)',
                              hintText: '/Volumes/115Drive/Downloads',
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
                        '下载完成后自动转封装为 MP4 (需服务端安装 ffmpeg)',
                        style: TextStyle(fontSize: 13),
                      ),
                      value: _convertToMp4,
                      activeColor: VideoPlatformTheme.accent,
                      onChanged: (v) => setState(() => _convertToMp4 = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        '下载完成后自动上传 115 / 移动到挂载目录',
                        style: TextStyle(fontSize: 13),
                      ),
                      value: _autoMove,
                      activeColor: VideoPlatformTheme.accent,
                      onChanged: (v) => setState(() => _autoMove = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        '服务端全局强制代理播放 VOD 视频',
                        style: TextStyle(fontSize: 13),
                      ),
                      value: _vodBackendProxy,
                      activeColor: VideoPlatformTheme.accent,
                      onChanged: (v) => setState(() => _vodBackendProxy = v),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: _isSavingServerSettings
                              ? null
                              : _saveBackendSettings,
                          icon: const Icon(Icons.save_outlined, size: 16),
                          label: Text(
                            _isSavingServerSettings ? '保存中...' : '保存服务端设置',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            try {
                              await state.api.restartServerService();
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('已发送重启服务指令，请稍候重连'),
                                ),
                              );
                            } catch (e) {
                              messenger.showSnackBar(
                                SnackBar(content: Text('重启服务失败：$e')),
                              );
                            }
                          },
                          icon: Icon(
                            Icons.restart_alt_rounded,
                            size: 16,
                            color: VideoPlatformTheme.warning,
                          ),
                          label: const Text('重启后台服务'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 3. 115 Cloud Drive Settings
              _buildSectionCard(
                title: '115 网盘配置与登录',
                subtitle: '用于下载完成后自动上传或从媒体库手动上传至 115 网盘',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _is115LoggedIn
                              ? Icons.check_circle
                              : Icons.info_outline,
                          size: 16,
                          color: _is115LoggedIn
                              ? VideoPlatformTheme.success
                              : VideoPlatformTheme.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '当前状态：$_user115Info',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        if (_is115LoggedIn)
                          OutlinedButton(
                            onPressed: _isBusy115
                                ? null
                                : () async {
                                    setState(() => _isBusy115 = true);
                                    try {
                                      await state.api.logout115();
                                      await _loadBackendSettingsAnd115();
                                    } finally {
                                      if (mounted) {
                                        setState(() => _isBusy115 = false);
                                      }
                                    }
                                  },
                            child: const Text('退出 115'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!_is115LoggedIn) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _cookie115Ctrl,
                              decoration: const InputDecoration(
                                labelText: '115 Cookie 登录 (包含 UID, CID, SEID)',
                                hintText: 'UID=...; CID=...; SEID=...',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton(
                            onPressed: _isBusy115
                                ? null
                                : () async {
                                    final ck = _cookie115Ctrl.text.trim();
                                    if (ck.isEmpty) return;
                                    final messenger =
                                        ScaffoldMessenger.of(context);
                                    setState(() => _isBusy115 = true);
                                    try {
                                      await state.api.login115WithCookie(ck);
                                      _cookie115Ctrl.clear();
                                      await _loadBackendSettingsAnd115();
                                      messenger.showSnackBar(
                                        const SnackBar(
                                          content: Text('115 网盘登录成功'),
                                        ),
                                      );
                                    } catch (e) {
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('115 登录失败：$e'),
                                        ),
                                      );
                                    } finally {
                                      if (mounted) {
                                        setState(() => _isBusy115 = false);
                                      }
                                    }
                                  },
                            child: const Text('Cookie 登录'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _show115QrCodeDialog,
                            icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                            label: const Text('手机扫码登录'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _elevenDirIdCtrl,
                            decoration: const InputDecoration(
                              labelText: '115 上传目标目录 CID (默认为 0 根目录)',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                              '禁用 115 API (仅移动到挂载点)',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _disable115Api,
                            activeColor: VideoPlatformTheme.accent,
                            onChanged: (v) =>
                                setState(() => _disable115Api = v),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 4. VOD / TVBox Source Speed Test & Pin/Hide Management
              _buildSectionCard(
                title: '片源站点批量测速与排序管理',
                subtitle:
                    '并发测试各点播站响应延迟，支持置顶常用高速站、屏蔽失效站及按速度一键排序（共 ${state.sources.length} 个站点）',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: state.isTestingSources
                              ? null
                              : state.batchTestVodSources,
                          icon: const Icon(Icons.speed_rounded, size: 16),
                          label: Text(
                            state.isTestingSources
                                ? '正在并发测速 (${state.sourceLatencyMs.length}/${state.sources.take(28).length})...'
                                : '一键批量测速',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: state.sourceLatencyMs.isEmpty
                              ? null
                              : state.sortSourcesByLatency,
                          icon: const Icon(Icons.sort_rounded, size: 16),
                          label: const Text('按响应速度排序'),
                        ),
                        Text(
                          '已置顶 ${state.pinnedSourceIds.length} 个 · 已屏蔽 ${state.hiddenSourceIds.length} 个',
                          style: TextStyle(
                            fontSize: 12,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: Container(
                        decoration: BoxDecoration(
                          color: VideoPlatformTheme.bgCard,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: state.sources.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, idx) {
                            final src = state.sources[idx];
                            final isPinned =
                                state.pinnedSourceIds.contains(src.id);
                            final isHidden =
                                state.hiddenSourceIds.contains(src.id);
                            final isSelected =
                                state.selectedSource?.id == src.id;
                            final ms = state.sourceLatencyMs[src.id];

                            return ListTile(
                              dense: true,
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      src.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        decoration: isHidden
                                            ? TextDecoration.lineThrough
                                            : null,
                                        fontWeight: isSelected || isPinned
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: isHidden
                                            ? VideoPlatformTheme.textMuted
                                            : (isSelected
                                                ? VideoPlatformTheme.accent
                                                : VideoPlatformTheme
                                                    .textPrimary),
                                      ),
                                    ),
                                  ),
                                  if (ms != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: (ms > 0 && ms < 800
                                                ? VideoPlatformTheme.success
                                                : (ms > 0
                                                    ? VideoPlatformTheme.warning
                                                    : VideoPlatformTheme
                                                        .danger))
                                            .withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        ms > 0 ? '${ms}ms' : '超时',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: ms > 0 && ms < 800
                                              ? VideoPlatformTheme.success
                                              : (ms > 0
                                                  ? VideoPlatformTheme.warning
                                                  : VideoPlatformTheme.danger),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: isPinned ? '取消置顶' : '置顶此片源',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        state.togglePinSource(src.id),
                                    icon: Icon(
                                      isPinned
                                          ? Icons.push_pin_rounded
                                          : Icons.push_pin_outlined,
                                      size: 16,
                                      color: isPinned
                                          ? VideoPlatformTheme.warning
                                          : VideoPlatformTheme.textMuted,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: isHidden ? '恢复显示' : '屏蔽此片源',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        state.toggleHideSource(src.id),
                                    icon: Icon(
                                      isHidden
                                          ? Icons.visibility_off_rounded
                                          : Icons.visibility_outlined,
                                      size: 16,
                                      color: isHidden
                                          ? VideoPlatformTheme.danger
                                          : VideoPlatformTheme.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () => state.selectVodSource(src),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
      },
    );
  }

  Widget _buildSectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: VideoPlatformTheme.textMuted,
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
