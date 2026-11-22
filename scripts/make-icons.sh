#!/usr/bin/env bash
# Regenerate DSH Flick's original artwork (menu bar template icons + app icon).
#
# The actual drawing lives in make-icons.py; this wrapper only picks a Python
# interpreter that has Pillow:
#   1. $PYTHON, when set;
#   2. the Pillow-enabled Python bundled with DeepSeek Harness ($HOME/.dsh);
#   3. python3 from Homebrew / the system.
#
# Usage:
#   ./scripts/make-icons.sh
#   PYTHON=/opt/homebrew/bin/python3 ./scripts/make-icons.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pick_python() {
    local candidates=()
    if [[ -n "${PYTHON:-}" ]]; then
        candidates+=("$PYTHON")
    fi
    local bundled
    for bundled in "$HOME"/.dsh/dsh-runtimes/*/dependencies/python/bin/python3; do
        [[ -x "$bundled" ]] && candidates+=("$bundled")
    done
    candidates+=("/opt/homebrew/bin/python3" "/usr/local/bin/python3" "$(command -v python3 || true)")

    local candidate
    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -c "import PIL" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! PYTHON_BIN="$(pick_python)"; then
    echo "错误：未找到带 Pillow 的 Python 解释器。" >&2
    echo "提示：安装 Pillow（pip3 install Pillow），或用 PYTHON=/path/to/python3 指定。" >&2
    exit 1
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/make-icons.py" "$@"
