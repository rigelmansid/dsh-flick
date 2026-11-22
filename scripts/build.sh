#!/usr/bin/env bash
# Build "DSH Flick.app" (menu bar companion for DeepSeek Harness).
#
# SwiftPM is intentionally not used: this is a plain swiftc build of every
# file under Sources/, packaged by hand into a minimal .app bundle.
#
# Usage:
#   ./scripts/build.sh            # optimized release build -> dist/DSH Flick.app
#   ./scripts/build.sh --debug    # faster, debug build (no -O)
#   ./scripts/build.sh --run      # build, then open the app
#   ./scripts/build.sh --debug --run
#
# Requirements: macOS 14+, Xcode Command Line Tools (swiftc).
# The script is idempotent: dist/ and .build/modulecache are reused/replaced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="DSH Flick"
EXECUTABLE_NAME="DSHFlick"
BUNDLE_ID="com.rigelmansid.dshflick"
VERSION="0.4.0"
BUILD_NUMBER="4"
MIN_MACOS="14.0"

BUILD_DIR="$PROJECT_ROOT/.build"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
RESOURCES_DIR="$PROJECT_ROOT/Resources"

MODE="release"
RUN_AFTER_BUILD=0
UNIVERSAL=0

usage() {
    cat <<'EOF'
用法: ./scripts/build.sh [选项]

选项:
  --debug      使用调试构建（-Onone -g，编译更快）
  --universal  同时构建 arm64 + x86_64 的 universal 二进制
  --run        构建完成后自动打开 dist/DSH Flick.app
  -h, --help   显示本帮助

产物: dist/DSH Flick.app
EOF
}

for arg in "$@"; do
    case "$arg" in
        --debug) MODE="debug" ;;
        --universal) UNIVERSAL=1 ;;
        --run) RUN_AFTER_BUILD=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "错误: 未知选项: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[build]\033[0m 错误: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
    if command -v xcrun >/dev/null 2>&1 && xcrun -f swiftc >/dev/null 2>&1; then
        SWIFTC="$(xcrun -f swiftc)"
    else
        fail "未找到 swiftc。请先安装 Xcode Command Line Tools：xcode-select --install"
    fi
else
    SWIFTC="$(command -v swiftc)"
fi

ARCH="$(uname -m)"
HOST_TARGET="${ARCH}-apple-macos${MIN_MACOS}"
if [[ "$ARCH" == "arm64" ]]; then
    OTHER_ARCH="x86_64"
else
    OTHER_ARCH="arm64"
fi
OTHER_TARGET="${OTHER_ARCH}-apple-macos${MIN_MACOS}"
TARGET="$HOST_TARGET"

# ---------------------------------------------------------------------------
# Resources (menu bar template icons + app icon)
# ---------------------------------------------------------------------------
ensure_resources() {
    local missing=0
    for icon in MenuIcon.png MenuIcon@2x.png MenuIcon@3x.png; do
        [[ -f "$RESOURCES_DIR/$icon" ]] || missing=1
    done
    if [[ "$missing" -eq 1 ]]; then
        log "Resources 缺少菜单栏图标，尝试用 scripts/make-icons.sh 生成…"
        if [[ -x "$SCRIPT_DIR/make-icons.sh" ]]; then
            "$SCRIPT_DIR/make-icons.sh" || log "警告: 图标生成失败（将继续尝试构建）"
        fi
    fi
    for icon in MenuIcon.png MenuIcon@2x.png MenuIcon@3x.png; do
        [[ -f "$RESOURCES_DIR/$icon" ]] \
            || fail "缺少 Resources/${icon}。请运行 ./scripts/make-icons.sh 生成图标。"
    done

    # Verify the PNG dimensions expected by AppKit (18 / 36 / 54 px).
    local spec name expected dims width height
    for spec in "MenuIcon.png:18" "MenuIcon@2x.png:36" "MenuIcon@3x.png:54"; do
        name="${spec%%:*}"
        expected="${spec##*:}"
        dims="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$RESOURCES_DIR/$name" 2>/dev/null |
            /usr/bin/awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w " " h}')"
        width="${dims%% *}"
        height="${dims##* }"
        [[ "${width:-0}" == "$expected" && "${height:-0}" == "$expected" ]] \
            || fail "Resources/${name} 尺寸为 ${width:-?}x${height:-?}，应为 ${expected}x${expected}。请重新运行 ./scripts/make-icons.sh。"
    done

    if [[ ! -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
        log "Resources 缺少 AppIcon.icns，尝试用 scripts/make-icons.sh 生成…"
        if [[ -x "$SCRIPT_DIR/make-icons.sh" ]]; then
            "$SCRIPT_DIR/make-icons.sh" || log "警告: 图标生成失败（将继续尝试构建）"
        fi
        [[ -f "$RESOURCES_DIR/AppIcon.icns" ]] \
            || fail "缺少 Resources/AppIcon.icns。请运行 ./scripts/make-icons.sh 生成图标。"
    fi
}

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
log "项目目录: $PROJECT_ROOT"
log "目标: ${TARGET}（模式: ${MODE}）"

SWIFT_FILES=()
while IFS= read -r file; do
    SWIFT_FILES+=("$file")
done < <(find Sources -name '*.swift' -type f | LC_ALL=C sort)
[[ "${#SWIFT_FILES[@]}" -gt 0 ]] || fail "Sources/ 下没有找到任何 .swift 文件。"

log "编译 ${#SWIFT_FILES[@]} 个 Swift 源文件…"
mkdir -p "$BUILD_DIR"
BUILD_START="$(date +%s)"

compile_arch() {
    local target="$1"
    local output="$2"
    local arch="${target%%-*}"
    local flags=(-swift-version 5 -module-cache-path "$BUILD_DIR/modulecache-$arch")
    if [[ "$MODE" == "debug" ]]; then
        flags+=(-Onone -g)
    else
        flags+=(-O)
    fi
    flags+=(-target "$target")

    "$SWIFTC" "${flags[@]}" \
        -framework AppKit \
        -framework SwiftUI \
        -framework Combine \
        -framework WebKit \
        -framework Carbon \
        -o "$output" \
        "${SWIFT_FILES[@]}"
}

if [[ "$UNIVERSAL" -eq 1 ]]; then
    log "编译 universal（${HOST_TARGET} + ${OTHER_TARGET}）…"
    compile_arch "$HOST_TARGET" "$BUILD_DIR/${EXECUTABLE_NAME}.${ARCH}"
    compile_arch "$OTHER_TARGET" "$BUILD_DIR/${EXECUTABLE_NAME}.${OTHER_ARCH}"
    /usr/bin/lipo -create \
        "$BUILD_DIR/${EXECUTABLE_NAME}.${ARCH}" \
        "$BUILD_DIR/${EXECUTABLE_NAME}.${OTHER_ARCH}" \
        -o "$BUILD_DIR/$EXECUTABLE_NAME"
    TARGET="${ARCH}+${OTHER_ARCH}"
else
    log "编译 ${HOST_TARGET}…"
    compile_arch "$HOST_TARGET" "$BUILD_DIR/$EXECUTABLE_NAME"
fi

BUILD_SECONDS=$(( $(date +%s) - BUILD_START ))
log "编译完成（${BUILD_SECONDS}s）: .build/$EXECUTABLE_NAME"

ensure_resources

# ---------------------------------------------------------------------------
# Assemble the .app bundle
# ---------------------------------------------------------------------------
log "组装 .app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

for resource in MenuIcon.png MenuIcon@2x.png MenuIcon@3x.png AppIcon.icns; do
    cp "$RESOURCES_DIR/$resource" "$APP_DIR/Contents/Resources/$resource"
done
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>DSH Flick is an independent community companion for DeepSeek Harness. DeepSeek is a trademark of its owner.</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Ad-hoc code signature (no Developer ID required for local use)
# ---------------------------------------------------------------------------
log "ad-hoc 签名…"
/usr/bin/codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 \
    || fail "codesign 失败。"
if ! /usr/bin/codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
    fail "codesign 校验失败: $APP_DIR"
fi
log "签名校验通过（ad-hoc，仅本机使用）"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf '\n\033[1;32m✅ 构建成功\033[0m\n'
printf '   产物: %s\n' "$APP_DIR"
printf '   版本: %s (%s) · 模式: %s · %s\n' "$VERSION" "$BUILD_NUMBER" "$MODE" "$TARGET"
printf '   运行: open "%s"\n' "$APP_DIR"
printf '   安装: ./scripts/install.sh\n\n'

if [[ "$RUN_AFTER_BUILD" -eq 1 ]]; then
    log "启动应用…"
    open "$APP_DIR"
fi
