# Slash 命令参考

> 斜杠命令（Slash Commands）是在对话框中输入 `/` 开头的快捷指令，用于控制会话行为、切换模型设置等。

在快捷配置面板 → 常用命令标签中点击任意命令，会自动填入对话框。

---

## 会话命令

这些命令直接发送后立即执行。

| 命令 | 说明 |
|------|------|
| `/new` | 开启新会话，清除当前上下文，重新开始 |
| `/reset` | 重置当前会话，保留配置但清除对话记录 |
| `/compact` | 压缩会话上下文，减少 Token 占用（适合长对话）|
| `/stop` | 停止 Agent 当前正在执行的任务 |
| `/clear` | 清空聊天记录（仅清除界面显示）|
| `/focus` | 切换专注模式（减少干扰性输出）|

---

## 模型命令

这些命令需要追加参数，填入对话框后补充内容再发送。

| 命令 | 语法 | 说明 |
|------|------|------|
| `/model` | `/model <name>` | 查看当前使用的模型，或切换到指定模型 |
| `/think` | `/think <level>` | 设置思考深度（如 `low` / `medium` / `high`）|
| `/verbose` | `/verbose <on\|off\|full>` | 切换详细输出模式：`on` 显示步骤，`full` 显示完整日志 |
| `/fast` | `/fast <status\|on\|off>` | 切换快速模式：`on` 优先速度，`off` 优先质量 |

**示例：**

```
/model claude-3-5-sonnet-20241022
/think high
/verbose on
/fast off
```

---

## 工具命令

| 命令 | 说明 |
|------|------|
| `/help` | 显示所有可用命令列表及说明 |
| `/status` | 显示当前会话状态（Agent 状态、已安装 Skill 等）|

---

## Skill 命令

安装 Skill 后，可直接调用对应命令：

| 命令 | 对应 Skill | 说明 |
|------|-----------|------|
| `/skill-vetter` | Skill Vetter | 对指定 Skill 进行安全审计 |
| `/self-improving-agent` | Self-Improving Agent | 启动自我优化模式 |
| `/proactive-agent` | Proactive Agent | 启动主动式任务规划 |
| `/multi-search-engine` | Multi Search Engine | 聚合多引擎搜索 |
| `/exa-web-search-free` | Exa Web Search Free | 使用 Exa 进行语义搜索 |

通用 Skill 调用格式：

```
/skill <skill-dir-name>
```

例如调用名为 `my-skill` 的 Skill：

```
/skill my-skill
```

---

## 快捷使用

在实例详情页 **⚡ 快捷配置 → / 常用命令** 标签中，点击任意命令条目：

- **立即发送类**（如 `/new`、`/reset`）→ 自动发送并执行
- **需要参数类**（如 `/model`、`/think`）→ 命令填入对话框，光标定位在末尾，手动补充参数后发送

---

## 相关文档

- [Skills 使用](07-skills.md)
- [MCP 配置](08-mcp-servers.md)
- [实例配置参考](05-instance-config.md)

---

内容由AI生成，欢迎联系support@aijishu.com
