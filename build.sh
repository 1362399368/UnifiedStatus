#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
APP_PATH="${1:-/Applications/三合一状态.app}"
PACKAGE_PATH="${2:-}"

if (( $# > 2 )); then
  echo "用法: $0 [应用路径] [可选的 zip 输出路径]" >&2
  exit 2
fi

CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

/bin/rm -rf "$APP_PATH"
/bin/mkdir -p "$MACOS"
/bin/cp "$SOURCE_DIR/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$SOURCE_DIR/AppIcon.icns" ]]; then
  /bin/mkdir -p "$RESOURCES"
  /bin/cp "$SOURCE_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

echo "==> 正在编译 Universal 2 双架构（Apple Silicon + Intel）..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

/usr/bin/swiftc \
  -target arm64-apple-macos13.0 \
  -O \
  -framework AppKit \
  -framework Carbon \
  -framework CoreWLAN \
  -framework IOKit \
  -framework SystemConfiguration \
  -framework ServiceManagement \
  "$SOURCE_DIR/Onboarding.swift" \
  "$SOURCE_DIR/App.swift" \
  -o "$TMP_DIR/UnifiedStatus_arm64"

/usr/bin/swiftc \
  -target x86_64-apple-macos13.0 \
  -O \
  -framework AppKit \
  -framework Carbon \
  -framework CoreWLAN \
  -framework IOKit \
  -framework SystemConfiguration \
  -framework ServiceManagement \
  "$SOURCE_DIR/Onboarding.swift" \
  "$SOURCE_DIR/App.swift" \
  -o "$TMP_DIR/UnifiedStatus_x86_64"

/usr/bin/lipo -create "$TMP_DIR/UnifiedStatus_arm64" "$TMP_DIR/UnifiedStatus_x86_64" -output "$MACOS/UnifiedStatus"

/usr/bin/xattr -cr "$APP_PATH"
/usr/bin/codesign --force --deep --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

if [[ -n "$PACKAGE_PATH" ]]; then
  echo "==> 正在打包通用安装包..."
  /bin/mkdir -p "${PACKAGE_PATH:h}"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PACKAGE_PATH"
fi

echo "======================================"
echo "✅ 构建完成！"
echo "已安装到: $APP_PATH"
if [[ -n "$PACKAGE_PATH" ]]; then
  echo "安装包: $PACKAGE_PATH"
fi
echo "架构支持: $(/usr/bin/file "$MACOS/UnifiedStatus")"
echo "======================================"
