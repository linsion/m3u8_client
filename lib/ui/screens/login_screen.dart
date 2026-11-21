import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/app_brand_logo.dart';

class LoginScreen extends StatefulWidget {
  final AppState appState;

  const LoginScreen({
    super.key,
    required this.appState,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _passwordController;
  late AuthMode _authMode;
  bool _obscurePassword = true;
  bool _showServerOptions = false;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final cfg = widget.appState.serverConfig;
    _urlController = TextEditingController(text: cfg.baseUrl);
    _passwordController = TextEditingController(text: cfg.secret);
    _authMode = cfg.authMode;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final baseUrl = _urlController.text.trim();
    final secret = _passwordController.text.trim();

    if (baseUrl.isEmpty) {
      setState(() => _errorText = '请输入服务器地址');
      return;
    }
    if (_authMode != AuthMode.none && secret.isEmpty) {
      setState(
        () => _errorText =
            _authMode == AuthMode.password ? '请输入访问密码' : '请输入 API Token',
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final newConfig = widget.appState.serverConfig.copyWith(
      baseUrl: baseUrl,
      authMode: _authMode,
      secret: secret,
    );

    final ok = await widget.appState.updateServerConfig(newConfig);
    if (!mounted) return;

    setState(() {
      _isSubmitting = false;
      if (!ok) {
        _errorText = widget.appState.connectionError ?? '登录失败，请检查密码或服务器地址';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VideoPlatformTheme.bgPrimary,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const AppBrandLogo(size: 36),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '流光视频',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: VideoPlatformTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: VideoPlatformTheme.accent
                                      .withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: VideoPlatformTheme.accent
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Text(
                                  widget.appState.appShortVersion,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: VideoPlatformTheme.accent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '请输入访问密码以连接视频服务',
                            style: TextStyle(
                              fontSize: 12,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_authMode != AuthMode.none) ...[
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofocus: true,
                      onSubmitted: (_) => _handleLogin(),
                      decoration: InputDecoration(
                        labelText: _authMode == AuthMode.password
                            ? '访问密码'
                            : 'API Token',
                        hintText: _authMode == AuthMode.password
                            ? '请输入站点访问密码'
                            : '请输入 Bearer Token',
                        prefixIcon: Icon(
                          Icons.lock_outline_rounded,
                          size: 18,
                          color: VideoPlatformTheme.textMuted,
                        ),
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
                    const SizedBox(height: 14),
                  ],
                  if (_showServerOptions) ...[
                    TextField(
                      controller: _urlController,
                      onSubmitted: (_) => _handleLogin(),
                      decoration: InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://jp2.linsionwinwin.top:8081',
                        prefixIcon: Icon(
                          Icons.dns_outlined,
                          size: 18,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<AuthMode>(
                      value: _authMode,
                      dropdownColor: VideoPlatformTheme.bgElevated,
                      decoration: const InputDecoration(
                        labelText: '认证方式',
                      ),
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
                      onChanged: (val) {
                        if (val != null) setState(() => _authMode = val);
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (_errorText != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: VideoPlatformTheme.danger.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color:
                              VideoPlatformTheme.danger.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        _errorText!,
                        style: TextStyle(
                          color: VideoPlatformTheme.danger,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  SizedBox(
                    height: 40,
                    child: FilledButton(
                      onPressed: _isSubmitting ? null : _handleLogin,
                      child: _isSubmitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('登录进入'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _urlController.text.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () => _showServerOptions = !_showServerOptions,
                        ),
                        child: Text(
                          _showServerOptions ? '收起服务器设置' : '修改服务器地址',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
