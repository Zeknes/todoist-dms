#!/usr/bin/env python3
"""DMS Todoist 插件的数据层。

所有子命令都往 stdout 打一份 JSON，QML 只负责渲染：

    {"ok": true, "tasks": [...], "projects": [...], "fetched_at": 1700000000}
    {"ok": false, "kind": "unauthorized", "http": 401, "message": "...", "detail": "..."}

kind 取值：no_token / unauthorized / rate_limited / server / not_found /
bad_request / network / timeout / unknown。message 是给用户看的中文文案。

token 只在这里读，只进 Authorization 头；不打印、不写日志、不回传。
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = os.environ.get("TODOIST_DMS_API_BASE", "https://api.todoist.com/api/v1").rstrip("/")

TOKEN_FILE_CANDIDATES = (
    "~/.config/todoist-dms/config.json",
    "~/.config/todoist-dms/token",
    "~/.config/todoist/token",
)

CONFIG_TOKEN_KEYS = ("apiToken", "api_token", "token", "apiKey", "api_key")

TASK_FIELDS = ("id", "content", "description", "project_id", "section_id", "parent_id",
               "labels", "priority", "due", "child_order", "day_order", "checked",
               "is_collapsed", "note_count")
PROJECT_FIELDS = ("id", "name", "color", "child_order", "is_favorite", "inbox_project", "is_archived")
SECTION_FIELDS = ("id", "project_id", "name", "section_order", "is_collapsed")


class ApiError(Exception):
    def __init__(self, kind, message, http=0, detail=""):
        super().__init__(message)
        self.kind = kind
        self.message = message
        self.http = http
        self.detail = detail


def _read_secret_file(path):
    p = os.path.expanduser(path)
    if not os.path.isfile(p):
        return ""
    try:
        with open(p, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _token_from_config_json(path):
    raw = _read_secret_file(path)
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except ValueError:
        return ""
    if not isinstance(data, dict):
        return ""
    for key in CONFIG_TOKEN_KEYS:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def resolve_token(explicit_path: str = ""):
    """返回 (token, 来源描述)。来源描述只用于“有没有配好”的提示，不含 token 本身。"""
    if explicit_path:
        # 显式指定了就只认它，读不到直接算没配，避免“设了 A 却在用 B”的误会
        path = os.path.expanduser(explicit_path)
        token = _token_from_config_json(path) if path.endswith(".json") else _read_secret_file(path)
        return (token, explicit_path) if token else ("", explicit_path)
    env_token = os.environ.get("TODOIST_DMS_API_KEY", "").strip()
    if env_token:
        return env_token, "环境变量 TODOIST_DMS_API_KEY"
    for candidate in TOKEN_FILE_CANDIDATES:
        path = os.path.expanduser(candidate)
        token = _token_from_config_json(path) if path.endswith(".json") else _read_secret_file(path)
        if token:
            return token, candidate
    return "", ""


def _classify_http_error(status: int, body: str, retry_after: str = ""):
    if status in (401, 403):
        return ApiError("unauthorized", "认证失败：token 无效或已过期（HTTP %d）" % status,
                        status, body)
    if status == 429:
        message = "请求过于频繁，已被 Todoist 限流（HTTP 429）"
        if retry_after:
            message += "，%s 秒后重试" % retry_after
        return ApiError("rate_limited", message, status, body)
    if status == 404:
        return ApiError("not_found", "任务不存在或已被删除（HTTP 404）", status, body)
    if 400 <= status < 500:
        return ApiError("bad_request", "请求被拒绝（HTTP %d）" % status, status, body)
    if status >= 500:
        return ApiError("server", "Todoist 服务端错误（HTTP %d），稍后重试" % status, status, body)
    return ApiError("unknown", "未知错误（HTTP %d）" % status, status, body)


def _classify_transport_error(exc: Exception):
    if isinstance(exc, socket.timeout) or isinstance(getattr(exc, "reason", None), socket.timeout):
        return ApiError("timeout", "请求超时，Todoist 或网络没有响应")
    reason = getattr(exc, "reason", exc)
    if isinstance(reason, socket.timeout):
        return ApiError("timeout", "请求超时，Todoist 或网络没有响应")
    if isinstance(exc, urllib.error.URLError):
        return ApiError("network", "网络连接失败：%s" % reason)
    return ApiError("network", "网络连接失败：%s" % exc)


def request(method, path, payload=None, token="", timeout=30.0, retry_on_429=True):
    url = API_BASE + path
    data = None
    headers = {"Accept": "application/json", "User-Agent": "dms-todoist-plugin/1.0"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"

    attempt = 0
    while True:
        attempt += 1
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
                return resp.status, body
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace") if exc.fp else ""
            retry_after = exc.headers.get("Retry-After", "") if exc.headers else ""
            if exc.code == 429 and retry_on_429 and attempt <= 1:
                delay = 1.0
                try:
                    delay = min(5.0, max(0.5, float(retry_after)))
                except (TypeError, ValueError):
                    pass
                time.sleep(delay)
                continue
            raise _classify_http_error(exc.code, body, retry_after) from None
        except Exception as exc:  # noqa: BLE001 - 统一转成分类错误
            classified = _classify_transport_error(exc)
            # 到 api.todoist.com 的链路偶发慢/断，读操作再给一次机会
            if classified.kind in ("timeout", "network") and retry_on_429 and attempt <= 1:
                time.sleep(0.5)
                continue
            raise classified from None


def _get_json(path, token, timeout):
    status, body = request("GET", path, token=token, timeout=timeout)
    try:
        return json.loads(body)
    except ValueError:
        raise ApiError("unknown", "Todoist 返回了无法解析的响应（HTTP %d）" % status,
                       status, body[:500]) from None


def _pages(path, token, timeout, params=None, key="results", limit=200):
    """按 cursor 翻完所有页。"""
    out = []
    cursor = None
    while True:
        query = dict(params or {})
        query["limit"] = str(limit)
        if cursor:
            query["cursor"] = cursor
        page = _get_json(path + "?" + urllib.parse.urlencode(query), token, timeout)
        items = page.get(key) or []
        if not isinstance(items, list):
            break
        out.extend(items)
        cursor = page.get("next_cursor") or page.get("next_cursor_after")
        if not cursor or not items:
            break
    return out


def _pick(source, fields):
    return {key: source[key] for key in fields if key in source}


def _due_compact(due):
    if not isinstance(due, dict):
        return None
    return {
        "date": due.get("date"),
        "datetime": due.get("datetime"),
        "string": due.get("string"),
        "is_recurring": bool(due.get("is_recurring")),
    }


def _task_compact(task):
    out = _pick(task, TASK_FIELDS)
    out["due"] = _due_compact(task.get("due"))
    return out


def cmd_snapshot(token, args):
    tasks = _pages("/tasks", token, args.timeout)
    projects = _pages("/projects", token, args.timeout)
    try:
        sections = _pages("/sections", token, args.timeout)
    except ApiError:
        sections = []
    return {
        "ok": True,
        "tasks": [_task_compact(t) for t in tasks],
        "projects": [_pick(p, PROJECT_FIELDS) for p in projects],
        "sections": [_pick(s, SECTION_FIELDS) for s in sections],
        "fetched_at": int(time.time()),
    }


def cmd_comment(token, args):
    status, _ = request("POST", "/comments",
                        payload={"task_id": args.task_id, "content": args.text},
                        token=token, timeout=args.timeout)
    return {"ok": True, "http": status}


def cmd_close(token, args):
    results = []
    for task_id in args.task_id:
        status, _ = request("POST", "/tasks/%s/close" % urllib.parse.quote(task_id),
                            token=token, timeout=args.timeout)
        results.append({"id": task_id, "http": status})
    return {"ok": True, "results": results}


def cmd_reopen(token, args):
    results = []
    for task_id in args.task_id:
        status, _ = request("POST", "/tasks/%s/reopen" % urllib.parse.quote(task_id),
                            token=token, timeout=args.timeout)
        results.append({"id": task_id, "http": status})
    return {"ok": True, "results": results}


def cmd_delete(token, args):
    results = []
    for task_id in args.task_id:
        status, _ = request("DELETE", "/tasks/%s" % urllib.parse.quote(task_id),
                            token=token, timeout=args.timeout)
        results.append({"id": task_id, "http": status})
    return {"ok": True, "results": results}


def cmd_token_info(token, args):
    return {"ok": bool(token), "source": args.token_source or ""}


def build_parser():
    parser = argparse.ArgumentParser(description="DMS Todoist 插件数据层")
    parser.add_argument("--token-file", default="", help="显式指定 token 文件或 config.json 路径")
    parser.add_argument("--timeout", type=float, default=30.0, help="单次 HTTP 超时（秒）")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("snapshot", help="拉取 任务/项目/分区 全量快照")

    comment = sub.add_parser("comment", help="给任务加评论")
    comment.add_argument("task_id")
    comment.add_argument("text")

    close = sub.add_parser("close", help="完成任务（可多条）")
    close.add_argument("task_id", nargs="+")

    reopen = sub.add_parser("reopen", help="撤销完成（可多条）")
    reopen.add_argument("task_id", nargs="+")

    delete = sub.add_parser("delete", help="删除任务（可多条）")
    delete.add_argument("task_id", nargs="+")

    sub.add_parser("token-info", help="只报告是否找到 token 及其来源")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    token, source = resolve_token(args.token_file)

    if args.command == "token-info":
        args.token_source = source
        print(json.dumps(cmd_token_info(token, args), ensure_ascii=False))
        return 0

    if not token:
        detail = ("请任选一种方式配置，然后重开面板：\n"
                  "1. 写入 ~/.config/todoist-dms/config.json 的 api_token 字段\n"
                  "2. 设置环境变量 TODOIST_DMS_API_KEY\n"
                  "3. 在插件设置里指定 token 文件路径\n"
                  "4. 复用 ~/.config/todoist/token")
        if args.token_file:
            detail = "插件设置里指定的 token 文件读不到或为空：%s\n\n" % args.token_file + detail
        print(json.dumps({
            "ok": False,
            "kind": "no_token",
            "http": 0,
            "message": "未找到 Todoist API token",
            "detail": detail,
        }, ensure_ascii=False))
        return 0

    handler = {
        "snapshot": cmd_snapshot,
        "comment": cmd_comment,
        "close": cmd_close,
        "reopen": cmd_reopen,
        "delete": cmd_delete,
    }[args.command]

    try:
        result = handler(token, args)
    except ApiError as exc:
        result = {
            "ok": False,
            "kind": exc.kind,
            "http": exc.http,
            "message": exc.message,
            "detail": exc.detail,
        }
    except Exception as exc:  # noqa: BLE001 - 兜底，避免崩在 QML 里看不见
        result = {"ok": False, "kind": "unknown", "http": 0,
                  "message": "插件内部错误：%s" % exc, "detail": ""}

    result.setdefault("token_source", source if args.command == "snapshot" else "")
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
