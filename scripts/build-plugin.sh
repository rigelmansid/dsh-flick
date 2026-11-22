#!/usr/bin/env bash
# Build the DSH Flick app and stage it inside the DSH plugin package.
#
# The plugin package is installed from this directory (local directory
# installations are linked, not copied), so the staged app must stay under
# plugin/resources/ for the Host half to find it.
#
# Usage:
#   ./scripts/build-plugin.sh              # build app + copy into plugin/resources
#   ./scripts/build-plugin.sh --debug      # faster debug build
#   ./scripts/build-plugin.sh --universal  # arm64 + x86_64 distribution build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --debug) BUILD_ARGS+=("--debug") ;;
        --universal) BUILD_ARGS+=("--universal") ;;
        -h|--help)
            cat <<'EOF'
用法: ./scripts/build-plugin.sh [--debug] [--universal]

构建 dist/DSH Flick.app，并复制到 plugin/resources/DSH Flick.app。
EOF
            exit 0
            ;;
        *)
            echo "错误: 未知选项: $arg" >&2
            exit 2
            ;;
    esac
done

log() { printf '\033[1;36m[plugin]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[plugin]\033[0m 错误: %s\n' "$*" >&2; exit 1; }

log "构建菜单栏 app…"
"$SCRIPT_DIR/build.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} >/dev/null
SOURCE_APP="$PROJECT_ROOT/dist/DSH Flick.app"
[[ -x "$SOURCE_APP/Contents/MacOS/DSHFlick" ]] || fail "构建产物不完整: $SOURCE_APP"

DEST_DIR="$PROJECT_ROOT/plugin/resources"
DEST_APP="$DEST_DIR/DSH Flick.app"
log "复制到插件 resources…"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
[[ -x "$DEST_APP/Contents/MacOS/DSHFlick" ]] || fail "复制后缺少可执行文件: $DEST_APP"

log "校验插件包清单…"
for file in package.json cordis.patch.yml index.js client.js icon.svg; do
    [[ -f "$PROJECT_ROOT/plugin/$file" ]] || fail "插件包缺少: $file"
done
[[ -f "$DEST_APP/Contents/Info.plist" ]] || fail "app Info.plist 缺失"
[[ -f "$DEST_APP/Contents/Resources/AppIcon.icns" ]] || fail "app 图标缺失"

printf '\n\033[1;32m✅ 插件包已就绪\033[0m\n'
printf '   插件目录: %s\n' "$PROJECT_ROOT/plugin"
printf '   内置 app: %s\n' "$DEST_APP"
printf '   安装: 在 DSH 设置 → 插件中安装本地目录，或让 agent 调用 plugin_manager install_bundle\n\n'
