import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "todoistDms"

    StyledText {
        width: parent.width
        text: "Todoist"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Token 读取顺序：本页填写的文件路径 → ~/.config/todoist-dms/config.json（api_token 字段）→ 环境变量 TODOIST_DMS_API_KEY → ~/.config/todoist/token → ~/.agents/personal-skills/todoist/token。token 只由脚本读取并放进请求头，不会写进本设置文件。"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "refreshMinutes"
        label: "后台刷新间隔"
        description: "不打开面板时，每隔多久拉一次 Todoist"
        defaultValue: 5
        minimum: 1
        maximum: 60
        unit: "分钟"
        leftIcon: "schedule"
    }

    SliderSetting {
        settingKey: "displayLimit"
        label: "面板显示上限"
        description: "今天 + 各项目合计最多显示多少条任务；超出时列表末尾提示还有多少条。同时也决定子任务默认折叠：展开后超过这个数就默认折叠"
        defaultValue: 50
        minimum: 10
        maximum: 200
        unit: "条"
        leftIcon: "list"
    }

    ToggleSetting {
        settingKey: "showBadge"
        label: "显示任务数徽标"
        description: "在 bar 图标右侧显示今日任务数；关掉只剩图标"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showOverdueInBadge"
        label: "徽标包含逾期任务"
        description: "开：徽标 = 今天到期 + 逾期；关：只算今天到期"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showLabels"
        label: "显示任务标签"
        description: "在任务名下方显示最多 2 个 @标签"
        defaultValue: true
    }

    StringSetting {
        settingKey: "tokenFile"
        label: "Token 文件路径"
        description: "留空则走默认读取顺序；填了只读这个文件（可以是纯 token 文本，也可以是含 api_token 字段的 config.json）"
        placeholder: "~/.config/todoist-dms/config.json"
        defaultValue: ""
    }
}
