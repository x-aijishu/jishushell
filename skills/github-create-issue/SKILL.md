---
name: github-create-issue
version: 1.1.0
description: 收集 JishuShell 运行日志并打包，方便提交 GitHub Issue 或直接发送给维护者
author: jishushell-team
tags: [debug, github, issue, support]
slash_command: /github-create-issue
---

# GitHub Issue 提交助手

当用户输入 `/github-create-issue` 或说「帮我提交 issue / 收集日志」时执行以下步骤。

## 执行一键收集脚本

告知用户运行以下命令，脚本会自动完成日志收集、环境信息采集、脱敏处理并打包：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/x-aijishu/jishushell/main/skills/github-create-issue/github-create-issue.sh)
```

**本地已安装时**直接运行：

```bash
bash ~/.jishushell/skills/github-create-issue/github-create-issue.sh
```

不想自动打开浏览器时加 `--no-open` 参数。

---

## 脚本完成后的操作

脚本输出的日志包路径形如 `~/jishushell-issue-<时间戳>.tar.gz`，包含：

| 文件 | 内容 |
|------|------|
| `install.log` | 最新安装日志 |
| `jishushell.log` | JishuShell 主日志 |
| `nomad.log` | Nomad 调度日志 |
| `journal.log` | systemd journalctl 输出 |
| `instances.log` | 各实例最新日志 |
| `env.txt` | 系统和软件版本信息 |

**有 GitHub 账号** → 前往 https://github.com/x-aijishu/jishushell/issues/new，将 `env.txt` 内容粘贴为 Issue 正文并附上日志包。

**无 GitHub 账号** → 将 `*.tar.gz` 文件通过微信 / 邮件发送给维护者即可。

---

## AI 辅助分析（可选）

如果用户希望在提交前先分析日志，执行：

```bash
mkdir -p /tmp/jishushell-issue-preview
tar -xzf ~/jishushell-issue-*.tar.gz -C /tmp/jishushell-issue-preview/
cat /tmp/jishushell-issue-preview/*/env.txt
```

识别关键词：`ERROR`、`FAILED`、`ENOENT`、`EACCES`、`EADDRINUSE`、`timeout`、`Permission denied`

按以下格式生成 Issue 草稿供用户复制：

```
**标题建议**：[根据错误关键词生成，15字以内]

**问题描述**
[一段话描述现象]

**复现步骤**
1. ...
2. ...

**错误信息**
[关键错误，≤30行]

**环境**
| 项目 | 版本 |
|------|------|
| OS   | ...  |
| Arch | ...  |
| Node | ...  |
| JishuShell | ... |

<details>
<summary>完整日志（已附件）</summary>
见附件 jishushell-issue-<时间戳>.tar.gz
</details>
```
