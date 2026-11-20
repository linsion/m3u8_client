#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export PATH="/opt/homebrew/Caskroom/flutter/3.27.1/flutter/bin:/opt/homebrew/Cellar/cocoapods/1.16.2_1/bin:/opt/homebrew/bin:$PATH"

APP_NAME="流光视频"
APP_SLUG="LiuguangVideo"
VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)"
BUILD_NUM="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f2)"
DIST_DIR="$ROOT_DIR/dist/v${VERSION}"

mkdir -p "$DIST_DIR"
echo "========================================================"
echo "  ${APP_NAME} (${APP_SLUG}) v${VERSION} (Build ${BUILD_NUM}) 全平台打包"
echo "  输出目录: ${DIST_DIR}"
echo "========================================================"

# 1. macOS Release (.app + .dmg + .zip)
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "▶ [1/5] 正在打包 macOS 桌面版 (Release)..."
  rm -rf build/macos/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules build/macos/ModuleCache.noindex
  flutter build macos --release

  MACOS_APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name "*.app" | head -n 1)"
  if [[ -n "$MACOS_APP_PATH" && -d "$MACOS_APP_PATH" ]]; then
    MACOS_ZIP="${DIST_DIR}/${APP_SLUG}-macOS-universal-v${VERSION}.zip"
    MACOS_DMG="${DIST_DIR}/${APP_SLUG}-macOS-universal-v${VERSION}.dmg"
    rm -f "$MACOS_ZIP" "$MACOS_DMG"

    ditto -c -k --sequesterRsrc --keepParent "$MACOS_APP_PATH" "$MACOS_ZIP"

    DMG_STAGE="$(mktemp -d)"
    cp -R "$MACOS_APP_PATH" "${DMG_STAGE}/${APP_NAME}.app"
    ln -s /Applications "${DMG_STAGE}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$MACOS_DMG" >/dev/null
    rm -rf "$DMG_STAGE"
    echo "  ✓ macOS DMG: $MACOS_DMG"
    echo "  ✓ macOS ZIP: $MACOS_ZIP"
  fi

  # 2. iOS Release (.app + .ipa)
  echo "▶ [2/5] 正在打包 iOS / iPadOS 版 (Release --no-codesign)..."
  if flutter build ios --release --no-codesign; then
    IOS_APP_PATH="build/ios/iphoneos/Runner.app"
    if [[ -d "$IOS_APP_PATH" ]]; then
      IOS_IPA="${DIST_DIR}/${APP_SLUG}-iOS-v${VERSION}-unsigned.ipa"
      rm -f "$IOS_IPA"
      IPA_STAGE="$(mktemp -d)"
      mkdir -p "${IPA_STAGE}/Payload"
      cp -R "$IOS_APP_PATH" "${IPA_STAGE}/Payload/Runner.app"
      (cd "$IPA_STAGE" && zip -qry "$IOS_IPA" Payload)
      rm -rf "$IPA_STAGE"
      echo "  ✓ iOS IPA: $IOS_IPA"
    fi
  else
    echo "  ⚠ 跳过本地 iOS IPA 打包（若 Xcode 提示缺少 iOS 平台组件，可执行: xcodebuild -downloadPlatform iOS）"
  fi

  # 2b. Apple TV (tvOS) Native Release (.app + .ipa)
  echo "▶ [2b/5] 正在打包 Apple TV (tvOS) 原生版 (Release --no-codesign)..."
  TVOS_APP_PATH="build/tvos/Build/Products/Release-appletvos/Runner.app"
  if ! xcodebuild -project tvos/Runner.xcodeproj -target Runner -sdk appletvos -configuration Release \
      MARKETING_VERSION="${VERSION}" CURRENT_PROJECT_VERSION="${BUILD_NUM}" \
      SYMROOT="$ROOT_DIR/build/tvos/Build/Products" \
      OBJROOT="$ROOT_DIR/build/tvos/Build/Intermediates.noindex" \
      CODE_SIGNING_ALLOWED=NO build >/dev/null 2>&1; then
    TVOS_SDK_PATH="$(xcrun --sdk appletvos --show-sdk-path)"
    mkdir -p "$TVOS_APP_PATH"
    cp -f tvos/Runner/Assets.car tvos/Runner/AppIcon.png tvos/Runner/AppIcon@2x.png tvos/Runner/TopShelfWide.png tvos/Runner/TopShelfWide@2x.png "$TVOS_APP_PATH/" 2>/dev/null || true
    cp -f tvos/Runner/Info.plist "$TVOS_APP_PATH/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Runner" "$TVOS_APP_PATH/Info.plist" || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.linsion.m3u8Client.tvos" "$TVOS_APP_PATH/Info.plist" || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$TVOS_APP_PATH/Info.plist" || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" "$TVOS_APP_PATH/Info.plist" || true
    printf "APPL????" > "$TVOS_APP_PATH/PkgInfo"
    xcrun --sdk appletvos swiftc \
      -O -whole-module-optimization \
      -sdk "$TVOS_SDK_PATH" \
      -target arm64-apple-tvos16.0 \
      -module-name Runner \
      -enable-bare-slash-regex \
      tvos/Runner/Models.swift \
      tvos/Runner/TvApiClient.swift \
      tvos/Runner/TvAppState.swift \
      tvos/Runner/TvPlayerView.swift \
      tvos/Runner/AppDelegate.swift \
      -o "$TVOS_APP_PATH/Runner"
  fi
  if [[ -d "$TVOS_APP_PATH" ]]; then
    cp -f tvos/Runner/Assets.car tvos/Runner/AppIcon.png tvos/Runner/AppIcon@2x.png tvos/Runner/TopShelfWide.png tvos/Runner/TopShelfWide@2x.png "$TVOS_APP_PATH/" 2>/dev/null || true
    TVOS_IPA="${DIST_DIR}/${APP_SLUG}-tvOS-v${VERSION}-unsigned.ipa"
    rm -f "$TVOS_IPA"
    IPA_STAGE="$(mktemp -d)"
    mkdir -p "${IPA_STAGE}/Payload"
    cp -R "$TVOS_APP_PATH" "${IPA_STAGE}/Payload/Runner.app"
    codesign --force --deep --sign - --timestamp=none "${IPA_STAGE}/Payload/Runner.app"
    (cd "$IPA_STAGE" && zip -qry "$TVOS_IPA" Payload)
    rm -rf "$IPA_STAGE"
    echo "  ✓ Apple TV (tvOS) IPA: $TVOS_IPA"
  fi
fi

# 3. Android & Android TV Release (.apk Universal + Split ABI + .aab)
echo "▶ [3/5] 正在打包 Android 手机 / 平板 / Android TV 通用版 (Release APK & AAB)..."
flutter build apk --release
if [[ -f "build/app/outputs/flutter-apk/app-release.apk" ]]; then
  cp "build/app/outputs/flutter-apk/app-release.apk" \
     "${DIST_DIR}/${APP_SLUG}-Android-Universal-v${VERSION}.apk"
  cp "build/app/outputs/flutter-apk/app-release.apk" \
     "${DIST_DIR}/${APP_SLUG}-AndroidTV-Universal-v${VERSION}.apk"
  echo "  ✓ Android Universal APK: ${DIST_DIR}/${APP_SLUG}-Android-Universal-v${VERSION}.apk"
  echo "  ✓ Android TV Universal APK: ${DIST_DIR}/${APP_SLUG}-AndroidTV-Universal-v${VERSION}.apk"
fi

flutter build apk --split-per-abi --release
for abi in arm64-v8a armeabi-v7a x86_64; do
  ABI_APK="build/app/outputs/flutter-apk/app-${abi}-release.apk"
  if [[ -f "$ABI_APK" ]]; then
    cp "$ABI_APK" "${DIST_DIR}/${APP_SLUG}-Android-${abi}-v${VERSION}.apk"
    echo "  ✓ Android ${abi} APK: ${DIST_DIR}/${APP_SLUG}-Android-${abi}-v${VERSION}.apk"
  fi
done

flutter build appbundle --release
if [[ -f "build/app/outputs/bundle/release/app-release.aab" ]]; then
  cp "build/app/outputs/bundle/release/app-release.aab" \
     "${DIST_DIR}/${APP_SLUG}-Android-Release-v${VERSION}.aab"
  echo "  ✓ Android Release AAB: ${DIST_DIR}/${APP_SLUG}-Android-Release-v${VERSION}.aab"
fi

# 4. Linux Release (when running on Linux)
if [[ "$(uname -s)" == "Linux" ]]; then
  echo "▶ [4/5] 正在打包 Linux x64 桌面版 (Release)..."
  flutter build linux --release
  LINUX_BUNDLE="build/linux/x64/release/bundle"
  if [[ -d "$LINUX_BUNDLE" ]]; then
    LINUX_TAR="${DIST_DIR}/${APP_SLUG}-Linux-x64-v${VERSION}.tar.gz"
    tar -czf "$LINUX_TAR" -C "$LINUX_BUNDLE" .
    echo "  ✓ Linux TAR.GZ: $LINUX_TAR"
  fi
fi

# 5. Generate SHA-256 Checksums
(
  cd "$DIST_DIR"
  shasum -a 256 *.* > SHA256SUMS.txt 2>/dev/null || true
)

echo "========================================================"
echo "✅ 打包完成！产物列表："
ls -lh "$DIST_DIR"
echo "========================================================"
