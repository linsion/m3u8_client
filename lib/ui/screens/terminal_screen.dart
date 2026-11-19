import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../../models/models.dart';
import '../../services/remote_storage_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';

// =============================================================================
// 1. Data Models: Host Profiles, SFTP Entries, Transfer Tasks & Server Metrics
// =============================================================================

enum TerminalHostKind {
  backendWs, // 流光服务端内置 WebSocket 终端 (/api/terminal/ws)
  ssh2, // 标准 SSH2 + SFTP 远程主机 (dartssh2)
  localShell, // 本机 Shell (macOS / Linux / Windows)
}

class TerminalHostProfile {
  final String id;
  final String name;
  final String group;
  final TerminalHostKind kind;
  final String host;
  final int port;
  final String username;
  final String authType; // 'password' or 'privateKey'
  final String password;
  final String privateKeyPem;
  final String passphrase;
  final String initialSftpPath;
  final String startupCommand;

  const TerminalHostProfile({
    required this.id,
    required this.name,
    this.group = '默认分组',
    required this.kind,
    this.host = '',
    this.port = 22,
    this.username = 'root',
    this.authType = 'password',
    this.password = '',
    this.privateKeyPem = '',
    this.passphrase = '',
    this.initialSftpPath = '/',
    this.startupCommand = '',
  });

  bool get isBuiltIn =>
      id == 'builtin_backend_ws' || id == 'builtin_local_shell';

  String get subtitle {
    switch (kind) {
      case TerminalHostKind.backendWs:
        return '流光服务端 WebSocket 终端 + 服务端文件管理';
      case TerminalHostKind.localShell:
        return '本机系统 Shell (${Platform.operatingSystem}) + 本地文件管理';
      case TerminalHostKind.ssh2:
        return '$username@$host:$port · SSH2 + SFTP (${authType == "privateKey" ? "密钥" : "密码"})';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'kind': kind.name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType,
        'password': password,
        'privateKeyPem': privateKeyPem,
        'passphrase': passphrase,
        'initialSftpPath': initialSftpPath,
        'startupCommand': startupCommand,
      };

  factory TerminalHostProfile.fromJson(Map<String, dynamic> json) {
    final kindStr = (json['kind'] ?? 'ssh2').toString();
    final kind = TerminalHostKind.values.firstWhere(
      (k) => k.name == kindStr,
      orElse: () => TerminalHostKind.ssh2,
    );
    return TerminalHostProfile(
      id: (json['id'] ?? 'ssh_${DateTime.now().millisecondsSinceEpoch}')
          .toString(),
      name: (json['name'] ?? '远程主机').toString(),
      group: (json['group'] ?? '默认分组').toString(),
      kind: kind,
      host: (json['host'] ?? '').toString(),
      port: int.tryParse((json['port'] ?? 22).toString()) ?? 22,
      username: (json['username'] ?? 'root').toString(),
      authType: (json['authType'] ?? 'password').toString(),
      password: (json['password'] ?? '').toString(),
      privateKeyPem: (json['privateKeyPem'] ?? '').toString(),
      passphrase: (json['passphrase'] ?? '').toString(),
      initialSftpPath: (json['initialSftpPath'] ?? '/').toString(),
      startupCommand: (json['startupCommand'] ?? '').toString(),
    );
  }
}

class SftpEntryItem {
  final String name;
  final String path;
  final bool isDir;
  final bool isSymlink;
  final int size;
  final int? permissions;
  final String modTimeText;
  final String longname;

  const SftpEntryItem({
    required this.name,
    required this.path,
    required this.isDir,
    this.isSymlink = false,
    required this.size,
    this.permissions,
    required this.modTimeText,
    this.longname = '',
  });

  String get formattedSize {
    if (isDir) return '目录';
    if (size <= 0) return '0 B';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get octalPermissions {
    if (permissions == null) return isDir ? '0755' : '0644';
    final p = permissions! & 0x1FF;
    return '0${p.toRadixString(8).padLeft(3, '0')}';
  }

  bool get isEditableText {
    if (isDir) return false;
    if (size > 2 * 1024 * 1024) return false; // Cap inline editor to 2MB
    final lower = name.toLowerCase();
    const exts = [
      '.txt',
      '.log',
      '.conf',
      '.ini',
      '.json',
      '.yaml',
      '.yml',
      '.xml',
      '.sh',
      '.bash',
      '.zsh',
      '.py',
      '.js',
      '.ts',
      '.dart',
      '.go',
      '.rs',
      '.c',
      '.cpp',
      '.h',
      '.html',
      '.css',
      '.md',
      '.env',
      '.service',
      '.toml',
      '.csv',
      '.sql',
      '.m3u',
      '.m3u8',
      '.lrc',
      '.srt',
    ];
    if (exts.any((e) => lower.endsWith(e))) return true;
    const exactNames = [
      'dockerfile',
      'makefile',
      'caddyfile',
      'hosts',
      'fstab',
      'crontab',
      'profile',
      '.bashrc',
      '.zshrc',
      '.profile',
      '.gitignore',
      '.env',
    ];
    return exactNames.contains(lower);
  }
}

class SftpTransferProgressItem {
  final String id;
  final String fileName;
  final bool isUpload;
  int transferredBytes;
  int totalBytes;
  String status; // 'running', 'completed', 'failed'
  String detail;

  SftpTransferProgressItem({
    required this.id,
    required this.fileName,
    required this.isUpload,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.status = 'running',
    this.detail = '',
  });

  double get progress => totalBytes > 0
      ? (transferredBytes / totalBytes).clamp(0.0, 1.0)
      : (status == 'completed' ? 1.0 : 0.0);
}

class ServerLiveMetrics {
  final String loadAvg;
  final String memText;
  final double memRatio;
  final String diskText;
  final double diskRatio;
  final String uptimeText;
  final String kernelText;

  const ServerLiveMetrics({
    this.loadAvg = '--',
    this.memText = '--',
    this.memRatio = 0.0,
    this.diskText = '--',
    this.diskRatio = 0.0,
    this.uptimeText = '--',
    this.kernelText = '',
  });
}

// =============================================================================
// 2. Terminal Tab Session (Supports WebSocket, SSH2 + SFTP, and Local Shell)
// =============================================================================

class _TerminalTabSession {
  final int id;
  String label;
  TerminalHostProfile hostProfile;
  late final Terminal terminal;
  final TerminalController controller = TerminalController();
  final FocusNode focusNode = FocusNode();
  final List<TerminalHighlight> searchHighlights = [];

  // 1) WebSocket mode (/api/terminal/ws)
  WebSocket? wsSocket;
  StreamSubscription<dynamic>? wsSub;

  // 2) SSH2 + SFTP mode (dartssh2)
  SSHClient? sshClient;
  SSHSession? sshShellSession;
  SftpClient? sftpClient;
  StreamSubscription<Uint8List>? sshStdoutSub;
  StreamSubscription<Uint8List>? sshStderrSub;

  // 3) Local Shell mode (Process)
  Process? localProcess;
  StreamSubscription<List<int>>? localStdoutSub;
  StreamSubscription<List<int>>? localStderrSub;

  bool isConnecting = false;
  bool isConnected = false;
  String statusText = '待连接 (点击连接按钮或选择主机启动)';
  String sessionMeta = '';
  int sessionCount = 0;
  int lastCols = 120;
  int lastRows = 36;

  // SFTP State for this tab
  String sftpCurrentPath = '/';
  List<SftpEntryItem> sftpEntries = const [];
  bool isLoadingSftp = false;
  String? sftpError;
  bool sftpShowHidden = false;
  String sftpSearchFilter = '';
  final List<SftpTransferProgressItem> sftpTransfers = [];

  // Live Server Metrics
  ServerLiveMetrics metrics = const ServerLiveMetrics();
  Timer? metricsTimer;

  _TerminalTabSession({
    required this.id,
    required this.label,
    required this.hostProfile,
    required void Function(String) onOutput,
    required void Function(int cols, int rows) onResize,
    required void Function(String title) onTitleChange,
  }) {
    sftpCurrentPath = hostProfile.initialSftpPath.trim().isEmpty
        ? '/'
        : hostProfile.initialSftpPath.trim();
    terminal = Terminal(
      maxLines: 8000,
      onOutput: onOutput,
      onResize: (cols, rows, _, __) {
        lastCols = cols;
        lastRows = rows;
        onResize(cols, rows);
      },
      onTitleChange: onTitleChange,
    );
  }

  void clearHighlights() {
    for (final h in searchHighlights) {
      h.dispose();
    }
    searchHighlights.clear();
  }

  Future<void> disconnectResources() async {
    metricsTimer?.cancel();
    metricsTimer = null;

    await wsSub?.cancel();
    wsSub = null;
    try {
      await wsSocket?.close(1000, 'disconnect');
    } catch (_) {}
    wsSocket = null;

    await sshStdoutSub?.cancel();
    sshStdoutSub = null;
    await sshStderrSub?.cancel();
    sshStderrSub = null;
    try {
      sftpClient?.close();
    } catch (_) {}
    sftpClient = null;
    try {
      sshShellSession?.close();
    } catch (_) {}
    sshShellSession = null;
    try {
      sshClient?.close();
    } catch (_) {}
    sshClient = null;

    await localStdoutSub?.cancel();
    localStdoutSub = null;
    await localStderrSub?.cancel();
    localStderrSub = null;
    try {
      localProcess?.kill();
    } catch (_) {}
    localProcess = null;
  }

  Future<void> dispose() async {
    clearHighlights();
    await disconnectResources();
    controller.dispose();
    focusNode.dispose();
  }
}

// =============================================================================
// 3. Main Terminal & SFTP Workbench Screen
// =============================================================================

class TerminalScreen extends StatefulWidget {
  final AppState appState;

  const TerminalScreen({
    super.key,
    required this.appState,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const int _maxInputFrameBytes = 32 * 1024;
  static const String _prefCustomSnippetsKey = 'm3u8_terminal_snippets_v1';
  static const String _prefTerminalThemeKey = 'm3u8_terminal_theme_v1';
  static const String _prefTerminalFontSizeKey = 'm3u8_terminal_font_size_v1';
  static const String _prefSshHostsKey = 'm3u8_terminal_ssh_hosts_v1';
  static const String _prefCmdHistoryKey = 'm3u8_terminal_cmd_history_v1';

  final List<_TerminalTabSession> _tabs = [];
  int _activeTabIndex = 0;
  int _nextTabId = 1;

  List<TerminalHostProfile> _hostProfiles = [];
  String _selectedProfileIdForNewConnect = 'builtin_backend_ws';

  double _fontSize = 14.0;
  String _terminalThemeId = 'ocean';
  bool _broadcastToAllTabs = false;
  TerminalCursorType _cursorType = TerminalCursorType.block;

  // Toggleable panels (SFTP Explorer, Live Metrics, Virtual Keys, Command Composer)
  bool _showSftpPanel = true;
  bool _showLiveMetricsBar = true;
  bool _showVirtualKeysBar = true;
  bool _showCommandComposerBar = true;
  bool _ctrlLocked = false;
  bool _altLocked = false;

  bool _showSearchBar = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _sftpPathCtrl = TextEditingController();
  final TextEditingController _sftpFilterCtrl = TextEditingController();
  final TextEditingController _commandInputCtrl = TextEditingController();
  int _searchMatchCount = 0;

  List<String> _commandHistory = [];
  int _historyCursor = -1;

  List<({String label, String command})> _quickSnippets = [
    (label: '📂 ls -la', command: 'ls -la\n'),
    (label: '💾 磁盘 df -h', command: 'df -h\n'),
    (label: '🧠 内存/负载', command: 'uptime && free -h 2>/dev/null || vm_stat\n'),
    (label: '⚙️ 进程排名前15', command: 'ps aux | head -n 16\n'),
    (
      label: '🌐 端口监听',
      command: 'ss -tlpn 2>/dev/null || netstat -tlpn 2>/dev/null || lsof -iTCP -sTCP:LISTEN -P -n\n'
    ),
    (label: '🐳 Docker容器', command: 'docker ps -a\n'),
    (label: '📊Docker状态', command: 'docker stats --no-stream\n'),
    (label: '🔥 系统服务', command: 'systemctl list-units --type=service --state=running\n'),
    (
      label: '📜 查看最新日志',
      command: 'ls -lt *.log logs/*.log /var/log/*.log 2>/dev/null | head -n 12\n'
    ),
    (label: '🌍 公网IP检测', command: 'curl -s ifconfig.me && echo ""\n'),
    (label: '🛑 Ctrl+C 中断', command: '\x03'),
  ];

  // 9 Open-Source Terminal Color Schemes (Tabby / iTerm2 / VSCode / Alacritty)
  static const Map<String, ({String name, TerminalTheme theme})>
      _terminalThemes = {
    'ocean': (
      name: '深海青黑 (Ocean Dark)',
      theme: TerminalTheme(
        cursor: Color(0xB379DDD0),
        selection: Color(0x66285B66),
        foreground: Color(0xFFD7E3E8),
        background: Color(0xFF0B141B),
        black: Color(0xFF172630),
        red: Color(0xFFEF746A),
        green: Color(0xFF65C99C),
        yellow: Color(0xFFE7BD68),
        blue: Color(0xFF67A7E8),
        magenta: Color(0xFFBD8BEA),
        cyan: Color(0xFF63C4C9),
        white: Color(0xFFD7E3E8),
        brightBlack: Color(0xFF718893),
        brightRed: Color(0xFFFF9188),
        brightGreen: Color(0xFF82DFB5),
        brightYellow: Color(0xFFF3D18E),
        brightBlue: Color(0xFF8BC0F5),
        brightMagenta: Color(0xFFD4A8F8),
        brightCyan: Color(0xFF83DADE),
        brightWhite: Color(0xFFF5FBFD),
        searchHitBackground: Color(0xFFE7BD68),
        searchHitBackgroundCurrent: Color(0xFFFF5C38),
        searchHitForeground: Color(0xFF0B141B),
      ),
    ),
    'dracula': (
      name: 'Dracula 暗紫',
      theme: TerminalTheme(
        cursor: Color(0xCCBD93F9),
        selection: Color(0x6644475A),
        foreground: Color(0xFFF8F8F2),
        background: Color(0xFF1E1F29),
        black: Color(0xFF21222C),
        red: Color(0xFFFF5555),
        green: Color(0xFF50FA7B),
        yellow: Color(0xFFF1FA8C),
        blue: Color(0xFFBD93F9),
        magenta: Color(0xFFFF79C6),
        cyan: Color(0xFF8BE9FD),
        white: Color(0xFFF8F8F2),
        brightBlack: Color(0xFF6272A4),
        brightRed: Color(0xFFFF6E6E),
        brightGreen: Color(0xFF69FF94),
        brightYellow: Color(0xFFFFFFA5),
        brightBlue: Color(0xFFD6ACFF),
        brightMagenta: Color(0xFFFF92DF),
        brightCyan: Color(0xFFA4FFFF),
        brightWhite: Color(0xFFFFFFFF),
        searchHitBackground: Color(0xFFF1FA8C),
        searchHitBackgroundCurrent: Color(0xFFFF79C6),
        searchHitForeground: Color(0xFF1E1F29),
      ),
    ),
    'onedark': (
      name: 'One Dark Pro (Atom/VSCode)',
      theme: TerminalTheme(
        cursor: Color(0xCC528BFF),
        selection: Color(0x663E4451),
        foreground: Color(0xFFABB2BF),
        background: Color(0xFF1E222A),
        black: Color(0xFF282C34),
        red: Color(0xFFE06C75),
        green: Color(0xFF98C379),
        yellow: Color(0xFFE5C07B),
        blue: Color(0xFF61AFEF),
        magenta: Color(0xFFC678DD),
        cyan: Color(0xFF56B6C2),
        white: Color(0xFFABB2BF),
        brightBlack: Color(0xFF5C6370),
        brightRed: Color(0xFFE06C75),
        brightGreen: Color(0xFF98C379),
        brightYellow: Color(0xFFE5C07B),
        brightBlue: Color(0xFF61AFEF),
        brightMagenta: Color(0xFFC678DD),
        brightCyan: Color(0xFF56B6C2),
        brightWhite: Color(0xFFFFFFFF),
        searchHitBackground: Color(0xFFE5C07B),
        searchHitBackgroundCurrent: Color(0xFFE06C75),
        searchHitForeground: Color(0xFF1E222A),
      ),
    ),
    'tokyonight': (
      name: 'Tokyo Night 东京夜色',
      theme: TerminalTheme(
        cursor: Color(0xCC7AA2F7),
        selection: Color(0x6633467C),
        foreground: Color(0xFFC0CAF5),
        background: Color(0xFF1A1B26),
        black: Color(0xFF15161E),
        red: Color(0xFFF7768E),
        green: Color(0xFF9ECE6A),
        yellow: Color(0xFFE0AF68),
        blue: Color(0xFF7AA2F7),
        magenta: Color(0xFFBB9AF7),
        cyan: Color(0xFF7DCFFF),
        white: Color(0xFFA9B1D6),
        brightBlack: Color(0xFF414868),
        brightRed: Color(0xFFF7768E),
        brightGreen: Color(0xFF9ECE6A),
        brightYellow: Color(0xFFE0AF68),
        brightBlue: Color(0xFF7AA2F7),
        brightMagenta: Color(0xFFBB9AF7),
        brightCyan: Color(0xFF7DCFFF),
        brightWhite: Color(0xFFC0CAF5),
        searchHitBackground: Color(0xFFE0AF68),
        searchHitBackgroundCurrent: Color(0xFFF7768E),
        searchHitForeground: Color(0xFF1A1B26),
      ),
    ),
    'catppuccin': (
      name: 'Catppuccin Mocha',
      theme: TerminalTheme(
        cursor: Color(0xCCF5E0DC),
        selection: Color(0x66585B70),
        foreground: Color(0xFFCDD6F4),
        background: Color(0xFF1E1E2E),
        black: Color(0xFF45475A),
        red: Color(0xFFF38BA8),
        green: Color(0xFFA6E3A1),
        yellow: Color(0xFFF9E2AF),
        blue: Color(0xFF89B4FA),
        magenta: Color(0xFFF5C2E7),
        cyan: Color(0xFF94E2D5),
        white: Color(0xFFBAC2DE),
        brightBlack: Color(0xFF585B70),
        brightRed: Color(0xFFF38BA8),
        brightGreen: Color(0xFFA6E3A1),
        brightYellow: Color(0xFFF9E2AF),
        brightBlue: Color(0xFF89B4FA),
        brightMagenta: Color(0xFFF5C2E7),
        brightCyan: Color(0xFF94E2D5),
        brightWhite: Color(0xFFA6ADC8),
        searchHitBackground: Color(0xFFF9E2AF),
        searchHitBackgroundCurrent: Color(0xFFF38BA8),
        searchHitForeground: Color(0xFF1E1E2E),
      ),
    ),
    'monokai': (
      name: 'Monokai Pro 经典',
      theme: TerminalTheme(
        cursor: Color(0xCCFFD866),
        selection: Color(0x665B595C),
        foreground: Color(0xFFFCFCFA),
        background: Color(0xFF2D2A2E),
        black: Color(0xFF403E41),
        red: Color(0xFFFF6188),
        green: Color(0xFFA9DC76),
        yellow: Color(0xFFFFD866),
        blue: Color(0xFFFC9867),
        magenta: Color(0xFFAB9DF2),
        cyan: Color(0xFF78DCE8),
        white: Color(0xFFFCFCFA),
        brightBlack: Color(0xFF727072),
        brightRed: Color(0xFFFF6188),
        brightGreen: Color(0xFFA9DC76),
        brightYellow: Color(0xFFFFD866),
        brightBlue: Color(0xFFFC9867),
        brightMagenta: Color(0xFFAB9DF2),
        brightCyan: Color(0xFF78DCE8),
        brightWhite: Color(0xFFFCFCFA),
        searchHitBackground: Color(0xFFFFD866),
        searchHitBackgroundCurrent: Color(0xFFFF6188),
        searchHitForeground: Color(0xFF2D2A2E),
      ),
    ),
    'solarized': (
      name: 'Solarized Dark',
      theme: TerminalTheme(
        cursor: Color(0xCC268BD2),
        selection: Color(0x66073642),
        foreground: Color(0xFF93A1A1),
        background: Color(0xFF002B36),
        black: Color(0xFF073642),
        red: Color(0xFFDC322F),
        green: Color(0xFF859900),
        yellow: Color(0xFFB58900),
        blue: Color(0xFF268BD2),
        magenta: Color(0xFFD33682),
        cyan: Color(0xFF2AA198),
        white: Color(0xFFEEE8D5),
        brightBlack: Color(0xFF586E75),
        brightRed: Color(0xFFCB4B16),
        brightGreen: Color(0xFF859900),
        brightYellow: Color(0xFFB58900),
        brightBlue: Color(0xFF839496),
        brightMagenta: Color(0xFF6C71C4),
        brightCyan: Color(0xFF93A1A1),
        brightWhite: Color(0xFFFDF6E3),
        searchHitBackground: Color(0xFFB58900),
        searchHitBackgroundCurrent: Color(0xFFCB4B16),
        searchHitForeground: Color(0xFF002B36),
      ),
    ),
    'matrix': (
      name: 'Matrix 极客黑客绿',
      theme: TerminalTheme(
        cursor: Color(0xCC00FF66),
        selection: Color(0x66004D1A),
        foreground: Color(0xFF33FF77),
        background: Color(0xFF050A06),
        black: Color(0xFF0A140C),
        red: Color(0xFFFF4D4D),
        green: Color(0xFF00E65C),
        yellow: Color(0xFFB8FF4D),
        blue: Color(0xFF00B894),
        magenta: Color(0xFF55EFC4),
        cyan: Color(0xFF00CEC9),
        white: Color(0xFF80FFAA),
        brightBlack: Color(0xFF1F4D2B),
        brightRed: Color(0xFFFF7675),
        brightGreen: Color(0xFF55FF99),
        brightYellow: Color(0xFFD9FF80),
        brightBlue: Color(0xFF55EFC4),
        brightMagenta: Color(0xFF81ECEC),
        brightCyan: Color(0xFF74B9FF),
        brightWhite: Color(0xFFE6FFFA),
        searchHitBackground: Color(0xFFB8FF4D),
        searchHitBackgroundCurrent: Color(0xFFFF4D4D),
        searchHitForeground: Color(0xFF050A06),
      ),
    ),
    'github_light': (
      name: 'GitHub Light 护眼浅色',
      theme: TerminalTheme(
        cursor: Color(0xCC0969DA),
        selection: Color(0x440969DA),
        foreground: Color(0xFF24292F),
        background: Color(0xFFF6F8FA),
        black: Color(0xFF24292F),
        red: Color(0xFFCF222E),
        green: Color(0xFF116329),
        yellow: Color(0xFF4D2D00),
        blue: Color(0xFF0969DA),
        magenta: Color(0xFF8250DF),
        cyan: Color(0xFF1B7C83),
        white: Color(0xFF6E7781),
        brightBlack: Color(0xFF57606A),
        brightRed: Color(0xFFA40E26),
        brightGreen: Color(0xFF1A7F37),
        brightYellow: Color(0xFF633C01),
        brightBlue: Color(0xFF218BFF),
        brightMagenta: Color(0xFFA475F9),
        brightCyan: Color(0xFF3192AA),
        brightWhite: Color(0xFF8C959F),
        searchHitBackground: Color(0xFFFFF8C5),
        searchHitBackgroundCurrent: Color(0xFFFFDF5D),
        searchHitForeground: Color(0xFF24292F),
      ),
    ),
  };

  TerminalTheme get _activeXtermTheme =>
      (_terminalThemes[_terminalThemeId] ?? _terminalThemes['ocean']!).theme;

  _TerminalTabSession get _activeTab =>
      _tabs[_activeTabIndex.clamp(0, _tabs.length - 1)];

  List<TerminalHostProfile> _buildBuiltInHostProfiles() {
    return [
      const TerminalHostProfile(
        id: 'builtin_backend_ws',
        name: '流光服务端终端',
        group: '内置终端',
        kind: TerminalHostKind.backendWs,
        initialSftpPath: '',
      ),
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows)
        TerminalHostProfile(
          id: 'builtin_local_shell',
          name: '本机系统 Shell',
          group: '内置终端',
          kind: TerminalHostKind.localShell,
          initialSftpPath: Platform.environment['HOME'] ?? '/',
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    _hostProfiles = _buildBuiltInHostProfiles();
    // 重要：打开终端页面时默认不自动连接！仅初始化待连接标签页，由用户主动点击连接或选择主机连接。
    _createNewTab(
      profile: _hostProfiles.first,
      autoConnect: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSavedPreferencesAndHosts();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _sftpPathCtrl.dispose();
    _sftpFilterCtrl.dispose();
    _commandInputCtrl.dispose();
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  TerminalHostProfile _resolveProfileById(String id) {
    return _hostProfiles.where((p) => p.id == id).firstOrNull ??
        _hostProfiles.first;
  }

  void _createNewTab({
    TerminalHostProfile? profile,
    bool autoConnect = false,
  }) {
    final tabId = _nextTabId++;
    final targetProfile =
        profile ?? _resolveProfileById(_selectedProfileIdForNewConnect);
    late final _TerminalTabSession session;
    session = _TerminalTabSession(
      id: tabId,
      label: '${targetProfile.name} #$tabId',
      hostProfile: targetProfile,
      onOutput: (data) => _handleTerminalUserInput(session, data),
      onResize: (cols, rows) => _sendResize(session, cols, rows),
      onTitleChange: (title) {
        if (mounted && title.trim().isNotEmpty) {
          setState(() => session.sessionMeta = title.trim());
        }
      },
    );

    session.terminal.write(
      '\x1b[38;2;121;221;208m╭──────────────────────────────────────────────────────────────╮\x1b[0m\r\n',
    );
    session.terminal.write(
      '\x1b[38;2;121;221;208m│  流光全功能终端 & SFTP 工作台 (${session.label})\x1b[0m\r\n',
    );
    session.terminal.write(
      '\x1b[38;2;121;221;208m│  目标主机: ${targetProfile.subtitle}\x1b[0m\r\n',
    );
    session.terminal.write(
      '\x1b[38;2;121;221;208m│  当前状态: 默认待连接（点击上方「连接终端」或下方主机卡片启动）\x1b[0m\r\n',
    );
    session.terminal.write(
      '\x1b[38;2;121;221;208m╰──────────────────────────────────────────────────────────────╯\x1b[0m\r\n',
    );

    setState(() {
      _tabs.add(session);
      _activeTabIndex = _tabs.length - 1;
      _sftpPathCtrl.text = session.sftpCurrentPath;
    });

    if (autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _connectTab(session);
      });
    }
  }

  Future<void> _closeTab(int index) async {
    if (_tabs.length <= 1) {
      await _disconnectTab(_activeTab);
      _clearTerminal(_activeTab);
      return;
    }
    final removed = _tabs.removeAt(index);
    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    }
    setState(() {
      _sftpPathCtrl.text = _activeTab.sftpCurrentPath;
    });
    await removed.dispose();
    _activeTab.focusNode.requestFocus();
  }

  // ===========================================================================
  // Persistence: Hosts, Snippets, Command History, Theme & Font Size
  // ===========================================================================

  Future<void> _loadSavedPreferencesAndHosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTheme = prefs.getString(_prefTerminalThemeKey);
      final savedSize = prefs.getDouble(_prefTerminalFontSizeKey);
      final savedHistory = prefs.getStringList(_prefCmdHistoryKey);
      final savedHostsRaw = prefs.getString(_prefSshHostsKey);
      final customHosts = <TerminalHostProfile>[];
      if (savedHostsRaw != null && savedHostsRaw.isNotEmpty) {
        final decoded = jsonDecode(savedHostsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final p = TerminalHostProfile.fromJson(item);
              if (!p.isBuiltIn) customHosts.add(p);
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _hostProfiles = [..._buildBuiltInHostProfiles(), ...customHosts];
          if (savedTheme != null && _terminalThemes.containsKey(savedTheme)) {
            _terminalThemeId = savedTheme;
          }
          if (savedSize != null) {
            _fontSize = savedSize.clamp(11.0, 24.0);
          }
          if (savedHistory != null) {
            _commandHistory = savedHistory;
          }
        });
      }

      final rawSnippets = prefs.getString(_prefCustomSnippetsKey);
      if (rawSnippets != null && rawSnippets.isNotEmpty) {
        final decoded = jsonDecode(rawSnippets);
        if (decoded is List && mounted) {
          final loaded = <({String label, String command})>[];
          for (final item in decoded) {
            if (item is Map) {
              final l = (item['l'] ?? '').toString().trim();
              final c = (item['c'] ?? '').toString();
              if (l.isNotEmpty && c.isNotEmpty) {
                loaded.add((label: l, command: c));
              }
            }
          }
          if (loaded.isNotEmpty) {
            setState(() => _quickSnippets = loaded);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _persistCustomHosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = _hostProfiles
          .where((p) => !p.isBuiltIn)
          .map((p) => p.toJson())
          .toList();
      await prefs.setString(_prefSshHostsKey, jsonEncode(custom));
    } catch (_) {}
  }

  Future<void> _saveCustomSnippets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          _quickSnippets.map((s) => {'l': s.label, 'c': s.command}).toList();
      await prefs.setString(_prefCustomSnippetsKey, jsonEncode(encoded));
    } catch (_) {}
  }

  Future<void> _saveTerminalAppearance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefTerminalThemeKey, _terminalThemeId);
      await prefs.setDouble(_prefTerminalFontSizeKey, _fontSize);
    } catch (_) {}
  }

  Future<void> _recordCommandHistory(String cmd) async {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) return;
    _commandHistory.remove(trimmed);
    _commandHistory.insert(0, trimmed);
    if (_commandHistory.length > 80) {
      _commandHistory = _commandHistory.sublist(0, 80);
    }
    _historyCursor = -1;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefCmdHistoryKey, _commandHistory);
    } catch (_) {}
  }

  // ===========================================================================
  // Connection Engines: 1) Backend WebSocket, 2) SSH2 + SFTP, 3) Local Shell
  // ===========================================================================

  Future<void> _connectTab(
    _TerminalTabSession tab, {
    TerminalHostProfile? overrideProfile,
  }) async {
    if (tab.isConnecting) return;
    if (tab.isConnected) {
      await _disconnectTab(tab, silent: true);
    }
    if (overrideProfile != null) {
      tab.hostProfile = overrideProfile;
      tab.label = '${overrideProfile.name} #${tab.id}';
      tab.sftpCurrentPath = overrideProfile.initialSftpPath.trim().isEmpty
          ? (overrideProfile.kind == TerminalHostKind.backendWs ? '' : '/')
          : overrideProfile.initialSftpPath.trim();
    }

    setState(() {
      tab.isConnecting = true;
      tab.statusText = '正在连接 ${tab.hostProfile.name}...';
      tab.sessionMeta = '';
    });

    if (tab.sessionCount > 0) {
      tab.terminal.write('\r\n\x1b[90m──── 建立新会话 (${tab.hostProfile.name}) ────\x1b[0m\r\n');
    }

    switch (tab.hostProfile.kind) {
      case TerminalHostKind.backendWs:
        await _connectBackendWebSocketTab(tab);
        break;
      case TerminalHostKind.ssh2:
        await _connectSsh2AndSftpTab(tab);
        break;
      case TerminalHostKind.localShell:
        await _connectLocalShellTab(tab);
        break;
    }
  }

  Future<void> _connectBackendWebSocketTab(_TerminalTabSession tab) async {
    try {
      final ws = await widget.appState.api.connectTerminalWebSocket();
      if (!mounted) {
        await ws.close();
        return;
      }

      tab.wsSocket = ws;
      setState(() {
        tab.isConnecting = false;
        tab.isConnected = true;
        tab.sessionCount += 1;
        tab.statusText = '已连接 (流光服务端)';
      });

      _sendResize(tab, tab.lastCols, tab.lastRows);
      if (tab == _activeTab) {
        tab.focusNode.requestFocus();
      }

      tab.wsSub = ws.listen(
        (dynamic event) {
          if (!mounted) return;
          if (event is String) {
            _handleTextFrame(tab, event);
          } else if (event is List<int>) {
            tab.terminal.write(utf8.decode(event, allowMalformed: true));
          }
        },
        onError: (Object err) {
          if (!mounted) return;
          setState(() {
            tab.isConnected = false;
            tab.isConnecting = false;
            tab.statusText = '连接异常：$err';
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            tab.wsSocket = null;
            tab.isConnected = false;
            tab.isConnecting = false;
            if (tab.statusText.startsWith('已连接')) {
              tab.statusText = '已断开';
            }
          });
        },
      );

      if (tab.hostProfile.startupCommand.trim().isNotEmpty) {
        _sendToSingleTab(tab, '${tab.hostProfile.startupCommand.trim()}\n');
      }

      // Load Server File Manager into SFTP pane
      unawaited(_loadSftpDirectory(tab, tab.sftpCurrentPath));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.isConnecting = false;
        tab.isConnected = false;
        tab.statusText = '连接失败：$e';
      });
      tab.terminal.write('\r\n\x1b[31m连接失败：$e\x1b[0m\r\n');
    }
  }

  Future<void> _connectSsh2AndSftpTab(_TerminalTabSession tab) async {
    final p = tab.hostProfile;
    try {
      tab.terminal.write(
        '\x1b[36m正在建立 SSH2 加密连接 ${p.username}@${p.host}:${p.port} ...\x1b[0m\r\n',
      );
      final socket = await SSHSocket.connect(
        p.host.trim(),
        p.port,
        timeout: const Duration(seconds: 15),
      );

      List<SSHKeyPair>? keyPairs;
      if (p.authType == 'privateKey' && p.privateKeyPem.trim().isNotEmpty) {
        keyPairs = SSHKeyPair.fromPem(
          p.privateKeyPem.trim(),
          p.passphrase.isEmpty ? null : p.passphrase,
        );
      }

      final client = SSHClient(
        socket,
        username: p.username.trim(),
        identities: keyPairs,
        onPasswordRequest: () => p.password,
        onUserInfoRequest: (req) {
          if (req.prompts.isEmpty) return const <String>[];
          return List<String>.filled(req.prompts.length, p.password);
        },
        onUserauthBanner: (banner) {
          if (mounted && banner.trim().isNotEmpty) {
            tab.terminal.write('\x1b[90m${banner.replaceAll('\n', '\r\n')}\x1b[0m\r\n');
          }
        },
      );

      final shell = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: tab.lastCols.clamp(40, 500),
          height: tab.lastRows.clamp(12, 200),
        ),
      );

      SftpClient? sftp;
      try {
        sftp = await client.sftp();
      } catch (sftpErr) {
        tab.terminal.write(
          '\x1b[33m[提示] SFTP 子系统初始化失败 ($sftpErr)，仅启用 SSH Shell。\x1b[0m\r\n',
        );
      }

      if (!mounted) {
        client.close();
        return;
      }

      tab.sshClient = client;
      tab.sshShellSession = shell;
      tab.sftpClient = sftp;

      setState(() {
        tab.isConnecting = false;
        tab.isConnected = true;
        tab.sessionCount += 1;
        tab.statusText = '已连接 SSH2 + SFTP (${p.username}@${p.host})';
        tab.sessionMeta = '${p.username}@${p.host}:${p.port}';
      });

      tab.sshStdoutSub = shell.stdout.listen((Uint8List chunk) {
        if (!mounted) return;
        tab.terminal.write(utf8.decode(chunk, allowMalformed: true));
      });
      tab.sshStderrSub = shell.stderr.listen((Uint8List chunk) {
        if (!mounted) return;
        tab.terminal.write(utf8.decode(chunk, allowMalformed: true));
      });

      unawaited(
        shell.done.then((_) {
          if (!mounted) return;
          setState(() {
            tab.isConnected = false;
            tab.isConnecting = false;
            tab.statusText =
                'SSH 会话已结束${shell.exitCode != null ? " (退出码 ${shell.exitCode})" : ""}';
          });
        }),
      );

      if (p.startupCommand.trim().isNotEmpty) {
        _sendToSingleTab(tab, '${p.startupCommand.trim()}\n');
      }

      if (tab == _activeTab) {
        tab.focusNode.requestFocus();
      }

      // Initialize SFTP directory & start live server monitor
      if (sftp != null) {
        try {
          final startDir = p.initialSftpPath.trim().isEmpty
              ? await sftp.absolute('.')
              : p.initialSftpPath.trim();
          unawaited(_loadSftpDirectory(tab, startDir));
        } catch (_) {
          unawaited(_loadSftpDirectory(tab, '/'));
        }
      }
      _startSshLiveMetricsPolling(tab);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.isConnecting = false;
        tab.isConnected = false;
        tab.statusText = 'SSH 连接失败：$e';
      });
      tab.terminal.write('\r\n\x1b[31mSSH 连接失败：$e\x1b[0m\r\n');
    }
  }

  Future<void> _connectLocalShellTab(_TerminalTabSession tab) async {
    try {
      final shellBin = Platform.isWindows
          ? 'powershell.exe'
          : (Platform.environment['SHELL'] ??
              (await File('/bin/zsh').exists() ? '/bin/zsh' : '/bin/bash'));
      final homeDir =
          Platform.environment['HOME'] ?? Directory.current.path;

      final proc = await Process.start(
        shellBin,
        Platform.isWindows ? const [] : const ['-i'],
        workingDirectory: homeDir,
        environment: {
          ...Platform.environment,
          'TERM': 'xterm-256color',
          'LANG': 'en_US.UTF-8',
        },
      );

      if (!mounted) {
        proc.kill();
        return;
      }

      tab.localProcess = proc;
      setState(() {
        tab.isConnecting = false;
        tab.isConnected = true;
        tab.sessionCount += 1;
        tab.statusText = '已启动本机 Shell ($shellBin)';
        tab.sessionMeta = '$shellBin · $homeDir';
      });

      tab.localStdoutSub = proc.stdout.listen((List<int> data) {
        if (!mounted) return;
        tab.terminal.write(
          utf8.decode(data, allowMalformed: true).replaceAll('\n', '\r\n'),
        );
      });
      tab.localStderrSub = proc.stderr.listen((List<int> data) {
        if (!mounted) return;
        tab.terminal.write(
          utf8.decode(data, allowMalformed: true).replaceAll('\n', '\r\n'),
        );
      });
      unawaited(
        proc.exitCode.then((code) {
          if (!mounted) return;
          setState(() {
            tab.isConnected = false;
            tab.isConnecting = false;
            tab.statusText = '本机 Shell 已退出 ($code)';
          });
        }),
      );

      unawaited(_loadSftpDirectory(tab, homeDir));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.isConnecting = false;
        tab.isConnected = false;
        tab.statusText = '启动本机 Shell 失败：$e';
      });
      tab.terminal.write('\r\n\x1b[31m启动本机 Shell 失败：$e\x1b[0m\r\n');
    }
  }

  void _startSshLiveMetricsPolling(_TerminalTabSession tab) {
    tab.metricsTimer?.cancel();
    Future<void> pollOnce() async {
      final client = tab.sshClient;
      if (client == null || !tab.isConnected || !mounted) return;
      try {
        const script = r'''
echo "LOAD:$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || uptime | awk -F'load average:' '{print $2}')"
echo "MEM:$(free -m 2>/dev/null | awk '/Mem:/ {printf "%d/%dMB (%.0f%%)|%.3f", $3, $2, ($2>0?$3*100/$2:0), ($2>0?$3/$2:0)}')"
echo "DISK:$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)|%s", $3, $2, $5, $5}')"
echo "UP:$(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}')"
echo "KERN:$(uname -sr 2>/dev/null)"
''';
        final bytes = await client.run(script);
        final out = utf8.decode(bytes, allowMalformed: true);
        String loadAvg = '--';
        String memText = '--';
        double memRatio = 0.0;
        String diskText = '--';
        double diskRatio = 0.0;
        String uptimeText = '--';
        String kernelText = '';

        for (final rawLine in out.split('\n')) {
          final line = rawLine.trim();
          if (line.startsWith('LOAD:')) {
            final v = line.substring(5).trim();
            if (v.isNotEmpty) loadAvg = v;
          } else if (line.startsWith('MEM:')) {
            final v = line.substring(4).trim();
            final parts = v.split('|');
            if (parts.isNotEmpty && parts[0].isNotEmpty) memText = parts[0];
            if (parts.length > 1) {
              memRatio = (double.tryParse(parts[1]) ?? 0.0).clamp(0.0, 1.0);
            }
          } else if (line.startsWith('DISK:')) {
            final v = line.substring(5).trim();
            final parts = v.split('|');
            if (parts.isNotEmpty && parts[0].isNotEmpty) diskText = parts[0];
            if (parts.length > 1) {
              final pct =
                  double.tryParse(parts[1].replaceAll('%', '').trim()) ?? 0.0;
              diskRatio = (pct / 100.0).clamp(0.0, 1.0);
            }
          } else if (line.startsWith('UP:')) {
            final v = line.substring(3).trim();
            if (v.isNotEmpty) uptimeText = v;
          } else if (line.startsWith('KERN:')) {
            kernelText = line.substring(5).trim();
          }
        }
        if (mounted) {
          setState(() {
            tab.metrics = ServerLiveMetrics(
              loadAvg: loadAvg,
              memText: memText,
              memRatio: memRatio,
              diskText: diskText,
              diskRatio: diskRatio,
              uptimeText: uptimeText,
              kernelText: kernelText,
            );
          });
        }
      } catch (_) {}
    }

    unawaited(pollOnce());
    tab.metricsTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => pollOnce(),
    );
  }

  // ===========================================================================
  // Terminal I/O, Modifiers, Resize & Disconnect
  // ===========================================================================

  void _sendToSingleTab(_TerminalTabSession tab, String data) {
    if (!tab.isConnected) return;
    final bytes = utf8.encode(data);

    if (tab.wsSocket != null) {
      for (var offset = 0; offset < bytes.length; offset += _maxInputFrameBytes) {
        final end = (offset + _maxInputFrameBytes < bytes.length)
            ? offset + _maxInputFrameBytes
            : bytes.length;
        tab.wsSocket!.add(bytes.sublist(offset, end));
      }
      return;
    }

    if (tab.sshShellSession != null) {
      tab.sshShellSession!.write(Uint8List.fromList(bytes));
      return;
    }

    if (tab.localProcess != null) {
      tab.localProcess!.stdin.add(bytes);
      return;
    }
  }

  void _handleTerminalUserInput(_TerminalTabSession tab, String rawData) {
    var data = rawData;
    // Apply virtual modifier locks (CTRL / ALT) for single character key presses
    if (_ctrlLocked && data.length == 1) {
      final code = data.toUpperCase().codeUnitAt(0);
      if (code >= 64 && code <= 95) {
        data = String.fromCharCode(code - 64);
      }
      setState(() => _ctrlLocked = false);
    } else if (_altLocked && data.isNotEmpty) {
      data = '\x1b$data';
      setState(() => _altLocked = false);
    }

    if (_broadcastToAllTabs && _tabs.length > 1) {
      for (final t in _tabs) {
        if (t.isConnected) {
          _sendToSingleTab(t, data);
        }
      }
      return;
    }
    _sendToSingleTab(tab, data);
  }

  void _sendResize(_TerminalTabSession tab, int cols, int rows) {
    if (!tab.isConnected) return;
    final safeCols = cols.clamp(2, 500);
    final safeRows = rows.clamp(2, 200);
    if (tab.wsSocket != null) {
      tab.wsSocket!.add(
        jsonEncode({'type': 'resize', 'cols': safeCols, 'rows': safeRows}),
      );
    } else if (tab.sshShellSession != null) {
      tab.sshShellSession!.resizeTerminal(safeCols, safeRows);
    }
  }

  void _handleTextFrame(_TerminalTabSession tab, String frame) {
    try {
      final parsed = jsonDecode(frame);
      if (parsed is Map<String, dynamic>) {
        final type = (parsed['type'] ?? '').toString();
        if (type == 'output') {
          tab.terminal.write((parsed['data'] ?? '').toString());
          return;
        }
        if (type == 'ready') {
          final shell = (parsed['shell'] ?? '').toString();
          final cwd = (parsed['cwd'] ?? '').toString();
          setState(() {
            tab.sessionMeta =
                [shell, cwd].where((s) => s.isNotEmpty).join(' · ');
          });
          return;
        }
        if (type == 'title') {
          setState(() {
            tab.sessionMeta = (parsed['title'] ?? '').toString();
          });
          return;
        }
        if (type == 'error') {
          final msg = (parsed['message'] ?? '终端会话发生错误').toString();
          setState(() => tab.statusText = msg);
          tab.terminal.write('\r\n\x1b[31m$msg\x1b[0m\r\n');
          return;
        }
        if (type == 'exit') {
          final code = parsed['code'];
          setState(() {
            tab.statusText = '会话已结束${code != null ? "（退出码 $code）" : ""}';
          });
          return;
        }
      }
    } catch (_) {}
    tab.terminal.write(frame);
  }

  Future<void> _disconnectTab(
    _TerminalTabSession tab, {
    bool silent = false,
  }) async {
    await tab.disconnectResources();
    if (!silent && mounted) {
      setState(() {
        tab.isConnected = false;
        tab.isConnecting = false;
        tab.statusText = '已断开连接';
      });
    }
  }

  void _clearTerminal(_TerminalTabSession tab) {
    tab.clearHighlights();
    tab.terminal.buffer.clear();
    tab.terminal.buffer.setCursor(0, 0);
    tab.terminal.write('\x1b[2J\x1b[H');
    if (tab.isConnected) {
      _handleTerminalUserInput(tab, '\x0c');
    }
    tab.focusNode.requestFocus();
  }

  // ===========================================================================
  // SFTP & Remote File Operations (Works across SSH2 SFTP, Server API & Local)
  // ===========================================================================

  static String _joinPosixPath(String base, String child) {
    if (base.isEmpty || base == '/') return '/$child';
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$cleanBase/$child';
  }

  static String _parentPosixPath(String path) {
    final clean = path.trim();
    if (clean.isEmpty || clean == '/') return '/';
    final trimmed =
        clean.endsWith('/') ? clean.substring(0, clean.length - 1) : clean;
    final idx = trimmed.lastIndexOf('/');
    if (idx <= 0) return '/';
    return trimmed.substring(0, idx);
  }

  Future<void> _loadSftpDirectory(
    _TerminalTabSession tab,
    String targetPath,
  ) async {
    setState(() {
      tab.isLoadingSftp = true;
      tab.sftpError = null;
    });

    try {
      final items = <SftpEntryItem>[];
      String resolvedPath = targetPath.trim();

      if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
        final sftp = tab.sftpClient;
        if (sftp == null) {
          throw Exception('尚未建立 SFTP 会话，请先连接 SSH 主机');
        }
        if (resolvedPath.isEmpty) resolvedPath = '/';
        try {
          resolvedPath = await sftp.absolute(resolvedPath);
        } catch (_) {}
        final list = await sftp.listdir(resolvedPath);
        for (final entry in list) {
          if (entry.filename == '.' || entry.filename == '..') continue;
          final attr = entry.attr;
          final isDir = attr.isDirectory;
          final isSym = attr.isSymbolicLink;
          final size = attr.size ?? 0;
          String modStr = '';
          if (attr.modifyTime != null && attr.modifyTime! > 0) {
            final dt = DateTime.fromMillisecondsSinceEpoch(
              attr.modifyTime! * 1000,
            );
            modStr =
                '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
                '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          }
          items.add(
            SftpEntryItem(
              name: entry.filename,
              path: _joinPosixPath(resolvedPath, entry.filename),
              isDir: isDir,
              isSymlink: isSym,
              size: size,
              permissions: attr.mode?.value,
              modTimeText: modStr,
              longname: entry.longname,
            ),
          );
        }
      } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
        final listing =
            await widget.appState.api.fetchFiles(path: resolvedPath);
        resolvedPath = listing.path.isEmpty ? '/' : listing.path;
        for (final e in listing.entries) {
          items.add(
            SftpEntryItem(
              name: e.name,
              path: e.path,
              isDir: e.isDir,
              size: e.size,
              modTimeText: e.modTime,
            ),
          );
        }
      } else {
        // Local Shell file system
        if (resolvedPath.isEmpty) {
          resolvedPath = Platform.environment['HOME'] ?? '/';
        }
        final dir = Directory(resolvedPath);
        resolvedPath = dir.absolute.path;
        final entities = await dir.list(followLinks: false).toList();
        for (final ent in entities) {
          final name = ent.path
                  .split(RegExp(r'[/\\]'))
                  .where((s) => s.isNotEmpty)
                  .lastOrNull ??
              '';
          if (name.isEmpty) continue;
          final stat = await ent.stat();
          final isDir = stat.type == FileSystemEntityType.directory;
          final dt = stat.modified;
          final modStr =
              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          items.add(
            SftpEntryItem(
              name: name,
              path: ent.path,
              isDir: isDir,
              isSymlink: stat.type == FileSystemEntityType.link,
              size: isDir ? 0 : stat.size,
              permissions: stat.mode,
              modTimeText: modStr,
            ),
          );
        }
      }

      items.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        tab.sftpCurrentPath = resolvedPath;
        tab.sftpEntries = items;
        tab.isLoadingSftp = false;
        if (tab == _activeTab) {
          _sftpPathCtrl.text = resolvedPath;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.isLoadingSftp = false;
        tab.sftpError = '$e';
      });
    }
  }

  Future<String> _readSftpTextFile(
    _TerminalTabSession tab,
    SftpEntryItem item,
  ) async {
    if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
      final sftp = tab.sftpClient;
      if (sftp == null) throw Exception('SFTP 未连接');
      final remoteFile = await sftp.open(
        item.path,
        mode: SftpFileOpenMode.read,
      );
      try {
        final bytes = await remoteFile.readBytes(length: 2 * 1024 * 1024);
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await remoteFile.close();
      }
    } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
      final url = widget.appState.api.buildFileStreamUrl(item.path);
      final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
      try {
        final req = await client.getUrl(Uri.parse(url));
        widget.appState.api.authHeaders.forEach(req.headers.set);
        final resp = await req.close();
        final bytes =
            await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        client.close(force: true);
      }
    } else {
      return await File(item.path).readAsString();
    }
  }

  Future<void> _writeSftpTextFile(
    _TerminalTabSession tab,
    String remotePath,
    String content,
  ) async {
    final data = Uint8List.fromList(utf8.encode(content));
    if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
      final sftp = tab.sftpClient;
      if (sftp == null) throw Exception('SFTP 未连接');
      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await remoteFile.writeBytes(data);
      } finally {
        await remoteFile.close();
      }
    } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
      final tmpFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}sftp_edit_${DateTime.now().millisecondsSinceEpoch}.tmp',
      );
      await tmpFile.writeAsBytes(data);
      try {
        final fileName = remotePath.split('/').last;
        final dirPath = _parentPosixPath(remotePath);
        await RemoteStorageService.instance.uploadWithProgress(
          targetMount: const StorageMount(
            id: 'builtin_server',
            name: '流光服务端',
            kind: StorageSourceKind.server,
            rootPath: '/',
          ),
          targetDir: dirPath == '/' ? '' : dirPath,
          fileName: fileName,
          localFilePath: tmpFile.path,
          serverApi: widget.appState.api,
          isCancelled: () => false,
          onProgress: (_, __, ___) {},
        );
      } finally {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
    } else {
      await File(remotePath).writeAsBytes(data);
    }
  }

  Future<void> _openSftpTextEditorDialog(
    _TerminalTabSession tab,
    SftpEntryItem item,
  ) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SftpOnlineEditorDialog(
        fileName: item.name,
        remotePath: item.path,
        loadContent: () => _readSftpTextFile(tab, item),
        saveContent: (newContent) async {
          await _writeSftpTextFile(tab, item.path, newContent);
          await _loadSftpDirectory(tab, tab.sftpCurrentPath);
        },
      ),
    );
  }

  Future<void> _downloadSftpFileToLocal(
    _TerminalTabSession tab,
    SftpEntryItem item,
  ) async {
    final dlRoot = RemoteStorageService.defaultLocalDownloadsRoot();
    final localDir = Directory(dlRoot);
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }
    final localPath = '$dlRoot${Platform.pathSeparator}${item.name}';
    final transfer = SftpTransferProgressItem(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      fileName: item.name,
      isUpload: false,
      totalBytes: item.size,
      detail: '正在下载至 $localPath',
    );
    setState(() {
      tab.sftpTransfers.insert(0, transfer);
    });

    try {
      if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
        final sftp = tab.sftpClient;
        if (sftp == null) throw Exception('SFTP 未连接');
        final remoteFile = await sftp.open(
          item.path,
          mode: SftpFileOpenMode.read,
        );
        final outFile = File(localPath);
        final sink = outFile.openWrite();
        try {
          var received = 0;
          await for (final chunk in remoteFile.read()) {
            sink.add(chunk);
            received += chunk.length;
            if (mounted) {
              setState(() {
                transfer.transferredBytes = received;
              });
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
          await remoteFile.close();
        }
      } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
        final url = widget.appState.api.buildFileStreamUrl(item.path);
        await RemoteStorageService.instance.downloadStreamWithProgress(
          uri: Uri.parse(url),
          headers: widget.appState.api.authHeaders,
          destinationPath: localPath,
          expectedSizeHint: item.size,
          isCancelled: () => false,
          onProgress: (rec, tot, _) {
            if (mounted) {
              setState(() {
                transfer.transferredBytes = rec;
                if (tot > 0) transfer.totalBytes = tot;
              });
            }
          },
        );
      } else {
        await File(item.path).copy(localPath);
      }

      if (!mounted) return;
      setState(() {
        transfer.status = 'completed';
        transfer.transferredBytes = transfer.totalBytes;
        transfer.detail = '✓ 已保存至 $localPath';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✓ 已通过 SFTP 下载保存至：$localPath')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        transfer.status = 'failed';
        transfer.detail = '下载失败：$e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('SFTP 下载失败：$e')),
      );
    }
  }

  Future<void> _showUploadLocalFileToSftpDialog(_TerminalTabSession tab) async {
    final localPathCtrl = TextEditingController(
      text: RemoteStorageService.defaultLocalDownloadsRoot(),
    );
    List<FileSystemEntity> localFiles = [];

    Future<void> listLocalDir(String dirPath, StateSetter setModalState) async {
      try {
        final d = Directory(dirPath);
        if (await d.exists()) {
          final list = await d.list(followLinks: false).toList();
          list.sort((a, b) => a.path.compareTo(b.path));
          setModalState(() => localFiles = list);
        }
      } catch (_) {}
    }

    final chosenLocalFile = await showDialog<File>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          if (localFiles.isEmpty) {
            listLocalDir(localPathCtrl.text, setModalState);
          }
          return AlertDialog(
            backgroundColor: VideoPlatformTheme.bgElevated,
            title: Text(
              '选择本机文件上传至 SFTP (${tab.sftpCurrentPath})',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            content: SizedBox(
              width: 620,
              height: 400,
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '上级目录',
                        onPressed: () {
                          final parent =
                              Directory(localPathCtrl.text).parent.path;
                          localPathCtrl.text = parent;
                          listLocalDir(parent, setModalState);
                        },
                        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                      ),
                      Expanded(
                        child: TextField(
                          controller: localPathCtrl,
                          onSubmitted: (v) => listLocalDir(v, setModalState),
                          decoration: const InputDecoration(
                            labelText: '本机目录路径 (回车跳转)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: VideoPlatformTheme.borderSubtle),
                      ),
                      child: ListView.separated(
                        itemCount: localFiles.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: VideoPlatformTheme.borderSubtle,
                        ),
                        itemBuilder: (_, idx) {
                          final ent = localFiles[idx];
                          final name = ent.path
                                  .split(RegExp(r'[/\\]'))
                                  .where((s) => s.isNotEmpty)
                                  .lastOrNull ??
                              ent.path;
                          final isDir = ent is Directory;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              isDir
                                  ? Icons.folder_rounded
                                  : Icons.insert_drive_file_rounded,
                              color: isDir
                                  ? VideoPlatformTheme.warning
                                  : VideoPlatformTheme.accent,
                            ),
                            title: Text(name, maxLines: 1),
                            trailing: isDir
                                ? null
                                : FilledButton.tonal(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(File(ent.path)),
                                    child: const Text('上传此文件'),
                                  ),
                            onTap: () {
                              if (isDir) {
                                localPathCtrl.text = ent.path;
                                listLocalDir(ent.path, setModalState);
                              } else {
                                Navigator.of(ctx).pop(File(ent.path));
                              }
                            },
                          );
                        },
                      ),
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
            ],
          );
        },
      ),
    );

    localPathCtrl.dispose();
    if (chosenLocalFile == null || !await chosenLocalFile.exists()) return;

    final fileName = chosenLocalFile.path
            .split(RegExp(r'[/\\]'))
            .where((s) => s.isNotEmpty)
            .lastOrNull ??
        'upload.bin';
    final fileSize = await chosenLocalFile.length();
    final remoteTarget = _joinPosixPath(tab.sftpCurrentPath, fileName);

    final transfer = SftpTransferProgressItem(
      id: 'up_${DateTime.now().millisecondsSinceEpoch}',
      fileName: fileName,
      isUpload: true,
      totalBytes: fileSize,
      detail: '正在上传至 $remoteTarget',
    );
    setState(() {
      tab.sftpTransfers.insert(0, transfer);
    });

    try {
      if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
        final sftp = tab.sftpClient;
        if (sftp == null) throw Exception('SFTP 未连接');
        final remoteFile = await sftp.open(
          remoteTarget,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        try {
          final stream =
              chosenLocalFile.openRead().map((c) => Uint8List.fromList(c));
          final writer = remoteFile.write(
            stream,
            onProgress: (sent) {
              if (mounted) {
                setState(() {
                  transfer.transferredBytes = sent;
                });
              }
            },
          );
          await writer.done;
        } finally {
          await remoteFile.close();
        }
      } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
        await RemoteStorageService.instance.uploadWithProgress(
          targetMount: const StorageMount(
            id: 'builtin_server',
            name: '流光服务端',
            kind: StorageSourceKind.server,
            rootPath: '/',
          ),
          targetDir: tab.sftpCurrentPath == '/' ? '' : tab.sftpCurrentPath,
          fileName: fileName,
          localFilePath: chosenLocalFile.path,
          serverApi: widget.appState.api,
          isCancelled: () => false,
          onProgress: (sent, tot, _) {
            if (mounted) {
              setState(() {
                transfer.transferredBytes = sent;
                if (tot > 0) transfer.totalBytes = tot;
              });
            }
          },
        );
      } else {
        await chosenLocalFile.copy(remoteTarget);
      }

      if (!mounted) return;
      setState(() {
        transfer.status = 'completed';
        transfer.transferredBytes = transfer.totalBytes;
        transfer.detail = '✓ 已上传至 $remoteTarget';
      });
      await _loadSftpDirectory(tab, tab.sftpCurrentPath);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        transfer.status = 'failed';
        transfer.detail = '上传失败：$e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('SFTP 上传失败：$e')),
      );
    }
  }

  Future<void> _createSftpDirectoryOrFile(
    _TerminalTabSession tab, {
    required bool isDirectory,
  }) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Text(
          isDirectory ? 'SFTP 新建远程文件夹' : 'SFTP 新建远程空白文件',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          decoration: InputDecoration(
            labelText: isDirectory ? '文件夹名称' : '文件名 (例如 config.yaml / run.sh)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;

    final targetPath = _joinPosixPath(tab.sftpCurrentPath, name);
    try {
      if (isDirectory) {
        if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
          await tab.sftpClient!.mkdir(targetPath);
        } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
          await widget.appState.api.createDirectory(
            tab.sftpCurrentPath == '/' ? '' : tab.sftpCurrentPath,
            name,
          );
        } else {
          await Directory(targetPath).create(recursive: true);
        }
      } else {
        await _writeSftpTextFile(tab, targetPath, '');
      }
      await _loadSftpDirectory(tab, tab.sftpCurrentPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：$e')),
        );
      }
    }
  }

  Future<void> _renameSftpEntry(
    _TerminalTabSession tab,
    SftpEntryItem item,
  ) async {
    final ctrl = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Text(
          '重命名：${item.name}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          decoration: const InputDecoration(labelText: '新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || newName.isEmpty || newName == item.name) return;

    try {
      if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
        final newPath = _joinPosixPath(tab.sftpCurrentPath, newName);
        await tab.sftpClient!.rename(item.path, newPath);
      } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
        await widget.appState.api.renameFile(item.path, newName);
      } else {
        final newPath = _joinPosixPath(tab.sftpCurrentPath, newName);
        if (item.isDir) {
          await Directory(item.path).rename(newPath);
        } else {
          await File(item.path).rename(newPath);
        }
      }
      await _loadSftpDirectory(tab, tab.sftpCurrentPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败：$e')),
        );
      }
    }
  }

  Future<void> _chmodSftpEntry(
    _TerminalTabSession tab,
    SftpEntryItem item,
  ) async {
    final ctrl = TextEditingController(text: item.octalPermissions);
    final newOctal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Text(
          '修改权限 (chmod)：${item.name}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '八进制权限值 (如 0755 / 0644 / 0777 / 0600)',
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final preset in const [
                  ('0755 (可执行/目录)', '0755'),
                  ('0644 (普通文件)', '0644'),
                  ('0777 (完全读写)', '0777'),
                  ('0600 (仅所有者)', '0600'),
                ])
                  ActionChip(
                    label: Text(preset.$1, style: const TextStyle(fontSize: 11)),
                    onPressed: () => ctrl.text = preset.$2,
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('应用权限'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newOctal == null || newOctal.isEmpty) return;

    try {
      final modeInt = int.parse(newOctal, radix: 8);
      if (tab.hostProfile.kind == TerminalHostKind.ssh2 &&
          tab.sftpClient != null) {
        await tab.sftpClient!.setStat(
          item.path,
          SftpFileAttrs(mode: SftpFileMode.value(modeInt)),
        );
      } else if (tab.isConnected) {
        _sendToSingleTab(tab, 'chmod $newOctal "${item.path}"\n');
      }
      await _loadSftpDirectory(tab, tab.sftpCurrentPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✓ 已将 ${item.name} 权限更新为 $newOctal')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('修改权限失败：$e')),
        );
      }
    }
  }

  Future<void> _deleteSftpEntry(
    _TerminalTabSession tab,
    SftpEntryItem item,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text('确认删除远程文件/目录？', style: TextStyle(fontSize: 15)),
        content: Text('即将永久删除「${item.path}」，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VideoPlatformTheme.danger,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      if (tab.hostProfile.kind == TerminalHostKind.ssh2) {
        if (item.isDir) {
          try {
            await tab.sftpClient!.rmdir(item.path);
          } catch (_) {
            if (tab.sshClient != null) {
              await tab.sshClient!.run('rm -rf "${item.path}"');
            } else {
              rethrow;
            }
          }
        } else {
          await tab.sftpClient!.remove(item.path);
        }
      } else if (tab.hostProfile.kind == TerminalHostKind.backendWs) {
        await widget.appState.api.deleteFile(item.path);
      } else {
        if (item.isDir) {
          await Directory(item.path).delete(recursive: true);
        } else {
          await File(item.path).delete();
        }
      }
      await _loadSftpDirectory(tab, tab.sftpCurrentPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    }
  }

  // ===========================================================================
  // SSH Host Manager Dialog (Add / Edit / Delete SSH2 + SFTP Hosts)
  // ===========================================================================

  Future<void> _showHostProfileEditorDialog({
    TerminalHostProfile? existing,
  }) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final groupCtrl = TextEditingController(text: existing?.group ?? '默认分组');
    final hostCtrl = TextEditingController(text: existing?.host ?? '');
    final portCtrl = TextEditingController(text: '${existing?.port ?? 22}');
    final userCtrl = TextEditingController(text: existing?.username ?? 'root');
    final passCtrl = TextEditingController(text: existing?.password ?? '');
    final keyCtrl = TextEditingController(text: existing?.privateKeyPem ?? '');
    final phraseCtrl = TextEditingController(text: existing?.passphrase ?? '');
    final sftpPathCtrl =
        TextEditingController(text: existing?.initialSftpPath ?? '/root');
    final startupCmdCtrl =
        TextEditingController(text: existing?.startupCommand ?? '');
    String authType = existing?.authType ?? 'password';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: VideoPlatformTheme.bgElevated,
          title: Row(
            children: [
              Icon(
                Icons.dns_rounded,
                color: VideoPlatformTheme.accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                existing == null ? '添加 SSH2 / SFTP 远程服务器主机' : '编辑主机：${existing.name}',
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
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
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: '主机名称 (如 阿里云生产服 / 群晖 NAS)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: groupCtrl,
                          decoration: const InputDecoration(
                            labelText: '分组标签',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: hostCtrl,
                          decoration: const InputDecoration(
                            labelText: '主机 IP 或域名 (例如 192.168.1.10)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: portCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'SSH 端口',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: userCtrl,
                          decoration: const InputDecoration(
                            labelText: '登录用户名 (如 root)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ChoiceChip(
                        label: const Text('密码认证'),
                        selected: authType == 'password',
                        onSelected: (_) =>
                            setModalState(() => authType = 'password'),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('SSH 私钥 (PEM)'),
                        selected: authType == 'privateKey',
                        onSelected: (_) =>
                            setModalState(() => authType = 'privateKey'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (authType == 'password')
                    TextField(
                      controller: passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'SSH 登录密码',
                      ),
                    )
                  else ...[
                    TextField(
                      controller: keyCtrl,
                      maxLines: 4,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        labelText:
                            '粘贴私钥内容 (-----BEGIN OPENSSH/RSA PRIVATE KEY-----)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: phraseCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '私钥密码 Passphrase (无密码留空)',
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: sftpPathCtrl,
                          decoration: const InputDecoration(
                            labelText: 'SFTP 默认起始目录 (如 /root 或 /)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: startupCmdCtrl,
                          decoration: const InputDecoration(
                            labelText: '连接后自动执行命令 (选填)',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null && !existing.isBuiltIn)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: VideoPlatformTheme.danger,
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _hostProfiles.removeWhere((h) => h.id == existing.id);
                    if (_selectedProfileIdForNewConnect == existing.id) {
                      _selectedProfileIdForNewConnect = 'builtin_backend_ws';
                    }
                  });
                  await _persistCustomHosts();
                },
                child: const Text('删除主机'),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final host = hostCtrl.text.trim();
                if (host.isEmpty) return;
                final port = int.tryParse(portCtrl.text.trim()) ?? 22;
                final user =
                    userCtrl.text.trim().isEmpty ? 'root' : userCtrl.text.trim();
                final name = nameCtrl.text.trim().isEmpty
                    ? '$user@$host'
                    : nameCtrl.text.trim();
                final newProfile = TerminalHostProfile(
                  id: existing?.id ??
                      'ssh_${DateTime.now().millisecondsSinceEpoch}',
                  name: name,
                  group: groupCtrl.text.trim().isEmpty
                      ? '默认分组'
                      : groupCtrl.text.trim(),
                  kind: TerminalHostKind.ssh2,
                  host: host,
                  port: port,
                  username: user,
                  authType: authType,
                  password: passCtrl.text,
                  privateKeyPem: keyCtrl.text.trim(),
                  passphrase: phraseCtrl.text,
                  initialSftpPath: sftpPathCtrl.text.trim().isEmpty
                      ? '/'
                      : sftpPathCtrl.text.trim(),
                  startupCommand: startupCmdCtrl.text.trim(),
                );
                Navigator.of(ctx).pop();
                setState(() {
                  final idx =
                      _hostProfiles.indexWhere((h) => h.id == newProfile.id);
                  if (idx >= 0) {
                    _hostProfiles[idx] = newProfile;
                  } else {
                    _hostProfiles.add(newProfile);
                  }
                  _selectedProfileIdForNewConnect = newProfile.id;
                  if (!_activeTab.isConnected && !_activeTab.isConnecting) {
                    _activeTab.hostProfile = newProfile;
                    _activeTab.label = '${newProfile.name} #${_activeTab.id}';
                  }
                });
                await _persistCustomHosts();
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: const Text('保存主机配置'),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // Buffer Search, Snippets & Log Export
  // ===========================================================================

  Future<void> _showAddSnippetDialog() async {
    final labelCtrl = TextEditingController();
    final cmdCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text(
          '添加快捷运维指令',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: '按钮名称',
                  hintText: '例如：重启服务 / 查看显卡状态',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cmdCtrl,
                decoration: const InputDecoration(
                  labelText: '执行命令 (自动附带回车)',
                  hintText: '例如：systemctl status nginx',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true &&
        labelCtrl.text.trim().isNotEmpty &&
        cmdCtrl.text.trim().isNotEmpty) {
      setState(() {
        _quickSnippets = [
          ..._quickSnippets,
          (
            label: labelCtrl.text.trim(),
            command: '${cmdCtrl.text.trim()}\n',
          ),
        ];
      });
      await _saveCustomSnippets();
    }
    labelCtrl.dispose();
    cmdCtrl.dispose();
  }

  void _runBufferSearch(String query) {
    final tab = _activeTab;
    tab.clearHighlights();
    final kw = query.trim().toLowerCase();
    if (kw.isEmpty) {
      setState(() => _searchMatchCount = 0);
      return;
    }

    int matches = 0;
    final lines = tab.terminal.buffer.lines;
    for (var y = 0; y < lines.length; y++) {
      final lineText = lines[y].toString().toLowerCase();
      int startIdx = 0;
      while (true) {
        final found = lineText.indexOf(kw, startIdx);
        if (found < 0) break;
        final endCol = found + kw.length;
        try {
          final a1 = tab.terminal.buffer.createAnchor(found, y);
          final a2 = tab.terminal.buffer.createAnchor(endCol, y);
          final hl = tab.controller.highlight(
            p1: a1,
            p2: a2,
            color: const Color(0x99E7BD68),
          );
          tab.searchHighlights.add(hl);
          matches++;
        } catch (_) {}
        startIdx = endCol;
        if (matches >= 200) break;
      }
      if (matches >= 200) break;
    }
    setState(() => _searchMatchCount = matches);
  }

  Future<void> _exportActiveTerminalLog() async {
    final tab = _activeTab;
    final lines = tab.terminal.buffer.lines;
    final sb = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i].toString().trimRight();
      if (text.isNotEmpty || i <= tab.terminal.buffer.absoluteCursorY) {
        sb.writeln(text);
      }
    }

    try {
      final dlRoot = RemoteStorageService.defaultLocalDownloadsRoot();
      final outPath =
          '$dlRoot${Platform.pathSeparator}terminal_session_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.log';
      await File(outPath).writeAsString(sb.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✓ 已导出终端会话日志：$outPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出终端日志失败：$e')),
        );
      }
    }
  }

  // ===========================================================================
  // UI Building
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final tab = _activeTab;
    final screenW = MediaQuery.sizeOf(context).width;
    final isWideScreen = screenW >= 960;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () {
          setState(() => _fontSize = (_fontSize + 1.0).clamp(11.0, 24.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () {
          setState(() => _fontSize = (_fontSize + 1.0).clamp(11.0, 24.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () {
          setState(() => _fontSize = (_fontSize - 1.0).clamp(11.0, 24.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () {
          setState(() => _fontSize = (_fontSize - 1.0).clamp(11.0, 24.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.digit0, meta: true): () {
          setState(() => _fontSize = 14.0);
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () {
          setState(() => _fontSize = 14.0);
          _saveTerminalAppearance();
        },
      },
      child: Column(
        children: [
          // 1. Top Multi-Tab, Host Selector & Action Toolbar
          _buildTopToolbar(tab),

          // 2. Live Server Metrics Strip (CPU Load / RAM / Disk / Uptime)
          if (_showLiveMetricsBar &&
              tab.isConnected &&
              tab.hostProfile.kind == TerminalHostKind.ssh2)
            _buildLiveMetricsStrip(tab),

          // 3. Inline Buffer Search Bar
          if (_showSearchBar) _buildSearchBar(tab),

          // 4. Quick DevOps Command Snippets Bar
          _buildQuickSnippetsBar(tab),

          // 5. Main Split View: Terminal Canvas + SFTP Visual File Explorer
          Expanded(
            child: _showSftpPanel
                ? (isWideScreen
                    ? Row(
                        children: [
                          Expanded(
                            flex: 6,
                            child: _buildTerminalStackArea(tab),
                          ),
                          Container(
                            width: 1,
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                          SizedBox(
                            width: (screenW * 0.36).clamp(350.0, 520.0),
                            child: _buildSftpExplorerPane(tab),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(
                            flex: 5,
                            child: _buildTerminalStackArea(tab),
                          ),
                          Divider(
                            height: 1,
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                          Expanded(
                            flex: 5,
                            child: _buildSftpExplorerPane(tab),
                          ),
                        ],
                      ))
                : _buildTerminalStackArea(tab),
          ),

          // 6. Virtual Modifier & Function Key Bar (ESC / TAB / CTRL / ALT / Arrows / Pipes)
          if (_showVirtualKeysBar) _buildVirtualFunctionKeysBar(tab),

          // 7. Command History & Multi-line Script Composer Bar
          if (_showCommandComposerBar) _buildCommandComposerBar(tab),
        ],
      ),
    );
  }

  Widget _buildTopToolbar(_TerminalTabSession tab) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
            // Multi-tab strip
            for (int idx = 0; idx < _tabs.length; idx++) ...[
              if (idx > 0) const SizedBox(width: 6),
              Builder(
                builder: (_) {
                  final t = _tabs[idx];
                  final selected = idx == _activeTabIndex;
                  return InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      setState(() {
                        _activeTabIndex = idx;
                        _sftpPathCtrl.text = t.sftpCurrentPath;
                      });
                      t.focusNode.requestFocus();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                            : VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: t.isConnected
                                  ? VideoPlatformTheme.success
                                  : (t.isConnecting
                                      ? VideoPlatformTheme.warning
                                      : VideoPlatformTheme.textMuted),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            t.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w400,
                              color: selected
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          if (_tabs.length > 1) ...[
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _closeTab(idx),
                              child: Icon(
                                Icons.close_rounded,
                                size: 13,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              tooltip: '新建待连接终端标签页',
              visualDensity: VisualDensity.compact,
              onPressed: () => _createNewTab(autoConnect: false),
              icon: const Icon(Icons.add_rounded, size: 17),
            ),
            const SizedBox(width: 8),

            // Host Selector Dropdown + Add SSH Host Button
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _hostProfiles.any((h) => h.id == tab.hostProfile.id)
                      ? tab.hostProfile.id
                      : _hostProfiles.first.id,
                  isDense: true,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                  dropdownColor: VideoPlatformTheme.bgElevated,
                  items: _hostProfiles.map((p) {
                    return DropdownMenuItem<String>(
                      value: p.id,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            p.kind == TerminalHostKind.ssh2
                                ? Icons.dns_rounded
                                : (p.kind == TerminalHostKind.localShell
                                    ? Icons.computer_rounded
                                    : Icons.cloud_rounded),
                            size: 14,
                            color: VideoPlatformTheme.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(p.name),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (newId) {
                    if (newId == null) return;
                    final prof = _resolveProfileById(newId);
                    setState(() {
                      _selectedProfileIdForNewConnect = newId;
                      if (!tab.isConnected && !tab.isConnecting) {
                        tab.hostProfile = prof;
                        tab.label = '${prof.name} #${tab.id}';
                        tab.sftpCurrentPath = prof.initialSftpPath;
                        _sftpPathCtrl.text = prof.initialSftpPath;
                      }
                    });
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '添加 SSH2 / SFTP 远程服务器',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showHostProfileEditorDialog(),
              icon: Icon(
                Icons.add_moderator_rounded,
                size: 17,
                color: VideoPlatformTheme.accent,
              ),
            ),
            if (!tab.hostProfile.isBuiltIn)
              IconButton(
                tooltip: '编辑当前 SSH 主机配置',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    _showHostProfileEditorDialog(existing: tab.hostProfile),
                icon: const Icon(Icons.edit_outlined, size: 16),
              ),
            const SizedBox(width: 6),

            // Connect / Disconnect / Clear Buttons
            FilledButton.icon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: VideoPlatformTheme.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: tab.isConnected || tab.isConnecting
                  ? null
                  : () => _connectTab(tab),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: Text(
                tab.isConnecting
                    ? '连接中...'
                    : (tab.sessionCount > 0 ? '重连终端' : '连接终端'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: tab.isConnected || tab.isConnecting
                  ? () => _disconnectTab(tab)
                  : null,
              child: const Text('断开', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => _clearTerminal(tab),
              child: const Text('清屏', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),

            // SFTP Panel Toggle Button
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: _showSftpPanel
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.2)
                    : VideoPlatformTheme.bgCard,
                foregroundColor: _showSftpPanel
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
              onPressed: () {
                setState(() => _showSftpPanel = !_showSftpPanel);
                if (_showSftpPanel && tab.sftpEntries.isEmpty) {
                  _loadSftpDirectory(tab, tab.sftpCurrentPath);
                }
              },
              icon: const Icon(Icons.folder_copy_rounded, size: 15),
              label: Text(
                _showSftpPanel ? 'SFTP 文件栏 (已开)' : 'SFTP 文件栏',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),

            // Live Metrics, Virtual Keys & Composer Toggles
            IconButton(
              tooltip: _showLiveMetricsBar
                  ? '隐藏服务器实时性能监控栏'
                  : '显示服务器实时性能监控栏 (CPU/内存/磁盘)',
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  setState(() => _showLiveMetricsBar = !_showLiveMetricsBar),
              icon: Icon(
                Icons.monitor_heart_outlined,
                size: 18,
                color: _showLiveMetricsBar
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
            ),
            IconButton(
              tooltip: _showVirtualKeysBar ? '隐藏虚拟扩展按键栏' : '显示虚拟扩展按键栏 (ESC/TAB/CTRL)',
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  setState(() => _showVirtualKeysBar = !_showVirtualKeysBar),
              icon: Icon(
                Icons.keyboard_alt_outlined,
                size: 18,
                color: _showVirtualKeysBar
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
            ),
            IconButton(
              tooltip: _showCommandComposerBar
                  ? '隐藏底部命令输入框与历史记录栏'
                  : '显示底部命令输入框与历史记录栏',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(
                () => _showCommandComposerBar = !_showCommandComposerBar,
              ),
              icon: Icon(
                Icons.code_rounded,
                size: 18,
                color: _showCommandComposerBar
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
            ),
            IconButton(
              tooltip: '搜索终端历史输出',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() => _showSearchBar = !_showSearchBar);
                if (!_showSearchBar) {
                  tab.clearHighlights();
                }
              },
              icon: Icon(
                Icons.search_rounded,
                size: 18,
                color: _showSearchBar
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
            ),
            IconButton(
              tooltip: '导出当前终端完整日志 (.log)',
              visualDensity: VisualDensity.compact,
              onPressed: _exportActiveTerminalLog,
              icon: const Icon(Icons.download_outlined, size: 18),
            ),
            PopupMenuButton<String>(
              tooltip: '切换终端配色主题 (9套开源经典主题)',
              initialValue: _terminalThemeId,
              onSelected: (themeId) {
                setState(() => _terminalThemeId = themeId);
                _saveTerminalAppearance();
                tab.focusNode.requestFocus();
              },
              itemBuilder: (_) => _terminalThemes.entries
                  .map(
                    (e) => PopupMenuItem<String>(
                      value: e.key,
                      child: Text(e.value.name),
                    ),
                  )
                  .toList(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.palette_outlined,
                  size: 18,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
            ),
            PopupMenuButton<TerminalCursorType>(
              tooltip: '切换光标样式',
              initialValue: _cursorType,
              onSelected: (t) {
                setState(() => _cursorType = t);
                tab.focusNode.requestFocus();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: TerminalCursorType.block,
                  child: Text('方块光标 (Block · 默认)'),
                ),
                PopupMenuItem(
                  value: TerminalCursorType.verticalBar,
                  child: Text('竖线光标 (Vertical Bar)'),
                ),
                PopupMenuItem(
                  value: TerminalCursorType.underline,
                  child: Text('下划线光标 (Underline)'),
                ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: VideoPlatformTheme.borderStrong),
                ),
                child: Text(
                  '${_fontSize.toInt()}pt',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '放大字号',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(
                  () => _fontSize = (_fontSize + 1.0).clamp(11.0, 24.0),
                );
                _saveTerminalAppearance();
              },
              icon: const Icon(Icons.add_circle_outline, size: 17),
            ),
            IconButton(
              tooltip: '缩小字号',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(
                  () => _fontSize = (_fontSize - 1.0).clamp(11.0, 24.0),
                );
                _saveTerminalAppearance();
              },
              icon: const Icon(Icons.remove_circle_outline, size: 17),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveMetricsStrip(_TerminalTabSession tab) {
    final m = tab.metrics;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(
              Icons.monitor_heart_rounded,
              size: 14,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(width: 6),
            Text(
              '实时监控:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
            _buildMetricBadge('CPU 负载', m.loadAvg, null),
            const SizedBox(width: 12),
            _buildMetricBadge('内存', m.memText, m.memRatio),
            const SizedBox(width: 12),
            _buildMetricBadge('根分区磁盘', m.diskText, m.diskRatio),
            const SizedBox(width: 12),
            _buildMetricBadge('运行时间', m.uptimeText, null),
            if (m.kernelText.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                m.kernelText,
                style: TextStyle(
                  fontSize: 11,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricBadge(String label, String value, double? ratio) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 11,
            color: VideoPlatformTheme.textMuted,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: VideoPlatformTheme.textPrimary,
          ),
        ),
        if (ratio != null && ratio > 0) ...[
          const SizedBox(width: 5),
          SizedBox(
            width: 44,
            height: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                backgroundColor: VideoPlatformTheme.borderSubtle,
                valueColor: AlwaysStoppedAnimation<Color>(
                  ratio > 0.85
                      ? VideoPlatformTheme.danger
                      : (ratio > 0.65
                          ? VideoPlatformTheme.warning
                          : VideoPlatformTheme.accent),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchBar(_TerminalTabSession tab) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.manage_search_rounded, size: 17),
          const SizedBox(width: 8),
          SizedBox(
            width: 280,
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: _runBufferSearch,
              decoration: const InputDecoration(
                hintText: '在终端缓冲区中搜索关键字...',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '高亮匹配：$_searchMatchCount 处',
            style: TextStyle(
              fontSize: 12,
              color: VideoPlatformTheme.textSecondary,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              _searchCtrl.clear();
              tab.clearHighlights();
              setState(() {
                _searchMatchCount = 0;
                _showSearchBar = false;
              });
              tab.focusNode.requestFocus();
            },
            child: const Text('关闭搜索'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickSnippetsBar(_TerminalTabSession tab) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          Text(
            '快捷指令:',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.textMuted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _quickSnippets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, idx) {
                final s = _quickSnippets[idx];
                return Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: !tab.isConnected
                        ? null
                        : () {
                            _handleTerminalUserInput(tab, s.command);
                            tab.focusNode.requestFocus();
                          },
                    onLongPress: idx >= 11
                        ? () {
                            setState(() => _quickSnippets.removeAt(idx));
                            _saveCustomSnippets();
                          }
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: VideoPlatformTheme.bgElevated,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: VideoPlatformTheme.borderSubtle,
                        ),
                      ),
                      child: Text(
                        s.label,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: tab.isConnected
                              ? VideoPlatformTheme.textPrimary
                              : VideoPlatformTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          if (_tabs.length > 1)
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () {
                setState(() => _broadcastToAllTabs = !_broadcastToAllTabs);
                tab.focusNode.requestFocus();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _broadcastToAllTabs
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                      : VideoPlatformTheme.bgElevated,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: _broadcastToAllTabs
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.borderSubtle,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cell_tower_rounded,
                      size: 13,
                      color: _broadcastToAllTabs
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _broadcastToAllTabs ? '广播已开' : '广播全部标签',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: _broadcastToAllTabs
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: _broadcastToAllTabs
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: _showAddSnippetDialog,
            icon: const Icon(Icons.add_rounded, size: 15),
            label: const Text('自定义指令', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalStackArea(_TerminalTabSession activeTab) {
    return Stack(
      children: [
        MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          child: IndexedStack(
            index: _activeTabIndex.clamp(0, _tabs.length - 1),
            children: [
              for (final t in _tabs)
                TerminalView(
                  t.terminal,
                  key: ValueKey('term_tab_${t.id}'),
                  controller: t.controller,
                  focusNode: t.focusNode,
                  autofocus: true,
                  theme: _activeXtermTheme,
                  padding: const EdgeInsets.all(12),
                  cursorType: _cursorType,
                  alwaysShowCursor: true,
                  textScaler: TextScaler.noScaling,
                  textStyle: TerminalStyle(
                    fontSize: _fontSize,
                    height: 1.2,
                    fontFamily: Platform.isMacOS ? 'Menlo' : 'Consolas',
                    fontFamilyFallback: const [
                      'Menlo',
                      'Monaco',
                      'Consolas',
                      'Cascadia Mono',
                      'Liberation Mono',
                      'Sarasa Mono SC',
                      'Noto Sans Mono CJK SC',
                      'PingFang SC',
                      'Heiti SC',
                      'Microsoft YaHei Mono',
                      'monospace',
                    ],
                  ),
                  onSecondaryTapDown: (details, offset) async {
                    final selection = t.controller.selection;
                    if (selection != null) {
                      final text = t.terminal.buffer.getText(selection);
                      t.controller.clearSelection();
                      await Clipboard.setData(ClipboardData(text: text));
                    } else {
                      final data = await Clipboard.getData('text/plain');
                      final text = data?.text;
                      if (text != null && text.isNotEmpty) {
                        t.terminal.paste(text);
                      }
                    }
                  },
                ),
            ],
          ),
        ),
        // Unconnected Welcome & Host Quick-Connect Card (Default state when opening Terminal page!)
        if (!activeTab.isConnected && !activeTab.isConnecting)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.58),
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Card(
                  color: VideoPlatformTheme.bgElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: VideoPlatformTheme.borderStrong),
                  ),
                  elevation: 16,
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: VideoPlatformTheme.accent
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.terminal_rounded,
                                color: VideoPlatformTheme.accent,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '终端已就绪（当前未连接）',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: VideoPlatformTheme.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    '请选择要连接的终端或 SSH / SFTP 远程主机，支持多标签并行与 SFTP 文件可视化管理',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: VideoPlatformTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 230),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: _hostProfiles.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, idx) {
                              final p = _hostProfiles[idx];
                              final isCur = activeTab.hostProfile.id == p.id;
                              return InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () =>
                                    _connectTab(activeTab, overrideProfile: p),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isCur
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.14)
                                        : VideoPlatformTheme.bgCard,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isCur
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.borderSubtle,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        p.kind == TerminalHostKind.ssh2
                                            ? Icons.dns_rounded
                                            : (p.kind ==
                                                    TerminalHostKind.localShell
                                                ? Icons.computer_rounded
                                                : Icons.cloud_rounded),
                                        color: VideoPlatformTheme.accent,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              p.name,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: VideoPlatformTheme
                                                    .textPrimary,
                                              ),
                                            ),
                                            Text(
                                              p.subtitle,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: VideoPlatformTheme
                                                    .textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (!p.isBuiltIn)
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          tooltip: '编辑主机',
                                          onPressed: () =>
                                              _showHostProfileEditorDialog(
                                            existing: p,
                                          ),
                                          icon: const Icon(
                                            Icons.edit_outlined,
                                            size: 16,
                                          ),
                                        ),
                                      const SizedBox(width: 4),
                                      FilledButton.tonalIcon(
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: () => _connectTab(
                                          activeTab,
                                          overrideProfile: p,
                                        ),
                                        icon: const Icon(
                                          Icons.bolt_rounded,
                                          size: 15,
                                        ),
                                        label: const Text(
                                          '立即连接',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _showHostProfileEditorDialog(),
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: const Text('新增 SSH / SFTP 远程服务器'),
                            ),
                            const Spacer(),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: VideoPlatformTheme.accent,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () => _connectTab(activeTab),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 17,
                              ),
                              label: Text('连接「${activeTab.hostProfile.name}」'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ===========================================================================
  // SFTP Visual File Explorer Split Pane
  // ===========================================================================

  Widget _buildSftpExplorerPane(_TerminalTabSession tab) {
    final kw = tab.sftpSearchFilter.trim().toLowerCase();
    final filtered = tab.sftpEntries.where((e) {
      if (!tab.sftpShowHidden && e.name.startsWith('.')) return false;
      if (kw.isNotEmpty && !e.name.toLowerCase().contains(kw)) return false;
      return true;
    }).toList();

    return Container(
      color: VideoPlatformTheme.bgElevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SFTP Header & Quick Actions
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.bgCard,
              border: Border(
                bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.folder_copy_rounded,
                      size: 16,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'SFTP 文件管理器 (${tab.hostProfile.name})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: '在当前终端中 cd 到此 SFTP 目录',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(5),
                        onTap: !tab.isConnected
                            ? null
                            : () {
                                final p = tab.sftpCurrentPath.isEmpty
                                    ? '/'
                                    : tab.sftpCurrentPath;
                                _sendToSingleTab(tab, 'cd "$p"\n');
                                tab.focusNode.requestFocus();
                              },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.accent
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '终端 cd 到此',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: tab.sftpShowHidden ? '隐藏以 . 开头的隐藏文件' : '显示隐藏文件 (.)',
                      onPressed: () => setState(
                        () => tab.sftpShowHidden = !tab.sftpShowHidden,
                      ),
                      icon: Icon(
                        tab.sftpShowHidden
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_outlined,
                        size: 16,
                        color: tab.sftpShowHidden
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textMuted,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '刷新 SFTP 目录',
                      onPressed: () =>
                          _loadSftpDirectory(tab, tab.sftpCurrentPath),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Path input bar + Parent folder button
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '返回上级目录 (..)',
                      onPressed: () {
                        final parent = _parentPosixPath(tab.sftpCurrentPath);
                        _loadSftpDirectory(tab, parent);
                      },
                      icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                    ),
                    Expanded(
                      child: SizedBox(
                        height: 28,
                        child: TextField(
                          controller: _sftpPathCtrl,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                          ),
                          onSubmitted: (v) => _loadSftpDirectory(tab, v),
                          decoration: InputDecoration(
                            hintText: '输入远程路径回车跳转 (如 /etc/nginx)',
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Toolbar: Upload / New Folder / New File / Filter
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () => _showUploadLocalFileToSftpDialog(tab),
                        icon: const Icon(Icons.upload_file_rounded, size: 14),
                        label: const Text(
                          '上传文件',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 5),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () =>
                            _createSftpDirectoryOrFile(tab, isDirectory: true),
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 14,
                        ),
                        label: const Text(
                          '新建目录',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 5),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () =>
                            _createSftpDirectoryOrFile(tab, isDirectory: false),
                        icon: const Icon(Icons.note_add_outlined, size: 14),
                        label: const Text(
                          '新建文件',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 125,
                        height: 26,
                        child: TextField(
                          controller: _sftpFilterCtrl,
                          style: const TextStyle(fontSize: 11),
                          onChanged: (v) =>
                              setState(() => tab.sftpSearchFilter = v),
                          decoration: InputDecoration(
                            hintText: '过滤文件名...',
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 7),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Active SFTP Transfers Strip (if any)
          if (tab.sftpTransfers.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: VideoPlatformTheme.bgCard,
              child: Column(
                children: [
                  for (final tr in tab.sftpTransfers.take(2))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(
                            tr.isUpload
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                            size: 13,
                            color: VideoPlatformTheme.accent,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              '${tr.fileName} · ${tr.detail}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 50,
                            height: 4,
                            child: LinearProgressIndicator(
                              value: tr.progress,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          // SFTP Entries List
          Expanded(
            child: tab.isLoadingSftp
                ? Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: VideoPlatformTheme.accent,
                    ),
                  )
                : (tab.sftpError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tab.sftpError!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: VideoPlatformTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: () => _loadSftpDirectory(
                                  tab,
                                  tab.sftpCurrentPath,
                                ),
                                icon: const Icon(Icons.refresh_rounded, size: 15),
                                label: const Text('加载 SFTP 目录'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : (filtered.isEmpty
                        ? Center(
                            child: Text(
                              tab.isConnected
                                  ? '当前目录为空'
                                  : '连接终端或点击刷新即可浏览 SFTP 文件',
                              style: TextStyle(
                                fontSize: 12,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: VideoPlatformTheme.borderSubtle,
                            ),
                            itemBuilder: (_, idx) {
                              final item = filtered[idx];
                              return ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 1,
                                ),
                                leading: Icon(
                                  item.isDir
                                      ? Icons.folder_rounded
                                      : (item.isEditableText
                                          ? Icons.description_rounded
                                          : Icons.insert_drive_file_outlined),
                                  size: 19,
                                  color: item.isDir
                                      ? VideoPlatformTheme.warning
                                      : (item.isEditableText
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textSecondary),
                                ),
                                title: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: item.isDir
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: VideoPlatformTheme.textPrimary,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item.formattedSize} · ${item.octalPermissions}${item.modTimeText.isNotEmpty ? " · ${item.modTimeText}" : ""}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: VideoPlatformTheme.textMuted,
                                  ),
                                ),
                                onTap: () {
                                  if (item.isDir) {
                                    _loadSftpDirectory(tab, item.path);
                                  } else if (item.isEditableText) {
                                    _openSftpTextEditorDialog(tab, item);
                                  } else {
                                    _downloadSftpFileToLocal(tab, item);
                                  }
                                },
                                trailing: PopupMenuButton<String>(
                                  tooltip: '文件操作',
                                  icon: const Icon(
                                    Icons.more_vert_rounded,
                                    size: 16,
                                  ),
                                  onSelected: (action) {
                                    switch (action) {
                                      case 'open':
                                        if (item.isDir) {
                                          _loadSftpDirectory(tab, item.path);
                                        } else {
                                          _openSftpTextEditorDialog(tab, item);
                                        }
                                        break;
                                      case 'cd':
                                        final dir = item.isDir
                                            ? item.path
                                            : _parentPosixPath(item.path);
                                        _sendToSingleTab(tab, 'cd "$dir"\n');
                                        tab.focusNode.requestFocus();
                                        break;
                                      case 'paste_path':
                                        _sendToSingleTab(
                                          tab,
                                          '"${item.path}" ',
                                        );
                                        tab.focusNode.requestFocus();
                                        break;
                                      case 'download':
                                        _downloadSftpFileToLocal(tab, item);
                                        break;
                                      case 'chmod':
                                        _chmodSftpEntry(tab, item);
                                        break;
                                      case 'rename':
                                        _renameSftpEntry(tab, item);
                                        break;
                                      case 'delete':
                                        _deleteSftpEntry(tab, item);
                                        break;
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    if (item.isDir)
                                      const PopupMenuItem(
                                        value: 'open',
                                        child: Text('进入此目录'),
                                      )
                                    else ...[
                                      const PopupMenuItem(
                                        value: 'open',
                                        child: Text('在线编辑 / 查看文本'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'download',
                                        child: Text('下载到本机 Downloads'),
                                      ),
                                    ],
                                    const PopupMenuItem(
                                      value: 'cd',
                                      child: Text('在终端中 cd 到此位置'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'paste_path',
                                      child: Text('发送完整路径到终端光标'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'chmod',
                                      child: Text('修改权限 (chmod)'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Text('重命名'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text(
                                        '删除',
                                        style: TextStyle(color: Colors.redAccent),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ))),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Virtual Modifier & Function Key Bar + Command History Composer Bar
  // ===========================================================================

  Widget _buildVirtualFunctionKeysBar(_TerminalTabSession tab) {
    final keys = <({String label, String? seq, VoidCallback? custom})>[
      (label: 'ESC', seq: '\x1b', custom: null),
      (label: 'TAB', seq: '\t', custom: null),
      (
        label: _ctrlLocked ? 'CTRL (已锁)' : 'CTRL',
        seq: null,
        custom: () => setState(() => _ctrlLocked = !_ctrlLocked),
      ),
      (
        label: _altLocked ? 'ALT (已锁)' : 'ALT',
        seq: null,
        custom: () => setState(() => _altLocked = !_altLocked),
      ),
      (label: '↑', seq: '\x1b[A', custom: null),
      (label: '↓', seq: '\x1b[B', custom: null),
      (label: '←', seq: '\x1b[D', custom: null),
      (label: '→', seq: '\x1b[C', custom: null),
      (label: 'Home', seq: '\x1b[H', custom: null),
      (label: 'End', seq: '\x1b[F', custom: null),
      (label: 'PgUp', seq: '\x1b[5~', custom: null),
      (label: 'PgDn', seq: '\x1b[6~', custom: null),
      (label: '|', seq: '|', custom: null),
      (label: '/', seq: '/', custom: null),
      (label: '~', seq: '~', custom: null),
      (label: '-', seq: '-', custom: null),
      (label: 'Ctrl+C', seq: '\x03', custom: null),
      (label: 'Ctrl+D', seq: '\x04', custom: null),
      (label: 'Ctrl+Z', seq: '\x1a', custom: null),
      (label: 'Ctrl+R 搜索', seq: '\x12', custom: null),
      (label: 'Ctrl+A 行首', seq: '\x01', custom: null),
      (label: 'Ctrl+E 行尾', seq: '\x05', custom: null),
    ];

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          top: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: keys.length,
        separatorBuilder: (_, __) => const SizedBox(width: 5),
        itemBuilder: (_, idx) {
          final k = keys[idx];
          final isLocked = (k.label.startsWith('CTRL') && _ctrlLocked) ||
              (k.label.startsWith('ALT') && _altLocked);
          return Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () {
                if (k.custom != null) {
                  k.custom!();
                } else if (k.seq != null && tab.isConnected) {
                  _handleTerminalUserInput(tab, k.seq!);
                }
                tab.focusNode.requestFocus();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: isLocked
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isLocked
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.borderSubtle,
                  ),
                ),
                child: Text(
                  k.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: isLocked
                        ? Colors.white
                        : VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCommandComposerBar(_TerminalTabSession tab) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        border: Border(
          top: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: '历史发送命令记录 (${_commandHistory.length})',
            onSelected: (cmd) {
              _commandInputCtrl.text = cmd;
              if (tab.isConnected) {
                _handleTerminalUserInput(tab, '$cmd\n');
                _recordCommandHistory(cmd);
                _commandInputCtrl.clear();
              }
            },
            itemBuilder: (_) => _commandHistory.isEmpty
                ? const [
                    PopupMenuItem(
                      enabled: false,
                      child: Text('暂无历史命令'),
                    ),
                  ]
                : _commandHistory
                    .take(25)
                    .map(
                      (c) => PopupMenuItem<String>(
                        value: c,
                        child: Text(
                          c,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    )
                    .toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 15,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 4),
                  const Text('命令历史', style: TextStyle(fontSize: 11.5)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 32,
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent && _commandHistory.isNotEmpty) {
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _historyCursor =
                          (_historyCursor + 1).clamp(0, _commandHistory.length - 1);
                      _commandInputCtrl.text = _commandHistory[_historyCursor];
                      return KeyEventResult.handled;
                    } else if (event.logicalKey ==
                        LogicalKeyboardKey.arrowDown) {
                      if (_historyCursor > 0) {
                        _historyCursor--;
                        _commandInputCtrl.text =
                            _commandHistory[_historyCursor];
                      } else {
                        _historyCursor = -1;
                        _commandInputCtrl.clear();
                      }
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _commandInputCtrl,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                  ),
                  onSubmitted: (cmd) {
                    if (!tab.isConnected || cmd.trim().isEmpty) return;
                    _handleTerminalUserInput(tab, '$cmd\n');
                    _recordCommandHistory(cmd);
                    _commandInputCtrl.clear();
                  },
                  decoration: InputDecoration(
                    hintText: _broadcastToAllTabs
                        ? '输入命令并回车（将同步广播至全部已连接终端标签页，按 ↑/↓ 翻阅历史）...'
                        : '命令构建器：输入或粘贴命令回车发送（按 ↑/↓ 翻阅历史命令）...',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              backgroundColor: VideoPlatformTheme.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: !tab.isConnected
                ? null
                : () {
                    final cmd = _commandInputCtrl.text;
                    if (cmd.trim().isEmpty) return;
                    _handleTerminalUserInput(tab, '$cmd\n');
                    _recordCommandHistory(cmd);
                    _commandInputCtrl.clear();
                    tab.focusNode.requestFocus();
                  },
            icon: const Icon(Icons.send_rounded, size: 14),
            label: const Text('执行', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 4. SFTP Online Code & Config File Editor Dialog
// =============================================================================

class _SftpOnlineEditorDialog extends StatefulWidget {
  final String fileName;
  final String remotePath;
  final Future<String> Function() loadContent;
  final Future<void> Function(String newContent) saveContent;

  const _SftpOnlineEditorDialog({
    required this.fileName,
    required this.remotePath,
    required this.loadContent,
    required this.saveContent,
  });

  @override
  State<_SftpOnlineEditorDialog> createState() =>
      _SftpOnlineEditorDialogState();
}

class _SftpOnlineEditorDialogState extends State<_SftpOnlineEditorDialog> {
  final TextEditingController _editorCtrl = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await widget.loadContent();
      if (!mounted) return;
      setState(() {
        _editorCtrl.text = text;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await widget.saveContent(_editorCtrl.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✓ 已通过 SFTP 保存远程文件：${widget.remotePath}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = '保存失败：$e';
      });
    }
  }

  @override
  void dispose() {
    _editorCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      title: Row(
        children: [
          Icon(
            Icons.edit_note_rounded,
            color: VideoPlatformTheme.accent,
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SFTP 在线编辑器：${widget.fileName}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  widget.remotePath,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 500,
        child: _isLoading
            ? Center(
                child: CircularProgressIndicator(
                  color: VideoPlatformTheme.accent,
                ),
              )
            : (_error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: TextStyle(color: VideoPlatformTheme.danger),
                    ),
                  )
                : TextField(
                    controller: _editorCtrl,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: VideoPlatformTheme.bgCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  )),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: VideoPlatformTheme.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: (_isLoading || _isSaving) ? null : _save,
          icon: _isSaving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.save_rounded, size: 16),
          label: Text(_isSaving ? '正在写回服务器...' : '保存至远程服务器 (SFTP)'),
        ),
      ],
    );
  }
}
