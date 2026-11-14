# 流光视频 (M3U8 Client) — 全平台客户端

基于 `https://jp2.linsionwinwin.top:8081/` 后端接口构建的 **iOS / Android / macOS / Windows / Linux** 五端统一视频流媒体与离线下载客户端。

## 界面设计原则

- **常规主流视频平台视觉规范**：采用深色炭灰低噪点配色（`#0F1014` 主背景、`#17181E` 导航栏、`#1D1F27` 卡片面、`#00AEEC` 播放器品牌色），遵循 Bilibili / 腾讯视频 / Infuse 的常规影视客户端布局习惯。
- **响应式桌面端与移动端自适应**：
  - **桌面端 (macOS / Windows / Linux)**：顶部品牌栏 + 站点切换器 + 集成搜索框（支持“全网搜”开关）+ 左侧紧凑型分类导航栏 + 详情页左右分栏（左侧 16:9 硬件加速播放器，右侧剧集与播放线路面板）。
  - **移动端 (iOS / Android)**：顶部固定搜索与换源栏 + 标准五栏底部导航栏（首页、直播、下载、媒体库、我的）+ 详情页顶部置顶播放器与选集面板。

## 核心功能

1. **影视片库与 TVBox 多源聚合 (`/api/settings`, `/api/tvbox/sites`, `/api/vod/*`)**
   - 自动加载服务端配置的全部采集资源站与 TVBox 站点，支持按分类筛选、无限滚动翻页、Alist 目录层级浏览。
   - 支持**当前站点搜索**与**全网多源并发聚合搜索**。
   - 内置基于 `media_kit` (libmpv) 的全平台硬件加速播放器，支持自定义 `Referer`/`User-Agent` 请求头、客户端直连与服务端代理中转一键切换、倍速播放、自动跳过/续播历史进度、自动连播下一集。
2. **电视直播 (`/api/tvbox/lives`, `/api/tvbox/live/*`)**
   - 支持切换多个 TVBox 直播源、按频道分组筛选、多信号源切换以及频道可用性批量测速。
3. **下载中心与网页视频嗅探 (`/api/tasks`, `/api/download`, `/api/web/extract`)**
   - 实时轮询展示服务端下载任务进度、实时速率、分片进度。
   - 支持一键将当前观看剧集或批量勾选剧集加入服务端下载队列。
   - 支持新建 M3U8 / MP4 / 磁力链下载，内置网页视频流嗅探提取器，支持任务重试、删除、上传 115 网盘及直接在线播放已下载视频。
4. **媒体资料库 (`/api/files`, `/api/files/open`)**
   - 浏览服务端本地媒体目录，支持在线直接流式播放视频、`.ts` 一键转封装 `.mp4`、上传 115 网盘、新建文件夹、重命名及删除。
5. **云端观看历史与收藏同步 (`/api/tvbox/library`)**
   - 自动将观看进度（精确到秒与具体集数/线路）和影视收藏同步至服务端，跨设备无缝续播。

## 各平台运行与打包指南

```bash
# 1. 获取依赖
flutter pub get

# 2. 运行代码静态检查与测试
flutter analyze
flutter test

# 3. 桌面端构建与运行
flutter run -d macos
flutter build macos --release
flutter build windows --release
flutter build linux --release

# 4. 移动端构建与运行
flutter build apk --release
flutter build ios --release --no-codesign
```
