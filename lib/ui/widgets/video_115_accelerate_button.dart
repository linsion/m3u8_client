import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/api_client.dart';
import '../../services/local_115_direct_service.dart';
import '../theme.dart';

class Video115AccelerateButton extends StatefulWidget {
  final ApiClient api;
  final String Function() downloadUrlBuilder;
  final String Function() videoNameBuilder;
  final Map<String, String> Function()? headersBuilder;
  final String? telegramAccountId;
  final bool isUsing115Direct;
  final bool compact;
  final bool overlayStyle;
  final FocusNode? focusNode;
  final FocusNode? upFocusNode;
  final FocusNode? downFocusNode;
  final FocusNode? leftFocusNode;
  final FocusNode? rightFocusNode;
  final VoidCallback? onInteraction;
  final ValueChanged<Resolved115Stream> onResolved;

  const Video115AccelerateButton({
    super.key,
    required this.api,
    required this.downloadUrlBuilder,
    required this.videoNameBuilder,
    this.headersBuilder,
    this.telegramAccountId,
    this.isUsing115Direct = false,
    this.compact = false,
    this.overlayStyle = true,
    this.focusNode,
    this.upFocusNode,
    this.downFocusNode,
    this.leftFocusNode,
    this.rightFocusNode,
    this.onInteraction,
    required this.onResolved,
  });

  @override
  State<Video115AccelerateButton> createState() =>
      _Video115AccelerateButtonState();
}

class _Video115AccelerateButtonState extends State<Video115AccelerateButton> {
  bool _isFocused = false;

  Future<void> _handleTap() async {
    widget.onInteraction?.call();
    final svc = Local115DirectService.instance;
    await svc.ensureInitialized();

    if (!mounted) return;
    if (svc.isAccelerating) {
      svc.cancelAcceleration();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已取消 115 云端加速任务'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (!svc.hasLocalCookie) {
      final loggedIn = await show115QuickLoginDialog(
        context: context,
        api: widget.api,
      );
      if (!loggedIn || !mounted) return;
    }

    final downloadUrl = widget.downloadUrlBuilder().trim();
    if (downloadUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前视频地址尚未就绪，请稍候再试')),
        );
      }
      return;
    }

    final videoName = widget.videoNameBuilder().trim();
    final headers = widget.headersBuilder?.call() ?? const <String, String>{};

    final resolved = await show115AccelerationProgressDialog(
      context: context,
      api: widget.api,
      downloadUrl: downloadUrl,
      videoName: videoName.isEmpty ? '视频资源' : videoName,
      headers: headers,
      telegramAccountId: widget.telegramAccountId,
    );

    if (resolved != null && mounted) {
      widget.onResolved(resolved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = Local115DirectService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final active = widget.isUsing115Direct;
        final running = svc.isAccelerating;
        final label = active
            ? (widget.compact ? '⚡115直连' : '⚡ 115直连中')
            : (running
                ? '⚡ 115加速中...'
                : (widget.compact ? '⚡115加速' : '⚡ 115加速播放'));

        final bgColor = _isFocused
            ? VideoPlatformTheme.accent
            : (active
                ? const Color(0xFF10B981).withValues(alpha: 0.25)
                : (widget.overlayStyle
                    ? const Color(0xAA000000)
                    : VideoPlatformTheme.bgElevated));

        final borderColor = _isFocused
            ? Colors.white
            : (active
                ? const Color(0xFF34D399)
                : (widget.overlayStyle
                    ? Colors.white.withValues(alpha: 0.22)
                    : VideoPlatformTheme.borderSubtle));

        final fgColor = _isFocused
            ? Colors.white
            : (active ? const Color(0xFF6EE7B7) : Colors.white);

        return Focus(
          focusNode: widget.focusNode,
          onFocusChange: (f) {
            if (mounted) setState(() => _isFocused = f);
            if (f) widget.onInteraction?.call();
          },
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA) {
              _handleTap();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowUp &&
                widget.upFocusNode != null) {
              widget.upFocusNode!.requestFocus();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowDown &&
                widget.downFocusNode != null) {
              widget.downFocusNode!.requestFocus();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft &&
                widget.leftFocusNode != null) {
              widget.leftFocusNode!.requestFocus();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowRight &&
                widget.rightFocusNode != null) {
              widget.rightFocusNode!.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Tooltip(
            message: '先由服务器高速下载并上传至 115 网盘，再从本地直连 115 国内 CDN 流畅播放',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: _handleTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 8 : 11,
                    vertical: widget.compact ? 4 : 5.5,
                  ),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: borderColor,
                      width: _isFocused ? 1.8 : 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        active
                            ? Icons.cloud_done_rounded
                            : Icons.bolt_rounded,
                        size: widget.compact ? 13 : 14,
                        color: fgColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: widget.compact ? 11 : 12,
                          fontWeight: FontWeight.w600,
                          color: fgColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shows the interactive 115 QR Code / Cookie Login dialog directly inside any player or screen.
/// Returns `true` if login succeeded.
Future<bool> show115QuickLoginDialog({
  required BuildContext context,
  required ApiClient api,
}) async {
  final svc = Local115DirectService.instance;
  await svc.ensureInitialized();
  if (!context.mounted) return false;

  final res = await showDialog<bool>(
    context: context,
    builder: (_) => _QuickLogin115Dialog(api: api),
  );
  return res == true;
}

class _QuickLogin115Dialog extends StatefulWidget {
  final ApiClient api;

  const _QuickLogin115Dialog({
    required this.api,
  });

  @override
  State<_QuickLogin115Dialog> createState() => _QuickLogin115DialogState();
}

class _QuickLogin115DialogState extends State<_QuickLogin115Dialog> {
  final TextEditingController _cookieCtrl = TextEditingController();
  String _statusText = '正在获取 115 官方扫码二维码...';
  String _imageUrl = '';
  int _activeQrFlowId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_startQrFlow(forceRefresh: false));
  }

  @override
  void dispose() {
    _activeQrFlowId++;
    _cookieCtrl.dispose();
    super.dispose();
  }

  Future<void> _startQrFlow({required bool forceRefresh}) async {
    final flowId = ++_activeQrFlowId;
    final svc = Local115DirectService.instance;
    if (mounted && (_imageUrl.isEmpty || forceRefresh)) {
      setState(() {
        _statusText = '正在获取 115 官方扫码二维码...';
        if (forceRefresh) {
          _imageUrl = '';
        }
      });
    }
    try {
      final session = await svc.startQrCodeSession(forceRefresh: forceRefresh);
      if (!mounted || flowId != _activeQrFlowId) return;
      const initialPrompt = '请使用手机 115 网盘 App 扫描二维码（确认后将自动完成登录）';
      if (_imageUrl != session.imageUrl || _statusText != initialPrompt) {
        setState(() {
          _imageUrl = session.imageUrl;
          _statusText = initialPrompt;
        });
      }

      // Poll calmly every 2.5s for up to 5 minutes (120 attempts) without refreshing the QR code
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        if (!mounted || flowId != _activeQrFlowId) break;
        final poll = await svc.pollQrCodeStatus(
          uid: session.uid,
          time: session.time,
          sign: session.sign,
          syncToServerApi: widget.api,
        );
        if (!mounted || flowId != _activeQrFlowId) break;
        if (_statusText != poll.message) {
          setState(() {
            _statusText = poll.message;
          });
        }
        if (poll.status == 2 && poll.cookie != null) {
          svc.invalidateCachedQrSession();
          if (mounted) {
            Navigator.of(context).pop(true);
          }
          break;
        } else if (poll.status < 0) {
          svc.invalidateCachedQrSession();
          break;
        }
      }
    } catch (e) {
      if (mounted && flowId == _activeQrFlowId) {
        setState(() {
          _statusText = '获取 115 二维码失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = Local115DirectService.instance;
    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      title: Row(
        children: [
          Icon(Icons.bolt_rounded, color: VideoPlatformTheme.accent, size: 22),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '登录 115 网盘开启「云端下载 + 本地直连 115 播放」',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '先由服务器高速下载资源并上传至 115 网盘，再由本地客户端直接请求 115 国内 CDN 高速播放',
                style: TextStyle(
                  fontSize: 12.5,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: 200,
                height: 200,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _imageUrl.isNotEmpty
                    ? Image.network(
                        _imageUrl,
                        key: ValueKey<String>(_imageUrl),
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.qr_code_2_rounded,
                            size: 64,
                            color: Colors.black54,
                          ),
                        ),
                      )
                    : const Center(
                        child: CircularProgressIndicator(),
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: VideoPlatformTheme.accent,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _startQrFlow(forceRefresh: true),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('刷新二维码'),
              ),
              const Divider(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '或者直接粘贴 115 浏览器 Cookie (包含 UID, CID, SEID)：',
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cookieCtrl,
                      style: const TextStyle(fontSize: 12.5),
                      decoration: const InputDecoration(
                        hintText: 'UID=...; CID=...; SEID=...',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      final raw = _cookieCtrl.text.trim();
                      if (raw.isEmpty) return;
                      await svc.saveCookie(
                        raw,
                        syncToServerApi: widget.api,
                      );
                      if (svc.hasLocalCookie && context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    },
                    child: const Text('保存并启用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// Runs the 3-stage "Server Download -> Upload to 115 -> Local 115 Direct CDN Play" pipeline
/// while displaying a live progress dialog with a Cancel button.
Future<Resolved115Stream?> show115AccelerationProgressDialog({
  required BuildContext context,
  required ApiClient api,
  required String downloadUrl,
  required String videoName,
  Map<String, String> headers = const {},
  String? telegramAccountId,
}) async {
  final svc = Local115DirectService.instance;
  Resolved115Stream? resolvedStream;
  String? pipelineError;
  bool dialogActive = true;

  BuildContext? activeDialogCtx;

  unawaited(
    svc
        .run115CloudAccelerationPipeline(
      api: api,
      downloadUrl: downloadUrl,
      videoName: videoName,
      headers: headers,
      telegramAccountId: telegramAccountId,
      onError: (err) {
        pipelineError = err;
      },
    )
        .then((res) {
      resolvedStream = res;
      if (dialogActive && activeDialogCtx != null && activeDialogCtx!.mounted) {
        Navigator.of(activeDialogCtx!).pop(res);
      }
    }),
  );

  final out = await showDialog<Resolved115Stream?>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      activeDialogCtx = dialogCtx;
      return ListenableBuilder(
        listenable: svc,
        builder: (ctx, _) {
          final pct = (svc.progress.clamp(0.02, 1.0) * 100).toStringAsFixed(0);
          return AlertDialog(
            backgroundColor: VideoPlatformTheme.bgElevated,
            title: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    svc.stageTitle.isEmpty
                        ? '⚡ 正在准备 115 云端加速播放...'
                        : svc.stageTitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '$pct%',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: svc.progress.clamp(0.03, 1.0),
                      minHeight: 8,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    svc.detailText.isEmpty ? videoName : svc.detailText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
                onPressed: () {
                  dialogActive = false;
                  svc.cancelAcceleration();
                  Navigator.of(dialogCtx).pop(null);
                },
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('取消加速'),
              ),
            ],
          );
        },
      );
    },
  );

  dialogActive = false;
  if (pipelineError != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(pipelineError!)),
    );
  }
  return out ?? resolvedStream;
}
