<!-- 建议素材：assets/JishuShellBanner.png、assets/JishuShellLogo.png、assets/JishuShellDemo.gif -->

# JishuShell

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![npm](https://img.shields.io/npm/v/jishushell?logo=npm)](https://www.npmjs.com/package/jishushell)
[![Node.js](https://img.shields.io/badge/Node.js-%3E%3D22-green?logo=node.js)](https://nodejs.org/)
[![Status](https://img.shields.io/badge/status-beta-orange)]()

**在自己的设备上一键部署和管理 Agent 与 AI 应用。**  
**All your agents and AI apps, one JishuShell.**

JishuShell 是面向本地和边缘设备的 AI Agent 管理面板。它帮助你在一台 Arm 设备上运行多个独立 Agent，统一管理模型、Skills、MCP、消息渠道、AI 应用和系统状态。

JishuShell is a Web control plane for deploying and managing multiple AI agents and supporting applications on local and edge devices, with one place for models, Skills, MCP servers, messaging channels, and system health.

[官方网站](https://aijishu.com/jishushell) · [快速开始](guidance/01-quick-start.md) · [使用文档](guidance/README.md) · [npm](https://www.npmjs.com/package/jishushell) · [更新日志](blogs/summary.md)

> **开源筹备中**
>
> 当前仓库用于产品介绍、安装、文档和版本发布。完整产品源代码仍在准备公开，欢迎 Star 本仓库关注后续进展。

<img src="./assets/JishuShellBanner.png" alt="JishuShell" width="100%">

## Overview / 项目简介

安装一个 Agent 并不难，难的是长期管理它依赖的模型、工具、数据、渠道和运行环境。JishuShell 把这些能力放进同一个中英双语 Web 面板，让你不必反复配置命令行环境，也能创建、运行和维护多个 Agent。

JishuShell 以 OpenClaw 为主要 Agent 运行时，并将 JishuDB、Drive、SearXNG、Immich 等知识、文件、搜索和照片服务连接给 Agent。你可以从一个实例开始，也可以在设备能力允许时同时运行多个相互隔离的 Agent 与 AI 应用。

JishuShell brings agent instances and their supporting services into one bilingual Web interface. It manages the runtime around OpenClaw and connects agents with models, knowledge, files, search, messaging channels, Skills, MCP tools, and selected self-hosted applications.

## Key Capabilities / 核心能力

### One-click Deployment / 一键部署

- 使用一条命令安装 JishuShell 及所需运行环境
- 自动配置 Node.js、Docker、Nomad 和系统服务
- 安装完成后通过浏览器继续设置，无需手工拼装整套 Agent 环境
- Linux 使用 systemd、macOS 使用 launchd 保持服务运行

### Multiple Agent Instances / Agent 多开

- 在一台设备上创建和管理多个独立 Agent 实例
- 支持创建、启动、停止、重启、克隆和删除实例
- 每个实例拥有独立的配置、工作区、Skills 和 MCP 连接
- 通过统一面板查看实例状态并进入内置对话界面

### Models, Skills and MCP / 模型与工具

- 内置 LLM 代理，支持 OpenAI、Anthropic、Google、Ollama 等 30+ 模型提供商
- 为不同 Agent 选择和管理模型连接
- 安装和管理 Skills，扩展 Agent 的任务能力
- 添加和维护 MCP Server，把外部工具连接给 Agent
- API Key 独立管理，避免在不同实例间无意混用

### Messaging Channels / 消息渠道

- 接入飞书、Lark 和微信等消息渠道
- 通过扫码或配置插件，把 Agent 带到日常使用的聊天入口
- 一个面板管理渠道配置和实例连接

### AI Applications / AI 应用

JishuShell 不只管理 Agent，也可以部署并连接 Agent 周边应用：

- **JishuDB**：为 Agent 提供可管理、可检索的长期知识
- **Drive**：让 Agent 浏览、读取、搜索和管理授权文件
- **SearXNG**：提供可自托管的联网搜索
- **Immich**：通过自然语言搜索和整理自托管照片库
- **Browserless**：为网页访问和浏览器自动化提供运行环境
- **FileBrowser**：通过网页管理设备上的文件

实际可安装应用和功能范围以当前版本、平台及应用市场显示为准。

### Isolation and Permissions / 隔离与权限

- 使用容器隔离 Agent、AI 应用与宿主系统环境
- 不同实例分别管理配置、凭据和工作空间
- 数据和工具按连接授权给 Agent，而不是默认全部开放
- 涉及删除照片等破坏性操作时，先展示待处理内容并由用户确认
- 内置知识服务默认只向 Agent 提供经过约束的工具集合

### Monitoring and Maintenance / 监控与维护

- 实时查看 CPU、内存、磁盘和支持设备的温度信息
- 查看实例日志和运行状态
- 检测新版本并通过面板一键升级
- 使用 `doctor` 检查环境，使用 `repair` 对账和修复系统组件
- 支持备份实例配置、Skills 和 MCP 配置

## Quick Start / 快速开始

### Requirements / 前置要求

- Arm64 设备或 Apple Silicon Mac
- Linux 或 macOS
- Node.js 22+（直接使用 npm 安装时）
- 可连接互联网，用于下载依赖、运行时和应用

官网建议从以下配置起步：

- 4 核 Arm Cortex-A72 或更高
- 4 GB 内存
- 16 GB 存储空间
- Ubuntu 22.04+、Debian 12+ 或受支持的 macOS

### Install / 安装

推荐使用一键安装脚本：

```bash
curl -fsSL https://aijishu.com/install.sh | bash
```

安装脚本会检测并配置所需组件、注册系统服务并启动 JishuShell。

也可以通过 npm 安装：

```bash
npm install -g jishushell
```

### Open / 打开

安装完成后，在浏览器中打开：

```text
http://localhost:8090
```

首次访问时设置管理员密码，然后按向导检查环境、配置模型提供商并创建第一个 Agent 实例。

## Usage / 使用方式

| 想做什么 | 在 JishuShell 中如何开始 |
| --- | --- |
| 创建第一个 Agent | 点击“新建实例”，填写名称并启动 |
| 与 Agent 对话 | 打开实例详情页中的 Chat |
| 切换或添加模型 | 在设置中配置 Provider，再绑定到实例 |
| 安装任务能力 | 从 Skills 页面选择并安装所需 Skill |
| 连接外部工具 | 在 MCP 页面添加并验证 MCP Server |
| 通过聊天软件使用 | 为实例配置飞书、Lark 或微信渠道 |
| 给 Agent 接入知识 | 安装并连接 JishuDB |
| 查看设备状态 | 在概览或设置页查看 CPU、内存、磁盘和温度 |

常用维护命令：

```bash
jishushell doctor
npm install -g jishushell@latest
sudo jishushell repair
```

系统级安装升级后，请根据终端显示的 `ACTION REQUIRED` 提示决定是否需要执行 `repair`。

## Supported Platforms / 支持平台

JishuShell 主要面向长期运行 Agent 的 Arm 设备，现有功能已在以下平台或设备系列上进行验证：

- Raspberry Pi
- Rockchip RK3588
- 此芯 P1
- NVIDIA Jetson
- Apple Silicon Mac
- Raspberry Pi OS、Debian、Ubuntu 和 macOS

不同型号、系统版本和外设组合的兼容性可能不同，请以安装检测和当前发布说明为准。部分内置应用可能只支持 Linux/arm64。

## Documentation / 文档

| Topic / 主题 | Link / 链接 |
| --- | --- |
| 快速上手 | [guidance/01-quick-start.md](guidance/01-quick-start.md) |
| 详细安装 | [guidance/02-installation.md](guidance/02-installation.md) |
| 初次配置 | [guidance/03-first-setup.md](guidance/03-first-setup.md) |
| 实例管理 | [guidance/04-instance-management.md](guidance/04-instance-management.md) |
| 实例配置 | [guidance/05-instance-config.md](guidance/05-instance-config.md) |
| 消息渠道 | [guidance/06-im-channels.md](guidance/06-im-channels.md) |
| Skills | [guidance/07-skills.md](guidance/07-skills.md) |
| MCP Server | [guidance/08-mcp-servers.md](guidance/08-mcp-servers.md) |
| Slash Commands | [guidance/09-slash-commands.md](guidance/09-slash-commands.md) |
| 系统维护 | [guidance/10-system-maintenance.md](guidance/10-system-maintenance.md) |
| 更新日志 | [blogs/summary.md](blogs/summary.md) |

## Boundaries and Security / 边界与安全

- 本地部署不代表所有数据天然只在本地处理；使用云端模型或外部服务时，相关请求仍会发送给对应提供商
- 安装 Skill、MCP 或应用不等于自动授予账户、文件、知识库或发布权限
- Agent 只能访问明确连接和授权的数据与工具
- 删除实例、应用或数据前应确认影响范围并完成必要备份
- 重启调度引擎会短暂中断正在运行的实例
- 已验证设备不代表所有系统镜像、驱动、外设和应用组合都已完成测试
- JishuShell 会降低部署和管理门槛，但不能替代用户对模型费用、第三方服务条款和数据权限的判断

## Project Status / 项目状态

**Beta**

JishuShell 已提供安装、实例管理、模型连接、Skills、MCP、消息渠道、应用管理和系统监控等核心能力，但仍在持续开发中。API、配置格式、应用契约和兼容范围可能随版本调整。

The core deployment and management workflows are available, while APIs, configuration formats, application contracts, and platform compatibility may continue to evolve during Beta.

## License

[Apache License 2.0](LICENSE)

## About AIJISHU

JishuShell 由 [AIJISHU](https://aijishu.com/) 团队打造。我们关注 AI Agent、知识工具、评测系统，以及 AI 与真实设备结合的开发体验。

**AIJISHU builds practical AI tools for agents, knowledge, evaluation, and real-world development.**
