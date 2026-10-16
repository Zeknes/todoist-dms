#!/usr/bin/env bash
# 开发用：把仓库里的插件文件同步到 DMS 并热重载，不用重启 DMS。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell"
PLUGIN_ID="todoistDms"
TARGET_DIR="$CONFIG_DIR/plugins/TodoistDMS"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

mkdir -p "$TARGET_DIR"
cp -r "$REPO_DIR/plugin/." "$TARGET_DIR/"

# DMS 的目录监听不一定会重新读已存在的 manifest，这里显式触发一次
dms ipc call plugin-scan reload "$PLUGIN_ID"
sleep 1
dms ipc call todoistDms status || true
