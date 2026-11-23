import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/models.dart';
import '../../services/proxy_routing_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/cloud_music_player.dart';
import '../widgets/mobile_edge_swipe_back.dart';
import '../widgets/video_115_accelerate_button.dart';
import '../widgets/video_download_speed_badge.dart';
import '../widgets/video_proxy_node_selector.dart';
import '../widgets/video_proxy_stats_overlay.dart';
import '../../services/local_115_direct_service.dart';

class _TelegramDraft {
  final String text;
  final TelegramMessage? replyingTo;
  final List<TelegramOutgoingFile> files;
  final bool asFile;

  const _TelegramDraft({
    this.text = '',
    this.replyingTo,
    this.files = const [],
    this.asFile = false,
  });

  bool get isEmpty => text.trim().isEmpty && files.isEmpty;
}

class _TelegramButtonActionState {
  bool busy = false;
  String? activeButtonKey;
  final Map<String, String> attemptIds = {};
  String notice = '';
  bool isAlert = false;
  String answerUrl = '';
}

class _TgEmojiCategory {
  final String icon;
  final String title;
  final List<String> items;
  final bool isTextPhrase;

  const _TgEmojiCategory({
    required this.icon,
    required this.title,
    required this.items,
    this.isTextPhrase = false,
  });
}

const List<_TgEmojiCategory> _kTelegramEmojiCategories = [
  _TgEmojiCategory(
    icon: '😀',
    title: '笑脸与情绪',
    items: [
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃',
      '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙',
      '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫',
      '🤔', '🫡', '🤐', '🤨', '😐', '😑', '😶', '🫥', '😏', '😒',
      '🙄', '😬', '😮‍💨', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷',
      '🤒', '🤕', '🤢', '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '🤯',
      '🤠', '🥳', '🥸', '😎', '🤓', '🧐', '😕', '🫤', '😟', '🙁',
      '😮', '😯', '😲', '😳', '🥺', '🥹', '😦', '😧', '😨', '😰',
      '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫',
      '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '💩', '🤡',
      '👻', '👽', '🤖',
    ],
  ),
  _TgEmojiCategory(
    icon: '👋',
    title: '手势与互动',
    items: [
      '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳', '🫴', '👌',
      '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉',
      '👆', '🖕', '👇', '☝️', '🫵', '👍', '👎', '✊', '👊', '🤛',
      '🤜', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅',
      '🤳', '💪', '🦾', '🦵', '🦶', '👂', '👃', '🧠', '🫀', '👀',
      '👁️', '👅', '👄', '🫦', '👶', '🧒', '👦', '👧', '🧑', '👱',
      '👨', '🧔', '👩', '🧓', '👴', '👵', '🙍', '🙎', '🙅', '🙆',
      '💁', '🙋', '🧏', '🙇', '🤦', '🤷', '💃', '🕺', '🏃', '🚶',
    ],
  ),
  _TgEmojiCategory(
    icon: '❤️',
    title: '心形与符号',
    items: [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔',
      '❤️‍🔥', '❤️‍🩹', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝',
      '💟', '🔥', '✨', '🌟', '💫', '💥', '💢', '💦', '💨', '💤',
      '💯', '✅', '☑️', '✔️', '❌', '❎', '➕', '➖', '➗', '✖️',
      '❓', '❔', '❕', '❗', '‼️', '⁉️', '⭕', '🛑', '⛔', '📛',
      '🚫', '⚠️', '♻️', '🔱', '⚜️', '🔰', '🔔', '🔕', '📢', '📣',
      '💬', '💭', '🗯️', '♠️', '♣️', '♥️', '♦️', '🃏', '🎴', '🀄',
    ],
  ),
  _TgEmojiCategory(
    icon: '🐱',
    title: '动物与自然',
    items: [
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐻‍❄️', '🐨',
      '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🙈', '🙉', '🙊', '🐒',
      '🐔', '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🦇', '🐺', '🐗',
      '🐴', '🦄', '🐝', '🐛', '🦋', '🐌', '🐞', '🐜', '🐢', '🐍',
      '🦎', '🦖', '🦕', '🐙', '🦑', '🦐', '🦞', '🦀', '🐡', '🐠',
      '🐟', '🐬', '🐳', '🐋', '🦈', '🐊', '🐅', '🐆', '🦓', '🦍',
      '💐', '🌸', '💮', '🌹', '🌺', '🌻', '🌼', '🌷', '🌱', '🪴',
      '🌲', '🌳', '🌴', '🌵', '🍀', '🍁', '🍂', '🍃', '☀️', '🌙',
      '⭐', '🌈', '⚡', '❄️', '🌊',
    ],
  ),
  _TgEmojiCategory(
    icon: '🍔',
    title: '美食与饮品',
    items: [
      '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈',
      '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🥑', '🍆', '🥔',
      '🥕', '🌽', '🌶️', '🥒', '🥦', '🍄', '🥜', '🥐', '🍞', '🥖',
      '🧀', '🥚', '🍳', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🌭',
      '🍔', '🍟', '🍕', '🥪', '🌮', '🌯', '🥗', '🥘', '🍝', '🍜',
      '🍲', '🍛', '🍣', '🍱', '🥟', '🍤', '🍙', '🍚', '🍘', '🍥',
      '🥮', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁', '🍰', '🎂',
      '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '☕', '🍵', '🧋',
      '🥤', '🍺', '🍻', '🥂', '🍷', '🥃', '🍸', '🍹',
    ],
  ),
  _TgEmojiCategory(
    icon: '🎉',
    title: '活动与数码',
    items: [
      '🎉', '🎊', '🎈', '🎂', '🎀', '🎁', '🎇', '🎆', '🧨', '🏆',
      '🥇', '🥈', '🥉', '🏅', '🎖️', '⚽', '🏀', '🏈', '⚾', '🎾',
      '🏐', '🎱', '🏓', '🏸', '🎮', '🕹️', '🎲', '🎯', '🎳', '🎰',
      '🎬', '🎤', '🎧', '🎼', '🎹', '🥁', '🎷', '🎺', '🎸', '🎻',
      '📱', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '📷', '📸', '📹', '🎥',
      '📽️', '🎞️', '📺', '📻', '🔋', '🔌', '💡', '🔦', '🕯️', '💰',
      '💴', '💵', '💶', '💷', '💳', '💎', '🚀', '✈️', '🚗', '🏎️',
      '🚓', '🚑', '🚒', '🚢', '🏠', '🏢', '🏝️', '🏔️',
    ],
  ),
  _TgEmojiCategory(
    icon: '✨',
    title: '颜文字与快捷语',
    isTextPhrase: true,
    items: [
      '(づ｡◕‿‿◕｡)づ',
      '¯\\_(ツ)_/¯',
      '(╯°□°）╯︵ ┻━┻',
      '┬─┬ノ( º _ ºノ)',
      '(❁´◡`❁)',
      '(≧∇≦)ﾉ',
      '(｡♥‿♥｡)',
      '(•_•) ( •_•)>⌐■-■ (⌐■_■)',
      '(っ˘ω˘ς )',
      '✧(≖ ◡ ≖✿)',
      '(ง •_•)ง',
      '收到，谢谢！👍',
      '辛苦了！🙏',
      '好的，马上处理 ✅',
      '清晰度非常棒 🎬',
      '求补档 / 感谢分享 ❤️',
    ],
  ),
];

/// Official Telegram Desktop / Telegram macOS color palette tokens
class _TgPalette {
  final bool isDark;

  const _TgPalette(this.isDark);

  Color get folderRailBg =>
      isDark ? const Color(0xFF0E1621) : const Color(0xFF293A4C);
  Color get folderRailIconActive => const Color(0xFF5EB5F7);
  Color get folderRailIconInactive =>
      isDark ? const Color(0xFF768C9E) : const Color(0xFFA6B8C7);

  Color get sidebarBg =>
      isDark ? const Color(0xFF17212B) : const Color(0xFFFFFFFF);
  Color get sidebarHover =>
      isDark ? const Color(0xFF202B36) : const Color(0xFFF1F3F6);
  Color get sidebarSelected =>
      isDark ? const Color(0xFF2B5278) : const Color(0xFF419FD9);
  Color get searchFill =>
      isDark ? const Color(0xFF242F3D) : const Color(0xFFF1F2F4);

  Color get chatWallpaperBg =>
      isDark ? const Color(0xFF0E1621) : const Color(0xFFD6E3CE);
  Color get headerBg =>
      isDark ? const Color(0xFF17212B) : const Color(0xFFFFFFFF);
  Color get composeBg =>
      isDark ? const Color(0xFF17212B) : const Color(0xFFFFFFFF);

  Color get bubbleIn =>
      isDark ? const Color(0xFF182533) : const Color(0xFFFFFFFF);
  Color get bubbleOut =>
      isDark ? const Color(0xFF2B5278) : const Color(0xFFEFFDDE);
  Color get bubbleSelected =>
      isDark ? const Color(0xFF244263) : const Color(0xFFD4ECFC);

  Color get datePillBg =>
      isDark ? const Color(0xCC1E2C3A) : const Color(0x88536D50);

  Color get tgBlue =>
      isDark ? const Color(0xFF5288C1) : const Color(0xFF3390EC);
  Color get tgBlueBright => const Color(0xFF3E99EE);

  Color get textPrimary =>
      isDark ? const Color(0xFFF5F5F5) : const Color(0xFF18191C);
  Color get textSecondary =>
      isDark ? const Color(0xFF7F91A4) : const Color(0xFF707579);
  Color get textMuted =>
      isDark ? const Color(0xFF6C7883) : const Color(0xFF9AA0A6);
  Color get borderLine =>
      isDark ? const Color(0xFF101921) : const Color(0xFFE4E7EB);

  static const List<List<Color>> avatarGradients = [
    [Color(0xFFFF885E), Color(0xFFE5534B)], // Red-Orange
    [Color(0xFFFFCD6A), Color(0xFFFF9636)], // Amber-Orange
    [Color(0xFF82B1FF), Color(0xFF665FFF)], // Violet-Indigo
    [Color(0xFFA0DE7E), Color(0xFF46BA67)], // Emerald-Green
    [Color(0xFF53EDD6), Color(0xFF28C9B7)], // Cyan-Teal
    [Color(0xFF72D5FD), Color(0xFF2A9EF1)], // Sky-Blue
    [Color(0xFFE0A2F3), Color(0xFFD669ED)], // Pink-Purple
  ];

  static List<Color> peerAvatarColors(String seed) {
    final idx = seed.hashCode.abs() % avatarGradients.length;
    return avatarGradients[idx];
  }

  static Color peerNameColor(String seed) {
    return peerAvatarColors(seed).last;
  }
}

class TelegramScreen extends StatefulWidget {
  final AppState appState;

  const TelegramScreen({
    super.key,
    required this.appState,
  });

  @override
  State<TelegramScreen> createState() => _TelegramScreenState();
}

class _TelegramScreenState extends State<TelegramScreen> {
  final _inlinePlaybackOwner = ValueNotifier<Object?>(null);
  // Static in-memory session cache so switching between chats, folders, or app
  // tabs restores the conversation and scroll position in 0ms without re-fetching.
  static List<TelegramAccount> _cachedAccounts = [];
  static String _cachedActiveAccountId = 'default';
  static TelegramAuthStatus _cachedAuthStatus = const TelegramAuthStatus();
  static String _cachedSelectedFolderKey = '0';
  static final Map<String, List<TelegramFolder>> _cachedFoldersByAccount = {};
  static final Map<String, ({List<TelegramChat> chats, String nextCursor})>
      _cachedChatsByAccountFolder = {};
  static final Map<
    String,
    ({List<TelegramMessage> messages, int nextOffset, double? scrollOffset})
  > _cachedMessagesByPeer = {};
  static final Map<String, TelegramChat> _cachedSelectedChatByAccount = {};

  List<TelegramAccount> _accounts = [];
  String _activeAccountId = 'default';
  TelegramAuthStatus _authStatus = const TelegramAuthStatus();

  List<TelegramFolder> _folders = const [
    TelegramFolder(key: '0', title: '全部会话'),
    TelegramFolder(key: '1', title: '已归档'),
  ];
  String _selectedFolderKey = '0';

  List<TelegramChat> _chats = [];
  String _nextChatCursor = '';
  bool _isLoadingChats = false;
  String _chatFilter = '';
  bool _isMobileChatSearchOpen = false;

  TelegramChat? _selectedChat;
  bool _userExitedChat = false;

  bool get _isMobileLayout {
    final isMobilePlatform =
        (Platform.isAndroid || Platform.isIOS) && !widget.appState.isHardwareTv;
    if (!mounted) return isMobilePlatform;
    final mq = MediaQuery.maybeSizeOf(context);
    if (mq != null) {
      if (isMobilePlatform && mq.shortestSide < 600) {
        return true;
      }
      return mq.width < 860 && !(widget.appState.tvMode && mq.width >= 760);
    }
    return isMobilePlatform;
  }

  void _exitCurrentChatOnMobile() {
    _saveCurrentDraft();
    _stopOutgoingTyping();
    setState(() {
      _userExitedChat = true;
      _selectedChat = null;
      _showRightInfoPanel = false;
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
    _cachedSelectedChatByAccount.remove(_activeAccountId);
    _syncReadingContext();
  }
  List<TelegramMessage> _messages = [];
  int _nextMessageOffset = 0;
  bool _isLoadingMessages = false;
  String _messageFilter = '';
  bool _showInChatSearch = false;
  String _mediaTypeFilter = 'all'; // all, video, photo, file, link
  bool _showRightInfoPanel = false;
  bool _isDialogsSidebarCollapsed = false;

  TelegramMessage? _replyingToMessage;
  final Set<int> _selectedMessageIds = {};
  bool _selectionMode = false;
  final Set<String> _pendingDownloads = {};
  final Set<String> _queuedDownloads = {};
  final Set<String> _failedDownloads = {};
  final Set<int> _pendingLocalSaves = {};
  final Set<int> _completedLocalSaves = {};
  final Set<int> _failedLocalSaves = {};
  String _downloadHudText = '';
  String _downloadHudState = ''; // 'loading', 'success', 'error'
  Timer? _downloadHudTimer;

  final TextEditingController _chatSearchCtrl = TextEditingController();
  final TextEditingController _msgSearchCtrl = TextEditingController();
  final TextEditingController _composeController = TextEditingController();
  final TextEditingController _emojiSearchCtrl = TextEditingController();
  final ScrollController _chatListScrollController = ScrollController();
  final ScrollController _messageScrollController = ScrollController();
  final FocusNode _composeFocusNode = FocusNode();
  final GlobalKey _captureBoundaryKey = GlobalKey();
  final GlobalKey _chatListContainerKey = GlobalKey();
  final GlobalKey _messageListContainerKey = GlobalKey();
  final GlobalKey _conversationHeaderContainerKey = GlobalKey();
  final GlobalKey _conversationBottomBarKey = GlobalKey();
  final FocusNode _headerConversationActionFocusNode =
      FocusNode(debugLabel: 'TgHeaderConvAction');

  static const MethodChannel _nativeUtilsChannel = MethodChannel(
    'com.linsion.m3u8_client/native_utils',
  );

  final bool _isSendingMessage = false;
  bool _showScrollToBottomBtn = false;
  bool _isHeaderDangerActionExpanded = false;
  DateTime _lastLoadOlderAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _statusBanner = '正在连接 Telegram...';
  bool _statusIsError = false;

  // Official Telegram Compose & Attachment Staging State
  final Map<String, _TelegramDraft> _drafts = {};
  List<TelegramOutgoingFile> _stagedFiles = [];
  bool _sendAsFile = false;
  final int _uploadPercent = 0;
  final String _uploadStatusText = '';
  bool _isDraggingFilesOverChat = false;
  String _activeSelectedBubbleText = '';

  // Official Telegram Emoji Panel & Formatting State
  bool _showEmojiPanel = false;
  int _selectedEmojiTab = 1; // 0 = 常用, 1..7 = _kTelegramEmojiCategories
  String _emojiSearchQuery = '';
  bool _showFormattingBar = false;
  List<String> _recentEmojis = [
    '😂', '👍', '❤️', '🔥', '🎉', '😭', '🙏', '✨',
    '🥳', '🤔', '😎', '💯', '🚀', '🎬', '📺', '👀',
    '🥰', '🤣', '👏', '🙌', '💪', '👌', '🫡', '🤩',
  ];

  // Live Polling & Typing State
  Timer? _livePollTimer;
  Timer? _typingCancelTimer;
  StreamSubscription<TelegramNotificationEvent>? _notifEventSub;
  int _lastTypingSentMs = 0;
  bool _isOutgoingTypingActive = false;
  int _livePollTickCount = 0;
  bool _isPollingLiveUpdates = false;
  bool _wasTelegramViewActive = false;

  static const _prefTgReadStateKey = 'm3u8_tg_read_state_v1';
  static const _prefTgRecentEmojisKey = 'm3u8_tg_recent_emojis_v1';
  static const _prefTgQuickRepliesKey = 'm3u8_tg_quick_replies_v1';
  static const _prefTgSavedLocalPathsKey = 'm3u8_tg_saved_local_paths_v1';
  static final Map<String, String> _savedLocalPathsByKey = {};

  // Official Telegram Optimistic Background Sending State
  static const int _kOptimisticIdBase = 900000000;
  static int _nextOptimisticSeq = 0;
  final Set<int> _sendingOptimisticMsgIds = {};
  final Map<
    int,
    ({
      String error,
      String text,
      List<TelegramOutgoingFile> files,
      bool asFile,
      int replyId,
      TelegramChat chat,
      List<int> groupOptimisticIds,
    })
  > _failedOptimisticMsgs = {};
  final Map<int, int> _optimisticUploadPercent = {};
  final Map<int, Uint8List> _optimisticPreviewBytesByMsgId = {};

  bool _isOptimisticMsgId(int id) => id >= _kOptimisticIdBase;

  final Map<String, int> _readUpToDateByPeer = {};
  final Map<String, int> _outboxReadMaxIdByPeer = {};
  final Map<String, _TelegramButtonActionState> _buttonActionStates = {};

  // Official Telegram Centralized Music & Voice Player State
  Player? _audioPlayer;
  StreamSubscription<bool>? _audioPlayingSub;
  StreamSubscription<Duration>? _audioPosSub;
  StreamSubscription<Duration>? _audioDurSub;
  StreamSubscription<bool>? _audioCompletedSub;
  StreamSubscription<String>? _audioErrorSub;
  String _playingAudioAccountId = '';
  TelegramChat? _playingAudioChat;
  TelegramMessage? _playingAudioMessage;
  List<TelegramMessage> _playingAudioPlaylist = [];
  bool _isAudioPlaying = false;
  bool _isAudioLoading = false;
  String _audioErrorText = '';
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;
  double _audioSpeed = 1.0;
  String _audioPlayMode = 'sequential'; // 'sequential', 'repeatAll', 'repeatOne', 'shuffle'
  bool _audioUsedFallbackUrl = false;
  bool _audioHandlingCompletion = false;
  bool _audioHasStartedPlaying = false;
  int _audioOpenSeq = 0;
  List<String> _quickReplies = [
    '收到，马上处理 👍',
    '感谢分享资源！🙏',
    '已加入流光下载队列 ✅',
    '请问有1080P/4K原盘链接吗？',
    '稍等，我看一下回复你。',
  ];

  @override
  void initState() {
    super.initState();
    CloudMusicController.registerExternalAudioStopper(_stopAndCloseAudioPlayer);
    _messageScrollController.addListener(_onMessageScroll);
    widget.appState.addListener(_onAppStateChanged);
    _nativeUtilsChannel.setMethodCallHandler(_handleNativeUtilsMethodCall);
    _notifEventSub = widget.appState.telegramNotifications.eventStream.listen(
      _onRealtimeNotificationEvent,
    );
    _restoreFromSessionCacheIfAvailable();
    _syncReadingContext();
    _initAndBootstrapTelegram();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotificationJump();
    });
  }

  Future<dynamic> _handleNativeUtilsMethodCall(MethodCall call) async {
    if (!mounted) return null;
    if (call.method == 'onFileDragUpdated') {
      final args = call.arguments;
      final active =
          (args is Map && args['active'] == true) && _selectedChat != null;
      if (_isDraggingFilesOverChat != active) {
        setState(() => _isDraggingFilesOverChat = active);
      }
      return null;
    }
    if (call.method == 'onFilesDropped') {
      if (_isDraggingFilesOverChat) {
        setState(() => _isDraggingFilesOverChat = false);
      }
      final chat = _selectedChat;
      if (chat == null || chat.readOnly) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先打开一个可发言的 Telegram 会话再拖拽发送文件')),
        );
        return null;
      }
      final rawList = call.arguments;
      if (rawList is List) {
        final droppedFiles = <TelegramOutgoingFile>[];
        for (final item in rawList) {
          if (item is Map) {
            final name = (item['name'] ?? '附件').toString();
            Uint8List bytes = item['bytes'] is Uint8List
                ? item['bytes'] as Uint8List
                : Uint8List(0);
            final path = item['path']?.toString();
            int size = (item['size'] as num?)?.toInt() ?? bytes.length;
            if (path != null && path.isNotEmpty) {
              try {
                final fileObj = File(path);
                if (await fileObj.exists()) {
                  if (size <= 0) {
                    size = await fileObj.length();
                  }
                  if (bytes.isEmpty &&
                      size > 0 &&
                      size <= 25 * 1024 * 1024) {
                    bytes = await fileObj.readAsBytes();
                  }
                }
              } catch (_) {}
            }
            if (size > 0 &&
                (bytes.isNotEmpty || (path != null && path.isNotEmpty))) {
              droppedFiles.add(
                TelegramOutgoingFile(
                  name: name,
                  bytes: bytes,
                  mimeType: _guessMimeType(name),
                  filePath: path,
                  fileSize: size,
                ),
              );
            }
          }
        }
        if (droppedFiles.isNotEmpty && mounted) {
          final allImages = droppedFiles.every((f) => f.isImage);
          _stageOrPreviewOutgoingFiles(
            droppedFiles,
            asFile: !allImages,
            openPreviewDialog: true,
            dialogTitle: allImages
                ? '拖拽发送图片 (${droppedFiles.length})'
                : '拖拽发送文件 (${droppedFiles.length})',
          );
        }
      }
      return null;
    }
    return null;
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final isNowActive = widget.appState.isTelegramViewActive;
    if (isNowActive) {
      widget.appState.activeChildBackHandler = _handleBackPress;
      if (!_wasTelegramViewActive && _authStatus.authorized) {
        widget.appState.telegramNotifications.registerActiveAccountId(
          _activeAccountId,
        );
        unawaited(_pollLiveUpdates(forceChatListSync: true));
      }
    } else if (widget.appState.activeChildBackHandler == _handleBackPress) {
      widget.appState.activeChildBackHandler = null;
    }
    _wasTelegramViewActive = isNowActive;
    _checkPendingNotificationJump();
  }

  void _syncReadingContext() {
    widget.appState.updateTelegramReadingContext(
      accountId: _activeAccountId,
      peer: _selectedChat?.peer ?? '',
      atBottom: !_showScrollToBottomBtn,
    );
  }

  Future<void> _checkPendingNotificationJump() async {
    final target = widget.appState.consumePendingTelegramJumpTarget();
    if (target == null || !mounted) return;

    if (target.accountId.isNotEmpty && target.accountId != _activeAccountId) {
      await _bootstrapTelegram(
        preferredAccountId: target.accountId,
        forceRefresh: true,
      );
      if (!mounted) return;
    }

    final existingChat = _chats.where((c) => c.peer == target.peer).toList();
    if (existingChat.isNotEmpty) {
      await _selectChat(existingChat.first);
      return;
    }

    final parts = target.peer.split(':');
    if (parts.length == 2 && target.messageId > 0) {
      await _openOrResolveLink(
        'telegram://${parts[0]}/${parts[1]}/${target.messageId}',
      );
    } else {
      await _selectChat(
        TelegramChat(
          peer: target.peer,
          title: target.peer,
        ),
      );
    }
  }

  void _onRealtimeNotificationEvent(TelegramNotificationEvent event) {
    if (!mounted || event.accountId != _activeAccountId) return;

    if (event.foldersChanged || event.refresh) {
      unawaited(
        widget.appState.api
            .fetchTelegramFolders(_activeAccountId)
            .then((loaded) {
          if (mounted && loaded.isNotEmpty) {
            setState(() => _folders = loaded);
            _cachedFoldersByAccount[_activeAccountId] =
                List<TelegramFolder>.from(loaded);
          }
        }).catchError((_) {}),
      );
      if (event.refresh) {
        unawaited(_pollLiveUpdates(forceChatListSync: true));
      }
    }

    final msg = event.message;
    final activeChat = _selectedChat;

    // 0. Update read_outbox_max_id in real time when recipient reads our sent messages/files
    if (event.readOutboxMaxId > 0 && event.peer.isNotEmpty) {
      final peerKey = _peerReadKey(event.peer);
      final prevMax = _outboxReadMaxIdByPeer[peerKey] ?? 0;
      if (event.readOutboxMaxId > prevMax) {
        _outboxReadMaxIdByPeer[peerKey] = event.readOutboxMaxId;
      }
      final nextMax = _outboxReadMaxIdByPeer[peerKey] ?? event.readOutboxMaxId;
      bool outboxUpdated = false;
      final chatIdx = _chats.indexWhere((c) => c.peer == event.peer);
      if (chatIdx >= 0 && _chats[chatIdx].readOutboxMaxId < nextMax) {
        _chats[chatIdx] = _chats[chatIdx].copyWith(readOutboxMaxId: nextMax);
        outboxUpdated = true;
      }
      if (activeChat != null &&
          activeChat.peer == event.peer &&
          activeChat.readOutboxMaxId < nextMax) {
        _selectedChat = activeChat.copyWith(readOutboxMaxId: nextMax);
        outboxUpdated = true;
      }
      if (outboxUpdated || activeChat?.peer == event.peer) {
        setState(() {});
        _saveCurrentChatToMemoryCache();
      }
    }

    // 1. Update chat list preview, topMessageId, date & unread in real time
    if (msg != null && event.peer.isNotEmpty) {
      final idx = _chats.indexWhere((c) => c.peer == event.peer);
      if (idx >= 0) {
        final existing = _chats[idx];
        final isNewer =
            existing.topMessageId <= 0 || msg.id >= existing.topMessageId;
        if (isNewer) {
          final isCurrentlyReading =
              activeChat?.peer == event.peer && !_showScrollToBottomBtn;
          final rawPreview = msg.text.trim().isNotEmpty
              ? msg.text.trim()
              : (msg.attachment != null
                  ? '[${msg.attachment!.displayName}]'
                  : existing.preview);
          final preview = rawPreview.characters.take(120).toString();
          final nextUnread = isCurrentlyReading
              ? 0
              : (event.newMessage && !msg.outgoing
                  ? existing.unread + 1
                  : existing.unread);
          final updatedChat = existing.copyWith(
            topMessageId: msg.id > existing.topMessageId
                ? msg.id
                : existing.topMessageId,
            preview: preview,
            date: msg.date > 0 ? msg.date : existing.date,
            unread: nextUnread,
            muted: event.notificationMuted ? true : existing.muted,
          );
          setState(() {
            if (event.newMessage && idx > 0) {
              _chats.removeAt(idx);
              _chats.insert(0, updatedChat);
            } else {
              _chats[idx] = updatedChat;
            }
          });
        }
      } else if (event.newMessage) {
        final rawPreview = msg.text.trim().isNotEmpty
            ? msg.text.trim()
            : (msg.attachment != null
                ? '[${msg.attachment!.displayName}]'
                : '');
        final newTitle = event.chatTitle.trim().isNotEmpty
            ? event.chatTitle.trim()
            : (msg.sender.trim().isNotEmpty ? msg.sender.trim() : event.peer);
        final inserted = TelegramChat(
          peer: event.peer,
          title: newTitle,
          preview: rawPreview.characters.take(120).toString(),
          date: msg.date > 0
              ? msg.date
              : DateTime.now().millisecondsSinceEpoch ~/ 1000,
          unread: msg.outgoing ? 0 : 1,
          topMessageId: msg.id,
          muted: event.notificationMuted,
        );
        setState(() {
          _chats = [inserted, ..._chats];
        });
        unawaited(_loadFoldersAndChats(loadMore: false, silent: true));
      }
    } else if (event.newMessage && event.peer.isNotEmpty) {
      // SSE notification without embedded message payload -> immediately pull latest messages
      if (activeChat != null && event.peer == activeChat.peer) {
        unawaited(_loadMessages(loadOlder: false, silent: true));
      }
      unawaited(_loadFoldersAndChats(loadMore: false, silent: true));
    }

    // 1b. Update in-memory message cache for background chats so switching to them is 0ms up-to-date
    if (msg != null &&
        msg.id > 0 &&
        msg.hasRenderableContent &&
        event.peer.isNotEmpty &&
        activeChat?.peer != event.peer) {
      final peerKey = _peerReadKey(event.peer);
      final cached = _cachedMessagesByPeer[peerKey];
      if (cached != null) {
        final nextList = List<TelegramMessage>.from(cached.messages);
        final existingIdx = nextList.indexWhere((m) => m.id == msg.id);
        if (existingIdx >= 0) {
          nextList[existingIdx] = msg;
        } else {
          nextList.add(msg);
          nextList.sort((a, b) => a.id.compareTo(b.id));
        }
        _cachedMessagesByPeer[peerKey] = (
          messages: nextList,
          nextOffset: cached.nextOffset,
          scrollOffset: cached.scrollOffset,
        );
      }
    }

    // 2. Update active open conversation messages in real time
    if (activeChat != null && event.peer == activeChat.peer) {
      bool changed = false;
      if (event.deletedIds.isNotEmpty) {
        final delSet = event.deletedIds.toSet();
        final beforeLen = _messages.length;
        _messages = _messages.where((m) => !delSet.contains(m.id)).toList();
        if (_messages.length != beforeLen) changed = true;
      }
      if (msg != null && msg.id > 0) {
        final nextMessages = List<TelegramMessage>.from(_messages);
        // If this is an outgoing message confirmed via SSE, remove any matching optimistic placeholder
        if (msg.outgoing) {
          final optIdx = nextMessages.indexWhere(
            (m) =>
                _isOptimisticMsgId(m.id) &&
                m.text.trim() == msg.text.trim() &&
                (m.attachment?.displayName ?? '') ==
                    (msg.attachment?.displayName ?? ''),
          );
          if (optIdx >= 0) {
            final optId = nextMessages[optIdx].id;
            nextMessages.removeAt(optIdx);
            _sendingOptimisticMsgIds.remove(optId);
            _optimisticUploadPercent.remove(optId);
            _optimisticPreviewBytesByMsgId.remove(optId);
            changed = true;
          }
        }
        final existingIdx = nextMessages.indexWhere((m) => m.id == msg.id);
        if (!msg.hasRenderableContent) {
          if (existingIdx >= 0) {
            nextMessages.removeAt(existingIdx);
            changed = true;
          }
        } else if (existingIdx >= 0) {
          nextMessages[existingIdx] = msg;
          changed = true;
        } else {
          nextMessages.add(msg);
          nextMessages.sort((a, b) => a.id.compareTo(b.id));
          changed = true;
        }
        if (changed) {
          _messages = nextMessages;
        }
      }
      if (changed) {
        setState(() {});
        _saveCurrentChatToMemoryCache();
        final realMsgs =
            _messages.where((m) => !_isOptimisticMsgId(m.id)).toList();
        if (!_showScrollToBottomBtn && realMsgs.isNotEmpty) {
          _markChatAsRead(
            activeChat,
            latestMessageDate: realMsgs.last.date,
            maxMessageId: realMsgs.last.id,
          );
          _scrollToBottom(animated: true);
        }
      }
    }
  }

  void _restoreFromSessionCacheIfAvailable() {
    if (_cachedAccounts.isEmpty || !_cachedAuthStatus.authorized) return;
    _accounts = List<TelegramAccount>.from(_cachedAccounts);
    _activeAccountId = _cachedActiveAccountId;
    _authStatus = _cachedAuthStatus;
    _selectedFolderKey = _cachedSelectedFolderKey;
    final cachedFolders = _cachedFoldersByAccount[_activeAccountId];
    if (cachedFolders != null && cachedFolders.isNotEmpty) {
      _folders = List<TelegramFolder>.from(cachedFolders);
    }
    final folderKey = '$_activeAccountId|$_selectedFolderKey';
    final cachedChatData = _cachedChatsByAccountFolder[folderKey];
    final isMobilePlatform =
        (Platform.isAndroid || Platform.isIOS) && !widget.appState.tvMode;
    final cachedSel = isMobilePlatform
        ? null
        : _cachedSelectedChatByAccount[_activeAccountId];
    if (cachedChatData != null) {
      _chats = _applyReadStateToChats(
        cachedChatData.chats,
        activeSelectedPeer: cachedSel?.peer,
      );
      _nextChatCursor = cachedChatData.nextCursor;
      _statusBanner = '${_chats.length} 个会话';
    }
    if (cachedSel != null) {
      _selectedChat = cachedSel;
      final peerKey = _peerReadKey(cachedSel.peer);
      final cachedMsgs = _cachedMessagesByPeer[peerKey];
      if (cachedMsgs != null) {
        _messages = List<TelegramMessage>.from(cachedMsgs.messages);
        _nextMessageOffset = cachedMsgs.nextOffset;
        final savedScroll = cachedMsgs.scrollOffset;
        if (savedScroll != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_messageScrollController.hasClients) return;
            final maxExt = _messageScrollController.position.maxScrollExtent;
            _messageScrollController.jumpTo(savedScroll.clamp(0.0, maxExt));
          });
        } else {
          _scrollToBottom(animated: false);
        }
      }
    }
  }

  void _saveCurrentChatToMemoryCache() {
    _cachedAccounts = List<TelegramAccount>.from(_accounts);
    _cachedActiveAccountId = _activeAccountId;
    _cachedAuthStatus = _authStatus;
    _cachedSelectedFolderKey = _selectedFolderKey;
    _cachedFoldersByAccount[_activeAccountId] =
        List<TelegramFolder>.from(_folders);
    if (_chats.isNotEmpty) {
      _cachedChatsByAccountFolder['$_activeAccountId|$_selectedFolderKey'] = (
        chats: List<TelegramChat>.from(_chats),
        nextCursor: _nextChatCursor,
      );
    }
    final chat = _selectedChat;
    if (chat != null) {
      _cachedSelectedChatByAccount[_activeAccountId] = chat;
      final peerKey = _peerReadKey(chat.peer);
      final existing = _cachedMessagesByPeer[peerKey];
      final currentScroll = _messageScrollController.hasClients
          ? _messageScrollController.position.pixels
          : existing?.scrollOffset;
      if (_messages.isNotEmpty) {
        final tailMessages = _messages.length > 80
            ? _messages.sublist(_messages.length - 80)
            : _messages;
        _cachedMessagesByPeer.remove(peerKey);
        _cachedMessagesByPeer[peerKey] = (
          messages: List<TelegramMessage>.from(tailMessages),
          nextOffset: _messages.length > 80
              ? tailMessages.first.id
              : _nextMessageOffset,
          scrollOffset: currentScroll,
        );
        while (_cachedMessagesByPeer.length > 20) {
          _cachedMessagesByPeer.remove(_cachedMessagesByPeer.keys.first);
        }
      }
    } else {
      _cachedSelectedChatByAccount.remove(_activeAccountId);
    }
  }

  Future<void> _initAndBootstrapTelegram() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefTgReadStateKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final ts = int.tryParse(v.toString());
            if (ts != null && ts > 0) {
              _readUpToDateByPeer[k.toString()] = ts;
            }
          });
        }
      }
      final savedEmojis = prefs.getStringList(_prefTgRecentEmojisKey);
      if (savedEmojis != null && savedEmojis.isNotEmpty) {
        _recentEmojis = savedEmojis;
      }
      final savedQuick = prefs.getStringList(_prefTgQuickRepliesKey);
      if (savedQuick != null && savedQuick.isNotEmpty) {
        _quickReplies = savedQuick;
      }
      final rawSavedPaths = prefs.getString(_prefTgSavedLocalPathsKey);
      if (rawSavedPaths != null && rawSavedPaths.isNotEmpty) {
        final decodedPaths = jsonDecode(rawSavedPaths);
        if (decodedPaths is Map) {
          decodedPaths.forEach((k, v) {
            final p = v?.toString().trim() ?? '';
            if (p.isNotEmpty) {
              _savedLocalPathsByKey[k.toString()] = p;
            }
          });
        }
      }
    } catch (_) {}
    if (!mounted) return;
    if (_chats.isNotEmpty && _authStatus.authorized) {
      setState(() {});
      _startLivePolling();
      return;
    }
    await _bootstrapTelegram();
  }

  Future<void> _persistSavedLocalPaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_savedLocalPathsByKey.length > 1000) {
        final excess = _savedLocalPathsByKey.length - 800;
        final keysToRemove = _savedLocalPathsByKey.keys.take(excess).toList();
        for (final k in keysToRemove) {
          _savedLocalPathsByKey.remove(k);
        }
      }
      await prefs.setString(
        _prefTgSavedLocalPathsKey,
        jsonEncode(_savedLocalPathsByKey),
      );
    } catch (_) {}
  }

  String _savedLocalPathKey(TelegramChat chat, int messageId, {String? accountId}) {
    final acc = accountId ?? _activeAccountId;
    return '$acc|${chat.peer}|$messageId';
  }

  void _recordSavedLocalPath(
    TelegramChat chat,
    int messageId,
    String filePath, {
    String? accountId,
  }) {
    final cleanPath = filePath.trim();
    if (cleanPath.isEmpty) return;
    _savedLocalPathsByKey[_savedLocalPathKey(chat, messageId, accountId: accountId)] =
        cleanPath;
    _savedLocalPathsByKey['${chat.peer}|$messageId'] = cleanPath;
    _savedLocalPathsByKey['msg|$messageId'] = cleanPath;
    _completedLocalSaves.add(messageId);
    unawaited(_persistSavedLocalPaths());
  }

  String? _getSavedLocalPath(TelegramChat chat, TelegramMessage msg) {
    final p1 = _savedLocalPathsByKey[_savedLocalPathKey(chat, msg.id)];
    if (p1 != null && p1.isNotEmpty) return p1;
    final p2 = _savedLocalPathsByKey['${chat.peer}|${msg.id}'];
    if (p2 != null && p2.isNotEmpty) return p2;
    final p3 = _savedLocalPathsByKey['msg|${msg.id}'];
    if (p3 != null && p3.isNotEmpty) return p3;
    return null;
  }

  Future<void> _openLocalFileDirectory(String filePath) async {
    final cleanPath = filePath.trim();
    if (cleanPath.isEmpty) return;
    final file = File(cleanPath);
    final dirPath = file.parent.path;

    try {
      if (Platform.isMacOS) {
        final fileExists = await file.exists();
        final res = await Process.run(
          'open',
          fileExists ? ['-R', cleanPath] : [dirPath],
        );
        if (res.exitCode == 0) {
          _showDownloadHud('已在 Finder 中打开所在目录', state: 'success');
          return;
        }
      } else if (Platform.isWindows) {
        final fileExists = await file.exists();
        final res = await Process.run(
          'explorer.exe',
          fileExists ? ['/select,$cleanPath'] : [dirPath],
        );
        if (res.exitCode == 0) {
          _showDownloadHud('已在资源管理器中打开所在目录', state: 'success');
          return;
        }
      } else if (Platform.isLinux) {
        final res = await Process.run('xdg-open', [dirPath]);
        if (res.exitCode == 0) {
          _showDownloadHud('已打开文件所在目录', state: 'success');
          return;
        }
      }
    } catch (_) {}

    try {
      final dirUri = Uri.directory(dirPath);
      if (await launchUrl(dirUri, mode: LaunchMode.externalApplication)) {
        _showDownloadHud('已打开所在目录：$dirPath', state: 'success');
        return;
      }
    } catch (_) {}

    await Clipboard.setData(ClipboardData(text: cleanPath));
    _showDownloadHud('已复制本地文件路径：$cleanPath', state: 'success');
  }

  Future<void> _persistQuickReplies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefTgQuickRepliesKey, _quickReplies);
    } catch (_) {}
  }

  Future<void> _persistRecentEmojis() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefTgRecentEmojisKey, _recentEmojis);
    } catch (_) {}
  }

  Future<void> _persistReadState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefTgReadStateKey,
        jsonEncode(_readUpToDateByPeer),
      );
    } catch (_) {}
  }

  final Map<String, String> _knownPeerAvatars = {};
  final Map<String, String> _knownTitleAvatars = {};
  final Map<String, ({String photoId, int dcId, String hdUrl})>
      _knownPeerSharpAvatars = {};
  final Map<String, String> _knownTitleHdAvatarUrls = {};

  String _peerReadKey(String peer) => '$_activeAccountId|$peer';

  int _effectiveReadOutboxMaxId(TelegramChat chat) {
    final peerKey = _peerReadKey(chat.peer);
    final cached = _outboxReadMaxIdByPeer[peerKey] ?? 0;
    return chat.readOutboxMaxId > cached ? chat.readOutboxMaxId : cached;
  }

  bool _isOutgoingMessageRead(TelegramChat chat, TelegramMessage msg) {
    if (_isOptimisticMsgId(msg.id)) return false;
    if (chat.self) return true;
    final maxId = _effectiveReadOutboxMaxId(chat);
    return maxId > 0 && msg.id > 0 && msg.id <= maxId;
  }

  bool _isOutgoingAlbumRead(
    TelegramChat chat,
    List<TelegramMessage> albumMessages,
  ) {
    if (albumMessages.any((m) => _isOptimisticMsgId(m.id))) return false;
    if (chat.self) return true;
    final maxId = _effectiveReadOutboxMaxId(chat);
    return maxId > 0 &&
        albumMessages.isNotEmpty &&
        albumMessages.every((m) => m.id > 0 && m.id <= maxId);
  }

  List<TelegramChat> _applyReadStateToChats(
    List<TelegramChat> rawChats, {
    String? activeSelectedPeer,
  }) {
    return rawChats.map((rawChat) {
      var chat = rawChat;
      final peerKey = _peerReadKey(chat.peer);
      final cachedOutboxMax = _outboxReadMaxIdByPeer[peerKey] ?? 0;
      if (chat.readOutboxMaxId > cachedOutboxMax) {
        _outboxReadMaxIdByPeer[peerKey] = chat.readOutboxMaxId;
      } else if (cachedOutboxMax > chat.readOutboxMaxId) {
        chat = chat.copyWith(readOutboxMaxId: cachedOutboxMax);
      }
      final cleanTitle = chat.title.trim();
      final titleKey = cleanTitle.isNotEmpty
          ? '$_activeAccountId|$cleanTitle'
          : '';
      if (chat.avatar.isNotEmpty) {
        _knownPeerAvatars[peerKey] = chat.avatar;
        if (titleKey.isNotEmpty) {
          _knownTitleAvatars[titleKey] = chat.avatar;
        }
      } else {
        final cachedAvatar = _knownPeerAvatars[peerKey];
        if (cachedAvatar != null && cachedAvatar.isNotEmpty) {
          chat = chat.copyWith(avatar: cachedAvatar);
        }
      }

      if (cleanTitle.isNotEmpty) {
        widget.appState.registerTelegramChatTitle(
          _activeAccountId,
          chat.peer,
          cleanTitle,
        );
      }
      if (chat.muted) {
        widget.appState.telegramNotifications.recordServerChatMuteState(
          _activeAccountId,
          chat.peer,
          true,
        );
      }

      if (chat.hasSharpAvatar) {
        final hdUrl = widget.appState.api.buildTelegramAvatarUrl(
          accountId: _activeAccountId,
          peer: chat.peer,
          photoId: chat.avatarPhotoId,
          dcId: chat.avatarDcId,
        );
        _knownPeerSharpAvatars[peerKey] = (
          photoId: chat.avatarPhotoId,
          dcId: chat.avatarDcId,
          hdUrl: hdUrl,
        );
        if (titleKey.isNotEmpty) {
          _knownTitleHdAvatarUrls[titleKey] = hdUrl;
        }
      } else {
        final cachedSharp = _knownPeerSharpAvatars[peerKey];
        if (cachedSharp != null) {
          chat = chat.copyWith(
            avatarPhotoId: cachedSharp.photoId,
            avatarDcId: cachedSharp.dcId,
          );
        }
      }

      if (activeSelectedPeer != null && chat.peer == activeSelectedPeer) {
        final prev = _readUpToDateByPeer[peerKey] ?? 0;
        if (chat.date > prev) {
          _readUpToDateByPeer[peerKey] = chat.date;
        }
        return chat.unread > 0 ? chat.copyWith(unread: 0) : chat;
      }
      if (chat.unread <= 0) return chat;
      final readUpTo = _readUpToDateByPeer[peerKey] ?? 0;
      if (readUpTo > 0 && chat.date <= readUpTo) {
        return chat.copyWith(unread: 0);
      }
      return chat;
    }).toList();
  }

  void _markChatAsRead(
    TelegramChat chat, {
    int? latestMessageDate,
    int? maxMessageId,
  }) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final key = _peerReadKey(chat.peer);
    final prev = _readUpToDateByPeer[key] ?? 0;
    int readTs = chat.date > prev ? chat.date : prev;
    if (latestMessageDate != null && latestMessageDate > readTs) {
      readTs = latestMessageDate;
    }
    if (nowSec > readTs) {
      readTs = nowSec;
    }
    _readUpToDateByPeer[key] = readTs;
    unawaited(_persistReadState());
    widget.appState.telegramNotifications.dismissByPeer(
      _activeAccountId,
      chat.peer,
    );

    if (mounted) {
      setState(() {
        _chats = _chats.map((c) {
          if (c.peer == chat.peer && c.unread > 0) {
            return c.copyWith(unread: 0);
          }
          return c;
        }).toList();
        if (_selectedChat?.peer == chat.peer &&
            (_selectedChat?.unread ?? 0) > 0) {
          _selectedChat = _selectedChat!.copyWith(unread: 0);
        }
      });
    }

    unawaited(
      widget.appState.api.markTelegramChatRead(
        accountId: _activeAccountId,
        peer: chat.peer,
        maxId: maxMessageId ?? 0,
      ),
    );
  }

  Future<void> _showNotificationSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: widget.appState.telegramNotifications,
          builder: (context, _) {
            final svc = widget.appState.telegramNotifications;
            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: const Row(
                children: [
                  Icon(
                    Icons.notifications_active_rounded,
                    color: Color(0xFF3E99EE),
                    size: 22,
                  ),
                  SizedBox(width: 8),
                  Text('Telegram 跨平台消息通知设置', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3E99EE).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF3E99EE).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.verified_user_outlined,
                            size: 16,
                            color: Color(0xFF5EB5F7),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '状态：${svc.statusText}\n自动过滤 Telegram 已静默会话（Muted）与静默发送消息（Silent），绝不打扰。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '系统原生通知（macOS / iOS / Android / Windows / Linux）',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      subtitle: const Text(
                        '在后台或切换其他窗口时推送操作系统通知横幅与角标',
                        style: TextStyle(fontSize: 11.5),
                      ),
                      value: svc.systemNotificationsEnabled,
                      onChanged: (v) => svc.setSystemNotificationsEnabled(v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '应用内悬浮消息卡片（支持点播/直播/TV 全屏时提醒）',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      subtitle: const Text(
                        '点击卡片即可一键跳转至对应 Telegram 会话与消息',
                        style: TextStyle(fontSize: 11.5),
                      ),
                      value: svc.inAppNotificationsEnabled,
                      onChanged: (v) => svc.setInAppNotificationsEnabled(v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '新消息通知提示音',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      value: svc.soundEnabled,
                      onChanged: (v) => svc.setSoundEnabled(v),
                    ),
                  ],
                ),
              ),
              actions: [
                if (svc.pendingNotifications.isNotEmpty)
                  TextButton(
                    onPressed: svc.dismissAll,
                    child: const Text('清空当前未读提醒'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _markAllChatsAsRead() {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final c in _chats) {
      final key = _peerReadKey(c.peer);
      final ts = c.date > nowSec ? c.date : nowSec;
      _readUpToDateByPeer[key] = ts;
      if (c.unread > 0) {
        unawaited(
          widget.appState.api.markTelegramChatRead(
            accountId: _activeAccountId,
            peer: c.peer,
          ),
        );
      }
    }
    unawaited(_persistReadState());
    if (mounted) {
      setState(() {
        _chats = _chats
            .map((c) => c.unread > 0 ? c.copyWith(unread: 0) : c)
            .toList();
        if (_selectedChat != null && _selectedChat!.unread > 0) {
          _selectedChat = _selectedChat!.copyWith(unread: 0);
        }
      });
    }
  }

  void _tryLoadOlderMessagesOnScroll() {
    if (_selectedChat == null ||
        _isLoadingMessages ||
        _nextMessageOffset <= 0) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastLoadOlderAt).inMilliseconds < 350) {
      return;
    }
    _lastLoadOlderAt = now;
    _loadMessages(loadOlder: true);
  }

  void _onMessageScroll() {
    if (!_messageScrollController.hasClients) return;
    final pos = _messageScrollController.position;
    final shouldShow = pos.pixels > 260;
    if (shouldShow != _showScrollToBottomBtn && mounted) {
      setState(() => _showScrollToBottomBtn = shouldShow);
      _syncReadingContext();
    }
    if (pos.pixels >= pos.maxScrollExtent - 120 &&
        pos.userScrollDirection == ScrollDirection.reverse) {
      _tryLoadOlderMessagesOnScroll();
    }
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_messageScrollController.hasClients) return;
      if (animated) {
        _messageScrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _messageScrollController.jumpTo(0.0);
      }
    });
  }

  @override
  void dispose() {
    CloudMusicController.unregisterExternalAudioStopper(
      _stopAndCloseAudioPlayer,
    );
    if (widget.appState.activeChildBackHandler == _handleBackPress) {
      widget.appState.activeChildBackHandler = null;
    }
    widget.appState.removeListener(_onAppStateChanged);
    _notifEventSub?.cancel();
    _saveCurrentChatToMemoryCache();
    _stopOutgoingTyping();
    _downloadHudTimer?.cancel();
    _livePollTimer?.cancel();
    _typingCancelTimer?.cancel();
    _audioPlayingSub?.cancel();
    _audioPosSub?.cancel();
    _audioDurSub?.cancel();
    _audioCompletedSub?.cancel();
    _audioErrorSub?.cancel();
    _audioPlayer?.dispose();
    _inlinePlaybackOwner.dispose();
    _chatSearchCtrl.dispose();
    _msgSearchCtrl.dispose();
    _composeController.dispose();
    _emojiSearchCtrl.dispose();
    _chatListScrollController.dispose();
    _messageScrollController.dispose();
    _composeFocusNode.dispose();
    _headerConversationActionFocusNode.dispose();
    super.dispose();
  }

  bool _focusFirstInContainer(
    GlobalKey containerKey, {
    FocusNode? preferred,
  }) {
    if (preferred != null &&
        preferred.canRequestFocus &&
        preferred.context != null) {
      preferred.requestFocus();
      return true;
    }
    final containerCtx = containerKey.currentContext;
    if (containerCtx == null) return false;
    final scope = FocusScope.of(containerCtx);
    FocusNode? bestNode;
    double bestX = double.infinity;
    for (final node in scope.traversalDescendants) {
      if (!node.canRequestFocus || node.context == null) continue;
      if (!_isFocusNodeInsideContainer(node, containerKey)) continue;
      final r = node.rect;
      if (r.isEmpty || r.width <= 0 || r.height <= 0) continue;
      if (r.left < bestX) {
        bestX = r.left;
        bestNode = node;
      }
    }
    if (bestNode != null) {
      bestNode.requestFocus();
      return true;
    }
    return false;
  }

  bool _isFocusNodeInsideContainer(FocusNode? node, GlobalKey containerKey) {
    if (node == null) return false;
    final containerCtx = containerKey.currentContext;
    final nodeCtx = node.context;
    if (containerCtx == null || nodeCtx == null) return false;
    bool found = false;
    nodeCtx.visitAncestorElements((ancestor) {
      if (ancestor == containerCtx) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool _areFocusNodesNested(FocusNode a, FocusNode b) {
    final ctxA = a.context;
    final ctxB = b.context;
    if (ctxA == null || ctxB == null) return false;
    if (ctxA == ctxB) return true;
    bool nested = false;
    ctxA.visitAncestorElements((ancestor) {
      if (ancestor == ctxB) {
        nested = true;
        return false;
      }
      return true;
    });
    if (nested) return true;
    ctxB.visitAncestorElements((ancestor) {
      if (ancestor == ctxA) {
        nested = true;
        return false;
      }
      return true;
    });
    return nested;
  }

  FocusNode? _findVerticalFocusTargetInContainer({
    required GlobalKey containerKey,
    FocusNode? containerNode,
    required FocusNode currentNode,
    required bool moveUp,
  }) {
    final containerCtx = containerKey.currentContext;
    if (containerCtx == null || !currentNode.canRequestFocus) return null;
    final currentRect = currentNode.rect;
    if (currentRect.isEmpty) return null;

    final containerBox = containerCtx.findRenderObject() as RenderBox?;
    Rect? containerBounds;
    if (containerBox != null && containerBox.hasSize) {
      final topLeft = containerBox.localToGlobal(Offset.zero);
      containerBounds = topLeft & containerBox.size;
    }

    final Iterable<FocusNode> descendants = containerNode != null
        ? containerNode.traversalDescendants
        : FocusScope.of(containerCtx).traversalDescendants;

    FocusNode? bestNode;
    double bestScore = double.infinity;

    for (final node in descendants) {
      if (node == currentNode ||
          !node.canRequestFocus ||
          node.context == null) {
        continue;
      }
      if (containerNode == null &&
          !_isFocusNodeInsideContainer(node, containerKey)) {
        continue;
      }
      if (_areFocusNodesNested(currentNode, node)) {
        continue;
      }
      final r = node.rect;
      if (r.isEmpty || r.width <= 0 || r.height <= 0) continue;
      if (containerBounds != null) {
        if (r.bottom < containerBounds.top - 120 ||
            r.top > containerBounds.bottom + 120) {
          continue;
        }
      }
      if (moveUp) {
        if (r.center.dy >= currentRect.top - 2 ||
            r.top >= currentRect.top - 4) {
          continue;
        }
      } else {
        if (r.center.dy <= currentRect.bottom + 2 ||
            r.bottom <= currentRect.bottom + 4) {
          continue;
        }
      }

      final verticalDist = moveUp
          ? (currentRect.top - r.bottom).abs()
          : (r.top - currentRect.bottom).abs();
      final horizontalDist = (r.center.dx - currentRect.center.dx).abs();
      final score = verticalDist * 10.0 + horizontalDist * 0.25;
      if (score < bestScore) {
        bestScore = score;
        bestNode = node;
      }
    }

    return bestNode;
  }

  KeyEventResult _handleMessageListKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isUp = key == LogicalKeyboardKey.arrowUp;
    final isDown = key == LogicalKeyboardKey.arrowDown;
    if (!isUp && !isDown) {
      return KeyEventResult.ignored;
    }

    final currentFocus = FocusManager.instance.primaryFocus;
    if (currentFocus == null ||
        !_isFocusNodeInsideContainer(currentFocus, _messageListContainerKey)) {
      return KeyEventResult.ignored;
    }

    final containerBox =
        _messageListContainerKey.currentContext?.findRenderObject()
            as RenderBox?;
    final currentRect = currentFocus.rect;
    double? listTop;
    double? listBottom;
    double? listHeight;
    if (containerBox != null && containerBox.hasSize) {
      listTop = containerBox.localToGlobal(Offset.zero).dy;
      listHeight = containerBox.size.height;
      listBottom = listTop + listHeight;
    }

    if (_messageScrollController.hasClients) {
      final pos = _messageScrollController.position;
      if (isUp &&
          listTop != null &&
          listHeight != null &&
          currentRect.top < listTop + listHeight * 0.42 &&
          pos.pixels < pos.maxScrollExtent - 2) {
        final nextPixels =
            (pos.pixels + 220.0).clamp(0.0, pos.maxScrollExtent);
        _messageScrollController.jumpTo(nextPixels);
        if (nextPixels >= pos.maxScrollExtent - 180) {
          _tryLoadOlderMessagesOnScroll();
        }
      } else if (isDown &&
          listBottom != null &&
          listHeight != null &&
          currentRect.bottom > listBottom - listHeight * 0.38 &&
          pos.pixels > 2) {
        final nextPixels =
            (pos.pixels - 220.0).clamp(0.0, pos.maxScrollExtent);
        _messageScrollController.jumpTo(nextPixels);
      }
    }

    final target = _findVerticalFocusTargetInContainer(
      containerKey: _messageListContainerKey,
      containerNode: node,
      currentNode: currentFocus,
      moveUp: isUp,
    );

    if (target != null) {
      target.requestFocus();
      if (_messageScrollController.hasClients &&
          listTop != null &&
          listBottom != null) {
        final pos = _messageScrollController.position;
        final tr = target.rect;
        if (isUp && tr.top < listTop + 28 && pos.pixels < pos.maxScrollExtent - 2) {
          final delta = (listTop + 56) - tr.top;
          _messageScrollController.jumpTo(
            (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
          );
          if (_messageScrollController.position.pixels >=
              _messageScrollController.position.maxScrollExtent - 180) {
            _tryLoadOlderMessagesOnScroll();
          }
        } else if (isDown &&
            tr.bottom > listBottom - 28 &&
            pos.pixels > 2) {
          final delta = tr.bottom - (listBottom - 56);
          _messageScrollController.jumpTo(
            (pos.pixels - delta).clamp(0.0, pos.maxScrollExtent),
          );
        }
      }
      return KeyEventResult.handled;
    }

    if (isUp) {
      final hasMoreAbove = _messageScrollController.hasClients &&
          (_messageScrollController.position.pixels <
                  _messageScrollController.position.maxScrollExtent - 2 ||
              _isLoadingMessages ||
              _nextMessageOffset > 0);
      if (hasMoreAbove) {
        if (_messageScrollController.hasClients &&
            _messageScrollController.position.pixels <
                _messageScrollController.position.maxScrollExtent) {
          final pos = _messageScrollController.position;
          final nextPixels =
              (pos.pixels + 280.0).clamp(0.0, pos.maxScrollExtent);
          _messageScrollController.jumpTo(nextPixels);
        }
        if (!_messageScrollController.hasClients ||
            _messageScrollController.position.pixels >=
                _messageScrollController.position.maxScrollExtent - 220) {
          _tryLoadOlderMessagesOnScroll();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nextTarget = _findVerticalFocusTargetInContainer(
            containerKey: _messageListContainerKey,
            containerNode: node,
            currentNode: currentFocus,
            moveUp: true,
          );
          if (nextTarget != null) {
            nextTarget.requestFocus();
          } else {
            currentFocus.requestFocus();
          }
        });
        return KeyEventResult.handled;
      }
      if (_focusFirstInContainer(
        _conversationHeaderContainerKey,
      )) {
        return KeyEventResult.handled;
      }
    } else if (isDown) {
      final hasMoreBelow = _messageScrollController.hasClients &&
          _messageScrollController.position.pixels > 2;
      if (hasMoreBelow) {
        final pos = _messageScrollController.position;
        final nextPixels =
            (pos.pixels - 280.0).clamp(0.0, pos.maxScrollExtent);
        _messageScrollController.jumpTo(nextPixels);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nextTarget = _findVerticalFocusTargetInContainer(
            containerKey: _messageListContainerKey,
            containerNode: node,
            currentNode: currentFocus,
            moveUp: false,
          );
          if (nextTarget != null) {
            nextTarget.requestFocus();
          } else {
            currentFocus.requestFocus();
          }
        });
        return KeyEventResult.handled;
      }
      if (_focusFirstInContainer(
        _conversationBottomBarKey,
        preferred: _composeFocusNode,
      )) {
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  KeyEventResult _handleChatListKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isUp = key == LogicalKeyboardKey.arrowUp;
    final isDown = key == LogicalKeyboardKey.arrowDown;
    if (!isUp && !isDown) {
      return KeyEventResult.ignored;
    }

    final currentFocus = FocusManager.instance.primaryFocus;
    if (currentFocus == null ||
        !_isFocusNodeInsideContainer(currentFocus, _chatListContainerKey)) {
      return KeyEventResult.ignored;
    }

    final containerBox =
        _chatListContainerKey.currentContext?.findRenderObject() as RenderBox?;
    final currentRect = currentFocus.rect;
    double? listTop;
    double? listBottom;
    double? listHeight;
    if (containerBox != null && containerBox.hasSize) {
      listTop = containerBox.localToGlobal(Offset.zero).dy;
      listHeight = containerBox.size.height;
      listBottom = listTop + listHeight;
    }

    if (_chatListScrollController.hasClients) {
      final pos = _chatListScrollController.position;
      if (isUp &&
          listTop != null &&
          listHeight != null &&
          currentRect.top < listTop + listHeight * 0.35 &&
          pos.pixels > 2) {
        _chatListScrollController.jumpTo(
          (pos.pixels - 140.0).clamp(0.0, pos.maxScrollExtent),
        );
      } else if (isDown &&
          listBottom != null &&
          listHeight != null &&
          currentRect.bottom > listBottom - listHeight * 0.35 &&
          pos.pixels < pos.maxScrollExtent - 2) {
        _chatListScrollController.jumpTo(
          (pos.pixels + 140.0).clamp(0.0, pos.maxScrollExtent),
        );
      }
    }

    final target = _findVerticalFocusTargetInContainer(
      containerKey: _chatListContainerKey,
      containerNode: node,
      currentNode: currentFocus,
      moveUp: isUp,
    );
    if (target != null) {
      target.requestFocus();
      return KeyEventResult.handled;
    }

    if (isUp &&
        _chatListScrollController.hasClients &&
        _chatListScrollController.position.pixels > 2) {
      final pos = _chatListScrollController.position;
      _chatListScrollController.jumpTo(
        (pos.pixels - 200.0).clamp(0.0, pos.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final nextTarget = _findVerticalFocusTargetInContainer(
          containerKey: _chatListContainerKey,
          containerNode: node,
          currentNode: currentFocus,
          moveUp: true,
        );
        if (nextTarget != null) {
          nextTarget.requestFocus();
        } else {
          currentFocus.requestFocus();
        }
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _handleBackPress() {
    if (!mounted) return false;
    if (_selectionMode) {
      setState(() {
        _selectionMode = false;
        _selectedMessageIds.clear();
      });
      return true;
    }
    if (_showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
      return true;
    }
    if (_showInChatSearch) {
      setState(() {
        _showInChatSearch = false;
        _messageFilter = '';
        _msgSearchCtrl.clear();
      });
      return true;
    }
    if (_showRightInfoPanel) {
      setState(() => _showRightInfoPanel = false);
      return true;
    }
    if (!_isMobileLayout && _isDialogsSidebarCollapsed) {
      setState(() => _isDialogsSidebarCollapsed = false);
      return true;
    }
    if (_selectedChat != null) {
      _exitCurrentChatOnMobile();
      return true;
    }
    if (_isMobileChatSearchOpen || _chatFilter.isNotEmpty) {
      setState(() {
        _isMobileChatSearchOpen = false;
        _chatFilter = '';
        _chatSearchCtrl.clear();
      });
      return true;
    }
    return false;
  }

  void _startLivePolling() {
    _livePollTimer?.cancel();
    if (!_authStatus.authorized) return;
    widget.appState.telegramNotifications.registerActiveAccountId(
      _activeAccountId,
    );
    _livePollTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      _pollLiveUpdates();
    });
  }

  Future<void> _pollLiveUpdates({bool forceChatListSync = false}) async {
    if (!mounted ||
        !_authStatus.authorized ||
        _isLoadingChats ||
        _isLoadingMessages ||
        _isPollingLiveUpdates) {
      return;
    }
    _isPollingLiveUpdates = true;
    final tick = ++_livePollTickCount;
    final pollAccountId = _activeAccountId;
    final pollEpoch = _accountSwitchEpoch;
    try {
      final activeChat = _selectedChat;
      if (activeChat != null) {
        final msgRes = await widget.appState.api.fetchTelegramMessages(
          accountId: pollAccountId,
          peer: activeChat.peer,
          offsetId: 0,
          limit: 30,
        );
        if (!mounted ||
            _accountSwitchEpoch != pollEpoch ||
            _activeAccountId != pollAccountId ||
            _selectedChat?.peer != activeChat.peer) {
          return;
        }
        if (msgRes.messages.isNotEmpty) {
          final realExisting =
              _messages.where((m) => !_isOptimisticMsgId(m.id)).toList();
          final currentLastId =
              realExisting.isNotEmpty ? realExisting.last.id : 0;
          final fetchedLastId = msgRes.messages.last.id;
          final hasNewer = fetchedLastId > currentLastId;
          bool changed = false;
          final nextMessages = List<TelegramMessage>.from(_messages);
          final indexById = <int, int>{
            for (var i = 0; i < nextMessages.length; i++)
              nextMessages[i].id: i,
          };
          for (final m in msgRes.messages) {
            final idx = indexById[m.id];
            if (idx == null) {
              // If an outgoing message was just confirmed, remove matching optimistic placeholder
              if (m.outgoing) {
                final optIdx = nextMessages.indexWhere(
                  (opt) =>
                      _isOptimisticMsgId(opt.id) &&
                      opt.text.trim() == m.text.trim() &&
                      (opt.attachment?.displayName ?? '') ==
                          (m.attachment?.displayName ?? ''),
                );
                if (optIdx >= 0) {
                  final optId = nextMessages[optIdx].id;
                  nextMessages.removeAt(optIdx);
                  _sendingOptimisticMsgIds.remove(optId);
                  _optimisticUploadPercent.remove(optId);
                  _optimisticPreviewBytesByMsgId.remove(optId);
                }
              }
              nextMessages.add(m);
              changed = true;
            } else {
              final prev = nextMessages[idx];
              if (prev.text != m.text ||
                  prev.buttons.length != m.buttons.length ||
                  prev.attachment?.url != m.attachment?.url) {
                nextMessages[idx] = m;
                changed = true;
              }
            }
          }
          if (changed) {
            nextMessages.sort((a, b) => a.id.compareTo(b.id));
            setState(() {
              _messages = nextMessages;
              if (hasNewer) {
                final lastReal = msgRes.messages.last;
                final rawPreview = lastReal.text.trim().isNotEmpty
                    ? lastReal.text.trim()
                    : (lastReal.attachment != null
                        ? '[${lastReal.attachment!.displayName}]'
                        : '');
                final chatIdx =
                    _chats.indexWhere((c) => c.peer == activeChat.peer);
                if (chatIdx >= 0) {
                  final updated = _chats[chatIdx].copyWith(
                    topMessageId: lastReal.id > _chats[chatIdx].topMessageId
                        ? lastReal.id
                        : _chats[chatIdx].topMessageId,
                    preview: rawPreview.isNotEmpty
                        ? rawPreview.characters.take(120).toString()
                        : _chats[chatIdx].preview,
                    date: lastReal.date > 0
                        ? lastReal.date
                        : _chats[chatIdx].date,
                    unread: 0,
                  );
                  _chats[chatIdx] = updated;
                }
              }
            });
            _saveCurrentChatToMemoryCache();
            if (hasNewer && !_showScrollToBottomBtn) {
              final lastReal = msgRes.messages.last;
              _markChatAsRead(
                activeChat,
                latestMessageDate: lastReal.date,
                maxMessageId: lastReal.id,
              );
              _scrollToBottom(animated: true);
            }
          }
        }
      }
      if (!mounted ||
          _accountSwitchEpoch != pollEpoch ||
          _activeAccountId != pollAccountId) {
        return;
      }
      // Refresh chat list metadata (such as new chats, unread counts, and read_outbox_max_id) in background
      if (forceChatListSync || tick % 2 == 0) {
        await _loadFoldersAndChats(loadMore: false, silent: true);
      }
    } catch (_) {
    } finally {
      _isPollingLiveUpdates = false;
    }
  }

  void _saveCurrentDraft() {
    final chat = _selectedChat;
    if (chat == null) return;
    final key = _peerReadKey(chat.peer);
    final draft = _TelegramDraft(
      text: _composeController.text,
      replyingTo: _replyingToMessage,
      files: List<TelegramOutgoingFile>.from(_stagedFiles),
      asFile: _sendAsFile,
    );
    if (draft.isEmpty && draft.replyingTo == null) {
      _drafts.remove(key);
    } else {
      _drafts[key] = draft;
    }
  }

  void _restoreDraftForChat(TelegramChat chat) {
    final key = _peerReadKey(chat.peer);
    final draft = _drafts[key];
    _composeController.text = draft?.text ?? '';
    _composeController.selection = TextSelection.collapsed(
      offset: _composeController.text.length,
    );
    _replyingToMessage = draft?.replyingTo;
    _stagedFiles = draft != null
        ? List<TelegramOutgoingFile>.from(draft.files)
        : <TelegramOutgoingFile>[];
    _sendAsFile = draft?.asFile ?? false;
  }

  void _onComposeTextChanged(String value) {
    _saveCurrentDraft();
    setState(() {});
    final chat = _selectedChat;
    if (chat == null || chat.readOnly || value.trim().isEmpty) {
      _stopOutgoingTyping();
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastTypingSentMs >= 4000) {
      _lastTypingSentMs = nowMs;
      _isOutgoingTypingActive = true;
      unawaited(
        widget.appState.api.sendTelegramTyping(
          accountId: _activeAccountId,
          peer: chat.peer,
          active: true,
        ),
      );
    }
    _typingCancelTimer?.cancel();
    _typingCancelTimer = Timer(const Duration(seconds: 5), _stopOutgoingTyping);
  }

  void _stopOutgoingTyping() {
    _typingCancelTimer?.cancel();
    _typingCancelTimer = null;
    if (!_isOutgoingTypingActive) return;
    _isOutgoingTypingActive = false;
    final chat = _selectedChat;
    if (chat != null && !chat.readOnly) {
      unawaited(
        widget.appState.api.sendTelegramTyping(
          accountId: _activeAccountId,
          peer: chat.peer,
          active: false,
        ),
      );
    }
  }

  int _accountSwitchEpoch = 0;

  /// Fast, race-free Telegram account switcher:
  /// 1. Saves current account's state to memory cache before mutating `_activeAccountId`.
  /// 2. Immediately switches UI state to `targetAccountId` (showing warm cached chats in 0ms or a clean loading indicator so the old account's chat list never lingers).
  /// 3. Fires `setActiveTelegramAccount` in parallel and concurrently fetches status, folders, and chats.
  Future<void> _switchTelegramAccount(
    String targetAccountId, {
    bool forceRefresh = false,
  }) async {
    final cleanTarget = targetAccountId.trim();
    if (cleanTarget.isEmpty) return;
    if (cleanTarget == _activeAccountId && !forceRefresh) return;

    _livePollTimer?.cancel();
    _saveCurrentDraft();
    _saveCurrentChatToMemoryCache();
    _stopOutgoingTyping();

    final epoch = ++_accountSwitchEpoch;
    final cachedFolders = _cachedFoldersByAccount[cleanTarget];
    final cachedChatData = _cachedChatsByAccountFolder['$cleanTarget|0'];
    final cachedSelected =
        _isMobileLayout ? null : _cachedSelectedChatByAccount[cleanTarget];

    setState(() {
      _activeAccountId = cleanTarget;
      _cachedActiveAccountId = cleanTarget;
      _selectedFolderKey = '0';
      _cachedSelectedFolderKey = '0';
      _folders = (cachedFolders != null && cachedFolders.isNotEmpty)
          ? List<TelegramFolder>.from(cachedFolders)
          : const [TelegramFolder(key: '0', title: '全部会话')];
      _selectedMessageIds.clear();
      _selectionMode = false;
      _mediaTypeFilter = 'all';

      if (cachedChatData != null && cachedChatData.chats.isNotEmpty) {
        final targetSel = cachedSelected ??
            (!_isMobileLayout && !_userExitedChat
                ? cachedChatData.chats.first
                : null);
        _chats = _applyReadStateToChats(
          cachedChatData.chats,
          activeSelectedPeer: targetSel?.peer,
        );
        _nextChatCursor = cachedChatData.nextCursor;
        _selectedChat = targetSel;
        _isLoadingChats = false;
        _statusIsError = false;
        _statusBanner = '${_chats.length} 个会话';
        if (targetSel != null) {
          _restoreDraftForChat(targetSel);
          final cachedMsgs = _cachedMessagesByPeer[_peerReadKey(targetSel.peer)];
          if (cachedMsgs != null && cachedMsgs.messages.isNotEmpty) {
            _messages = List<TelegramMessage>.from(cachedMsgs.messages);
            _nextMessageOffset = cachedMsgs.nextOffset;
            _isLoadingMessages = false;
          } else {
            _messages = [];
            _nextMessageOffset = 0;
          }
        } else {
          _messages = [];
          _nextMessageOffset = 0;
        }
      } else {
        _chats = [];
        _nextChatCursor = '';
        _selectedChat = null;
        _messages = [];
        _nextMessageOffset = 0;
        _isLoadingChats = true;
        _statusIsError = false;
        _statusBanner = '正在切换账号...';
      }
    });
    _syncReadingContext();

    // Notify backend of active account in parallel without blocking chat list load
    unawaited(
      widget.appState.api
          .setActiveTelegramAccount(cleanTarget)
          .catchError((_) {}),
    );

    try {
      // Launch status, accounts, and folders+chats requests in parallel so the new
      // account's chat list loads in 1 single network roundtrip instead of 4 sequential ones!
      final statusFuture = widget.appState.api.fetchTelegramStatus(cleanTarget);
      final accountsFuture = widget.appState.api
          .fetchTelegramAccounts()
          .catchError((_) => (
                activeId: cleanTarget,
                accounts: _accounts,
              ));
      final chatsLoadFuture = _loadFoldersAndChats(
        loadMore: false,
        silent: cachedChatData != null &&
            cachedChatData.chats.isNotEmpty &&
            !forceRefresh,
      );

      final status = await statusFuture;
      if (!mounted ||
          _accountSwitchEpoch != epoch ||
          _activeAccountId != cleanTarget) {
        return;
      }

      final accData = await accountsFuture;
      if (!mounted ||
          _accountSwitchEpoch != epoch ||
          _activeAccountId != cleanTarget) {
        return;
      }

      setState(() {
        if (accData.accounts.isNotEmpty) {
          _accounts = accData.accounts;
          _cachedAccounts = List<TelegramAccount>.from(_accounts);
        }
        _authStatus = status;
        _cachedAuthStatus = status;
      });

      if (!status.authorized) {
        setState(() {
          _isLoadingChats = false;
          _chats = [];
          _messages = [];
          _selectedChat = null;
          _statusBanner = status.configured ? '待验证码登录' : '未配置 API';
        });
        return;
      }

      await chatsLoadFuture;
      if (!mounted ||
          _accountSwitchEpoch != epoch ||
          _activeAccountId != cleanTarget) {
        return;
      }
      _startLivePolling();
    } catch (e) {
      if (!mounted ||
          _accountSwitchEpoch != epoch ||
          _activeAccountId != cleanTarget) {
        return;
      }
      if (_chats.isEmpty) {
        setState(() {
          _isLoadingChats = false;
          _statusIsError = true;
          _statusBanner = '切换账号异常';
        });
      }
    }
  }

  Future<void> _bootstrapTelegram({
    String? preferredAccountId,
    bool forceRefresh = false,
  }) async {
    if (preferredAccountId != null &&
        preferredAccountId.trim().isNotEmpty &&
        preferredAccountId.trim() != _activeAccountId) {
      await _switchTelegramAccount(
        preferredAccountId.trim(),
        forceRefresh: true,
      );
      return;
    }

    _livePollTimer?.cancel();
    final epoch = ++_accountSwitchEpoch;
    final hasWarmCache = !forceRefresh &&
        _chats.isNotEmpty &&
        _authStatus.authorized &&
        (preferredAccountId == null || preferredAccountId == _activeAccountId);

    if (!hasWarmCache) {
      setState(() {
        _isLoadingChats = true;
        _statusIsError = false;
        _statusBanner = '同步中...';
      });
    } else {
      _startLivePolling();
    }

    try {
      final accData = await widget.appState.api.fetchTelegramAccounts();
      if (!mounted || _accountSwitchEpoch != epoch) return;
      final chosenId = preferredAccountId ?? accData.activeId;
      final switchedAccount = chosenId != _activeAccountId;

      if (switchedAccount) {
        setState(() {
          _accounts = accData.accounts;
          _cachedAccounts = List<TelegramAccount>.from(_accounts);
        });
        await _switchTelegramAccount(chosenId, forceRefresh: true);
        return;
      }

      final status = await widget.appState.api.fetchTelegramStatus(chosenId);
      if (!mounted || _accountSwitchEpoch != epoch) return;

      setState(() {
        _accounts = accData.accounts;
        _activeAccountId = chosenId;
        _authStatus = status;
      });
      _cachedAccounts = List<TelegramAccount>.from(_accounts);
      _cachedActiveAccountId = _activeAccountId;
      _cachedAuthStatus = _authStatus;

      if (!status.authorized) {
        setState(() {
          _isLoadingChats = false;
          _chats = [];
          _messages = [];
          _selectedChat = null;
          _statusBanner = status.configured ? '待验证码登录' : '未配置 API';
        });
        return;
      }

      await _loadFoldersAndChats(
        silent: hasWarmCache && !switchedAccount,
      );
      if (!mounted || _accountSwitchEpoch != epoch) return;
      _startLivePolling();
    } catch (e) {
      if (!mounted || _accountSwitchEpoch != epoch) return;
      if (!hasWarmCache) {
        setState(() {
          _isLoadingChats = false;
          _statusIsError = true;
          _statusBanner = '连接异常';
        });
      }
    }
  }

  void _switchFolder(String folderKey) {
    if (_selectedFolderKey == folderKey) return;
    _saveCurrentChatToMemoryCache();
    final cacheKey = '$_activeAccountId|$folderKey';
    final cachedFolderData = _cachedChatsByAccountFolder[cacheKey];
    setState(() {
      _selectedFolderKey = folderKey;
      _cachedSelectedFolderKey = folderKey;
      if (cachedFolderData != null && cachedFolderData.chats.isNotEmpty) {
        _chats = _applyReadStateToChats(
          cachedFolderData.chats,
          activeSelectedPeer: _selectedChat?.peer,
        );
        _nextChatCursor = cachedFolderData.nextCursor;
        _isLoadingChats = false;
        _statusBanner = '${_chats.length} 个会话';
      } else {
        _chats = [];
        _nextChatCursor = '';
        _isLoadingChats = true;
      }
    });
    _loadFoldersAndChats(
      loadMore: false,
      silent: cachedFolderData != null && cachedFolderData.chats.isNotEmpty,
    );
  }

  Future<void> _loadFoldersAndChats({
    bool loadMore = false,
    bool silent = false,
  }) async {
    final reqAccountId = _activeAccountId;
    final reqFolderKey = _selectedFolderKey;
    final reqEpoch = _accountSwitchEpoch;

    if (!silent) {
      setState(() {
        _isLoadingChats = true;
        _statusIsError = false;
      });
    }

    try {
      // Fetch folders and chats concurrently instead of sequentially
      final Future<List<TelegramFolder>?> foldersFuture = !loadMore
          ? widget.appState.api
              .fetchTelegramFolders(reqAccountId)
              .then<List<TelegramFolder>?>((v) => v)
              .catchError((_) => null)
          : Future<List<TelegramFolder>?>.value(null);

      final chatsFuture = widget.appState.api.fetchTelegramChats(
        accountId: reqAccountId,
        folder: reqFolderKey,
        cursor: loadMore ? _nextChatCursor : '',
      );

      final res = await chatsFuture;
      final loadedFolders = await foldersFuture;

      if (!mounted ||
          _accountSwitchEpoch != reqEpoch ||
          _activeAccountId != reqAccountId ||
          _selectedFolderKey != reqFolderKey) {
        return;
      }

      if (loadedFolders != null && loadedFolders.isNotEmpty) {
        _folders = loadedFolders;
        _cachedFoldersByAccount[reqAccountId] =
            List<TelegramFolder>.from(loadedFolders);
      }

      setState(() {
        if (loadMore) {
          final existingPeers = _chats.map((c) => c.peer).toSet();
          final incoming = _applyReadStateToChats(
            res.chats.where((c) => !existingPeers.contains(c.peer)).toList(),
            activeSelectedPeer: _selectedChat?.peer,
          );
          _chats = [
            ..._chats,
            ...incoming,
          ];
        } else {
          final currentSelBelongsToList = _selectedChat != null &&
              res.chats.any((c) => c.peer == _selectedChat!.peer);
          final shouldAutoSelectFirst = !_isMobileLayout &&
              !_userExitedChat &&
              (_selectedChat == null || !currentSelBelongsToList) &&
              res.chats.isNotEmpty;
          final initialTargetPeer = shouldAutoSelectFirst
              ? res.chats.first.peer
              : _selectedChat?.peer;
          _chats = _applyReadStateToChats(
            res.chats,
            activeSelectedPeer: initialTargetPeer,
          );
          if (shouldAutoSelectFirst && _chats.isNotEmpty) {
            _selectedChat = _chats.first;
            _restoreDraftForChat(_selectedChat!);
            _markChatAsRead(_selectedChat!);
            final cachedMsgs =
                _cachedMessagesByPeer[_peerReadKey(_selectedChat!.peer)];
            if (cachedMsgs != null && cachedMsgs.messages.isNotEmpty) {
              _messages = List<TelegramMessage>.from(cachedMsgs.messages);
              _nextMessageOffset = cachedMsgs.nextOffset;
              _loadMessages(loadOlder: false, silent: true);
            } else {
              _messages = [];
              _nextMessageOffset = 0;
              _loadMessages(loadOlder: false);
            }
          } else if (_selectedChat != null) {
            final updatedSelected = _chats.where(
              (c) => c.peer == _selectedChat!.peer,
            );
            if (updatedSelected.isNotEmpty) {
              final freshChat = updatedSelected.first;
              int currentMaxId = 0;
              for (final m in _messages) {
                if (!_isOptimisticMsgId(m.id) && m.id > currentMaxId) {
                  currentMaxId = m.id;
                }
              }
              final hasNewerServerMsg =
                  (freshChat.topMessageId > 0 &&
                      freshChat.topMessageId > currentMaxId) ||
                  (freshChat.date > 0 &&
                      freshChat.date != _selectedChat!.date);
              _selectedChat = freshChat.copyWith(unread: 0);
              if (_messages.isEmpty && !_isLoadingMessages) {
                _loadMessages(loadOlder: false);
              } else if (hasNewerServerMsg && !_isLoadingMessages) {
                _loadMessages(loadOlder: false, silent: true);
              }
            }
          }
        }
        _nextChatCursor = res.nextCursor;
        _isLoadingChats = false;
        _statusBanner = '${_chats.length} 个会话';
      });
      _saveCurrentChatToMemoryCache();
      unawaited(_persistReadState());
    } catch (e) {
      if (!mounted ||
          _accountSwitchEpoch != reqEpoch ||
          _activeAccountId != reqAccountId ||
          _selectedFolderKey != reqFolderKey) {
        return;
      }
      if (!silent) {
        setState(() {
          _isLoadingChats = false;
          _statusIsError = true;
          _statusBanner = '读取会话失败';
        });
      }
    }
  }

  Future<void> _selectChat(TelegramChat chat) async {
    if (_selectedChat?.peer != chat.peer) {
      _inlinePlaybackOwner.value = null;
      _isHeaderDangerActionExpanded = false;
    }
    _userExitedChat = false;
    _saveCurrentDraft();
    _saveCurrentChatToMemoryCache();
    _stopOutgoingTyping();
    final cleanChat = chat.unread > 0 ? chat.copyWith(unread: 0) : chat;
    final hadUnread = chat.unread > 0;
    _markChatAsRead(chat);
    if (_selectedChat?.peer == chat.peer && _messages.isNotEmpty) {
      _scrollToBottom(animated: true);
      return;
    }

    final peerKey = _peerReadKey(chat.peer);
    final cached = _cachedMessagesByPeer[peerKey];
    if (cached != null && cached.messages.isNotEmpty) {
      setState(() {
        _selectedChat = cleanChat;
        _messages = List<TelegramMessage>.from(cached.messages);
        _nextMessageOffset = cached.nextOffset;
        _isLoadingMessages = false;
        _selectedMessageIds.clear();
        _selectionMode = false;
        _mediaTypeFilter = 'all';
        _restoreDraftForChat(cleanChat);
      });
      _cachedSelectedChatByAccount[_activeAccountId] = cleanChat;
      _syncReadingContext();

      final savedScroll = cached.scrollOffset;
      if (!hadUnread && savedScroll != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_messageScrollController.hasClients) return;
          final maxExt = _messageScrollController.position.maxScrollExtent;
          _messageScrollController.jumpTo(savedScroll.clamp(0.0, maxExt));
        });
      } else {
        _scrollToBottom(animated: false);
      }

      final cachedLastId = cached.messages.last.id;
      final cachedLastDate = cached.messages.last.date;
      if (hadUnread ||
          (chat.topMessageId > 0 && chat.topMessageId > cachedLastId) ||
          (chat.date > cachedLastDate)) {
        unawaited(_loadMessages(loadOlder: false, silent: true));
      }
      return;
    }

    setState(() {
      _selectedChat = cleanChat;
      _messages = [];
      _nextMessageOffset = 0;
      _selectedMessageIds.clear();
      _selectionMode = false;
      _mediaTypeFilter = 'all';
      _restoreDraftForChat(cleanChat);
    });
    _cachedSelectedChatByAccount[_activeAccountId] = cleanChat;
    _syncReadingContext();
    await _loadMessages(loadOlder: false);
  }

  Future<void> _loadMessages({
    bool loadOlder = false,
    bool silent = false,
  }) async {
    final chat = _selectedChat;
    if (chat == null) return;
    if (loadOlder && (_isLoadingMessages || _nextMessageOffset <= 0)) return;
    final reqAccountId = _activeAccountId;
    final reqEpoch = _accountSwitchEpoch;

    if (!silent) {
      setState(() {
        _isLoadingMessages = true;
      });
    }

    try {
      final res = await widget.appState.api.fetchTelegramMessages(
        accountId: reqAccountId,
        peer: chat.peer,
        offsetId: loadOlder ? _nextMessageOffset : 0,
      );
      if (!mounted ||
          _accountSwitchEpoch != reqEpoch ||
          _activeAccountId != reqAccountId ||
          _selectedChat?.peer != chat.peer) {
        return;
      }

      int addedOlderCount = 0;
      bool shouldChainLoadOlder = false;
      final prevLastId = _messages.isNotEmpty ? _messages.last.id : 0;
      setState(() {
        if (loadOlder) {
          final prevOffset = _nextMessageOffset;
          final existingIds = _messages.map((m) => m.id).toSet();
          final olderIncoming = res.messages
              .where((m) => !existingIds.contains(m.id))
              .toList();
          addedOlderCount = olderIncoming.length;
          if (olderIncoming.isNotEmpty) {
            final merged = [
              ...olderIncoming,
              ..._messages,
            ]..sort((a, b) => a.id.compareTo(b.id));
            _messages = merged;
          }
          if (res.nextOffset <= 1 ||
              res.nextOffset >= prevOffset ||
              (olderIncoming.isEmpty && res.messages.isNotEmpty)) {
            _nextMessageOffset = 0;
          } else {
            _nextMessageOffset = res.nextOffset;
            if (addedOlderCount == 0 && _nextMessageOffset > 0) {
              shouldChainLoadOlder = true;
            }
          }
        } else if (silent && _messages.isNotEmpty) {
          final byId = <int, TelegramMessage>{
            for (final m in _messages) m.id: m,
          };
          for (final m in res.messages) {
            byId[m.id] = m;
          }
          final merged = byId.values.toList()
            ..sort((a, b) => a.id.compareTo(b.id));
          _messages = merged;
          if (_nextMessageOffset == 0 && res.nextOffset > 1) {
            _nextMessageOffset = res.nextOffset;
          }
        } else {
          _messages = List<TelegramMessage>.from(res.messages);
          _nextMessageOffset = res.nextOffset > 1 ? res.nextOffset : 0;
        }
        _isLoadingMessages = false;
      });
      _lastLoadOlderAt = DateTime.now();
      _saveCurrentChatToMemoryCache();
      if (_messages.isNotEmpty) {
        final lastMsg = _messages.last;
        _markChatAsRead(
          chat,
          latestMessageDate: lastMsg.date,
          maxMessageId: lastMsg.id,
        );
      } else {
        _markChatAsRead(chat);
      }
      final hasNewerTail =
          _messages.isNotEmpty && prevLastId > 0 && _messages.last.id > prevLastId;
      if (!loadOlder && !silent) {
        _scrollToBottom(animated: false);
      } else if (!loadOlder && silent && hasNewerTail && !_showScrollToBottomBtn) {
        _scrollToBottom(animated: true);
      } else if (shouldChainLoadOlder && mounted) {
        unawaited(_loadMessages(loadOlder: true));
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _isLoadingMessages = false;
          _statusIsError = true;
          _statusBanner = '加载消息失败：$e';
        });
      }
    }
  }

  TelegramMessage _buildOptimisticOutgoingMessage({
    required int tempId,
    required int nowSec,
    required String text,
    required int replyId,
    TelegramOutgoingFile? file,
    required bool asFile,
    String groupedId = '',
  }) {
    TelegramAttachment? att;
    if (file != null) {
      final isImg = !asFile && file.isImage;
      final isVid = !asFile && file.isVideo;
      final isAud = !asFile &&
          (file.mimeType.toLowerCase().startsWith('audio/') ||
              RegExp(
                r'\.(mp3|m4a|aac|ogg|oga|opus|wav|flac|wma|ape|alac|aiff)$',
                caseSensitive: false,
              ).hasMatch(file.name));
      final kind = isImg
          ? 'photo'
          : (isVid ? 'video' : (isAud ? 'audio' : 'file'));
      att = TelegramAttachment(
        kind: kind,
        name: file.name,
        fileName: file.name,
        size: file.size,
        mimeType: file.mimeType,
        hasThumbnail: isImg && file.bytes.isNotEmpty,
      );
      if (file.bytes.isNotEmpty) {
        _optimisticPreviewBytesByMsgId[tempId] = file.bytes;
      }
    }
    return TelegramMessage(
      id: tempId,
      date: nowSec,
      sender: '我',
      text: text,
      outgoing: true,
      groupedId: groupedId,
      replyToId: replyId,
      attachment: att,
    );
  }

  Future<void> _sendMessage({
    String? overrideText,
    List<TelegramOutgoingFile>? overrideFiles,
    bool? overrideAsFile,
    TelegramChat? targetChat,
    List<int>? retryOptimisticIds,
    int? overrideReplyId,
  }) async {
    final chat = targetChat ?? _selectedChat;
    final isCurrentChat = chat != null && chat.peer == _selectedChat?.peer;
    final text = (overrideText ?? _composeController.text).trim();
    final files = overrideFiles ?? List<TelegramOutgoingFile>.from(_stagedFiles);
    final asFile = overrideAsFile ?? _sendAsFile;

    if (chat == null ||
        chat.readOnly ||
        (text.isEmpty && files.isEmpty)) {
      return;
    }

    if (files.isNotEmpty && text.length > 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('附件说明文字最多支持 1024 个字符，请精简后再发送')),
      );
      return;
    }

    _stopOutgoingTyping();
    final replyId = overrideReplyId ??
        (isCurrentChat ? (_replyingToMessage?.id ?? 0) : 0);
    final sendAccountId = _activeAccountId;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final previewText = text.isNotEmpty
        ? text
        : (files.isNotEmpty ? '[附件] ${files.first.name}' : '');

    // 1. Immediately clear compose input & staged attachments (Official Telegram Desktop/Mobile behavior)
    if (isCurrentChat &&
        overrideFiles == null &&
        overrideText == null &&
        retryOptimisticIds == null) {
      _composeController.clear();
      _stagedFiles.clear();
      _replyingToMessage = null;
      _drafts.remove(_peerReadKey(chat.peer));
    }

    // 2. Construct or reuse optimistic outgoing message(s) and show immediately in the chat window
    final optimisticIds = <int>[];
    final optimisticMessages = <TelegramMessage>[];

    if (retryOptimisticIds != null && retryOptimisticIds.isNotEmpty) {
      optimisticIds.addAll(retryOptimisticIds);
      for (final id in optimisticIds) {
        _failedOptimisticMsgs.remove(id);
        _sendingOptimisticMsgIds.add(id);
        if (files.isNotEmpty) {
          _optimisticUploadPercent[id] = 0;
        }
      }
    } else if (files.isEmpty) {
      final tempId = _kOptimisticIdBase + (++_nextOptimisticSeq);
      optimisticIds.add(tempId);
      _sendingOptimisticMsgIds.add(tempId);
      optimisticMessages.add(
        _buildOptimisticOutgoingMessage(
          tempId: tempId,
          nowSec: nowSec,
          text: text,
          replyId: replyId,
          asFile: asFile,
        ),
      );
    } else {
      final groupedId =
          files.length > 1 ? 'opt_group_${++_nextOptimisticSeq}' : '';
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final tempId = _kOptimisticIdBase + (++_nextOptimisticSeq);
        optimisticIds.add(tempId);
        _sendingOptimisticMsgIds.add(tempId);
        _optimisticUploadPercent[tempId] = 0;
        if (f.filePath != null && f.filePath!.trim().isNotEmpty) {
          _recordSavedLocalPath(
            chat,
            tempId,
            f.filePath!.trim(),
            accountId: sendAccountId,
          );
        }
        optimisticMessages.add(
          _buildOptimisticOutgoingMessage(
            tempId: tempId,
            nowSec: nowSec,
            text: i == 0 ? text : '',
            replyId: i == 0 ? replyId : 0,
            file: f,
            asFile: asFile,
            groupedId: groupedId,
          ),
        );
      }
    }

    setState(() {
      _chats = _chats.map((c) {
        if (c.peer == chat.peer) {
          return c.copyWith(
            preview: previewText,
            date: nowSec,
            unread: 0,
          );
        }
        return c;
      }).toList();

      if (optimisticMessages.isNotEmpty) {
        if (_selectedChat?.peer == chat.peer &&
            _activeAccountId == sendAccountId) {
          _messages = List<TelegramMessage>.from(_messages)
            ..addAll(optimisticMessages)
            ..sort((a, b) => a.id.compareTo(b.id));
        } else {
          final peerKey = '$sendAccountId|${chat.peer}';
          final cached = _cachedMessagesByPeer[peerKey];
          if (cached != null) {
            final nextList = List<TelegramMessage>.from(cached.messages)
              ..addAll(optimisticMessages)
              ..sort((a, b) => a.id.compareTo(b.id));
            _cachedMessagesByPeer[peerKey] = (
              messages: nextList,
              nextOffset: cached.nextOffset,
              scrollOffset: cached.scrollOffset,
            );
          }
        }
      }
    });

    if (_selectedChat?.peer == chat.peer && _activeAccountId == sendAccountId) {
      _saveCurrentChatToMemoryCache();
      _scrollToBottom(animated: true);
    }

    // 3. Perform the actual network send in the background
    try {
      final confirmed = <TelegramMessage>[];
      if (files.isNotEmpty) {
        final sentMsgs = await widget.appState.api.sendTelegramFiles(
          accountId: sendAccountId,
          peer: chat.peer,
          files: files,
          text: text,
          replyTo: replyId,
          asFile: asFile,
          onProgress: (percent, statusText) {
            if (!mounted) return;
            setState(() {
              for (final id in optimisticIds) {
                _optimisticUploadPercent[id] = percent;
              }
            });
          },
        );
        confirmed.addAll(sentMsgs);
      } else {
        final sentMsg = await widget.appState.api.sendTelegramTextMessage(
          accountId: sendAccountId,
          peer: chat.peer,
          text: text,
          replyTo: replyId,
        );
        if (sentMsg != null && sentMsg.id > 0) {
          confirmed.add(sentMsg);
        }
      }

      if (!mounted) return;

      // Associate local file paths with confirmed message IDs so sent files also show their local path
      for (var i = 0; i < confirmed.length && i < files.length; i++) {
        final fPath = files[i].filePath?.trim() ?? '';
        if (fPath.isNotEmpty && confirmed[i].id > 0) {
          _recordSavedLocalPath(
            chat,
            confirmed[i].id,
            fPath,
            accountId: sendAccountId,
          );
        }
      }

      final latestDate = confirmed.isNotEmpty && confirmed.last.date > 0
          ? confirmed.last.date
          : nowSec;
      final optimisticSet = optimisticIds.toSet();

      setState(() {
        for (final id in optimisticIds) {
          _sendingOptimisticMsgIds.remove(id);
          _failedOptimisticMsgs.remove(id);
          _optimisticUploadPercent.remove(id);
          _optimisticPreviewBytesByMsgId.remove(id);
        }

        _chats = _chats.map((c) {
          if (c.peer == chat.peer) {
            final maxConfirmedId = confirmed.isNotEmpty
                ? confirmed.last.id
                : c.topMessageId;
            return c.copyWith(
              topMessageId: maxConfirmedId > c.topMessageId
                  ? maxConfirmedId
                  : c.topMessageId,
              preview: previewText,
              date: latestDate,
              unread: 0,
            );
          }
          return c;
        }).toList();

        if (_selectedChat?.peer == chat.peer &&
            _activeAccountId == sendAccountId) {
          final nextMessages = _messages
              .where((m) => !optimisticSet.contains(m.id))
              .toList();
          final existingIds = nextMessages.map((m) => m.id).toSet();
          for (final item in confirmed) {
            if (item.id > 0 && !existingIds.contains(item.id)) {
              nextMessages.add(item);
              existingIds.add(item.id);
            }
          }
          nextMessages.sort((a, b) => a.id.compareTo(b.id));
          _messages = nextMessages;
        } else {
          final peerKey = '$sendAccountId|${chat.peer}';
          final cached = _cachedMessagesByPeer[peerKey];
          if (cached != null) {
            final nextList = cached.messages
                .where((m) => !optimisticSet.contains(m.id))
                .toList();
            final existingIds = nextList.map((m) => m.id).toSet();
            for (final item in confirmed) {
              if (item.id > 0 && !existingIds.contains(item.id)) {
                nextList.add(item);
                existingIds.add(item.id);
              }
            }
            nextList.sort((a, b) => a.id.compareTo(b.id));
            _cachedMessagesByPeer[peerKey] = (
              messages: nextList,
              nextOffset: cached.nextOffset,
              scrollOffset: cached.scrollOffset,
            );
          }
        }
      });

      if (_selectedChat?.peer == chat.peer &&
          _activeAccountId == sendAccountId) {
        _saveCurrentChatToMemoryCache();
        if (confirmed.isNotEmpty) {
          _markChatAsRead(
            chat,
            latestMessageDate: latestDate,
            maxMessageId: confirmed.last.id,
          );
        } else {
          await _loadMessages(loadOlder: false, silent: true);
        }
      } else if (targetChat != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已发送到「${chat.title}」')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final errStr = e.toString();
      setState(() {
        for (final id in optimisticIds) {
          _sendingOptimisticMsgIds.remove(id);
          _optimisticUploadPercent.remove(id);
          _failedOptimisticMsgs[id] = (
            error: errStr,
            text: text,
            files: files,
            asFile: asFile,
            replyId: replyId,
            chat: chat,
            groupOptimisticIds: optimisticIds,
          );
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('发送失败：$e'),
          action: SnackBarAction(
            label: '重试',
            onPressed: () {
              if (optimisticIds.isNotEmpty) {
                _retryFailedOptimisticMessage(optimisticIds.first);
              }
            },
          ),
        ),
      );
    }
  }

  void _retryFailedOptimisticMessage(int tempId) {
    final failed = _failedOptimisticMsgs[tempId];
    if (failed == null) return;
    unawaited(
      _sendMessage(
        overrideText: failed.text,
        overrideFiles: failed.files,
        overrideAsFile: failed.asFile,
        targetChat: failed.chat,
        retryOptimisticIds: failed.groupOptimisticIds,
        overrideReplyId: failed.replyId,
      ),
    );
  }

  /// Insert emoji/kaomoji/text at the current cursor position in `_composeController`
  void _insertTextAtCursor(String insertStr) {
    final text = _composeController.text;
    final sel = _composeController.selection;
    final start = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final end = sel.isValid ? sel.end.clamp(0, text.length) : text.length;
    final newText = text.replaceRange(start, end, insertStr);
    _composeController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insertStr.length),
    );
    _onComposeTextChanged(newText);
    _composeFocusNode.requestFocus();
  }

  /// Wrap selected text (or insert placeholder) with Telegram markdown syntax (`**`, `__`, `` ` ``, `||`, `~~`)
  void _wrapSelectionWithMarkdown(
    String prefix,
    String suffix, {
    String placeholder = '文字',
  }) {
    final text = _composeController.text;
    final sel = _composeController.selection;
    final start = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final end = sel.isValid ? sel.end.clamp(0, text.length) : text.length;
    final selectedStr =
        start < end ? text.substring(start, end) : placeholder;
    final replacement = '$prefix$selectedStr$suffix';
    final newText = text.replaceRange(start, end, replacement);
    _composeController.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selectedStr.length,
      ),
    );
    _onComposeTextChanged(newText);
    _composeFocusNode.requestFocus();
  }

  void _onEmojiSelected(String item, {bool sendImmediately = false}) {
    if (item.characters.length <= 2) {
      _recentEmojis.remove(item);
      _recentEmojis.insert(0, item);
      if (_recentEmojis.length > 32) {
        _recentEmojis = _recentEmojis.sublist(0, 32);
      }
      unawaited(_persistRecentEmojis());
    }
    if (sendImmediately) {
      setState(() => _showEmojiPanel = false);
      unawaited(_sendMessage(overrideText: item, overrideFiles: const []));
      return;
    }
    _insertTextAtCursor(item);
  }

  String _guessMimeType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.m4a') || lower.endsWith('.alac')) return 'audio/mp4';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.wav') || lower.endsWith('.wave')) return 'audio/wav';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.ape') || lower.endsWith('.mac')) return 'audio/x-ape';
    if (lower.endsWith('.aiff') || lower.endsWith('.aif')) return 'audio/aiff';
    if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
    if (lower.endsWith('.ogg') ||
        lower.endsWith('.oga') ||
        lower.endsWith('.opus')) {
      return 'audio/ogg';
    }
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.m3u8') ||
        lower.endsWith('.srt') ||
        lower.endsWith('.log')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  /// Stage files or open the official Telegram "Send Media / Files" preview modal
  void _stageOrPreviewOutgoingFiles(
    List<TelegramOutgoingFile> added, {
    required bool asFile,
    bool openPreviewDialog = true,
    String dialogTitle = '发送图片与文件',
  }) {
    final chat = _selectedChat;
    if (chat == null || chat.readOnly || added.isEmpty) return;

    final valid = added.where((f) => f.size > 0).toList();
    if (valid.isEmpty) return;

    final totalBytes = [..._stagedFiles, ...valid].fold<int>(
      0,
      (sum, f) => sum + f.size,
    );
    if (_stagedFiles.length + valid.length > 10 ||
        totalBytes > 2 * 1024 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('每次最多支持发送 10 个文件，总大小不超过 2 GB')),
      );
      return;
    }

    if (openPreviewDialog && _stagedFiles.isEmpty) {
      _showMediaSendPreviewDialog(
        valid,
        initialAsFile: asFile,
        title: dialogTitle,
      );
      return;
    }

    setState(() {
      _stagedFiles = [..._stagedFiles, ...valid];
      _sendAsFile = asFile;
    });
    _saveCurrentDraft();
    _composeFocusNode.requestFocus();
  }

  /// Capture interactive system region screenshot (`✂️ 区域截图`)
  Future<void> _captureSystemRegionScreenshot() async {
    final chat = _selectedChat;
    if (chat == null || chat.readOnly) return;

    try {
      if (Platform.isMacOS) {
        // 1. Try native MethodChannel interactive screencapture
        try {
          final res = await _nativeUtilsChannel.invokeMethod<dynamic>(
            'captureInteractiveScreenshot',
          );
          if (res is Map) {
            final rawBytes = res['bytes'];
            if (rawBytes is Uint8List && rawBytes.isNotEmpty) {
              final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
              final file = TelegramOutgoingFile(
                name: (res['name'] ?? '屏幕截图-$ts.png').toString(),
                bytes: rawBytes,
                mimeType: 'image/png',
              );
              if (!mounted) return;
              _stageOrPreviewOutgoingFiles(
                [file],
                asFile: false,
                openPreviewDialog: true,
                dialogTitle: '发送屏幕截图',
              );
              return;
            }
          }
        } catch (_) {}

        // 2. Fallback: `/usr/sbin/screencapture -i` to temp file
        final tmpPath =
            '${Directory.systemTemp.path}/tg_shot_${DateTime.now().millisecondsSinceEpoch}.png';
        final proc = await Process.run('/usr/sbin/screencapture', [
          '-i',
          tmpPath,
        ]);
        final tmpFile = File(tmpPath);
        if (proc.exitCode == 0 && await tmpFile.exists()) {
          final bytes = await tmpFile.readAsBytes();
          await tmpFile.delete().catchError((_) => tmpFile);
          if (bytes.isNotEmpty && mounted) {
            final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            _stageOrPreviewOutgoingFiles(
              [
                TelegramOutgoingFile(
                  name: '屏幕截图-$ts.png',
                  bytes: bytes,
                  mimeType: 'image/png',
                ),
              ],
              asFile: false,
              openPreviewDialog: true,
              dialogTitle: '发送屏幕截图',
            );
            return;
          }
        }
        return;
      }
    } catch (_) {}

    // On all other platforms or if system screencapture isn't used, open in-app region cropper!
    await _openInAppRegionCropScreenshot();
  }

  /// Capture current client window screenshot via `RepaintBoundary` (`🪟 窗口截图`)
  Future<Uint8List?> _renderBoundaryPngBytes() async {
    try {
      final ctx = _captureBoundaryKey.currentContext;
      if (ctx == null) return null;
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return byteData.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _captureAppWindowScreenshot() async {
    final chat = _selectedChat;
    if (chat == null || chat.readOnly) return;

    final bytes = await _renderBoundaryPngBytes();
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('获取窗口截图失败，请稍后重试')),
      );
      return;
    }
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _stageOrPreviewOutgoingFiles(
      [
        TelegramOutgoingFile(
          name: '窗口截图-$ts.png',
          bytes: bytes,
          mimeType: 'image/png',
        ),
      ],
      asFile: false,
      openPreviewDialog: true,
      dialogTitle: '发送当前窗口截图',
    );
  }

  /// Open interactive in-app region cropper screenshot (`📐 应用内框选区域截图`)
  Future<void> _openInAppRegionCropScreenshot() async {
    final chat = _selectedChat;
    if (chat == null || chat.readOnly) return;

    final fullBytes = await _renderBoundaryPngBytes();
    if (!mounted || fullBytes == null || fullBytes.isEmpty) return;

    final croppedBytes = await showDialog<Uint8List>(
      context: context,
      barrierColor: const Color(0xD9000000),
      builder: (_) => _TelegramRegionCropDialog(fullImageBytes: fullBytes),
    );
    if (!mounted || croppedBytes == null || croppedBytes.isEmpty) return;

    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _stageOrPreviewOutgoingFiles(
      [
        TelegramOutgoingFile(
          name: '区域截图-$ts.png',
          bytes: croppedBytes,
          mimeType: 'image/png',
        ),
      ],
      asFile: false,
      openPreviewDialog: true,
      dialogTitle: '发送区域框选截图',
    );
  }

  /// Pick local files / photos / videos to attach (`📎 选择文件 / 媒体`)
  Future<void> _pickFilesToAttach({
    required bool mediaOnly,
    required bool asFile,
  }) async {
    final chat = _selectedChat;
    if (chat == null || chat.readOnly) return;

    final pickedFiles = <TelegramOutgoingFile>[];

    // 1. Try native MethodChannel file picker on macOS & Windows
    if (Platform.isMacOS || Platform.isWindows) {
      try {
        final rawList = await _nativeUtilsChannel.invokeMethod<dynamic>(
          'pickFiles',
          {'mediaOnly': mediaOnly},
        );
        if (rawList is List) {
          for (final item in rawList) {
            if (item is Map) {
              final name = (item['name'] ?? '附件').toString();
              Uint8List bytes = item['bytes'] is Uint8List
                  ? item['bytes'] as Uint8List
                  : Uint8List(0);
              final path = item['path']?.toString();
              int size = (item['size'] as num?)?.toInt() ?? bytes.length;
              if (path != null && path.isNotEmpty) {
                try {
                  final fileObj = File(path);
                  if (await fileObj.exists()) {
                    if (size <= 0) {
                      size = await fileObj.length();
                    }
                    if (bytes.isEmpty &&
                        size > 0 &&
                        size <= 25 * 1024 * 1024) {
                      bytes = await fileObj.readAsBytes();
                    }
                  }
                } catch (_) {}
              }
              if (size > 0 &&
                  (bytes.isNotEmpty || (path != null && path.isNotEmpty))) {
                pickedFiles.add(
                  TelegramOutgoingFile(
                    name: name,
                    bytes: bytes,
                    mimeType: _guessMimeType(name),
                    filePath: path,
                    fileSize: size,
                  ),
                );
              }
            }
          }
          if (pickedFiles.isNotEmpty && mounted) {
            _stageOrPreviewOutgoingFiles(
              pickedFiles,
              asFile: asFile,
              openPreviewDialog: true,
              dialogTitle: asFile ? '作为无损文件发送' : '发送图片与视频',
            );
          }
          return;
        }
      } catch (_) {}
    }

    // 2. Fallback: Built-in cross-platform local file browser dialog
    if (!mounted) return;
    final selectedPaths = await showDialog<List<String>>(
      context: context,
      builder: (_) => _LocalFilePickerFallbackDialog(mediaOnly: mediaOnly),
    );
    if (!mounted || selectedPaths == null || selectedPaths.isEmpty) return;

    for (final p in selectedPaths.take(10)) {
      try {
        final f = File(p);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          if (bytes.isNotEmpty) {
            final name = p.split(Platform.pathSeparator).last;
            pickedFiles.add(
              TelegramOutgoingFile(
                name: name,
                bytes: bytes,
                mimeType: _guessMimeType(name),
                filePath: p,
              ),
            );
          }
        }
      } catch (_) {}
    }

    if (pickedFiles.isNotEmpty && mounted) {
      _stageOrPreviewOutgoingFiles(
        pickedFiles,
        asFile: asFile,
        openPreviewDialog: true,
        dialogTitle: asFile ? '作为无损文件发送' : '发送图片与视频',
      );
    }
  }

  /// Read image or file from system clipboard (`📋 粘贴剪贴板图片 Cmd+V / Ctrl+V`)
  Future<bool> _pasteClipboardImageOrFiles({bool showEmptyToast = false}) async {
    final chat = _selectedChat;
    if (chat == null || chat.readOnly) return false;

    try {
      if (Platform.isMacOS) {
        final res = await _nativeUtilsChannel.invokeMethod<dynamic>(
          'readClipboardImage',
        );
        if (res is Map) {
          final name = (res['name'] ?? '粘贴图片.png').toString();
          final bytes = res['bytes'] is Uint8List
              ? res['bytes'] as Uint8List
              : Uint8List(0);
          final path = res['path']?.toString();
          final size = (res['size'] as num?)?.toInt() ?? bytes.length;
          if (size > 0 &&
              (bytes.isNotEmpty || (path != null && path.isNotEmpty)) &&
              mounted) {
            final file = TelegramOutgoingFile(
              name: name,
              bytes: bytes,
              mimeType: _guessMimeType(name),
              filePath: path,
              fileSize: size,
            );
            _stageOrPreviewOutgoingFiles(
              [file],
              asFile: !file.isImage,
              openPreviewDialog: true,
              dialogTitle: file.isImage ? '发送剪贴板图片' : '发送剪贴板文件',
            );
            return true;
          }
        }
      }
    } catch (_) {}

    if (showEmptyToast && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('剪贴板中未检测到图片，可先截图或复制图片后再粘贴')),
      );
    }
    return false;
  }

  /// Show the official Telegram "Send Photo / Screenshot / File" preview modal dialog
  Future<void> _showMediaSendPreviewDialog(
    List<TelegramOutgoingFile> initialFiles, {
    required bool initialAsFile,
    String title = '发送媒体与文件',
  }) async {
    final chat = _selectedChat;
    if (chat == null || initialFiles.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => _TelegramSendPreviewDialog(
        title: title,
        targetChatTitle: chat.title,
        initialFiles: initialFiles,
        initialAsFile: initialAsFile,
        initialCaption: _composeController.text,
        onStageToBar: (files, asFile, caption) {
          setState(() {
            _stagedFiles = [..._stagedFiles, ...files];
            _sendAsFile = asFile;
            _composeController.text = caption;
          });
          _saveCurrentDraft();
        },
        onSendNow: (files, asFile, caption) {
          _composeController.clear();
          _stagedFiles.clear();
          _saveCurrentDraft();
          unawaited(
            _sendMessage(
              overrideText: caption,
              overrideFiles: files,
              overrideAsFile: asFile,
            ),
          );
        },
      ),
    );
  }

  /// Check if a Telegram attachment can be previewed inline via `/api/telegram/file-preview`
  bool _canPreviewTelegramFile(TelegramAttachment att) {
    final name = att.displayName.toLowerCase();
    final mime = att.mimeType.split(';').first.toLowerCase();
    if (RegExp(
      r'\.(txt|log|md|markdown|json|jsonl|xml|csv|tsv|yaml|yml|ini|conf|cfg|toml|srt|ass|vtt|lrc|m3u8?|html?|css|jsx?|tsx?|py|go|java|c|cpp|h|rs|sh|sql|zip|pdf|docx)$',
    ).hasMatch(name)) {
      return true;
    }
    return mime.startsWith('text/') ||
        mime == 'application/json' ||
        mime == 'application/xml' ||
        mime == 'application/zip';
  }

  /// Open inline file preview modal (`/api/telegram/file-preview`)
  Future<void> _openFilePreviewDialog(
    TelegramChat chat,
    TelegramMessage msg,
  ) async {
    final att = msg.attachment;
    if (att == null) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _TelegramFilePreviewDialog(
        appState: widget.appState,
        accountId: _activeAccountId,
        peer: chat.peer,
        messageId: msg.id,
        attachment: att,
      ),
    );
  }

  void _showDownloadHud(
    String text, {
    required String state,
    Duration duration = const Duration(milliseconds: 2800),
  }) {
    _downloadHudTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _downloadHudText = text;
      _downloadHudState = state;
    });
    if (state != 'loading') {
      _downloadHudTimer = Timer(duration, () {
        if (mounted) {
          setState(() {
            _downloadHudText = '';
            _downloadHudState = '';
          });
        }
      });
    }
  }

  /// Save any Telegram attachment or photo directly to local `~/Downloads` folder
  Future<bool> _saveAttachmentToLocalDownloads(
    TelegramChat chat,
    TelegramMessage msg, {
    bool showToast = true,
  }) async {
    final att = msg.attachment;
    if (att == null) return false;
    if (_pendingLocalSaves.contains(msg.id)) return false;

    final fileUrl = widget.appState.api.buildTelegramFileDownloadUrl(
      accountId: _activeAccountId,
      peer: chat.peer,
      messageId: msg.id,
      local: true,
    );

    setState(() {
      _pendingLocalSaves.add(msg.id);
      _failedLocalSaves.remove(msg.id);
    });
    _showDownloadHud('正在保存「${att.displayName}」到本地电脑...', state: 'loading');

    try {
      final bytes = await widget.appState.api.downloadTelegramBytes(fileUrl);
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home${Platform.pathSeparator}Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final safeName = att.displayName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      var outPath = '${targetDir.path}${Platform.pathSeparator}$safeName';
      if (await File(outPath).exists()) {
        final dotIdx = safeName.lastIndexOf('.');
        final base = dotIdx > 0 ? safeName.substring(0, dotIdx) : safeName;
        final ext = dotIdx > 0 ? safeName.substring(dotIdx) : '';
        outPath =
            '${targetDir.path}${Platform.pathSeparator}${base}_${DateTime.now().millisecondsSinceEpoch ~/ 1000}$ext';
      }
      await File(outPath).writeAsBytes(bytes);
      _recordSavedLocalPath(chat, msg.id, outPath);
      if (!mounted) return true;
      setState(() {
        _pendingLocalSaves.remove(msg.id);
        _completedLocalSaves.add(msg.id);
        _failedLocalSaves.remove(msg.id);
      });
      _showDownloadHud('已保存到本地：$outPath', state: 'success');
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF1F3327),
            content: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF4ECC5E),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('已保存到本地：$outPath')),
              ],
            ),
            action: SnackBarAction(
              label: '打开所在目录',
              textColor: const Color(0xFF69F0AE),
              onPressed: () => _openLocalFileDirectory(outPath),
            ),
          ),
        );
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _pendingLocalSaves.remove(msg.id);
        _failedLocalSaves.add(msg.id);
      });
      _showDownloadHud('保存本机失败：${att.displayName}', state: 'error');
      final uri = Uri.tryParse(fileUrl);
      if (uri != null) {
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      } else if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF3A1D22),
            content: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFFF6B6B),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('保存失败：$e')),
              ],
            ),
          ),
        );
      }
      return false;
    }
  }

  /// Forward one or more messages to another Telegram chat (or Saved Messages)
  Future<void> _showForwardMessagesDialog(
    List<TelegramMessage> messagesToForward,
  ) async {
    if (messagesToForward.isEmpty) return;
    final targetChat = await showDialog<TelegramChat>(
      context: context,
      builder: (_) => _TelegramForwardDialog(
        appState: widget.appState,
        accountId: _activeAccountId,
        chats: _chats.where((c) => !c.readOnly).toList(),
      ),
    );
    if (!mounted || targetChat == null) return;
    await _forwardMessagesToChat(messagesToForward, targetChat);
  }

  Future<void> _forwardMessagesToChat(
    List<TelegramMessage> messagesToForward,
    TelegramChat targetChat,
  ) async {
    final sourceChat = _selectedChat;
    int successCount = 0;

    for (final m in messagesToForward) {
      final senderLabel =
          m.sender.isNotEmpty ? m.sender : (sourceChat?.title ?? '会话');
      final header = '📤 [转发自 $senderLabel]';
      final bodyText = [
        header,
        if (m.text.trim().isNotEmpty) m.text.trim(),
        if (m.links.isNotEmpty &&
            !m.links.every((u) => m.text.contains(u)))
          m.links.join('\n'),
      ].join('\n');

      // If message has an image/small file attachment, try forwarding the file too
      final att = m.attachment;
      if (att != null &&
          sourceChat != null &&
          (att.kind == 'photo' || (att.size > 0 && att.size <= 25 * 1024 * 1024))) {
        try {
          final dlUrl = att.kind == 'photo'
              ? widget.appState.api.buildTelegramThumbnailUrl(
                  accountId: _activeAccountId,
                  peer: sourceChat.peer,
                  messageId: m.id,
                )
              : widget.appState.api.buildTelegramFileDownloadUrl(
                  accountId: _activeAccountId,
                  peer: sourceChat.peer,
                  messageId: m.id,
                  local: true,
                );
          final bytes = await widget.appState.api.downloadTelegramBytes(dlUrl);
          if (bytes.isNotEmpty) {
            await widget.appState.api.sendTelegramFiles(
              accountId: _activeAccountId,
              peer: targetChat.peer,
              files: [
                TelegramOutgoingFile(
                  name: att.displayName,
                  bytes: bytes,
                  mimeType: att.mimeType.isNotEmpty
                      ? att.mimeType
                      : _guessMimeType(att.displayName),
                ),
              ],
              text: bodyText.length > 1024
                  ? bodyText.substring(0, 1024)
                  : bodyText,
              asFile: att.kind != 'photo',
            );
            successCount++;
            continue;
          }
        } catch (_) {}
      }

      try {
        await widget.appState.api.sendTelegramTextMessage(
          accountId: _activeAccountId,
          peer: targetChat.peer,
          text: bodyText,
        );
        successCount++;
      } catch (_) {}
    }

    if (!mounted) return;
    if (_selectionMode) {
      setState(() {
        _selectionMode = false;
        _selectedMessageIds.clear();
      });
    }
    if (_selectedChat?.peer == targetChat.peer) {
      await _loadMessages(loadOlder: false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已成功转发 $successCount 条消息至「${targetChat.title}」')),
    );
  }

  /// One-click save message to Saved Messages ("收藏夹")
  Future<void> _saveMessageToSavedMessages(TelegramMessage msg) async {
    final selfChat = _chats.cast<TelegramChat?>().firstWhere(
      (c) =>
          c != null &&
          (c.self ||
              c.peer.startsWith('self') ||
              c.title.contains('收藏') ||
              c.title.toLowerCase().contains('saved messages')),
      orElse: () => null,
    );
    if (selfChat != null) {
      await _forwardMessagesToChat([msg], selfChat);
    } else {
      await _showForwardMessagesDialog([msg]);
    }
  }

  bool _isTelegramLink(String url) {
    final lower = url.trim().toLowerCase();
    return lower.startsWith('tg://') ||
        lower.startsWith('https://t.me/') ||
        lower.startsWith('http://t.me/') ||
        lower.startsWith('https://telegram.me/') ||
        lower.startsWith('https://telegram.dog/');
  }

  Future<void> _openOrResolveLink(String url) async {
    if (_isTelegramLink(url)) {
      try {
        final resolved = await widget.appState.api.resolveTelegramLink(
          accountId: _activeAccountId,
          url: url,
        );
        if (!mounted) return;
        setState(() {
          final existingIdx = _chats.indexWhere(
            (c) => c.peer == resolved.chat.peer,
          );
          if (existingIdx >= 0) {
            _chats[existingIdx] = resolved.chat.copyWith(unread: 0);
          } else {
            _chats = [resolved.chat.copyWith(unread: 0), ..._chats];
          }
          _selectedChat = resolved.chat.copyWith(unread: 0);
          _messages = resolved.messages;
          _nextMessageOffset = resolved.nextOffset;
        });
        _markChatAsRead(resolved.chat);
        _scrollToBottom(animated: false);
        return;
      } catch (_) {}
    }
    final uri = Uri.tryParse(url);
    if (uri != null) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    }
  }

  Future<void> _deleteMessagesByIds(List<int> ids) async {
    final chat = _selectedChat;
    if (chat == null || ids.isEmpty) return;

    try {
      await widget.appState.api.deleteTelegramMessages(
        accountId: _activeAccountId,
        peer: chat.peer,
        messageIds: ids,
        revoke: true,
      );
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => ids.contains(m.id));
        _selectedMessageIds.removeAll(ids);
        if (_selectedMessageIds.isEmpty) {
          _selectionMode = false;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 ${ids.length} 条消息')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除消息失败：$e')),
        );
      }
    }
  }

  bool _isUrlQueuedOrInTasks(String url) {
    if (url.isEmpty) return false;
    final key = '$_activeAccountId:$url';
    if (_queuedDownloads.contains(key)) return true;
    return widget.appState.tasks.any((t) => t.url == url);
  }

  Future<bool> _queueTelegramDownload({
    required String url,
    required String name,
    bool showToast = true,
  }) async {
    final key = '$_activeAccountId:$url';
    if (_pendingDownloads.contains(key)) return false;
    if (_isUrlQueuedOrInTasks(url)) {
      setState(() {
        _queuedDownloads.add(key);
        _failedDownloads.remove(key);
      });
      if (showToast) {
        _showDownloadHud('该媒体已在服务器下载队列中：$name', state: 'success');
      }
      return true;
    }

    setState(() {
      _pendingDownloads.add(key);
      _failedDownloads.remove(key);
    });
    if (showToast) {
      _showDownloadHud('正在添加到服务器下载队列：$name', state: 'loading');
    }

    try {
      await widget.appState.api.createDownloadTask(
        url: url,
        name: name,
        telegramAccountId: _activeAccountId,
        videoContext: {'download_source': 'telegram'},
      );
      await widget.appState.refreshDownloadTasks(silent: true);
      if (!mounted) return true;
      setState(() {
        _pendingDownloads.remove(key);
        _queuedDownloads.add(key);
        _failedDownloads.remove(key);
        _statusIsError = false;
      });
      if (showToast) {
        _showDownloadHud('已成功加入服务器下载队列：$name', state: 'success');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            backgroundColor: const Color(0xFF1F3327),
            content: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF4ECC5E),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('已成功加入下载队列：$name')),
              ],
            ),
          ),
        );
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _pendingDownloads.remove(key);
        _failedDownloads.add(key);
      });
      if (showToast) {
        _showDownloadHud('添加下载失败 ($name)：$e', state: 'error');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF3A1D22),
            content: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFFF6B6B),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('添加下载失败：$e')),
              ],
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _batchQueueSelectedDownloads() async {
    final selectedMsgs = _messages
        .where(
          (m) =>
              _selectedMessageIds.contains(m.id) &&
              (m.attachment?.url.isNotEmpty ?? false),
        )
        .toList();
    if (selectedMsgs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所选消息中没有可下载的媒体附件')),
      );
      return;
    }

    int count = 0;
    for (final m in selectedMsgs) {
      final att = m.attachment!;
      await _queueTelegramDownload(
        url: att.url,
        name: att.displayName,
        showToast: false,
      );
      count++;
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已批量将 $count 个 Telegram 媒体加入服务器下载队列')),
    );
  }

  void _openVideoInMiniPlayer(
    TelegramChat chat,
    TelegramMessage msg, {
    int initialPositionSeconds = 0,
  }) {
    final att = msg.attachment;
    if (att == null) return;
    _inlinePlaybackOwner.value = null;
    if (_isAudioPlaying) {
      unawaited(_audioPlayer?.pause());
    }
    final streamUrl = widget.appState.api.buildTelegramVideoStreamUrl(
      accountId: _activeAccountId,
      peer: chat.peer,
      messageId: msg.id,
    );
    widget.appState.startMiniPlayer(
      MiniPlayerSession(
        title: att.displayName,
        subtitle: 'Telegram · ${chat.title}',
        streamUrl: streamUrl,
        headers: widget.appState.api.authHeaders,
        isLive: false,
        initialPositionSeconds: initialPositionSeconds,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已开启小窗播放：${att.displayName}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openVideoViewer(
    TelegramChat chat,
    TelegramMessage msg, {
    List<TelegramMessage>? albumMessages,
  }) {
    _openMediaGalleryViewer(chat, msg, albumMessages: albumMessages);
  }

  void _openMediaGalleryViewer(
    TelegramChat chat,
    TelegramMessage msg, {
    List<TelegramMessage>? albumMessages,
  }) {
    if ((msg.attachment?.isVideo ?? false) && _isAudioPlaying) {
      unawaited(_audioPlayer?.pause());
    }
    _inlinePlaybackOwner.value = null;
    final allVisualMedia = _messages
        .where((m) => m.attachment != null && m.attachment!.isVisualMedia)
        .toList();
    if (!allVisualMedia.any((m) => m.id == msg.id)) {
      allVisualMedia.add(msg);
    }

    List<TelegramMessage>? resolvedAlbum = albumMessages;
    final gid = msg.groupedId.trim();
    if ((resolvedAlbum == null || resolvedAlbum.isEmpty) &&
        gid.isNotEmpty &&
        gid != '0') {
      final matched = _messages
          .where(
            (m) =>
                m.groupedId.trim() == gid &&
                m.attachment != null &&
                m.attachment!.isVisualMedia,
          )
          .toList();
      if (matched.length > 1) {
        resolvedAlbum = matched;
      }
    }

    showDialog<void>(
      context: context,
      barrierColor: const Color(0xEB000000),
      builder: (_) => _TelegramPhotoGalleryDialog(
        appState: widget.appState,
        accountId: _activeAccountId,
        chat: chat,
        photoMessages: allVisualMedia,
        albumMessages: resolvedAlbum,
        initialMessageId: msg.id,
        onQueueDownload: (m) async {
          if (m.attachment?.url.isNotEmpty ?? false) {
            return await _queueTelegramDownload(
              url: m.attachment!.url,
              name: m.attachment!.displayName,
            );
          }
          return false;
        },
        onQueueAlbumDownload: (items) async {
          int okCount = 0;
          for (final item in items) {
            final a = item.attachment;
            if (a != null && a.url.isNotEmpty) {
              final ok = await _queueTelegramDownload(
                url: a.url,
                name: a.displayName,
                showToast: false,
              );
              if (ok) okCount++;
            }
          }
          if (mounted) {
            _showDownloadHud(
              okCount > 0
                  ? '已将相册分组 ($okCount 项) 成功加入下载队列'
                  : '相册分组添加下载失败',
              state: okCount > 0 ? 'success' : 'error',
            );
          }
          return okCount > 0;
        },
        onSaveLocal: (m) => _saveAttachmentToLocalDownloads(chat, m),
        onOpenMiniPlayer: (m, posSec) => _openVideoInMiniPlayer(
          chat,
          m,
          initialPositionSeconds: posSec,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Official Telegram Music & Voice Playback Controller
  // ---------------------------------------------------------------------------

  bool _isAudioTrackActive(TelegramChat chat, TelegramMessage msg) {
    return _playingAudioMessage?.id == msg.id &&
        _playingAudioChat?.peer == chat.peer &&
        _playingAudioAccountId == _activeAccountId;
  }

  List<TelegramMessage> _resolveAudioPlaylistFor(
    TelegramChat chat,
    TelegramMessage seedMsg,
  ) {
    final seedIsMusic = seedMsg.attachment?.isMusic ?? false;
    final source = (_selectedChat?.peer == chat.peer && _messages.isNotEmpty)
        ? _messages
        : (_cachedMessagesByPeer['$_activeAccountId|${chat.peer}']?.messages ??
            _playingAudioPlaylist);
    final filtered = source.where((m) {
      final a = m.attachment;
      if (a == null || !a.isAudio) return false;
      return seedIsMusic ? a.isMusic : a.isVoiceMessage;
    }).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (!filtered.any((m) => m.id == seedMsg.id)) {
      filtered.add(seedMsg);
      filtered.sort((a, b) => a.id.compareTo(b.id));
    }
    return filtered;
  }

  void _ensureAudioPlayerInitialized() {
    if (_audioPlayer != null) return;
    final p = Player();
    _audioPlayer = p;
    _audioPlayingSub = p.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() {
        _isAudioPlaying = playing;
        if (playing) {
          _isAudioLoading = false;
          _audioErrorText = '';
        }
      });
    });
    _audioPosSub = p.stream.position.listen((pos) {
      if (!mounted) return;
      if (pos.inMilliseconds >= 600 && _isAudioPlaying) {
        _audioHasStartedPlaying = true;
      }
      if ((pos.inMilliseconds - _audioPosition.inMilliseconds).abs() >= 250 ||
          pos == Duration.zero) {
        setState(() => _audioPosition = pos);
      }
    });
    _audioDurSub = p.stream.duration.listen((dur) {
      if (dur > Duration.zero && mounted && dur != _audioDuration) {
        setState(() => _audioDuration = dur);
      }
    });
    _audioCompletedSub = p.stream.completed.listen((completed) {
      if (!completed ||
          !mounted ||
          _audioHandlingCompletion ||
          _isAudioLoading ||
          _audioErrorText.isNotEmpty) {
        return;
      }
      // Only auto-advance when the current track genuinely played past 600ms
      if (!_audioHasStartedPlaying || _audioPosition.inMilliseconds < 600) {
        return;
      }
      _audioHasStartedPlaying = false;
      _onAudioTrackCompleted();
    });
    _audioErrorSub = p.stream.error.listen((err) {
      if (!mounted || err.trim().isEmpty) return;
      // If _togglePlayAudioMessage is still actively opening/falling back, let it handle recovery sequentially
      if (_isAudioLoading && !_audioUsedFallbackUrl) return;
      setState(() {
        _isAudioLoading = false;
        _isAudioPlaying = false;
        _audioHasStartedPlaying = false;
        _audioErrorText = '音频播放失败，点击重试';
      });
    });
  }

  Future<void> _togglePlayAudioMessage(
    TelegramChat chat,
    TelegramMessage msg, {
    bool forceRestart = false,
  }) async {
    final att = msg.attachment;
    if (att == null || !att.isAudio) return;

    if (!forceRestart &&
        _isAudioTrackActive(chat, msg) &&
        _audioPlayer != null &&
        _audioErrorText.isEmpty &&
        !_isAudioLoading) {
      if (!_audioPlayer!.state.playing) {
        unawaited(
          CloudMusicController.shared.stopAndClose(clearPersistedQueue: false),
        );
      }
      await _audioPlayer!.playOrPause();
      return;
    }

    unawaited(
      CloudMusicController.shared.stopAndClose(clearPersistedQueue: false),
    );
    _ensureAudioPlayerInitialized();
    final openSeq = ++_audioOpenSeq;
    final playlist = _resolveAudioPlaylistFor(chat, msg);
    final initialDur = att.duration > 0
        ? Duration(seconds: att.duration)
        : Duration.zero;

    setState(() {
      _playingAudioAccountId = _activeAccountId;
      _playingAudioChat = chat;
      _playingAudioMessage = msg;
      _playingAudioPlaylist = playlist;
      _isAudioLoading = true;
      _isAudioPlaying = false;
      _audioHasStartedPlaying = false;
      _audioErrorText = '';
      _audioPosition = Duration.zero;
      _audioDuration = initialDur;
      _audioUsedFallbackUrl = false;
    });

    final primaryUrl = widget.appState.api.buildTelegramFileContentUrl(
      accountId: _activeAccountId,
      peer: chat.peer,
      messageId: msg.id,
    );

    try {
      await _audioPlayer!.open(
        Media(primaryUrl, httpHeaders: widget.appState.api.authHeaders),
        play: true,
      );
      if (!mounted || openSeq != _audioOpenSeq) return;
      if (_audioSpeed != 1.0) {
        await _audioPlayer!.setRate(_audioSpeed);
      }
    } catch (_) {
      if (!mounted || openSeq != _audioOpenSeq) return;
      // Fallback to /api/telegram/file?local=1
      _audioUsedFallbackUrl = true;
      final fallbackUrl = widget.appState.api.buildTelegramFileDownloadUrl(
        accountId: _activeAccountId,
        peer: chat.peer,
        messageId: msg.id,
        local: true,
      );
      try {
        await _audioPlayer!.open(
          Media(fallbackUrl, httpHeaders: widget.appState.api.authHeaders),
          play: true,
        );
        if (!mounted || openSeq != _audioOpenSeq) return;
        if (_audioSpeed != 1.0) {
          await _audioPlayer!.setRate(_audioSpeed);
        }
      } catch (_) {
        if (mounted && openSeq == _audioOpenSeq) {
          setState(() {
            _isAudioLoading = false;
            _isAudioPlaying = false;
            _audioHasStartedPlaying = false;
            _audioErrorText = '音频加载失败，点击重试';
          });
        }
      }
    }
  }

  Future<void> _onAudioTrackCompleted() async {
    final chat = _playingAudioChat;
    final current = _playingAudioMessage;
    if (chat == null || current == null || _audioHandlingCompletion) return;

    _audioHandlingCompletion = true;
    try {
      if (_audioPlayMode == 'repeatOne') {
        await _audioPlayer?.seek(Duration.zero);
        await _audioPlayer?.play();
        return;
      }

      final playlist = _resolveAudioPlaylistFor(chat, current);
      _playingAudioPlaylist = playlist;
      if (playlist.length <= 1) {
        if (_audioPlayMode == 'repeatAll') {
          await _audioPlayer?.seek(Duration.zero);
          await _audioPlayer?.play();
        } else if (mounted) {
          setState(() {
            _isAudioPlaying = false;
            _audioPosition = Duration.zero;
          });
        }
        return;
      }

      final curIdx = playlist.indexWhere((m) => m.id == current.id);
      if (curIdx < 0) return;

      if (_audioPlayMode == 'shuffle') {
        final candidates =
            playlist.where((m) => m.id != current.id).toList();
        if (candidates.isNotEmpty) {
          final pickIdx =
              DateTime.now().microsecondsSinceEpoch % candidates.length;
          await _togglePlayAudioMessage(
            chat,
            candidates[pickIdx],
            forceRestart: true,
          );
          return;
        }
      }

      final nextIdx = curIdx + 1;
      if (nextIdx < playlist.length) {
        await _togglePlayAudioMessage(
          chat,
          playlist[nextIdx],
          forceRestart: true,
        );
      } else if (_audioPlayMode == 'repeatAll') {
        await _togglePlayAudioMessage(
          chat,
          playlist.first,
          forceRestart: true,
        );
      } else if (mounted) {
        setState(() {
          _isAudioPlaying = false;
          _audioPosition = Duration.zero;
        });
      }
    } finally {
      _audioHandlingCompletion = false;
    }
  }

  Future<void> _playAdjacentAudioTrack(int delta) async {
    final chat = _playingAudioChat;
    final current = _playingAudioMessage;
    if (chat == null || current == null) return;
    final playlist = _resolveAudioPlaylistFor(chat, current);
    _playingAudioPlaylist = playlist;
    if (playlist.isEmpty) return;

    final curIdx = playlist.indexWhere((m) => m.id == current.id);
    if (curIdx < 0) {
      await _togglePlayAudioMessage(chat, playlist.first, forceRestart: true);
      return;
    }

    if (delta < 0 && _audioPosition.inSeconds >= 4) {
      await _audioPlayer?.seek(Duration.zero);
      return;
    }

    int targetIdx = curIdx + delta;
    if (targetIdx < 0) {
      targetIdx = playlist.length - 1;
    } else if (targetIdx >= playlist.length) {
      targetIdx = 0;
    }
    await _togglePlayAudioMessage(
      chat,
      playlist[targetIdx],
      forceRestart: true,
    );
  }

  Future<void> _seekAudioTrack(Duration target) async {
    if (_audioPlayer == null) return;
    setState(() => _audioPosition = target);
    await _audioPlayer!.seek(target);
  }

  void _cycleAudioSpeed() {
    final next = _audioSpeed == 1.0
        ? 1.25
        : (_audioSpeed == 1.25
            ? 1.5
            : (_audioSpeed == 1.5 ? 2.0 : 1.0));
    setState(() => _audioSpeed = next);
    _audioPlayer?.setRate(next);
  }

  void _cycleAudioPlayMode() {
    const modes = ['sequential', 'repeatAll', 'repeatOne', 'shuffle'];
    final idx = modes.indexOf(_audioPlayMode);
    final next = modes[(idx + 1) % modes.length];
    setState(() => _audioPlayMode = next);
    final label = switch (next) {
      'repeatAll' => '列表循环播放',
      'repeatOne' => '单曲循环播放',
      'shuffle' => '随机播放',
      _ => '顺序连播',
    };
    _showDownloadHud('已切换音乐播放模式：$label', state: 'success');
  }

  Future<void> _stopAndCloseAudioPlayer() async {
    _audioOpenSeq++;
    _audioHasStartedPlaying = false;
    await _audioPlayer?.stop();
    if (!mounted) return;
    setState(() {
      _isAudioPlaying = false;
      _isAudioLoading = false;
      _audioErrorText = '';
      _audioPosition = Duration.zero;
      _audioDuration = Duration.zero;
      _playingAudioMessage = null;
      _playingAudioChat = null;
    });
  }

  Future<void> _jumpToPlayingAudioMessage() async {
    final chat = _playingAudioChat;
    final msg = _playingAudioMessage;
    if (chat == null || msg == null) return;
    if (_selectedChat?.peer != chat.peer) {
      await _selectChat(chat);
    }
    if (!mounted) return;
    if (_mediaTypeFilter != 'all' && _mediaTypeFilter != 'music') {
      setState(() => _mediaTypeFilter = 'all');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messageScrollController.hasClients) return;
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      if (idx < 0 || _messages.isEmpty) return;
      final maxExt = _messageScrollController.position.maxScrollExtent;
      final ratio = ((_messages.length - 1 - idx) / _messages.length).clamp(0.0, 1.0);
      _messageScrollController.animateTo(
        (maxExt * ratio).clamp(0.0, maxExt),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _exportCurrentChatHistory(
    TelegramChat chat, {
    required bool asJson,
  }) async {
    final targetMsgs =
        _selectionMode && _selectedMessageIds.isNotEmpty
            ? _messages
                .where((m) => _selectedMessageIds.contains(m.id))
                .toList()
            : _messages;
    if (targetMsgs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前会话暂无可导出的消息')),
      );
      return;
    }

    String content;
    final ext = asJson ? 'json' : 'md';
    if (asJson) {
      final payload = {
        'chat': {
          'peer': chat.peer,
          'title': chat.title,
          'kind': chat.kind,
        },
        'exported_at': DateTime.now().toIso8601String(),
        'count': targetMsgs.length,
        'messages': targetMsgs
            .map(
              (m) => {
                'id': m.id,
                'sender': m.sender,
                'date': m.date,
                'outgoing': m.outgoing,
                'text': m.text,
                if (m.attachment != null)
                  'attachment': {
                    'kind': m.attachment!.kind,
                    'name': m.attachment!.displayName,
                    'size': m.attachment!.size,
                    'url': m.attachment!.url,
                  },
              },
            )
            .toList(),
      };
      content = const JsonEncoder.withIndent('  ').convert(payload);
    } else {
      final sb = StringBuffer();
      sb.writeln('# Telegram 会话归档：${chat.title} (${chat.peer})');
      sb.writeln('> 导出时间：${DateTime.now().toIso8601String()} · 共 ${targetMsgs.length} 条消息\n');
      for (final m in targetMsgs) {
        final dt = m.date > 0
            ? DateTime.fromMillisecondsSinceEpoch(m.date * 1000)
                .toString()
                .substring(0, 19)
            : '';
        final who = m.outgoing ? '我' : (m.sender.isNotEmpty ? m.sender : chat.title);
        sb.writeln('### [$dt] **$who** (#${m.id})');
        if (m.attachment != null) {
          sb.writeln(
            '- 📎 附件 (${m.attachment!.kind}): `${m.attachment!.displayName}` ${m.attachment!.formattedSize}',
          );
        }
        if (m.text.isNotEmpty) {
          sb.writeln(m.text);
        }
        sb.writeln();
      }
      content = sb.toString();
    }

    await Clipboard.setData(ClipboardData(text: content));
    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home/Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final safePeer = chat.peer.replaceAll(RegExp(r'[^\w\-]'), '_');
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final file = File('${targetDir.path}/telegram_${safePeer}_$ts.$ext');
      await file.writeAsString(content, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出 ${targetMsgs.length} 条消息并复制到剪贴板：${file.path}'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已将 ${targetMsgs.length} 条消息记录复制到剪贴板'),
        ),
      );
    }
  }

  Future<void> _showQuickRepliesDialog(_TgPalette tg) async {
    final newCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: tg.sidebarBg,
              title: Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 19, color: tg.tgBlueBright),
                  const SizedBox(width: 8),
                  Text(
                    '快捷回复模板管理',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: tg.textPrimary,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                height: 340,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newCtrl,
                            style: TextStyle(
                              fontSize: 13,
                              color: tg.textPrimary,
                            ),
                            decoration: const InputDecoration(
                              hintText: '输入新增常用快捷回复短语...',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: () {
                            final text = newCtrl.text.trim();
                            if (text.isEmpty) return;
                            setState(() {
                              _quickReplies.insert(0, text);
                            });
                            _persistQuickReplies();
                            newCtrl.clear();
                            setDialogState(() {});
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _quickReplies.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: tg.borderLine),
                        itemBuilder: (_, idx) {
                          final phrase = _quickReplies[idx];
                          return ListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 6),
                            title: Text(
                              phrase,
                              style: TextStyle(
                                fontSize: 13,
                                color: tg.textPrimary,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    _insertTextAtCursor(phrase);
                                  },
                                  child: const Text('填入'),
                                ),
                                FilledButton.tonal(
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    _composeController.text = phrase;
                                    _sendMessage();
                                  },
                                  child: const Text('直接发送'),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                    color: tg.textMuted,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _quickReplies.removeAt(idx);
                                    });
                                    _persistQuickReplies();
                                    setDialogState(() {});
                                  },
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
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
    newCtrl.dispose();
  }

  Future<void> _showAccountSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TelegramAccountConfigDialog(
        appState: widget.appState,
        initialAccountId: _activeAccountId,
        onChanged: (newAccountId) {
          _bootstrapTelegram(preferredAccountId: newAccountId);
        },
      ),
    );
  }

  String _formatDialogTime(int unixSec) {
    if (unixSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final now = DateTime.now();
    final isToday =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return '昨天';
    }
    if (now.difference(dt).inDays < 7) {
      const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      return weekdays[(dt.weekday - 1).clamp(0, 6)];
    }
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  String _formatBubbleTime(int unixSec) {
    if (unixSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDatePill(int unixSec) {
    if (unixSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '今天';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return '昨天';
    }
    if (dt.year == now.year) {
      return '${dt.month}月${dt.day}日';
    }
    return '${dt.year}年${dt.month}月${dt.day}日';
  }

  String _formatDurationClock(int seconds) {
    if (seconds <= 0) return '00:00';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _resolvePeerAvatar(
    String peer,
    String title, {
    String? explicitAvatar,
  }) {
    final direct = explicitAvatar?.trim() ?? '';
    if (direct.isNotEmpty) return direct;

    if (peer.isNotEmpty) {
      final cachedByPeer = _knownPeerAvatars[_peerReadKey(peer)];
      if (cachedByPeer != null && cachedByPeer.isNotEmpty) {
        return cachedByPeer;
      }
      for (final c in _chats) {
        if (c.peer == peer && c.avatar.isNotEmpty) {
          return c.avatar;
        }
      }
      for (final a in _accounts) {
        if (a.id == peer) {
          if (a.avatar.isNotEmpty) return a.avatar;
          if (a.userId.isNotEmpty && a.userId != '0') {
            final userPeer = 'user:${a.userId}';
            final byAccUser = _knownPeerAvatars['${a.id}|$userPeer'] ??
                _knownPeerAvatars[_peerReadKey(userPeer)];
            if (byAccUser != null && byAccUser.isNotEmpty) {
              return byAccUser;
            }
            for (final c in _chats) {
              if ((c.peer == userPeer || c.self) && c.avatar.isNotEmpty) {
                return c.avatar;
              }
            }
          }
        }
      }
    }

    final cleanTitle = title.trim();
    if (cleanTitle.isNotEmpty) {
      final cachedByTitle = _knownTitleAvatars['$_activeAccountId|$cleanTitle'];
      if (cachedByTitle != null && cachedByTitle.isNotEmpty) {
        return cachedByTitle;
      }
      for (final c in _chats) {
        if (c.title.trim() == cleanTitle && c.avatar.isNotEmpty) {
          return c.avatar;
        }
      }
    }

    return '';
  }

  String _resolvePeerHdAvatarUrl(
    String peer,
    String title, {
    String? explicitHdAvatarUrl,
  }) {
    final direct = explicitHdAvatarUrl?.trim() ?? '';
    if (direct.isNotEmpty) return direct;

    if (peer.isNotEmpty) {
      final cachedByPeer = _knownPeerSharpAvatars[_peerReadKey(peer)];
      if (cachedByPeer != null && cachedByPeer.hdUrl.isNotEmpty) {
        return cachedByPeer.hdUrl;
      }
      for (final c in _chats) {
        if (c.peer == peer && c.hasSharpAvatar) {
          return widget.appState.api.buildTelegramAvatarUrl(
            accountId: _activeAccountId,
            peer: c.peer,
            photoId: c.avatarPhotoId,
            dcId: c.avatarDcId,
          );
        }
      }
      for (final a in _accounts) {
        if (a.id == peer && a.userId.isNotEmpty && a.userId != '0') {
          final userPeer = 'user:${a.userId}';
          final byAccUser = _knownPeerSharpAvatars['${a.id}|$userPeer'] ??
              _knownPeerSharpAvatars[_peerReadKey(userPeer)];
          if (byAccUser != null && byAccUser.hdUrl.isNotEmpty) {
            return byAccUser.hdUrl;
          }
          for (final c in _chats) {
            if ((c.peer == userPeer || c.self) && c.hasSharpAvatar) {
              return widget.appState.api.buildTelegramAvatarUrl(
                accountId: a.id,
                peer: c.peer,
                photoId: c.avatarPhotoId,
                dcId: c.avatarDcId,
              );
            }
          }
        }
      }
    }

    final cleanTitle = title.trim();
    if (cleanTitle.isNotEmpty) {
      final cachedByTitle =
          _knownTitleHdAvatarUrls['$_activeAccountId|$cleanTitle'];
      if (cachedByTitle != null && cachedByTitle.isNotEmpty) {
        return cachedByTitle;
      }
      for (final c in _chats) {
        if (c.title.trim() == cleanTitle && c.hasSharpAvatar) {
          return widget.appState.api.buildTelegramAvatarUrl(
            accountId: _activeAccountId,
            peer: c.peer,
            photoId: c.avatarPhotoId,
            dcId: c.avatarDcId,
          );
        }
      }
    }

    return '';
  }

  Widget _buildPeerAvatar(
    String peer,
    String title, {
    String? avatar,
    String? hdAvatarUrl,
    bool isSelf = false,
    double size = 48,
    double fontSize = 17,
  }) {
    final resolvedAvatar = _resolvePeerAvatar(
      peer,
      title,
      explicitAvatar: avatar,
    );
    final resolvedHdAvatarUrl = _resolvePeerHdAvatarUrl(
      peer,
      title,
      explicitHdAvatarUrl: hdAvatarUrl,
    );
    final effectiveSelf = isSelf ||
        peer == 'self' ||
        peer.startsWith('self:') ||
        title.trim() == '收藏夹';
    return _TelegramPeerAvatar(
      peer: peer,
      title: title,
      avatar: resolvedAvatar,
      hdAvatarUrl: resolvedHdAvatarUrl,
      isSelf: effectiveSelf,
      size: size,
      fontSize: fontSize,
      appState: widget.appState,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.appState.isTelegramViewActive) {
      widget.appState.activeChildBackHandler = _handleBackPress;
    } else if (widget.appState.activeChildBackHandler == _handleBackPress) {
      widget.appState.activeChildBackHandler = null;
    }
    final tg = _TgPalette(VideoPlatformTheme.isDark);

    if (!_authStatus.authorized && !_isLoadingChats) {
      return RepaintBoundary(
        key: _captureBoundaryKey,
        child: Container(
          color: tg.chatWallpaperBg,
          child: _buildUnauthorizedPlaceholder(tg),
        ),
      );
    }

    return RepaintBoundary(
      key: _captureBoundaryKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mqSize = MediaQuery.sizeOf(context);
          final isPhoneDevice = (Platform.isAndroid || Platform.isIOS) &&
              !widget.appState.isHardwareTv &&
              mqSize.shortestSide < 600;
          final isDesktop = !isPhoneDevice &&
              constraints.maxWidth >= 760 &&
              (constraints.maxWidth >= 860 || widget.appState.tvMode);
          final showInfoDrawer =
              isDesktop && _showRightInfoPanel && _selectedChat != null;

          if (isDesktop) {
            final dialogsWidth = constraints.maxWidth < 1080 ? 256.0 : 320.0;
            return Row(
              children: [
                if (!_isDialogsSidebarCollapsed) ...[
                  // 1. Official Telegram Desktop Far-Left Folder Rail (72px)
                  _buildTelegramFolderRail(tg),
                  // 2. Official Telegram Dialogs List Column
                  SizedBox(
                    width: dialogsWidth,
                    child: _buildDialogsSidebar(tg, isMobile: false),
                  ),
                  Container(width: 1, color: tg.borderLine),
                ],
                // 3. Official Telegram Main Chat Window
                Expanded(
                  child: _buildConversationPane(tg, isMobile: false),
                ),
                // 4. Optional Right Shared Media / Chat Info Drawer (290px)
                if (showInfoDrawer) ...[
                  Container(width: 1, color: tg.borderLine),
                  SizedBox(
                    width: 280,
                    child: _buildRightChatInfoPanel(tg, _selectedChat!),
                  ),
                ],
              ],
            );
          }

          // Official Telegram Mobile (iOS / Android) Full-Screen Single-Page Stack Navigation:
          // Page 1: Full-screen Chat List -> Tap Chat -> Page 2: Full-screen Conversation -> Tap Header -> Page 3: Full-screen Chat Info
          if (_selectedChat != null) {
            return _showRightInfoPanel
                ? _buildRightChatInfoPanel(tg, _selectedChat!)
                : _buildConversationPane(tg, isMobile: true);
          }
          return _buildDialogsSidebar(tg, isMobile: true);
        },
      ),
    );
  }

  /// Far-left vertical folder & account rail matching official Telegram Desktop
  Widget _buildTelegramFolderRail(_TgPalette tg) {
    final activeAcc = _accounts.firstWhere(
      (a) => a.id == _activeAccountId,
      orElse: () => TelegramAccount(id: _activeAccountId, name: '账号'),
    );

    return Container(
      width: 72,
      color: tg.folderRailBg,
      child: Column(
        children: [
          const SizedBox(height: 8),
          // If multiple accounts exist, render direct 1-click / TV-focusable account pills right on the rail!
          if (_accounts.length > 1)
            ..._accounts.map((acc) {
              final isCurrent = acc.id == _activeAccountId;
              return StatefulBuilder(
                builder: (accCtx, setAccState) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onFocusChange: (_) {
                      if (accCtx.mounted) setAccState(() {});
                    },
                    onTap: () {
                      if (!isCurrent) {
                        _switchTelegramAccount(acc.id);
                      } else {
                        _showAccountSettingsDialog();
                      }
                    },
                    child: Builder(
                      builder: (innerCtx) {
                        final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
                        return Container(
                          width: 64,
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(
                            vertical: 5,
                            horizontal: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isFocused
                                ? tg.tgBlueBright.withValues(alpha: 0.28)
                                : (isCurrent
                                    ? tg.tgBlueBright.withValues(alpha: 0.14)
                                    : Colors.transparent),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isFocused
                                  ? const Color(0xFFFFE066)
                                  : (isCurrent
                                      ? tg.tgBlueBright
                                      : Colors.transparent),
                              width: isFocused ? 2.2 : 1.5,
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  _buildPeerAvatar(
                                    acc.id,
                                    acc.name,
                                    size: 34,
                                    fontSize: 13,
                                  ),
                                  if (isCurrent)
                                    Positioned(
                                      right: -1,
                                      bottom: -1,
                                      child: Container(
                                        width: 11,
                                        height: 11,
                                        decoration: BoxDecoration(
                                          color: _authStatus.authorized
                                              ? const Color(0xFF4ECC5E)
                                              : const Color(0xFFF5A623),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: tg.folderRailBg,
                                            width: 1.8,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                acc.name.trim().isNotEmpty
                                    ? acc.name.trim()
                                    : acc.id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: (isCurrent || isFocused)
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: (isCurrent || isFocused)
                                      ? Colors.white
                                      : tg.folderRailIconInactive,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            })
          else
            // Single account: focusable avatar button opening menu / settings
            PopupMenuButton<String>(
              color: tg.sidebarBg,
              onSelected: (val) async {
                if (val == '__settings__') {
                  _showAccountSettingsDialog();
                } else if (val == '__refresh__') {
                  _bootstrapTelegram(
                    preferredAccountId: _activeAccountId,
                    forceRefresh: true,
                  );
                } else if (val != _activeAccountId) {
                  await _switchTelegramAccount(val);
                }
              },
              itemBuilder: (_) => [
                ..._accounts.map(
                  (a) => PopupMenuItem<String>(
                    value: a.id,
                    child: Row(
                      children: [
                        _buildPeerAvatar(
                          a.id,
                          a.name,
                          size: 26,
                          fontSize: 11,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            a.displayLabel,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: a.id == _activeAccountId
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: tg.textPrimary,
                            ),
                          ),
                        ),
                        if (a.id == _activeAccountId)
                          Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: tg.tgBlueBright,
                          ),
                      ],
                    ),
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: '__settings__',
                  child: Row(
                    children: [
                      Icon(
                        Icons.settings_outlined,
                        size: 18,
                        color: tg.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '账号与 API 登录配置...',
                        style: TextStyle(fontSize: 13, color: tg.textPrimary),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: '__refresh__',
                  child: Row(
                    children: [
                      Icon(
                        Icons.sync_rounded,
                        size: 18,
                        color: tg.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '重新同步会话列表',
                        style: TextStyle(fontSize: 13, color: tg.textPrimary),
                      ),
                    ],
                  ),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _buildPeerAvatar(
                      activeAcc.id,
                      activeAcc.name,
                      size: 38,
                      fontSize: 14,
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _authStatus.authorized
                              ? const Color(0xFF4ECC5E)
                              : const Color(0xFFF5A623),
                          shape: BoxShape.circle,
                          border: Border.all(color: tg.folderRailBg, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Divider(height: 1, indent: 12, endIndent: 12, color: tg.borderLine),
          const SizedBox(height: 4),
          // Vertical folder tabs
          Expanded(
            child: ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (_, idx) {
                final f = _folders[idx];
                final selected = f.key == _selectedFolderKey;
                IconData iconData = Icons.folder_outlined;
                if (f.key == '0') {
                  iconData = Icons.forum_rounded;
                } else if (f.key == '1') {
                  iconData = Icons.inventory_2_outlined;
                } else if (f.title.contains('频道') ||
                    f.title.toLowerCase().contains('channel')) {
                  iconData = Icons.campaign_rounded;
                } else if (f.title.contains('群') ||
                    f.title.toLowerCase().contains('group')) {
                  iconData = Icons.groups_rounded;
                } else if (f.title.contains('影视') ||
                    f.title.contains('视频')) {
                  iconData = Icons.movie_outlined;
                }

                return StatefulBuilder(
                  builder: (fCtx, setFState) {
                    return InkWell(
                      onFocusChange: (_) {
                        if (fCtx.mounted) setFState(() {});
                      },
                      onTap: () => _switchFolder(f.key),
                      child: Builder(
                        builder: (innerCtx) {
                          final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isFocused
                                  ? tg.tgBlueBright.withValues(alpha: 0.22)
                                  : Colors.transparent,
                              border: isFocused
                                  ? Border.all(
                                      color: const Color(0xFFFFE066),
                                      width: 2.0,
                                    )
                                  : Border(
                                      left: BorderSide(
                                        color: selected
                                            ? tg.folderRailIconActive
                                            : Colors.transparent,
                                        width: 3,
                                      ),
                                    ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  iconData,
                                  size: 24,
                                  color: (selected || isFocused)
                                      ? tg.folderRailIconActive
                                      : tg.folderRailIconInactive,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  f.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: (selected || isFocused)
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: (selected || isFocused)
                                        ? tg.folderRailIconActive
                                        : tg.folderRailIconInactive,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Bottom settings button on rail
          IconButton(
            tooltip: '账号与 API 登录配置',
            onPressed: _showAccountSettingsDialog,
            icon: Icon(
              Icons.settings_outlined,
              size: 22,
              color: tg.folderRailIconInactive,
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildUnauthorizedPlaceholder(_TgPalette tg) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: tg.sidebarBg,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [Color(0xFF42ADE8), Color(0xFF2288CC)],
                ),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.send_rounded,
                size: 36,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _authStatus.configured
                  ? '登录您的 Telegram 账号'
                  : '连接 Telegram Desktop 会话',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: tg.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '配置 API ID / API Hash 并完成验证码登录后，即可像官方客户端一样浏览所有频道与群组、在线流式播放视频或一键转存至服务器。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: tg.textSecondary,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tg.tgBlueBright,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _showAccountSettingsDialog,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('打开 Telegram 登录与账号配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMobileTelegramAccountDrawer(_TgPalette tg) {
    final activeAcc = _accounts.firstWhere(
      (a) => a.id == _activeAccountId,
      orElse: () => TelegramAccount(id: _activeAccountId, name: '当前账号'),
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tg.sidebarBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: tg.textMuted.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Active Account Profile Header
                Row(
                  children: [
                    _buildPeerAvatar(
                      activeAcc.id,
                      activeAcc.name,
                      size: 52,
                      fontSize: 18,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            activeAcc.displayLabel,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: tg.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _authStatus.authorized
                                ? '在线 · ${_chats.length} 个会话'
                                : (_authStatus.configured ? '待验证码登录' : '未配置 API'),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _authStatus.authorized
                                  ? const Color(0xFF4ECC5E)
                                  : tg.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(sheetCtx).pop();
                        _showAccountSettingsDialog();
                      },
                      icon: Icon(
                        Icons.manage_accounts_rounded,
                        size: 18,
                        color: tg.tgBlueBright,
                      ),
                      label: Text(
                        '管理账号',
                        style: TextStyle(color: tg.tgBlueBright),
                      ),
                    ),
                  ],
                ),
                if (_accounts.length > 1) ...[
                  const SizedBox(height: 12),
                  Divider(height: 1, color: tg.borderLine),
                  const SizedBox(height: 8),
                  Text(
                    '切换 Telegram 账号',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tg.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ..._accounts.map(
                    (acc) => ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: _buildPeerAvatar(
                        acc.id,
                        acc.name,
                        size: 34,
                        fontSize: 13,
                      ),
                      title: Text(
                        acc.displayLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: acc.id == _activeAccountId
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: tg.textPrimary,
                        ),
                      ),
                      trailing: acc.id == _activeAccountId
                          ? Icon(
                              Icons.check_circle_rounded,
                              size: 19,
                              color: tg.tgBlueBright,
                            )
                          : null,
                      onTap: () async {
                        Navigator.of(sheetCtx).pop();
                        if (acc.id != _activeAccountId) {
                          await _switchTelegramAccount(acc.id);
                        }
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Divider(height: 1, color: tg.borderLine),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    Icons.bookmark_outline_rounded,
                    color: tg.tgBlueBright,
                  ),
                  title: Text(
                    '收藏夹 (Saved Messages)',
                    style: TextStyle(fontSize: 14.5, color: tg.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    final selfChats = _chats.where(
                      (c) =>
                          c.self ||
                          c.peer == 'self' ||
                          c.peer.startsWith('self:') ||
                          c.title.trim() == '收藏夹',
                    );
                    if (selfChats.isNotEmpty) {
                      _selectChat(selfChats.first);
                    } else {
                      _selectChat(
                        const TelegramChat(
                          peer: 'self',
                          title: '收藏夹',
                          self: true,
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    Icons.done_all_rounded,
                    color: tg.tgBlueBright,
                  ),
                  title: Text(
                    '全部会话标为已读',
                    style: TextStyle(fontSize: 14.5, color: tg.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _markAllChatsAsRead();
                  },
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    Icons.notifications_active_outlined,
                    color: tg.textSecondary,
                  ),
                  title: Text(
                    '消息推送与免打扰设置',
                    style: TextStyle(fontSize: 14.5, color: tg.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _showNotificationSettingsDialog();
                  },
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    Icons.settings_outlined,
                    color: tg.textSecondary,
                  ),
                  title: Text(
                    '账号登录与 API 配置',
                    style: TextStyle(fontSize: 14.5, color: tg.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _showAccountSettingsDialog();
                  },
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    Icons.sync_rounded,
                    color: tg.textSecondary,
                  ),
                  title: Text(
                    '重新同步会话与分组',
                    style: TextStyle(fontSize: 14.5, color: tg.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _bootstrapTelegram(
                      preferredAccountId: _activeAccountId,
                      forceRefresh: true,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmAndPerformConversationAction(
    _TgPalette tg,
    TelegramChat chat,
  ) async {
    final action = chat.conversationActionType;
    final label = chat.conversationActionLabel;
    if (action.isEmpty || label.isEmpty) return;

    final isDeleteContact = action == 'delete_contact';
    final cancelFocusNode = FocusNode(debugLabel: 'TgConfirmCancel');
    final confirmFocusNode = FocusNode(debugLabel: 'TgConfirmOk');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: tg.sidebarBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            Icon(
              isDeleteContact
                  ? Icons.person_remove_outlined
                  : Icons.logout_rounded,
              color: const Color(0xFFE54D42),
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: tg.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          isDeleteContact
              ? '确定删除好友「${chat.title}」？\n删除后将从您的联系人列表中移除（历史聊天记录仍会保留）。'
              : '确定$label「${chat.title}」？\n退出后将从会话列表中移除，且无法继续接收新消息（重新加入可能需要邀请链接）。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: tg.textSecondary,
          ),
        ),
        actions: [
          _buildTvFocusableActionChip(
            focusNode: cancelFocusNode,
            rightFocusNode: confirmFocusNode,
            label: '取消',
            icon: Icons.close_rounded,
            textColor: tg.textPrimary,
            bgColor: tg.searchFill,
            onTap: () => Navigator.of(dlgCtx).pop(false),
          ),
          _buildTvFocusableActionChip(
            focusNode: confirmFocusNode,
            autofocus: true,
            leftFocusNode: cancelFocusNode,
            label: '确认$label',
            icon: isDeleteContact
                ? Icons.person_remove_outlined
                : Icons.logout_rounded,
            textColor: Colors.white,
            bgColor: const Color(0xFFE54D42),
            onTap: () => Navigator.of(dlgCtx).pop(true),
          ),
        ],
      ),
    );
    cancelFocusNode.dispose();
    confirmFocusNode.dispose();

    if (confirmed != true || !mounted) return;

    _showDownloadHud('正在执行$label「${chat.title}」...', state: 'loading');
    try {
      await widget.appState.api.performTelegramConversationAction(
        accountId: _activeAccountId,
        peer: chat.peer,
        action: action,
      );
      if (!mounted) return;

      setState(() {
        _chats.removeWhere((c) => c.peer == chat.peer);
        if (_selectedChat?.peer == chat.peer) {
          _selectedChat = _chats.isNotEmpty && !_isMobileLayout
              ? _chats.first
              : null;
          _showRightInfoPanel = false;
          _selectionMode = false;
          _selectedMessageIds.clear();
          if (_selectedChat == null) {
            _messages = [];
          }
        }
      });
      _cachedChatsByAccountFolder['$_activeAccountId:$_selectedFolderKey'] = (
        chats: List<TelegramChat>.from(_chats),
        nextCursor: _nextChatCursor,
      );
      _cachedMessagesByPeer.remove('$_activeAccountId:${chat.peer}');
      if (_selectedChat != null) {
        _loadMessages(loadOlder: false);
      }
      _showDownloadHud('已成功$label：${chat.title}', state: 'success');
    } catch (e) {
      if (!mounted) return;
      _showDownloadHud('$label失败：$e', state: 'error');
    }
  }

  Future<void> _showDesktopChatRowContextMenu(
    _TgPalette tg,
    TelegramChat chat,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final isMuted = chat.muted ||
        widget.appState.telegramNotifications.isPeerMuted(
          _activeAccountId,
          chat.peer,
        );
    final actionLabel = chat.conversationActionLabel;
    final isDeleteContact = chat.conversationActionType == 'delete_contact';

    final selected = await showMenu<String>(
      context: context,
      color: tg.sidebarBg,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (chat.unread > 0)
          PopupMenuItem(
            value: 'read',
            child: Row(
              children: [
                Icon(
                  Icons.mark_chat_read_outlined,
                  size: 18,
                  color: tg.tgBlueBright,
                ),
                const SizedBox(width: 10),
                Text('标记为已读', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'mute',
          child: Row(
            children: [
              Icon(
                isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                size: 18,
                color: tg.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                isMuted ? '开启此会话新消息通知' : '静音此会话通知',
                style: TextStyle(color: tg.textPrimary),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'info',
          child: Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: tg.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                '查看共享媒体与会话资料',
                style: TextStyle(color: tg.textPrimary),
              ),
            ],
          ),
        ),
        if (actionLabel.isNotEmpty) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'leave_or_delete',
            child: Row(
              children: [
                Icon(
                  isDeleteContact
                      ? Icons.person_remove_outlined
                      : Icons.logout_rounded,
                  size: 18,
                  color: const Color(0xFFE54D42),
                ),
                const SizedBox(width: 10),
                Text(
                  actionLabel,
                  style: const TextStyle(
                    color: Color(0xFFE54D42),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );

    if (!mounted || selected == null) return;
    switch (selected) {
      case 'read':
        _markChatAsRead(chat);
        break;
      case 'mute':
        await widget.appState.telegramNotifications.toggleLocalPeerMute(
          _activeAccountId,
          chat.peer,
        );
        if (mounted) setState(() {});
        break;
      case 'info':
        await _selectChat(chat);
        if (mounted) setState(() => _showRightInfoPanel = true);
        break;
      case 'leave_or_delete':
        await _confirmAndPerformConversationAction(tg, chat);
        break;
    }
  }

  void _showMobileChatRowContextSheet(_TgPalette tg, TelegramChat chat) {
    final isMuted = chat.muted ||
        widget.appState.telegramNotifications.isPeerMuted(
          _activeAccountId,
          chat.peer,
        );
    final actionLabel = chat.conversationActionLabel;
    final isDeleteContact = chat.conversationActionType == 'delete_contact';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tg.sidebarBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: _buildPeerAvatar(
                    chat.peer,
                    chat.title,
                    avatar: chat.avatar,
                    isSelf: chat.self,
                    size: 42,
                    fontSize: 15,
                  ),
                  title: Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: tg.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    chat.preview.isNotEmpty
                        ? chat.preview
                        : (chat.broadcast ? '频道广播' : '会话'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: tg.textSecondary),
                  ),
                ),
                Divider(height: 1, color: tg.borderLine),
                if (chat.unread > 0)
                  ListTile(
                    focusColor: tg.tgBlueBright.withValues(alpha: 0.24),
                    leading: Icon(
                      Icons.mark_chat_read_outlined,
                      color: tg.tgBlueBright,
                    ),
                    title: Text(
                      '标记为已读',
                      style: TextStyle(color: tg.textPrimary),
                    ),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _markChatAsRead(chat);
                    },
                  ),
                ListTile(
                  autofocus: actionLabel.isEmpty,
                  focusColor: tg.tgBlueBright.withValues(alpha: 0.24),
                  leading: Icon(
                    isMuted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    color: tg.textSecondary,
                  ),
                  title: Text(
                    isMuted ? '开启此会话新消息通知' : '静音此会话通知',
                    style: TextStyle(color: tg.textPrimary),
                  ),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await widget.appState.telegramNotifications
                        .toggleLocalPeerMute(_activeAccountId, chat.peer);
                    if (mounted) setState(() {});
                  },
                ),
                ListTile(
                  focusColor: tg.tgBlueBright.withValues(alpha: 0.24),
                  leading: Icon(
                    Icons.info_outline_rounded,
                    color: tg.textSecondary,
                  ),
                  title: Text(
                    '查看共享媒体与会话资料',
                    style: TextStyle(color: tg.textPrimary),
                  ),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await _selectChat(chat);
                    if (mounted) {
                      setState(() => _showRightInfoPanel = true);
                    }
                  },
                ),
                if (actionLabel.isNotEmpty) ...[
                  Divider(height: 1, color: tg.borderLine),
                  ListTile(
                    autofocus: true,
                    focusColor: const Color(0xFFE54D42).withValues(alpha: 0.24),
                    leading: Icon(
                      isDeleteContact
                          ? Icons.person_remove_outlined
                          : Icons.logout_rounded,
                      color: const Color(0xFFE54D42),
                    ),
                    title: Text(
                      actionLabel,
                      style: const TextStyle(
                        color: Color(0xFFE54D42),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _confirmAndPerformConversationAction(tg, chat);
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Left dialogs list matching official Telegram Desktop & Official Telegram Mobile
  Widget _buildDialogsSidebar(_TgPalette tg, {required bool isMobile}) {
    final kw = _chatFilter.trim().toLowerCase();
    final filteredChats = _chats.where((c) {
      if (kw.isEmpty) return true;
      return c.title.toLowerCase().contains(kw) ||
          c.kind.toLowerCase().contains(kw) ||
          c.preview.toLowerCase().contains(kw);
    }).toList();
    final totalUnreadChats = _chats.where((c) => c.unread > 0).length;
    final showMobileSearchBar =
        isMobile && (_isMobileChatSearchOpen || _chatFilter.isNotEmpty);

    return Container(
      color: tg.sidebarBg,
      child: Column(
        children: [
          // Official Telegram Top AppBar (Mobile vs Desktop)
          if (isMobile)
            Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: tg.headerBg,
                border: Border(
                  bottom: BorderSide(
                    color: _folders.length > 1
                        ? Colors.transparent
                        : tg.borderLine,
                  ),
                ),
              ),
              child: showMobileSearchBar
                  ? Row(
                      children: [
                        IconButton(
                          tooltip: '关闭搜索',
                          onPressed: () {
                            _chatSearchCtrl.clear();
                            setState(() {
                              _chatFilter = '';
                              _isMobileChatSearchOpen = false;
                            });
                          },
                          icon: Icon(
                            Icons.arrow_back_rounded,
                            size: 22,
                            color: tg.textSecondary,
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _chatSearchCtrl,
                            autofocus: true,
                            onChanged: (v) => setState(() => _chatFilter = v),
                            style: TextStyle(
                              fontSize: 15,
                              color: tg.textPrimary,
                            ),
                            decoration: InputDecoration(
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              hintText: '搜索会话、频道或消息...',
                              hintStyle: TextStyle(
                                fontSize: 14.5,
                                color: tg.textMuted,
                              ),
                            ),
                          ),
                        ),
                        if (_chatFilter.isNotEmpty)
                          IconButton(
                            onPressed: () {
                              _chatSearchCtrl.clear();
                              setState(() => _chatFilter = '');
                            },
                            icon: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: tg.textMuted,
                            ),
                          ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton(
                          tooltip: 'Telegram 菜单与账号',
                          onPressed: () => _showMobileTelegramAccountDrawer(tg),
                          icon: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(
                                Icons.menu_rounded,
                                size: 24,
                                color: tg.textPrimary,
                              ),
                              Positioned(
                                right: -1,
                                bottom: -1,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _authStatus.authorized
                                        ? const Color(0xFF4ECC5E)
                                    : const Color(0xFFF5A623),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: tg.headerBg,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  _isLoadingChats ? '更新中...' : 'Telegram',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: tg.textPrimary,
                                  ),
                                ),
                              ),
                              if (totalUnreadChats > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tg.tgBlueBright,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '$totalUnreadChats',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_isLoadingChats)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: tg.tgBlueBright,
                              ),
                            ),
                          ),
                        if (totalUnreadChats > 0)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '全部标为已读',
                            onPressed: _markAllChatsAsRead,
                            icon: Icon(
                              Icons.done_all_rounded,
                              size: 21,
                              color: tg.tgBlueBright,
                            ),
                          ),
                        IconButton(
                          tooltip: '搜索会话',
                          onPressed: () => setState(
                            () => _isMobileChatSearchOpen = true,
                          ),
                          icon: Icon(
                            Icons.search_rounded,
                            size: 23,
                            color: tg.textPrimary,
                          ),
                        ),
                      ],
                    ),
            )
          else
            Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: tg.searchFill,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: TextField(
                        controller: _chatSearchCtrl,
                        onChanged: (v) => setState(() => _chatFilter = v),
                        style: TextStyle(fontSize: 13, color: tg.textPrimary),
                        decoration: InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          hintText: '搜索',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: tg.textMuted,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 9),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: tg.textMuted,
                          ),
                          suffixIcon: _chatFilter.isNotEmpty
                              ? IconButton(
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: tg.textMuted,
                                  ),
                                  onPressed: () {
                                    _chatSearchCtrl.clear();
                                    setState(() => _chatFilter = '');
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (_chats.any((c) => c.unread > 0))
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: _markAllChatsAsRead,
                      icon: Icon(
                        Icons.done_all_rounded,
                        size: 19,
                        color: tg.tgBlueBright,
                      ),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: _showNotificationSettingsDialog,
                    icon: Icon(
                      (widget.appState.telegramNotifications
                                  .systemNotificationsEnabled ||
                              widget.appState.telegramNotifications
                                  .inAppNotificationsEnabled)
                          ? Icons.notifications_active_outlined
                          : Icons.notifications_off_outlined,
                      size: 19,
                      color: (widget.appState.telegramNotifications
                                  .systemNotificationsEnabled ||
                              widget.appState.telegramNotifications
                                  .inAppNotificationsEnabled)
                          ? tg.tgBlueBright
                          : tg.textMuted,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: _isLoadingChats
                        ? null
                        : () => _loadFoldersAndChats(loadMore: false),
                    icon: _isLoadingChats
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tg.tgBlueBright,
                            ),
                          )
                        : Icon(
                            Icons.refresh_rounded,
                            size: 19,
                            color: tg.textSecondary,
                          ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '收起左侧会话列表',
                    onPressed: () => setState(
                      () => _isDialogsSidebarCollapsed = true,
                    ),
                    icon: Icon(
                      Icons.chevron_left_rounded,
                      size: 20,
                      color: tg.textSecondary,
                    ),
                  ),
                ],
              ),
            ),

          // Mobile horizontal folder tabs (Official Telegram Mobile style)
          if (isMobile && _folders.length > 1)
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: tg.headerBg,
                border: Border(bottom: BorderSide(color: tg.borderLine)),
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                scrollDirection: Axis.horizontal,
                itemCount: _folders.length,
                separatorBuilder: (_, __) => const SizedBox(width: 20),
                itemBuilder: (_, idx) {
                  final f = _folders[idx];
                  final selected = f.key == _selectedFolderKey;
                  return InkWell(
                    onTap: () => _switchFolder(f.key),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: selected
                                ? tg.tgBlueBright
                                : Colors.transparent,
                            width: 3.0,
                          ),
                        ),
                      ),
                      child: Text(
                        f.displayTitle,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? tg.tgBlueBright : tg.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // Dialog rows list
          Expanded(
            child: _isLoadingChats && _chats.isEmpty
                ? Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: tg.tgBlueBright,
                    ),
                  )
                : filteredChats.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的会话',
                          style: TextStyle(
                            color: tg.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        color: tg.tgBlueBright,
                        backgroundColor: tg.sidebarBg,
                        onRefresh: () => _loadFoldersAndChats(loadMore: false),
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (_nextChatCursor.isNotEmpty &&
                                !_isLoadingChats &&
                                notification.metrics.pixels >=
                                    notification.metrics.maxScrollExtent - 100) {
                              _loadFoldersAndChats(loadMore: true);
                            }
                            return false;
                          },
                          child: Focus(
                            key: _chatListContainerKey,
                            canRequestFocus: false,
                            onKeyEvent: _handleChatListKeyEvent,
                            child: ListView.builder(
                              controller: _chatListScrollController,
                              cacheExtent: 350,
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: filteredChats.length +
                                  (_nextChatCursor.isNotEmpty ? 1 : 0),
                              itemBuilder: (_, idx) {
                            if (idx >= filteredChats.length) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: TextButton(
                                  onPressed: _isLoadingChats
                                      ? null
                                      : () =>
                                          _loadFoldersAndChats(loadMore: true),
                                  child: Text(
                                    _isLoadingChats ? '正在加载更多...' : '加载更多会话',
                                    style: TextStyle(color: tg.tgBlueBright),
                                  ),
                                ),
                              );
                            }
                            final chat = filteredChats[idx];
                            final isSelected =
                                !isMobile && _selectedChat?.peer == chat.peer;

                            return Material(
                              color: isSelected
                                  ? tg.sidebarSelected
                                  : Colors.transparent,
                              child: StatefulBuilder(
                                builder: (rowStateCtx, setRowState) {
                                  return GestureDetector(
                                    onSecondaryTapDown: (details) =>
                                        _showDesktopChatRowContextMenu(
                                      tg,
                                      chat,
                                      details.globalPosition,
                                    ),
                                    child: InkWell(
                                      hoverColor: isSelected
                                          ? tg.sidebarSelected
                                          : tg.sidebarHover,
                                      onFocusChange: (_) {
                                        if (rowStateCtx.mounted) {
                                          setRowState(() {});
                                        }
                                      },
                                      onTap: () => _selectChat(chat),
                                      onLongPress: () =>
                                          _showMobileChatRowContextSheet(
                                        tg,
                                        chat,
                                      ),
                                      child: Builder(
                                      builder: (itemCtx) {
                                        final isFocused =
                                            Focus.of(itemCtx).hasPrimaryFocus;
                                        return Container(
                                      height: isMobile ? 72 : 68,
                                      padding: EdgeInsets.symmetric(
                                        horizontal: isMobile ? 12 : 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isFocused && !isSelected
                                            ? tg.tgBlueBright
                                                .withValues(alpha: 0.22)
                                            : null,
                                        border: isFocused
                                            ? Border.all(
                                                color: const Color(0xFFFFE066),
                                                width: 2.0,
                                              )
                                            : (isMobile
                                                ? Border(
                                                    bottom: BorderSide(
                                                      color: tg.borderLine
                                                          .withValues(alpha: 0.45),
                                                      width: 0.6,
                                                    ),
                                                  )
                                                : null),
                                      ),
                                      child: Row(
                                        children: [
                                      _buildPeerAvatar(
                                        chat.peer,
                                        chat.title,
                                        avatar: chat.avatar,
                                        isSelf: chat.self,
                                        size: isMobile ? 52 : 48,
                                        fontSize: isMobile ? 18 : 17,
                                      ),
                                      SizedBox(width: isMobile ? 12 : 11),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          // Top row: Icon + Title + Timestamp
                                          Row(
                                            children: [
                                              if (chat.broadcast ||
                                                  chat.kind.contains('频道'))
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    right: 4,
                                                  ),
                                                  child: Icon(
                                                    Icons.campaign_rounded,
                                                    size: 16,
                                                    color: isSelected
                                                        ? Colors.white
                                                        : tg.textSecondary,
                                                  ),
                                                )
                                              else if (chat.kind.contains('群'))
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    right: 4,
                                                  ),
                                                  child: Icon(
                                                    Icons.groups_rounded,
                                                    size: 15,
                                                    color: isSelected
                                                        ? Colors.white
                                                        : tg.textSecondary,
                                                  ),
                                                ),
                                              Expanded(
                                                child: Row(
                                                  children: [
                                                    Flexible(
                                                      child: Text(
                                                        chat.title,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: isSelected
                                                              ? Colors.white
                                                              : tg.textPrimary,
                                                        ),
                                                      ),
                                                    ),
                                                    if (chat.muted ||
                                                        widget
                                                            .appState
                                                            .telegramNotifications
                                                            .isPeerMuted(
                                                              _activeAccountId,
                                                              chat.peer,
                                                            )) ...[
                                                      const SizedBox(width: 4),
                                                      Icon(
                                                        Icons
                                                            .volume_off_rounded,
                                                        size: 13.5,
                                                        color: isSelected
                                                            ? Colors.white70
                                                            : tg.textMuted,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                _formatDialogTime(chat.date),
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  color: isSelected
                                                      ? Colors.white
                                                          .withValues(alpha: 0.85)
                                                      : tg.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 5),
                                          // Bottom row: Preview / Draft + Unread Pill
                                          Builder(
                                            builder: (_) {
                                              final chatDraft =
                                                  _drafts[_peerReadKey(
                                                    chat.peer,
                                                  )];
                                              final hasDraft =
                                                  chatDraft != null &&
                                                  !chatDraft.isEmpty;
                                              final draftSummary = hasDraft
                                                  ? (chatDraft.text
                                                            .trim()
                                                            .isNotEmpty
                                                        ? chatDraft.text.trim()
                                                        : '[待发附件 ${chatDraft.files.length} 个]')
                                                  : '';
                                              return Row(
                                                children: [
                                                  if (hasDraft) ...[
                                                    Text(
                                                      '草稿: ',
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: isSelected
                                                            ? const Color(
                                                                0xFFFFB4B4,
                                                              )
                                                            : const Color(
                                                                0xFFEB5757,
                                                              ),
                                                      ),
                                                    ),
                                                  ],
                                                  Expanded(
                                                    child: Text(
                                                      hasDraft
                                                          ? draftSummary
                                                          : (chat
                                                                    .preview
                                                                    .isNotEmpty
                                                                ? chat.preview
                                                                : (chat.broadcast
                                                                      ? '频道广播'
                                                                      : chat.kind)),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        color: isSelected
                                                            ? Colors.white
                                                                  .withValues(
                                                                    alpha: 0.85,
                                                                  )
                                                            : tg.textSecondary,
                                                      ),
                                                    ),
                                                  ),
                                                  if (chat.unread > 0) ...[
                                                    const SizedBox(width: 6),
                                                    Builder(
                                                      builder: (_) {
                                                        final isChatMuted =
                                                            chat.muted ||
                                                            widget
                                                                .appState
                                                                .telegramNotifications
                                                                .isPeerMuted(
                                                                  _activeAccountId,
                                                                  chat.peer,
                                                                );
                                                        return Container(
                                                          constraints:
                                                              const BoxConstraints(
                                                                minWidth: 20,
                                                              ),
                                                          height: 20,
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 6,
                                                              ),
                                                          alignment:
                                                              Alignment.center,
                                                          decoration: BoxDecoration(
                                                            color: isSelected
                                                                ? Colors.white
                                                                : (isChatMuted
                                                                      ? tg.textMuted
                                                                      : tg.tgBlueBright),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  10,
                                                                ),
                                                          ),
                                                          child: Text(
                                                            chat.unread > 999
                                                                ? '999+'
                                                                : '${chat.unread}',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: isSelected
                                                                  ? tg.sidebarSelected
                                                                  : Colors
                                                                        .white,
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  ],
),
);
  }

  /// Main Chat Window matching official Telegram Desktop
  Widget _buildConversationPane(_TgPalette tg, {required bool isMobile}) {
    final chat = _selectedChat;
    if (chat == null) {
      return CustomPaint(
        painter: _TelegramWallpaperPainter(isDark: tg.isDark),
        child: Container(
          color: tg.chatWallpaperBg.withValues(alpha: 0.92),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: tg.datePillBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              '选择一个会话开始浏览消息与视频',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    final kw = _messageFilter.trim().toLowerCase();
    final visibleMessages = _messages.where((m) {
      if (!m.hasRenderableContent) return false;
      if (_mediaTypeFilter == 'video' && !(m.attachment?.isVideo ?? false)) {
        return false;
      }
      if (_mediaTypeFilter == 'photo' && !(m.attachment?.isPhoto ?? false)) {
        return false;
      }
      if (_mediaTypeFilter == 'music' && !(m.attachment?.isMusic ?? false)) {
        return false;
      }
      if (_mediaTypeFilter == 'file' &&
          (m.attachment == null ||
              m.attachment!.isVisualMedia ||
              m.attachment!.isMusic)) {
        return false;
      }
      if (_mediaTypeFilter == 'link' && m.links.isEmpty) {
        return false;
      }
      if (kw.isEmpty) return true;
      return m.text.toLowerCase().contains(kw) ||
          m.sender.toLowerCase().contains(kw) ||
          (m.attachment?.displayName.toLowerCase().contains(kw) ?? false) ||
          (m.attachment?.musicTitle.toLowerCase().contains(kw) ?? false) ||
          (m.attachment?.musicPerformer.toLowerCase().contains(kw) ?? false);
    }).toList();

    final videoCount =
        _messages.where((m) => m.attachment?.isVideo ?? false).length;
    final photoCount =
        _messages.where((m) => m.attachment?.isPhoto ?? false).length;
    final musicCount =
        _messages.where((m) => m.attachment?.isMusic ?? false).length;

    return Column(
      children: [
        // 1. Official Telegram Chat Top Header Bar (56px)
        Container(
          key: _conversationHeaderContainerKey,
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: tg.headerBg,
            border: Border(
              bottom: BorderSide(color: tg.borderLine),
            ),
          ),
          child: Row(
            children: [
              if (isMobile)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '返回会话列表',
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    size: 20,
                    color: tg.textSecondary,
                  ),
                  onPressed: _exitCurrentChatOnMobile,
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _isDialogsSidebarCollapsed ? '展开左侧会话列表' : '收起左侧会话列表',
                  icon: Icon(
                    _isDialogsSidebarCollapsed
                        ? Icons.menu_open_rounded
                        : Icons.view_sidebar_outlined,
                    size: 20,
                    color: _isDialogsSidebarCollapsed
                        ? tg.tgBlueBright
                        : tg.textSecondary,
                  ),
                  onPressed: () => setState(
                    () => _isDialogsSidebarCollapsed =
                        !_isDialogsSidebarCollapsed,
                  ),
                ),
              Expanded(
                child: StatefulBuilder(
                  builder: (hdrTitleCtx, setHdrTitleState) {
                    return Focus(
                      onFocusChange: (_) {
                        if (hdrTitleCtx.mounted) setHdrTitleState(() {});
                      },
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            (event.logicalKey == LogicalKeyboardKey.select ||
                                event.logicalKey == LogicalKeyboardKey.enter ||
                                event.logicalKey ==
                                    LogicalKeyboardKey.numpadEnter ||
                                event.logicalKey == LogicalKeyboardKey.space ||
                                event.logicalKey ==
                                    LogicalKeyboardKey.gameButtonA)) {
                          setState(
                            () => _showRightInfoPanel = !_showRightInfoPanel,
                          );
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Builder(
                        builder: (innerHdrCtx) {
                          final isHdrFocused =
                              Focus.of(innerHdrCtx).hasPrimaryFocus;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(
                              () => _showRightInfoPanel = !_showRightInfoPanel,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: isHdrFocused
                                    ? tg.tgBlueBright.withValues(alpha: 0.22)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                border: isHdrFocused
                                    ? Border.all(
                                        color: const Color(0xFFFFE066),
                                        width: 2.0,
                                      )
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  _buildPeerAvatar(
                                    chat.peer,
                                    chat.title,
                                    avatar: chat.avatar,
                                    isSelf: chat.self,
                                    size: 38,
                                    fontSize: 15,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          chat.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: tg.textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          [
                                            if (chat.kind.isNotEmpty)
                                              chat.kind
                                            else if (chat.broadcast)
                                              '频道广播'
                                            else
                                              '会话',
                                            '${_messages.length} 条消息',
                                            if (videoCount > 0)
                                              '$videoCount 个视频',
                                            if (photoCount > 0)
                                              '$photoCount 张图片',
                                            if (musicCount > 0)
                                              '$musicCount 首音乐',
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: tg.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              if (isMobile)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '搜索消息',
                      icon: Icon(
                        Icons.search_rounded,
                        size: 21,
                        color: _showInChatSearch
                            ? tg.tgBlueBright
                            : tg.textSecondary,
                      ),
                      onPressed: () {
                        setState(() {
                          _showInChatSearch = !_showInChatSearch;
                          if (!_showInChatSearch) {
                            _msgSearchCtrl.clear();
                            _messageFilter = '';
                          }
                        });
                      },
                    ),
                    Builder(
                      builder: (_) {
                        final isMuted = chat.muted ||
                            widget.appState.telegramNotifications.isPeerMuted(
                              _activeAccountId,
                              chat.peer,
                            );
                        return PopupMenuButton<String>(
                          color: tg.sidebarBg,
                          tooltip: '更多操作',
                          icon: Icon(
                            Icons.more_vert_rounded,
                            size: 21,
                            color: tg.textSecondary,
                          ),
                          onSelected: (action) async {
                            switch (action) {
                              case 'info':
                                setState(() => _showRightInfoPanel = true);
                                break;
                              case 'mute':
                                await widget.appState.telegramNotifications
                                    .toggleLocalPeerMute(
                                  _activeAccountId,
                                  chat.peer,
                                );
                                if (!mounted) return;
                                final nowMuted = widget
                                    .appState.telegramNotifications
                                    .isPeerMuted(_activeAccountId, chat.peer);
                                setState(() {});
                                _showDownloadHud(
                                  nowMuted
                                      ? '已将「${chat.title}」设为免打扰'
                                      : '已恢复「${chat.title}」的新消息通知',
                                  state: 'success',
                                );
                                break;
                              case 'select':
                                setState(() {
                                  _selectionMode = !_selectionMode;
                                  if (!_selectionMode) {
                                    _selectedMessageIds.clear();
                                  }
                                });
                                break;
                              case 'refresh':
                                _loadMessages(loadOlder: false);
                                break;
                              case 'export_md':
                                _exportCurrentChatHistory(chat, asJson: false);
                                break;
                              case 'export_json':
                                _exportCurrentChatHistory(chat, asJson: true);
                                break;
                              case 'leave_or_delete':
                                await _confirmAndPerformConversationAction(
                                  tg,
                                  chat,
                                );
                                break;
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'info',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    size: 18,
                                    color: tg.tgBlueBright,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '查看会话信息与共享媒体',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'mute',
                              child: Row(
                                children: [
                                  Icon(
                                    isMuted
                                        ? Icons.notifications_active_outlined
                                        : Icons.notifications_off_outlined,
                                    size: 18,
                                    color: isMuted
                                        ? tg.tgBlueBright
                                        : tg.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    isMuted ? '开启新消息通知' : '设为免打扰 (静音)',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'select',
                              child: Row(
                                children: [
                                  Icon(
                                    _selectionMode
                                        ? Icons.close_rounded
                                        : Icons.checklist_rounded,
                                    size: 18,
                                    color: tg.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _selectionMode ? '退出多选模式' : '多选消息 (批量转存/转发)',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'refresh',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.refresh_rounded,
                                    size: 18,
                                    color: tg.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '刷新最新消息',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'export_md',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 18,
                                    color: tg.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '导出聊天记录 (.md)',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'export_json',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.data_object_rounded,
                                    size: 18,
                                    color: tg.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '导出聊天记录 (.json)',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (chat.conversationActionLabel.isNotEmpty) ...[
                              const PopupMenuDivider(),
                              PopupMenuItem(
                                value: 'leave_or_delete',
                                child: Row(
                                  children: [
                                    Icon(
                                      chat.conversationActionType ==
                                              'delete_contact'
                                          ? Icons.person_remove_outlined
                                          : Icons.logout_rounded,
                                      size: 18,
                                      color: const Color(0xFFE54D42),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      chat.conversationActionLabel,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFE54D42),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ],
                )
              else
                Flexible(
                  flex: 0,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Quick media filter pills (All / Videos / Photos / Music / Files) on desktop
                        _buildMediaFilterChip(tg, 'all', '全部'),
                        const SizedBox(width: 4),
                        _buildMediaFilterChip(
                          tg,
                          'video',
                          videoCount > 0 ? '视频 ($videoCount)' : '视频',
                        ),
                        const SizedBox(width: 4),
                        _buildMediaFilterChip(
                          tg,
                          'photo',
                          photoCount > 0 ? '图片 ($photoCount)' : '图片',
                        ),
                        const SizedBox(width: 4),
                        _buildMediaFilterChip(
                          tg,
                          'music',
                          musicCount > 0 ? '音乐 ($musicCount)' : '音乐',
                        ),
                        const SizedBox(width: 4),
                        _buildMediaFilterChip(tg, 'file', '文件'),
                        const SizedBox(width: 6),
                        Builder(
                          builder: (_) {
                            final isMuted = chat.muted ||
                                widget.appState.telegramNotifications
                                    .isPeerMuted(
                                  _activeAccountId,
                                  chat.peer,
                                );
                            return IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                isMuted
                                    ? Icons.notifications_off_outlined
                                    : Icons.notifications_active_outlined,
                                size: 19,
                                color: isMuted ? tg.textMuted : tg.tgBlueBright,
                              ),
                              onPressed: () async {
                                await widget.appState.telegramNotifications
                                    .toggleLocalPeerMute(
                                  _activeAccountId,
                                  chat.peer,
                                );
                                if (!mounted) return;
                                final nowMuted = widget
                                    .appState.telegramNotifications
                                    .isPeerMuted(_activeAccountId, chat.peer);
                                setState(() {});
                                _showDownloadHud(
                                  nowMuted
                                      ? '已将「${chat.title}」设为静默免打扰，不再推送通知'
                                      : '已恢复「${chat.title}」的新消息通知',
                                  state: 'success',
                                );
                              },
                            );
                          },
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            Icons.search_rounded,
                            size: 19,
                            color: _showInChatSearch
                                ? tg.tgBlueBright
                                : tg.textSecondary,
                          ),
                          onPressed: () {
                            setState(() {
                              _showInChatSearch = !_showInChatSearch;
                              if (!_showInChatSearch) {
                                _msgSearchCtrl.clear();
                                _messageFilter = '';
                              }
                            });
                          },
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            _selectionMode
                                ? Icons.check_circle_rounded
                                : Icons.checklist_rounded,
                            size: 19,
                            color: _selectionMode
                                ? tg.tgBlueBright
                                : tg.textSecondary,
                          ),
                          onPressed: () {
                            setState(() {
                              _selectionMode = !_selectionMode;
                              if (!_selectionMode) _selectedMessageIds.clear();
                            });
                          },
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip:
                              _showRightInfoPanel ? '收起会话信息与媒体' : '展开会话信息与媒体',
                          icon: Icon(
                            Icons.view_sidebar_outlined,
                            size: 19,
                            color: _showRightInfoPanel
                                ? tg.tgBlueBright
                                : tg.textSecondary,
                          ),
                          onPressed: () => setState(
                            () => _showRightInfoPanel = !_showRightInfoPanel,
                          ),
                        ),
                        PopupMenuButton<String>(
                          color: tg.sidebarBg,
                          icon: Icon(
                            Icons.file_download_outlined,
                            size: 19,
                            color: tg.textSecondary,
                          ),
                          onSelected: (fmt) {
                            _exportCurrentChatHistory(
                              chat,
                              asJson: fmt == 'json',
                            );
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'md',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 17,
                                    color: tg.tgBlueBright,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '导出为 Markdown (.md)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'json',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.data_object_rounded,
                                    size: 17,
                                    color: tg.textSecondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '导出为 JSON (.json)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        _buildTvFocusableActionChip(
                          icon: Icons.refresh_rounded,
                          label: null,
                          tooltip: '刷新最新消息',
                          textColor: tg.textSecondary,
                          bgColor: tg.searchFill,
                          compact: true,
                          onTap: () => _loadMessages(loadOlder: false),
                        ),
                        if (chat.conversationActionLabel.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          if (!_isHeaderDangerActionExpanded)
                            _buildTvFocusableActionChip(
                              icon: Icons.more_horiz_rounded,
                              label: null,
                              tooltip: '展开${chat.conversationActionLabel}',
                              textColor: tg.textSecondary,
                              bgColor: tg.searchFill,
                              compact: true,
                              onTap: () => setState(
                                () => _isHeaderDangerActionExpanded = true,
                              ),
                            )
                          else ...[
                            _buildTvFocusableActionChip(
                              focusNode: _headerConversationActionFocusNode,
                              icon: chat.conversationActionType ==
                                      'delete_contact'
                                  ? Icons.person_remove_outlined
                                  : Icons.logout_rounded,
                              label: chat.conversationActionLabel,
                              tooltip: chat.conversationActionLabel,
                              textColor: const Color(0xFFFF6B6B),
                              bgColor: const Color(0x28E54D42),
                              compact: true,
                              onTap: () {
                                setState(
                                  () => _isHeaderDangerActionExpanded = false,
                                );
                                _confirmAndPerformConversationAction(tg, chat);
                              },
                            ),
                            const SizedBox(width: 4),
                            _buildTvFocusableActionChip(
                              icon: Icons.chevron_right_rounded,
                              label: null,
                              tooltip: '折叠${chat.conversationActionLabel}',
                              textColor: tg.textSecondary,
                              bgColor: tg.searchFill,
                              compact: true,
                              onTap: () => setState(
                                () => _isHeaderDangerActionExpanded = false,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Mobile horizontally scrollable media filter bar (All / Videos / Photos / Music / Files)
        if (isMobile)
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: tg.headerBg,
              border: Border(bottom: BorderSide(color: tg.borderLine)),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Center(child: _buildMediaFilterChip(tg, 'all', '全部')),
                const SizedBox(width: 6),
                Center(
                  child: _buildMediaFilterChip(
                    tg,
                    'video',
                    videoCount > 0 ? '视频 ($videoCount)' : '视频',
                  ),
                ),
                const SizedBox(width: 6),
                Center(
                  child: _buildMediaFilterChip(
                    tg,
                    'photo',
                    photoCount > 0 ? '图片 ($photoCount)' : '图片',
                  ),
                ),
                const SizedBox(width: 6),
                Center(
                  child: _buildMediaFilterChip(
                    tg,
                    'music',
                    musicCount > 0 ? '音乐 ($musicCount)' : '音乐',
                  ),
                ),
                const SizedBox(width: 6),
                Center(child: _buildMediaFilterChip(tg, 'file', '文件')),
              ],
            ),
          ),

        if (_playingAudioMessage != null && _playingAudioChat != null)
          _buildTopPinnedAudioPlayerBar(tg, isMobile),

        if (_statusIsError && _statusBanner.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.danger.withValues(alpha: 0.14),
              border: Border(bottom: BorderSide(color: tg.borderLine)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 15,
                  color: VideoPlatformTheme.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusBanner,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Optional expandable in-chat search bar
        if (_showInChatSearch)
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: tg.headerBg,
              border: Border(bottom: BorderSide(color: tg.borderLine)),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 17, color: tg.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _msgSearchCtrl,
                    autofocus: true,
                    onChanged: (v) => setState(() => _messageFilter = v),
                    style: TextStyle(fontSize: 13, color: tg.textPrimary),
                    decoration: InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: '搜索此会话中的消息内容、歌曲名称、艺术家或文件名...',
                      hintStyle: TextStyle(fontSize: 12.5, color: tg.textMuted),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (_messageFilter.isNotEmpty)
                  Text(
                    '匹配 ${visibleMessages.length} 条',
                    style: TextStyle(fontSize: 11.5, color: tg.textSecondary),
                  ),
                IconButton(
                  icon: Icon(Icons.close_rounded, size: 16, color: tg.textMuted),
                  onPressed: () {
                    _msgSearchCtrl.clear();
                    setState(() {
                      _messageFilter = '';
                      _showInChatSearch = false;
                    });
                  },
                ),
              ],
            ),
          ),

        // 2. Official Telegram Message Canvas with Wallpaper
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: tg.chatWallpaperBg,
                  child: CustomPaint(
                    painter: _TelegramWallpaperPainter(isDark: tg.isDark),
                  ),
                ),
              ),
              if (_isLoadingMessages && _messages.isEmpty)
                Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: tg.tgBlueBright,
                  ),
                )
              else if (visibleMessages.isEmpty)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: tg.datePillBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text(
                      '暂无消息记录',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                )
              else
                Builder(
                  builder: (context) {
                    // Group messages sharing a non-empty `groupedId`:
                    // - Visual media (`isVisualMedia`) into Album Grids
                    // - Music / Audio / Documents into Unified Music/File Group Bubbles (Official Telegram style)
                    final groupedEntries = <List<TelegramMessage>>[];
                    final gidToGroup = <String, List<TelegramMessage>>{};
                    for (final m in visibleMessages) {
                      final gid = m.groupedId.trim();
                      final att = m.attachment;
                      if (gid.isNotEmpty && gid != '0' && att != null) {
                        final kindKey =
                            att.isVisualMedia ? 'visual:$gid' : 'doc:$gid';
                        final existing = gidToGroup[kindKey];
                        if (existing != null) {
                          existing.add(m);
                        } else {
                          final group = <TelegramMessage>[m];
                          gidToGroup[kindKey] = group;
                          groupedEntries.add(group);
                        }
                      } else {
                        groupedEntries.add([m]);
                      }
                    }

                    return Focus(
                      key: _messageListContainerKey,
                      canRequestFocus: false,
                      onKeyEvent: _handleMessageListKeyEvent,
                      child: Listener(
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent &&
                              event.scrollDelta.dy < 0) {
                            if (!_messageScrollController.hasClients ||
                                _messageScrollController.position.pixels >=
                                    _messageScrollController
                                            .position.maxScrollExtent -
                                        120) {
                              _tryLoadOlderMessagesOnScroll();
                            }
                          }
                        },
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ListView.builder(
                            controller: _messageScrollController,
                            reverse: true,
                            shrinkWrap: groupedEntries.length <= 8 &&
                                _nextMessageOffset <= 0,
                            cacheExtent: 400,
                            padding: EdgeInsets.symmetric(
                              horizontal: isMobile ? 8 : 18,
                              vertical: isMobile ? 10 : 14,
                            ),
                            itemCount: groupedEntries.length +
                                (_nextMessageOffset > 0 ? 1 : 0),
                            itemBuilder: (context, idx) {
                              if (_nextMessageOffset > 0 &&
                                  idx == groupedEntries.length) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 14),
                                  child: Center(
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: _isLoadingMessages
                                          ? null
                                          : () => _loadMessages(loadOlder: true),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: tg.datePillBg,
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_isLoadingMessages)
                                              const SizedBox(
                                                width: 12,
                                                height: 12,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 1.8,
                                                  color: Colors.white,
                                                ),
                                              )
                                            else
                                              const Icon(
                                                Icons.history_rounded,
                                                size: 15,
                                                color: Colors.white,
                                              ),
                                            const SizedBox(width: 6),
                                            Text(
                                              _isLoadingMessages
                                                  ? '正在加载更早的消息...'
                                                  : '向上滚动滚轮或点击加载更早消息',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }

                              final entryIdx =
                                  groupedEntries.length - 1 - idx;
                              final entry = groupedEntries[entryIdx];
                              final msg = entry.first;
                              final prevMsg = entryIdx > 0
                                  ? groupedEntries[entryIdx - 1].first
                                  : null;
                              final curDateLabel = _formatDatePill(msg.date);
                              final prevDateLabel = prevMsg != null
                                  ? _formatDatePill(prevMsg.date)
                                  : '';
                              final showDateHeader = curDateLabel.isNotEmpty &&
                                  curDateLabel != prevDateLabel;

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (showDateHeader)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: tg.datePillBg,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            curDateLabel,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: entry.length > 1
                                        ? ((msg.attachment?.isVisualMedia ??
                                                false)
                                            ? _buildTelegramAlbumBubble(
                                                tg,
                                                chat,
                                                entry,
                                              )
                                            : _buildTelegramMusicOrFileGroupBubble(
                                                tg,
                                                chat,
                                                entry,
                                              ))
                                        : _buildTelegramMessageBubble(
                                            tg,
                                            chat,
                                            msg,
                                          ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),

              // Floating scroll-to-bottom button (exact Telegram Desktop style)
              if (_showScrollToBottomBtn)
                Positioned(
                  right: 18,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    backgroundColor: tg.headerBg,
                    foregroundColor: tg.textSecondary,
                    elevation: 4,
                    onPressed: () => _scrollToBottom(animated: true),
                    child: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
                  ),
                ),

              // Animated top floating HUD banner for download/save status feedback
              Positioned(
                top: 12,
                left: 24,
                right: 24,
                child: IgnorePointer(
                  ignoring: _downloadHudText.isEmpty,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween<double>(begin: 0.92, end: 1.0)
                              .animate(anim),
                          child: child,
                        ),
                      ),
                      child: _downloadHudText.isEmpty
                          ? const SizedBox.shrink()
                          : Container(
                              key: ValueKey(
                                '$_downloadHudState:$_downloadHudText',
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: _downloadHudState == 'error'
                                    ? const Color(0xEB3A1D22)
                                    : (_downloadHudState == 'success'
                                        ? const Color(0xEB1B3326)
                                        : const Color(0xEB17212B)),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _downloadHudState == 'error'
                                      ? const Color(0x80FF6B6B)
                                      : (_downloadHudState == 'success'
                                          ? const Color(0x804ECC5E)
                                          : const Color(0x4D5EB5F7)),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x40000000),
                                    blurRadius: 10,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_downloadHudState == 'loading')
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF5EB5F7),
                                      ),
                                    )
                                  else
                                    Icon(
                                      _downloadHudState == 'error'
                                          ? Icons.error_outline_rounded
                                          : Icons.check_circle_rounded,
                                      size: 16,
                                      color: _downloadHudState == 'error'
                                          ? const Color(0xFFFF6B6B)
                                          : const Color(0xFF4ECC5E),
                                    ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _downloadHudText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),

              // 5. Drag-and-Drop File Sending Overlay (Desktop / macOS)
              if (_isDraggingFilesOverChat)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _isDraggingFilesOverChat = false),
                    child: Container(
                      margin: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: tg.isDark
                            ? const Color(0xDA0E1621)
                            : const Color(0xE6F4F9FF),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: chat.readOnly
                              ? const Color(0xFFE54D42)
                              : tg.tgBlueBright,
                          width: 2.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x55000000),
                            blurRadius: 24,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: (chat.readOnly
                                      ? const Color(0xFFE54D42)
                                      : tg.tgBlueBright)
                                  .withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              chat.readOnly
                                  ? Icons.block_rounded
                                  : Icons.cloud_upload_rounded,
                              size: 38,
                              color: chat.readOnly
                                  ? const Color(0xFFE54D42)
                                  : tg.tgBlueBright,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            chat.readOnly
                                ? '当前频道「${chat.title}」为只读，无法拖拽发送文件'
                                : '释放鼠标以发送文件至「${chat.title}」',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: tg.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            chat.readOnly
                                ? '请切换到私聊、群组或收藏夹 (Saved Messages) 会话'
                                : '支持图片、视频、音频及任意文档 (单文件最高 2GB · 可选无损原文件或压缩媒体)',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: tg.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // 3. Official Telegram Bottom Compose Bar / Selection Toolbar / Broadcast Footer
        _buildBottomBar(tg, chat),
      ],
    );
  }

  Widget _buildTvFocusableActionChip({
    FocusNode? focusNode,
    bool autofocus = false,
    FocusNode? leftFocusNode,
    FocusNode? rightFocusNode,
    FocusNode? upFocusNode,
    FocusNode? downFocusNode,
    required IconData icon,
    required String? label,
    String? tooltip,
    required Color textColor,
    required Color bgColor,
    bool compact = false,
    required VoidCallback? onTap,
  }) {
    return StatefulBuilder(
      builder: (btnCtx, setBtnState) {
        return Focus(
          focusNode: focusNode,
          autofocus: autofocus,
          onFocusChange: (hasFocus) {
            if (btnCtx.mounted) setBtnState(() {});
            if (hasFocus) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (btnCtx.mounted) {
                  Scrollable.ensureVisible(
                    btnCtx,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 140),
                  );
                }
              });
            }
          },
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA) {
              if (onTap != null) onTap();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                leftFocusNode != null) {
              leftFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                rightFocusNode != null) {
              rightFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                upFocusNode != null) {
              upFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                downFocusNode != null) {
              downFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (innerCtx) {
              final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
              final child = GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? (label != null ? 9 : 7) : 13,
                    vertical: compact ? 5 : 8,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? (bgColor == const Color(0xFFE54D42) ||
                                bgColor == const Color(0x28E54D42) ||
                                bgColor == const Color(0x22E54D42)
                            ? const Color(0xFFE54D42)
                            : const Color(0xFF3E99EE))
                        : bgColor,
                    borderRadius: BorderRadius.circular(compact ? 14 : 10),
                    border: Border.all(
                      color: isFocused
                          ? const Color(0xFFFFE066)
                          : Colors.white12,
                      width: isFocused ? 2.2 : 1.0,
                    ),
                    boxShadow: isFocused
                        ? const [
                            BoxShadow(
                              color: Color(0x80FFE066),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: compact ? 15 : 16,
                        color: isFocused ? Colors.white : textColor,
                      ),
                      if (label != null && label.isNotEmpty) ...[
                        const SizedBox(width: 5),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: compact ? 11.5 : 13,
                            fontWeight:
                                isFocused ? FontWeight.w700 : FontWeight.w600,
                            color: isFocused ? Colors.white : textColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
              return tooltip != null && tooltip.isNotEmpty
                  ? Tooltip(message: tooltip, child: child)
                  : child;
            },
          ),
        );
      },
    );
  }

  Widget _buildMediaFilterChip(_TgPalette tg, String key, String label) {
    final active = _mediaTypeFilter == key;
    return StatefulBuilder(
      builder: (chipCtx, setChipState) {
        return Focus(
          onFocusChange: (hasFocus) {
            if (chipCtx.mounted) setChipState(() {});
            if (hasFocus) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (chipCtx.mounted) {
                  Scrollable.ensureVisible(
                    chipCtx,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 140),
                  );
                }
              });
            }
          },
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                    event.logicalKey == LogicalKeyboardKey.space ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
              setState(() => _mediaTypeFilter = key);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (innerCtx) {
              final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
              return GestureDetector(
                onTap: () => setState(() => _mediaTypeFilter = key),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? tg.tgBlueBright
                        : (active
                            ? tg.tgBlueBright.withValues(alpha: 0.18)
                            : tg.searchFill),
                    borderRadius: BorderRadius.circular(14),
                    border: isFocused
                        ? Border.all(
                            color: const Color(0xFFFFE066),
                            width: 2.0,
                          )
                        : null,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: (active || isFocused)
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: isFocused
                          ? Colors.white
                          : (active ? tg.tgBlueBright : tg.textSecondary),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// Official Telegram Album Mosaic Grid Bubble for messages sharing `groupedId`
  Widget _buildTelegramAlbumBubble(
    _TgPalette tg,
    TelegramChat chat,
    List<TelegramMessage> albumMessages,
  ) {
    final first = albumMessages.first;
    final isOutgoing = first.outgoing && !chat.broadcast;
    final senderName = first.sender.isNotEmpty ? first.sender : chat.title;
    final senderColor = _TgPalette.peerNameColor(senderName);
    final timeStr = _formatBubbleTime(first.date);
    final captionMsg = albumMessages.firstWhere(
      (m) => m.text.trim().isNotEmpty,
      orElse: () => first,
    );
    final cols = albumMessages.length == 2 || albumMessages.length == 4 ? 2 : 3;
    final videoCount =
        albumMessages.where((m) => m.attachment?.isVideo ?? false).length;
    final photoCount = albumMessages.length - videoCount;
    final albumBadgeLabel = videoCount > 0 && photoCount > 0
        ? '相册 ${albumMessages.length} 项 ($photoCount图 · $videoCount视频)'
        : (videoCount > 0
            ? '视频组 ${albumMessages.length} 项'
            : '相册 ${albumMessages.length} 项');

    final bubbleContent = Container(
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 480),
      decoration: BoxDecoration(
        color: isOutgoing ? tg.bubbleOut : tg.bubbleIn,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(isOutgoing ? 14 : 4),
          bottomRight: Radius.circular(isOutgoing ? 4 : 14),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                if (!isOutgoing)
                  Expanded(
                    child: Text(
                      senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: senderColor,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: tg.tgBlueBright.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    albumBadgeLabel,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: tg.tgBlueBright,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: GridView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
                childAspectRatio: cols == 2 ? 1.15 : 1.0,
              ),
              itemCount: albumMessages.length,
              itemBuilder: (_, idx) {
                final m = albumMessages[idx];
                final att = m.attachment;
                final downloadKey = '$_activeAccountId:${att?.url ?? ''}';
                final isQueueing = att != null &&
                    att.url.isNotEmpty &&
                    _pendingDownloads.contains(downloadKey);
                final isQueued = att != null &&
                    att.url.isNotEmpty &&
                    _isUrlQueuedOrInTasks(att.url);
                final isFailed = att != null &&
                    att.url.isNotEmpty &&
                    _failedDownloads.contains(downloadKey);
                final isSavingLocal = _pendingLocalSaves.contains(m.id);
                final tileSavedPath = _getSavedLocalPath(chat, m);
                final isSavedLocal =
                    _completedLocalSaves.contains(m.id) ||
                    tileSavedPath != null;
                final isSelected = _selectedMessageIds.contains(m.id);

                return _TelegramAlbumMediaTile(
                  key: ValueKey('album_tile_${chat.peer}_${m.id}'),
                  inlinePlaybackOwner: _inlinePlaybackOwner,
                  appState: widget.appState,
                  accountId: _activeAccountId,
                  chat: chat,
                  message: m,
                  tg: tg,
                  selectionMode: _selectionMode,
                  isSelected: isSelected,
                  isQueueing: isQueueing,
                  isQueued: isQueued,
                  isFailed: isFailed,
                  isSavingLocal: isSavingLocal,
                  isSavedLocal: isSavedLocal,
                  durationText: att != null && att.isVideo
                      ? _formatDurationClock(att.duration)
                      : '',
                  onToggleSelect: () {
                    setState(() {
                      if (isSelected) {
                        _selectedMessageIds.remove(m.id);
                      } else {
                        _selectedMessageIds.add(m.id);
                      }
                    });
                  },
                  onOpenGallery: () {
                    _markChatAsRead(
                      chat,
                      latestMessageDate: m.date,
                      maxMessageId: m.id,
                    );
                    _openMediaGalleryViewer(
                      chat,
                      m,
                      albumMessages: albumMessages,
                    );
                  },
                  onOpenMiniPlayer: (posSec) => _openVideoInMiniPlayer(
                    chat,
                    m,
                    initialPositionSeconds: posSec,
                  ),
                  onSaveLocal: () {
                    if (tileSavedPath != null) {
                      _openLocalFileDirectory(tileSavedPath);
                    } else {
                      _saveAttachmentToLocalDownloads(chat, m);
                    }
                  },
                  onQueueDownload: att != null && att.url.isNotEmpty
                      ? () => _queueTelegramDownload(
                            url: att.url,
                            name: att.displayName,
                          )
                      : null,
                  onShowContextMenu: (pos) =>
                      _showMessageContextMenu(tg, chat, m, pos),
                );
              },
            ),
          ),
          for (final m in albumMessages)
            if (_getSavedLocalPath(chat, m) != null)
              _buildLocalFilePathBanner(tg, _getSavedLocalPath(chat, m)!),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (captionMsg.text.trim().isNotEmpty) ...[
                  _buildInteractiveMessageText(
                    tg,
                    chat,
                    captionMsg,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                  const SizedBox(height: 4),
                ],
                Row(
                  children: [
                    InkWell(
                      onTap: () => _openMediaGalleryViewer(
                        chat,
                        albumMessages.first,
                        albumMessages: albumMessages,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.collections_rounded,
                            size: 13,
                            color: tg.tgBlueBright,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '浏览相册 (${albumMessages.length})',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: tg.tgBlueBright,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Builder(
                      builder: (_) {
                        final downloadableItems = albumMessages
                            .where(
                              (m) =>
                                  m.attachment != null &&
                                  m.attachment!.url.isNotEmpty,
                            )
                            .toList();
                        final anyPending = downloadableItems.any(
                          (m) => _pendingDownloads.contains(
                            '$_activeAccountId:${m.attachment!.url}',
                          ),
                        );
                        final allQueued = downloadableItems.isNotEmpty &&
                            downloadableItems.every(
                              (m) => _isUrlQueuedOrInTasks(m.attachment!.url),
                            );
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: anyPending
                              ? null
                              : () async {
                                  int okCount = 0;
                                  for (final m in downloadableItems) {
                                    final a = m.attachment!;
                                    final ok = await _queueTelegramDownload(
                                      url: a.url,
                                      name: a.displayName,
                                      showToast: false,
                                    );
                                    if (ok) okCount++;
                                  }
                                  if (mounted) {
                                    _showDownloadHud(
                                      okCount > 0
                                          ? '已将整组相册 ($okCount 项) 加入下载队列'
                                          : '整组相册添加下载失败',
                                      state: okCount > 0 ? 'success' : 'error',
                                    );
                                  }
                                },
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Row(
                              key: ValueKey(
                                'album_batch_${anyPending}_$allQueued',
                              ),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (anyPending)
                                  SizedBox(
                                    width: 11,
                                    height: 11,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.8,
                                      color: tg.tgBlueBright,
                                    ),
                                  )
                                else
                                  Icon(
                                    allQueued
                                        ? Icons.check_circle_rounded
                                        : Icons.cloud_download_outlined,
                                    size: 13,
                                    color: allQueued
                                        ? const Color(0xFF2EBE70)
                                        : tg.tgBlueBright,
                                  ),
                                const SizedBox(width: 4),
                                Text(
                                  anyPending
                                      ? '正在转存...'
                                      : (allQueued
                                          ? '已整组入队 (${albumMessages.length})'
                                          : '整组转存 (${albumMessages.length})'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: allQueued
                                        ? const Color(0xFF2EBE70)
                                        : tg.tgBlueBright,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const Spacer(),
                    if (captionMsg.text.trim().isNotEmpty)
                      InkWell(
                        onTap: () {
                          Clipboard.setData(
                            ClipboardData(text: captionMsg.text),
                          );
                          _showDownloadHud('已复制消息文本', state: 'success');
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: Text(
                            '复制',
                            style: TextStyle(fontSize: 11, color: tg.textMuted),
                          ),
                        ),
                      ),
                    InkWell(
                      onTap: () => _showForwardMessagesDialog(albumMessages),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '转发相册',
                          style: TextStyle(fontSize: 11, color: tg.textMuted),
                        ),
                      ),
                    ),
                    Text(
                      timeStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: isOutgoing
                            ? (tg.isDark
                                ? const Color(0xFF8AB4DF)
                                : const Color(0xFF5FA853))
                            : tg.textMuted,
                      ),
                    ),
                    if (isOutgoing) ...[
                      const SizedBox(width: 4),
                      _buildOutgoingReadReceipt(
                        tg,
                        chat,
                        isRead: _isOutgoingAlbumRead(chat, albumMessages),
                        groupMessages: albumMessages,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          for (final item in albumMessages)
            if (item.hasButtons) _buildTelegramInlineKeyboard(tg, chat, item),
        ],
      ),
    );

    final showLeftSenderAvatar = !isOutgoing &&
        (!_isMobileLayout ||
            (!chat.broadcast &&
                !chat.peer.startsWith('user:') &&
                !chat.self));

    return Row(
      mainAxisAlignment:
          isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showLeftSenderAvatar) ...[
          _buildPeerAvatar(
            chat.broadcast ||
                    senderName == chat.title ||
                    chat.peer.startsWith('user:')
                ? chat.peer
                : senderName,
            senderName,
            avatar: first.senderAvatar.isNotEmpty
                ? first.senderAvatar
                : (chat.broadcast ||
                          senderName == chat.title ||
                          chat.peer.startsWith('user:')
                      ? chat.avatar
                      : null),
            isSelf: chat.self,
            size: 34,
            fontSize: 13,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(child: bubbleContent),
      ],
    );
  }

  /// Official Telegram Top Pinned Music & Audio Player Bar (below chat header)
  Widget _buildTopPinnedAudioPlayerBar(_TgPalette tg, bool isMobile) {
    final msg = _playingAudioMessage;
    final chat = _playingAudioChat;
    final att = msg?.attachment;
    if (msg == null || chat == null || att == null) {
      return const SizedBox.shrink();
    }

    final totalMs =
        _audioDuration.inMilliseconds > 0 ? _audioDuration.inMilliseconds : 1;
    final progress = (_audioPosition.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final isMusic = att.isMusic;
    final title = isMusic ? att.musicTitle : '语音消息';
    final subtitle = isMusic ? att.musicPerformer : chat.title;
    final playlistCount = _playingAudioPlaylist.length;

    final modeIcon = switch (_audioPlayMode) {
      'repeatAll' => Icons.repeat_rounded,
      'repeatOne' => Icons.repeat_one_rounded,
      'shuffle' => Icons.shuffle_rounded,
      _ => Icons.playlist_play_rounded,
    };

    return Container(
      key: ValueKey('tg_top_pinned_audio_${msg.id}'),
      decoration: BoxDecoration(
        color: tg.headerBg,
        border: Border(bottom: BorderSide(color: tg.borderLine)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                if (isMusic)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.skip_previous_rounded,
                      size: 20,
                      color: tg.tgBlueBright,
                    ),
                    onPressed: () => _playAdjacentAudioTrack(-1),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: _isAudioLoading
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: tg.tgBlueBright,
                          ),
                        )
                      : Icon(
                          _isAudioPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                          color: tg.tgBlueBright,
                        ),
                  onPressed: () => _togglePlayAudioMessage(
                    chat,
                    msg,
                    forceRestart: _audioErrorText.isNotEmpty,
                  ),
                ),
                if (isMusic)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.skip_next_rounded,
                      size: 20,
                      color: tg.tgBlueBright,
                    ),
                    onPressed: () => _playAdjacentAudioTrack(1),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: _jumpToPlayingAudioMessage,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: tg.textPrimary,
                                  ),
                                ),
                              ),
                              if (subtitle.isNotEmpty) ...[
                                Text(
                                  ' — ',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: tg.textMuted,
                                  ),
                                ),
                                Flexible(
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: tg.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _audioErrorText.isNotEmpty
                                ? _audioErrorText
                                : '${_formatDurationClock(_audioPosition.inSeconds)} / ${_formatDurationClock(_audioDuration.inSeconds)}${_playingAudioChat?.peer != _selectedChat?.peer ? " · 来自 ${chat.title}" : ""}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: _audioErrorText.isNotEmpty
                                  ? VideoPlatformTheme.danger
                                  : tg.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (isMusic && !isMobile)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      modeIcon,
                      size: 18,
                      color: _audioPlayMode == 'sequential'
                          ? tg.textSecondary
                          : tg.tgBlueBright,
                    ),
                    onPressed: _cycleAudioPlayMode,
                  ),
                if (_audioPlayer != null) ...[
                  VideoDownloadSpeedBadge(
                    player: _audioPlayer!,
                    compact: true,
                  ),
                  const SizedBox(width: 4),
                  PlayerVolumeControl(
                    player: _audioPlayer!,
                    compact: true,
                    sliderWidth: isMobile ? 44 : 64,
                    showPercentage: !isMobile,
                  ),
                  const SizedBox(width: 2),
                ],
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _cycleAudioSpeed,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: tg.tgBlueBright.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${_audioSpeed}x',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: tg.tgBlueBright,
                      ),
                    ),
                  ),
                ),
                if (isMusic && playlistCount > 0)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.queue_music_rounded,
                      size: 19,
                      color: tg.textSecondary,
                    ),
                    onPressed: () => _showAudioPlaylistModal(tg),
                  ),
                if (!isMobile)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.download_rounded,
                      size: 18,
                      color: tg.textSecondary,
                    ),
                    onPressed: () => _saveAttachmentToLocalDownloads(chat, msg),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: tg.textMuted,
                  ),
                  onPressed: _stopAndCloseAudioPlayer,
                ),
              ],
            ),
          ),
          // Interactive slim progress scrubber along the bottom edge of the top player bar
          LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (_audioDuration > Duration.zero &&
                      constraints.maxWidth > 0) {
                    final ratio =
                        (details.localPosition.dx / constraints.maxWidth)
                            .clamp(0.0, 1.0);
                    _seekAudioTrack(
                      Duration(
                        milliseconds:
                            (_audioDuration.inMilliseconds * ratio).round(),
                      ),
                    );
                  }
                },
                onHorizontalDragUpdate: (details) {
                  if (_audioDuration > Duration.zero &&
                      constraints.maxWidth > 0) {
                    final ratio =
                        (details.localPosition.dx / constraints.maxWidth)
                            .clamp(0.0, 1.0);
                    _seekAudioTrack(
                      Duration(
                        milliseconds:
                            (_audioDuration.inMilliseconds * ratio).round(),
                      ),
                    );
                  }
                },
                child: SizedBox(
                  height: 6,
                  width: double.infinity,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(
                      value: _isAudioLoading ? null : progress,
                      minHeight: 2.5,
                      color: tg.tgBlueBright,
                      backgroundColor: tg.borderLine,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Official Telegram Music Playlist Modal Dialog
  Future<void> _showAudioPlaylistModal(_TgPalette tg) async {
    final chat = _playingAudioChat ?? _selectedChat;
    final current = _playingAudioMessage;
    if (chat == null) return;
    final playlist = current != null
        ? _resolveAudioPlaylistFor(chat, current)
        : _messages
            .where((m) => m.attachment?.isMusic ?? false)
            .toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final modeLabel = switch (_audioPlayMode) {
              'repeatAll' => '列表循环',
              'repeatOne' => '单曲循环',
              'shuffle' => '随机播放',
              _ => '顺序连播',
            };
            return Dialog(
              backgroundColor: tg.sidebarBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 460,
                  maxHeight: 540,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
                      child: Row(
                        children: [
                          Icon(
                            Icons.queue_music_rounded,
                            color: tg.tgBlueBright,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '音乐播放列表 (${playlist.length})',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: tg.textPrimary,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              _cycleAudioPlayMode();
                              setModalState(() {});
                            },
                            icon: Icon(
                              Icons.repeat_rounded,
                              size: 15,
                              color: tg.tgBlueBright,
                            ),
                            label: Text(
                              modeLabel,
                              style: TextStyle(
                                fontSize: 12,
                                color: tg.tgBlueBright,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: tg.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: tg.borderLine),
                    Expanded(
                      child: playlist.isEmpty
                          ? Center(
                              child: Text(
                                '当前会话暂无音乐曲目',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: tg.textMuted,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              itemCount: playlist.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 4),
                              itemBuilder: (_, idx) {
                                final item = playlist[idx];
                                final a = item.attachment!;
                                final active = _isAudioTrackActive(chat, item);
                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  tileColor: active
                                      ? tg.tgBlueBright.withValues(alpha: 0.14)
                                      : Colors.transparent,
                                  leading: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: tg.tgBlueBright,
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      active && _isAudioPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  title: Text(
                                    a.musicTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: active
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: active
                                          ? tg.tgBlueBright
                                          : tg.textPrimary,
                                    ),
                                  ),
                                  subtitle: Text(
                                    [
                                      a.musicPerformer,
                                      if (a.duration > 0)
                                        _formatDurationClock(a.duration),
                                      if (a.formattedSize.isNotEmpty)
                                        a.formattedSize,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: tg.textSecondary,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    icon: Icon(
                                      Icons.download_rounded,
                                      size: 18,
                                      color: tg.textSecondary,
                                    ),
                                    onPressed: () =>
                                        _saveAttachmentToLocalDownloads(
                                          chat,
                                          item,
                                        ),
                                  ),
                                  onTap: () async {
                                    await _togglePlayAudioMessage(chat, item);
                                    setModalState(() {});
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Official Telegram Grouped Music / File Bubble (multiple tracks or documents sharing `groupedId`)
  Widget _buildTelegramMusicOrFileGroupBubble(
    _TgPalette tg,
    TelegramChat chat,
    List<TelegramMessage> groupMessages,
  ) {
    final first = groupMessages.first;
    final last = groupMessages.last;
    final isOutgoing = first.outgoing && !chat.broadcast;
    final senderName = first.sender.isNotEmpty ? first.sender : chat.title;
    final senderColor = _TgPalette.peerNameColor(senderName);
    final timeStr = _formatBubbleTime(last.date);
    final captionMsg = groupMessages.firstWhere(
      (m) => m.text.trim().isNotEmpty,
      orElse: () => first,
    );
    final allMusic =
        groupMessages.every((m) => m.attachment?.isMusic ?? false);

    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomLeft: Radius.circular(isOutgoing ? 14 : 4),
      bottomRight: Radius.circular(isOutgoing ? 4 : 14),
    );

    final bubbleContent = Container(
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 460),
      decoration: BoxDecoration(
        color: isOutgoing ? tg.bubbleOut : tg.bubbleIn,
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isOutgoing)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: senderColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    allMusic
                        ? '音乐合集 (${groupMessages.length} 首)'
                        : '文件组 (${groupMessages.length} 项)',
                    style: TextStyle(fontSize: 10.5, color: tg.textMuted),
                  ),
                ],
              ),
            ),
          if (first.replyToId > 0)
            _buildReplyQuoteBanner(tg, chat, first.replyToId),
          for (var i = 0; i < groupMessages.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 66,
                endIndent: 12,
                color: tg.borderLine.withValues(alpha: 0.55),
              ),
            if (groupMessages[i].attachment != null)
              _buildTelegramBubbleAttachment(
                tg,
                chat,
                groupMessages[i],
                groupMessages[i].attachment!,
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (captionMsg.text.trim().isNotEmpty) ...[
                  _buildInteractiveMessageText(
                    tg,
                    chat,
                    captionMsg,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                  const SizedBox(height: 4),
                ],
                Row(
                  children: [
                    if (allMusic)
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _togglePlayAudioMessage(
                          chat,
                          first,
                          forceRestart: true,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.playlist_play_rounded,
                                size: 15,
                                color: tg.tgBlueBright,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '连播全部 (${groupMessages.length})',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: tg.tgBlueBright,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const Spacer(),
                    InkWell(
                      onTap: () => _showForwardMessagesDialog(groupMessages),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '转发',
                          style: TextStyle(fontSize: 11, color: tg.textMuted),
                        ),
                      ),
                    ),
                    Text(
                      timeStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: isOutgoing
                            ? (tg.isDark
                                ? const Color(0xFF8AB4DF)
                                : const Color(0xFF5FA853))
                            : tg.textMuted,
                      ),
                    ),
                    if (isOutgoing) ...[
                      const SizedBox(width: 4),
                      _buildOutgoingReadReceipt(
                        tg,
                        chat,
                        isRead: _isOutgoingAlbumRead(chat, groupMessages),
                        groupMessages: groupMessages,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          for (final item in groupMessages)
            if (item.hasButtons) _buildTelegramInlineKeyboard(tg, chat, item),
        ],
      ),
    );

    final showLeftSenderAvatar = !isOutgoing &&
        (!_isMobileLayout ||
            (!chat.broadcast &&
                !chat.peer.startsWith('user:') &&
                !chat.self));

    return Row(
      mainAxisAlignment:
          isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showLeftSenderAvatar) ...[
          _buildPeerAvatar(
            chat.broadcast ||
                    senderName == chat.title ||
                    chat.peer.startsWith('user:')
                ? chat.peer
                : senderName,
            senderName,
            avatar: first.senderAvatar.isNotEmpty
                ? first.senderAvatar
                : (chat.broadcast ||
                          senderName == chat.title ||
                          chat.peer.startsWith('user:')
                      ? chat.avatar
                      : null),
            isSelf: chat.self,
            size: 34,
            fontSize: 13,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(child: bubbleContent),
      ],
    );
  }

  /// Authentic Telegram Message Bubble (Left for incoming/channel, Right for outgoing)
  Widget _buildTelegramMessageBubble(
    _TgPalette tg,
    TelegramChat chat,
    TelegramMessage msg,
  ) {
    final isOutgoing = msg.outgoing && !chat.broadcast;
    final isSelected = _selectedMessageIds.contains(msg.id);
    final att = msg.attachment;
    final senderName = msg.sender.isNotEmpty ? msg.sender : chat.title;
    final senderColor = _TgPalette.peerNameColor(senderName);
    final timeStr = _formatBubbleTime(msg.date);

    final bubbleColor = isSelected
        ? tg.bubbleSelected
        : (isOutgoing ? tg.bubbleOut : tg.bubbleIn);

    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomLeft: Radius.circular(isOutgoing ? 14 : 4),
      bottomRight: Radius.circular(isOutgoing ? 4 : 14),
    );

    Widget innerColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Sender header (for incoming group/channel messages)
        if (!isOutgoing)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    senderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: senderColor,
                    ),
                  ),
                ),
                if (chat.broadcast) ...[
                  const SizedBox(width: 6),
                  Text(
                    '频道',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: tg.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),

        // Optional reply quote header when this message replies to another message
        if (msg.replyToId > 0)
          _buildReplyQuoteBanner(tg, chat, msg.replyToId),

        // Media attachment (Video / Photo / Document)
        if (att != null) _buildTelegramBubbleAttachment(tg, chat, msg, att),

        // Message text + bottom-right floated timestamp & read status
        Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            msg.text.isNotEmpty ? 6 : 2,
            12,
            7,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg.text.isNotEmpty) ...[
                if (att == null)
                  StatefulBuilder(
                    builder: (textFocusCtx, setTextFocusState) {
                      return Focus(
                        onFocusChange: (_) {
                          if (textFocusCtx.mounted) {
                            setTextFocusState(() {});
                          }
                        },
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              (event.logicalKey ==
                                      LogicalKeyboardKey.select ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.enter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.gameButtonA)) {
                            _markChatAsRead(
                              chat,
                              latestMessageDate: msg.date,
                              maxMessageId: msg.id,
                            );
                            if (_selectionMode) {
                              setState(() {
                                if (isSelected) {
                                  _selectedMessageIds.remove(msg.id);
                                } else {
                                  _selectedMessageIds.add(msg.id);
                                }
                              });
                            } else {
                              final box = textFocusCtx.findRenderObject()
                                  as RenderBox?;
                              final pos = box != null && box.hasSize
                                  ? box.localToGlobal(
                                      box.size.center(Offset.zero),
                                    )
                                  : const Offset(400, 300);
                              _showMessageContextMenu(tg, chat, msg, pos);
                            }
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Builder(
                          builder: (innerCtx) {
                            final hasFocus =
                                Focus.of(innerCtx).hasPrimaryFocus;
                            final trimmed = msg.text.trim();
                            final isGiantEmoji =
                                trimmed.characters.length <= 2 &&
                                trimmed.runes.any((r) => r > 0x1F000);
                            return Container(
                              padding: hasFocus
                                  ? const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    )
                                  : EdgeInsets.zero,
                              decoration: hasFocus
                                  ? BoxDecoration(
                                      color: tg.tgBlueBright
                                          .withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFFFFE066),
                                        width: 1.8,
                                      ),
                                    )
                                  : null,
                              child: _buildInteractiveMessageText(
                                tg,
                                chat,
                                msg,
                                fontSize: isGiantEmoji ? 36 : 13.5,
                                height: isGiantEmoji ? 1.15 : 1.42,
                              ),
                            );
                          },
                        ),
                      );
                    },
                  )
                else
                  _buildInteractiveMessageText(
                    tg,
                    chat,
                    msg,
                    fontSize: 13.5,
                    height: 1.42,
                  ),
                const SizedBox(height: 3),
              ],
              Align(
                alignment: Alignment.centerRight,
                widthFactor: 1.0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!chat.readOnly)
                      InkWell(
                        onTap: () {
                          setState(() => _replyingToMessage = msg);
                          _saveCurrentDraft();
                          _composeFocusNode.requestFocus();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '回复',
                            style: TextStyle(
                              fontSize: 11,
                              color: tg.textMuted,
                            ),
                          ),
                        ),
                      ),
                    if (msg.text.trim().isNotEmpty)
                      InkWell(
                        onTap: () {
                          final selectedText = _activeSelectedBubbleText.trim();
                          final textToCopy = selectedText.isNotEmpty
                              ? selectedText
                              : msg.text;
                          Clipboard.setData(ClipboardData(text: textToCopy));
                          _showDownloadHud(
                            selectedText.isNotEmpty
                                ? '已复制选中内容'
                                : '已复制消息文本',
                            state: 'success',
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '复制',
                            style: TextStyle(
                              fontSize: 11,
                              color: tg.textMuted,
                            ),
                          ),
                        ),
                      ),
                    InkWell(
                      onTap: () => _showForwardMessagesDialog([msg]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '转发',
                          style: TextStyle(
                            fontSize: 11,
                            color: tg.textMuted,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      timeStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: isOutgoing
                            ? (tg.isDark
                                ? const Color(0xFF8AB4DF)
                                : const Color(0xFF5FA853))
                            : tg.textMuted,
                      ),
                    ),
                    if (isOutgoing) ...[
                      const SizedBox(width: 4),
                      _buildOutgoingReadReceipt(
                        tg,
                        chat,
                        isRead: _isOutgoingMessageRead(chat, msg),
                        message: msg,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        // Extracted links inside message
        if (msg.links.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: msg.links.map((url) {
                final isTg = _isTelegramLink(url);
                return InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => isTg
                      ? _openOrResolveLink(url)
                      : _queueTelegramDownload(
                          url: url,
                          name: 'TG_${msg.id}',
                        ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tg.tgBlueBright.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isTg
                              ? Icons.open_in_new_rounded
                              : Icons.add_to_queue_rounded,
                          size: 13,
                          color: tg.tgBlueBright,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          url.length > 34
                              ? '${url.substring(0, 34)}...'
                              : url,
                          style: TextStyle(
                            fontSize: 11,
                            color: tg.tgBlueBright,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

        // Interactive selection / inline keyboard buttons
        if (msg.hasButtons) _buildTelegramInlineKeyboard(tg, chat, msg),
      ],
    );

    if (att == null && !msg.hasButtons) {
      innerColumn = IntrinsicWidth(child: innerColumn);
    }

    Widget bubbleContent = Container(
      constraints: const BoxConstraints(minWidth: 110, maxWidth: 500),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: innerColumn,
    );

    return GestureDetector(
      onTap: () {
        _markChatAsRead(
          chat,
          latestMessageDate: msg.date,
          maxMessageId: msg.id,
        );
        if (_selectionMode) {
          setState(() {
            if (isSelected) {
              _selectedMessageIds.remove(msg.id);
            } else {
              _selectedMessageIds.add(msg.id);
            }
          });
        }
      },
      onSecondaryTapDown: (details) =>
          _showMessageContextMenu(tg, chat, msg, details.globalPosition),
      onLongPressStart: (details) =>
          _showMessageContextMenu(tg, chat, msg, details.globalPosition),
      child: Row(
        mainAxisAlignment:
            isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_selectionMode)
            Padding(
              padding: const EdgeInsets.only(right: 10, bottom: 8),
              child: Icon(
                isSelected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: isSelected ? tg.tgBlueBright : Colors.white70,
              ),
            ),
          if (!isOutgoing &&
              (!_isMobileLayout ||
                  (!chat.broadcast &&
                      !chat.peer.startsWith('user:') &&
                      !chat.self))) ...[
            _buildPeerAvatar(
              chat.broadcast ||
                      senderName == chat.title ||
                      chat.peer.startsWith('user:')
                  ? chat.peer
                  : senderName,
              senderName,
              avatar: msg.senderAvatar.isNotEmpty
                  ? msg.senderAvatar
                  : (chat.broadcast ||
                            senderName == chat.title ||
                            chat.peer.startsWith('user:')
                        ? chat.avatar
                        : null),
              isSelf: chat.self,
              size: 34,
              fontSize: 13,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubbleContent),
        ],
      ),
    );
  }

  /// Interactive selectable message text inside a Telegram bubble supporting
  /// partial mouse/touch selection, Cmd+C copy, and a rich text context menu.
  Widget _buildInteractiveMessageText(
    _TgPalette tg,
    TelegramChat chat,
    TelegramMessage msg, {
    required double fontSize,
    required double height,
  }) {
    return SelectableText(
      msg.text,
      style: TextStyle(
        fontSize: fontSize,
        height: height,
        color: tg.textPrimary,
      ),
      onSelectionChanged: (selection, cause) {
        if (!selection.isValid || selection.isCollapsed) {
          _activeSelectedBubbleText = '';
          return;
        }
        final start = selection.start.clamp(0, msg.text.length);
        final end = selection.end.clamp(0, msg.text.length);
        if (end > start) {
          _activeSelectedBubbleText = msg.text.substring(start, end);
        } else {
          _activeSelectedBubbleText = '';
        }
      },
      contextMenuBuilder: (ctx, editableTextState) {
        final val = editableTextState.textEditingValue;
        final sel = val.selection;
        final hasSelection =
            sel.isValid && !sel.isCollapsed && sel.end > sel.start;
        final selectedSubstr = hasSelection
            ? val.text.substring(
                sel.start.clamp(0, val.text.length),
                sel.end.clamp(0, val.text.length),
              )
            : '';

        final buttonItems = <ContextMenuButtonItem>[
          if (hasSelection)
            ContextMenuButtonItem(
              label: '复制选中文字',
              onPressed: () {
                editableTextState.copySelection(SelectionChangedCause.toolbar);
                ContextMenuController.removeAny();
                _showDownloadHud('已复制选中文字', state: 'success');
              },
            ),
          ContextMenuButtonItem(
            label: '复制整条消息',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: msg.text));
              ContextMenuController.removeAny();
              _showDownloadHud('已复制整条消息文本', state: 'success');
            },
          ),
          ContextMenuButtonItem(
            label: '全选文字',
            onPressed: () {
              editableTextState.selectAll(SelectionChangedCause.toolbar);
            },
          ),
          if (!chat.readOnly)
            ContextMenuButtonItem(
              label: hasSelection ? '引用选中内容回复' : '回复此消息',
              onPressed: () {
                ContextMenuController.removeAny();
                setState(() => _replyingToMessage = msg);
                if (hasSelection && selectedSubstr.trim().isNotEmpty) {
                  final existing = _composeController.text;
                  final quoteLine = '> ${selectedSubstr.trim()}\n';
                  if (!existing.startsWith(quoteLine)) {
                    _composeController.text = '$quoteLine$existing';
                    _composeController.selection = TextSelection.fromPosition(
                      TextPosition(offset: _composeController.text.length),
                    );
                  }
                }
                _saveCurrentDraft();
                _composeFocusNode.requestFocus();
              },
            ),
          if (!chat.readOnly)
            ContextMenuButtonItem(
              label: '填入输入框编辑',
              onPressed: () {
                ContextMenuController.removeAny();
                final textToInsert =
                    hasSelection && selectedSubstr.trim().isNotEmpty
                        ? selectedSubstr
                        : msg.text;
                _composeController.text = textToInsert;
                _composeController.selection = TextSelection.fromPosition(
                  TextPosition(offset: _composeController.text.length),
                );
                _saveCurrentDraft();
                _composeFocusNode.requestFocus();
              },
            ),
          ContextMenuButtonItem(
            label: '转发消息...',
            onPressed: () {
              ContextMenuController.removeAny();
              _showForwardMessagesDialog([msg]);
            },
          ),
          ContextMenuButtonItem(
            label: '保存到收藏夹',
            onPressed: () {
              ContextMenuController.removeAny();
              _saveMessageToSavedMessages(msg);
            },
          ),
        ];

        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editableTextState.contextMenuAnchors,
          buttonItems: buttonItems,
        );
      },
    );
  }

  /// Outgoing message / file read receipt badge (`发送中...` / `发送失败·重试` / `已读` double check / `已发送` single check)
  Widget _buildOutgoingReadReceipt(
    _TgPalette tg,
    TelegramChat chat, {
    required bool isRead,
    TelegramMessage? message,
    List<TelegramMessage>? groupMessages,
  }) {
    final targetIds = groupMessages != null && groupMessages.isNotEmpty
        ? groupMessages.map((m) => m.id).toList()
        : (message != null ? <int>[message.id] : const <int>[]);

    final isSending = targetIds.any(_sendingOptimisticMsgIds.contains);
    if (isSending) {
      int? uploadPct;
      for (final id in targetIds) {
        final pct = _optimisticUploadPercent[id];
        if (pct != null && pct > 0) {
          uploadPct = pct;
          break;
        }
      }
      final sendingColor =
          tg.isDark ? const Color(0xFF8AB4DF) : const Color(0xFF5FA853);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule_rounded,
            size: 13,
            color: sendingColor,
          ),
          const SizedBox(width: 3),
          Text(
            uploadPct != null ? '发送中 $uploadPct%' : '发送中...',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: sendingColor,
            ),
          ),
        ],
      );
    }

    int? failedId;
    for (final id in targetIds) {
      if (_failedOptimisticMsgs.containsKey(id)) {
        failedId = id;
        break;
      }
    }
    if (failedId != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _retryFailedOptimisticMessage(failedId!),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 13.5,
                color: Color(0xFFFF6B6B),
              ),
              SizedBox(width: 3),
              Text(
                '发送失败 · 点击重试',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFF6B6B),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final activeColor = isRead
        ? (tg.isDark ? const Color(0xFF64B5F6) : const Color(0xFF2E9B47))
        : (tg.isDark ? const Color(0xFF8AB4DF) : const Color(0xFF5FA853));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isRead ? Icons.done_all_rounded : Icons.done_rounded,
          size: 14,
          color: activeColor,
        ),
        const SizedBox(width: 2),
        Text(
          isRead ? '已读' : '已发送',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: isRead ? FontWeight.w600 : FontWeight.w400,
            color: activeColor,
          ),
        ),
      ],
    );
  }

  /// Reply quote banner inside a Telegram message bubble
  Widget _buildReplyQuoteBanner(
    _TgPalette tg,
    TelegramChat chat,
    int replyToId,
  ) {
    final original = _messages.cast<TelegramMessage?>().firstWhere(
          (m) => m != null && m.id == replyToId,
          orElse: () => null,
        );
    final quoteSender = (original != null && original.sender.isNotEmpty)
        ? original.sender
        : (original != null && original.outgoing ? '我' : '消息 #$replyToId');
    final quoteText = original != null
        ? (original.text.trim().isNotEmpty
            ? original.text.trim()
            : (original.attachment?.displayName ?? '媒体消息'))
        : '原消息 #$replyToId';

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: tg.tgBlueBright.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: tg.tgBlueBright, width: 2.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '回复 $quoteSender',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: tg.tgBlueBright,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            quoteText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: tg.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _buttonActionStateKey(TelegramChat chat, TelegramMessage msg) =>
      '$_activeAccountId|${chat.peer}|${msg.id}';

  /// Interactive selection / inline keyboard buttons rendered under a Telegram message
  Widget _buildTelegramInlineKeyboard(
    _TgPalette tg,
    TelegramChat chat,
    TelegramMessage msg,
  ) {
    final stateKey = _buttonActionStateKey(chat, msg);
    final state =
        _buttonActionStates.putIfAbsent(stateKey, _TelegramButtonActionState.new);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < msg.buttons.length; r++) ...[
            if (r > 0) const SizedBox(height: 5),
            Row(
              children: [
                for (var c = 0; c < msg.buttons[r].length; c++) ...[
                  if (c > 0) const SizedBox(width: 5),
                  Expanded(
                    child: _buildTelegramChoiceButton(
                      tg,
                      chat,
                      msg,
                      state,
                      r,
                      c,
                      msg.buttons[r][c],
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (state.notice.isNotEmpty || state.answerUrl.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              key: ValueKey('tg_btn_notice_${msg.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: state.isAlert
                    ? const Color(0xFFFF6B6B).withValues(alpha: 0.14)
                    : tg.tgBlueBright.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: state.isAlert
                      ? const Color(0xFFFF6B6B).withValues(alpha: 0.35)
                      : tg.tgBlueBright.withValues(alpha: 0.30),
                ),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.busy) ...[
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.7,
                            color: tg.tgBlueBright,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ] else ...[
                        Icon(
                          state.isAlert
                              ? Icons.info_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 13,
                          color: state.isAlert
                              ? const Color(0xFFFF6B6B)
                              : tg.tgBlueBright,
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          state.notice,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: state.isAlert
                                ? (tg.isDark
                                    ? const Color(0xFFFF9E9E)
                                    : const Color(0xFFC92A2A))
                                : tg.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (state.answerUrl.isNotEmpty)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _openButtonUrl(state.answerUrl),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.open_in_new_rounded,
                              size: 12,
                              color: tg.tgBlueBright,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '打开机器人返回的链接',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: tg.tgBlueBright,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTelegramChoiceButton(
    _TgPalette tg,
    TelegramChat chat,
    TelegramMessage msg,
    _TelegramButtonActionState state,
    int row,
    int column,
    TelegramMessageButton btn,
  ) {
    final btnKey = '$row/$column';
    final isThisBusy = state.busy && state.activeButtonKey == btnKey;
    final disabled = state.busy ||
        !btn.isSupported ||
        (btn.kind == 'text' && chat.readOnly);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('tg_choice_btn_${msg.id}_${row}_$column'),
        borderRadius: BorderRadius.circular(8),
        onTap: disabled
            ? null
            : () => _handleTelegramMessageButtonTap(
                  chat,
                  msg,
                  row,
                  column,
                  btn,
                ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: disabled
                ? tg.searchFill.withValues(alpha: 0.45)
                : tg.tgBlueBright.withValues(alpha: tg.isDark ? 0.18 : 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: disabled
                  ? tg.borderLine.withValues(alpha: 0.5)
                  : tg.tgBlueBright.withValues(alpha: 0.38),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isThisBusy) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: tg.tgBlueBright,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  btn.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: disabled ? tg.textMuted : tg.textPrimary,
                  ),
                ),
              ),
              if (btn.isUrl) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.open_in_new_rounded,
                  size: 12,
                  color: tg.tgBlueBright,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openButtonUrl(String rawUrl) async {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return;
    if (_isTelegramLink(trimmed)) {
      await _openOrResolveLink(trimmed);
      return;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null &&
        (uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'tg')) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        if (mounted) {
          _showDownloadHud('无法打开链接：$trimmed', state: 'error');
        }
      }
    }
  }

  bool _sameInlineButtons(
    List<List<TelegramMessageButton>> a,
    List<List<TelegramMessageButton>> b,
  ) {
    if (a.length != b.length) return false;
    for (int r = 0; r < a.length; r++) {
      if (a[r].length != b[r].length) return false;
      for (int c = 0; c < a[r].length; c++) {
        if (a[r][c].text != b[r][c].text ||
            a[r][c].token != b[r][c].token ||
            a[r][c].url != b[r][c].url) {
          return false;
        }
      }
    }
    return true;
  }

  void _scheduleBotReplySyncs({
    required String accountId,
    required String peer,
    required int clickedMessageId,
    required String initialText,
    required List<List<TelegramMessageButton>> initialButtons,
    required int initialLastMessageId,
    required _TelegramButtonActionState state,
  }) {
    for (final delayMs in const [900, 2200, 4200, 7000]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () async {
        if (!mounted ||
            _activeAccountId != accountId ||
            _selectedChat?.peer != peer) {
          return;
        }
        await _loadMessages(loadOlder: false, silent: true);
        if (!mounted ||
            _activeAccountId != accountId ||
            _selectedChat?.peer != peer) {
          return;
        }
        final currentLastId = _messages.isNotEmpty ? _messages.last.id : 0;
        final clickedIdx =
            _messages.indexWhere((m) => m.id == clickedMessageId);
        final clickedUpdated = clickedIdx >= 0 &&
            (_messages[clickedIdx].text != initialText ||
                !_sameInlineButtons(
                  _messages[clickedIdx].buttons,
                  initialButtons,
                ));
        if (state.busy &&
            (currentLastId > initialLastMessageId || clickedUpdated)) {
          // Bot has already replied with a new message or updated the inline keyboard!
          // Release button spinner immediately without waiting for MTProto callback timeout.
          setState(() {
            state.busy = false;
            state.activeButtonKey = null;
            if (!state.isAlert && state.answerUrl.isEmpty) {
              state.notice = '';
            }
          });
        }
      });
    }
  }

  Future<void> _handleTelegramMessageButtonTap(
    TelegramChat chat,
    TelegramMessage msg,
    int row,
    int column,
    TelegramMessageButton btn,
  ) async {
    if (btn.isUrl) {
      await _openButtonUrl(btn.url);
      return;
    }
    if (!btn.isInteractive) return;
    if (btn.kind == 'text' && chat.readOnly) return;

    final stateKey = _buttonActionStateKey(chat, msg);
    final state =
        _buttonActionStates.putIfAbsent(stateKey, _TelegramButtonActionState.new);
    if (state.busy) return;

    final attemptKey = '$row/$column/${btn.token}';
    final randomId = state.attemptIds.putIfAbsent(
      attemptKey,
      () => widget.appState.api.generateTelegramRandomId(),
    );
    final accountId = _activeAccountId;
    final peer = chat.peer;
    final initialLastId = _messages.isNotEmpty ? _messages.last.id : 0;

    setState(() {
      state.busy = true;
      state.activeButtonKey = '$row/$column';
      state.notice = '';
      state.isAlert = false;
      state.answerUrl = '';
    });

    // Proactively poll for bot's new message or keyboard edit while callback RPC is in flight
    _scheduleBotReplySyncs(
      accountId: accountId,
      peer: peer,
      clickedMessageId: msg.id,
      initialText: msg.text,
      initialButtons: msg.buttons,
      initialLastMessageId: initialLastId,
      state: state,
    );

    try {
      final result = await widget.appState.api.pressTelegramMessageButton(
        accountId: accountId,
        peer: peer,
        messageId: msg.id,
        row: row,
        column: column,
        token: btn.token,
        randomId: randomId,
      );
      state.attemptIds.remove(attemptKey);
      if (!mounted ||
          _activeAccountId != accountId ||
          _selectedChat?.peer != peer) {
        return;
      }

      setState(() {
        state.notice = result.notice;
        state.isAlert = result.alert;
        state.answerUrl = result.url;
        if (result.message != null && result.message!.id > 0) {
          final updated = result.message!;
          final idx = _messages.indexWhere((m) => m.id == updated.id);
          if (idx >= 0) {
            final prev = _messages[idx];
            _messages[idx] = updated.sender.isEmpty && prev.sender.isNotEmpty
                ? updated.copyWith(sender: prev.sender)
                : updated;
          } else {
            _messages.add(updated);
            _messages.sort((a, b) => a.id.compareTo(b.id));
          }
        }
      });
      _saveCurrentChatToMemoryCache();
      if (result.notice.isNotEmpty) {
        _showDownloadHud(result.notice, state: 'success');
        if (!result.alert && result.url.isEmpty) {
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (mounted && state.notice == result.notice) {
              setState(() => state.notice = '');
            }
          });
        }
      }
      // Refresh messages and chats so any new bot reply or keyboard update appears immediately
      unawaited(_loadMessages(loadOlder: false, silent: true));
      unawaited(_loadFoldersAndChats(loadMore: false, silent: true));
    } catch (e) {
      if (!mounted ||
          _activeAccountId != accountId ||
          _selectedChat?.peer != peer) {
        return;
      }
      final errText = e.toString();
      if (errText.toUpperCase().contains('BOT_RESPONSE_TIMEOUT') ||
          errText.toUpperCase().contains('QUERY_ID_INVALID')) {
        state.attemptIds.remove(attemptKey);
        setState(() {
          state.notice = '';
          state.isAlert = false;
        });
        unawaited(_loadMessages(loadOlder: false, silent: true));
        unawaited(_loadFoldersAndChats(loadMore: false, silent: true));
      } else {
        setState(() {
          state.notice = '操作未确认：$e';
          state.isAlert = true;
        });
      }
    } finally {
      state.busy = false;
      state.activeButtonKey = null;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Widget _buildLocalFilePathBanner(_TgPalette tg, String savedPath) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openLocalFileDirectory(savedPath),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF2EBE70).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFF2EBE70).withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.folder_open_rounded,
                size: 14,
                color: Color(0xFF2EBE70),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  savedPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: tg.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '打开目录',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: tg.tgBlueBright,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Edge-to-edge Video / Photo / File card inside a Telegram message bubble
  Widget _buildTelegramBubbleAttachment(
    _TgPalette tg,
    TelegramChat chat,
    TelegramMessage msg,
    TelegramAttachment att,
  ) {
    final isVideo = att.isVideo;
    final isPhoto = att.isPhoto;
    final thumbUrl = widget.appState.api.buildTelegramThumbnailUrl(
      accountId: _activeAccountId,
      peer: chat.peer,
      messageId: msg.id,
    );
    final downloadKey = '$_activeAccountId:${att.url}';
    final isQueueing = _pendingDownloads.contains(downloadKey);
    final isQueued = _isUrlQueuedOrInTasks(att.url);
    final isFailed = _failedDownloads.contains(downloadKey);
    final savedLocalPath = _getSavedLocalPath(chat, msg);
    final isSavingLocal = _pendingLocalSaves.contains(msg.id);
    final isSavedLocal =
        _completedLocalSaves.contains(msg.id) || savedLocalPath != null;
    final isFailedLocal = _failedLocalSaves.contains(msg.id);
    final optimisticBytes = _optimisticPreviewBytesByMsgId[msg.id];

    if (isVideo || isPhoto) {
      return StatefulBuilder(
        builder: (attStateCtx, setAttState) {
          void refreshAttFocus(bool _) {
            if (attStateCtx.mounted) setAttState(() {});
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: isVideo ? 320 : 240,
                margin: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A1017),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (optimisticBytes != null &&
                        optimisticBytes.isNotEmpty &&
                        isPhoto)
                      Image.memory(
                        optimisticBytes,
                        fit: BoxFit.cover,
                      )
                    else if (isPhoto ||
                        att.hasThumbnail ||
                        att.thumbnail.isNotEmpty)
                      Image.network(
                        thumbUrl,
                        headers: widget.appState.api.authHeaders,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => isVideo
                            ? _TelegramVideoFrameFallback(
                                streamUrl: widget.appState.api
                                    .buildTelegramVideoStreamUrl(
                                  accountId: _activeAccountId,
                                  peer: chat.peer,
                                  messageId: msg.id,
                                ),
                                headers: widget.appState.api.authHeaders,
                                fallbackIconColor: tg.textMuted,
                              )
                            : Container(
                                color: const Color(0xFF101923),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.image_outlined,
                                  size: 46,
                                  color: tg.textMuted,
                                ),
                              ),
                      )
                    else
                      _TelegramVideoFrameFallback(
                        streamUrl:
                            widget.appState.api.buildTelegramVideoStreamUrl(
                          accountId: _activeAccountId,
                          peer: chat.peer,
                          messageId: msg.id,
                        ),
                        headers: widget.appState.api.authHeaders,
                        fallbackIconColor: tg.textMuted,
                      ),
                    // Top-left official Telegram duration + size pill
                    if (isVideo)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xA6000000),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            [
                              _formatDurationClock(att.duration),
                              if (att.formattedSize.isNotEmpty)
                                att.formattedSize,
                            ].join(' · '),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    // Disjoint sibling leaf Focus for main media preview area
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      bottom: 34,
                      child: Focus(
                        onFocusChange: refreshAttFocus,
                        onKeyEvent: (node, event) {
                          if (!node.hasPrimaryFocus) {
                            return KeyEventResult.ignored;
                          }
                          if (event is KeyDownEvent &&
                              (event.logicalKey == LogicalKeyboardKey.select ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.enter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.numpadEnter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.space ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.gameButtonA)) {
                            _openMediaGalleryViewer(chat, msg);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Builder(
                          builder: (mediaCtx) {
                            final isMediaFocused =
                                Focus.of(mediaCtx).hasPrimaryFocus;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _openMediaGalleryViewer(chat, msg),
                              child: Container(
                                decoration: isMediaFocused
                                    ? BoxDecoration(
                                        borderRadius:
                                            const BorderRadius.vertical(
                                          top: Radius.circular(10),
                                        ),
                                        border: Border.all(
                                          color: const Color(0xFFFFE066),
                                          width: 2.6,
                                        ),
                                      )
                                    : null,
                                alignment: Alignment.center,
                                child: isVideo
                                    ? Container(
                                        width: isMediaFocused ? 60 : 54,
                                        height: isMediaFocused ? 60 : 54,
                                        decoration: BoxDecoration(
                                          color: isMediaFocused
                                              ? tg.tgBlueBright
                                              : const Color(0x99000000),
                                          shape: BoxShape.circle,
                                          border: isMediaFocused
                                              ? Border.all(
                                                  color:
                                                      const Color(0xFFFFE066),
                                                  width: 2.2,
                                                )
                                              : null,
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 34,
                                        ),
                                      )
                                    : const SizedBox.expand(),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    // Bottom filename + quick action bar overlay (sibling of media Focus)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(10, 12, 8, 6),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Color(0xCC000000),
                              Color(0x00000000),
                            ],
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _openMediaGalleryViewer(chat, msg),
                                child: Text(
                                  att.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            if (isVideo)
                              InkWell(
                                onFocusChange: refreshAttFocus,
                                onTap: () => _openVideoInMiniPlayer(chat, msg),
                                child: Builder(
                                  builder: (pipCtx) {
                                    final isPipFocused =
                                        Focus.of(pipCtx).hasPrimaryFocus;
                                    return Container(
                                      margin: const EdgeInsets.only(right: 6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isPipFocused
                                            ? tg.tgBlueBright
                                            : const Color(0x99000000),
                                        borderRadius: BorderRadius.circular(10),
                                        border: isPipFocused
                                            ? Border.all(
                                                color: const Color(0xFFFFE066),
                                                width: 1.8,
                                              )
                                            : null,
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons
                                                .picture_in_picture_alt_rounded,
                                            size: 12,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 3),
                                          Text(
                                            '小窗',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 10.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            if (!_isOptimisticMsgId(msg.id))
                              InkWell(
                                onFocusChange: refreshAttFocus,
                                onTap: isSavingLocal
                                    ? null
                                    : () {
                                        if (savedLocalPath != null) {
                                          _openLocalFileDirectory(
                                            savedLocalPath,
                                          );
                                        } else {
                                          _saveAttachmentToLocalDownloads(
                                            chat,
                                            msg,
                                          );
                                        }
                                      },
                                child: Builder(
                                  builder: (saveCtx) {
                                    final isSaveFocused =
                                        Focus.of(saveCtx).hasPrimaryFocus;
                                    return Container(
                                      margin: const EdgeInsets.only(right: 6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSavedLocal
                                            ? const Color(0xCC2EBE70)
                                            : (isFailedLocal
                                                ? const Color(0xCCE54D42)
                                                : (isSaveFocused
                                                    ? tg.tgBlueBright
                                                    : const Color(0x99000000))),
                                        borderRadius: BorderRadius.circular(10),
                                        border: isSaveFocused
                                            ? Border.all(
                                                color: const Color(0xFFFFE066),
                                                width: 1.8,
                                              )
                                            : null,
                                      ),
                                      child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 200),
                                        transitionBuilder: (child, anim) =>
                                            ScaleTransition(
                                          scale: anim,
                                          child: child,
                                        ),
                                        child: Row(
                                          key: ValueKey(
                                            'local_${msg.id}_${isSavingLocal}_${isSavedLocal}_$isFailedLocal',
                                          ),
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (isSavingLocal)
                                              const SizedBox(
                                                width: 11,
                                                height: 11,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 1.8,
                                                  color: Colors.white,
                                                ),
                                              )
                                            else
                                              Icon(
                                                isSavedLocal
                                                    ? Icons.folder_open_rounded
                                                    : (isFailedLocal
                                                        ? Icons
                                                            .error_outline_rounded
                                                        : Icons
                                                            .download_rounded),
                                                size: 12,
                                                color: Colors.white,
                                              ),
                                            const SizedBox(width: 3),
                                            Text(
                                              isSavingLocal
                                                  ? '保存中...'
                                                  : (isSavedLocal
                                                      ? '打开目录'
                                                      : (isFailedLocal
                                                          ? '重试保存'
                                                          : '保存本机')),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            if (att.url.isNotEmpty)
                              InkWell(
                                onFocusChange: refreshAttFocus,
                                onTap: isQueueing
                                    ? null
                                    : () => _queueTelegramDownload(
                                          url: att.url,
                                          name: att.displayName,
                                        ),
                                child: Builder(
                                  builder: (qCtx) {
                                    final isQueueFocused =
                                        Focus.of(qCtx).hasPrimaryFocus;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isQueued
                                            ? const Color(0xE62EBE70)
                                            : (isFailed
                                                ? const Color(0xE6E54D42)
                                                : tg.tgBlueBright),
                                        borderRadius: BorderRadius.circular(10),
                                        border: isQueueFocused
                                            ? Border.all(
                                                color: const Color(0xFFFFE066),
                                                width: 1.8,
                                              )
                                            : null,
                                      ),
                                      child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 200),
                                        transitionBuilder: (child, anim) =>
                                            ScaleTransition(
                                          scale: anim,
                                          child: child,
                                        ),
                                        child: Row(
                                          key: ValueKey(
                                            'queue_${msg.id}_${isQueueing}_${isQueued}_$isFailed',
                                          ),
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (isQueueing)
                                              const SizedBox(
                                                width: 11,
                                                height: 11,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 1.8,
                                                  color: Colors.white,
                                                ),
                                              )
                                            else
                                              Icon(
                                                isQueued
                                                    ? Icons.check_circle_rounded
                                                    : (isFailed
                                                        ? Icons
                                                            .error_outline_rounded
                                                        : Icons
                                                            .cloud_download_outlined),
                                                size: 13,
                                                color: Colors.white,
                                              ),
                                            const SizedBox(width: 4),
                                            Text(
                                              isQueueing
                                                  ? '添加中...'
                                                  : (isQueued
                                                      ? '已入队 ✓'
                                                      : (isFailed
                                                          ? '失败·重试'
                                                          : '转存下载')),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
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
                      ),
                    ),
                  ],
                ),
              ),
              if (savedLocalPath != null)
                _buildLocalFilePathBanner(tg, savedLocalPath),
            ],
          );
        },
      );
    }

    // Official Telegram Inline Music / Voice Message Player inside bubble
    if (att.isAudio) {
      final isActive = _isAudioTrackActive(chat, msg);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _TelegramInlineAudioPlayer(
            appState: widget.appState,
            accountId: _activeAccountId,
            chat: chat,
            message: msg,
            attachment: att,
            tg: tg,
            isActive: isActive,
            isPlaying: isActive && _isAudioPlaying,
            isLoading: isActive && _isAudioLoading,
            errorText: isActive ? _audioErrorText : '',
            position: isActive ? _audioPosition : Duration.zero,
            duration: isActive && _audioDuration > Duration.zero
                ? _audioDuration
                : Duration(seconds: att.duration),
            speed: _audioSpeed,
            onTogglePlay: () => _togglePlayAudioMessage(
              chat,
              msg,
              forceRestart: isActive && _audioErrorText.isNotEmpty,
            ),
            onSeek: (target) {
              if (isActive) {
                _seekAudioTrack(target);
              }
            },
            onCycleSpeed: _cycleAudioSpeed,
            isQueued: isQueued,
            onQueueDownload: att.url.isEmpty
                ? null
                : () => _queueTelegramDownload(
                      url: att.url,
                      name: att.displayName,
                    ),
            onSaveLocal: () {
              if (savedLocalPath != null) {
                _openLocalFileDirectory(savedLocalPath);
              } else {
                _saveAttachmentToLocalDownloads(chat, msg);
              }
            },
          ),
          if (savedLocalPath != null)
            _buildLocalFilePathBanner(tg, savedLocalPath),
        ],
      );
    }

    // Official Telegram File / Document Card inside bubble
    final canPreview = _canPreviewTelegramFile(att);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              StatefulBuilder(
                builder: (fileStateCtx, setFileState) {
                  return InkWell(
                    customBorder: const CircleBorder(),
                    onFocusChange: (_) {
                      if (fileStateCtx.mounted) setFileState(() {});
                    },
                    onTap: () {
                      if (savedLocalPath != null) {
                        _openLocalFileDirectory(savedLocalPath);
                      } else if (canPreview) {
                        _openFilePreviewDialog(chat, msg);
                      } else if (!_isOptimisticMsgId(msg.id)) {
                        _saveAttachmentToLocalDownloads(chat, msg);
                      }
                    },
                    child: Builder(
                      builder: (fileCtx) {
                        final isFileFocused = Focus.of(fileCtx).hasPrimaryFocus;
                        return Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: isSavedLocal
                                ? const Color(0xFF2EBE70)
                                : tg.tgBlueBright,
                            shape: BoxShape.circle,
                            border: isFileFocused
                                ? Border.all(
                                    color: const Color(0xFFFFE066),
                                    width: 2.2,
                                  )
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            isSavedLocal
                                ? Icons.folder_open_rounded
                                : (isQueued
                                    ? Icons.check_rounded
                                    : Icons.insert_drive_file_rounded),
                            color: Colors.white,
                            size: 22,
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      att.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tg.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (att.formattedSize.isNotEmpty) att.formattedSize,
                        att.kind.toUpperCase(),
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: tg.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (canPreview && !_isOptimisticMsgId(msg.id))
                IconButton(
                  tooltip: '在线预览文件内容',
                  onPressed: () => _openFilePreviewDialog(chat, msg),
                  icon: Icon(
                    Icons.visibility_outlined,
                    size: 19,
                    color: tg.tgBlueBright,
                  ),
                ),
              if (att.url.isNotEmpty)
                IconButton(
                  tooltip: '转存至服务器下载队列',
                  onPressed: isQueueing
                      ? null
                      : () => _queueTelegramDownload(
                            url: att.url,
                            name: att.displayName,
                          ),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: isQueueing
                        ? SizedBox(
                            key: const ValueKey('file_q_loading'),
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tg.tgBlueBright,
                            ),
                          )
                        : Icon(
                            key: ValueKey('file_q_${isQueued}_$isFailed'),
                            isQueued
                                ? Icons.check_circle_rounded
                                : (isFailed
                                    ? Icons.error_outline_rounded
                                    : Icons.cloud_download_outlined),
                            size: 20,
                            color: isQueued
                                ? const Color(0xFF4ECC5E)
                                : (isFailed
                                    ? const Color(0xFFFF6B6B)
                                    : tg.tgBlueBright),
                          ),
                  ),
                ),
              if (!_isOptimisticMsgId(msg.id) || savedLocalPath != null)
                IconButton(
                  tooltip: savedLocalPath != null
                      ? '已下载: $savedLocalPath (点击打开所在目录)'
                      : '下载保存到本机电脑',
                  onPressed: isSavingLocal
                      ? null
                      : () {
                          if (savedLocalPath != null) {
                            _openLocalFileDirectory(savedLocalPath);
                          } else {
                            _saveAttachmentToLocalDownloads(chat, msg);
                          }
                        },
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: isSavingLocal
                        ? SizedBox(
                            key: const ValueKey('file_l_loading'),
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tg.tgBlueBright,
                            ),
                          )
                        : Icon(
                            key: ValueKey(
                              'file_l_${isSavedLocal}_$isFailedLocal',
                            ),
                            isSavedLocal
                                ? Icons.folder_open_rounded
                                : (isFailedLocal
                                    ? Icons.error_outline_rounded
                                    : Icons.download_rounded),
                            size: 19,
                            color: isSavedLocal
                                ? const Color(0xFF4ECC5E)
                                : (isFailedLocal
                                    ? const Color(0xFFFF6B6B)
                                    : tg.textSecondary),
                          ),
                  ),
                ),
            ],
          ),
        ),
        if (savedLocalPath != null)
          _buildLocalFilePathBanner(tg, savedLocalPath),
      ],
    );
  }

  /// Right-click / long-press Telegram context menu on a message bubble
  Future<void> _showMessageContextMenu(
    _TgPalette tg,
    TelegramChat chat,
    TelegramMessage msg,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final att = msg.attachment;
    final savedLocalPath = _getSavedLocalPath(chat, msg);
    final activeSelection = _activeSelectedBubbleText.trim();
    final selected = await showMenu<String>(
      context: context,
      color: tg.sidebarBg,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (activeSelection.isNotEmpty)
          PopupMenuItem(
            value: 'copy_selected',
            child: Row(
              children: [
                Icon(Icons.content_copy_rounded, size: 17, color: tg.tgBlueBright),
                const SizedBox(width: 10),
                Text('复制选中文字', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        if (msg.text.isNotEmpty)
          PopupMenuItem(
            value: 'copy',
            child: Row(
              children: [
                Icon(Icons.copy_rounded, size: 17, color: tg.textSecondary),
                const SizedBox(width: 10),
                Text('复制整条消息文本', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        if (msg.links.isNotEmpty)
          PopupMenuItem(
            value: 'copy_links',
            child: Row(
              children: [
                Icon(Icons.link_rounded, size: 18, color: tg.tgBlueBright),
                const SizedBox(width: 10),
                Text(
                  msg.links.length > 1
                      ? '复制消息内全部链接 (${msg.links.length})'
                      : '复制消息内链接',
                  style: TextStyle(color: tg.textPrimary),
                ),
              ],
            ),
          ),
        if (!chat.readOnly && msg.text.trim().isNotEmpty)
          PopupMenuItem(
            value: 'insert_compose',
            child: Row(
              children: [
                Icon(Icons.edit_note_rounded, size: 18, color: tg.textSecondary),
                const SizedBox(width: 10),
                Text('填入输入框编辑', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        if (!chat.readOnly)
          PopupMenuItem(
            value: 'reply',
            child: Row(
              children: [
                Icon(Icons.reply_rounded, size: 18, color: tg.textSecondary),
                const SizedBox(width: 10),
                Text('回复消息', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'forward',
          child: Row(
            children: [
              Icon(Icons.forward_rounded, size: 18, color: tg.textSecondary),
              const SizedBox(width: 10),
              Text('转发到其他会话...', style: TextStyle(color: tg.textPrimary)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'save_self',
          child: Row(
            children: [
              Icon(
                Icons.bookmark_border_rounded,
                size: 18,
                color: tg.tgBlueBright,
              ),
              const SizedBox(width: 10),
              Text('保存到收藏夹 (Saved Messages)', style: TextStyle(color: tg.textPrimary)),
            ],
          ),
        ),
        if (att != null && _canPreviewTelegramFile(att))
          PopupMenuItem(
            value: 'preview_file',
            child: Row(
              children: [
                Icon(
                  Icons.visibility_outlined,
                  size: 18,
                  color: tg.tgBlueBright,
                ),
                const SizedBox(width: 10),
                Text('在线预览文件内容', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        if (att != null && att.isVisualMedia)
          PopupMenuItem(
            value: 'play',
            child: Row(
              children: [
                Icon(
                  att.isVideo
                      ? Icons.play_circle_outline_rounded
                      : Icons.photo_library_outlined,
                  size: 18,
                  color: tg.tgBlueBright,
                ),
                const SizedBox(width: 10),
                Text(
                  att.isVideo ? '预览并播放视频' : '大图相册预览',
                  style: TextStyle(color: tg.textPrimary),
                ),
              ],
            ),
          ),
        if (savedLocalPath != null)
          PopupMenuItem(
            value: 'open_local_dir',
            child: Row(
              children: [
                const Icon(
                  Icons.folder_open_rounded,
                  size: 18,
                  color: Color(0xFF4ECC5E),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '打开文件所在目录 ($savedLocalPath)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tg.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        if (att != null)
          PopupMenuItem(
            value: 'save_local',
            child: Row(
              children: [
                Icon(
                  Icons.download_rounded,
                  size: 18,
                  color: tg.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  savedLocalPath != null ? '重新下载保存到本机电脑' : '下载保存到本机电脑',
                  style: TextStyle(color: tg.textPrimary),
                ),
              ],
            ),
          ),
        if (att != null && att.url.isNotEmpty)
          PopupMenuItem(
            value: 'queue',
            child: Row(
              children: [
                Icon(
                  Icons.cloud_download_outlined,
                  size: 18,
                  color: tg.tgBlueBright,
                ),
                const SizedBox(width: 10),
                Text('转存至服务器下载队列', style: TextStyle(color: tg.textPrimary)),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'select',
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 18,
                color: tg.textSecondary,
              ),
              const SizedBox(width: 10),
              Text('多选此消息', style: TextStyle(color: tg.textPrimary)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              const Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: Color(0xFFE54D42),
              ),
              const SizedBox(width: 10),
              const Text(
                '删除消息',
                style: TextStyle(color: Color(0xFFE54D42)),
              ),
            ],
          ),
        ),
      ],
    );

    if (!mounted || selected == null) return;
    switch (selected) {
      case 'copy_selected':
        if (activeSelection.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: activeSelection));
          _showDownloadHud('已复制选中文字', state: 'success');
        }
        break;
      case 'copy':
        Clipboard.setData(ClipboardData(text: msg.text));
        _showDownloadHud('已复制整条消息文本', state: 'success');
        break;
      case 'copy_links':
        if (msg.links.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: msg.links.join('\n')));
          _showDownloadHud(
            msg.links.length > 1
                ? '已复制 ${msg.links.length} 条链接'
                : '已复制消息内链接',
            state: 'success',
          );
        }
        break;
      case 'insert_compose':
        final textToInsert =
            activeSelection.isNotEmpty ? activeSelection : msg.text;
        _composeController.text = textToInsert;
        _composeController.selection = TextSelection.fromPosition(
          TextPosition(offset: _composeController.text.length),
        );
        _saveCurrentDraft();
        _composeFocusNode.requestFocus();
        break;
      case 'reply':
        setState(() => _replyingToMessage = msg);
        _saveCurrentDraft();
        _composeFocusNode.requestFocus();
        break;
      case 'forward':
        _showForwardMessagesDialog([msg]);
        break;
      case 'save_self':
        _saveMessageToSavedMessages(msg);
        break;
      case 'preview_file':
        _openFilePreviewDialog(chat, msg);
        break;
      case 'play':
        _openVideoViewer(chat, msg);
        break;
      case 'open_local_dir':
        if (savedLocalPath != null) {
          _openLocalFileDirectory(savedLocalPath);
        }
        break;
      case 'save_local':
        _saveAttachmentToLocalDownloads(chat, msg);
        break;
      case 'queue':
        if (att != null && att.url.isNotEmpty) {
          _queueTelegramDownload(url: att.url, name: att.displayName);
        }
        break;
      case 'select':
        setState(() {
          _selectionMode = true;
          _selectedMessageIds.add(msg.id);
        });
        break;
      case 'delete':
        _deleteMessagesByIds([msg.id]);
        break;
    }
  }

  /// Bottom Compose Bar / Selection Action Bar / Channel Read-Only Footer
  Widget _buildBottomBar(_TgPalette tg, TelegramChat chat) {
    final isMobile = _isMobileLayout;
    // 1. Multi-selection toolbar
    if (_selectionMode) {
      if (isMobile) {
        return Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: tg.composeBg,
            border: Border(top: BorderSide(color: tg.borderLine)),
          ),
          child: Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: tg.textSecondary,
                ),
                onPressed: () {
                  setState(() {
                    _selectionMode = false;
                    _selectedMessageIds.clear();
                  });
                },
              ),
              Text(
                '已选 ${_selectedMessageIds.length}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tg.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: _selectedMessageIds.isEmpty
                    ? null
                    : () {
                        final selectedList = _messages
                            .where((m) => _selectedMessageIds.contains(m.id))
                            .toList();
                        _showForwardMessagesDialog(selectedList);
                      },
                icon: const Icon(Icons.forward_rounded, size: 16),
                label: const Text('转发', style: TextStyle(fontSize: 12.5)),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tg.tgBlueBright,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: _selectedMessageIds.isEmpty
                    ? null
                    : _batchQueueSelectedDownloads,
                icon: const Icon(Icons.cloud_download_outlined, size: 15),
                label: const Text('转存', style: TextStyle(fontSize: 12.5)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除所选',
                onPressed: _selectedMessageIds.isEmpty
                    ? null
                    : () => _deleteMessagesByIds(_selectedMessageIds.toList()),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: _selectedMessageIds.isEmpty
                      ? tg.textMuted
                      : const Color(0xFFE54D42),
                ),
              ),
            ],
          ),
        );
      }

      return Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: tg.composeBg,
          border: Border(top: BorderSide(color: tg.borderLine)),
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.close_rounded, size: 20, color: tg.textSecondary),
              onPressed: () {
                setState(() {
                  _selectionMode = false;
                  _selectedMessageIds.clear();
                });
              },
            ),
            const SizedBox(width: 6),
            Text(
              '已选择 ${_selectedMessageIds.length} 条消息',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: tg.textPrimary,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _selectedMessageIds.isEmpty
                  ? null
                  : () {
                      final selectedList = _messages
                          .where((m) => _selectedMessageIds.contains(m.id))
                          .toList();
                      _showForwardMessagesDialog(selectedList);
                    },
              icon: const Icon(Icons.forward_rounded, size: 16),
              label: const Text('批量转发'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: tg.tgBlueBright),
              onPressed: _selectedMessageIds.isEmpty
                  ? null
                  : _batchQueueSelectedDownloads,
              icon: const Icon(Icons.cloud_download_outlined, size: 16),
              label: const Text('批量转存下载'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _selectedMessageIds.isEmpty
                  ? null
                  : () => _deleteMessagesByIds(_selectedMessageIds.toList()),
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 16,
                color: Color(0xFFE54D42),
              ),
              label: const Text(
                '删除所选',
                style: TextStyle(color: Color(0xFFE54D42)),
              ),
            ),
          ],
        ),
      );
    }

    // 2. Read-only broadcast channel footer (official Telegram style + TV remote focusable actions)
    if (chat.readOnly) {
      final isMuted = chat.muted ||
          widget.appState.telegramNotifications.isPeerMuted(
            _activeAccountId,
            chat.peer,
          );
      return Container(
        key: _conversationBottomBarKey,
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tg.composeBg,
          border: Border(top: BorderSide(color: tg.borderLine)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTvFocusableActionChip(
                icon: isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                label: isMuted ? '开启频道通知' : '静音频道',
                textColor: tg.tgBlueBright,
                bgColor: tg.searchFill,
                compact: true,
                onTap: () async {
                  await widget.appState.telegramNotifications
                      .toggleLocalPeerMute(
                    _activeAccountId,
                    chat.peer,
                  );
                  if (!mounted) return;
                  final nowMuted = widget.appState.telegramNotifications
                      .isPeerMuted(_activeAccountId, chat.peer);
                  setState(() {});
                  _showDownloadHud(
                    nowMuted
                        ? '已将频道「${chat.title}」设为免打扰'
                        : '已开启频道「${chat.title}」的新消息通知',
                    state: 'success',
                  );
                },
              ),
              const SizedBox(width: 8),
              _buildTvFocusableActionChip(
                icon: _mediaTypeFilter == 'video'
                    ? Icons.filter_alt_off_rounded
                    : Icons.videocam_outlined,
                label: _mediaTypeFilter == 'video' ? '显示全部消息' : '只看视频',
                textColor: _mediaTypeFilter == 'video'
                    ? Colors.white
                    : tg.textSecondary,
                bgColor: _mediaTypeFilter == 'video'
                    ? tg.tgBlueBright
                    : tg.searchFill,
                compact: true,
                onTap: () => setState(
                  () => _mediaTypeFilter =
                      _mediaTypeFilter == 'video' ? 'all' : 'video',
                ),
              ),
              const SizedBox(width: 8),
              _buildTvFocusableActionChip(
                icon: Icons.info_outline_rounded,
                label: _showRightInfoPanel ? '收起资料' : '频道资料与媒体',
                textColor: tg.textSecondary,
                bgColor: tg.searchFill,
                compact: true,
                onTap: () => setState(
                  () => _showRightInfoPanel = !_showRightInfoPanel,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final canSendNow =
        _composeController.text.trim().isNotEmpty || _stagedFiles.isNotEmpty;

    // 3. Official Telegram Message Compose Bar (with Emoji Panel, Formatting Bar, Staged Attachments, Screenshot & File Pickers)
    return Container(
      key: _conversationBottomBarKey,
      decoration: BoxDecoration(
        color: tg.composeBg,
        border: Border(top: BorderSide(color: tg.borderLine)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A. Official Telegram Emoji & Expression Panel (when open)
          if (_showEmojiPanel) _buildTelegramEmojiPanel(tg),

          // B. Optional Text Formatting Toolbar (Bold / Italic / Code / Spoiler / Link)
          if (_showFormattingBar) _buildFormattingToolbar(tg),

          // C. Reply Quote Banner
          if (_replyingToMessage != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 6, 10, 4),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: tg.borderLine)),
              ),
              child: Row(
                children: [
                  Icon(Icons.reply_rounded, size: 18, color: tg.tgBlueBright),
                  const SizedBox(width: 10),
                  Container(width: 2.5, height: 30, color: tg.tgBlueBright),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '回复 ${_replyingToMessage!.sender.isNotEmpty ? _replyingToMessage!.sender : chat.title}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: tg.tgBlueBright,
                          ),
                        ),
                        Text(
                          _replyingToMessage!.text.isNotEmpty
                              ? _replyingToMessage!.text
                              : (_replyingToMessage!.attachment?.displayName ??
                                  '[媒体消息]'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: tg.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: tg.textMuted,
                    ),
                    onPressed: () {
                      setState(() => _replyingToMessage = null);
                      _saveCurrentDraft();
                    },
                  ),
                ],
              ),
            ),

          // D. Staged Files / Screenshots Bar + Upload Progress Bar
          if (_stagedFiles.isNotEmpty || _uploadStatusText.isNotEmpty)
            _buildStagedAttachmentsBar(tg),

          // E. Main Compose Input Row
          if (isMobile)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 1. Emoji picker button on left (Official Telegram Android/iOS style)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _showEmojiPanel = !_showEmojiPanel),
                    icon: Icon(
                      _showEmojiPanel
                          ? Icons.keyboard_alt_outlined
                          : Icons.sentiment_satisfied_alt_rounded,
                      size: 23,
                      color: _showEmojiPanel
                          ? tg.tgBlueBright
                          : tg.textSecondary,
                    ),
                  ),

                  // 2. Rounded pill text field
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: tg.searchFill,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: TextField(
                        controller: _composeController,
                        focusNode: _composeFocusNode,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.newline,
                        maxLength: _stagedFiles.isNotEmpty ? 1024 : 4096,
                        buildCounter: (
                          _, {
                          required currentLength,
                          required isFocused,
                          maxLength,
                        }) =>
                            null,
                        onChanged: _onComposeTextChanged,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: tg.textPrimary,
                        ),
                        decoration: InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 9,
                          ),
                          hintText: _stagedFiles.isNotEmpty
                              ? '添加说明文字...'
                              : '消息...',
                          hintStyle: TextStyle(
                            fontSize: 14,
                            color: tg.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 3. Attachment menu (`📎` Media / File / Quick reply / Format)
                  PopupMenuButton<String>(
                    color: tg.sidebarBg,
                    offset: const Offset(0, -190),
                    onSelected: (action) {
                      switch (action) {
                        case 'media':
                          _pickFilesToAttach(mediaOnly: true, asFile: false);
                          break;
                        case 'file':
                          _pickFilesToAttach(mediaOnly: false, asFile: true);
                          break;
                        case 'quick_reply':
                          _showQuickRepliesDialog(tg);
                          break;
                        case 'format':
                          setState(
                            () => _showFormattingBar = !_showFormattingBar,
                          );
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'media',
                        child: Row(
                          children: [
                            Icon(
                              Icons.photo_library_outlined,
                              size: 18,
                              color: tg.tgBlueBright,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '发送相册图片或视频',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: tg.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'file',
                        child: Row(
                          children: [
                            Icon(
                              Icons.insert_drive_file_outlined,
                              size: 18,
                              color: tg.tgBlueBright,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '发送原文件 / 文档',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: tg.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'quick_reply',
                        child: Row(
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 18,
                              color: tg.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '快捷回复短语模板',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: tg.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'format',
                        child: Row(
                          children: [
                            Icon(
                              Icons.text_format_rounded,
                              size: 18,
                              color: _showFormattingBar
                                  ? tg.tgBlueBright
                                  : tg.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _showFormattingBar ? '隐藏文字格式栏' : '文字格式 (加粗/代码/剧透)',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: tg.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Icon(
                        Icons.attach_file_rounded,
                        size: 22,
                        color: _stagedFiles.isNotEmpty
                            ? tg.tgBlueBright
                            : tg.textSecondary,
                      ),
                    ),
                  ),

                  // 4. Send button
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: canSendNow ? () => _sendMessage() : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: canSendNow ? tg.tgBlueBright : tg.searchFill,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: _isSendingMessage
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              Icons.send_rounded,
                              size: 18,
                              color: canSendNow ? Colors.white : tg.textMuted,
                            ),
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 1. Official Telegram Paperclip Attachment Menu (`📎 发送图片/视频/文件/粘贴`)
                PopupMenuButton<String>(
                  color: tg.sidebarBg,
                  offset: const Offset(0, -210),
                  onSelected: (action) {
                    switch (action) {
                      case 'media':
                        _pickFilesToAttach(mediaOnly: true, asFile: false);
                        break;
                      case 'file':
                        _pickFilesToAttach(mediaOnly: false, asFile: true);
                        break;
                      case 'paste':
                        _pasteClipboardImageOrFiles(showEmptyToast: true);
                        break;
                      case 'shot_region':
                        _captureSystemRegionScreenshot();
                        break;
                      case 'shot_window':
                        _captureAppWindowScreenshot();
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'media',
                      child: Row(
                        children: [
                          Icon(
                            Icons.photo_library_outlined,
                            size: 18,
                            color: tg.tgBlueBright,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '发送图片或视频 (相册媒体)',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'file',
                      child: Row(
                        children: [
                          Icon(
                            Icons.insert_drive_file_outlined,
                            size: 18,
                            color: tg.tgBlueBright,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '发送无损原文件 / 文档 (不压缩)',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'paste',
                      child: Row(
                        children: [
                          Icon(
                            Icons.content_paste_rounded,
                            size: 18,
                            color: tg.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '粘贴剪贴板中的图片 (Cmd+V)',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'shot_region',
                      child: Row(
                        children: [
                          Icon(
                            Icons.crop_rounded,
                            size: 18,
                            color: tg.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '选区截图并发送',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'shot_window',
                      child: Row(
                        children: [
                          Icon(
                            Icons.screenshot_monitor_rounded,
                            size: 18,
                            color: tg.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '截取当前窗口并发送',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(
                      Icons.attach_file_rounded,
                      size: 21,
                      color: _stagedFiles.isNotEmpty
                          ? tg.tgBlueBright
                          : tg.textSecondary,
                    ),
                  ),
                ),

                // 2. Dedicated Screenshot Button (`✂️ 截图`: Click for region capture, right-click/menu for options)
                PopupMenuButton<String>(
                  color: tg.sidebarBg,
                  offset: const Offset(0, -145),
                  onSelected: (mode) {
                    if (mode == 'system_region') {
                      _captureSystemRegionScreenshot();
                    } else if (mode == 'app_crop') {
                      _openInAppRegionCropScreenshot();
                    } else if (mode == 'app_window') {
                      _captureAppWindowScreenshot();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'system_region',
                      child: Row(
                        children: [
                          Icon(
                            Icons.content_cut_rounded,
                            size: 17,
                            color: tg.tgBlueBright,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '系统选区交互截图 (推荐)',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'app_crop',
                      child: Row(
                        children: [
                          Icon(
                            Icons.crop_free_rounded,
                            size: 17,
                            color: tg.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '应用内框选区域截图',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'app_window',
                      child: Row(
                        children: [
                          Icon(
                            Icons.screenshot_monitor_rounded,
                            size: 17,
                            color: tg.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '截取整个客户端窗口画面',
                            style: TextStyle(fontSize: 13, color: tg.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(
                      Icons.content_cut_rounded,
                      size: 19,
                      color: tg.textSecondary,
                    ),
                  ),
                ),

                const SizedBox(width: 4),

                // 3. Multi-line Official Telegram Input Field (Enter to send, Shift+Enter for newline, Cmd+V image paste)
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    onKeyEvent: (node, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      final isShift = HardwareKeyboard.instance.isShiftPressed;
                      final isCmdOrCtrl =
                          HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed;

                      // Enter (without Shift) sends message
                      if ((event.logicalKey == LogicalKeyboardKey.enter ||
                              event.logicalKey ==
                                  LogicalKeyboardKey.numpadEnter) &&
                          !isShift) {
                        _sendMessage();
                        return KeyEventResult.handled;
                      }

                      // Cmd+V / Ctrl+V: check if clipboard holds an image
                      if (isCmdOrCtrl &&
                          event.logicalKey == LogicalKeyboardKey.keyV) {
                        _pasteClipboardImageOrFiles(showEmptyToast: false);
                        return KeyEventResult.ignored;
                      }

                      // Escape closes emoji panel or cancels reply
                      if (event.logicalKey == LogicalKeyboardKey.escape) {
                        if (_showEmojiPanel) {
                          setState(() => _showEmojiPanel = false);
                          return KeyEventResult.handled;
                        }
                        if (_replyingToMessage != null) {
                          setState(() => _replyingToMessage = null);
                          _saveCurrentDraft();
                          return KeyEventResult.handled;
                        }
                      }

                      // Up arrow when input is empty replies to the latest message
                      if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                          _composeController.text.isEmpty &&
                          _messages.isNotEmpty) {
                        setState(() => _replyingToMessage = _messages.last);
                        _saveCurrentDraft();
                        return KeyEventResult.handled;
                      }

                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _composeController,
                      focusNode: _composeFocusNode,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: _stagedFiles.isNotEmpty ? 1024 : 4096,
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                      onChanged: _onComposeTextChanged,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.38,
                        color: tg.textPrimary,
                      ),
                      decoration: InputDecoration(
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        hintText: _stagedFiles.isNotEmpty
                            ? '添加图片/文件说明文字 (可选，Enter 发送)...'
                            : '撰写消息... (Enter 发送，Shift+Enter 换行，支持粘贴图片)',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: tg.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),

                // 4. Text Formatting Toggle Button (`Aa`)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(
                    () => _showFormattingBar = !_showFormattingBar,
                  ),
                  icon: Icon(
                    Icons.text_format_rounded,
                    size: 21,
                    color: _showFormattingBar
                        ? tg.tgBlueBright
                        : tg.textSecondary,
                  ),
                ),

                // 4b. Quick Replies Template Manager (`⚡`)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showQuickRepliesDialog(tg),
                  icon: Icon(
                    Icons.bolt_rounded,
                    size: 20,
                    color: tg.textSecondary,
                  ),
                ),

                // 5. Official Telegram Emoji & Expression Picker Button (`😊`)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _showEmojiPanel = !_showEmojiPanel),
                  icon: Icon(
                    _showEmojiPanel
                        ? Icons.keyboard_alt_outlined
                        : Icons.sentiment_satisfied_alt_rounded,
                    size: 21,
                    color: _showEmojiPanel ? tg.tgBlueBright : tg.textSecondary,
                  ),
                ),

                const SizedBox(width: 4),

                // 6. Official Telegram Send Button
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: canSendNow ? () => _sendMessage() : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: canSendNow
                          ? tg.tgBlueBright
                          : tg.searchFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: _isSendingMessage
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            Icons.send_rounded,
                            size: 18,
                            color: canSendNow ? Colors.white : tg.textMuted,
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

  /// Staged Attachments & Upload Progress Bar above Compose Box
  Widget _buildStagedAttachmentsBar(_TgPalette tg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      decoration: BoxDecoration(
        color: tg.headerBg,
        border: Border(bottom: BorderSide(color: tg.borderLine)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.attach_file_rounded,
                size: 15,
                color: tg.tgBlueBright,
              ),
              const SizedBox(width: 6),
              Text(
                '待发送附件 (${_stagedFiles.length}/10)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: tg.textPrimary,
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: _isSendingMessage
                    ? null
                    : () {
                        setState(() => _sendAsFile = !_sendAsFile);
                        _saveCurrentDraft();
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
                        _sendAsFile
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 16,
                        color: _sendAsFile ? tg.tgBlueBright : tg.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '作为无损原文件发送 (不压缩)',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _sendAsFile
                              ? tg.tgBlueBright
                              : tg.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _isSendingMessage
                    ? null
                    : () => _pickFilesToAttach(
                        mediaOnly: false,
                        asFile: _sendAsFile,
                      ),
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('继续添加', style: TextStyle(fontSize: 11.5)),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _isSendingMessage
                    ? null
                    : () {
                        setState(() => _stagedFiles.clear());
                        _saveCurrentDraft();
                      },
                child: const Text(
                  '清空',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFFE54D42)),
                ),
              ),
            ],
          ),
          if (_stagedFiles.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 58,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _stagedFiles.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, idx) {
                  final f = _stagedFiles[idx];
                  return Container(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: tg.searchFill,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tg.borderLine),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (f.isImage && f.bytes.isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.memory(
                              f.bytes,
                              width: 46,
                              height: 46,
                              fit: BoxFit.cover,
                            ),
                          )
                        else
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: tg.tgBlueBright.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              f.isVideo
                                  ? Icons.movie_outlined
                                  : Icons.insert_drive_file_outlined,
                              size: 22,
                              color: tg.tgBlueBright,
                            ),
                          ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 135),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                f.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: tg.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                f.formattedSize,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: tg.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 22,
                            minHeight: 22,
                          ),
                          onPressed: _isSendingMessage
                              ? null
                              : () {
                                  setState(() => _stagedFiles.removeAt(idx));
                                  _saveCurrentDraft();
                                },
                          icon: Icon(
                            Icons.close_rounded,
                            size: 15,
                            color: tg.textMuted,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          if (_isSendingMessage && _uploadStatusText.isNotEmpty) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: _uploadPercent > 0 ? (_uploadPercent / 100.0) : null,
              minHeight: 3,
              color: tg.tgBlueBright,
              backgroundColor: tg.searchFill,
            ),
            const SizedBox(height: 4),
            Text(
              _uploadStatusText,
              style: TextStyle(fontSize: 11.5, color: tg.tgBlueBright),
            ),
          ],
        ],
      ),
    );
  }

  /// Text Formatting Toolbar (`B` / `I` / `S` / `||剧透||` / `` `代码` `` / `代码块`)
  Widget _buildFormattingToolbar(_TgPalette tg) {
    Widget fmtBtn(String label, String tip, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: tg.searchFill,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: tg.textPrimary,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: tg.headerBg,
        border: Border(bottom: BorderSide(color: tg.borderLine)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            fmtBtn(
              'B 粗体',
              '加粗选中文字 (**粗体**)',
              () => _wrapSelectionWithMarkdown('**', '**', placeholder: '粗体文字'),
            ),
            const SizedBox(width: 6),
            fmtBtn(
              'I 斜体',
              '斜体选中文字 (__斜体__)',
              () => _wrapSelectionWithMarkdown('__', '__', placeholder: '斜体文字'),
            ),
            const SizedBox(width: 6),
            fmtBtn(
              'S 删除线',
              '删除线 (~~文字~~)',
              () => _wrapSelectionWithMarkdown('~~', '~~', placeholder: '删除线'),
            ),
            const SizedBox(width: 6),
            fmtBtn(
              '|| 剧透隐藏 ||',
              'Telegram 防剧透遮罩 (||内容||)',
              () => _wrapSelectionWithMarkdown('||', '||', placeholder: '剧透内容'),
            ),
            const SizedBox(width: 6),
            fmtBtn(
              '<> 行内代码',
              '等宽行内代码 (`code`)',
              () => _wrapSelectionWithMarkdown('`', '`', placeholder: 'code'),
            ),
            const SizedBox(width: 6),
            fmtBtn(
              '{ } 代码块',
              '多行代码块 (```...```)',
              () => _wrapSelectionWithMarkdown(
                '```\n',
                '\n```',
                placeholder: '代码内容',
              ),
            ),
            const SizedBox(width: 6),
            fmtBtn(
              '🔗 超链接',
              '插入 Markdown 链接',
              () => _wrapSelectionWithMarkdown(
                '[',
                '](https://)',
                placeholder: '链接标题',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Official Telegram Desktop Emoji, Kaomoji & Quick Phrase Panel
  Widget _buildTelegramEmojiPanel(_TgPalette tg) {
    final kw = _emojiSearchQuery.trim().toLowerCase();
    List<String> currentItems = [];
    bool isTextPhraseMode = false;

    if (kw.isNotEmpty) {
      // Search across all categories
      final all = <String>{
        ..._recentEmojis,
        for (final cat in _kTelegramEmojiCategories) ...cat.items,
      };
      currentItems = all.where((item) => item.toLowerCase().contains(kw)).toList();
      if (currentItems.isEmpty) {
        // Match category title keywords (e.g. "笑", "手", "心", "动物", "美食", "颜文字")
        for (final cat in _kTelegramEmojiCategories) {
          if (cat.title.toLowerCase().contains(kw)) {
            currentItems.addAll(cat.items);
          }
        }
      }
    } else if (_selectedEmojiTab == 0) {
      currentItems = _recentEmojis;
    } else {
      final catIdx = (_selectedEmojiTab - 1).clamp(
        0,
        _kTelegramEmojiCategories.length - 1,
      );
      final cat = _kTelegramEmojiCategories[catIdx];
      currentItems = cat.items;
      isTextPhraseMode = cat.isTextPhrase;
    }

    return Container(
      height: 255,
      decoration: BoxDecoration(
        color: tg.headerBg,
        border: Border(bottom: BorderSide(color: tg.borderLine)),
      ),
      child: Column(
        children: [
          // Top category bar + search input
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tg.borderLine)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildEmojiCategoryTabBtn(tg, 0, '🕒', '最近常用'),
                        for (int i = 0;
                            i < _kTelegramEmojiCategories.length;
                            i++)
                          _buildEmojiCategoryTabBtn(
                            tg,
                            i + 1,
                            _kTelegramEmojiCategories[i].icon,
                            _kTelegramEmojiCategories[i].title,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  height: 28,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: tg.searchFill,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: TextField(
                      controller: _emojiSearchCtrl,
                      onChanged: (v) => setState(() => _emojiSearchQuery = v),
                      style: TextStyle(fontSize: 12, color: tg.textPrimary),
                      decoration: InputDecoration(
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                        hintText: '搜索表情...',
                        hintStyle:
                            TextStyle(fontSize: 11.5, color: tg.textMuted),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _showEmojiPanel = false),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: tg.textMuted,
                  ),
                ),
              ],
            ),
          ),

          // Emoji grid or Kaomoji/Phrase chips
          Expanded(
            child: isTextPhraseMode
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: currentItems.map((phrase) {
                        return GestureDetector(
                          onSecondaryTap: () =>
                              _onEmojiSelected(phrase, sendImmediately: true),
                          child: ActionChip(
                            backgroundColor: tg.searchFill,
                            label: Text(
                              phrase,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: tg.textPrimary,
                              ),
                            ),
                            onPressed: () => _onEmojiSelected(phrase),
                          ),
                        );
                      }).toList(),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 42,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemCount: currentItems.length,
                    itemBuilder: (_, idx) {
                      final emoji = currentItems[idx];
                      return GestureDetector(
                        onSecondaryTap: () =>
                            _onEmojiSelected(emoji, sendImmediately: true),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _onEmojiSelected(emoji),
                          child: Center(
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 23),
                            ),
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

  Widget _buildEmojiCategoryTabBtn(
    _TgPalette tg,
    int index,
    String iconStr,
    String tooltip,
  ) {
    final active = _selectedEmojiTab == index && _emojiSearchQuery.isEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        _emojiSearchCtrl.clear();
        setState(() {
          _emojiSearchQuery = '';
          _selectedEmojiTab = index;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? tg.tgBlueBright.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(iconStr, style: const TextStyle(fontSize: 16)),
      ),
    );
  }

  /// Right-hand Official Telegram "Chat Info & Shared Media" Panel
  Widget _buildRightChatInfoPanel(_TgPalette tg, TelegramChat chat) {
    final mediaMessages = _messages
        .where((m) => m.attachment != null && m.attachment!.url.isNotEmpty)
        .toList();

    return Container(
      color: tg.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tg.borderLine)),
            ),
            child: Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '返回聊天',
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    size: 19,
                    color: tg.textSecondary,
                  ),
                  onPressed: () =>
                      setState(() => _showRightInfoPanel = false),
                ),
                const SizedBox(width: 4),
                Text(
                  '会话信息与媒体',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: tg.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '收起面板',
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: tg.textSecondary,
                  ),
                  onPressed: () =>
                      setState(() => _showRightInfoPanel = false),
                ),
              ],
            ),
          ),
          // Peer profile summary
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                _buildPeerAvatar(
                  chat.peer,
                  chat.title,
                  avatar: chat.avatar,
                  isSelf: chat.self,
                  size: 68,
                  fontSize: 24,
                ),
                const SizedBox(height: 10),
                Text(
                  chat.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: tg.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${chat.kind.isNotEmpty ? chat.kind : "Telegram 会话"} · ID: ${chat.peer}',
                  style: TextStyle(fontSize: 11.5, color: tg.textSecondary),
                ),
                if (chat.conversationActionLabel.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _buildTvFocusableActionChip(
                      autofocus: true,
                      icon: chat.conversationActionType == 'delete_contact'
                          ? Icons.person_remove_outlined
                          : Icons.logout_rounded,
                      label: chat.conversationActionLabel,
                      textColor: const Color(0xFFFF6B6B),
                      bgColor: const Color(0x28E54D42),
                      onTap: () =>
                          _confirmAndPerformConversationAction(tg, chat),
                    ),
                  ),
                ],
                if (mediaMessages.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _buildTvFocusableActionChip(
                      icon: Icons.cloud_download_outlined,
                      label: '一键转存本页媒体 (${mediaMessages.length})',
                      textColor: Colors.white,
                      bgColor: tg.tgBlueBright,
                      onTap: () async {
                        int count = 0;
                        for (final m in mediaMessages) {
                          final att = m.attachment!;
                          await _queueTelegramDownload(
                            url: att.url,
                            name: att.displayName,
                            showToast: false,
                          );
                          count++;
                        }
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已将本页 $count 个媒体加入服务器下载队列'),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: tg.borderLine),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Text(
              '共享媒体列表 (${mediaMessages.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: tg.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: mediaMessages.isEmpty
                ? Center(
                    child: Text(
                      '当前已加载消息中无媒体附件',
                      style: TextStyle(fontSize: 12, color: tg.textMuted),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    itemCount: mediaMessages.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, idx) {
                      final m = mediaMessages[idx];
                      final att = m.attachment!;
                      final isVideo = att.isVideo;
                      final isPhoto = att.isPhoto;
                      final isAudio = att.isAudio;
                      final isMusic = att.isMusic;
                      final isAudioActive =
                          isAudio && _isAudioTrackActive(chat, m);
                      final dlKey = '$_activeAccountId:${att.url}';
                      final isQueueing = _pendingDownloads.contains(dlKey);
                      final isQueued = _isUrlQueuedOrInTasks(att.url);
                      final isFailed = _failedDownloads.contains(dlKey);
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        tileColor: isAudioActive
                            ? tg.tgBlueBright.withValues(alpha: 0.14)
                            : tg.searchFill,
                        leading: Icon(
                          isVideo
                              ? Icons.play_circle_fill_rounded
                              : (isPhoto
                                  ? Icons.image_rounded
                                  : (isAudio
                                      ? (isAudioActive && _isAudioPlaying
                                          ? Icons.pause_circle_filled_rounded
                                          : Icons.music_note_rounded)
                                      : Icons.insert_drive_file_rounded)),
                          color: tg.tgBlueBright,
                          size: 26,
                        ),
                        title: Text(
                          isMusic ? att.musicTitle : att.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isAudioActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: isAudioActive
                                ? tg.tgBlueBright
                                : tg.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          [
                            if (isMusic) att.musicPerformer,
                            if (att.duration > 0 && isAudio)
                              _formatDurationClock(att.duration),
                            if (att.formattedSize.isNotEmpty) att.formattedSize,
                            if (isQueued) '已加入下载队列 ✓',
                            if (isFailed) '添加失败 · 点击重试',
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 11,
                            color: isQueued
                                ? const Color(0xFF4ECC5E)
                                : (isFailed
                                    ? const Color(0xFFFF6B6B)
                                    : tg.textMuted),
                          ),
                        ),
                        trailing: IconButton(
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                            child: isQueueing
                                ? SizedBox(
                                    key: const ValueKey('info_q_loading'),
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: tg.tgBlueBright,
                                    ),
                                  )
                                : Icon(
                                    key: ValueKey(
                                      'info_q_${isQueued}_$isFailed',
                                    ),
                                    isQueued
                                        ? Icons.check_circle_rounded
                                        : (isFailed
                                            ? Icons.error_outline_rounded
                                            : Icons.cloud_download_outlined),
                                    size: 18,
                                    color: isQueued
                                        ? const Color(0xFF4ECC5E)
                                        : (isFailed
                                            ? const Color(0xFFFF6B6B)
                                            : tg.tgBlueBright),
                                  ),
                          ),
                          onPressed: isQueueing
                              ? null
                              : () => _queueTelegramDownload(
                                    url: att.url,
                                    name: att.displayName,
                                  ),
                        ),
                        onTap: () {
                          if (att.isVisualMedia) {
                            _openMediaGalleryViewer(chat, m);
                          } else if (isAudio) {
                            _togglePlayAudioMessage(chat, m);
                          } else if (_canPreviewTelegramFile(att)) {
                            _openFilePreviewDialog(chat, m);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Subtle geometric pattern painter matching the official Telegram Desktop chat wallpaper
class _TelegramWallpaperPainter extends CustomPainter {
  final bool isDark;

  const _TelegramWallpaperPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isDark
          ? const Color(0x07FFFFFF)
          : const Color(0x12385934)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    const step = 64.0;
    for (double y = 16; y < size.height; y += step) {
      for (double x = 16; x < size.width; x += step) {
        final offset = ((y ~/ step) % 2 == 0) ? 0.0 : 28.0;
        final cx = x + offset;
        if (cx > size.width) continue;
        canvas.drawCircle(Offset(cx, y), 6, paint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx + 26, y + 22),
              width: 12,
              height: 9,
            ),
            const Radius.circular(3),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TelegramWallpaperPainter oldDelegate) {
    return oldDelegate.isDark != isDark;
  }
}

class _TelegramAccountConfigDialog extends StatefulWidget {
  final AppState appState;
  final String initialAccountId;
  final ValueChanged<String> onChanged;

  const _TelegramAccountConfigDialog({
    required this.appState,
    required this.initialAccountId,
    required this.onChanged,
  });

  @override
  State<_TelegramAccountConfigDialog> createState() =>
      _TelegramAccountConfigDialogState();
}

class _TelegramAccountConfigDialogState
    extends State<_TelegramAccountConfigDialog> {
  List<TelegramAccount> _accounts = [];
  late String _accountId;
  TelegramAuthStatus _status = const TelegramAuthStatus();

  final TextEditingController _newAccountNameCtrl = TextEditingController();
  final TextEditingController _apiIdCtrl = TextEditingController();
  final TextEditingController _apiHashCtrl = TextEditingController();
  final TextEditingController _proxyCtrl = TextEditingController();
  final TextEditingController _cacheDirCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _codeCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  String _effectiveCacheDir = '';
  bool _isBusy = false;
  String _feedback = '';
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _accountId = widget.initialAccountId;
    _refreshState();
  }

  @override
  void dispose() {
    _newAccountNameCtrl.dispose();
    _apiIdCtrl.dispose();
    _apiHashCtrl.dispose();
    _proxyCtrl.dispose();
    _cacheDirCtrl.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshState() async {
    setState(() {
      _isBusy = true;
      _isError = false;
      _feedback = '正在同步 Telegram 账号状态...';
    });

    try {
      final accData = await widget.appState.api.fetchTelegramAccounts();
      if (!accData.accounts.any((a) => a.id == _accountId) &&
          accData.accounts.isNotEmpty) {
        _accountId = accData.activeId;
      }
      final st = await widget.appState.api.fetchTelegramStatus(_accountId);
      final cacheCfg =
          await widget.appState.api.fetchTelegramCacheConfig(_accountId);
      if (!mounted) return;

      setState(() {
        _accounts = accData.accounts;
        _status = st;
        _cacheDirCtrl.text = (cacheCfg['cache_dir'] ?? '').toString();
        _effectiveCacheDir =
            (cacheCfg['effective_dir'] ?? '默认缓存目录').toString();
        _isBusy = false;
        _feedback = st.authorized
            ? '当前账号已登录，可直接浏览聊天并下载媒体'
            : (st.codeSent
                ? '验证码已发送，请输入验证码完成登录'
                : (st.configured ? 'API 已配置，请输入手机号发送验证码' : '请先填写 API ID 和 API Hash'));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _isError = true;
        _feedback = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Telegram 账号与登录配置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onChanged(_accountId);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _isError
                        ? VideoPlatformTheme.danger
                        : VideoPlatformTheme.borderSubtle,
                  ),
                ),
                child: Text(
                  _feedback,
                  style: TextStyle(
                    fontSize: 12,
                    color: _isError
                        ? VideoPlatformTheme.danger
                        : VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (_accounts.isNotEmpty)
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: _accounts.any((a) => a.id == _accountId)
                                    ? _accountId
                                    : _accounts.first.id,
                                dropdownColor: VideoPlatformTheme.bgElevated,
                                decoration: const InputDecoration(
                                  labelText: '当前账号',
                                ),
                                items: _accounts
                                    .map(
                                      (a) => DropdownMenuItem(
                                        value: a.id,
                                        child: Text(a.displayLabel),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _isBusy
                                    ? null
                                    : (val) async {
                                        if (val == null) return;
                                        setState(() => _accountId = val);
                                        widget.onChanged(val);
                                        await widget.appState.api
                                            .setActiveTelegramAccount(val);
                                        await _refreshState();
                                      },
                              ),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _newAccountNameCtrl,
                              decoration: InputDecoration(
                                labelText: '新增账号备注名',
                                suffixIcon: TextButton(
                                  onPressed: _isBusy
                                      ? null
                                      : () async {
                                          final name =
                                              _newAccountNameCtrl.text.trim();
                                          if (name.isEmpty) return;
                                          setState(() => _isBusy = true);
                                          try {
                                            final acc = await widget
                                                .appState.api
                                                .createTelegramAccount(name);
                                            _newAccountNameCtrl.clear();
                                            _accountId = acc.id;
                                            await _refreshState();
                                          } catch (e) {
                                            setState(() {
                                              _isBusy = false;
                                              _isError = true;
                                              _feedback = e.toString();
                                            });
                                          }
                                        },
                                  child: const Text('添加'),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      const Text(
                        '1. API 凭据配置 (从 my.telegram.org 获取)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _apiIdCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'API ID',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _apiHashCtrl,
                              decoration: const InputDecoration(
                                labelText: 'API Hash (32位十六进制)',
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
                              controller: _proxyCtrl,
                              decoration: const InputDecoration(
                                labelText: 'SOCKS5 代理 (可选)',
                                hintText: 'socks5://127.0.0.1:1080',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    final apiId =
                                        int.tryParse(_apiIdCtrl.text.trim()) ??
                                            0;
                                    final hash = _apiHashCtrl.text.trim();
                                    if (apiId <= 0 || hash.isEmpty) {
                                      setState(() {
                                        _isError = true;
                                        _feedback = '请填写有效的 API ID 和 API Hash';
                                      });
                                      return;
                                    }
                                    setState(() => _isBusy = true);
                                    try {
                                      await widget.appState.api
                                          .saveTelegramApiConfig(
                                        accountId: _accountId,
                                        apiId: apiId,
                                        apiHash: hash,
                                        proxyUrl: _proxyCtrl.text.trim(),
                                      );
                                      await _refreshState();
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = e.toString();
                                      });
                                    }
                                  },
                            child: const Text('保存 API 配置'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      const Text(
                        '2. 手机号验证码与两步验证登录',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _phoneCtrl,
                              decoration: const InputDecoration(
                                labelText: '手机号 (含国家区号)',
                                hintText: '+8613800000000',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    final phone = _phoneCtrl.text.trim();
                                    if (phone.isEmpty) return;
                                    setState(() => _isBusy = true);
                                    try {
                                      await widget.appState.api
                                          .sendTelegramLoginCode(
                                        accountId: _accountId,
                                        phone: phone,
                                      );
                                      await _refreshState();
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = e.toString();
                                      });
                                    }
                                  },
                            child: const Text('发送验证码'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _codeCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Telegram 验证码',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _passwordCtrl,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: '两步验证密码 (如有)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    setState(() => _isBusy = true);
                                    try {
                                      await widget.appState.api
                                          .submitTelegramLogin(
                                        accountId: _accountId,
                                        code: _codeCtrl.text.trim(),
                                        password: _passwordCtrl.text,
                                      );
                                      _codeCtrl.clear();
                                      _passwordCtrl.clear();
                                      await _refreshState();
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = e.toString();
                                      });
                                    }
                                  },
                            child: const Text('登录 Telegram'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      const Text(
                        '3. 视频缓存目录与账号操作',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _cacheDirCtrl,
                              decoration: InputDecoration(
                                labelText: '视频缓存目录',
                                helperText: '实际生效：$_effectiveCacheDir',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    setState(() => _isBusy = true);
                                    try {
                                      await widget.appState.api
                                          .saveTelegramCacheConfig(
                                        _accountId,
                                        _cacheDirCtrl.text.trim(),
                                      );
                                      await _refreshState();
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = e.toString();
                                      });
                                    }
                                  },
                            child: const Text('保存缓存目录'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _isBusy ? null : _refreshState,
                            icon: const Icon(Icons.refresh, size: 15),
                            label: const Text('刷新状态'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    setState(() => _isBusy = true);
                                    try {
                                      final jsonStr = await widget.appState.api
                                          .exportTelegramAccountsJson();
                                      await Clipboard.setData(
                                        ClipboardData(text: jsonStr),
                                      );
                                      setState(() {
                                        _isBusy = false;
                                        _isError = false;
                                        _feedback =
                                            '已导出所有账号备份 JSON 到剪贴板，请妥善保存';
                                      });
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = e.toString();
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.download_outlined, size: 15),
                            label: const Text('导出账号备份到剪贴板'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    final data =
                                        await Clipboard.getData('text/plain');
                                    final txt = data?.text?.trim() ?? '';
                                    if (txt.isEmpty) {
                                      setState(() {
                                        _isError = true;
                                        _feedback = '剪贴板为空，请先复制备份 JSON';
                                      });
                                      return;
                                    }
                                    setState(() => _isBusy = true);
                                    try {
                                      final parsed = jsonDecode(txt);
                                      final res = await widget.appState.api
                                          .importTelegramAccountsJson(parsed);
                                      await _refreshState();
                                      setState(() {
                                        _feedback =
                                            '导入完成：新增 ${res['imported'] ?? 0} 个，跳过 ${res['skipped'] ?? 0} 个';
                                      });
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = '导入备份失败：$e';
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.upload_outlined, size: 15),
                            label: const Text('从剪贴板导入备份'),
                          ),
                          if (_status.authorized)
                            OutlinedButton(
                              onPressed: _isBusy
                                  ? null
                                  : () async {
                                      setState(() => _isBusy = true);
                                      try {
                                        await widget.appState.api
                                            .logoutTelegram(_accountId);
                                        await _refreshState();
                                      } catch (e) {
                                        setState(() {
                                          _isBusy = false;
                                          _isError = true;
                                          _feedback = e.toString();
                                        });
                                      }
                                    },
                              child: const Text('退出当前 Telegram 账号'),
                            ),
                          TextButton(
                            onPressed: _isBusy
                                ? null
                                : () async {
                                    setState(() => _isBusy = true);
                                    try {
                                      final nextId = await widget.appState.api
                                          .deleteTelegramAccount(_accountId);
                                      _accountId = nextId;
                                      await _refreshState();
                                    } catch (e) {
                                      setState(() {
                                        _isBusy = false;
                                        _isError = true;
                                        _feedback = e.toString();
                                      });
                                    }
                                  },
                            child: Text(
                              '删除此账号',
                              style: TextStyle(color: VideoPlatformTheme.danger),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Official Telegram Desktop "Send Photo / Screenshot / File" Preview Modal
class _TelegramSendPreviewDialog extends StatefulWidget {
  final String title;
  final String targetChatTitle;
  final List<TelegramOutgoingFile> initialFiles;
  final bool initialAsFile;
  final String initialCaption;
  final void Function(
    List<TelegramOutgoingFile> files,
    bool asFile,
    String caption,
  ) onStageToBar;
  final void Function(
    List<TelegramOutgoingFile> files,
    bool asFile,
    String caption,
  ) onSendNow;

  const _TelegramSendPreviewDialog({
    required this.title,
    required this.targetChatTitle,
    required this.initialFiles,
    required this.initialAsFile,
    required this.initialCaption,
    required this.onStageToBar,
    required this.onSendNow,
  });

  @override
  State<_TelegramSendPreviewDialog> createState() =>
      _TelegramSendPreviewDialogState();
}

class _TelegramSendPreviewDialogState
    extends State<_TelegramSendPreviewDialog> {
  late List<TelegramOutgoingFile> _files;
  late bool _asFile;
  late final TextEditingController _captionCtrl;
  int _previewIdx = 0;

  @override
  void initState() {
    super.initState();
    _files = List<TelegramOutgoingFile>.from(widget.initialFiles);
    _asFile = widget.initialAsFile;
    _captionCtrl = TextEditingController(text: widget.initialCaption);
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tg = _TgPalette(VideoPlatformTheme.isDark);
    final currentFile =
        _files.isNotEmpty
            ? _files[_previewIdx.clamp(0, _files.length - 1)]
            : null;
    final hasAnyImage = _files.any((f) => f.isImage);

    return Dialog(
      backgroundColor: tg.sidebarBg,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top header
              Row(
                children: [
                  Icon(
                    hasAnyImage && !_asFile
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 20,
                    color: tg.tgBlueBright,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.title} · 发送至「${widget.targetChatTitle}」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: tg.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: tg.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Main preview stage
              if (currentFile != null)
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: 180,
                      maxHeight: 330,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B121A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: tg.borderLine),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: currentFile.isImage && currentFile.bytes.isNotEmpty
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              InteractiveViewer(
                                minScale: 0.6,
                                maxScale: 4.0,
                                child: Image.memory(
                                  currentFile.bytes,
                                  fit: BoxFit.contain,
                                ),
                              ),
                              Positioned(
                                left: 10,
                                bottom: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xB3000000),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${currentFile.name} · ${currentFile.formattedSize}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 60,
                                    height: 60,
                                    decoration: BoxDecoration(
                                      color: tg.tgBlueBright.withValues(
                                        alpha: 0.18,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      currentFile.isVideo
                                          ? Icons.movie_creation_outlined
                                          : Icons.insert_drive_file_rounded,
                                      size: 32,
                                      color: tg.tgBlueBright,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    currentFile.name,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${currentFile.formattedSize} · ${currentFile.mimeType}',
                                    style: TextStyle(
                                      color: tg.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),

              // Multi-file selector strip
              if (_files.length > 1) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _files.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, idx) {
                      final f = _files[idx];
                      final selected = idx == _previewIdx;
                      return GestureDetector(
                        onTap: () => setState(() => _previewIdx = idx),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: tg.searchFill,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selected
                                  ? tg.tgBlueBright
                                  : Colors.transparent,
                              width: 1.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (f.isImage && f.bytes.isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.memory(
                                    f.bytes,
                                    width: 36,
                                    height: 36,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              else
                                Icon(
                                  Icons.insert_drive_file_outlined,
                                  size: 20,
                                  color: tg.tgBlueBright,
                                ),
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 96),
                                child: Text(
                                  f.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: tg.textPrimary,
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
              ],

              const SizedBox(height: 10),

              // Official Telegram "Send as photo/media" vs "Send as uncompressed file" toggle
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _asFile = !_asFile),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _asFile
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 19,
                        color: _asFile ? tg.tgBlueBright : tg.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '作为无损原文件发送 (不压缩图片画质，保持原始文件名)',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: tg.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // Caption input with quick emoji strip
              TextField(
                controller: _captionCtrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                maxLength: 1024,
                onSubmitted: (_) {
                  final files = List<TelegramOutgoingFile>.from(_files);
                  final caption = _captionCtrl.text.trim();
                  Navigator.of(context).pop();
                  widget.onSendNow(files, _asFile, caption);
                },
                style: TextStyle(fontSize: 13.5, color: tg.textPrimary),
                decoration: InputDecoration(
                  labelText: '添加说明文字 (可选)',
                  hintText: '输入说明文字或按 Enter 直接发送...',
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: ['👍', '😂', '❤️', '🔥', '🎉'].map((e) {
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          _captionCtrl.text = '${_captionCtrl.text}$e';
                          _captionCtrl.selection = TextSelection.collapsed(
                            offset: _captionCtrl.text.length,
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(e, style: const TextStyle(fontSize: 16)),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '取消',
                      style: TextStyle(color: tg.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      final files = List<TelegramOutgoingFile>.from(_files);
                      final caption = _captionCtrl.text;
                      Navigator.of(context).pop();
                      widget.onStageToBar(files, _asFile, caption);
                    },
                    icon: const Icon(Icons.playlist_add_rounded, size: 17),
                    label: const Text('加入待发栏继续编辑'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: tg.tgBlueBright,
                    ),
                    onPressed: () {
                      final files = List<TelegramOutgoingFile>.from(_files);
                      final caption = _captionCtrl.text.trim();
                      Navigator.of(context).pop();
                      widget.onSendNow(files, _asFile, caption);
                    },
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: Text(
                      _files.length > 1
                          ? '立即发送 (${_files.length} 个)'
                          : '立即发送',
                    ),
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

/// Interactive Region Cropper Screenshot Dialog (`📐 应用内框选区域截图`)
class _TelegramRegionCropDialog extends StatefulWidget {
  final Uint8List fullImageBytes;

  const _TelegramRegionCropDialog({required this.fullImageBytes});

  @override
  State<_TelegramRegionCropDialog> createState() =>
      _TelegramRegionCropDialogState();
}

class _TelegramRegionCropDialogState extends State<_TelegramRegionCropDialog> {
  Offset? _dragStart;
  Offset? _dragEnd;
  ui.Image? _decodedImage;
  final GlobalKey _imageBoxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.fullImageBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _decodedImage = frame.image);
    }
  }

  Rect? get _selectionRect {
    if (_dragStart == null || _dragEnd == null) return null;
    return Rect.fromPoints(_dragStart!, _dragEnd!);
  }

  Future<void> _finishCrop() async {
    final rect = _selectionRect;
    final img = _decodedImage;
    final box = _imageBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (rect == null ||
        rect.width < 12 ||
        rect.height < 12 ||
        img == null ||
        box == null) {
      Navigator.of(context).pop(widget.fullImageBytes);
      return;
    }

    try {
      final boxSize = box.size;
      final scaleX = img.width / boxSize.width;
      final scaleY = img.height / boxSize.height;
      final srcRect = Rect.fromLTWH(
        (rect.left * scaleX).clamp(0.0, img.width.toDouble() - 1),
        (rect.top * scaleY).clamp(0.0, img.height.toDouble() - 1),
        (rect.width * scaleX).clamp(1.0, img.width.toDouble()),
        (rect.height * scaleY).clamp(1.0, img.height.toDouble()),
      );

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final dstRect = Rect.fromLTWH(0, 0, srcRect.width, srcRect.height);
      canvas.drawImageRect(img, srcRect, dstRect, Paint());
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(
        srcRect.width.round(),
        srcRect.height.round(),
      );
      final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(byteData?.buffer.asUint8List() ?? widget.fullImageBytes);
    } catch (_) {
      if (mounted) {
        Navigator.of(context).pop(widget.fullImageBytes);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rect = _selectionRect;
    return Dialog.fullscreen(
      backgroundColor: Colors.black87,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: GestureDetector(
              onPanStart: (d) {
                setState(() {
                  _dragStart = d.localPosition;
                  _dragEnd = d.localPosition;
                });
              },
              onPanUpdate: (d) {
                setState(() => _dragEnd = d.localPosition);
              },
              child: Stack(
                key: _imageBoxKey,
                children: [
                  Image.memory(
                    widget.fullImageBytes,
                    fit: BoxFit.contain,
                  ),
                  if (rect != null)
                    Positioned.fromRect(
                      rect: rect,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0x263E99EE),
                          border: Border.all(
                            color: const Color(0xFF3E99EE),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Top floating instruction & action bar
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xD917212B),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.crop_free_rounded,
                      size: 18,
                      color: Color(0xFF5EB5F7),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      rect != null && rect.width > 12
                          ? '已框选区域 (${rect.width.round()} × ${rect.height.round()})'
                          : '按住鼠标左键拖动框选截图区域，或直接发送全窗口',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text(
                        '取消',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(width: 6),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF3E99EE),
                      ),
                      onPressed: _finishCrop,
                      icon: const Icon(Icons.check_rounded, size: 16),
                      label: Text(
                        rect != null && rect.width > 12
                            ? '完成框选并预览'
                            : '发送全窗口截图',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable circular Telegram peer/group/contact avatar supporting
/// progressive loading from `data:image/(jpeg|png|gif|webp);base64,...`
/// stripped thumbnails to crisp HD avatars (`/api/telegram/avatar`),
/// Saved Messages bookmark icon, and colored gradient initials fallback.
class _TelegramPeerAvatar extends StatefulWidget {
  static final Map<String, Uint8List> _decodedDataUriCache = {};
  static final Map<String, Uint8List> _hdAvatarBytesCache = {};
  static final Map<String, Future<Uint8List?>> _hdAvatarInFlight = {};
  static final Set<String> _hdAvatarFailedUrls = {};
  static final List<void Function()> _downloadQueue = [];
  static int _activeDownloads = 0;
  static const int _maxConcurrentDownloads = 4;

  final String peer;
  final String title;
  final String avatar;
  final String hdAvatarUrl;
  final bool isSelf;
  final double size;
  final double fontSize;
  final AppState? appState;

  const _TelegramPeerAvatar({
    required this.peer,
    required this.title,
    this.avatar = '',
    this.hdAvatarUrl = '',
    this.isSelf = false,
    this.size = 48,
    this.fontSize = 17,
    this.appState,
  });

  static Uint8List? _decodeDataUri(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('data:image/')) return null;
    final cached = _decodedDataUriCache[trimmed];
    if (cached != null) return cached;
    final commaIdx = trimmed.indexOf(',');
    if (commaIdx <= 0 || commaIdx >= trimmed.length - 1) return null;
    try {
      final b64 = trimmed.substring(commaIdx + 1).replaceAll(RegExp(r'\s+'), '');
      final bytes = base64Decode(base64.normalize(b64));
      if (bytes.isEmpty) return null;
      if (_decodedDataUriCache.length > 600) {
        _decodedDataUriCache.remove(_decodedDataUriCache.keys.first);
      }
      _decodedDataUriCache[trimmed] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _fetchHdAvatarBytes(
    AppState appState,
    String hdUrl,
  ) {
    final cached = _hdAvatarBytesCache[hdUrl];
    if (cached != null) return Future.value(cached);
    if (_hdAvatarFailedUrls.contains(hdUrl)) return Future.value(null);
    final inflight = _hdAvatarInFlight[hdUrl];
    if (inflight != null) return inflight;

    final completer = Completer<Uint8List?>();
    final future = completer.future;
    _hdAvatarInFlight[hdUrl] = future;

    void startDownload() async {
      _activeDownloads++;
      try {
        final bytes = await appState.api
            .downloadTelegramBytes(hdUrl)
            .timeout(const Duration(seconds: 20));
        if (bytes.isNotEmpty) {
          if (_hdAvatarBytesCache.length > 400) {
            _hdAvatarBytesCache.remove(_hdAvatarBytesCache.keys.first);
          }
          _hdAvatarBytesCache[hdUrl] = bytes;
          completer.complete(bytes);
        } else {
          _hdAvatarFailedUrls.add(hdUrl);
          completer.complete(null);
        }
      } catch (_) {
        _hdAvatarFailedUrls.add(hdUrl);
        completer.complete(null);
      } finally {
        _hdAvatarInFlight.remove(hdUrl);
        _activeDownloads--;
        if (_downloadQueue.isNotEmpty &&
            _activeDownloads < _maxConcurrentDownloads) {
          final next = _downloadQueue.removeAt(0);
          next();
        }
      }
    }

    if (_activeDownloads < _maxConcurrentDownloads) {
      startDownload();
    } else {
      _downloadQueue.add(startDownload);
    }

    return future;
  }

  @override
  State<_TelegramPeerAvatar> createState() => _TelegramPeerAvatarState();
}

class _TelegramPeerAvatarState extends State<_TelegramPeerAvatar> {
  Uint8List? _hdBytes;

  @override
  void initState() {
    super.initState();
    _syncHdAvatar();
  }

  @override
  void didUpdateWidget(covariant _TelegramPeerAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hdAvatarUrl != widget.hdAvatarUrl ||
        oldWidget.appState != widget.appState) {
      _syncHdAvatar();
    }
  }

  void _syncHdAvatar() {
    final hdUrl = widget.hdAvatarUrl.trim();
    if (hdUrl.isEmpty || widget.appState == null) {
      _hdBytes = null;
      return;
    }
    final cached = _TelegramPeerAvatar._hdAvatarBytesCache[hdUrl];
    if (cached != null) {
      _hdBytes = cached;
      return;
    }
    _hdBytes = null;
    _TelegramPeerAvatar._fetchHdAvatarBytes(widget.appState!, hdUrl).then((
      bytes,
    ) {
      if (!mounted || widget.hdAvatarUrl.trim() != hdUrl) return;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() {
          _hdBytes = bytes;
        });
      }
    });
  }

  String _computeInitials() {
    final clean = widget.title.trim();
    if (clean.isEmpty) return '#';
    final chars = clean.characters.toList();
    if (chars.length >= 2 &&
        RegExp(r'^[a-zA-Z0-9]+$').hasMatch(chars[0] + chars[1])) {
      return (chars[0] + chars[1]).toUpperCase();
    }
    return chars.first.toUpperCase();
  }

  Widget _buildFallbackContent() {
    if (widget.isSelf) {
      return Icon(
        Icons.bookmark_rounded,
        size: widget.size * 0.52,
        color: Colors.white,
      );
    }
    return Text(
      _computeInitials(),
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final colors = widget.isSelf
        ? const [Color(0xFF42ADE8), Color(0xFF2288CC)]
        : _TgPalette.peerAvatarColors(
            widget.peer.isEmpty ? widget.title : widget.peer,
          );
    final rawAvatar = widget.avatar.trim();
    final previewBytes = rawAvatar.isNotEmpty
        ? _TelegramPeerAvatar._decodeDataUri(rawAvatar)
        : null;
    final activeMemoryBytes = _hdBytes ?? previewBytes;

    String networkUrl = '';
    if (activeMemoryBytes == null && rawAvatar.isNotEmpty) {
      if (rawAvatar.startsWith('http://') || rawAvatar.startsWith('https://')) {
        networkUrl = rawAvatar;
      } else if (rawAvatar.startsWith('/') && widget.appState != null) {
        final base = widget.appState!.serverConfig.normalizedBaseUrl;
        if (base.isNotEmpty) {
          networkUrl = '$base$rawAvatar';
        }
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: activeMemoryBytes != null
          ? Image.memory(
              activeMemoryBytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, __, ___) => previewBytes != null &&
                      !identical(activeMemoryBytes, previewBytes)
                  ? Image.memory(
                      previewBytes,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, __, ___) => _buildFallbackContent(),
                    )
                  : _buildFallbackContent(),
            )
          : (networkUrl.isNotEmpty
                ? Image.network(
                    networkUrl,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    headers: widget.appState?.api.authHeaders,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => _buildFallbackContent(),
                  )
                : _buildFallbackContent()),
    );
  }
}

/// Official Telegram "Forward Messages To..." Chat Picker Dialog
class _TelegramForwardDialog extends StatefulWidget {
  final AppState appState;
  final String accountId;
  final List<TelegramChat> chats;

  const _TelegramForwardDialog({
    required this.appState,
    required this.accountId,
    required this.chats,
  });

  @override
  State<_TelegramForwardDialog> createState() => _TelegramForwardDialogState();
}

class _TelegramForwardDialogState extends State<_TelegramForwardDialog> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final tg = _TgPalette(VideoPlatformTheme.isDark);
    final kw = _filter.trim().toLowerCase();
    final filtered = widget.chats.where((c) {
      if (kw.isEmpty) return true;
      return c.title.toLowerCase().contains(kw) ||
          c.kind.toLowerCase().contains(kw);
    }).toList();

    return Dialog(
      backgroundColor: tg.sidebarBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 540),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.forward_rounded, size: 20, color: tg.tgBlueBright),
                  const SizedBox(width: 8),
                  Text(
                    '转发消息到...',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: tg.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: tg.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _filter = v),
                style: TextStyle(fontSize: 13, color: tg.textPrimary),
                decoration: InputDecoration(
                  hintText: '搜索目标会话或收藏夹...',
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: tg.textMuted,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          '没有找到可发言的会话',
                          style: TextStyle(fontSize: 13, color: tg.textMuted),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, idx) {
                          final c = filtered[idx];
                          final isSelf =
                              c.self ||
                              c.peer.startsWith('self') ||
                              c.title.contains('收藏');
                          return ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            leading: _TelegramPeerAvatar(
                              peer: c.peer,
                              title: c.title,
                              avatar: c.avatar,
                              hdAvatarUrl: c.hasSharpAvatar
                                  ? widget.appState.api.buildTelegramAvatarUrl(
                                      accountId: widget.accountId,
                                      peer: c.peer,
                                      photoId: c.avatarPhotoId,
                                      dcId: c.avatarDcId,
                                    )
                                  : '',
                              isSelf: isSelf,
                              size: 40,
                              fontSize: 14,
                              appState: widget.appState,
                            ),
                            title: Text(
                              c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: tg.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              c.kind.isNotEmpty ? c.kind : c.peer,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: tg.textSecondary,
                              ),
                            ),
                            onTap: () => Navigator.of(context).pop(c),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Official Telegram Inline File Preview Dialog (`/api/telegram/file-preview`)
class _TelegramFilePreviewDialog extends StatefulWidget {
  final AppState appState;
  final String accountId;
  final String peer;
  final int messageId;
  final TelegramAttachment attachment;

  const _TelegramFilePreviewDialog({
    required this.appState,
    required this.accountId,
    required this.peer,
    required this.messageId,
    required this.attachment,
  });

  @override
  State<_TelegramFilePreviewDialog> createState() =>
      _TelegramFilePreviewDialogState();
}

class _TelegramFilePreviewDialogState
    extends State<_TelegramFilePreviewDialog> {
  TelegramFilePreview? _preview;
  bool _isLoading = true;
  String? _error;
  String? _activeEntry;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview({String? entry}) async {
    setState(() {
      _isLoading = true;
      _error = null;
      _activeEntry = entry;
    });
    try {
      final data = await widget.appState.api.fetchTelegramFilePreview(
        accountId: widget.accountId,
        peer: widget.peer,
        messageId: widget.messageId,
        entry: entry,
      );
      if (!mounted) return;
      setState(() {
        _preview = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = _TgPalette(VideoPlatformTheme.isDark);
    final p = _preview;

    return Dialog(
      backgroundColor: tg.sidebarBg,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (_activeEntry != null)
                    IconButton(
                      onPressed: () => _loadPreview(entry: null),
                      icon: Icon(
                        Icons.arrow_back_rounded,
                        size: 18,
                        color: tg.tgBlueBright,
                      ),
                    ),
                  Icon(
                    Icons.description_outlined,
                    size: 20,
                    color: tg.tgBlueBright,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p?.name ?? widget.attachment.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: tg.textPrimary,
                      ),
                    ),
                  ),
                  if (p != null && p.text.isNotEmpty)
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: p.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制文件内容到剪贴板')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 15),
                      label: const Text('复制全文'),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: tg.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tg.chatWallpaperBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tg.borderLine),
                  ),
                  child: _isLoading
                      ? Center(
                          child: CircularProgressIndicator(
                            color: tg.tgBlueBright,
                          ),
                        )
                      : _error != null
                          ? Center(
                              child: Text(
                                '预览加载失败：$_error',
                                style: TextStyle(color: VideoPlatformTheme.danger),
                              ),
                            )
                          : (p != null && p.entries.isNotEmpty)
                              ? ListView.builder(
                                  itemCount: p.entries.length,
                                  itemBuilder: (_, idx) {
                                    final entryName = p.entries[idx];
                                    return ListTile(
                                      dense: true,
                                      leading: Icon(
                                        Icons.insert_drive_file_outlined,
                                        size: 18,
                                        color: tg.tgBlueBright,
                                      ),
                                      title: Text(
                                        entryName,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: tg.textPrimary,
                                        ),
                                      ),
                                      onTap: () =>
                                          _loadPreview(entry: entryName),
                                    );
                                  },
                                )
                              : SingleChildScrollView(
                                  child: Text(
                                    (p?.text.isNotEmpty ?? false)
                                        ? p!.text
                                        : '（文件内容为空或为二进制文件，请下载到本地查看）',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12.5,
                                      height: 1.45,
                                      color: tg.textPrimary,
                                    ),
                                  ),
                                ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Built-in cross-platform local file browser fallback dialog
class _LocalFilePickerFallbackDialog extends StatefulWidget {
  final bool mediaOnly;

  const _LocalFilePickerFallbackDialog({required this.mediaOnly});

  @override
  State<_LocalFilePickerFallbackDialog> createState() =>
      _LocalFilePickerFallbackDialogState();
}

class _LocalFilePickerFallbackDialogState
    extends State<_LocalFilePickerFallbackDialog> {
  late final TextEditingController _dirCtrl;
  List<FileSystemEntity> _entries = [];
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    _dirCtrl = TextEditingController(text: home);
    _listDirectory(home);
  }

  @override
  void dispose() {
    _dirCtrl.dispose();
    super.dispose();
  }

  void _listDirectory(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      final list = dir.listSync()
        ..sort((a, b) {
          final aDir = a is Directory ? 0 : 1;
          final bDir = b is Directory ? 0 : 1;
          if (aDir != bDir) return aDir.compareTo(bDir);
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });
      setState(() {
        _dirCtrl.text = dir.path;
        _entries = list.where((e) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) return false;
          if (e is Directory) return true;
          if (!widget.mediaOnly) return true;
          final lower = name.toLowerCase();
          return lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.gif') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.mp4') ||
              lower.endsWith('.mkv') ||
              lower.endsWith('.mov');
        }).toList();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final tg = _TgPalette(VideoPlatformTheme.isDark);
    return Dialog(
      backgroundColor: tg.sidebarBg,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 540),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 20,
                    color: tg.tgBlueBright,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.mediaOnly ? '选择本地图片或视频' : '选择本地文件发送',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: tg.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: tg.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    onPressed: () {
                      final parent = Directory(_dirCtrl.text).parent.path;
                      _listDirectory(parent);
                    },
                    icon: Icon(
                      Icons.arrow_upward_rounded,
                      size: 18,
                      color: tg.textSecondary,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _dirCtrl,
                      onSubmitted: _listDirectory,
                      style: TextStyle(fontSize: 12.5, color: tg.textPrimary),
                      decoration: const InputDecoration(
                        labelText: '当前目录路径 (也可以直接粘贴完整文件路径)',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (_, idx) {
                    final e = _entries[idx];
                    final isDir = e is Directory;
                    final name = e.path.split(Platform.pathSeparator).last;
                    final checked = _selectedPaths.contains(e.path);
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isDir
                            ? Icons.folder_rounded
                            : Icons.insert_drive_file_outlined,
                        color: isDir ? const Color(0xFFFFB74D) : tg.tgBlueBright,
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: tg.textPrimary),
                      ),
                      trailing: isDir
                          ? null
                          : Checkbox(
                              value: checked,
                              onChanged: (_) {
                                setState(() {
                                  if (checked) {
                                    _selectedPaths.remove(e.path);
                                  } else if (_selectedPaths.length < 10) {
                                    _selectedPaths.add(e.path);
                                  }
                                });
                              },
                            ),
                      onTap: () {
                        if (isDir) {
                          _listDirectory(e.path);
                        } else {
                          setState(() {
                            if (checked) {
                              _selectedPaths.remove(e.path);
                            } else if (_selectedPaths.length < 10) {
                              _selectedPaths.add(e.path);
                            }
                          });
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: tg.tgBlueBright,
                    ),
                    onPressed: () {
                      if (_selectedPaths.isNotEmpty) {
                        Navigator.of(context).pop(_selectedPaths.toList());
                      } else if (File(_dirCtrl.text.trim()).existsSync()) {
                        Navigator.of(context).pop([_dirCtrl.text.trim()]);
                      }
                    },
                    child: Text('确定选择 (${_selectedPaths.length})'),
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

/// Lightweight video preview placeholder when `/api/telegram/thumbnail` returns 404/error
class _TelegramVideoFrameFallback extends StatelessWidget {
  final String streamUrl;
  final Map<String, String> headers;
  final Color fallbackIconColor;

  const _TelegramVideoFrameFallback({
    required this.streamUrl,
    required this.headers,
    required this.fallbackIconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF13202E),
            Color(0xFF0A121A),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.movie_creation_outlined,
        size: 32,
        color: fallbackIconColor,
      ),
    );
  }
}

/// Official Telegram Album Mosaic Grid Tile supporting both Photos and Videos
/// (with video thumbnail/first-frame preview, inline cell playback, PiP mini-player, and unified gallery viewer)
class _TelegramAlbumMediaTile extends StatefulWidget {
  final AppState appState;
  final ValueNotifier<Object?> inlinePlaybackOwner;
  final String accountId;
  final TelegramChat chat;
  final TelegramMessage message;
  final _TgPalette tg;
  final bool selectionMode;
  final bool isSelected;
  final bool isQueueing;
  final bool isQueued;
  final bool isFailed;
  final bool isSavingLocal;
  final bool isSavedLocal;
  final String durationText;
  final VoidCallback onToggleSelect;
  final VoidCallback onOpenGallery;
  final ValueChanged<int> onOpenMiniPlayer;
  final VoidCallback onSaveLocal;
  final VoidCallback? onQueueDownload;
  final ValueChanged<Offset> onShowContextMenu;

  const _TelegramAlbumMediaTile({
    super.key,
    required this.appState,
    required this.inlinePlaybackOwner,
    required this.accountId,
    required this.chat,
    required this.message,
    required this.tg,
    required this.selectionMode,
    required this.isSelected,
    this.isQueueing = false,
    required this.isQueued,
    this.isFailed = false,
    this.isSavingLocal = false,
    this.isSavedLocal = false,
    required this.durationText,
    required this.onToggleSelect,
    required this.onOpenGallery,
    required this.onOpenMiniPlayer,
    required this.onSaveLocal,
    this.onQueueDownload,
    required this.onShowContextMenu,
  });

  @override
  State<_TelegramAlbumMediaTile> createState() =>
      _TelegramAlbumMediaTileState();
}

class _TelegramAlbumMediaTileState extends State<_TelegramAlbumMediaTile>
    with AutomaticKeepAliveClientMixin {
  final _inlinePlaybackToken = Object();
  Player? _inlinePlayer;
  VideoController? _inlineController;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _completedSub;

  bool _isInlineMode = false;
  bool _isPlaying = false;
  bool _userPaused = false;
  bool _isMuted = false;
  double _volume = 100.0;
  double _preMuteVolume = 100.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _pendingResumeSeconds = 0;
  DateTime? _lastInlinePosUiUpdateAt;
  String _lastInlineRouteSignature = '';

  String _computeInlineRouteSignature() {
    final svc = widget.appState.proxyService;
    final effective = svc.resolveEffectiveRoute(RequestScenario.telegram);
    final nodeId = effective == ScenarioRouteMode.proxyNode
        ? (svc.resolveNodeForScenario(RequestScenario.telegram)?.id ?? '')
        : '';
    return '${svc.proxyEnabled}|${effective.name}|$nodeId';
  }

  void _onInlineProxyServiceChanged() {
    if (!mounted) return;
    final nextSig = _computeInlineRouteSignature();
    if (nextSig == _lastInlineRouteSignature) return;
    _lastInlineRouteSignature = nextSig;
    final p = _inlinePlayer;
    if (!_isInlineMode || p == null) return;
    unawaited(_reopenInlinePlayerOnProxyChange(p));
  }

  Future<void> _reopenInlinePlayerOnProxyChange(Player p) async {
    final rawStreamUrl = widget.appState.api.buildTelegramVideoStreamUrl(
      accountId: widget.accountId,
      peer: widget.chat.peer,
      messageId: widget.message.id,
    );
    final streamUrl = await widget.appState.proxyService.resolveProxiedStreamUrl(
      RequestScenario.telegram,
      rawStreamUrl,
      headers: widget.appState.api.authHeaders,
    );
    if (!mounted || _inlinePlayer != p) return;
    final usingLocalRelay = streamUrl.contains('/__m3u8_proxy__/');
    final resumeSec = _position.inSeconds;
    if (resumeSec > 2) {
      _pendingResumeSeconds = resumeSec;
    }
    await p.open(
      Media(
        streamUrl,
        httpHeaders:
            usingLocalRelay ? const {} : widget.appState.api.authHeaders,
        start: resumeSec > 2 ? Duration(seconds: resumeSec) : null,
      ),
      play: !_userPaused,
    );
  }

  @override
  bool get wantKeepAlive => _isInlineMode;

  @override
  void initState() {
    super.initState();
    _lastInlineRouteSignature = _computeInlineRouteSignature();
    widget.appState.proxyService.addListener(_onInlineProxyServiceChanged);
    widget.inlinePlaybackOwner.addListener(_onInlinePlaybackOwnerChanged);
  }

  @override
  void dispose() {
    widget.appState.proxyService.removeListener(_onInlineProxyServiceChanged);
    widget.inlinePlaybackOwner.removeListener(_onInlinePlaybackOwnerChanged);
    _disposeInlinePlayer();
    super.dispose();
  }

  void _onInlinePlaybackOwnerChanged() {
    if (_inlinePlayer == null ||
        identical(widget.inlinePlaybackOwner.value, _inlinePlaybackToken)) {
      return;
    }
    _pendingResumeSeconds = _position.inSeconds;
    _disposeInlinePlayer();
    setState(() {
      _isInlineMode = false;
      _isPlaying = false;
    });
    updateKeepAlive();
  }

  void _disposeInlinePlayer() {
    _playingSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _playingSub = null;
    _posSub = null;
    _durSub = null;
    _completedSub = null;
    _inlinePlayer?.dispose();
    _inlinePlayer = null;
    _inlineController = null;
  }

  Future<void> _configureTelegramPlayer(Player p) async {
    try {
      final dynamic platform = p.platform;
      final isMobileOrTv = Platform.isAndroid || Platform.isIOS;
      final props = <String, String>{
        'hwdec': Platform.isAndroid ? 'mediacodec-copy' : 'auto-safe',
        'hwdec-codecs': 'h264,hevc,vp8,vp9,av1',
        'vd-lavc-check-hw-profile': 'yes',
        'vd-lavc-software-fallback': 'yes',
        'vd-lavc-dr': 'yes',
        'vd-lavc-fast': 'yes',
        'vd-lavc-skiploopfilter': 'nonref',
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': isMobileOrTv ? '90' : '120',
        'cache-pause': 'yes',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '2.5',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': isMobileOrTv ? '100663296' : '134217728',
        'demuxer-max-back-bytes': isMobileOrTv ? '25165824' : '33554432',
        'demuxer-readahead-secs': isMobileOrTv ? '60' : '90',
        'stream-buffer-size': '2097152',
        'demuxer-lavf-probesize': '131072',
        'framedrop': 'vo',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        'network-timeout': '20',
        'tls-verify': 'no',
        'keep-open': 'no',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=5',
        'demuxer-lavf-o':
            'http_persistent=1,http_multiple=1,allowed_extensions=ALL',
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (_) {}
  }

  Future<void> _toggleInlinePlay() async {
    final att = widget.message.attachment;
    if (att == null || !att.isVideo) return;

    if (!_isInlineMode || _inlinePlayer == null) {
      if (_inlinePlayer != null) return;
      widget.inlinePlaybackOwner.value = _inlinePlaybackToken;
      final p = Player(
        configuration: PlayerConfiguration(
          bufferSize: (Platform.isAndroid || Platform.isIOS)
              ? 48 * 1024 * 1024
              : 64 * 1024 * 1024,
        ),
      );
      final c = VideoController(
        p,
        configuration: VideoControllerConfiguration(
          hwdec: Platform.isAndroid ? 'mediacodec-copy' : null,
          enableHardwareAcceleration: true,
        ),
      );
      _inlinePlayer = p;
      _inlineController = c;
      _userPaused = false;
      if (att.duration > 0) {
        _duration = Duration(seconds: att.duration);
      }
      final rawStreamUrl = widget.appState.api.buildTelegramVideoStreamUrl(
        accountId: widget.accountId,
        peer: widget.chat.peer,
        messageId: widget.message.id,
      );
      final streamUrl =
          await widget.appState.proxyService.resolveProxiedStreamUrl(
        RequestScenario.telegram,
        rawStreamUrl,
        headers: widget.appState.api.authHeaders,
      );
      if (!mounted || _inlinePlayer != p) return;
      final usingLocalRelay = streamUrl.contains('/__m3u8_proxy__/');
      var retriedPrematureEnd = false;
      _playingSub = p.stream.playing.listen((playing) {
        if (playing) {
          unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
        }
        if (mounted) setState(() => _isPlaying = playing);
      });
      _posSub = p.stream.position.listen((pos) {
        if (!mounted) return;
        if (pos > Duration.zero) {
          final now = DateTime.now();
          if (_lastInlinePosUiUpdateAt == null ||
              now.difference(_lastInlinePosUiUpdateAt!) >=
                  const Duration(milliseconds: 250)) {
            _lastInlinePosUiUpdateAt = now;
            setState(() => _position = pos);
          } else {
            _position = pos;
          }
        }
        if (_pendingResumeSeconds > 2 && _duration.inSeconds > 0) {
          final target = _pendingResumeSeconds;
          _pendingResumeSeconds = 0;
          if (target < _duration.inSeconds - 3) {
            p.seek(Duration(seconds: target));
          }
        }
      });
      _durSub = p.stream.duration.listen((dur) {
        if (dur > Duration.zero && mounted) {
          setState(() => _duration = dur);
        }
      });
      _completedSub = p.stream.completed.listen((completed) {
        if (!completed || !mounted || _inlinePlayer != p || _userPaused) {
          return;
        }
        final durSec = _duration.inSeconds;
        final posSec = _position.inSeconds;
        final isPrematureEof =
            durSec <= 0 || (durSec > 6 && posSec > 1 && posSec < durSec - 4);
        if (isPrematureEof && !retriedPrematureEnd) {
          retriedPrematureEnd = true;
          _pendingResumeSeconds = posSec;
          unawaited(
            p.open(
              Media(
                streamUrl,
                httpHeaders:
                    usingLocalRelay ? const {} : widget.appState.api.authHeaders,
              ),
              play: true,
            ),
          );
        } else {
          if (!isPrematureEof) _position = Duration.zero;
          widget.inlinePlaybackOwner.value = null;
        }
      });
      setState(() {
        _isInlineMode = true;
        _isPlaying = true;
      });
      updateKeepAlive();
      await _configureTelegramPlayer(p);
      if (!mounted || _inlinePlayer != p) return;
      await p.setVolume(_isMuted ? 0 : _volume);
      if (!mounted || _inlinePlayer != p) return;
      unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
      await p.open(
        Media(
          streamUrl,
          httpHeaders:
              usingLocalRelay ? const {} : widget.appState.api.authHeaders,
        ),
        play: true,
      );
      return;
    }

    _userPaused = _inlinePlayer!.state.playing;
    await _inlinePlayer!.playOrPause();
  }

  Future<void> _toggleMute() async {
    if (_inlinePlayer == null) return;
    if (_isMuted || _volume <= 0) {
      final restored = _preMuteVolume > 5 ? _preMuteVolume : 100.0;
      setState(() {
        _isMuted = false;
        _volume = restored;
      });
      await _inlinePlayer!.setVolume(restored);
    } else {
      _preMuteVolume = _volume;
      setState(() {
        _isMuted = true;
        _volume = 0;
      });
      await _inlinePlayer!.setVolume(0);
    }
  }

  Future<void> _setInlineVolume(double val) async {
    final clamped = val.clamp(0.0, 100.0);
    if (clamped > 0) _preMuteVolume = clamped;
    setState(() {
      _volume = clamped;
      _isMuted = clamped <= 0;
    });
    await _inlinePlayer?.setVolume(clamped);
  }

  bool _isInlineHorizontalSeeking = false;
  Duration _inlineSeekStartPos = Duration.zero;
  Duration _inlineSeekPreviewPos = Duration.zero;
  bool _isTileFocused = false;

  String _fmtInlineClock(Duration d) {
    final total = d.inSeconds;
    if (total <= 0) return '00:00';
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final att = widget.message.attachment;
    final isVideo = att?.isVideo ?? false;
    final thumbUrl = widget.appState.api.buildTelegramThumbnailUrl(
      accountId: widget.accountId,
      peer: widget.chat.peer,
      messageId: widget.message.id,
    );
    final streamUrl = isVideo
        ? widget.appState.api.buildTelegramVideoStreamUrl(
            accountId: widget.accountId,
            peer: widget.chat.peer,
            messageId: widget.message.id,
          )
        : '';

    final totalMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 1;
    final activePos =
        _isInlineHorizontalSeeking ? _inlineSeekPreviewPos : _position;
    final progress = (activePos.inMilliseconds / totalMs).clamp(0.0, 1.0);

    return Focus(
      onFocusChange: (focused) {
        if (mounted && _isTileFocused != focused) {
          setState(() => _isTileFocused = focused);
        }
      },
      onKeyEvent: (node, event) {
        if (!node.hasPrimaryFocus) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          if (widget.selectionMode) {
            widget.onToggleSelect();
          } else {
            if (_isInlineMode && _inlinePlayer != null) {
              _inlinePlayer!.pause();
            }
            widget.onOpenGallery();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () {
          if (widget.selectionMode) {
            widget.onToggleSelect();
            return;
          }
          if (_isInlineMode && _inlinePlayer != null) {
            _inlinePlayer!.pause();
          }
          widget.onOpenGallery();
        },
        onHorizontalDragStart: (isVideo && _isInlineMode && _inlinePlayer != null)
            ? (details) {
                if (details.globalPosition.dx <= 40.0) return;
                setState(() {
                  _isInlineHorizontalSeeking = true;
                  _inlineSeekStartPos = _position;
                  _inlineSeekPreviewPos = _position;
                });
              }
            : null,
        onHorizontalDragUpdate: (isVideo && _isInlineMode && _inlinePlayer != null)
            ? (details) {
                if (!_isInlineHorizontalSeeking) return;
                final boxWidth = context.size?.width ?? 220.0;
                final maxSec = _duration.inSeconds > 0
                    ? _duration.inSeconds
                    : (att?.duration != null && att!.duration > 0
                        ? att.duration
                        : 120);
                final spanSec = maxSec.clamp(30, 180);
                final deltaMs =
                    ((details.delta.dx / boxWidth) * spanSec * 1000).round();
                final nextMs = (_inlineSeekPreviewPos.inMilliseconds + deltaMs)
                    .clamp(0, maxSec * 1000);
                setState(() {
                  _inlineSeekPreviewPos = Duration(milliseconds: nextMs);
                });
              }
            : null,
        onHorizontalDragEnd: (isVideo && _isInlineMode && _inlinePlayer != null)
            ? (_) {
                if (!_isInlineHorizontalSeeking) return;
                final target = _inlineSeekPreviewPos;
                setState(() {
                  _isInlineHorizontalSeeking = false;
                  _position = target;
                });
                _inlinePlayer?.seek(target);
              }
            : null,
        onSecondaryTapDown: (d) => widget.onShowContextMenu(d.globalPosition),
        onLongPressStart: (d) => widget.onShowContextMenu(d.globalPosition),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: _isTileFocused
                ? Border.all(
                    color: const Color(0xFFFFE066),
                    width: 2.6,
                  )
                : null,
            boxShadow: _isTileFocused
                ? [
                    BoxShadow(
                      color: widget.tg.tgBlueBright.withValues(alpha: 0.65),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Base visual layer: Inline video player OR Thumbnail + Video first-frame fallback
            if (isVideo && _isInlineMode && _inlineController != null)
              Video(
                controller: _inlineController!,
                fit: BoxFit.cover,
                fill: Colors.black,
                controls: NoVideoControls,
              )
            else if (!isVideo ||
                (att != null &&
                    (att.hasThumbnail || att.thumbnail.isNotEmpty)))
              Image.network(
                thumbUrl,
                headers: widget.appState.api.authHeaders,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => isVideo
                    ? _TelegramVideoFrameFallback(
                        streamUrl: streamUrl,
                        headers: widget.appState.api.authHeaders,
                        fallbackIconColor: widget.tg.textMuted,
                      )
                    : Container(
                        color: const Color(0xFF101923),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.image_outlined,
                          size: 28,
                          color: widget.tg.textMuted,
                        ),
                      ),
              )
            else
              _TelegramVideoFrameFallback(
                streamUrl: streamUrl,
                headers: widget.appState.api.authHeaders,
                fallbackIconColor: widget.tg.textMuted,
              ),

            // 2. Top-left Official Telegram Video Duration + File Size Pill
            if (isVideo)
              Positioned(
                top: 5,
                left: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.videocam_rounded,
                        size: 11,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        [
                          if (widget.durationText.isNotEmpty &&
                              widget.durationText != '00:00')
                            widget.durationText
                          else
                            '视频',
                          if (att != null && att.formattedSize.isNotEmpty)
                            att.formattedSize,
                        ].join(' · '),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 3. Top-right quick controls for Video Tile (Inline Play/Pause + Mute + PiP Mini-Player)
            if (isVideo && !widget.selectionMode)
              Positioned(
                top: 5,
                right: 5,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isInlineMode && _inlinePlayer != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: VideoDownloadSpeedBadge(
                          player: _inlinePlayer!,
                          compact: true,
                        ),
                      ),
                    if (_isInlineMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xCC000000),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                onTap: _toggleMute,
                                child: Icon(
                                  _isMuted || _volume <= 0
                                      ? Icons.volume_off_rounded
                                      : (_volume < 50
                                          ? Icons.volume_down_rounded
                                          : Icons.volume_up_rounded),
                                  size: 13,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(
                                width: 52,
                                height: 16,
                                child: ExcludeFocus(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2.2,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 4.5,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 8,
                                      ),
                                      activeTrackColor: widget.tg.tgBlueBright,
                                      inactiveTrackColor: Colors.white30,
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: _isMuted ? 0 : _volume,
                                      min: 0,
                                      max: 100,
                                      onChanged: _setInlineVolume,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    InkWell(
                      onTap: _toggleInlinePlay,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _isInlineMode
                              ? widget.tg.tgBlueBright
                              : const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isInlineMode && _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_circle_outline_rounded,
                              size: 12,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _isInlineMode
                                  ? (_isPlaying ? '暂停' : '播放')
                                  : '内嵌播',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () {
                        final posSec = _position.inSeconds;
                        _inlinePlayer?.pause();
                        widget.onOpenMiniPlayer(posSec);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xB3000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.picture_in_picture_alt_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // 4. Selection checkbox when in multi-select mode
            if (widget.selectionMode)
              Positioned(
                top: 6,
                right: 6,
                child: Icon(
                  widget.isSelected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: widget.isSelected
                      ? widget.tg.tgBlueBright
                      : Colors.white,
                ),
              ),

            // 5. Center Official Telegram Play Button (when not actively playing inline) or Seek HUD
            if (isVideo && _isInlineHorizontalSeeking)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC000000),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Text(
                    '${_inlineSeekPreviewPos >= _inlineSeekStartPos ? '⏩' : '⏪'} ${_fmtInlineClock(_inlineSeekPreviewPos)} / ${_fmtInlineClock(_duration)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
            else if (isVideo && !(_isInlineMode && _isPlaying))
              Center(
                child: Container(
                  width: _isTileFocused ? 46 : 42,
                  height: _isTileFocused ? 46 : 42,
                  decoration: BoxDecoration(
                    color: _isTileFocused
                        ? widget.tg.tgBlueBright
                        : const Color(0xA6000000),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _isTileFocused
                          ? const Color(0xFFFFE066)
                          : Colors.white38,
                      width: _isTileFocused ? 2.0 : 1.2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),

            // 6. Bottom quick action bar (Save local / Queue server download) + inline progress bar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 12, 5, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Color(0xC6000000),
                          Color(0x00000000),
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            att?.displayName ?? (isVideo ? '视频' : '图片'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: widget.isSavingLocal
                              ? null
                              : widget.onSaveLocal,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: widget.isSavedLocal
                                  ? const Color(0xCC2EBE70)
                                  : const Color(0x80000000),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              transitionBuilder: (child, anim) =>
                                  ScaleTransition(scale: anim, child: child),
                              child: widget.isSavingLocal
                                  ? const SizedBox(
                                      key: ValueKey('tile_l_spin'),
                                      width: 11,
                                      height: 11,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.6,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
                                      key: ValueKey(
                                        'tile_l_${widget.isSavedLocal}',
                                      ),
                                      widget.isSavedLocal
                                          ? Icons.check_circle_rounded
                                          : Icons.download_rounded,
                                      size: 12,
                                      color: Colors.white,
                                    ),
                            ),
                          ),
                        ),
                        if (widget.onQueueDownload != null) ...[
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: widget.isQueueing
                                ? null
                                : widget.onQueueDownload,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: widget.isQueued
                                    ? const Color(0xE62EBE70)
                                    : (widget.isFailed
                                        ? const Color(0xE6E54D42)
                                        : const Color(0xB31E88E5)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                transitionBuilder: (child, anim) =>
                                    ScaleTransition(
                                      scale: anim,
                                      child: child,
                                    ),
                                child: widget.isQueueing
                                    ? const SizedBox(
                                        key: ValueKey('tile_q_spin'),
                                        width: 11,
                                        height: 11,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.6,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Row(
                                        key: ValueKey(
                                          'tile_q_${widget.isQueued}_${widget.isFailed}',
                                        ),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            widget.isQueued
                                                ? Icons.check_circle_rounded
                                                : (widget.isFailed
                                                    ? Icons
                                                        .error_outline_rounded
                                                    : Icons
                                                        .cloud_download_outlined),
                                            size: 12,
                                            color: Colors.white,
                                          ),
                                          if (widget.isQueued ||
                                              widget.isFailed) ...[
                                            const SizedBox(width: 2),
                                            Text(
                                              widget.isQueued ? '已入队' : '重试',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isVideo && _isInlineMode)
                    SizedBox(
                      height: 16,
                      child: ExcludeFocus(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3.0,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5.0,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 9.0,
                            ),
                            activeTrackColor: widget.tg.tgBlueBright,
                            inactiveTrackColor: Colors.white30,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            value: progress,
                            min: 0.0,
                            max: 1.0,
                            onChanged: (val) {
                              final maxMs = _duration.inMilliseconds > 0
                                  ? _duration.inMilliseconds
                                  : ((att?.duration ?? 0) * 1000);
                              if (maxMs > 0) {
                                final target =
                                    Duration(milliseconds: (val * maxMs).round());
                                setState(() => _position = target);
                                _inlinePlayer?.seek(target);
                              }
                            },
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
        ),
      ),
    );
  }
}

/// Official Telegram Unified Multimedia Album & Chat Gallery Lightbox (`photo` + `video`)
/// with `←` / `→` / `Space` keyboard controls, inline `media_kit` video player, album thumbnail strip & PiP handoff
class _TelegramPhotoGalleryDialog extends StatefulWidget {
  final AppState appState;
  final String accountId;
  final TelegramChat chat;
  final List<TelegramMessage> photoMessages;
  final List<TelegramMessage>? albumMessages;
  final int initialMessageId;
  final Future<bool> Function(TelegramMessage) onQueueDownload;
  final Future<bool> Function(List<TelegramMessage>)? onQueueAlbumDownload;
  final Future<bool> Function(TelegramMessage) onSaveLocal;
  final void Function(TelegramMessage msg, int positionSeconds)?
      onOpenMiniPlayer;

  const _TelegramPhotoGalleryDialog({
    required this.appState,
    required this.accountId,
    required this.chat,
    required this.photoMessages,
    this.albumMessages,
    required this.initialMessageId,
    required this.onQueueDownload,
    this.onQueueAlbumDownload,
    required this.onSaveLocal,
    this.onOpenMiniPlayer,
  });

  @override
  State<_TelegramPhotoGalleryDialog> createState() =>
      _TelegramPhotoGalleryDialogState();
}

class _TelegramGalleryPlaybackTiming {
  final Stopwatch clock;
  final String route;
  final Duration initialPosition;
  int? _startedAt;
  int? _seekStartedAt;
  Duration? _seekTarget;
  int? _stallStartedAt;
  int _stallCount = 0;
  int _stallMs = 0;

  _TelegramGalleryPlaybackTiming(this.clock, this.route, this.initialPosition);

  void log(String event, String metrics) {
    debugPrint(
      '[TelegramPlayback] session=${identityHashCode(this)} route=$route '
      'event=$event $metrics',
    );
  }

  void recordPosition(Duration position) {
    final now = clock.elapsedMilliseconds;
    if (_startedAt == null &&
        position > initialPosition + const Duration(milliseconds: 80)) {
      _startedAt = now;
      log('start', 'playback_start_ms=$now');
    }
    final target = _seekTarget;
    final seekStartedAt = _seekStartedAt;
    if (target != null && seekStartedAt != null) {
      final advance = position - target;
      if (advance >= const Duration(milliseconds: 80) &&
          advance <= const Duration(seconds: 2)) {
        log('seek', 'seek_resume_ms=${now - seekStartedAt}');
        _seekTarget = null;
        _seekStartedAt = null;
      }
    }
  }

  void seek(Duration target) {
    pause();
    _seekStartedAt = clock.elapsedMilliseconds;
    _seekTarget = target;
  }

  void buffering(bool value) {
    if (value) {
      if (_startedAt != null && _seekTarget == null) {
        _stallStartedAt ??= clock.elapsedMilliseconds;
      }
    } else if (_stallStartedAt case final start?) {
      _stallCount++;
      _stallMs += clock.elapsedMilliseconds - start;
      _stallStartedAt = null;
    }
  }

  void pause() {
    buffering(false);
    if (_seekStartedAt case final start?) {
      log('seek_interrupted', 'seek_wait_ms=${clock.elapsedMilliseconds - start}');
    }
    _seekTarget = null;
    _seekStartedAt = null;
  }

  void finish() {
    pause();
    clock.stop();
    log(
      'summary',
      'elapsed_ms=${clock.elapsedMilliseconds} '
      'stall_count=$_stallCount stall_ms=$_stallMs',
    );
  }
}

class _TelegramPhotoGalleryDialogState
    extends State<_TelegramPhotoGalleryDialog> {
  static const _playbackTimingEnabled = bool.fromEnvironment(
    'TELEGRAM_PLAYBACK_TIMING',
  );
  static const _compareDirectPlayback = bool.fromEnvironment(
    'TELEGRAM_PLAYBACK_DIRECT',
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'Gallery_Stage');
  final FocusNode _scrubberFocusNode = FocusNode(debugLabel: 'Gallery_Scrubber');

  // Middle Left / Right previous/next media switch buttons (`<` / `>`)
  final FocusNode _prevItemFocusNode = FocusNode(debugLabel: 'Gallery_MidPrev');
  final FocusNode _nextItemFocusNode = FocusNode(debugLabel: 'Gallery_MidNext');

  // Top bar focus nodes
  final FocusNode _topTitleFocusNode =
      FocusNode(debugLabel: 'Gallery_TopTitle');
  final FocusNode _topProxyFocusNode = FocusNode(debugLabel: 'Gallery_TopProxy');
  final FocusNode _topScopeFocusNode = FocusNode(debugLabel: 'Gallery_TopScope');
  final FocusNode _topMiniFocusNode = FocusNode(debugLabel: 'Gallery_TopMini');
  final FocusNode _topAlbumQueueFocusNode =
      FocusNode(debugLabel: 'Gallery_TopAlbumQueue');
  final FocusNode _topSaveFocusNode = FocusNode(debugLabel: 'Gallery_TopSave');
  final FocusNode _topQueueFocusNode = FocusNode(debugLabel: 'Gallery_TopQueue');
  final FocusNode _topCloseFocusNode = FocusNode(debugLabel: 'Gallery_TopClose');

  // Progress bar top header strip focus nodes
  final FocusNode _barToggleCaptionFocusNode =
      FocusNode(debugLabel: 'Gallery_BarToggleCaption');
  final FocusNode _barMovePosFocusNode =
      FocusNode(debugLabel: 'Gallery_BarMovePos');
  final FocusNode _barHideControlsFocusNode =
      FocusNode(debugLabel: 'Gallery_BarHideControls');

  // Bottom Row 2 control buttons focus nodes
  final FocusNode _playPauseFocusNode =
      FocusNode(debugLabel: 'Gallery_PlayPause');
  final FocusNode _rewindFocusNode = FocusNode(debugLabel: 'Gallery_Rewind5s');
  final FocusNode _forwardFocusNode = FocusNode(debugLabel: 'Gallery_Forward5s');
  final FocusNode _bottomPrevFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomPrev');
  final FocusNode _bottomNextFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomNext');
  final FocusNode _speedFocusNode = FocusNode(debugLabel: 'Gallery_Speed');
  final FocusNode _aspectModeFocusNode =
      FocusNode(debugLabel: 'Gallery_AspectMode');
  final FocusNode _bottomToggleCaptionFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomToggleCaption');
  final FocusNode _bottomMovePosFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomMovePos');
  final FocusNode _bottomHideBarFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomHideBar');
  final FocusNode _bottomProxyFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomProxy');
  final FocusNode _muteFocusNode = FocusNode(debugLabel: 'Gallery_Mute');
  final FocusNode _bottomSaveFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomSave');
  final FocusNode _bottomQueueFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomQueue');
  final FocusNode _bottomExitFocusNode =
      FocusNode(debugLabel: 'Gallery_BottomExit');
  final FocusNode _restoreControlsFocusNode =
      FocusNode(debugLabel: 'Gallery_RestoreControls');
  final Map<int, FocusNode> _thumbFocusNodes = <int, FocusNode>{};

  FocusNode _getThumbFocusNode(int idx) {
    return _thumbFocusNodes.putIfAbsent(
      idx,
      () => FocusNode(debugLabel: 'Gallery_Thumb_$idx'),
    );
  }

  final DateTime _dialogOpenedAt = DateTime.now();
  DateTime? _lastBackHandledAt;
  bool _hasAssignedInitialFocus = false;

  bool _isGalleryBackKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.gameButtonB;
  }

  void _handleGalleryBackPress() {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_dialogOpenedAt) < const Duration(milliseconds: 220)) {
      return;
    }
    if (_lastBackHandledAt != null &&
        now.difference(_lastBackHandledAt!) <
            const Duration(milliseconds: 240)) {
      return;
    }
    _lastBackHandledAt = now;

    if (_showProxyStatsOverlay) {
      setState(() => _showProxyStatsOverlay = false);
      return;
    }

    if (!_controlsHidden) {
      _galleryAutoHideTimer?.cancel();
      setState(() => _controlsHidden = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsHidden) {
          _restoreControlsFocusNode.requestFocus();
        }
      });
      return;
    }
    Navigator.of(context).pop();
  }
  late bool _albumScopeOnly;
  late int _currentIndex;

  Player? _videoPlayer;
  VideoController? _videoController;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _completedSub;
  int _pendingGalleryResumeSeconds = 0;
  DateTime? _lastGalleryPosUiUpdateAt;

  bool _isVideoPlaying = false;
  bool _isVideoBuffering = false;
  Duration _videoPosition = Duration.zero;
  Duration _videoDuration = Duration.zero;
  Duration _videoBuffer = Duration.zero;
  double _playbackSpeed = 1.0;
  bool _isMuted = false;
  double _volume = 100.0;
  double _preMuteVolume = 100.0;
  bool _isGalleryHorizontalSeeking = false;
  Duration _gallerySeekStartPos = Duration.zero;
  Duration _gallerySeekPreviewPos = Duration.zero;
  Duration? _gallerySliderPreviewPos;
  _TelegramGalleryPlaybackTiming? _galleryPlaybackTiming;
  String _galleryAspectMode = 'fit'; // 'fit', 'cover'
  bool? _galleryLandscapeOverride;
  bool _galleryDidChangeOrientation = false;

  // Draggable & hideable state for Progress/Controls Bar and Video Title/Caption Windows
  Offset _controlsDragOffset = Offset.zero;
  bool _controlsHidden = false;
  Offset _captionDragOffset = Offset.zero;
  bool _captionHidden = false;
  Offset _topTitleDragOffset = Offset.zero;
  bool _topTitleHidden = false;
  int _controlsPosPreset = 0; // 0: 底部默认, 1: 顶部避字幕, 2: 中上位置
  int _galleryVideoOpenSeq = 0;
  Future<void>? _galleryPlayerSetup;
  bool _galleryOpening = false;
  bool _galleryRetriedPrematureEnd = false;
  bool _galleryWantsPlayback = true;
  String _activeGalleryStreamUrl = '';
  bool _activeGalleryUsingLocalRelay = false;
  bool _showProxyStatsOverlay = false;
  Timer? _galleryAutoHideTimer;
  final ScrollController _thumbStripScrollController = ScrollController();

  void _pokeGalleryControls() {
    _galleryAutoHideTimer?.cancel();
    final wasHidden = _controlsHidden;
    if (wasHidden) {
      setState(() {
        _controlsHidden = false;
      });
      _scrollActiveThumbnailIntoView(animated: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_controlsHidden) {
          _playPauseFocusNode.requestFocus();
        }
      });
    }
    _scheduleGalleryAutoHide();
  }

  void _scheduleGalleryAutoHide() {
    _galleryAutoHideTimer?.cancel();
    _galleryAutoHideTimer = Timer(const Duration(milliseconds: 3800), () {
      if (!mounted) return;
      final list = _activeMessages;
      if (list.isEmpty) return;
      final msg = list[_currentIndex.clamp(0, list.length - 1)];
      final isVid = msg.attachment?.isVideo ?? false;
      if (isVid && _isVideoPlaying && !_controlsHidden) {
        setState(() {
          _controlsHidden = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controlsHidden) {
            _restoreControlsFocusNode.requestFocus();
          }
        });
      }
    });
  }

  String get _controlsPosPresetLabel => switch (_controlsPosPreset) {
        1 => '位置:顶部',
        2 => '位置:中上',
        _ => _controlsDragOffset != Offset.zero ? '位置:归位' : '位置:底部',
      };

  void _cycleControlsAndCaptionPosition() {
    final mq = MediaQuery.maybeSizeOf(context);
    final h = mq?.height ?? 720.0;
    setState(() {
      if (_controlsDragOffset != Offset.zero && _controlsPosPreset == 0) {
        _controlsDragOffset = Offset.zero;
        _captionDragOffset = Offset.zero;
        _controlsPosPreset = 0;
      } else {
        _controlsPosPreset = (_controlsPosPreset + 1) % 3;
        if (_controlsPosPreset == 0) {
          _controlsDragOffset = Offset.zero;
          _captionDragOffset = Offset.zero;
        } else if (_controlsPosPreset == 1) {
          _controlsDragOffset = Offset(0, -(h * 0.56).clamp(220.0, 520.0));
          _captionDragOffset = Offset(0, -(h * 0.42).clamp(160.0, 380.0));
        } else {
          _controlsDragOffset = Offset(0, -(h * 0.28).clamp(110.0, 260.0));
          _captionDragOffset = Offset(0, -(h * 0.22).clamp(80.0, 200.0));
        }
      }
    });
    final desc = switch (_controlsPosPreset) {
      1 => '已将进度条与标题窗移至顶部（避开底部字幕）',
      2 => '已将进度条与标题窗移至中上位置',
      _ => '已将进度条与标题窗恢复至底部默认位置',
    };
    _showGalleryHud(desc, state: 'success');
  }

  void _hideControlsBar() {
    setState(() {
      _controlsHidden = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controlsHidden) {
        _restoreControlsFocusNode.requestFocus();
      }
    });
  }

  void _restoreControlsBar() {
    setState(() {
      _controlsHidden = false;
    });
    _scrollActiveThumbnailIntoView(animated: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_controlsHidden) {
        _playPauseFocusNode.requestFocus();
      }
    });
  }

  void _scrollActiveThumbnailIntoView({bool animated = true}) {
    void performScroll(bool useAnimation) {
      if (!mounted || !_thumbStripScrollController.hasClients) return;
      final pos = _thumbStripScrollController.position;
      if (!pos.hasViewportDimension || !pos.hasContentDimensions) return;
      const itemWidth = 54.0;
      const separatorWidth = 6.0;
      const horizontalPadding = 8.0;
      final itemCenter = horizontalPadding +
          _currentIndex * (itemWidth + separatorWidth) +
          itemWidth / 2.0;
      final targetOffset = (itemCenter - pos.viewportDimension / 2.0)
          .clamp(0.0, pos.maxScrollExtent);
      if (useAnimation && (pos.pixels - targetOffset).abs() > 2.0) {
        _thumbStripScrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _thumbStripScrollController.jumpTo(targetOffset);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      performScroll(animated);
      if (_currentIndex > 0) {
        Future<void>.delayed(const Duration(milliseconds: 90), () {
          performScroll(animated);
        });
      }
    });
  }

  void _cycleGalleryAspectMode() {
    setState(() {
      _galleryAspectMode = _galleryAspectMode == 'fit' ? 'cover' : 'fit';
    });
    _showGalleryHud(
      _galleryAspectMode == 'cover' ? '画面比例：铺满裁剪 (去黑边)' : '画面比例：适应屏幕',
      state: 'success',
    );
  }

  void _toggleGalleryOrientation() {
    if (!(Platform.isAndroid || Platform.isIOS) || widget.appState.tvMode) {
      return;
    }
    final mq = MediaQuery.maybeSizeOf(context);
    final isCurrentlyLandscape =
        _galleryLandscapeOverride ?? (mq != null && mq.width > mq.height);
    final nextLandscape = !isCurrentlyLandscape;
    setState(() {
      _galleryLandscapeOverride = nextLandscape;
      _galleryDidChangeOrientation = true;
    });
    if (nextLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
    _showGalleryHud(
      nextLandscape ? '已切换为：横屏全屏模式' : '已切换为：竖屏全屏模式',
      state: 'success',
    );
  }

  // Per-message download/save visual feedback inside the gallery lightbox
  final Set<int> _queueingIds = {};
  final Set<int> _queuedIds = {};
  final Set<int> _failedIds = {};
  final Set<int> _savingLocalIds = {};
  final Set<int> _savedLocalIds = {};
  bool _queueingAlbum = false;
  bool _queuedAlbum = false;
  String? _dialogHudText;
  String _dialogHudState = 'idle'; // 'loading' | 'success' | 'error'
  Timer? _dialogHudTimer;
  String _lastGalleryRouteSignature = '';

  String _computeGalleryRouteSignature() {
    final svc = widget.appState.proxyService;
    final effective = svc.resolveEffectiveRoute(RequestScenario.telegram);
    final nodeId = effective == ScenarioRouteMode.proxyNode
        ? (svc.resolveNodeForScenario(RequestScenario.telegram)?.id ?? '')
        : '';
    return '${svc.proxyEnabled}|${effective.name}|$nodeId';
  }

  void _onGalleryExternalProxyChanged() {
    if (!mounted) return;
    final nextSig = _computeGalleryRouteSignature();
    if (nextSig == _lastGalleryRouteSignature) return;
    _lastGalleryRouteSignature = nextSig;
    if (_usingGallery115Direct || _videoPlayer == null) return;
    unawaited(
      _syncVideoPlayerForCurrentItem(
        resumeFrom: _videoPosition,
        play: _galleryWantsPlayback,
      ),
    );
  }

  void _showGalleryHud(String text, {required String state}) {
    _dialogHudTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _dialogHudText = text;
      _dialogHudState = state;
    });
    if (state != 'loading') {
      _dialogHudTimer = Timer(const Duration(milliseconds: 2400), () {
        if (mounted) {
          setState(() => _dialogHudText = null);
        }
      });
    }
  }

  Future<void> _handleQueueSingle(TelegramMessage msg) async {
    if (_queueingIds.contains(msg.id)) return;
    final name = msg.attachment?.displayName ?? '媒体 #${msg.id}';
    setState(() {
      _queueingIds.add(msg.id);
      _failedIds.remove(msg.id);
    });
    _showGalleryHud('正在添加转存任务：$name ...', state: 'loading');
    final ok = await widget.onQueueDownload(msg);
    if (!mounted) return;
    setState(() {
      _queueingIds.remove(msg.id);
      if (ok) {
        _queuedIds.add(msg.id);
      } else {
        _failedIds.add(msg.id);
      }
    });
    _showGalleryHud(
      ok ? '已成功加入下载队列：$name' : '添加失败，请点击重试：$name',
      state: ok ? 'success' : 'error',
    );
  }

  Future<void> _handleSaveLocal(TelegramMessage msg) async {
    if (_savingLocalIds.contains(msg.id)) return;
    final name = msg.attachment?.displayName ?? '媒体 #${msg.id}';
    setState(() {
      _savingLocalIds.add(msg.id);
    });
    _showGalleryHud('正在保存至本机 Downloads：$name ...', state: 'loading');
    final ok = await widget.onSaveLocal(msg);
    if (!mounted) return;
    setState(() {
      _savingLocalIds.remove(msg.id);
      if (ok) {
        _savedLocalIds.add(msg.id);
      }
    });
    _showGalleryHud(
      ok ? '已保存至本机 Downloads：$name' : '本机保存失败：$name',
      state: ok ? 'success' : 'error',
    );
  }

  Future<void> _handleQueueAlbum(List<TelegramMessage> items) async {
    if (_queueingAlbum || widget.onQueueAlbumDownload == null) return;
    setState(() {
      _queueingAlbum = true;
    });
    _showGalleryHud('正在批量添加整组 ${items.length} 项媒体...', state: 'loading');
    final ok = await widget.onQueueAlbumDownload!(items);
    if (!mounted) return;
    setState(() {
      _queueingAlbum = false;
      if (ok) {
        _queuedAlbum = true;
        for (final m in items) {
          _queuedIds.add(m.id);
        }
      }
    });
    _showGalleryHud(
      ok ? '整组媒体已成功加入下载队列' : '整组转存失败，请重试',
      state: ok ? 'success' : 'error',
    );
  }

  List<TelegramMessage> get _activeMessages {
    if (_albumScopeOnly &&
        widget.albumMessages != null &&
        widget.albumMessages!.isNotEmpty) {
      return widget.albumMessages!;
    }
    return widget.photoMessages;
  }

  void _onGalleryFocusManagerChanged() {
    if (!mounted || _controlsHidden) return;
    _galleryAutoHideTimer?.cancel();
    _scheduleGalleryAutoHide();
  }

  @override
  void initState() {
    super.initState();
    // Default to all chat media so Left/Right (`<` / `>`) can switch across all videos/photos in the chat
    _albumScopeOnly = false;
    final list = _activeMessages;
    final idx = list.indexWhere((m) => m.id == widget.initialMessageId);
    _currentIndex = idx >= 0 ? idx : 0;
    _lastGalleryRouteSignature = _computeGalleryRouteSignature();
    widget.appState.proxyService.addListener(_onGalleryExternalProxyChanged);
    FocusManager.instance.addListener(_onGalleryFocusManagerChanged);
    _syncVideoPlayerForCurrentItem();
    _scrollActiveThumbnailIntoView(animated: false);
    _scheduleGalleryAutoHide();
  }

  @override
  void dispose() {
    if (_galleryDidChangeOrientation &&
        (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (!widget.appState.tvMode) {
        SystemChrome.setPreferredOrientations(const []);
      }
    }
    FocusManager.instance.removeListener(_onGalleryFocusManagerChanged);
    widget.appState.proxyService.removeListener(_onGalleryExternalProxyChanged);
    _galleryAutoHideTimer?.cancel();
    _dialogHudTimer?.cancel();
    _disposeVideoPlayer();
    _thumbStripScrollController.dispose();
    _focusNode.dispose();
    _scrubberFocusNode.dispose();
    _prevItemFocusNode.dispose();
    _nextItemFocusNode.dispose();
    _topTitleFocusNode.dispose();
    _topProxyFocusNode.dispose();
    _topScopeFocusNode.dispose();
    _topMiniFocusNode.dispose();
    _topAlbumQueueFocusNode.dispose();
    _topSaveFocusNode.dispose();
    _topQueueFocusNode.dispose();
    _topCloseFocusNode.dispose();
    _barToggleCaptionFocusNode.dispose();
    _barMovePosFocusNode.dispose();
    _barHideControlsFocusNode.dispose();
    _playPauseFocusNode.dispose();
    _rewindFocusNode.dispose();
    _forwardFocusNode.dispose();
    _bottomPrevFocusNode.dispose();
    _bottomNextFocusNode.dispose();
    _speedFocusNode.dispose();
    _aspectModeFocusNode.dispose();
    _bottomToggleCaptionFocusNode.dispose();
    _bottomMovePosFocusNode.dispose();
    _bottomHideBarFocusNode.dispose();
    _bottomProxyFocusNode.dispose();
    _muteFocusNode.dispose();
    _bottomSaveFocusNode.dispose();
    _bottomQueueFocusNode.dispose();
    _bottomExitFocusNode.dispose();
    _restoreControlsFocusNode.dispose();
    for (final node in _thumbFocusNodes.values) {
      node.dispose();
    }
    _thumbFocusNodes.clear();
    super.dispose();
  }

  void _disposeVideoPlayer() {
    _galleryVideoOpenSeq++;
    _finishGalleryPlaybackTiming();
    _galleryPlayerSetup = null;
    _playingSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _bufferSub?.cancel();
    _bufferingSub?.cancel();
    _completedSub?.cancel();
    _playingSub = null;
    _posSub = null;
    _durSub = null;
    _bufferSub = null;
    _bufferingSub = null;
    _completedSub = null;
    _videoPlayer?.dispose();
    _videoPlayer = null;
    _videoController = null;
  }

  Future<void> _configureGalleryVideoPlayer(Player p) async {
    try {
      final dynamic platform = p.platform;
      final isMobileOrTv = Platform.isAndroid || Platform.isIOS;
      final props = <String, String>{
        'hwdec': Platform.isAndroid ? 'mediacodec-copy' : 'auto-safe',
        'hwdec-codecs': 'h264,hevc,vp8,vp9,av1',
        'vd-lavc-check-hw-profile': 'yes',
        'vd-lavc-software-fallback': 'yes',
        'vd-lavc-dr': 'yes',
        'vd-lavc-fast': 'yes',
        'vd-lavc-skiploopfilter': 'nonref',
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': isMobileOrTv ? '90' : '120',
        'cache-pause': 'yes',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '2.5',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': isMobileOrTv ? '100663296' : '134217728',
        'demuxer-max-back-bytes': isMobileOrTv ? '25165824' : '33554432',
        'demuxer-readahead-secs': isMobileOrTv ? '60' : '90',
        'stream-buffer-size': '2097152',
        'demuxer-lavf-probesize': '131072',
        'demuxer-lavf-analyzeduration': '0.5',
        'framedrop': 'vo',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        'network-timeout': '20',
        'tls-verify': 'no',
        'keep-open': 'no',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=5',
        'demuxer-lavf-o':
            'http_persistent=1,http_multiple=1,allowed_extensions=ALL',
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (_) {}
  }

  Future<void> _syncVideoPlayerForCurrentItem({
    Duration resumeFrom = Duration.zero,
    bool play = true,
  }) async {
    _lastGalleryRouteSignature = _computeGalleryRouteSignature();
    final openSeq = ++_galleryVideoOpenSeq;
    _finishGalleryPlaybackTiming();
    _gallerySliderPreviewPos = null;
    final timingClock = _playbackTimingEnabled && play ? Stopwatch() : null;
    timingClock?.start();
    final list = _activeMessages;
    if (list.isEmpty) return;
    _currentIndex = _currentIndex.clamp(0, list.length - 1);
    final msg = list[_currentIndex];
    final att = msg.attachment;
    if (att == null || !att.isVideo) {
      _galleryOpening = false;
      _activeGalleryStreamUrl = '';
      _usingGallery115Direct = false;
      await _videoPlayer?.stop();
      if (openSeq != _galleryVideoOpenSeq) return;
      if (mounted) {
        setState(() {
          _isVideoPlaying = false;
          _isVideoBuffering = false;
          _videoPosition = Duration.zero;
          _videoDuration = Duration.zero;
          _videoBuffer = Duration.zero;
        });
      }
      return;
    }

    Player p;
    VideoController? newController;
    if (_videoPlayer == null || _videoController == null) {
      p = Player(
        configuration: PlayerConfiguration(
          bufferSize:
              (Platform.isAndroid || Platform.isIOS)
                  ? 96 * 1024 * 1024
                  : 128 * 1024 * 1024,
        ),
      );
      final c = VideoController(
        p,
        configuration: VideoControllerConfiguration(
          hwdec: Platform.isAndroid ? 'mediacodec-copy' : null,
          enableHardwareAcceleration: true,
        ),
      );
      _videoPlayer = p;
      _videoController = c;
      newController = c;
      _galleryPlayerSetup = _configureGalleryVideoPlayer(p);

      _playingSub = p.stream.playing.listen((playing) {
        if (playing) {
          unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
        }
        if (mounted && _isVideoPlaying != playing) {
          setState(() => _isVideoPlaying = playing);
        }
      });
      _posSub = p.stream.position.listen((pos) {
        if (!mounted) return;
        if (_galleryWantsPlayback && p.state.playing && !p.state.buffering) {
          _galleryPlaybackTiming?.recordPosition(pos);
        }
        if (pos > Duration.zero) {
          final now = DateTime.now();
          final shouldClearBuf = _isVideoBuffering && !p.state.buffering;
          if (shouldClearBuf ||
              _lastGalleryPosUiUpdateAt == null ||
              now.difference(_lastGalleryPosUiUpdateAt!) >=
                  const Duration(milliseconds: 250)) {
            _lastGalleryPosUiUpdateAt = now;
            setState(() {
              _videoPosition = pos;
              if (!p.state.buffering) {
                _isVideoBuffering = false;
              }
            });
          } else {
            _videoPosition = pos;
          }
        }
        if (_pendingGalleryResumeSeconds > 2 && _videoDuration.inSeconds > 0) {
          final target = _pendingGalleryResumeSeconds;
          _pendingGalleryResumeSeconds = 0;
          if (target < _videoDuration.inSeconds - 3) {
            p.seek(Duration(seconds: target));
          }
        }
      });
      _durSub = p.stream.duration.listen((dur) {
        if (dur > Duration.zero && mounted && _videoDuration != dur) {
          setState(() => _videoDuration = dur);
        }
      });
      _bufferSub = p.stream.buffer.listen((buf) {
        if (!mounted) return;
        if ((buf.inMilliseconds - _videoBuffer.inMilliseconds).abs() >= 1000) {
          setState(() => _videoBuffer = buf);
        } else {
          _videoBuffer = buf;
        }
      });
      _bufferingSub = p.stream.buffering.listen((buf) {
        _galleryPlaybackTiming?.buffering(buf && _galleryWantsPlayback);
        if (mounted && _isVideoBuffering != buf) {
          setState(() => _isVideoBuffering = buf);
        }
      });
      _completedSub = p.stream.completed.listen((completed) {
        if (!completed ||
            !mounted ||
            _galleryOpening ||
            _galleryRetriedPrematureEnd ||
            !_galleryWantsPlayback) {
          return;
        }
        final durSec = _videoDuration.inSeconds;
        final posSec = _videoPosition.inSeconds;
        final isPrematureEof =
            durSec <= 0 || (durSec > 6 && posSec > 1 && posSec < durSec - 4);
        if (isPrematureEof && _activeGalleryStreamUrl.isNotEmpty) {
          _galleryRetriedPrematureEnd = true;
          _pendingGalleryResumeSeconds = posSec;
          unawaited(
            p.open(
              Media(
                _activeGalleryStreamUrl,
                httpHeaders:
                    _activeGalleryUsingLocalRelay
                        ? const {}
                        : widget.appState.api.authHeaders,
              ),
              play: true,
            ),
          );
        }
      });
    } else {
      p = _videoPlayer!;
    }

    _galleryOpening = true;
    _galleryWantsPlayback = play;
    if (play) {
      unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    }
    _galleryRetriedPrematureEnd = false;
    _videoPosition = resumeFrom;
    _videoBuffer = Duration.zero;
    _pendingGalleryResumeSeconds = 0;
    _videoDuration =
        att.duration > 0 ? Duration(seconds: att.duration) : Duration.zero;
    _isVideoBuffering = true;

    final rawStreamUrl = widget.appState.api.buildTelegramVideoStreamUrl(
      accountId: widget.accountId,
      peer: widget.chat.peer,
      messageId: msg.id,
    );
    _activeGalleryStreamUrl = rawStreamUrl;
    _activeGalleryUsingLocalRelay = false;
    _usingGallery115Direct = false;

    if (mounted) {
      setState(() {});
      if (!_hasAssignedInitialFocus) {
        _hasAssignedInitialFocus = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _playPauseFocusNode.requestFocus();
        });
      }
    }

    bool isCurrent() =>
        mounted && _videoPlayer == p && _galleryVideoOpenSeq == openSeq;
    try {
      await _galleryPlayerSetup;
      if (!isCurrent()) return;
      await p.stop();
      if (!isCurrent()) return;
      final authHeaders = widget.appState.api.authHeaders;
      final proxyService = widget.appState.proxyService;
      final useDirectComparison =
          _compareDirectPlayback &&
          proxyService.resolveEffectiveRoute(
                RequestScenario.telegram,
                targetUri: Uri.parse(rawStreamUrl),
              ) ==
              ScenarioRouteMode.direct;
      final resolvedUrl =
          useDirectComparison
              ? rawStreamUrl
              : await proxyService.resolveProxiedStreamUrl(
                RequestScenario.telegram,
                rawStreamUrl,
                headers: authHeaders,
              );
      if (!isCurrent()) return;
      _activeGalleryStreamUrl = resolvedUrl;
      _activeGalleryUsingLocalRelay = resolvedUrl.contains('/__m3u8_proxy__/');
      await p.setVolume(_isMuted ? 0 : _volume);
      if (!isCurrent()) return;
      final playOnOpen = _galleryWantsPlayback;
      if (timingClock != null && playOnOpen) {
        final route =
            !_activeGalleryUsingLocalRelay
                ? 'server_direct'
                : Uri.parse(resolvedUrl).queryParameters['direct'] == '1'
                ? 'relay_direct'
                : 'relay_proxy';
        final timing = _TelegramGalleryPlaybackTiming(
          timingClock,
          route,
          resumeFrom,
        );
        _galleryPlaybackTiming = timing;
        if (newController != null) {
          unawaited(
            newController.waitUntilFirstFrameRendered.then<void>((_) {
              if (identical(_galleryPlaybackTiming, timing)) {
                timing.log(
                  'first_frame',
                  'first_frame_ms=${timingClock.elapsedMilliseconds}',
                );
              }
            }, onError: (Object _) {}),
          );
        }
      }
      await p.open(
        Media(
          resolvedUrl,
          httpHeaders: _activeGalleryUsingLocalRelay ? const {} : authHeaders,
          start: resumeFrom > Duration.zero ? resumeFrom : null,
        ),
        play: playOnOpen,
      );
      if (!isCurrent()) return;
      if (playOnOpen != _galleryWantsPlayback) {
        if (_galleryWantsPlayback) {
          await p.play();
        } else {
          await p.pause();
        }
      }
      if (isCurrent() && _playbackSpeed != 1.0) {
        await p.setRate(_playbackSpeed);
      }
    } catch (_) {
      if (isCurrent()) {
        _finishGalleryPlaybackTiming();
        setState(() => _isVideoBuffering = false);
      }
    } finally {
      if (isCurrent()) _galleryOpening = false;
    }
  }

  Future<void> _toggleGalleryPlayback() async {
    final player = _videoPlayer;
    if (player == null) return;
    _galleryWantsPlayback = !_galleryWantsPlayback;
    if (!_galleryWantsPlayback) _galleryPlaybackTiming?.pause();
    if (_galleryOpening) return;
    if (_galleryWantsPlayback) {
      await player.play();
    } else {
      await player.pause();
    }
  }

  void _switchGalleryProxy(String status) {
    if (!mounted) return;
    _showGalleryHud(status, state: 'success');
    unawaited(
      _syncVideoPlayerForCurrentItem(
        resumeFrom: _videoPosition,
        play: _galleryWantsPlayback,
      ),
    );
  }

  bool _usingGallery115Direct = false;

  String _resolveGallery115DownloadUrl() {
    final list = _activeMessages;
    if (list.isEmpty) return '';
    final msg = list[_currentIndex.clamp(0, list.length - 1)];
    return widget.appState.api.buildTelegramVideoStreamUrl(
      accountId: widget.accountId,
      peer: widget.chat.peer,
      messageId: msg.id,
    );
  }

  String _resolveGallery115VideoName() {
    final list = _activeMessages;
    if (list.isEmpty) return 'telegram_video.mp4';
    final msg = list[_currentIndex.clamp(0, list.length - 1)];
    final raw = (msg.attachment?.displayName ?? '').trim();
    if (raw.isNotEmpty) return raw;
    final cleanPeer = widget.chat.peer.replaceAll(':', '_');
    return 'telegram_${cleanPeer}_${msg.id}.mp4';
  }

  Future<void> _applyGallery115Stream(Resolved115Stream resolved) async {
    final p = _videoPlayer;
    if (!mounted || p == null) return;
    final openSeq = ++_galleryVideoOpenSeq;
    _finishGalleryPlaybackTiming();
    final curSec = _videoPosition.inSeconds;
    setState(() {
      _usingGallery115Direct = true;
      _activeGalleryStreamUrl = resolved.proxyStreamUrl;
      _activeGalleryUsingLocalRelay =
          resolved.proxyStreamUrl.contains('127.0.0.1');
      _isVideoBuffering = false;
    });
    if (curSec > 2) {
      _pendingGalleryResumeSeconds = curSec;
    }
    await p.setVolume(_isMuted ? 0 : _volume);
    if (!mounted || _galleryVideoOpenSeq != openSeq) return;
    await p.open(
      Media(
        resolved.proxyStreamUrl,
        httpHeaders: resolved.playbackHeaders,
        start: curSec > 2 ? Duration(seconds: curSec) : null,
      ),
      play: true,
    );
    if (!mounted || _galleryVideoOpenSeq != openSeq) return;
    if (_playbackSpeed != 1.0) {
      await p.setRate(_playbackSpeed);
    }
    _showGalleryHud(
      '⚡ 已切换本地直连 115 播放：${resolved.fileName}',
      state: 'success',
    );
  }

  void _selectIndex(int newIndex) {
    final list = _activeMessages;
    if (list.isEmpty) return;
    final clamped = (newIndex + list.length) % list.length;
    if (clamped == _currentIndex && _videoPlayer != null) {
      _scrollActiveThumbnailIntoView(animated: true);
      return;
    }
    setState(() {
      _currentIndex = clamped;
    });
    _syncVideoPlayerForCurrentItem();
    _scrollActiveThumbnailIntoView(animated: true);
  }

  void _step(int delta) {
    final list = _activeMessages;
    if (list.length <= 1) return;
    _selectIndex(_currentIndex + delta);
  }

  void _toggleScopeMode() {
    if (widget.albumMessages == null || widget.albumMessages!.length <= 1) {
      return;
    }
    final currentMsgId = _activeMessages[_currentIndex].id;
    setState(() {
      _albumScopeOnly = !_albumScopeOnly;
      final newList = _activeMessages;
      final idx = newList.indexWhere((m) => m.id == currentMsgId);
      _currentIndex = idx >= 0 ? idx : 0;
    });
    _scrollActiveThumbnailIntoView(animated: true);
  }

  void _cycleSpeed() {
    const speeds = [0.5, 1.0, 1.25, 1.5, 2.0];
    final curIdx = speeds.indexOf(_playbackSpeed);
    final next = speeds[(curIdx + 1) % speeds.length];
    setState(() => _playbackSpeed = next);
    _videoPlayer?.setRate(next);
  }

  void _toggleMute() {
    if (_isMuted || _volume <= 0) {
      final restored = _preMuteVolume > 5 ? _preMuteVolume : 100.0;
      setState(() {
        _isMuted = false;
        _volume = restored;
      });
      _videoPlayer?.setVolume(restored);
    } else {
      _preMuteVolume = _volume;
      setState(() {
        _isMuted = true;
        _volume = 0;
      });
      _videoPlayer?.setVolume(0);
    }
  }

  void _setVolume(double val) {
    final clamped = val.clamp(0.0, 100.0);
    if (clamped > 0) {
      _preMuteVolume = clamped;
    }
    setState(() {
      _volume = clamped;
      _isMuted = clamped <= 0;
    });
    _videoPlayer?.setVolume(clamped);
  }

  void _stepVolume(double delta) {
    final current = _isMuted ? 0.0 : _volume;
    _setVolume(current + delta);
  }

  void _seekRelative(int deltaSeconds) {
    final target = _videoPosition + Duration(seconds: deltaSeconds);
    final maxDur = _videoDuration > Duration.zero
        ? _videoDuration
        : const Duration(hours: 12);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > maxDur ? maxDur : target);
    _seekGalleryVideo(clamped);
  }

  void _seekGalleryVideo(Duration target) {
    final player = _videoPlayer;
    if (player == null) return;
    if (_galleryWantsPlayback) _galleryPlaybackTiming?.seek(target);
    player.seek(target);
  }

  void _previewGallerySlider(double value) {
    setState(() {
      _gallerySliderPreviewPos = Duration(milliseconds: value.round());
    });
  }

  void _commitGallerySlider(double value) {
    if (_gallerySliderPreviewPos == null) return;
    final target = Duration(milliseconds: value.round());
    setState(() {
      _gallerySliderPreviewPos = null;
      _videoPosition = target;
    });
    _seekGalleryVideo(target);
  }

  void _finishGalleryPlaybackTiming() {
    _galleryPlaybackTiming?.finish();
    _galleryPlaybackTiming = null;
  }

  String _fmtClock(Duration d) {
    final total = d.inSeconds;
    if (total <= 0) return '00:00';
    final h = total ~/ 3600;
    final m = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  FocusNode? _neighborInChain(
    List<FocusNode> chain,
    FocusNode node,
    int delta, {
    FocusNode? edgeTarget,
  }) {
    final idx = chain.indexOf(node);
    if (idx < 0) return edgeTarget;
    final nextIdx = idx + delta;
    if (nextIdx >= 0 && nextIdx < chain.length) {
      return chain[nextIdx];
    }
    return edgeTarget;
  }

  Widget _buildGalleryTvButton({
    FocusNode? focusNode,
    bool autofocus = false,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Color bgColor = const Color(0xCC1E2C3A),
    Color iconColor = Colors.white,
    FocusNode? upFocusNode,
    FocusNode? downFocusNode,
    FocusNode? leftFocusNode,
    FocusNode? rightFocusNode,
  }) {
    return StatefulBuilder(
      builder: (btnCtx, setBtnState) {
        return Focus(
          focusNode: focusNode,
          autofocus: autofocus,
          onFocusChange: (hasFocus) {
            setBtnState(() {});
            if (hasFocus) {
              _pokeGalleryControls();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (btnCtx.mounted) {
                  Scrollable.ensureVisible(
                    btnCtx,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 140),
                  );
                }
              });
            }
          },
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            _pokeGalleryControls();
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                    event.logicalKey == LogicalKeyboardKey.space ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
              if (onTap != null) onTap();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                leftFocusNode != null) {
              leftFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                rightFocusNode != null) {
              rightFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                upFocusNode != null) {
              upFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                downFocusNode != null) {
              downFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (innerCtx) {
              final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused ? const Color(0xFF3E99EE) : bgColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isFocused
                          ? const Color(0xFFFFE066)
                          : Colors.white24,
                      width: isFocused ? 2.2 : 1.0,
                    ),
                    boxShadow: isFocused
                        ? const [
                            BoxShadow(
                              color: Color(0x883E99EE),
                              blurRadius: 10,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: isFocused ? Colors.white : iconColor,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          color: onTap == null ? Colors.white54 : Colors.white,
                          fontSize: 12,
                          fontWeight:
                              isFocused ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildGalleryTvIconButton({
    FocusNode? focusNode,
    bool autofocus = false,
    required IconData icon,
    String? label,
    required VoidCallback? onTap,
    double iconSize = 20,
    FocusNode? upFocusNode,
    FocusNode? downFocusNode,
    FocusNode? leftFocusNode,
    FocusNode? rightFocusNode,
  }) {
    return StatefulBuilder(
      builder: (btnCtx, setBtnState) {
        return Focus(
          focusNode: focusNode,
          autofocus: autofocus,
          onFocusChange: (hasFocus) {
            setBtnState(() {});
            if (hasFocus) {
              _pokeGalleryControls();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (btnCtx.mounted) {
                  Scrollable.ensureVisible(
                    btnCtx,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 140),
                  );
                }
              });
            }
          },
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            _pokeGalleryControls();
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                    event.logicalKey == LogicalKeyboardKey.space ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
              if (onTap != null) onTap();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                leftFocusNode != null) {
              leftFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                rightFocusNode != null) {
              rightFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                upFocusNode != null) {
              upFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                downFocusNode != null) {
              downFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (innerCtx) {
              final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: label != null ? 10 : 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? const Color(0xFF3E99EE)
                        : const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isFocused
                          ? const Color(0xFFFFE066)
                          : Colors.white24,
                      width: isFocused ? 2.2 : 1.0,
                    ),
                    boxShadow: isFocused
                        ? const [
                            BoxShadow(
                              color: Color(0x883E99EE),
                              blurRadius: 10,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: iconSize,
                        color: Colors.white,
                      ),
                      if (label != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          label,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight:
                                isFocused ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _activeMessages;
    final msg = list[_currentIndex.clamp(0, list.length - 1)];
    final att = msg.attachment;
    final isVideo = att?.isVideo ?? false;
    final thumbUrl = widget.appState.api.buildTelegramThumbnailUrl(
      accountId: widget.accountId,
      peer: widget.chat.peer,
      messageId: msg.id,
    );
    final hasAlbumGroup =
        widget.albumMessages != null && widget.albumMessages!.length > 1;
    final mqSize = MediaQuery.sizeOf(context);
    final isMobileDialog = mqSize.shortestSide < 600 || mqSize.width < 760;
    final totalMs =
        _videoDuration.inMilliseconds > 0 ? _videoDuration.inMilliseconds : 1;
    final activePos =
        _isGalleryHorizontalSeeking
            ? _gallerySeekPreviewPos
            : _gallerySliderPreviewPos ?? _videoPosition;
    final posMs = activePos.inMilliseconds.clamp(0, totalMs);
    final bufMs = _videoBuffer.inMilliseconds.clamp(posMs, totalMs);

    final topFocusChain = <FocusNode>[
      _topTitleFocusNode,
      if (isVideo && _videoPlayer != null) _topProxyFocusNode,
      if (hasAlbumGroup) _topScopeFocusNode,
      if (isVideo && widget.onOpenMiniPlayer != null) _topMiniFocusNode,
      if (hasAlbumGroup && widget.onQueueAlbumDownload != null)
        _topAlbumQueueFocusNode,
      _topSaveFocusNode,
      if (att?.url.isNotEmpty ?? false) _topQueueFocusNode,
      _topCloseFocusNode,
    ];

    final barHeaderFocusChain = <FocusNode>[
      if (msg.text.trim().isNotEmpty) _barToggleCaptionFocusNode,
      _barMovePosFocusNode,
      _barHideControlsFocusNode,
    ];

    final bottomFocusChain = <FocusNode>[
      _playPauseFocusNode,
      _rewindFocusNode,
      _forwardFocusNode,
      if (list.length > 1) ...[
        _bottomPrevFocusNode,
        _bottomNextFocusNode,
      ],
      _speedFocusNode,
      _aspectModeFocusNode,
      if (msg.text.trim().isNotEmpty) _bottomToggleCaptionFocusNode,
      _bottomMovePosFocusNode,
      _bottomHideBarFocusNode,
      if (_videoPlayer != null) _bottomProxyFocusNode,
      _bottomSaveFocusNode,
      if (att?.url.isNotEmpty ?? false) _bottomQueueFocusNode,
      _bottomExitFocusNode,
      _muteFocusNode,
    ];

    final activeThumbNode =
        list.length > 1 ? _getThumbFocusNode(_currentIndex) : null;

    final topDownDefault = _controlsHidden
        ? _restoreControlsFocusNode
        : (list.length > 1
            ? _prevItemFocusNode
            : (isVideo ? _scrubberFocusNode : _focusNode));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleGalleryBackPress();
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (_isGalleryBackKey(event.logicalKey)) {
            if (event is KeyDownEvent) {
              _handleGalleryBackPress();
            }
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            final wasHidden = _controlsHidden;
            _pokeGalleryControls();
            if (wasHidden) {
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _pokeGalleryControls(),
          onPointerMove: (_) => _pokeGalleryControls(),
          onPointerHover: (_) => _pokeGalleryControls(),
          child: MobileEdgeSwipeBack(
          enabled: !widget.appState.tvMode,
          onBack: () => Navigator.of(context).pop(),
          child: Dialog(
        backgroundColor: isMobileDialog ? Colors.black : Colors.transparent,
        insetPadding:
            isMobileDialog ? EdgeInsets.zero : const EdgeInsets.all(14),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 1. Main Media Stage (Video Player OR Interactive Zoomable Photo)
            Positioned.fill(
              child: Focus(
                focusNode: _focusNode,
                autofocus: !isVideo,
                canRequestFocus: !isVideo,
                onFocusChange: (hasFocus) {
                  if (hasFocus) _pokeGalleryControls();
                  if (mounted) setState(() {});
                },
                onKeyEvent: (node, event) {
                  if (!node.hasPrimaryFocus) {
                    return KeyEventResult.ignored;
                  }
                  if (event is KeyDownEvent || event is KeyRepeatEvent) {
                    _pokeGalleryControls();
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                      if (isVideo) {
                        _seekRelative(-5);
                      } else if (event is KeyDownEvent) {
                        _step(-1);
                      }
                      return KeyEventResult.handled;
                    } else if (event.logicalKey ==
                        LogicalKeyboardKey.arrowRight) {
                      if (isVideo) {
                        _seekRelative(5);
                      } else if (event is KeyDownEvent) {
                        _step(1);
                      }
                      return KeyEventResult.handled;
                    } else if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _topSaveFocusNode.requestFocus();
                      return KeyEventResult.handled;
                    } else if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      if (isVideo) {
                        _playPauseFocusNode.requestFocus();
                      } else {
                        node.focusInDirection(TraversalDirection.down);
                      }
                      return KeyEventResult.handled;
                    } else if (event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.space ||
                            event.logicalKey == LogicalKeyboardKey.select ||
                            event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey ==
                                LogicalKeyboardKey.numpadEnter ||
                            event.logicalKey ==
                                LogicalKeyboardKey.gameButtonA) &&
                        isVideo) {
                      _toggleGalleryPlayback();
                      return KeyEventResult.handled;
                    } else if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.keyM &&
                        isVideo) {
                      _toggleMute();
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: isVideo
                  ? Listener(
                      onPointerSignal: (signal) {
                        if (signal is PointerScrollEvent) {
                          _stepVolume(signal.scrollDelta.dy < 0 ? 5 : -5);
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (_controlsHidden) {
                            setState(() => _controlsHidden = false);
                            _scrollActiveThumbnailIntoView(animated: false);
                          } else {
                            _toggleGalleryPlayback();
                          }
                        },
                        onDoubleTap: () => _toggleGalleryPlayback(),
                        onHorizontalDragStart: (details) {
                          if (details.globalPosition.dx <= 40.0) return;
                          if (_videoPlayer == null) return;
                          setState(() {
                            _isGalleryHorizontalSeeking = true;
                            _gallerySeekStartPos = _videoPosition;
                            _gallerySeekPreviewPos = _videoPosition;
                          });
                        },
                        onHorizontalDragUpdate: (details) {
                          if (!_isGalleryHorizontalSeeking ||
                              _videoPlayer == null) {
                            return;
                          }
                          final screenWidth =
                              MediaQuery.sizeOf(context).width.clamp(240.0, 1920.0);
                          final maxSec = _videoDuration.inSeconds > 0
                              ? _videoDuration.inSeconds
                              : (att?.duration != null && att!.duration > 0
                                  ? att.duration
                                  : 300);
                          final spanSec = maxSec.clamp(60, 240);
                          final deltaMs =
                              ((details.delta.dx / screenWidth) * spanSec * 1000)
                                  .round();
                          final nextMs =
                              (_gallerySeekPreviewPos.inMilliseconds + deltaMs)
                                  .clamp(0, maxSec * 1000);
                          setState(() {
                            _gallerySeekPreviewPos =
                                Duration(milliseconds: nextMs);
                          });
                        },
                        onHorizontalDragEnd: (_) {
                          if (!_isGalleryHorizontalSeeking) return;
                          final target = _gallerySeekPreviewPos;
                          setState(() {
                            _isGalleryHorizontalSeeking = false;
                            _videoPosition = target;
                          });
                          _seekGalleryVideo(target);
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                          // Poster thumbnail while first video frame loads
                          Image.network(
                            thumbUrl,
                            headers: widget.appState.api.authHeaders,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                          if (_videoController != null)
                            LayoutBuilder(
                              builder: (context, stageConstraints) {
                                final vp = _videoPlayer?.state.videoParams;
                                final rawW = vp?.dw ??
                                    vp?.w ??
                                    _videoPlayer?.state.width ??
                                    0;
                                final rawH = vp?.dh ??
                                    vp?.h ??
                                    _videoPlayer?.state.height ??
                                    0;
                                final rot = ((vp?.rotate ?? 0) % 360 + 360) % 360;
                                final effW = (rot == 90 || rot == 270) ? rawH : rawW;
                                final effH = (rot == 90 || rot == 270) ? rawW : rawH;
                                return Video(
                                  key: ValueKey('gallery_video_${msg.id}'),
                                  controller: _videoController!,
                                  width: stageConstraints.maxWidth,
                                  height: stageConstraints.maxHeight,
                                  fit: _galleryAspectMode == 'cover'
                                      ? BoxFit.cover
                                      : BoxFit.contain,
                                  aspectRatio: (effW > 0 && effH > 0)
                                      ? effW / effH
                                      : null,
                                  fill: Colors.black,
                                  controls: NoVideoControls,
                                );
                              },
                            ),
                          if (_isGalleryHorizontalSeeking)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xD90B121A),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFF5EB5F7),
                                  width: 1.2,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${_gallerySeekPreviewPos >= _gallerySeekStartPos ? '⏩ 快进' : '⏪ 快退'}  ${_fmtClock(_gallerySeekPreviewPos)} / ${_fmtClock(_videoDuration)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: [
                                        ui.FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${(_gallerySeekPreviewPos.inSeconds - _gallerySeekStartPos.inSeconds) >= 0 ? '+' : ''}${_gallerySeekPreviewPos.inSeconds - _gallerySeekStartPos.inSeconds} 秒',
                                    style: const TextStyle(
                                      color: Color(0xFF5EB5F7),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (_isVideoBuffering ||
                              (_videoPosition == Duration.zero &&
                                  (_videoPlayer?.state.width ?? 0) == 0))
                            IgnorePointer(
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xD80A111A),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFF5EB5F7)
                                        .withValues(alpha: 0.45),
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x77000000),
                                      blurRadius: 16,
                                      offset: Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.6,
                                        color: Color(0xFF5EB5F7),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _videoPosition == Duration.zero
                                          ? '正在连接 Telegram 视频流，加载首帧画面...'
                                          : '正在缓冲 Telegram 视频数据...',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      alignment: WrapAlignment.center,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF5EB5F7)
                                                .withValues(alpha: 0.16),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            widget.appState.proxyService
                                                        .resolveEffectiveRoute(
                                                      RequestScenario.telegram,
                                                    ) ==
                                                    ScenarioRouteMode.proxyNode
                                                ? '代理: ${widget.appState.proxyService.resolveNodeForScenario(RequestScenario.telegram)?.displayTitle ?? "加速节点"}'
                                                : '通道: 客户端直连',
                                            style: const TextStyle(
                                              color: Color(0xFF5EB5F7),
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        if (_videoPlayer != null)
                                          VideoDownloadSpeedBadge(
                                            player: _videoPlayer!,
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else if (!_isVideoPlaying)
                            Container(
                              width: 68,
                              height: 68,
                              decoration: BoxDecoration(
                                color: _focusNode.hasPrimaryFocus
                                    ? const Color(0xFF3E99EE)
                                    : const Color(0xA6000000),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _focusNode.hasPrimaryFocus
                                      ? const Color(0xFFFFE066)
                                      : Colors.white38,
                                  width: _focusNode.hasPrimaryFocus ? 2.2 : 1.5,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 42,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : InteractiveViewer(
                      key: ValueKey('gallery_photo_${msg.id}'),
                      minScale: 0.5,
                      maxScale: 5.0,
                      child: Image.network(
                        thumbUrl,
                        headers: widget.appState.api.authHeaders,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                            size: 56,
                          ),
                        ),
                      ),
                    ),
              ),
            ),

            // 2. Top Official Telegram Action & Counter Bar
            if (!_controlsHidden)
              Positioned(
                top: isMobileDialog ? 10 : 6,
                left: isMobileDialog ? 8 : 12,
                right: isMobileDialog ? 8 : 12,
                child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_topTitleHidden)
                            Transform.translate(
                              offset: _topTitleDragOffset,
                              child: GestureDetector(
                                onPanUpdate: (details) {
                                  setState(() {
                                    _topTitleDragOffset += details.delta;
                                  });
                                },
                                onDoubleTap: () {
                                  setState(() {
                                    _topTitleDragOffset = Offset.zero;
                                  });
                                },
                                child: _buildGalleryTvButton(
                                  focusNode: _topTitleFocusNode,
                                  icon: isVideo
                                      ? Icons.videocam_rounded
                                      : Icons.photo_outlined,
                                  iconColor: const Color(0xFF5EB5F7),
                                  bgColor: const Color(0xCC0F1720),
                                  label: [
                                    '${_currentIndex + 1}/${list.length}',
                                    (att?.displayName ??
                                            (isVideo ? '视频' : '图片'))
                                        .characters
                                        .take(isMobileDialog ? 10 : 22)
                                        .toString(),
                                    if (att != null &&
                                        att.formattedSize.isNotEmpty)
                                      att.formattedSize,
                                    '✕',
                                  ].join(' · '),
                                  onTap: () => setState(
                                    () => _topTitleHidden = true,
                                  ),
                                  rightFocusNode: _neighborInChain(
                                    topFocusChain,
                                    _topTitleFocusNode,
                                    1,
                                  ),
                                  downFocusNode: topDownDefault,
                                ),
                              ),
                            )
                          else
                            _buildGalleryTvButton(
                              focusNode: _topTitleFocusNode,
                              icon: Icons.title_rounded,
                              label: '显示文件名',
                              onTap: () => setState(() {
                                _topTitleHidden = false;
                                _topTitleDragOffset = Offset.zero;
                              }),
                              rightFocusNode: _neighborInChain(
                                topFocusChain,
                                _topTitleFocusNode,
                                1,
                              ),
                              downFocusNode: topDownDefault,
                            ),
                          if (isVideo && _videoPlayer != null) ...[
                            const SizedBox(width: 6),
                            Video115AccelerateButton(
                              api: widget.appState.api,
                              downloadUrlBuilder: _resolveGallery115DownloadUrl,
                              videoNameBuilder: _resolveGallery115VideoName,
                              headersBuilder: () =>
                                  widget.appState.api.authHeaders,
                              telegramAccountId: widget.accountId,
                              player: _videoPlayer,
                              selected115Url: _usingGallery115Direct
                                  ? _activeGalleryStreamUrl
                                  : null,
                              overlayStyle: true,
                              compact: isMobileDialog,
                              onResolved: _applyGallery115Stream,
                            ),
                            const SizedBox(width: 6),
                            VideoProxyNodeSelector(
                              focusNode: _topProxyFocusNode,
                              leftFocusNode: _neighborInChain(
                                topFocusChain,
                                _topProxyFocusNode,
                                -1,
                                edgeTarget:
                                    list.length > 1 ? _prevItemFocusNode : null,
                              ),
                              rightFocusNode: _neighborInChain(
                                topFocusChain,
                                _topProxyFocusNode,
                                1,
                              ),
                              downFocusNode: topDownDefault,
                              proxyService: widget.appState.proxyService,
                              scenario: RequestScenario.telegram,
                              overlayStyle: true,
                              onProxyChanged: _switchGalleryProxy,
                            ),
                            const SizedBox(width: 6),
                            VideoProxyStatsButton(
                              proxyService: widget.appState.proxyService,
                              scenario: RequestScenario.telegram,
                              isShowingStats: _showProxyStatsOverlay,
                              overlayStyle: true,
                              compact: isMobileDialog,
                              onToggle: () {
                                setState(() {
                                  _showProxyStatsOverlay =
                                      !_showProxyStatsOverlay;
                                });
                              },
                            ),
                          ],
                          if (hasAlbumGroup) ...[
                            const SizedBox(width: 6),
                            _buildGalleryTvButton(
                              focusNode: _topScopeFocusNode,
                              icon: Icons.filter_none_rounded,
                              label: _albumScopeOnly
                                  ? '本组 (${widget.albumMessages!.length})'
                                  : '全部 (${widget.photoMessages.length})',
                              bgColor: _albumScopeOnly
                                  ? const Color(0xFF2B5278)
                                  : const Color(0xCC0F1720),
                              onTap: _toggleScopeMode,
                              leftFocusNode: _neighborInChain(
                                topFocusChain,
                                _topScopeFocusNode,
                                -1,
                                edgeTarget:
                                    list.length > 1 ? _prevItemFocusNode : null,
                              ),
                              rightFocusNode: _neighborInChain(
                                topFocusChain,
                                _topScopeFocusNode,
                                1,
                              ),
                              downFocusNode: topDownDefault,
                            ),
                          ],
                          if (isVideo && widget.onOpenMiniPlayer != null) ...[
                            const SizedBox(width: 6),
                            _buildGalleryTvButton(
                              focusNode: _topMiniFocusNode,
                              icon: Icons.picture_in_picture_alt_rounded,
                              label: '小窗',
                              onTap: () {
                                final posSec = _videoPosition.inSeconds;
                                _videoPlayer?.pause();
                                Navigator.of(context).pop();
                                widget.onOpenMiniPlayer!(msg, posSec);
                              },
                              leftFocusNode: _neighborInChain(
                                topFocusChain,
                                _topMiniFocusNode,
                                -1,
                                edgeTarget:
                                    list.length > 1 ? _prevItemFocusNode : null,
                              ),
                              rightFocusNode: _neighborInChain(
                                topFocusChain,
                                _topMiniFocusNode,
                                1,
                              ),
                              downFocusNode: topDownDefault,
                            ),
                          ],
                          if (hasAlbumGroup &&
                              widget.onQueueAlbumDownload != null) ...[
                            const SizedBox(width: 6),
                            _buildGalleryTvButton(
                              focusNode: _topAlbumQueueFocusNode,
                              icon: _queuedAlbum
                                  ? Icons.check_circle_rounded
                                  : Icons.collections_bookmark_outlined,
                              iconColor: _queuedAlbum
                                  ? const Color(0xFF69F0AE)
                                  : Colors.white,
                              bgColor: _queuedAlbum
                                  ? const Color(0xFF1F6E43)
                                  : const Color(0xCC1E2C3A),
                              label: _queueingAlbum
                                  ? '转存中...'
                                  : (_queuedAlbum
                                      ? '已入队 ✓'
                                      : '整组(${widget.albumMessages!.length})'),
                              onTap: _queueingAlbum
                                  ? null
                                  : () =>
                                      _handleQueueAlbum(widget.albumMessages!),
                              leftFocusNode: _neighborInChain(
                                topFocusChain,
                                _topAlbumQueueFocusNode,
                                -1,
                                edgeTarget:
                                    list.length > 1 ? _prevItemFocusNode : null,
                              ),
                              rightFocusNode: _neighborInChain(
                                topFocusChain,
                                _topAlbumQueueFocusNode,
                                1,
                              ),
                              downFocusNode: topDownDefault,
                            ),
                          ],
                          const SizedBox(width: 6),
                          _buildGalleryTvButton(
                            focusNode: _topSaveFocusNode,
                            icon: _savedLocalIds.contains(msg.id)
                                ? Icons.check_circle_rounded
                                : Icons.download_rounded,
                            iconColor: _savedLocalIds.contains(msg.id)
                                ? const Color(0xFF69F0AE)
                                : Colors.white,
                            bgColor: _savedLocalIds.contains(msg.id)
                                ? const Color(0xFF1F6E43)
                                : const Color(0xCC1E2C3A),
                            label: _savingLocalIds.contains(msg.id)
                                ? '保存中...'
                                : (_savedLocalIds.contains(msg.id)
                                    ? '已存 ✓'
                                    : '存本机'),
                            onTap: _savingLocalIds.contains(msg.id)
                                ? null
                                : () => _handleSaveLocal(msg),
                            leftFocusNode: _neighborInChain(
                              topFocusChain,
                              _topSaveFocusNode,
                              -1,
                              edgeTarget:
                                  list.length > 1 ? _prevItemFocusNode : null,
                            ),
                            rightFocusNode: _neighborInChain(
                              topFocusChain,
                              _topSaveFocusNode,
                              1,
                            ),
                            downFocusNode: topDownDefault,
                          ),
                          if (att?.url.isNotEmpty ?? false) ...[
                            const SizedBox(width: 6),
                            _buildGalleryTvButton(
                              focusNode: _topQueueFocusNode,
                              icon: _queuedIds.contains(msg.id)
                                  ? Icons.check_circle_rounded
                                  : (_failedIds.contains(msg.id)
                                      ? Icons.error_outline_rounded
                                      : Icons.cloud_download_outlined),
                              iconColor: _queuedIds.contains(msg.id)
                                  ? const Color(0xFF69F0AE)
                                  : Colors.white,
                              bgColor: _queuedIds.contains(msg.id)
                                  ? const Color(0xFF1F6E43)
                                  : (_failedIds.contains(msg.id)
                                      ? const Color(0xFF8B2635)
                                      : const Color(0xFF2B5278)),
                              label: _queueingIds.contains(msg.id)
                                  ? '添加中...'
                                  : (_queuedIds.contains(msg.id)
                                      ? '已入队 ✓'
                                      : '转存'),
                              onTap: _queueingIds.contains(msg.id)
                                  ? null
                                  : () => _handleQueueSingle(msg),
                              leftFocusNode: _neighborInChain(
                                topFocusChain,
                                _topQueueFocusNode,
                                -1,
                              ),
                              rightFocusNode: _neighborInChain(
                                topFocusChain,
                                _topQueueFocusNode,
                                1,
                              ),
                              downFocusNode: topDownDefault,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _buildGalleryTvIconButton(
                    focusNode: _topCloseFocusNode,
                    icon: Icons.close_rounded,
                    label: isMobileDialog ? null : '关闭',
                    iconSize: 18,
                    onTap: () => Navigator.of(context).pop(),
                    leftFocusNode: _neighborInChain(
                      topFocusChain,
                      _topCloseFocusNode,
                      -1,
                    ),
                    rightFocusNode:
                        list.length > 1 ? _nextItemFocusNode : null,
                    downFocusNode: list.length > 1
                        ? _nextItemFocusNode
                        : (isVideo ? _scrubberFocusNode : _focusNode),
                  ),
                ],
              ),
            ),

            // 2a. Floating movable / hideable / closable download speed tag on Telegram video stage
            if (isVideo && _videoPlayer != null)
              Positioned(
                top: isMobileDialog ? 54 : 52,
                right: 14,
                child: VideoDownloadSpeedBadge(
                  player: _videoPlayer!,
                  compact: true,
                ),
              ),

            // 2b. Floating Animated HUD Banner inside Gallery Lightbox
            Positioned(
              top: 54,
              child: IgnorePointer(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.92, end: 1.0).animate(anim),
                      child: child,
                    ),
                  ),
                  child: _dialogHudText == null
                      ? const SizedBox.shrink()
                      : Container(
                          key: ValueKey('${_dialogHudState}_$_dialogHudText'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: _dialogHudState == 'success'
                                ? const Color(0xEE165B36)
                                : (_dialogHudState == 'error'
                                    ? const Color(0xEE7A1F2B)
                                    : const Color(0xEE182636)),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: _dialogHudState == 'success'
                                  ? const Color(0xFF4ADE80)
                                  : (_dialogHudState == 'error'
                                      ? const Color(0xFFF87171)
                                      : const Color(0xFF5EB5F7)),
                              width: 1.2,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 14,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_dialogHudState == 'loading')
                                const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF5EB5F7),
                                  ),
                                )
                              else
                                Icon(
                                  _dialogHudState == 'success'
                                      ? Icons.check_circle_rounded
                                      : Icons.error_outline_rounded,
                                  size: 18,
                                  color: _dialogHudState == 'success'
                                      ? const Color(0xFF69F0AE)
                                      : const Color(0xFFFF8A80),
                                ),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 460),
                                child: Text(
                                  _dialogHudText!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),

            // 3. Left / Right Navigation Arrows (`←` / `→`)
            if (!_controlsHidden && list.length > 1) ...[
              Positioned(
                left: 12,
                child: _buildGalleryTvIconButton(
                  focusNode: _prevItemFocusNode,
                  icon: Icons.chevron_left_rounded,
                  label: isMobileDialog ? null : '上一项',
                  iconSize: 28,
                  onTap: () => _step(-1),
                  upFocusNode: _topSaveFocusNode,
                  downFocusNode:
                      isVideo ? _scrubberFocusNode : _focusNode,
                  leftFocusNode: _nextItemFocusNode,
                  rightFocusNode: _nextItemFocusNode,
                ),
              ),
              Positioned(
                right: 12,
                child: _buildGalleryTvIconButton(
                  focusNode: _nextItemFocusNode,
                  icon: Icons.chevron_right_rounded,
                  label: isMobileDialog ? null : '下一项',
                  iconSize: 28,
                  onTap: () => _step(1),
                  upFocusNode: _topCloseFocusNode,
                  downFocusNode:
                      isVideo ? _scrubberFocusNode : _focusNode,
                  leftFocusNode: _prevItemFocusNode,
                  rightFocusNode: _prevItemFocusNode,
                ),
              ),
            ],

            // 4a. Draggable & Hideable Video Title / Caption Small Window (`视频标题/简介小窗`)
            if (!_controlsHidden && msg.text.trim().isNotEmpty && !_captionHidden)
              Positioned(
                bottom: isVideo ? (list.length > 1 ? 182 : 112) : 82,
                child: Transform.translate(
                  offset: _captionDragOffset,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) {
                      setState(() {
                        _captionDragOffset += details.delta;
                      });
                    },
                    onDoubleTap: () {
                      setState(() {
                        _captionDragOffset = Offset.zero;
                      });
                    },
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: isMobileDialog ? 330 : 680,
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 6, 8, 7),
                      decoration: BoxDecoration(
                        color: const Color(0xCC0B121A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2, right: 6),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 15,
                              color: Colors.white54,
                            ),
                          ),
                          Flexible(
                            child: Text(
                              msg.text.trim(),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (_captionDragOffset != Offset.zero)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: InkWell(
                                onTap: () => setState(
                                  () => _captionDragOffset = Offset.zero,
                                ),
                                child: const Icon(
                                  Icons.restart_alt_rounded,
                                  size: 15,
                                  color: Color(0xFF5EB5F7),
                                ),
                              ),
                            ),
                          InkWell(
                            onTap: () => setState(() => _captionHidden = true),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 4b. Draggable & Hideable Bottom Controls Stack: Video Playback Progress Bar + Album Strip
            if (!_controlsHidden)
              Positioned(
                left: 16,
                right: 16,
                bottom: 6,
                child: Transform.translate(
                  offset: _controlsDragOffset,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Official Telegram 2-Tier Video Scrubber & Controls Bar (shown when active item is a Video)
                      if (isVideo)
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanUpdate: (details) {
                            setState(() {
                              _controlsDragOffset += details.delta;
                            });
                          },
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 1120),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.fromLTRB(12, 5, 12, 8),
                            decoration: BoxDecoration(
                              color: const Color(0xE60F1720),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white12),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black54,
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Top Drag Handle & Quick Hide/Title Bar (TV remote focusable!)
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.drag_indicator_rounded,
                                      size: 14,
                                      color: Colors.white54,
                                    ),
                                    const SizedBox(width: 4),
                                    const Flexible(
                                      child: Text(
                                        '按住可拖动进度条 · 遥控器可切换位置或隐藏',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 10.5,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    if (msg.text.trim().isNotEmpty) ...[
                                      _buildGalleryTvButton(
                                        focusNode: _barToggleCaptionFocusNode,
                                        icon: _captionHidden
                                            ? Icons.subtitles_outlined
                                            : Icons.subtitles_off_outlined,
                                        iconColor: const Color(0xFF5EB5F7),
                                        label: _captionHidden
                                            ? '显示标题窗'
                                            : '隐藏标题窗',
                                        onTap: () => setState(
                                          () =>
                                              _captionHidden = !_captionHidden,
                                        ),
                                        upFocusNode: list.length > 1
                                            ? _prevItemFocusNode
                                            : _topSaveFocusNode,
                                        downFocusNode: _scrubberFocusNode,
                                        leftFocusNode: _neighborInChain(
                                          barHeaderFocusChain,
                                          _barToggleCaptionFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          barHeaderFocusChain,
                                          _barToggleCaptionFocusNode,
                                          1,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    _buildGalleryTvButton(
                                      focusNode: _barMovePosFocusNode,
                                      icon: Icons.open_with_rounded,
                                      iconColor: const Color(0xFF81C784),
                                      label: _controlsPosPresetLabel,
                                      onTap: _cycleControlsAndCaptionPosition,
                                      upFocusNode: list.length > 1
                                          ? _prevItemFocusNode
                                          : _topSaveFocusNode,
                                      downFocusNode: _scrubberFocusNode,
                                      leftFocusNode: _neighborInChain(
                                        barHeaderFocusChain,
                                        _barMovePosFocusNode,
                                        -1,
                                      ),
                                      rightFocusNode: _neighborInChain(
                                        barHeaderFocusChain,
                                        _barMovePosFocusNode,
                                        1,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    _buildGalleryTvButton(
                                      focusNode: _barHideControlsFocusNode,
                                      icon: Icons.visibility_off_outlined,
                                      iconColor: const Color(0xFFFFB74D),
                                      label: '隐藏进度条',
                                      onTap: _hideControlsBar,
                                      upFocusNode: list.length > 1
                                          ? _nextItemFocusNode
                                          : _topCloseFocusNode,
                                      downFocusNode: _scrubberFocusNode,
                                      leftFocusNode: _neighborInChain(
                                        barHeaderFocusChain,
                                        _barHideControlsFocusNode,
                                        -1,
                                      ),
                                      rightFocusNode: _neighborInChain(
                                        barHeaderFocusChain,
                                        _barHideControlsFocusNode,
                                        1,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                // Row 1: Dedicated TV Focusable Progress Scrubber
                          StatefulBuilder(
                            builder: (scrubCtx, setScrubState) {
                              return Focus(
                                focusNode: _scrubberFocusNode,
                                onFocusChange: (hasFocus) {
                                  if (hasFocus) _pokeGalleryControls();
                                  setScrubState(() {});
                                },
                                onKeyEvent: (node, event) {
                                  if (event is! KeyDownEvent &&
                                      event is! KeyRepeatEvent) {
                                    return KeyEventResult.ignored;
                                  }
                                  _pokeGalleryControls();
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowLeft) {
                                    _seekRelative(-5);
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowRight) {
                                    _seekRelative(5);
                                    return KeyEventResult.handled;
                                  }
                                  if (event is KeyDownEvent &&
                                      event.logicalKey ==
                                          LogicalKeyboardKey.arrowDown) {
                                    _playPauseFocusNode.requestFocus();
                                    return KeyEventResult.handled;
                                  }
                                  if (event is KeyDownEvent &&
                                      event.logicalKey ==
                                          LogicalKeyboardKey.arrowUp) {
                                    if (barHeaderFocusChain.isNotEmpty) {
                                      barHeaderFocusChain.first.requestFocus();
                                    } else if (list.length > 1) {
                                      _prevItemFocusNode.requestFocus();
                                    } else {
                                      _topSaveFocusNode.requestFocus();
                                    }
                                    return KeyEventResult.handled;
                                  }
                                  if (event is KeyDownEvent &&
                                      (event.logicalKey ==
                                              LogicalKeyboardKey.select ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.enter ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.numpadEnter ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.space ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.gameButtonA)) {
                                    _toggleGalleryPlayback();
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                child: Builder(
                                  builder: (innerScrubCtx) {
                                    final isScrubFocused =
                                        Focus.of(innerScrubCtx).hasPrimaryFocus;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isScrubFocused
                                            ? const Color(0x383E99EE)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: isScrubFocused
                                              ? const Color(0xFFFFE066)
                                              : Colors.transparent,
                                          width: isScrubFocused ? 2.0 : 1.0,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            _fmtClock(_videoPosition),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              fontFeatures: [
                                                ui.FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            child: ExcludeFocus(
                                              child: SliderTheme(
                                                data: SliderTheme.of(context)
                                                    .copyWith(
                                                  trackHeight:
                                                      isScrubFocused ? 5.0 : 3.5,
                                                  thumbShape:
                                                      RoundSliderThumbShape(
                                                    enabledThumbRadius:
                                                        isScrubFocused
                                                            ? 7.5
                                                            : 6.0,
                                                  ),
                                                  overlayShape:
                                                      const RoundSliderOverlayShape(
                                                    overlayRadius: 12,
                                                  ),
                                                  activeTrackColor:
                                                      isScrubFocused
                                                          ? const Color(
                                                              0xFFFFE066,
                                                            )
                                                          : const Color(
                                                              0xFF3E99EE,
                                                            ),
                                                  secondaryActiveTrackColor:
                                                      Colors.white54,
                                                  inactiveTrackColor:
                                                      Colors.white24,
                                                  thumbColor: isScrubFocused
                                                      ? const Color(0xFFFFE066)
                                                      : Colors.white,
                                                ),
                                                child: Slider(
                                                  value: posMs.toDouble(),
                                                  secondaryTrackValue:
                                                      bufMs.toDouble(),
                                                  min: 0,
                                                  max: totalMs.toDouble(),
                                                  onChanged:
                                                      _previewGallerySlider,
                                                  onChangeEnd:
                                                      _commitGallerySlider,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Text(
                                            _fmtClock(_videoDuration),
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                              fontFeatures: [
                                                ui.FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                          if (isScrubFocused &&
                                              !isMobileDialog) ...[
                                            const SizedBox(width: 8),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF3E99EE),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: const Text(
                                                '◀▶ 调进度 · ▲ 左右切换 · ▼ 切按钮',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          // Row 2: Focusable Control Buttons Row + Always-Visible Pinned Volume Control
                          Row(
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildGalleryTvIconButton(
                                        focusNode: _playPauseFocusNode,
                                        autofocus: true,
                                        icon: _isVideoPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        label: _isVideoPlaying ? '暂停' : '播放',
                                        onTap: () => _toggleGalleryPlayback(),
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _playPauseFocusNode,
                                          -1,
                                          edgeTarget: list.length > 1
                                              ? _prevItemFocusNode
                                              : null,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _playPauseFocusNode,
                                          1,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _rewindFocusNode,
                                        icon: Icons.replay_5_rounded,
                                        label: '快退5s',
                                        onTap: () => _seekRelative(-5),
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _rewindFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _rewindFocusNode,
                                          1,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _forwardFocusNode,
                                        icon: Icons.forward_5_rounded,
                                        label: '快进5s',
                                        onTap: () => _seekRelative(5),
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _forwardFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _forwardFocusNode,
                                          1,
                                        ),
                                      ),
                                      if (list.length > 1) ...[
                                        const SizedBox(width: 6),
                                        _buildGalleryTvIconButton(
                                          focusNode: _bottomPrevFocusNode,
                                          icon: Icons.skip_previous_rounded,
                                          label: '上一项',
                                          onTap: () => _step(-1),
                                          upFocusNode: _prevItemFocusNode,
                                          downFocusNode: activeThumbNode,
                                          leftFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomPrevFocusNode,
                                            -1,
                                          ),
                                          rightFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomPrevFocusNode,
                                            1,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _buildGalleryTvIconButton(
                                          focusNode: _bottomNextFocusNode,
                                          icon: Icons.skip_next_rounded,
                                          label: '下一项',
                                          onTap: () => _step(1),
                                          upFocusNode: _nextItemFocusNode,
                                          downFocusNode: activeThumbNode,
                                          leftFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomNextFocusNode,
                                            -1,
                                          ),
                                          rightFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomNextFocusNode,
                                            1,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _speedFocusNode,
                                        icon: Icons.speed_rounded,
                                        label: '${_playbackSpeed}x',
                                        onTap: _cycleSpeed,
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _speedFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _speedFocusNode,
                                          1,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _aspectModeFocusNode,
                                        icon: _galleryAspectMode == 'cover'
                                            ? Icons.crop_free_rounded
                                            : Icons.aspect_ratio_rounded,
                                        label: _galleryAspectMode == 'cover'
                                            ? '铺满'
                                            : '适应',
                                        onTap: _cycleGalleryAspectMode,
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _aspectModeFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _aspectModeFocusNode,
                                          1,
                                        ),
                                      ),
                                      if (msg.text.trim().isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        _buildGalleryTvIconButton(
                                          focusNode:
                                              _bottomToggleCaptionFocusNode,
                                          icon: _captionHidden
                                              ? Icons.subtitles_outlined
                                              : Icons.subtitles_off_outlined,
                                          label: _captionHidden
                                              ? '显示标题'
                                              : '隐藏标题',
                                          onTap: () => setState(
                                            () => _captionHidden =
                                                !_captionHidden,
                                          ),
                                          upFocusNode: _scrubberFocusNode,
                                          downFocusNode: activeThumbNode,
                                          leftFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomToggleCaptionFocusNode,
                                            -1,
                                          ),
                                          rightFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomToggleCaptionFocusNode,
                                            1,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _bottomMovePosFocusNode,
                                        icon: Icons.open_with_rounded,
                                        label: _controlsPosPresetLabel,
                                        onTap: _cycleControlsAndCaptionPosition,
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomMovePosFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomMovePosFocusNode,
                                          1,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _bottomHideBarFocusNode,
                                        icon: Icons.visibility_off_outlined,
                                        label: '隐藏进度条',
                                        onTap: _hideControlsBar,
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomHideBarFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomHideBarFocusNode,
                                          1,
                                        ),
                                      ),
                                      if ((Platform.isAndroid ||
                                              Platform.isIOS) &&
                                          !widget.appState.tvMode) ...[
                                        const SizedBox(width: 6),
                                        _buildGalleryTvIconButton(
                                          icon: Icons.screen_rotation_rounded,
                                          label: '横竖屏',
                                          onTap: _toggleGalleryOrientation,
                                          upFocusNode: _scrubberFocusNode,
                                        ),
                                      ],
                                      if (_videoPlayer != null) ...[
                                        const SizedBox(width: 6),
                                        Video115AccelerateButton(
                                          api: widget.appState.api,
                                          downloadUrlBuilder:
                                              _resolveGallery115DownloadUrl,
                                          videoNameBuilder:
                                              _resolveGallery115VideoName,
                                          headersBuilder: () =>
                                              widget.appState.api.authHeaders,
                                          telegramAccountId: widget.accountId,
                                          player: _videoPlayer,
                                          selected115Url: _usingGallery115Direct
                                              ? _activeGalleryStreamUrl
                                              : null,
                                          overlayStyle: true,
                                          compact: true,
                                          onResolved: _applyGallery115Stream,
                                        ),
                                        const SizedBox(width: 6),
                                        VideoProxyNodeSelector(
                                          focusNode: _bottomProxyFocusNode,
                                          upFocusNode: _scrubberFocusNode,
                                          leftFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomProxyFocusNode,
                                            -1,
                                          ),
                                          rightFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomProxyFocusNode,
                                            1,
                                          ),
                                          proxyService:
                                              widget.appState.proxyService,
                                          scenario: RequestScenario.telegram,
                                          overlayStyle: true,
                                          compact: true,
                                          onProxyChanged: _switchGalleryProxy,
                                        ),
                                        const SizedBox(width: 6),
                                        VideoProxyStatsButton(
                                          proxyService:
                                              widget.appState.proxyService,
                                          scenario: RequestScenario.telegram,
                                          isShowingStats:
                                              _showProxyStatsOverlay,
                                          overlayStyle: true,
                                          compact: true,
                                          onToggle: () {
                                            setState(() {
                                              _showProxyStatsOverlay =
                                                  !_showProxyStatsOverlay;
                                            });
                                          },
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _bottomSaveFocusNode,
                                        icon: _savedLocalIds.contains(msg.id)
                                            ? Icons.check_circle_rounded
                                            : Icons.download_rounded,
                                        label: _savingLocalIds.contains(msg.id)
                                            ? '保存中'
                                            : (_savedLocalIds.contains(msg.id)
                                                ? '已存 ✓'
                                                : '存本机'),
                                        onTap: _savingLocalIds.contains(msg.id)
                                            ? null
                                            : () => _handleSaveLocal(msg),
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomSaveFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomSaveFocusNode,
                                          1,
                                        ),
                                      ),
                                      if (att?.url.isNotEmpty ?? false) ...[
                                        const SizedBox(width: 6),
                                        _buildGalleryTvIconButton(
                                          focusNode: _bottomQueueFocusNode,
                                          icon: _queuedIds.contains(msg.id)
                                              ? Icons.check_circle_rounded
                                              : Icons.cloud_download_outlined,
                                          label: _queueingIds.contains(msg.id)
                                              ? '添加中'
                                              : (_queuedIds.contains(msg.id)
                                                  ? '已入队 ✓'
                                                  : '转存'),
                                          onTap: _queueingIds.contains(msg.id)
                                              ? null
                                              : () => _handleQueueSingle(msg),
                                          upFocusNode: _scrubberFocusNode,
                                          downFocusNode: activeThumbNode,
                                          leftFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomQueueFocusNode,
                                            -1,
                                          ),
                                          rightFocusNode: _neighborInChain(
                                            bottomFocusChain,
                                            _bottomQueueFocusNode,
                                            1,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      _buildGalleryTvIconButton(
                                        focusNode: _bottomExitFocusNode,
                                        icon: Icons.close_rounded,
                                        label: '退出全屏',
                                        onTap: () =>
                                            Navigator.of(context).pop(),
                                        upFocusNode: _scrubberFocusNode,
                                        downFocusNode: activeThumbNode,
                                        leftFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomExitFocusNode,
                                          -1,
                                        ),
                                        rightFocusNode: _neighborInChain(
                                          bottomFocusChain,
                                          _bottomExitFocusNode,
                                          1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                width: 1,
                                height: 22,
                                color: Colors.white24,
                              ),
                              const SizedBox(width: 8),
                              // Always-Visible Pinned Volume Control (never scrolled out of view!)
                              Listener(
                                onPointerSignal: (signal) {
                                  if (signal is PointerScrollEvent) {
                                    _stepVolume(
                                      signal.scrollDelta.dy < 0 ? 5 : -5,
                                    );
                                  }
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildGalleryTvIconButton(
                                      focusNode: _muteFocusNode,
                                      icon: _isMuted || _volume <= 0
                                          ? Icons.volume_off_rounded
                                          : (_volume < 50
                                              ? Icons.volume_down_rounded
                                              : Icons.volume_up_rounded),
                                      label: isMobileDialog
                                          ? null
                                          : (_isMuted || _volume <= 0
                                              ? '已静音'
                                              : '音量'),
                                      onTap: _toggleMute,
                                      upFocusNode: _scrubberFocusNode,
                                      downFocusNode: activeThumbNode,
                                      leftFocusNode: _neighborInChain(
                                        bottomFocusChain,
                                        _muteFocusNode,
                                        -1,
                                      ),
                                      rightFocusNode: list.length > 1
                                          ? _nextItemFocusNode
                                          : null,
                                    ),
                                    SizedBox(
                                      width: isMobileDialog ? 56 : 84,
                                      child: ExcludeFocus(
                                        child: SliderTheme(
                                          data: SliderTheme.of(context)
                                              .copyWith(
                                            trackHeight: 3.2,
                                            thumbShape:
                                                const RoundSliderThumbShape(
                                              enabledThumbRadius: 6.0,
                                            ),
                                            overlayShape:
                                                const RoundSliderOverlayShape(
                                              overlayRadius: 10,
                                            ),
                                            activeTrackColor:
                                                const Color(0xFF5EB5F7),
                                            inactiveTrackColor: Colors.white24,
                                            thumbColor: Colors.white,
                                          ),
                                          child: Slider(
                                            value: (_isMuted ? 0.0 : _volume)
                                                .clamp(0.0, 100.0),
                                            min: 0,
                                            max: 100,
                                            onChanged: _setVolume,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: isMobileDialog ? 30 : 34,
                                      child: Text(
                                        '${(_isMuted ? 0 : _volume.round())}%',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: [
                                            ui.FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Official Telegram Bottom Album / Gallery Thumbnail Strip (`photo` + `video`)
                  if (list.length > 1)
                    Container(
                      height: 64,
                      constraints: const BoxConstraints(maxWidth: 880),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xD90B121A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: ListView.separated(
                        controller: _thumbStripScrollController,
                        scrollDirection: Axis.horizontal,
                        shrinkWrap: true,
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (_, idx) {
                          final item = list[idx];
                          final itemAtt = item.attachment;
                          final itemIsVideo = itemAtt?.isVideo ?? false;
                          final active = idx == _currentIndex;
                          final itemThumbUrl =
                              widget.appState.api.buildTelegramThumbnailUrl(
                            accountId: widget.accountId,
                            peer: widget.chat.peer,
                            messageId: item.id,
                          );
                          return StatefulBuilder(
                            builder: (thumbCtx, setThumbState) {
                              return Focus(
                                focusNode: _getThumbFocusNode(idx),
                                onFocusChange: (hasFocus) {
                                  if (thumbCtx.mounted) setThumbState(() {});
                                  if (hasFocus) {
                                    _pokeGalleryControls();
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (thumbCtx.mounted) {
                                        Scrollable.ensureVisible(
                                          thumbCtx,
                                          alignment: 0.5,
                                          duration:
                                              const Duration(milliseconds: 140),
                                        );
                                      }
                                    });
                                  }
                                },
                                onKeyEvent: (node, event) {
                                  if (event is! KeyDownEvent &&
                                      event is! KeyRepeatEvent) {
                                    return KeyEventResult.ignored;
                                  }
                                  _pokeGalleryControls();
                                  if (event is KeyDownEvent &&
                                      (event.logicalKey ==
                                              LogicalKeyboardKey.select ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.enter ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.numpadEnter ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.space ||
                                          event.logicalKey ==
                                              LogicalKeyboardKey.gameButtonA)) {
                                    _selectIndex(idx);
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowLeft) {
                                    final prevIdx =
                                        (idx - 1).clamp(0, list.length - 1);
                                    _getThumbFocusNode(prevIdx).requestFocus();
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowRight) {
                                    final nextIdx =
                                        (idx + 1).clamp(0, list.length - 1);
                                    _getThumbFocusNode(nextIdx).requestFocus();
                                    return KeyEventResult.handled;
                                  }
                                  if (event is KeyDownEvent &&
                                      event.logicalKey ==
                                          LogicalKeyboardKey.arrowUp) {
                                    if (isVideo) {
                                      _playPauseFocusNode.requestFocus();
                                    } else {
                                      _focusNode.requestFocus();
                                    }
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                child: Builder(
                                  builder: (innerThumbCtx) {
                                    final isThumbFocused =
                                        Focus.of(innerThumbCtx).hasPrimaryFocus;
                                    return GestureDetector(
                                      onTap: () => _selectIndex(idx),
                                      child: Container(
                                        width: 54,
                                        height: 54,
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                            color: isThumbFocused
                                                ? const Color(0xFFFFE066)
                                                : (active
                                                    ? const Color(0xFF00E5FF)
                                                    : Colors.white24),
                                            width: isThumbFocused
                                                ? 2.6
                                                : (active ? 2.5 : 1.0),
                                          ),
                                          boxShadow: active
                                              ? const [
                                                  BoxShadow(
                                                    color: Color(0x8000E5FF),
                                                    blurRadius: 8,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.network(
                                              itemThumbUrl,
                                              headers: widget
                                                  .appState.api.authHeaders,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  Container(
                                                color: const Color(0xFF141E2B),
                                                alignment: Alignment.center,
                                                child: Icon(
                                                  itemIsVideo
                                                      ? Icons.videocam_rounded
                                                      : Icons.image_outlined,
                                                  size: 18,
                                                  color: Colors.white54,
                                                ),
                                              ),
                                            ),
                                            if (itemIsVideo)
                                              Container(
                                                color: active
                                                    ? const Color(0x2600E5FF)
                                                    : const Color(0x4D000000),
                                                alignment: Alignment.center,
                                                child: Icon(
                                                  active
                                                      ? Icons.equalizer_rounded
                                                      : Icons
                                                          .play_circle_fill_rounded,
                                                  size: 20,
                                                  color: active
                                                      ? const Color(0xFFFFE066)
                                                      : Colors.white,
                                                ),
                                              ),
                                            // Top-left sequence number / active indicator badge
                                            Positioned(
                                              top: 2,
                                              left: 2,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 3.5,
                                                  vertical: 0.5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: active
                                                      ? const Color(0xEE0088CC)
                                                      : const Color(0xB3000000),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  active
                                                      ? '${idx + 1}·播'
                                                      : '${idx + 1}',
                                                  style: TextStyle(
                                                    color: active
                                                        ? const Color(
                                                            0xFFFFE066,
                                                          )
                                                        : Colors.white70,
                                                    fontSize: 8.5,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (itemIsVideo &&
                                                itemAtt != null &&
                                                itemAtt.duration > 0)
                                              Positioned(
                                                bottom: 2,
                                                right: 2,
                                                child: Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 3,
                                                    vertical: 0.5,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        const Color(0xB3000000),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      4,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    _fmtClock(
                                                      Duration(
                                                        seconds:
                                                            itemAtt.duration,
                                                      ),
                                                    ),
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 8.5,
                                                      fontWeight:
                                                          FontWeight.w600,
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
                              );
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          )
        else
          Positioned(
            right: 0,
            bottom: 0,
            child: Focus(
              focusNode: _restoreControlsFocusNode,
              autofocus: true,
              onKeyEvent: (node, event) {
                if (_isGalleryBackKey(event.logicalKey)) {
                  if (event is KeyDownEvent) {
                    _handleGalleryBackPress();
                  }
                  return KeyEventResult.handled;
                }
                if (event is KeyDownEvent || event is KeyRepeatEvent) {
                  _restoreControlsBar();
                  _scheduleGalleryAutoHide();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: const SizedBox(width: 1, height: 1),
            ),
          ),
        if (_showProxyStatsOverlay)
          VideoProxyStatsDetailPanel(
            proxyService: widget.appState.proxyService,
            scenario: RequestScenario.telegram,
            onClose: () {
              if (mounted) {
                setState(() => _showProxyStatsOverlay = false);
              }
            },
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

/// Official Telegram Music Track Card & Voice Message Player
/// - Music tracks (`att.isMusic`): Circular play/pause button with album cover thumbnail & progress ring + Song Title + Performer + interactive seek scrubber
/// - Voice messages (`att.isVoiceMessage`): Circular play/pause button + 28 interactive waveform bars + duration + speed badge
class _TelegramInlineAudioPlayer extends StatelessWidget {
  final AppState appState;
  final String accountId;
  final TelegramChat chat;
  final TelegramMessage message;
  final TelegramAttachment attachment;
  final _TgPalette tg;
  final bool isActive;
  final bool isPlaying;
  final bool isLoading;
  final String errorText;
  final Duration position;
  final Duration duration;
  final double speed;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onCycleSpeed;
  final bool isQueued;
  final VoidCallback? onQueueDownload;
  final VoidCallback onSaveLocal;

  const _TelegramInlineAudioPlayer({
    required this.appState,
    required this.accountId,
    required this.chat,
    required this.message,
    required this.attachment,
    required this.tg,
    required this.isActive,
    required this.isPlaying,
    required this.isLoading,
    required this.errorText,
    required this.position,
    required this.duration,
    required this.speed,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onCycleSpeed,
    required this.isQueued,
    this.onQueueDownload,
    required this.onSaveLocal,
  });

  String _fmtDur(Duration d) {
    final total = d.inSeconds.clamp(0, 86400);
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildPlayCircleButton({required bool isMusic}) {
    final hasCover =
        isMusic && (attachment.hasThumbnail || attachment.thumbnail.isNotEmpty);
    final thumbUrl = appState.api.buildTelegramThumbnailUrl(
      accountId: accountId,
      peer: chat.peer,
      messageId: message.id,
    );
    final totalMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;
    final progress =
        isActive ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      onTap: onTogglePlay,
      child: SizedBox(
        width: 46,
        height: 46,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tg.tgBlueBright,
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasCover)
                    Image.network(
                      thumbUrl,
                      headers: appState.api.authHeaders,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: tg.tgBlueBright,
                      ),
                    ),
                  if (hasCover)
                    const ColoredBox(
                      color: Color(0x59000000),
                    ),
                  Center(
                    child: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                  ),
                ],
              ),
            ),
            if (isActive && !isLoading)
              SizedBox(
                width: 46,
                height: 46,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.2,
                  color: Colors.white,
                  backgroundColor: tg.tgBlueBright.withValues(alpha: 0.25),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedBadge() {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onCycleSpeed,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 6,
          vertical: 1.5,
        ),
        decoration: BoxDecoration(
          color: tg.tgBlueBright.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '${speed}x',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: tg.tgBlueBright,
          ),
        ),
      ),
    );
  }

  Widget _buildMusicTrackDetails(double progress) {
    final showScrubber =
        isActive && (isPlaying || position.inMilliseconds > 0 || isLoading);
    final metaParts = <String>[
      attachment.musicPerformer,
      if (duration > Duration.zero) _fmtDur(duration),
      if (attachment.formattedSize.isNotEmpty) attachment.formattedSize,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          attachment.musicTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: isActive ? tg.tgBlueBright : tg.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        if (errorText.isNotEmpty)
          InkWell(
            onTap: onTogglePlay,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.refresh_rounded,
                  size: 13,
                  color: VideoPlatformTheme.danger,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    errorText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: VideoPlatformTheme.danger,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (showScrubber) ...[
          // Official Telegram Music Scrubber Bar when track is active
          LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (duration > Duration.zero && constraints.maxWidth > 0) {
                    final ratio =
                        (details.localPosition.dx / constraints.maxWidth)
                            .clamp(0.0, 1.0);
                    onSeek(
                      Duration(
                        milliseconds:
                            (duration.inMilliseconds * ratio).round(),
                      ),
                    );
                  }
                },
                onHorizontalDragUpdate: (details) {
                  if (duration > Duration.zero && constraints.maxWidth > 0) {
                    final ratio =
                        (details.localPosition.dx / constraints.maxWidth)
                            .clamp(0.0, 1.0);
                    onSeek(
                      Duration(
                        milliseconds:
                            (duration.inMilliseconds * ratio).round(),
                      ),
                    );
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: isLoading ? null : progress,
                      minHeight: 3.5,
                      color: tg.tgBlueBright,
                      backgroundColor: tg.textMuted.withValues(alpha: 0.28),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Text(
                '${_fmtDur(position)} / ${_fmtDur(duration)}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: tg.tgBlueBright,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  attachment.musicPerformer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: tg.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _buildSpeedBadge(),
            ],
          ),
        ] else
          Text(
            metaParts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: tg.textSecondary,
            ),
          ),
      ],
    );
  }

  Widget _buildVoiceMessageDetails(double progress) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Interactive 28-bar voice waveform
        LayoutBuilder(
          builder: (context, constraints) {
            const barCount = 28;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                if (isActive &&
                    duration > Duration.zero &&
                    constraints.maxWidth > 0) {
                  final ratio =
                      (details.localPosition.dx / constraints.maxWidth)
                          .clamp(0.0, 1.0);
                  onSeek(
                    Duration(
                      milliseconds: (duration.inMilliseconds * ratio).round(),
                    ),
                  );
                } else {
                  onTogglePlay();
                }
              },
              child: SizedBox(
                height: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: List.generate(barCount, (idx) {
                    final barRatio = idx / barCount;
                    final active = isActive && barRatio <= progress;
                    final seed = ((message.id + idx * 7) % 11) + 4;
                    final barH = (seed / 15.0) * 16.0;
                    return Container(
                      width: 3,
                      height: barH.clamp(4.0, 16.0),
                      decoration: BoxDecoration(
                        color: active
                            ? tg.tgBlueBright
                            : tg.textMuted.withValues(alpha: 0.38),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    );
                  }),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text(
              isActive
                  ? '${_fmtDur(position)} / ${_fmtDur(duration)}'
                  : _fmtDur(duration),
              style: TextStyle(
                fontSize: 11,
                color: tg.textSecondary,
              ),
            ),
            if (attachment.formattedSize.isNotEmpty) ...[
              Text(
                ' · ${attachment.formattedSize}',
                style: TextStyle(
                  fontSize: 11,
                  color: tg.textMuted,
                ),
              ),
            ],
            const Spacer(),
            _buildSpeedBadge(),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMusic = attachment.isMusic;
    final totalMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;
    final progress =
        isActive ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          _buildPlayCircleButton(isMusic: isMusic),
          const SizedBox(width: 10),
          Expanded(
            child: isMusic
                ? _buildMusicTrackDetails(progress)
                : _buildVoiceMessageDetails(progress),
          ),
          const SizedBox(width: 4),
          if (onQueueDownload != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: isQueued ? null : onQueueDownload,
              icon: Icon(
                isQueued
                    ? Icons.cloud_done_rounded
                    : Icons.cloud_download_outlined,
                size: 19,
                color:
                    isQueued ? const Color(0xFF4ECC5E) : tg.tgBlueBright,
              ),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onSaveLocal,
            icon: Icon(
              Icons.download_rounded,
              size: 18,
              color: tg.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
