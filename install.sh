#!/usr/bin/env bash
# 把本仓库安装为 DSH 技能（macOS / Linux）
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DST="$DSH_HOME/skills/paper-citation-guard"

FORCE=0
[ "${1:-}" = "-f" ] || [ "${1:-}" = "--force" ] && FORCE=1

echo
echo "安装 paper-citation-guard"
echo "  源目录：$SRC"
echo "  目标：  $DST"
echo

if [ -e "$DST" ]; then
    if [ "$FORCE" -ne 1 ]; then
        echo "目标已存在。加 -f 覆盖（会先备份）。" >&2
        exit 1
    fi
    BAK="$DST.bak-$(date +%Y%m%d-%H%M%S)"
    cp -R "$DST" "$BAK"
    echo "  已备份到 $BAK"
fi

mkdir -p "$DST"
for f in "$SRC"/*; do
    case "$(basename "$f")" in
        cache|config.json|.git) continue ;;
    esac
    cp -R "$f" "$DST/"
done
chmod +x "$DST/scripts/refcheck.sh" 2>/dev/null || true

if [ ! -f "$DST/config.json" ] && [ -f "$SRC/config.json" ]; then
    cp "$SRC/config.json" "$DST/config.json"
fi

echo "安装完成。下一步："
echo "  python3 \"$DST/scripts/refcheck.py\" doctor -InitConfig"
echo
echo "如果是新会话，需要在 agent 里重开会话才会加载这个技能。"