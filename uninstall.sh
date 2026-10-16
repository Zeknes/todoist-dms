#!/usr/bin/env bash
# 卸载：禁用插件 + 从 bar 移除 + 删除插件目录（会备份 settings.json）
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell"
PLUGIN_ID="todoistDms"
TARGET_DIR="$CONFIG_DIR/plugins/TodoistDMS"
SETTINGS="$CONFIG_DIR/settings.json"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

dms ipc call plugins disable "$PLUGIN_ID" || true

if [[ -f $SETTINGS ]]; then
    BACKUP="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$SETTINGS" "$BACKUP"
    echo "已备份 $SETTINGS → $BACKUP"
    python3 - "$SETTINGS" "$PLUGIN_ID" <<'PY'
import json, sys

path, plugin_id = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

changed = False
for bar in data.get("barConfigs") or []:
    for key in ("leftWidgets", "centerWidgets", "rightWidgets"):
        widgets = bar.get(key)
        if not widgets:
            continue
        kept = [w for w in widgets if w.get("id") != plugin_id]
        if len(kept) != len(widgets):
            bar[key] = kept
            changed = True

if changed:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    print("已从 bar 布局移除")
else:
    print("bar 布局里没有这个小组件")
PY
    dms restart || true
fi

rm -rf "$TARGET_DIR"
echo "已删除 $TARGET_DIR"
echo "注意：插件设置仍留在 $CONFIG_DIR/plugin_settings.json 的 $PLUGIN_ID 键下，需要的话手动删。"
