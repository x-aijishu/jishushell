# JishuShell

[![License](https://img.shields.io/badge/License-Apache%202.0-blue)](LICENSE) [![npm](https://img.shields.io/badge/npm-jishushell-orange?logo=npm)](https://www.npmjs.com/package/jishushell) [![Node](https://img.shields.io/badge/Node.js-%3E%3D22-green?logo=node.js)](https://nodejs.org/) [![Project Status](https://img.shields.io/badge/status-alpha-orange)]()

> ## 🚧 开源筹备中，敬请期待
>
> JishuShell 正在积极筹备开源，代码仓库即将公开。欢迎关注本项目，届时将第一时间收到通知。感谢您的支持与耐心！
>
> **[Star 本仓库](https://github.com/x-aijishu/jishushell)** 以获取最新动态。

---

JishuShell 是 AI Agent 实例的 Web 管理面板。它提供实例生命周期管理、内置兼 LLM 代理（支持 30+ 提供商）、技能市场、MCP 服务器管理、即时通讯频道接入，以及实时系统监控——所有功能均通过中英双语 Web UI 呈现，专为Arm生态设计。

> **Beta 版本。** JishuShell 正处于开发阶段。核心功能——实例管理、LLM 代理、技能/MCP、系统监控——已在树莓派/Rockchip RK3588/此芯P1/Nvidia Jetson等Arm设备经过功能验证。API 可能发生变更。欢迎贡献代码。

## 快速开始

### 前置要求

- **Node.js 22+**（必需）
- **Linux**（树莓派 OS、Debian、Ubuntu）或 **macOS**

### 安装

Shell 安装脚本：
```bash
curl -fsSL https://aijishu.com/install.sh | bash
```

NPM 安装
```bash
npm install -g jishushell
```

在浏览器中打开 `http://localhost:8090`。