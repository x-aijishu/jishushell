# JishuShell 快速上手

> 5 分钟内完成安装并开始与 AI Agent 对话。

## 什么是 JishuShell？

JishuShell 是一个运行在本地或边缘设备（树莓派等）上的 **AI Agent 管理面板**，为更好的运行与管理Agent能力而构建。它让你能够：

- 创建和管理多个 AI Agent 实例
- 通过飞书、微信等渠道直接与 Agent 对话
- 安装 Skills 扩展 Agent 能力
- 接入 MCP（Model Context Protocol）工具
- 实时监控系统资源

---

## 第一步：安装

在终端中执行以下命令（支持树莓派 / Ubuntu / Debian / macOS）：

```bash
curl -fsSL https://aijishu.com/install.sh | bash
```

安装脚本会自动完成：

1. 安装 Node.js（通过 nvm）
2. 安装 Docker
3. 安装 Nomad 调度引擎
4. 安装 OpenClaw 运行时
5. 注册系统服务（开机自启）

安装完成后，浏览器自动打开 `http://localhost:8090`。

> 📖 遇到问题？查看 [详细安装指南](02-installation.md)

---

## 第二步：设置管理员密码

首次访问时，设置管理员密码（至少 8 位）：

1. 输入密码并再次确认
2. 点击**确认设置**
3. 自动进入配置向导

---

## 第三步：完成配置向导

向导引导你完成两件事：

1. **检测运行环境** — 确认 Node.js / Docker / Nomad / OpenClaw 均正常
2. **配置 AI 模型提供商** — 填写 API Key（支持 OpenAI、Anthropic、Google、Ollama 等）

点击**完成**后进入主界面。

> 📖 详细说明见 [初次配置向导](03-first-setup.md)

---

## 第四步：创建第一个实例

1. 点击左上角 **+ 新建实例**
2. 填写实例名称（如 `我的助手`）
3. 点击**创建**

实例自动启动，状态变为绿色「运行中」。

---

## 第五步：开始对话

点击实例名称进入详情页，**Chat** 标签已内嵌对话界面，直接输入消息即可。

---

## 下一步

| 目标 | 文档 |
|------|------|
| 接入飞书 / 微信 | [IM 渠道接入](06-im-channels.md) |
| 安装扩展技能 | [Skills 使用](07-skills.md) |
| 接入 MCP 工具 | [MCP 配置](08-mcp-servers.md) |
| 管理多个实例 | [实例管理](04-instance-management.md) |
| 查看所有斜杠命令 | [Slash 命令参考](09-slash-commands.md) |

---

内容由AI生成，欢迎联系support@aijishu.com
