#!/usr/bin/env bash
# 把 Todoist 插件装进正在运行的 DMS。
#
#   ./install.sh                 # 只安装 + 启用插件（不动 bar 布局）
#   ./install.sh --with-bar      # 顺便把小组件加进 bar 的左侧（会备份 settings.json 并重启 DMS）
#   ./install.sh --dry-run       # 只打印会做什么
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell"
PLUGIN_ID="todoistDms"
TARGET_DIR="$CONFIG_DIR/plugins/TodoistDMS"
SETTINGS="$CONFIG_DIR/settings.json"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

WITH_BAR=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
    --with-bar) WITH_BAR=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
        sed -n '2,7p' "$0"
        exit 0
        ;;
    *)
        echo "未知参数：$arg" >&2
        exit 2
        ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "+ $*"
    else
        "$@"
    fi
}

echo "== 1/4 复制插件到 $TARGET_DIR"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ mkdir -p $TARGET_DIR && cp -r $REPO_DIR/plugin/. $TARGET_DIR/"
else
    mkdir -p "$TARGET_DIR"
    cp -r "$REPO_DIR/plugin/." "$TARGET_DIR/"
    chmod +x "$TARGET_DIR/scripts/todoist_api.py" 2>/dev/null || true
fi

echo "== 2/4 让 DMS 重新扫描插件目录"
run dms ipc call plugin-scan scan || echo "   扫描失败（DMS 没在跑？后面重启会重新扫）"
if [[ $DRY_RUN -eq 0 ]]; then
    sleep 2
fi

echo "== 3/4 启用插件 $PLUGIN_ID"
run dms ipc call plugins enable "$PLUGIN_ID" || echo "   启用失败（DMS 没在跑？）"
if [[ $DRY_RUN -eq 0 ]]; then
    sleep 1
    dms ipc call plugin-scan status "$PLUGIN_ID" || true
fi

if [[ $WITH_BAR -eq 1 ]]; then
    echo "== 4/4 把小组件加进 bar 右侧组的最左（rightWidgets[0]）"
    if [[ ! -f $SETTINGS ]]; then
        echo "   找不到 $SETTINGS，跳过" >&2
    elif [[ $DRY_RUN -eq 1 ]]; then
        echo "+ 备份 $SETTINGS 并把 $PLUGIN_ID 插到 barConfigs[].rightWidgets[0]"
    else
        BACKUP="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$SETTINGS" "$BACKUP"
        echo "   已备份到 $BACKUP"
        python3 - "$SETTINGS" "$PLUGIN_ID" <<'PY'
import json, sys

path, plugin_id = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

bars = data.get("barConfigs") or []
if not bars:
    sys.exit("settings.json 里没有 barConfigs，请手动在 设置 → DankBar 布局 里添加")

changed = False
for bar in bars:
    for key in ("leftWidgets", "centerWidgets"):
        widgets = bar.get(key) or []
        kept = [w for w in widgets if w.get("id") != plugin_id]
        if len(kept) != len(widgets):
            bar[key] = kept
            changed = True
    right = [w for w in (bar.get("rightWidgets") or []) if w.get("id") != plugin_id]
    if not bar.get("rightWidgets") or bar["rightWidgets"][0].get("id") != plugin_id:
        changed = True
    right.insert(0, {"id": plugin_id, "enabled": True})
    bar["rightWidgets"] = right

if not changed:
    print("   bar 右侧最左已经有这个小组件，未改动")
else:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    print("   已插到 barConfigs[].rightWidgets[0]，其余顺序不变")
PY
        run dms restart
    fi
else
    echo "== 4/4 跳过 bar 布局（要自动加进 bar 请用 --with-bar；也可在 设置 → DankBar 布局 里手动加）"
fi

echo "完成。查看状态：dms ipc call plugins list"
