#!/usr/bin/env bash
# github-create-issue.sh
# 收集 JishuShell 运行日志并打包，方便提交 Issue 或分享给维护者
# 用法: bash github-create-issue.sh [--no-open]

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
header(){ echo -e "\n${BOLD}$*${RESET}"; }

# ── 参数 ──────────────────────────────────────────────────────────────────────
OPEN_BROWSER=true
for arg in "$@"; do
  [[ "$arg" == "--no-open" ]] && OPEN_BROWSER=false
done

# ── 工作目录 ──────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$HOME/jishushell-issue-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

header "=== JishuShell Issue 日志收集工具 ==="
info "输出目录：$OUTPUT_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: 收集日志文件
# ══════════════════════════════════════════════════════════════════════════════
header "Step 1/4  收集日志文件"

## 安装日志（取最新一份）
LATEST_LOG=""
while IFS= read -r f; do
  [[ -z "$LATEST_LOG" || "$f" -nt "$LATEST_LOG" ]] && LATEST_LOG="$f"
done < <(find ~ /tmp -maxdepth 2 -name "jishu-install-*.log" 2>/dev/null)

if [[ -n "$LATEST_LOG" && -f "$LATEST_LOG" ]]; then
  cp "$LATEST_LOG" "$OUTPUT_DIR/install.log"
  ok "安装日志：$LATEST_LOG"
else
  warn "未找到 jishu-install-*.log"
fi

## JishuShell 主日志
if [[ -f ~/.jishushell/jishushell.log ]]; then
  cp ~/.jishushell/jishushell.log "$OUTPUT_DIR/jishushell.log"
  ok "JishuShell 主日志"
else
  warn "未找到 ~/.jishushell/jishushell.log"
fi

## Nomad 日志（兼容两条路径）
NOMAD_LOG=""
[[ -f ~/.jishushell/nomad/nomad.log ]] && NOMAD_LOG=~/.jishushell/nomad/nomad.log
[[ -z "$NOMAD_LOG" && -f ~/.jishushell/nomad.log ]] && NOMAD_LOG=~/.jishushell/nomad.log
if [[ -n "$NOMAD_LOG" ]]; then
  cp "$NOMAD_LOG" "$OUTPUT_DIR/nomad.log"
  ok "Nomad 日志"
else
  warn "未找到 Nomad 日志"
fi

## journalctl（若可用）
if command -v journalctl &>/dev/null; then
  {
    echo "=== jishushell service ==="
    journalctl -u jishushell --no-pager -n 100 2>/dev/null || echo "(无 jishushell 服务)"
    echo ""
    echo "=== nomad service ==="
    journalctl -u nomad --no-pager -n 50 2>/dev/null || echo "(无 nomad 服务)"
  } > "$OUTPUT_DIR/journal.log" 2>&1
  ok "journalctl 日志"
fi

## 实例目录中的日志（最近 20 个 log 文件，各取末 50 行）
if [[ -d ~/.jishushell/instances ]]; then
  {
    while IFS= read -r f; do
      echo ""; echo "=== $f ==="; tail -50 "$f" 2>/dev/null
    done < <(find ~/.jishushell/instances -maxdepth 3 -name "*.log" -mtime -7 2>/dev/null | head -20)
  } > "$OUTPUT_DIR/instances.log" 2>&1
  ok "实例日志"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: 收集环境信息
# ══════════════════════════════════════════════════════════════════════════════
header "Step 2/4  收集环境信息"

ENV_FILE="$OUTPUT_DIR/env.txt"
{
  echo "=== 系统信息 ==="
  echo "收集时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "OS:       $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
  echo "Arch:     $(uname -m)"
  echo "Kernel:   $(uname -r)"
  echo "Hostname: $(hostname)"
  echo ""

  echo "=== 软件版本 ==="
  echo "Node:     $(node --version 2>/dev/null || echo 'not found')"
  echo "npm:      $(npm --version 2>/dev/null || echo 'not found')"
  echo "Docker:   $(docker --version 2>/dev/null || echo 'not found')"
  echo "Nomad:    $(~/.jishushell/bin/nomad version 2>/dev/null | head -1 || echo 'not found')"

  JS_PKG=$(npm root -g 2>/dev/null)/jishushell/package.json
  if [[ -f "$JS_PKG" ]]; then
    JS_VER=$(node -p "require('$JS_PKG').version" 2>/dev/null || echo 'parse error')
  else
    JS_VER="not installed"
  fi
  echo "JishuShell: $JS_VER"
  echo ""

  echo "=== 相关端口占用 ==="
  ss -tlnp 2>/dev/null | grep -E '8090|4646|4647|4648' || \
    netstat -tlnp 2>/dev/null | grep -E '8090|4646|4647|4648' || \
    echo "(端口检查不可用)"
  echo ""

  echo "=== 磁盘空间 ==="
  df -h ~ 2>/dev/null || true
  echo ""

  echo "=== 内存 ==="
  free -h 2>/dev/null || true
} > "$ENV_FILE" 2>&1

cat "$ENV_FILE"
ok "环境信息已写入 env.txt"

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: 脱敏处理
# ══════════════════════════════════════════════════════════════════════════════
header "Step 3/4  脱敏处理"

for f in "$OUTPUT_DIR"/*.log "$OUTPUT_DIR"/*.txt; do
  [[ -f "$f" ]] || continue
  sed -i \
    -e 's/sk-[A-Za-z0-9_-]\{8,\}/sk-[REDACTED]/g' \
    -e 's/Bearer [A-Za-z0-9._~+\/-]\{8,\}/Bearer [REDACTED]/g' \
    -e 's/password[=:][^ \t]*/password=[REDACTED]/gi' \
    -e 's/secret[=:][^ \t]*/secret=[REDACTED]/gi' \
    "$f" 2>/dev/null || true
done
ok "脱敏完成（API Key / Token / password / secret）"

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: 打包
# ══════════════════════════════════════════════════════════════════════════════
header "Step 4/4  打包"

ARCHIVE="$HOME/jishushell-issue-${TIMESTAMP}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>/dev/null
rm -rf "$OUTPUT_DIR"

FILESIZE=$(du -sh "$ARCHIVE" 2>/dev/null | cut -f1 || echo "?")
ok "日志包已生成"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}日志包路径：${RESET} $ARCHIVE"
echo -e "${GREEN}文件大小：${RESET}   $FILESIZE"
echo ""
echo -e "▶ ${BOLD}下一步${RESET}"
echo "  有 GitHub 账号 → 前往 https://github.com/x-aijishu/jishushell/issues/new"
echo "               将 env.txt 内容粘贴到 Issue，并上传日志包"
echo "  无 GitHub 账号 → 将此文件发送给维护者："
echo "                  $ARCHIVE"
echo ""
echo "  查看包内容：tar -tzf \"$ARCHIVE\""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# ── 打开浏览器（可选）────────────────────────────────────────────────────────
if [[ "$OPEN_BROWSER" == true ]]; then
  ISSUE_URL="https://github.com/x-aijishu/jishushell/issues/new"
  xdg-open "$ISSUE_URL" 2>/dev/null \
    || open "$ISSUE_URL" 2>/dev/null \
    || info "请手动打开：$ISSUE_URL"
fi
