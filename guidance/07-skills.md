# Skills 使用

> Skills 是 OpenClaw 的任务扩展能力包，安装后通过斜杠命令调用，赋予 Agent 特定领域的专项能力。

---

## 内置 Skills 列表

| Skill | 说明 | 调用命令 |
|-------|------|---------|
| **Skill Vetter** | 对 Skill 代码进行安全审计，安装新 Skill 前建议先审查 | `/skill-vetter` |
| **Self-Improving Agent** | 自我优化的 Agent，持续改进任务执行能力 | `/self-improving-agent` |
| **Proactive Agent** | 主动式 Agent，自动感知上下文并提前规划和完成任务 | `/proactive-agent` |
| **Multi Search Engine** | 聚合多个搜索引擎，提供更全面的网络搜索结果 | `/multi-search-engine` |
| **Exa Web Search Free** | 免费版 Exa 语义搜索，适合精准信息检索 | `/exa-web-search-free` |

---

## 查看已安装的 Skills

1. 打开实例详情页 → **⚡ 快捷配置**
2. 切换到 **⚡ 常用 Skill** 标签

每个 Skill 右侧显示安装状态徽标：

| 徽标 | 含义 |
|------|------|
| 已安装（绿色）| 已在当前实例安装 |
| 安装（蓝色）| 未安装，点击执行安装 |
| 安装中…（黄色）| 正在安装，请等待 |

面板底部的「其他已安装」区域显示通过其他方式安装、不在预设列表中的 Skill。

---

## 安装 Skill

### 方式一：点击预设安装（推荐）

1. 在快捷配置 → Skills 标签中找到目标 Skill
2. 点击该 Skill 条目（显示「安装」徽标时）
3. 安装命令自动注入到对话框并发送
4. 等待 Agent 完成安装，徽标变为「已安装」

安装命令格式（发送给 Agent）：
```
根据以下链接安装 skill：https://clawhub.ai/author/skill-name
```

### 方式二：输入自定义 URL

安装来自 ClawHub 或其他来源的第三方 Skill：

1. 在 Skills 标签底部找到「自定义安装」输入框
2. 粘贴 Skill URL（如 `https://clawhub.ai/author/skill-name`）
3. 点击**安装**

---

## 使用已安装的 Skill

安装完成后，在实例对话框中直接输入对应的斜杠命令：

```
/skill-vetter
```

或先切换到 Chat 标签，点击快捷配置中已安装的 Skill 条目——命令会自动填入对话框并执行。

---

## 删除 Skill

1. 在快捷配置 → Skills 标签中找到已安装的 Skill
2. 点击该条目右侧的**删除**按钮
3. 在确认弹窗中点击**确定**

删除操作会移除 `workspace/skills/<name>/` 目录下的所有文件。

> ⚠️ 删除后无法撤销，如需使用需重新安装。

---

## 常见问题

### 安装失败

1. 确认实例处于「运行中」状态
2. 确认网络可访问 npm 或 ClawHub
3. 查看 **Logs** 标签的 stderr 输出

### Skill 安装后显示为「安装」（未识别为已安装）

部分 Skill 的安装目录名称与预设不一致。打开快捷配置查看底部「其他已安装」区域，确认实际目录名。

### 找不到想要的 Skill

访问 [ClawHub](https://clawhub.ai) 搜索社区 Skill，复制链接后通过自定义 URL 安装。

---

## 相关文档

- [Slash 命令参考](09-slash-commands.md)
- [实例配置参考](05-instance-config.md)
- [MCP 配置](08-mcp-servers.md)

---

内容由AI生成，欢迎联系support@aijishu.com
