# todoist-dms

DankMaterialShell（DMS）的 Todoist 插件。在 bar 右侧组的最左显示「今天（含逾期）」任务数徽标，点开面板按 tab 看任务、点勾完成（4 秒内可撤销）。

面板结构与 macOS 版 `Zeknes/todoist-bar` 对齐：优先级色点 / 任务名 / 最多 2 个 @标签 / 中文日期胶囊（逾期红、今天绿、明天橙），错误分类提示。只读 + 完成 + 撤销，不做添加。


面板顶部是一排**平级 tab**：`今天` + 每个项目各一个，点 tab 切换；32px 行高的紧凑排版，内容少时面板自动收缩，内容多时按屏幕高度上限在列表内滚动。


## 目录结构

```
todoist-dms/
├── plugin/                       # 会被安装到 DMS 插件目录的内容
│   ├── plugin.json               # 插件清单（id=todoistDms）
│   ├── TodoistWidget.qml         # bar 小组件 + 面板（PluginComponent）
│   ├── TodoistSettings.qml       # 设置界面（PluginSettings）
│   └── scripts/todoist_api.py    # 唯一碰 token 的地方，Todoist API v1 客户端
├── install.sh                    # 安装 + 启用（--with-bar 顺便加进 bar 布局）
├── uninstall.sh                  # 禁用 + 从 bar 移除 + 删目录
├── reload.sh                     # 开发用：同步文件 + 热重载，不重启 DMS
└── README.md
```

安装位置：`~/.config/DankMaterialShell/plugins/TodoistDMS/`（DMS 从 `$XDG_CONFIG_HOME/DankMaterialShell/plugins/` 发现插件）。

## 安装 / 启用 / 关闭

```bash
./install.sh                # 复制插件 + 让 DMS 重扫 + 启用（不动 bar 布局）
./install.sh --with-bar     # 再顺手把小组件插到 bar 右侧组最左（备份 settings.json 后 dms restart）
./install.sh --dry-run      # 只打印会做什么

./reload.sh                 # 改完代码热重载（插件级，不重启 DMS）
./uninstall.sh              # 卸载（会备份 settings.json 并重启 DMS）
```

手动等价操作：

```bash
cp -r plugin/. ~/.config/DankMaterialShell/plugins/TodoistDMS/
dms ipc call plugin-scan scan                  # 让 DMS 重新扫插件目录
dms ipc call plugins enable todoistDms         # 启用 / 自动加载
dms ipc call plugin-scan reload todoistDms     # 改了 QML 后热重载
dms ipc call plugins disable todoistDms        # 关闭（不删文件）
```

bar 布局：设置 → DankBar 布局 里把 `todoistDms` 拖到想放的分区，或直接改
`~/.config/DankMaterialShell/settings.json` 的 `barConfigs[].rightWidgets`，把它放在数组第 0 位
（`{"id": "todoistDms", "enabled": true}`）后 `dms restart`。本机当前就是 `rightWidgets[0]`。

## Token

token 只由 `plugin/scripts/todoist_api.py` 读取，只进 `Authorization` 头，不写日志、不进仓库、不回传给 QML。

读取顺序（先命中先用）：

1. 插件设置里的「Token 文件路径」（填了就只认它；读不到按未配置处理）
2. `~/.config/todoist-dms/config.json` 的 `api_token` / `apiToken` / `token` 字段
3. 环境变量 `TODOIST_DMS_API_KEY`
4. `~/.config/todoist-dms/token`（纯 token 文本）
5. `~/.config/todoist/token`
6. `~/.agents/personal-skills/todoist/token`（本机 Todoist skill 自带的）

```bash
# 例子：独立配置（不动 skill 的 token）
mkdir -p ~/.config/todoist-dms
printf '{"api_token": "%s"}\n' "$(cat ~/.agents/personal-skills/todoist/token)" > ~/.config/todoist-dms/config.json
chmod 600 ~/.config/todoist-dms/config.json
```

## 设置项

设置 → 插件 → Todoist（`plugin_settings.json` 的 `todoistDms` 键）：

| 设置 | 默认 | 说明 |
| --- | --- | --- |
| 后台刷新间隔 | 5 分钟 | 1–60 分钟；另外每次打开面板都会刷新 |
| 面板显示上限 | 50 | **每个 tab** 最多显示多少条任务；超出时列表末尾提示「还有 N 条未显示」。同时是「子任务默认折叠」的阈值（见下） |
| 显示任务数徽标 | 开 | 关掉只剩图标 |
| 徽标包含逾期任务 | 开 | 关掉只算今天到期 |
| 显示任务标签 | 开 | 任务名下方最多 2 个 @标签 |
| Token 文件路径 | 空 | 见上表第 1 条 |

> 改设置请走 **设置 → 插件 → Todoist**。手工改 `plugin_settings.json` 不会同步到正在跑的 shell（DMS 把 pluginSettings 放在内存里），要么重启 DMS，要么用设置界面。

## 面板结构

- **一排平级 tab**：`今天` + **每个项目各一个 tab**（Inbox、购物清单、个人空间、快送熊 ……）。没有「项目」这一级中间层。
- **tab 顺序**：第一个固定「今天」，其余沿用 **Todoist API `/projects` 的返回顺序**（即 `child_order` —— 他在 Todoist App 里拖动项目得到的顺序），Inbox 也在它自己的位置。**要改顺序就在 Todoist App 里拖动项目**，插件不排序。
- tab 上显示该组未完成数（如 `个人空间 24`）。tab 多时这一排可以横向滚动（触摸板/拖动），不会挤爆面板宽度。
- **每个 tab 是独立视图，不跨 tab 去重**：一条任务可以既出现在「今天」tab（今天到期/逾期），也出现在它所属项目的 tab 里 —— 与 macOS 版一致。
- **每个 tab 最多显示 50 条**（设置项）：到上限后列表末尾显示「还有 N 条未显示」。
- **面板高度自适应**：内容少就收缩到刚好放下；上限约**屏幕可用高度的 90%**（只留 bar 厚度与上下留白），超过才在列表内滚动。切 tab / 窗口尺寸变化都会重算。
  本机实测（行高 32px）：**1440 屏一次能放 34 行**（第 35 条起滚动）；**1080 屏能放 25 行**（第 26 条起滚动）。
- **tab 选择在多实例（多屏 bar）间共享**：一个屏上切了 tab，另一屏的面板打开也是同一个 tab。
- 状态行（`今天 N 项 · 更新于 HH:mm · 子任务已折叠 · 还有 N 条未显示`）在 tab 条上方，10px 小字。

### 紧凑排版（行高 / 字号）

| 元素 | 之前 | 现在 |
| --- | --- | --- |
| 任务行高 | 46px（+2 间距） | **32px**（+2 间距）→ 同高度多放约 41% 的行 |
| 提示行高 | 30px | 24px |
| tab 条 / 胶囊 | 34px / 30px | 30px / 24px |
| 任务名 | 14px | 12px |
| @标签 / 日期胶囊 | 12px / 高 20 | 10px / 高 16 |
| tab 文字 | 12px | 11px |
| 状态行 / 提示行 | 12px（还有一条 PopoutComponent 自带 14px 的 details 行） | 10px（details 行已去掉，换成自己的状态行） |
| 撤销条 / 反馈文字 | 12px / 高 34 | 11px / 高 28 |
| 优先级色点 | 8px | 6px |
| 勾选圆圈 | 20px（命中 28px） | 18px（命中 28px，仍 ≥20px） |
| 子任务缩进 | 14px/级 | 10px/级（最多 3 级） |

字号跟着 Theme 缩放（`Theme.fontSizeMedium * 0.86` 之类），但有可读性下限：**任务名 ≥11px，其余 ≥9px**。

## 子任务

- 按**当前 tab 展开后的总条数**判断：会超过显示上限（默认 50）→ 子任务**默认折叠**，父任务行右侧显示 `▸ N 个子任务`；不超过 → **默认展开**。
- 缩进最多 3 层（更深的子任务不再增加缩进，但不会藏起来）。
- 两种默认状态都可以**手动点击**行内的 `▸/▾ N 个子任务` 切换；本次会话内记住手动选择（不落盘，刷新数据后仍以手动选择为准）。
- 点父任务左侧圆圈完成时，会**连带整棵子树**（子、孙任务）一起完成，撤销时一起恢复。

## 交互

- **bar 图标**：勾选清单图标 + 数字徽标。有逾期任务时数字用错误色。位置在右侧组最左（`barConfigs[].rightWidgets[0]`）。
- **点图标** → 打开面板；再点一次或点面板外关闭。
- **今天 tab**：今天到期 + 逾期，逾期排在前，按日期 → 优先级 → 顺序排序。胶囊文字：`逾期 N 天`（红）/`今天`（绿）/`明天`（橙）/`M月D日`。
- **项目 tab**：该项目的未完成任务（含今天到期的），同样按日期 → 优先级 → 顺序排序。
- **点任务左侧圆圈** → 完成（连带子树，见上）；面板底部出现「已完成「xxx」 撤销」条，4 秒内点撤销调 `/tasks/{id}/reopen` 恢复，超时则确认完成。
  完成/撤销后会立刻拉一次，并在 3 秒后再拉一次——Todoist 的读副本偶尔滞后，第二次拉取用来收敛数字。

- **错误态**：无 token 时显示引导页（key_off 图标 + 四种配置方式）；401/403、429、5xx、断网、超时分别给出中文文案 + 重试按钮。刷新失败不会清空已有数据。
- 面板只有列表，没有输入框（不做添加）。

## 命令行接口（也可绑快捷键）

插件注册了 IPC 目标 `todoistDms`：

```bash
dms ipc call todoistDms status      # ok badge=2 today=2 overdue=1 tasks=50 tab=today rows=2 shown=2 truncated=0 limit=50 collapsed=false maxRows=34 scrolls=false updated=15:19
dms ipc call todoistDms tabs        # tab 列表（* 是当前）：今天 (2) / Inbox (0) / 购物清单 (6) / 个人空间 (24) / 快送熊 (20)
dms ipc call todoistDms entries     # 当前 tab 的行：depth / 折叠标记 / 任务 id / 文案 | 日期
dms ipc call todoistDms tab today            # 切 tab（参数也可以是项目 id）
dms ipc call todoistDms tab 6hj7pqqcGGQP96WX
dms ipc call todoistDms refresh              # 立刻拉一次
dms ipc call todoistDms open                 # 打开面板（close 关闭）
dms ipc call todoistDms done <taskId>        # 完成（连带子树）
dms ipc call todoistDms undo                 # 撤销上一次完成
dms ipc call todoistDms subtasks <taskId>    # 调试/快捷键：切换某个父任务的子任务折叠
dms ipc call widget toggle todoistDms  # DMS 自带：等价于点击图标
```

## 在 bar 上验证（三步）

1. 看 bar **右侧组的最左**：应该是「勾选清单」图标 + 数字（它右边依次是运行中的 App、网速、通知、电池、控制中心）。数字 = 今天到期 + 逾期任务数；和 Todoist 网页/App 的 Today 数对齐（有逾期时数字是红色）。
2. 点图标开面板：顶部是一排 tab —— `今天` + 各项目（顺序 = 你在 Todoist App 里拖出来的项目顺序），每个 tab 带未完成数。行比之前紧凑（32px 行高、12px 任务名）；1440 屏一次能放下 34 行、1080 屏 25 行，超了才滚动。点「Inbox」这种空 tab：面板会缩到很小，只显示「这个项目没有未完成任务」。
3. 点任意一条任务的左侧圆圈完成它：它（连同子任务）从列表消失、徽标 -1、底部出现「已完成「xxx」 撤销」；4 秒内点「撤销」，它带着原日期胶囊回来（等 3–4 秒让数字收敛）。若某行右侧有 `▸ N 个子任务`，点它可以展开/折叠（超过 50 条的 tab 默认折叠）。

## 数据层（`scripts/todoist_api.py`）

只用 python3 标准库（urllib），无第三方依赖。所有子命令都往 stdout 打一行 JSON，永不抛栈：

```bash
python3 todoist_api.py snapshot                 # 任务/项目/分区全量快照（自动翻页）
python3 todoist_api.py comment <taskId> "备注"   # POST /comments
python3 todoist_api.py close <id> [<id>...]     # POST /tasks/{id}/close
python3 todoist_api.py reopen <id> [<id>...]    # POST /tasks/{id}/reopen
python3 todoist_api.py delete <id> [<id>...]    # DELETE /tasks/{id}
python3 todoist_api.py token-info               # 只报告 token 是否存在及来源
```

面板只用到 `snapshot` / `close` / `reopen`；`comment` / `delete` 是维护用命令（造/清测试数据就靠它们）。
脚本本身不含任何添加任务的代码路径。

可选参数：`--token-file <路径>`、`--timeout <秒>`（默认 30，读操作超时会自动重试一次）。

成功：`{"ok": true, ...}`；失败：`{"ok": false, "kind": "...", "http": 4xx, "message": "中文文案", "detail": "原始响应"}`，
`kind ∈ no_token | unauthorized | rate_limited | server | not_found | bad_request | network | timeout | unknown`。

## 踩过的坑（Todoist API v1）

- `limit` 上限实际是 50/页（请求 200 也只回 50），必须按 `next_cursor` 翻页；空 `next_cursor` 表示结束。
- **日期不能用中文**：服务端只认英文自然语言，`due_string: "今天"` → `400 Invalid date format`；要指定日期请用 ISO 的 `due_date`（`2026-10-16`）。
- 完成/重开后立刻读列表偶发读不到最新状态（读副本滞后），隔几秒再读就对了。
- `POST /tasks/{id}` 不能用来换项目（要 `POST /tasks/{id}/move`）。
- 撤销完成用 `POST /tasks/{id}/reopen`，不是重新建任务。
- 到 `api.todoist.com` 的链路偶发十几秒无响应，读操作超时重试一次。

## DMS 插件接口要点（本插件用到的部分）

- 插件目录 `~/.config/DankMaterialShell/plugins/<Name>/`，清单 `plugin.json`：
  `id`（`^[a-zA-Z][a-zA-Z0-9]*$`，会直接当 bar 里的 widgetId）、`name`、`description`、`version`、`author`、
  `type`（widget/daemon/launcher/desktop/composite）、`capabilities`、`component`（主 QML）、
  `settings`（可选设置界面）、`permissions`（只有 `settings_write` 被强制检查）。
- 主组件继承 `PluginComponent`（`qs.Modules.Plugins`）：`horizontalBarPill` / `verticalBarPill` 定义 bar 上的样子，
  `popoutContent` + `popoutWidth` 定义点击后的面板；点击默认 toggle 面板（可用 `pillClickAction` 覆盖，注意别在里面再调 `triggerPopout()`，会无限递归）。
- **基类文件里的 id 在插件文件里不可见**：`PluginComponent.qml` 里 `pluginPopout` 这类 id 拿不到（拿它算屏幕高度会得到 0）；要屏幕信息用注入的属性 `parentScreen`（有 `width/height/name`）。
- 面板内容用 `PopoutComponent`（给 header/details/关闭按钮，`closePopout()` 关闭）；**面板高度由内容的 `implicitHeight` 决定**（`PluginPopout` 会把 `contentHeight` 重新绑到内容的 implicitHeight），所以做自适应高度就是按内容算 implicitHeight，别再写死 `popoutHeight`。
- 注入的属性：`axis`/`section`/`parentScreen`/`widgetThickness`/`barThickness`/`barConfig`/`pluginData`/`pluginService`/`pluginId`（还有 `popoutService` 如果需要）。`popoutContent` 里通过 `parentPopout` 拿 popout 本身，用它的 `onOpened`/`onPopoutClosed` 跟踪开合。
- 设置：`PluginSettings { pluginId: "..." }` + `StringSetting`/`ToggleSetting`/`SliderSetting`/`SelectionSetting`/`ListSetting`，
  自动存到 `~/.config/DankMaterialShell/plugin_settings.json`，组件里通过注入的 `pluginData` 读。
  **手工改这个 json 不会热影响正在跑的 shell**（DMS 内存里有一份，插件重载也读内存），要重启 DMS 或走设置界面。
- 数据：插件实例由 bar 承载，同一插件在多屏 bar 上会有多个实例（本插件每个实例各拉一次，每 5 分钟 1 次）。
- 跑外部命令：`Process`（`Quickshell.Io`，配 `StdioCollector` 收 stdout）或 `Proc.runCommand(id, cmd, cb, debounceMs)`。
  QML 里没有 `XMLHttpRequest`，HTTP 就走本地脚本。
- 日志：`console.info/warn` 进 `journalctl --user -t dms`（也可看 `/run/user/1000/quickshell/by-id/*/log.qslog`）。
- IPC：在插件里放 `Quickshell.Io.IpcHandler { target: "..." }` 就能加 `dms ipc call <target> <fn>` 命令；
  注意 **IpcHandler 的函数里不要调用同文件定义的辅助函数**（本机实测会返回空），只用 `root.xxx` 属性/方法。
- 改完文件 `dms ipc call plugin-scan scan` 不一定重读已存在的 manifest，要 `dms ipc call plugin-scan reload <pluginId>`。
- `dms screenshot output -o <输出名>` 可以按输出截图；`WAYLAND_DISPLAY` 要用 `wayland-1`（不是 niri 的 socket 名）。

## 已知限制 / 未做

- 只读 + 完成 + 撤销；**没做**添加任务、改期、删除任务、评论、提醒、拖拽排序、离线队列。（按钮级的添加功能已按要求移除，数据层也不再带相关代码路径。）
- 分区（section）不渲染：数据里已经有 `section_id`，但当前账号所有项目都没有分区，界面只按项目分 tab。
- 项目 tab 里不显示"项目内还有哪些今天到期的任务"之外的额外标注；今天到期的任务同时出现在「今天」tab 和项目 tab（有意不去重）。
- 后台每个实例独立轮询；多屏 bar 会各拉一次（免费档限流 1000 次/15 分钟，远够用）。
- 面板高度自适应，上限约屏幕高度 65%，超出后列表内滚动。
- `dms ipc call widget toggle` 对插件组件能打开面板，但 `widget status` 对插件会误报 `WIDGET_NO_POPOUT`（DMS 只认内置 widget 的 `popoutTarget`）。
- 显示上限之外的取舍：被**折叠**藏起来的子任务**不会**计入「还有 N 条未显示」（那一行只统计因为超过显示上限被截掉的）；折叠了多少看行内的 `▸ N 个子任务` 和标题里的「子任务已折叠」。
