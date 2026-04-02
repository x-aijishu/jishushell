# 详细安装指南

> 覆盖完整安装流程，包括各平台说明、安装后目录结构、常见问题排查和卸载方法。

---

## 系统要求

| 项目 | 最低要求 |
|------|---------|
| 操作系统 | Raspberry Pi OS (64-bit) / Ubuntu 20.04+ / Debian 11+ / macOS 12+ |
| CPU 架构 | arm64 |
| 内存 | ≥ 4 GB（推荐 8 GB）|
| 磁盘空间 | ≥ 8 GB 可用空间 |
| 网络 | 需连接互联网（用于下载依赖）|
| 已有 | `curl`（系统内置即可）|

---

## 一键安装

```bash
curl -fsSL https://aijishu.com/install.sh | bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/x-base/jishushell/main/install/jishu-install.sh | bash
```

### 安装脚本做了什么？

安装脚本（`jishu-install.sh`）按顺序执行以下步骤：

1. **检测并安装 Node.js** — 通过 nvm 安装 Node.js ≥ 22
2. **检测并安装 Docker** — 优先使用 get.docker.com 官方脚本；若官方脚本失败（网络问题、GPG 错误等），自动降级为 `apt-get install docker.io`（或 dnf/yum）作为保底（已安装则跳过）
3. **安装 Nomad** — 下载 HashiCorp Nomad 调度引擎，配置 ACL 令牌
4. **安装 JishuShell 面板** — `npm install -g jishushell`
5. **生成启动脚本** — 写入 `~/.jishushell/bin/jishushell-start`（内嵌绝对 Node.js 路径，兼容 systemd）
6. **注册系统服务**
   - Linux：注册 `nomad.service` + `jishushell.service`（systemd）
   - macOS：注册 launchd plist
7. **启动服务** — 自动打开 `http://localhost:8090`

> **安全说明**：所有下载均强制 TLS 1.2+，临时文件在退出时自动清理。

---

## 安装后目录结构

```
~/.jishushell/
├── bin/
│   ├── jishushell-start      # 面板启动脚本
│   └── nomad                 # Nomad 二进制
├── nomad/
│   ├── nomad.hcl             # Nomad 配置（含 ACL）
│   ├── nomad.log             # Nomad 启动日志
│   └── data/                 # Nomad 状态数据
├── instances/                # 所有 OpenClaw 实例目录
│   └── <instance-id>/
│       └── openclaw-home/
│           └── .openclaw/
│               ├── openclaw.json     # 实例配置
│               ├── workspace/
│               │   ├── skills/       # 已安装的 Skills
│               │   └── config/
│               │       └── mcporter.json  # MCP 配置
│               └── ...
├── packages/                 # npm 包缓存
├── panel.json                # 面板运行时配置
├── nomad.env                 # NOMAD_TOKEN（权限 600）
└── jishushell.log            # 面板服务日志
```

---

## 验证安装

```bash
# 检查面板服务状态
systemctl status jishushell

# 检查 Nomad 状态
systemctl status nomad

# 访问面板
curl -I http://localhost:8090
```

---

## 常见问题

### `curl: command not found`

```bash
# Debian/Ubuntu
sudo apt-get install -y curl

# macOS
brew install curl
```

### Node.js 安装失败

安装脚本依赖 nvm，确保 `$HOME` 目录可写，然后手动执行：

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 22
```

### Docker 权限问题（Linux）

安装脚本会自动为当前用户处理 docker 组权限，并按以下三级策略在**当前会话**内立即激活 docker 访问权限，无需重新登录：

| 优先级 | 方式 | 说明 |
|--------|------|------|
| 1 | `sg docker -c` | 通过 sg 切换组，最常见 |
| 2 | `setfacl` ACL 授权 | 对 `/var/run/docker.sock` 授予用户读写权限（需 `acl` 包）|
| 3 | `sudo docker` 临时代理 | 前两种均失败时的最终兜底，重启后不再需要 |

若安装完成后仍提示权限不足，手动执行：

```bash
sudo usermod -aG docker $USER
newgrp docker   # 在当前终端立即生效，或重新登录
```

### 端口 8090 已被占用

修改面板端口（安装前设置环境变量）：

```bash
export JISHUSHELL_PORT=8091
curl -fsSL https://aijishu.com/install.sh | bash
```

## 更新 JishuShell

面板检测到新版本时会在顶部显示更新提示，点击**立即升级**即可。

或通过命令行手动更新：

```bash
npm install -g jishushell@latest
systemctl restart jishushell
```

---

## 卸载

### 推荐方式（完整清理）

```bash
jishushell uninstall
```

该命令会：
1. 停止 JishuShell 和 Nomad 服务并移除开机自启
2. 删除 `~/.jishushell` 数据目录（实例、配置、日志）
3. 执行 `npm uninstall -g jishushell`

加 `--yes` 跳过确认提示：

```bash
jishushell uninstall --yes
```

### 手动方式

```bash
# 停止服务并取消开机自启（保留数据）
bash jishu-uninstall.sh

# 完全卸载（删除所有组件）
bash jishu-uninstall.sh --all

# 仅卸载特定组件
bash jishu-uninstall.sh --nomad         # 仅卸载 Nomad
bash jishu-uninstall.sh --openclaw      # 仅卸载 OpenClaw
bash jishu-uninstall.sh --node          # 仅卸载 Node.js（nvm）
bash jishu-uninstall.sh --docker        # 仅卸载 Docker
bash jishu-uninstall.sh --data          # 仅删除 ~/.jishushell 数据目录
```

> ⚠️ `--all` 会删除所有容器、镜像和卷，**实例数据也会丢失**，请提前备份。

使用 `--dry-run` 预览将要执行的操作：

```bash
bash jishu-uninstall.sh --all --dry-run
```

---

## 相关文档

- [快速上手](01-quick-start.md)
- [初次配置向导](03-first-setup.md)

---

内容由AI生成，欢迎联系support@aijishu.com
