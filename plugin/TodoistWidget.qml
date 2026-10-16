import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string pluginKey: "todoistDms"
    readonly property string scriptPath: Qt.resolvedUrl("scripts/todoist_api.py").toString().replace("file://", "")

    // ---- 插件设置 ----
    readonly property int refreshMinutes: Math.max(1, Math.min(60, Number(pluginData.refreshMinutes) || 5))
    readonly property bool showBadge: pluginData.showBadge !== false
    readonly property bool showOverdueInBadge: pluginData.showOverdueInBadge !== false
    readonly property bool showLabels: pluginData.showLabels !== false
    readonly property string tokenFile: pluginData.tokenFile || ""
    // 每个 tab 的显示上限：同时也是「子任务是否默认折叠」的阈值
    readonly property int displayLimit: Math.max(1, Math.min(500, Number(pluginData.displayLimit) || 50))

    // ---- 数据状态 ----
    property var tasks: []
    property var projects: []
    property var sections: []
    property bool hasLoaded: false
    property bool loading: false
    property string errorKind: ""
    property string errorMessage: ""
    property string errorDetail: ""
    property string tokenSource: ""
    property double lastUpdated: 0

    // ---- 界面状态 ----
    // 当前 tab：用全局变量在多实例（多屏 bar）之间共享，切一次两块屏的面板都跟着切
    readonly property string activeTab: {
        const value = activeTabVar.value;
        return (value === undefined || value === null || value === "") ? "today" : String(value);
    }

    PluginGlobalVar {
        id: activeTabVar
        varName: "activeTab"
        defaultValue: "today"
    }
    property bool popoutOpen: false
    property string flashText: ""
    property bool flashIsError: false
    property var undoEntry: null
    property var pendingIds: ({})
    property var actionQueue: []
    // 子任务折叠状态的手动覆盖：taskId -> true(折叠) / false(展开)，只在本次会话内保留
    property var subtaskOverride: ({})

    readonly property string todayIso: Qt.formatDate(new Date(), "yyyy-MM-dd")
    readonly property color orange: "#F5A524"
    readonly property color green: "#35C46A"
    readonly property real rowHeight: 32
    readonly property real noteRowHeight: 24
    readonly property real tabStripHeight: 30
    readonly property real indentStep: 10
    readonly property int maxIndentSteps: 3
    // 紧凑排版字号：跟随 Theme 缩放，但有可读性下限（任务名 ≥11，其它 ≥9）
    readonly property real fontTask: Math.max(11, Math.round(Theme.fontSizeMedium * 0.86))
    readonly property real fontMeta: Math.max(9, Math.round(Theme.fontSizeSmall * 0.83))
    readonly property real fontTab: Math.max(10, Math.round(Theme.fontSizeSmall * 0.92))

    Timer {
        id: undoHideTimer
        interval: 4000
        onTriggered: root.undoEntry = null
    }

    Timer {
        id: flashTimer
        interval: 4000
        onTriggered: root.flashText = ""
    }

    Timer {
        id: pollTimer
        interval: root.refreshMinutes * 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // 完成/撤销后立刻拉一次可能撞上 Todoist 读副本延迟，隔几秒再拉一次收敛
    Timer {
        id: settleTimer
        interval: 3000
        onTriggered: root.refresh()
    }

    // ---- 数据层 ----

    function scriptCommand(args) {
        let cmd = ["python3", scriptPath];
        if (tokenFile) {
            cmd.push("--token-file");
            cmd.push(tokenFile);
        }
        cmd.push("--timeout");
        cmd.push("30");
        return cmd.concat(args);
    }

    function parseResponse(raw) {
        const text = String(raw || "").trim();
        if (text === "")
            return { "ok": false, "data": { "ok": false, "kind": "unknown", "message": "数据层没有返回内容", "detail": "" } };
        const lineEnd = text.indexOf("\n");
        const line = lineEnd === -1 ? text : text.slice(0, lineEnd);
        try {
            const data = JSON.parse(line);
            return { "ok": data.ok === true, "data": data };
        } catch (e) {
            return { "ok": false, "data": { "ok": false, "kind": "unknown", "message": "无法解析数据层输出", "detail": text.slice(0, 400) } };
        }
    }

    function refresh() {
        if (runner.running)
            return;
        loading = true;
        runner.command = scriptCommand(["snapshot"]);
        runner.running = true;
    }

    // 写操作串行执行：写接口单条就要几百毫秒到数秒，避免并发打乱 完成/撤销 的顺序
    function runAction(args, callback) {
        actionQueue = actionQueue.concat([{ "args": args, "callback": callback }]);
        pumpActions();
    }

    function pumpActions() {
        if (actionRunner.running || actionQueue.length === 0)
            return;
        const next = actionQueue[0];
        actionQueue = actionQueue.slice(1);
        actionRunner.pending = next.callback;
        actionRunner.command = scriptCommand(next.args);
        actionRunner.running = true;
    }

    Process {
        id: runner

        stdout: StdioCollector {
            id: runnerOut
        }

        onExited: (exitCode, exitStatus) => {
            const parsed = parseResponse(runnerOut.data);
            root.loading = false;
            if (!parsed.ok) {
                root.errorKind = parsed.data.kind || "unknown";
                root.errorMessage = parsed.data.message || "未知错误";
                root.errorDetail = parsed.data.detail || "";
                root.reportState();
                return;
            }
            root.errorKind = "";
            root.errorMessage = "";
            root.errorDetail = "";
            root.tokenSource = parsed.data.token_source || "";
            root.tasks = parsed.data.tasks || [];
            root.projects = parsed.data.projects || [];
            root.sections = parsed.data.sections || [];
            root.hasLoaded = true;
            root.lastUpdated = Date.now();
            root.prunePending();
            root.reportState();
        }
    }

    Process {
        id: actionRunner
        property var pending: null

        stdout: StdioCollector {
            id: actionOut
        }

        onExited: (exitCode, exitStatus) => {
            if (!pending)
                return;
            const callback = pending;
            pending = null;
            const parsed = parseResponse(actionOut.data);
            callback(parsed.data, parsed.ok);
            Qt.callLater(root.pumpActions);
        }
    }

    // ---- 日期与优先级 ----

    function dueIso(task) {
        if (!task || !task.due)
            return "";
        if (task.due.date)
            return String(task.due.date).slice(0, 10);
        if (task.due.datetime)
            return String(task.due.datetime).slice(0, 10);
        return "";
    }

    function dueTime(task) {
        if (!task || !task.due || !task.due.datetime)
            return "";
        const parts = String(task.due.datetime).split("T");
        return parts.length > 1 ? parts[1].slice(0, 5) : "";
    }

    function parseLocalDate(iso) {
        if (!iso)
            return null;
        const parts = String(iso).slice(0, 10).split("-");
        if (parts.length !== 3)
            return null;
        return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    }

    function daysFromToday(iso) {
        const target = parseLocalDate(iso);
        if (!target)
            return null;
        const now = new Date();
        const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        return Math.round((target - midnight) / 86400000);
    }

    function isOverdue(task) {
        const iso = dueIso(task);
        return iso !== "" && iso < todayIso;
    }

    function isDueTodayOrOverdue(task) {
        const iso = dueIso(task);
        return iso !== "" && iso <= todayIso;
    }

    function dueLabel(task) {
        const iso = dueIso(task);
        if (iso === "")
            return "";
        const days = daysFromToday(iso);
        if (days === null)
            return iso;
        if (days < 0)
            return "逾期 " + (-days) + " 天";
        if (days === 0) {
            const at = dueTime(task);
            return at !== "" ? "今天 " + at : "今天";
        }
        if (days === 1)
            return "明天";
        if (days === 2)
            return "后天";
        const date = parseLocalDate(iso);
        return (date.getMonth() + 1) + "月" + date.getDate() + "日";
    }

    function dueColor(task) {
        const days = daysFromToday(dueIso(task));
        if (days === null)
            return Theme.surfaceVariantText;
        if (days < 0)
            return Theme.error;
        if (days === 0)
            return green;
        if (days === 1)
            return orange;
        return Theme.surfaceVariantText;
    }

    function priorityColor(priority) {
        switch (Number(priority)) {
        case 4:
            return Theme.error;
        case 3:
            return orange;
        case 2:
            return Theme.primary;
        default:
            return Theme.surfaceVariantText;
        }
    }

    function isHidden(task) {
        return pendingIds[task.id] === true;
    }

    function taskById(taskId) {
        if (!taskId)
            return null;
        for (let i = 0; i < tasks.length; i++) {
            if (tasks[i].id === taskId)
                return tasks[i];
        }
        return null;
    }

    function sortTasks(list) {
        return list.slice().sort((a, b) => {
            const da = dueIso(a) || "9999-12-31";
            const db = dueIso(b) || "9999-12-31";
            if (da !== db)
                return da < db ? -1 : 1;
            if (Number(b.priority) !== Number(a.priority))
                return Number(b.priority) - Number(a.priority);
            return Number(a.child_order || 0) - Number(b.child_order || 0);
        });
    }

    // ---- tab 模型：今天 + 每个项目一个平级 tab ----

    readonly property var visibleTasks: tasks.filter(t => !isHidden(t))

    // 今天 tab：今天到期 + 逾期（逾期靠日期排序自然在前）
    readonly property var todayTasks: sortTasks(visibleTasks.filter(isDueTodayOrOverdue))
    readonly property var overdueList: todayTasks.filter(isOverdue)
    readonly property var todayOnlyList: todayTasks.filter(t => !isOverdue(t))
    readonly property int badgeCount: showOverdueInBadge ? todayTasks.length : todayOnlyList.length

    // tab 顺序：今天固定第一，其余沿用 /projects 的返回顺序（即 child_order，Inbox 也在它自己的位置）
    readonly property var tabs: {
        const list = [{ "id": "today", "label": "今天", "count": todayTasks.length }];
        for (let i = 0; i < projects.length; i++) {
            const project = projects[i];
            list.push({
                "id": project.id,
                "label": project.name,
                "count": visibleTasks.filter(t => t.project_id === project.id).length
            });
        }
        return list;
    }

    // 选中的 tab 失效（项目被删）时回落到今天
    readonly property string currentTab: {
        if (activeTab === "today")
            return "today";
        for (let i = 0; i < projects.length; i++) {
            if (projects[i].id === activeTab)
                return activeTab;
        }
        return "today";
    }

    readonly property string currentTabLabel: {
        for (let i = 0; i < tabs.length; i++) {
            if (tabs[i].id === currentTab)
                return tabs[i].label;
        }
        return "今天";
    }

    // 每个 tab 都是独立视图：项目 tab 里也会出现今天/逾期的任务，不跨 tab 去重
    function tabTasks(tabId) {
        if (tabId === "today")
            return todayTasks;
        return sortTasks(visibleTasks.filter(t => t.project_id === tabId));
    }

    readonly property var currentTasks: tabTasks(currentTab)
    readonly property int tabExpandedCount: currentTasks.length
    readonly property bool collapseByDefault: tabExpandedCount > displayLimit

    function descendantCount(taskId) {
        let count = 0;
        const queue = [taskId];
        while (queue.length > 0) {
            const current = queue.pop();
            for (let i = 0; i < visibleTasks.length; i++) {
                if (visibleTasks[i].parent_id === current) {
                    count++;
                    queue.push(visibleTasks[i].id);
                }
            }
        }
        return count;
    }

    function isCollapsed(taskId, childTotal) {
        if (childTotal <= 0)
            return false;
        if (subtaskOverride[taskId] !== undefined)
            return subtaskOverride[taskId];
        return collapseByDefault;
    }

    function toggleSubtasks(taskId) {
        const childTotal = descendantCount(taskId);
        if (childTotal <= 0)
            return false;
        const next = Object.assign({}, subtaskOverride);
        next[taskId] = !isCollapsed(taskId, childTotal);
        subtaskOverride = next;
        return next[taskId];
    }

    function indentFor(depth) {
        return Math.min(Number(depth) || 0, maxIndentSteps) * indentStep;
    }

    // 按父子关系摊平当前 tab 的任务；父任务不在本 tab 时子任务按顶层处理，不会丢
    function appendTaskRows(out, list) {
        const present = {};
        for (let i = 0; i < list.length; i++)
            present[list[i].id] = true;

        const byParent = {};
        for (let j = 0; j < list.length; j++) {
            const task = list[j];
            const key = (task.parent_id && present[task.parent_id]) ? task.parent_id : "";
            if (!byParent[key])
                byParent[key] = [];
            byParent[key].push(task);
        }

        const walk = (parentKey, depth) => {
            const kids = byParent[parentKey] || [];
            for (let k = 0; k < kids.length; k++) {
                const task = kids[k];
                const childTotal = descendantCount(task.id);
                const collapsed = isCollapsed(task.id, childTotal);
                out.push({
                    "kind": "task",
                    "id": task.id,
                    "task": task,
                    "depth": depth,
                    "childTotal": childTotal,
                    "collapsed": collapsed
                });
                if (childTotal > 0 && !collapsed)
                    walk(task.id, depth + 1);
            }
        };
        walk("", 0);
    }

    function truncateRows(rows) {
        const kept = [];
        let shown = 0;
        let hidden = 0;
        for (let i = 0; i < rows.length; i++) {
            if (shown < displayLimit) {
                shown++;
                kept.push(rows[i]);
            } else {
                hidden++;
            }
        }
        if (hidden > 0)
            kept.push({ "kind": "note", "id": "__hidden", "text": "还有 " + hidden + " 条未显示", "count": hidden });
        else if (kept.length === 0 && hasLoaded && errorKind === "")
            kept.push({ "kind": "note", "id": "__empty", "text": currentTab === "today" ? "今天没有到期任务" : "这个项目没有未完成任务", "count": 0 });
        return kept;
    }

    readonly property var listRows: {
        if (errorKind !== "" || !hasLoaded)
            return [];
        const rows = [];
        appendTaskRows(rows, currentTasks);
        return truncateRows(rows);
    }

    readonly property int shownTaskCount: {
        let n = 0;
        for (let i = 0; i < listRows.length; i++) {
            if (listRows[i].kind === "task")
                n++;
        }
        return n;
    }

    // 因为超过显示上限被截掉的任务数（不含被折叠藏起来的子任务）
    readonly property int truncatedCount: {
        for (let i = 0; i < listRows.length; i++) {
            if (listRows[i].kind === "note" && listRows[i].id === "__hidden")
                return Number(listRows[i].count) || 0;
        }
        return 0;
    }

    readonly property real rowSpacing: Theme.spacingXXS

    // 列表内容高度：少则收缩，多则交给上限去滚动
    readonly property real rowsContentHeight: {
        let h = 0;
        for (let i = 0; i < listRows.length; i++) {
            h += listRows[i].kind === "task" ? rowHeight : noteRowHeight;
            if (i > 0)
                h += rowSpacing;
        }
        return h;
    }

    // 面板上限约屏幕可用高度的 90%（只留 bar 厚度与上下留白）
    readonly property real screenHeight: (parentScreen && parentScreen.height > 0) ? parentScreen.height : 1080
    readonly property real maxBodyHeight: Math.max(150, screenHeight * 0.9 - 60)

    // 纯几何估算（供 status 观测"最多能放几行 / 现在会不会滚动"；面板实际布局由 body 里按真实高度算，两者差 1 行以内）
    readonly property real statusRowHeight: Math.round(fontMeta * 1.4) + Theme.spacingXXS
    readonly property real estMaxListHeight: Math.max(80, maxBodyHeight - statusRowHeight - Theme.spacingXS - tabStripHeight - Theme.spacingS)
    readonly property int maxVisibleRows: Math.floor((estMaxListHeight + rowSpacing) / (rowHeight + rowSpacing))
    readonly property bool listScrolls: rowsContentHeight > estMaxListHeight

    // ---- 写操作 ----

    function prunePending() {
        const next = {};
        let changed = false;
        for (const key in pendingIds) {
            const stillThere = tasks.some(t => t.id === key);
            if (stillThere)
                next[key] = true;
            else
                changed = true;
        }
        if (changed)
            pendingIds = next;
    }

    function completeTask(task) {
        if (!task || !task.id)
            return;
        // 连带整棵子树（子任务、孙任务都算）
        const ids = [task.id];
        const seen = {};
        seen[task.id] = true;
        const queue = [task.id];
        while (queue.length > 0) {
            const current = queue.pop();
            for (let i = 0; i < tasks.length; i++) {
                const candidate = tasks[i];
                if (candidate.parent_id === current && !seen[candidate.id]) {
                    seen[candidate.id] = true;
                    ids.push(candidate.id);
                    queue.push(candidate.id);
                }
            }
        }

        const next = Object.assign({}, pendingIds);
        for (let j = 0; j < ids.length; j++)
            next[ids[j]] = true;
        pendingIds = next;

        undoEntry = { "ids": ids, "label": task.content, "childCount": ids.length - 1 };
        undoHideTimer.restart();

        runAction(["close"].concat(ids), (data, ok) => {
            if (!ok) {
                showFlash(data.message || "完成失败", true);
                restorePending(ids);
                undoEntry = null;
                return;
            }
            refresh();
            settleTimer.restart();
        });
    }

    function restorePending(ids) {
        const next = Object.assign({}, pendingIds);
        for (let i = 0; i < ids.length; i++)
            delete next[ids[i]];
        pendingIds = next;
    }

    function undoLast() {
        if (!undoEntry)
            return;
        const entry = undoEntry;
        undoHideTimer.stop();
        undoEntry = null;
        runAction(["reopen"].concat(entry.ids), (data, ok) => {
            if (!ok) {
                showFlash(data.message || "撤销失败", true);
                return;
            }
            restorePending(entry.ids);
            showFlash("已撤销「" + entry.label + "」", false);
            refresh();
            settleTimer.restart();
        });
    }

    function showFlash(text, isError) {
        flashText = text;
        flashIsError = isError === true;
        flashTimer.restart();
    }

    function statusLine() {
        if (errorKind !== "")
            return "同步失败";
        if (!hasLoaded)
            return "正在加载…";
        let line = currentTabLabel + " " + tabExpandedCount + " 项 · 更新于 " + Qt.formatTime(new Date(lastUpdated), "HH:mm");
        if (collapseByDefault)
            line += " · 子任务已折叠";
        if (truncatedCount > 0)
            line += " · 还有 " + truncatedCount + " 条未显示";
        return line;
    }

    // 状态变化才打一行日志，平时不刷屏（DMS 常驻，日志要省着用）
    property string _lastReport: ""

    function reportState() {
        const line = errorKind !== ""
            ? "error=" + errorKind + " " + errorMessage
            : "badge=" + badgeCount + " today=" + todayTasks.length + " overdue=" + overdueList.length + " tasks=" + tasks.length + " tab=" + currentTab + " rows=" + tabExpandedCount + " limit=" + displayLimit + " collapsed=" + collapseByDefault + " token=" + tokenSource;
        if (line === _lastReport)
            return;
        _lastReport = line;
        if (errorKind !== "")
            console.warn("[todoistDms] " + line);
        else
            console.info("[todoistDms] " + line);
    }

    // 供 `dms ipc call todoistDms status` 使用：直接读运行中实例的真实状态
    IpcHandler {
        target: "todoistDms"

        function status(): string {
            if (root.errorKind !== "")
                return "error\t" + root.errorKind + "\t" + root.errorMessage;
            return "ok\tbadge=" + root.badgeCount + "\ttoday=" + root.todayTasks.length + "\toverdue=" + root.overdueList.length + "\ttasks=" + root.tasks.length + "\ttab=" + root.currentTab + "\trows=" + root.tabExpandedCount + "\tshown=" + root.shownTaskCount + "\ttruncated=" + root.truncatedCount + "\tlimit=" + root.displayLimit + "\tcollapsed=" + root.collapseByDefault + "\tmaxRows=" + root.maxVisibleRows + "\tscrolls=" + root.listScrolls + "\tupdated=" + (root.lastUpdated > 0 ? Qt.formatTime(new Date(root.lastUpdated), "HH:mm:ss") : "never");
        }

        function tabs(): string {
            const lines = [];
            for (let i = 0; i < root.tabs.length; i++) {
                const tab = root.tabs[i];
                lines.push((tab.id === root.currentTab ? "* " : "  ") + String(tab.label).replace(/[\t\n\r]/g, " ") + " (" + tab.count + ")\t" + tab.id);
            }
            return lines.join("\n") || "(没有 tab)";
        }

        function entries(): string {
            const lines = ["tab: " + root.currentTabLabel + " (" + root.currentTab + ")"];
            for (let i = 0; i < root.listRows.length; i++) {
                const row = root.listRows[i];
                if (row.kind === "note") {
                    lines.push("note\t0\t-\t" + String(row.text).replace(/[\t\n\r]/g, " "));
                    continue;
                }
                const task = row.task;
                const mark = row.childTotal > 0 ? (row.collapsed ? "▸" : "▾") + row.childTotal : "-";
                const due = root.dueLabel(task);
                lines.push("task\t" + row.depth + "\t" + mark + "\t" + task.id + "\t" + String(task.content).replace(/[\t\n\r]/g, " ") + (due !== "" ? " | " + due : ""));
            }
            return lines.join("\n");
        }

        function tab(id: string): string {
            if (!id)
                return "ERROR: tab requires an id (today 或 项目 id)";
            for (let i = 0; i < root.tabs.length; i++) {
                if (root.tabs[i].id === id) {
                    activeTabVar.set(id);
                    return "TAB=" + root.currentTabLabel + " (" + root.currentTab + ")";
                }
            }
            return "ERROR: unknown tab " + id;
        }

        function refresh(): string {
            root.refresh();
            return "REFRESH_TRIGGERED";
        }

        function open(): string {
            root.triggerPopout();
            return "OPEN_REQUESTED hasPopout=" + root.hasPopout + " open=" + root.popoutOpen;
        }

        function close(): string {
            root.closePopout();
            return "CLOSE_REQUESTED";
        }

        function done(taskId: string): string {
            const task = root.taskById(taskId);
            if (!task)
                return "ERROR: unknown taskId " + taskId;
            root.completeTask(task);
            return "DONE_REQUESTED: " + taskId + " " + task.content;
        }

        function undo(): string {
            if (root.undoEntry === null)
                return "ERROR: nothing to undo";
            const ids = root.undoEntry.ids.join(",");
            root.undoLast();
            return "UNDO_REQUESTED: " + ids;
        }

        // 调试/快捷键：切换某个父任务的子任务折叠（等同点行内的「N 个子任务」）
        function subtasks(taskId: string): string {
            const total = root.descendantCount(taskId);
            if (total <= 0)
                return "ERROR: " + taskId + " 没有子任务";
            return "SUBTASKS " + taskId + " collapsed=" + root.toggleSubtasks(taskId) + " total=" + total;
        }

        function popout(): string {
            return "hasPopout=" + root.hasPopout + " open=" + root.popoutOpen + " width=" + root.popoutWidth + " rows=" + root.listRows.length + " tab=" + root.currentTab + " maxBody=" + Math.round(root.maxBodyHeight) + " screenH=" + root.screenHeight;
        }
    }

    // ---- bar 小组件 ----

    horizontalBarPill: Component {
        Item {
            implicitWidth: pillRow.implicitWidth + Theme.spacingM * 2
            implicitHeight: root.widgetThickness

            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: "checklist"
                    size: Theme.iconSize - 4
                    color: root.errorKind !== "" ? Theme.error : (root.badgeCount > 0 ? Theme.primary : Theme.surfaceVariantText)
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    visible: root.showBadge && root.badgeCount > 0
                    text: String(root.badgeCount)
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: root.overdueList.length > 0 ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DankIcon {
                name: "checklist"
                size: Theme.iconSize - 4
                color: root.errorKind !== "" ? Theme.error : (root.badgeCount > 0 ? Theme.primary : Theme.surfaceVariantText)
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.showBadge && root.badgeCount > 0
                text: String(root.badgeCount)
                font.pixelSize: Theme.fontSizeSmall
                color: root.overdueList.length > 0 ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---- 面板 ----

    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn

            headerText: I18n.trFor(root.pluginKey, "Todoist")
            detailsText: ""
            showCloseButton: true

            Connections {
                target: popoutColumn.parentPopout

                function onOpened() {
                    root.popoutOpen = true;
                    root.refresh();
                }

                function onPopoutClosed() {
                    root.popoutOpen = false;
                }
            }

            Item {
                id: body

                width: parent.width
                implicitHeight: statusText.height + Theme.spacingXS + tabStrip.height + Theme.spacingS + listHeight + (footer.height > 0 ? footer.height + Theme.spacingS : 0)

                // 列表可用高度：上限约屏幕 90% 再扣掉顶部状态行、tab 条与底部
                readonly property real maxListHeight: Math.max(80, root.maxBodyHeight - statusText.height - Theme.spacingXS - root.tabStripHeight - Theme.spacingS - (footer.height > 0 ? footer.height + Theme.spacingS : 0))
                readonly property real listHeight: Math.max(root.noteRowHeight, Math.min(root.rowsContentHeight, maxListHeight))

                Connections {
                    target: root

                    function onCurrentTabChanged() {
                        taskList.positionViewAtBeginning();
                    }
                }

                // 状态行（替掉 PopoutComponent 自带的 details 行，字号更小更省高度）
                StyledText {
                    id: statusText
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    topPadding: Theme.spacingXXS
                    text: root.statusLine()
                    font.pixelSize: root.fontMeta
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                // 错误 / 引导页
                Column {
                    id: errorPage
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingL
                    spacing: Theme.spacingM
                    visible: root.errorKind !== ""
                    z: 2

                    DankIcon {
                        name: root.errorKind === "no_token" ? "key_off" : "cloud_off"
                        size: 30
                        color: Theme.error
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    StyledText {
                        width: parent.width
                        text: root.errorMessage
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        width: parent.width
                        visible: root.errorDetail !== ""
                        text: root.errorDetail
                        font.pixelSize: root.fontTab
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    DankButton {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: I18n.trFor(root.pluginKey, "重试")
                        iconName: "refresh"
                        onClicked: root.refresh()
                    }
                }

                // 一排平级 tab：今天 + 每个项目（横向可滚动）
                Flickable {
                    id: tabStrip
                    anchors.top: statusText.bottom
                    anchors.topMargin: Theme.spacingXS
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: root.tabStripHeight
                    visible: root.errorKind === ""
                    contentWidth: tabRow.width
                    contentHeight: height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Row {
                        id: tabRow
                        height: parent.height
                        spacing: Theme.spacingXS

                        Repeater {
                            model: root.tabs

                            StyledRect {
                                id: tabChip

                                readonly property bool selected: modelData.id === root.currentTab

                                width: tabChipLabel.implicitWidth + Theme.spacingM
                                height: 24
                                anchors.verticalCenter: parent.verticalCenter
                                radius: 12
                                color: tabChip.selected ? Theme.primaryPressed : Theme.surfaceContainerHigh

                                StyledText {
                                    id: tabChipLabel
                                    anchors.centerIn: parent
                                    text: modelData.label + " " + modelData.count
                                    font.pixelSize: root.fontTab
                                    font.weight: tabChip.selected ? Font.Medium : Font.Normal
                                    color: tabChip.selected ? Theme.primary : Theme.surfaceVariantText
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: activeTabVar.set(modelData.id)
                                }
                            }
                        }
                    }
                }

                // 当前 tab 的任务列表
                DankListView {
                    id: taskList
                    anchors.top: tabStrip.bottom
                    anchors.topMargin: Theme.spacingS - 2
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: body.listHeight
                    visible: root.errorKind === ""
                    clip: true
                    spacing: root.rowSpacing
                    model: root.listRows

                    delegate: Item {
                        id: rowRoot

                        readonly property var row: modelData
                        readonly property bool isTask: row !== null && row !== undefined && row.kind === "task"
                        readonly property var task: isTask ? row.task : null
                        readonly property int depth: isTask ? row.depth : 0
                        readonly property int childTotal: isTask ? row.childTotal : 0
                        readonly property bool collapsed: isTask ? row.collapsed : false
                        readonly property string dueText: task !== null ? root.dueLabel(task) : ""

                        width: taskList.width
                        height: isTask ? root.rowHeight : root.noteRowHeight

                        // 提示行（还有 N 条未显示 / 空）
                        StyledText {
                            visible: !rowRoot.isTask
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowRoot.row && rowRoot.row.text ? rowRoot.row.text : ""
                            font.pixelSize: root.fontMeta
                            color: Theme.surfaceVariantText
                        }

                        StyledRect {
                            id: taskRow
                            visible: rowRoot.isTask
                            anchors.fill: parent
                            radius: Theme.cornerRadius
                            color: rowArea.containsMouse ? Theme.surfaceContainerHighest : (rowRoot.depth > 0 ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.55) : Theme.surfaceContainerHigh)

                            MouseArea {
                                id: rowArea
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                            }

                            Rectangle {
                                id: priorityDot
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS + root.indentFor(rowRoot.depth)
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: rowRoot.task ? root.priorityColor(rowRoot.task.priority) : "transparent"
                            }

                            DankIcon {
                                id: checkIcon
                                anchors.left: priorityDot.right
                                anchors.leftMargin: Theme.spacingS - 2
                                anchors.verticalCenter: parent.verticalCenter
                                name: "radio_button_unchecked"
                                size: Theme.iconSize - 6
                                color: checkArea.containsMouse ? Theme.primary : Theme.surfaceVariantText

                                MouseArea {
                                    id: checkArea
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (rowRoot.task)
                                            root.completeTask(rowRoot.task);
                                    }
                                }
                            }

                            StyledRect {
                                id: dueCapsule
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowRoot.dueText !== ""
                                width: rowRoot.dueText !== "" ? capsuleLabel.implicitWidth + Theme.spacingM : 0
                                height: 16
                                radius: 8
                                color: rowRoot.task ? Theme.withAlpha(root.dueColor(rowRoot.task), 0.16) : "transparent"

                                StyledText {
                                    id: capsuleLabel
                                    anchors.centerIn: parent
                                    text: rowRoot.dueText
                                    font.pixelSize: root.fontMeta
                                    color: rowRoot.task ? root.dueColor(rowRoot.task) : Theme.surfaceVariantText
                                }
                            }

                            // 父任务右侧：子任务折叠开关
                            StyledRect {
                                id: subChip
                                anchors.right: dueCapsule.visible ? dueCapsule.left : parent.right
                                anchors.rightMargin: dueCapsule.visible ? Theme.spacingXS : Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowRoot.childTotal > 0
                                width: subChipLabel.implicitWidth + Theme.spacingM
                                height: 16
                                radius: 8
                                color: subArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                                StyledText {
                                    id: subChipLabel
                                    anchors.centerIn: parent
                                    text: (rowRoot.collapsed ? "▸ " : "▾ ") + rowRoot.childTotal + " 个子任务"
                                    font.pixelSize: root.fontMeta
                                    color: subArea.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                }

                                MouseArea {
                                    id: subArea
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (rowRoot.task)
                                            root.toggleSubtasks(rowRoot.task.id);
                                    }
                                }
                            }

                            Column {
                                id: titleColumn
                                anchors.left: checkIcon.right
                                anchors.leftMargin: Theme.spacingS - 2
                                anchors.right: subChip.visible ? subChip.left : (dueCapsule.visible ? dueCapsule.left : taskRow.right)
                                anchors.rightMargin: Theme.spacingXS + 2
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0

                                StyledText {
                                    width: parent.width
                                    text: rowRoot.task ? rowRoot.task.content : ""
                                    font.pixelSize: root.fontTask
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingXS
                                    visible: root.showLabels && rowRoot.task !== null && rowRoot.task.labels && rowRoot.task.labels.length > 0

                                    Repeater {
                                        model: root.showLabels && rowRoot.task && rowRoot.task.labels ? rowRoot.task.labels.slice(0, 2) : []

                                        StyledText {
                                            text: "@" + modelData
                                            font.pixelSize: root.fontMeta
                                            color: Theme.primary
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Column {
                    id: footer
                    anchors.top: taskList.bottom
                    anchors.topMargin: Theme.spacingXS
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Theme.spacingXS

                    StyledRect {
                        width: parent.width
                        height: 28
                        visible: root.undoEntry !== null
                        color: Theme.surfaceContainerHighest
                        radius: Theme.cornerRadius

                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: undoButton.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.undoEntry === null ? "" : ("已完成「" + root.undoEntry.label + "」" + (root.undoEntry.childCount > 0 ? " 及 " + root.undoEntry.childCount + " 个子任务" : ""))
                            font.pixelSize: root.fontTab
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        DankButton {
                            id: undoButton
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingXXS
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.trFor(root.pluginKey, "撤销")
                            iconName: "undo"
                            buttonHeight: 22
                            horizontalPadding: Theme.spacingS + 2
                            onClicked: root.undoLast()
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: root.flashText !== ""
                        text: root.flashText
                        font.pixelSize: root.fontTab
                        color: root.flashIsError ? Theme.error : root.green
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    popoutWidth: 420
}
