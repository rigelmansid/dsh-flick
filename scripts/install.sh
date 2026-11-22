#!/usr/bin/env bash
# Install / uninstall DSH Flick into ~/Applications.
#
# The app is a per-user menu bar agent (LSUIElement), so no sudo and no
# system-wide locations are involved. Default action: copy
# "dist/DSH Flick.app" -> "~/Applications/DSH Flick.app".
#
# Usage:
#   ./scripts/install.sh              # install (build first with ./scripts/build.sh)
#   ./scripts/install.sh --launch     # install and open the app
#   ./scripts/install.sh --uninstall  # stop the app, remove app + login item
#
# It never uses sudo; target paths are verified to live under $HOME first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="DSH Flick"
APP_BUNDLE="$APP_NAME.app"
SOURCE_APP="$PROJECT_ROOT/dist/$APP_BUNDLE"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_BUNDLE"
AGENT_LABEL="com.rigelmansid.dshflick"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
EXECUTABLE_PATH="$DEST_APP/Contents/MacOS/DSHFlick"

ACTION="install"
LAUNCH_AFTER_INSTALL=0

usage() {
    cat <<'EOF'
用法: ./scripts/install.sh [选项]

选项:
  --launch      安装完成后立即启动 DSH Flick
  --uninstall   卸载：退出应用，删除 ~/Applications/DSH Flick.app 与开机自启项
  -h, --help    显示本帮助

默认安装位置: ~/Applications/DSH Flick.app
无需 sudo，也不会写入系统目录。
EOF
}

log() { printf '\033[1;36m[install]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[install]\033[0m 错误: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH_AFTER_INSTALL=1 ;;
        --uninstall) ACTION="uninstall" ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "错误: 未知选项: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Safety: never install/remove anything outside the user's home directory.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
    fail "请勿使用 sudo 运行本脚本：DSH Flick 只安装到当前用户的 ~/Applications。"
fi

HOME_REAL="$(cd "$HOME" && pwd -P)"

assert_under_home() {
    local path="$1"
    case "$path" in
        "$HOME"/*) ;;
        *) fail "拒绝操作：路径不在用户主目录下：$path" ;;
    esac
    # Resolve symlinks of the deepest existing directory ancestor (the target may
    # not exist yet, and may itself be a file such as the LaunchAgent plist).
    local probe="$path"
    while [[ ! -d "$probe" && "$probe" != "/" ]]; do
        probe="$(dirname "$probe")"
    done
    local resolved
    resolved="$(cd "$probe" && pwd -P)"
    case "$resolved/" in
        "$HOME_REAL"/*) ;;
        *) fail "拒绝操作：路径解析后不在主目录下：$path -> $resolved" ;;
    esac
}

stop_running_app() {
    # Only kill DSH Flick instances started from the installed bundle.
    if pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
        log "正在退出已运行的 DSH Flick…"
        pkill -f "$EXECUTABLE_PATH" >/dev/null 2>&1 || true
        sleep 1
        if pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
            log "仍然存活，强制退出…"
            pkill -9 -f "$EXECUTABLE_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

remove_login_item() {
    log "移除开机自启项: $AGENT_PLIST"
    # The LaunchAgent is only loaded while "开机自启" is enabled in the menu.
    /bin/launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
    assert_under_home "$AGENT_PLIST"
    rm -f "$AGENT_PLIST"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "$ACTION" == "uninstall" ]]; then
    log "卸载 $APP_NAME …"
    stop_running_app
    remove_login_item

    assert_under_home "$DEST_APP"
    if [[ -d "$DEST_APP" ]]; then
        rm -rf "$DEST_APP"
        log "已删除: $DEST_APP"
    else
        log "未找到已安装的应用（${DEST_APP}），无需删除。"
    fi

    printf '\n\033[1;32m✅ 卸载完成\033[0m\n'
    printf '   DeepSeek Harness 本体未受任何影响。\n\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
command -v ditto >/dev/null 2>&1 || fail "未找到 ditto 命令（macOS 自带，不应缺失）。"

if [[ ! -d "$SOURCE_APP" ]]; then
    fail "未找到构建产物: $SOURCE_APP
请先运行: ./scripts/build.sh"
fi
if [[ ! -x "$SOURCE_APP/Contents/MacOS/DSHFlick" ]]; then
    fail "构建产物不完整（缺少可执行文件）: $SOURCE_APP
请重新运行: ./scripts/build.sh"
fi

log "安装 $APP_NAME 到 ~/Applications …"
assert_under_home "$DEST_APP"
mkdir -p "$DEST_DIR"

stop_running_app

# ditto preserves the code signature, resource forks and permissions.
assert_under_home "$DEST_APP"
rm -rf "$DEST_APP"
ditto -V "$SOURCE_APP" "$DEST_APP" || fail "复制应用失败。"

# Refresh LaunchServices so the new bundle shows up correctly.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST_APP" >/dev/null 2>&1 || true

printf '\n\033[1;32m✅ 安装完成\033[0m\n'
printf '   应用位置: %s\n' "$DEST_APP"
printf '   启动方式: open "%s"\n' "$DEST_APP"
printf '   也可以双击 Finder 中的「%s」或从菜单栏图标使用。\n' "$APP_NAME"
printf '   卸载命令: ./scripts/install.sh --uninstall\n\n'
printf '   提示：首次启动后菜单栏会出现 DSH Flick 图标（无 Dock 图标、无主窗口）。\n'
printf '   若系统提示后台项目，可在「系统设置 › 通用 › 登录项与扩展」中允许。\n\n'

if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
    log "启动 $APP_NAME …"
    open "$DEST_APP"
fi
