import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../../state/app_state.dart';
import '../theme.dart';

class _TerminalTabSession {
  final int id;
  final String label;
  late final Terminal terminal;
  final TerminalController controller = TerminalController();
  final FocusNode focusNode = FocusNode();
  final List<TerminalHighlight> searchHighlights = [];

  WebSocket? socket;
  StreamSubscription<dynamic>? socketSub;
  bool isConnecting = false;
  bool isConnected = false;
  String statusText = '尚未连接';
  String sessionMeta = '';
  int sessionCount = 0;
  int lastCols = 120;
  int lastRows = 36;

  _TerminalTabSession({
    required this.id,
    required this.label,
    required void Function(String) onOutput,
    required void Function(int cols, int rows) onResize,
    required void Function(String title) onTitleChange,
  }) {
    terminal = Terminal(
      maxLines: 5000,
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

  Future<void> dispose() async {
    clearHighlights();
    await socketSub?.cancel();
    try {
      await socket?.close(1000, 'tab closed');
    } catch (_) {}
    controller.dispose();
    focusNode.dispose();
  }
}

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

  final List<_TerminalTabSession> _tabs = [];
  int _activeTabIndex = 0;
  int _nextTabId = 1;

  double _fontSize = 14.0;
  String _terminalThemeId = 'ocean'; // ocean, dracula, solarized, matrix
  bool _broadcastToAllTabs = false;
  TerminalCursorType _cursorType = TerminalCursorType.block;

  bool _showSearchBar = false;
  final TextEditingController _searchCtrl = TextEditingController();
  int _searchMatchCount = 0;

  List<({String label, String command})> _quickSnippets = [
    (label: '📂 ls -la', command: 'ls -la\n'),
    (label: '💾 磁盘 df -h', command: 'df -h\n'),
    (label: '🧠 内存/负载', command: 'uptime && free -h 2>/dev/null || vm_stat\n'),
    (label: '⚙️ 进程排名前15', command: 'ps aux | head -n 16\n'),
    (
      label: '🌐 端口监听',
      command: 'netstat -tlpn 2>/dev/null || lsof -iTCP -sTCP:LISTEN -P -n\n'
    ),
    (label: '🐳 Docker容器', command: 'docker ps\n'),
    (
      label: '📜 查看最新日志',
      command: 'ls -lt *.log logs/*.log 2>/dev/null | head -n 10\n'
    ),
    (label: '🛑 Ctrl+C 中断', command: '\x03'),
  ];

  static const Map<String, ({String name, TerminalTheme theme})>
      _terminalThemes = {
    'ocean': (
      name: '深海青黑 (默认)',
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
      name: 'Matrix 极客绿黑',
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
  };

  TerminalTheme get _activeXtermTheme =>
      (_terminalThemes[_terminalThemeId] ?? _terminalThemes['ocean']!).theme;

  _TerminalTabSession get _activeTab =>
      _tabs[_activeTabIndex.clamp(0, _tabs.length - 1)];

  @override
  void initState() {
    super.initState();
    _createNewTab(autoConnect: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCustomSnippets();
      _connectTab(_activeTab);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  void _createNewTab({bool autoConnect = true}) {
    final tabId = _nextTabId++;
    late final _TerminalTabSession session;
    session = _TerminalTabSession(
      id: tabId,
      label: '终端 $tabId',
      onOutput: (data) => _handleTerminalUserInput(session, data),
      onResize: (cols, rows) => _sendResize(session, cols, rows),
      onTitleChange: (title) {
        if (mounted && title.trim().isNotEmpty) {
          setState(() => session.sessionMeta = title.trim());
        }
      },
    );

    session.terminal.write('\x1b[38;2;121;221;208m流光交互式系统终端 (${session.label})\x1b[0m\r\n');
    session.terminal.write('直接在终端区域内按键输入命令，支持顶部多标签并行会话。\r\n');

    setState(() {
      _tabs.add(session);
      _activeTabIndex = _tabs.length - 1;
    });

    if (autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _connectTab(session);
      });
    }
  }

  Future<void> _closeTab(int index) async {
    if (_tabs.length <= 1) {
      _clearTerminal(_activeTab);
      return;
    }
    final removed = _tabs.removeAt(index);
    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    }
    setState(() {});
    await removed.dispose();
    _activeTab.focusNode.requestFocus();
  }

  Future<void> _loadCustomSnippets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTheme = prefs.getString(_prefTerminalThemeKey);
      final savedSize = prefs.getDouble(_prefTerminalFontSizeKey);
      if (mounted) {
        setState(() {
          if (savedTheme != null && _terminalThemes.containsKey(savedTheme)) {
            _terminalThemeId = savedTheme;
          }
          if (savedSize != null) {
            _fontSize = savedSize.clamp(11.0, 22.0);
          }
        });
      }
      final raw = prefs.getString(_prefCustomSnippetsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
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

  Future<void> _saveCustomSnippets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _quickSnippets
          .map((s) => {'l': s.label, 'c': s.command})
          .toList();
      await prefs.setString(_prefCustomSnippetsKey, jsonEncode(encoded));
    } catch (_) {}
  }

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

  Future<void> _saveTerminalAppearance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefTerminalThemeKey, _terminalThemeId);
      await prefs.setDouble(_prefTerminalFontSizeKey, _fontSize);
    } catch (_) {}
  }

  void _sendToSingleTab(_TerminalTabSession tab, String data) {
    final ws = tab.socket;
    if (ws == null || !tab.isConnected) return;
    final bytes = utf8.encode(data);
    for (var offset = 0; offset < bytes.length; offset += _maxInputFrameBytes) {
      final end = (offset + _maxInputFrameBytes < bytes.length)
          ? offset + _maxInputFrameBytes
          : bytes.length;
      ws.add(bytes.sublist(offset, end));
    }
  }

  void _handleTerminalUserInput(_TerminalTabSession tab, String data) {
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
    final ws = tab.socket;
    if (ws == null || !tab.isConnected) return;
    final safeCols = cols.clamp(2, 500);
    final safeRows = rows.clamp(2, 200);
    ws.add(jsonEncode({'type': 'resize', 'cols': safeCols, 'rows': safeRows}));
  }

  Future<void> _connectTab(_TerminalTabSession tab) async {
    if (tab.isConnecting || tab.isConnected) return;
    setState(() {
      tab.isConnecting = true;
      tab.statusText = '正在建立终端会话...';
      tab.sessionMeta = '';
    });

    if (tab.sessionCount > 0) {
      tab.terminal.write('\r\n\x1b[90m──── 新会话 ────\x1b[0m\r\n');
    }

    try {
      final ws = await widget.appState.api.connectTerminalWebSocket();
      if (!mounted) {
        await ws.close();
        return;
      }

      tab.socket = ws;
      setState(() {
        tab.isConnecting = false;
        tab.isConnected = true;
        tab.sessionCount += 1;
        tab.statusText = '已连接';
      });

      _sendResize(tab, tab.lastCols, tab.lastRows);
      if (tab == _activeTab) {
        tab.focusNode.requestFocus();
      }

      tab.socketSub = ws.listen(
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
            tab.socket = null;
            tab.isConnected = false;
            tab.isConnecting = false;
            if (tab.statusText == '已连接') {
              tab.statusText = '已断开';
            }
          });
        },
      );
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
    } catch (_) {
      // Plain text terminal output
    }
    tab.terminal.write(frame);
  }

  Future<void> _disconnectTab(
    _TerminalTabSession tab, {
    bool silent = false,
  }) async {
    await tab.socketSub?.cancel();
    tab.socketSub = null;
    try {
      await tab.socket?.close(1000, 'client disconnect');
    } catch (_) {}
    tab.socket = null;
    if (!silent && mounted) {
      setState(() {
        tab.isConnected = false;
        tab.isConnecting = false;
        tab.statusText = '已断开';
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
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home${Platform.pathSeparator}Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final outPath =
          '${targetDir.path}${Platform.pathSeparator}terminal_session_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.log';
      await File(outPath).writeAsString(sb.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出终端会话日志：$outPath')),
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

  @override
  Widget build(BuildContext context) {
    final tab = _activeTab;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () {
          setState(() => _fontSize = (_fontSize + 1.0).clamp(11.0, 22.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () {
          setState(() => _fontSize = (_fontSize + 1.0).clamp(11.0, 22.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () {
          setState(() => _fontSize = (_fontSize - 1.0).clamp(11.0, 22.0));
          _saveTerminalAppearance();
        },
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () {
          setState(() => _fontSize = (_fontSize - 1.0).clamp(11.0, 22.0));
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
        // Top status, Multi-Tab switcher & action bar (horizontally scrollable on mobile)
        Container(
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
                          setState(() => _activeTabIndex = idx);
                          t.focusNode.requestFocus();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.16)
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
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
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
                  tooltip: '新建并行终端标签页',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _createNewTab(autoConnect: true),
                  icon: const Icon(Icons.add_rounded, size: 17),
                ),
                const SizedBox(width: 10),
                Text(
                  tab.statusText,
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
                if (tab.sessionMeta.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      tab.sessionMeta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textMuted,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: tab.isConnected || tab.isConnecting
                      ? null
                      : () => _connectTab(tab),
                  icon: const Icon(Icons.terminal_rounded, size: 16),
                  label: Text(
                    tab.isConnecting
                        ? '连接中...'
                        : (tab.sessionCount > 0 ? '重连会话' : '连接终端'),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: tab.isConnected || tab.isConnecting
                      ? () => _disconnectTab(tab)
                      : null,
                  child: const Text('断开'),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: () => _clearTerminal(tab),
                  child: const Text('清屏'),
                ),
                const SizedBox(width: 6),
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
                  tooltip: '切换终端配色主题',
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: VideoPlatformTheme.borderStrong),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.text_fields_rounded, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          '${_fontSize.toInt()}pt',
                          style: TextStyle(
                            fontSize: 12,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '放大终端字号 (Cmd/Ctrl + =)',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(
                      () => _fontSize = (_fontSize + 1.0).clamp(11.0, 22.0),
                    );
                    _saveTerminalAppearance();
                    tab.focusNode.requestFocus();
                  },
                  icon: const Icon(Icons.add_circle_outline, size: 17),
                ),
                IconButton(
                  tooltip: '缩小终端字号 (Cmd/Ctrl + -)',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(
                      () => _fontSize = (_fontSize - 1.0).clamp(11.0, 22.0),
                    );
                    _saveTerminalAppearance();
                    tab.focusNode.requestFocus();
                  },
                  icon: const Icon(Icons.remove_circle_outline, size: 17),
                ),
              ],
            ),
          ),
        ),

        // Inline Buffer Search Bar
        if (_showSearchBar)
          Container(
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
          ),

        // Quick DevOps Command Snippets Bar
        Container(
          height: 38,
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
                        onLongPress: idx >= 8
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
                    setState(
                      () => _broadcastToAllTabs = !_broadcastToAllTabs,
                    );
                    tab.focusNode.requestFocus();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
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
                label: const Text(
                  '自定义指令',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),

        // Full-bleed interactive xterm multi-tab stack (strict integer cell grid alignment)
        Expanded(
          child: MediaQuery.removePadding(
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
        ),
      ],
      ),
    );
  }
}
