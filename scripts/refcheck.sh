#!/usr/bin/env bash
# paper-citation-guard 的 Unix 入口。
# 优先用 Python（各发行版自带），没有就退回 PowerShell 7。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
    exec python3 "$DIR/refcheck.py" "$@"
fi

if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "$DIR/refcheck.ps1" "$@"
fi

cat >&2 <<'EOF'
需要 Python 3 或 PowerShell 7，两个都没找到。

  Python 3（推荐）：macOS / Linux 通常自带；Windows 用 winget install Python.Python.3.12
  PowerShell 7：   brew install --cask powershell  |  sudo snap install powershell --classic

装任意一个即可。
EOF
exit 127