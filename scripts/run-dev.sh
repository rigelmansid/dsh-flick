#!/usr/bin/env bash
# Developer convenience: debug build + open the freshly built bundle.
#
# Usage:
#   ./scripts/run-dev.sh
#
# Quick iteration loop: edit Sources/, run this script, and the new build is
# launched (an already running DSH Flick instance is replaced).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_ROOT/dist/DSH Flick.app"

"$SCRIPT_DIR/build.sh" --debug "$@"

# Stop a previous debug instance started from dist/ so the new binary is used.
if pgrep -f "$APP_DIR/Contents/MacOS/DSHFlick" >/dev/null 2>&1; then
    printf '\033[1;36m[run-dev]\033[0m 停止旧的调试实例…\n'
    pkill -f "$APP_DIR/Contents/MacOS/DSHFlick" >/dev/null 2>&1 || true
    sleep 1
fi

printf '\033[1;36m[run-dev]\033[0m 启动 %s\n' "$APP_DIR"
open "$APP_DIR"
