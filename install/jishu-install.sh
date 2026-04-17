#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# JishuShell Installer
#
# Self-contained installer for all JishuShell dependencies:
#   Node.js (via nvm), Docker, Nomad, OpenClaw Docker image
#
# Can also be sourced by other scripts (post-install.sh, jishu-uninstall.sh)
# to reuse shared functions — main() only runs when executed directly.
#
# Usage:
#   bash jishu-install.sh [options]       — run the full installer
#   source jishu-install.sh               — import functions only
# ═══════════════════════════════════════════════════════════════════════════════

# Guard against double-sourcing
if [[ -n "${_JISHU_INSTALL_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_JISHU_INSTALL_LOADED=1

# ═══════════════════════════════════════════════════════════════════════════════
# Temporary File Management (trap cleanup)
# ═══════════════════════════════════════════════════════════════════════════════
TMPFILES=()
_SUDO_KEEPALIVE_PID=""

cleanup_tmpfiles() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        rm -rf "$f" 2>/dev/null || true
    done
    # Kill sudo keepalive background process if running
    if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup_tmpfiles EXIT

mktempfile() {
    local f
    f="$(mktemp)"
    TMPFILES+=("$f")
    echo "$f"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Download Tool Detection
# ═══════════════════════════════════════════════════════════════════════════════
DOWNLOADER=""
detect_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
        return 0
    fi
    if command -v wget &> /dev/null; then
        DOWNLOADER="wget"
        return 0
    fi
    ui_error "Missing downloader (curl or wget required)"
    exit 1
}

download_file() {
    local url="$1"
    local output="$2"
    if [[ -z "$DOWNLOADER" ]]; then
        detect_downloader
    fi
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --retry-connrefused -o "$output" "$url"
        return
    fi
    wget -q --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=20 -O "$output" "$url"
}

# retry_net <description> <max_attempts> <cmd> [args...]
# Runs cmd up to max_attempts times; waits 5s, 10s between retries.
# Network-related exit codes (6,7,28,35,56 for curl; DNS/timeout) are all retried.
retry_net() {
    local desc="$1"
    local max="${2:-3}"
    shift 2
    local attempt=1
    local delay=5
    while true; do
        if "$@"; then
            return 0
        fi
        local rc=$?
        if [[ $attempt -ge $max ]]; then
            ui_error "${desc} failed after ${max} attempts (last exit code: ${rc})"
            return $rc
        fi
        ui_warn "${desc} failed (attempt ${attempt}/${max}, exit ${rc}) — retrying in ${delay}s..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 ))
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# Non-interactive Shell Detection
# ═══════════════════════════════════════════════════════════════════════════════
is_non_interactive_shell() {
    if [[ "${NO_PROMPT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        return 0
    fi
    return 1
}

is_promptable() {
    if [[ "${NO_PROMPT:-0}" == "1" ]]; then
        return 1
    fi
    # Web-triggered upgrades never have an interactive TTY
    if [[ "${JISHUSHELL_WEB_UPDATE:-0}" == "1" ]]; then
        return 1
    fi
    if ( : <> /dev/tty ) 2>/dev/null; then
        return 0
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Holiday Taglines (fun Easter eggs)
# ═══════════════════════════════════════════════════════════════════════════════
HOLIDAY_NEW_YEAR="New year, new config—same old EADDRINUSE, but this time we resolve it like grown-ups."
HOLIDAY_CHRISTMAS="Ho ho ho—Santa's little helper is here to ship joy, roll back chaos, and stash the keys safely."
HOLIDAY_HALLOWEEN="Spooky season: beware haunted dependencies, cursed caches, and the ghost of node_modules past."
HOLIDAY_THANKSGIVING="Grateful for stable ports, working DNS, and a bot that reads the logs so nobody has to."

append_holiday_taglines() {
    local month_day
    month_day="$(date -u +%m-%d 2>/dev/null || date +%m-%d)"
    case "$month_day" in
        "01-01") TAGLINE="${HOLIDAY_NEW_YEAR}" ;;
        "12-25") TAGLINE="${HOLIDAY_CHRISTMAS}" ;;
        "10-31") TAGLINE="${HOLIDAY_HALLOWEEN}" ;;
        "11-27"|"11-28") TAGLINE="${HOLIDAY_THANKSGIVING}" ;;
    esac
}

pick_tagline() {
    if [[ -n "${JISHU_TAGLINE:-}" ]]; then
        TAGLINE="${JISHU_TAGLINE}"
        return
    fi
    append_holiday_taglines
    if [[ -z "${TAGLINE:-}" ]]; then
        TAGLINE="   All your agents, one JishuShell."
    fi
}

# Script directory (BASH_SOURCE[0] is unset when piped via curl|bash, fall back to $0)
JISHU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || pwd)"

# ═══════════════════════════════════════════════════════════════════════════════
# ──── BEGIN VERSIONS ────
NODE_VERSION="${JISHU_NODE_VERSION:-22}"
NVM_VERSION="${JISHU_NVM_VERSION:-0.40.4}"
NOMAD_VERSION="${JISHU_NOMAD_VERSION:-1.6.5}"
JISHUSHELL_PORT="${JISHUSHELL_PORT:-8090}"

# ──── NPM Registry Configuration ────
# Pass --registry <url> to override the npm registry for all installs.
NPM_REGISTRY="${NPM_REGISTRY:-}"
# Resolve the real (non-root) user when running via sudo.
# REAL_USER / REAL_HOME are used wherever paths must belong to the target user.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    REAL_USER="${SUDO_USER}"
    REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6 2>/dev/null || echo "")"
elif [[ $EUID -eq 0 ]]; then
    # Running as root without sudo — try to detect the first non-root UID-1000 user
    # (common default user on Raspberry Pi, Ubuntu, etc.)
    _fallback_user="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
    if [[ -n "${_fallback_user}" && "${_fallback_user}" != "root" ]]; then
        REAL_USER="${_fallback_user}"
        REAL_HOME="$(getent passwd "${_fallback_user}" | cut -d: -f6 2>/dev/null || echo "")"
    else
        REAL_USER="$(id -un)"
        REAL_HOME="${HOME}"
    fi
    unset _fallback_user
else
    REAL_USER="$(id -un)"
    REAL_HOME="${HOME}"
fi
[[ -z "${REAL_HOME}" ]] && REAL_HOME="${HOME}"
REAL_GID="$(id -g "${REAL_USER}" 2>/dev/null || echo "")"

# JISHUSHELL_HOME always lives in the real user's home so data is accessible
# regardless of whether the process runs as root or as that user.
if [[ -z "${JISHUSHELL_HOME:-}" ]]; then
    JISHUSHELL_HOME="${REAL_HOME}/.jishushell"
fi
JISHUSHELL_BIN_DIR="${JISHUSHELL_BIN_DIR:-$JISHUSHELL_HOME/bin}"
# ──── END VERSIONS ────

# Pick tagline
TAGLINE=""
pick_tagline

# Colors
BOLD='\033[1m'
ACCENT='\033[38;2;66;135;245m'
ACCENT_CORAL='\033[38;2;255;77;77m'
INFO='\033[38;2;136;146;176m'
SUCCESS='\033[38;2;0;229;204m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;230;57;70m'
MUTED='\033[38;2;90;100;128m'
NC='\033[0m'

# Shared state
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_NODE="${SKIP_NODE:-0}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"
SKIP_NOMAD="${SKIP_NOMAD:-0}"
SKIP_OPENCLAW="${SKIP_OPENCLAW:-0}"  # default=0 (install); use --skip 4 or --skip-openclaw to skip
SKIP_JISHUSHELL="${SKIP_JISHUSHELL:-0}"          # 1=skip install_jishushell
SKIP_JISHUSHELL_SERVICE="${SKIP_JISHUSHELL_SERVICE:-0}"  # 1=skip service registration
JISHUSHELL_NPM_VERSION="${JISHUSHELL_NPM_VERSION:-latest}"  # jishushell npm package version
JISHUSHELL_VERSION_OVERRIDE=0
if [[ "${JISHUSHELL_NPM_VERSION}" != "latest" ]]; then
    JISHUSHELL_VERSION_OVERRIDE=1
fi
OPENCLAW_NPM_VERSION="${OPENCLAW_NPM_VERSION:-latest}"   # openclaw npm package version
OPENCLAW_DOCKER_TAG="${OPENCLAW_DOCKER_TAG:-ghcr.io/x-aijishu/openclaw-runtime:latest}"  # pre-built image from registry
OPENCLAW_IMAGE=""                                        # set dynamically after pull/build
AUTO_YES="${AUTO_YES:-0}"
DOCKER_CMD_PREFIX=""          # Set to "sg docker -c" when group activated via sg
DOCKER_GROUP_JUST_ADDED=0     # 1 if usermod was called this run
DOCKER_USE_SUDO=0             # 1 if sudo docker should be used as fallback

PKG_UPDATED=0

INSTALL_STAGE_TOTAL="${INSTALL_STAGE_TOTAL:-6}"
INSTALL_STAGE_CURRENT="${INSTALL_STAGE_CURRENT:-0}"
JISHU_LOG_FILE=""
_JISHU_RAW_LOG=""
_JISHU_TEE_PID=""
_JISHU_LOG_FIFO=""
_JISHU_DETAIL_LOG=""

# Legacy environment variable mapping
map_legacy_env() {
    local key="$1"
    local legacy="$2"
    if [[ -z "${!key:-}" && -n "${!legacy:-}" ]]; then
        printf -v "$key" '%s' "${!legacy}"
    fi
}

# (legacy env var mappings reserved for future renames)

# ─── UI helpers ───────────────────────────────────────────────────────────────
ui_info() {
    echo -e "${MUTED}·${NC} $*"
}

ui_success() {
    echo -e "${SUCCESS}✓${NC} $*"
}

ui_warn() {
    echo -e "${WARN}!${NC} $*"
}

ui_error() {
    echo -e "${ERROR}✗${NC} $*" >&2
}

ui_stage() {
    local title="$1"
    INSTALL_STAGE_CURRENT=$((INSTALL_STAGE_CURRENT + 1))
    echo ""
    echo -e "${ACCENT}${BOLD}[${INSTALL_STAGE_CURRENT}/${INSTALL_STAGE_TOTAL}] ${title}${NC}"
}

ui_section() {
    echo -e "\n${ACCENT}${BOLD}── $* ──${NC}"
}

ui_kv() {
    local key="$1" value="$2"
    printf "${MUTED}%-18s${NC} %s\n" "$key:" "$value"
}

# ─── Detail-log helpers ───────────────────────────────────────────────────────
# Appends one line directly to the detail log file (bypasses the terminal pipe).
log_detail() {
    [[ -n "${_JISHU_DETAIL_LOG:-}" ]] || return 0
    printf '%s\n' "$*" >> "${_JISHU_DETAIL_LOG}"
}

# Runs a command, capturing stdout+stderr to the detail log file only.
# Nothing is written to the terminal — use ui_* helpers for status messages.
# Returns the command's exit code.
log_cmd() {
    local _rc=0
    if [[ -z "${_JISHU_DETAIL_LOG:-}" ]]; then
        "$@" 2>&1
        return
    fi
    log_detail ""
    log_detail "[$(date '+%H:%M:%S')] \$ $*"
    # Capture output to detail log only (not forwarded to the terminal)
    local _tmp
    _tmp="$(mktemp)"
    "$@" > "${_tmp}" 2>&1 || _rc=$?
    if [[ -s "${_tmp}" ]]; then
        sed 's/^/  /' "${_tmp}" >> "${_JISHU_DETAIL_LOG}"  # → detail log only
    fi
    rm -f "${_tmp}"
    log_detail "  \u2192 exit ${_rc}"
    return $_rc
}

# Like log_cmd but prepends \$SUDO when set (mirrors run_sudo behaviour).
_log_sudo() {
    if [[ -n "${SUDO:-}" ]]; then
        log_cmd "${SUDO}" "$@"
    else
        log_cmd "$@"
    fi
}

# ─── User confirmation prompt ────────────────────────────────────────────────
# Usage: confirm "Delete everything?" && do_delete
# Respects AUTO_YES=1 to skip prompts.
confirm() {
    local prompt="$1"
    if [[ "${AUTO_YES:-0}" == "1" ]]; then
        ui_info "$prompt → auto-confirmed (--yes)"
        return 0
    fi
    local answer answer_lc
    read -r -p "$(echo -e "${WARN}  ${prompt} [y/N]: ${NC}")" answer </dev/tty || answer="n"
    answer_lc="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer_lc" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ─── Utility functions ────────────────────────────────────────────────────────

# Detect OS and package manager.
# Sets: OS_ID, OS_VERSION, OS_NAME, PKG_MANAGER
detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
        OS_ID="macos"
        OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
        OS_NAME="macOS ${OS_VERSION}"
        if command -v brew &>/dev/null; then
            PKG_MANAGER="brew"
        else
            PKG_MANAGER="none"
            ui_warn "Homebrew not found — some optional installs may be skipped"
        fi
        ui_success "OS: ${OS_NAME} (package manager: ${PKG_MANAGER})"
        return 0
    fi

    if [[ ! -f /etc/os-release ]]; then
        ui_error "Cannot detect OS: /etc/os-release not found"
        ui_error "This installer supports Linux and macOS"
        exit 1
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION}"

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora|amzn)
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            ui_warn "Untested distribution: $OS_ID — attempting auto-detect"
            if command -v apt-get &>/dev/null; then
                PKG_MANAGER="apt"
            elif command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            elif command -v yum &>/dev/null; then
                PKG_MANAGER="yum"
            else
                ui_error "No supported package manager found (apt/dnf/yum)"
                exit 1
            fi
            ;;
    esac

    OS="linux"
    ui_success "OS: ${OS_NAME} (package manager: ${PKG_MANAGER})"
}

# Detect CPU architecture.  Sets: ARCH (arm64)
# Only Arm-family (aarch64, arm64, armv7l) and Apple Silicon (Darwin/arm64)
# are supported.  x86_64, i686, riscv, mips, s390x, ppc, etc. are rejected.
detect_arch() {
    local raw_arch
    raw_arch="$(uname -m)"
    case "$raw_arch" in
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv8l|armhf)
            # 32-bit Arm — may work but not officially tested
            ARCH="arm64"
            ui_warn "32-bit Arm detected (${raw_arch}). 64-bit OS on a 64-bit board is strongly recommended."
            ;;
        *)
            ui_error "Unsupported CPU architecture: ${raw_arch}"
            ui_error ""
            ui_error "JishuShell runs exclusively on Arm-based devices (aarch64 / arm64)."
            ui_error "Supported examples: Raspberry Pi 4/5, Orange Pi 5, Jetson Orin,"
            ui_error "  Rockchip RK3588, Apple Silicon Mac (arm64 macOS)."
            ui_error ""
            ui_error "x86_64 / i686 / RISC-V / MIPS / s390x / PowerPC are not supported."
            exit 1
            ;;
    esac
    ui_success "Architecture: ${ARCH} (${raw_arch})"
}

# Verify sudo access.  Sets: SUDO ("" if root, "sudo" otherwise)
check_sudo() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        return 0
    fi

    if ! command -v sudo &>/dev/null; then
        ui_error "Not running as root and sudo is not installed. Re-run as root."
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        ui_info "Some steps require sudo — you may be prompted for your password."
        if ! is_promptable; then
            ui_error "Failed to obtain sudo privileges (no interactive TTY available)"
            exit 1
        fi
        if ! sudo -v </dev/tty; then
            ui_error "Failed to obtain sudo privileges"
            exit 1
        fi
    fi

    SUDO="sudo"
    ui_success "sudo privileges confirmed"

    # Keep sudo credentials alive for the entire install (refreshes every 60s).
    # This ensures 'sudo docker' works even after a long Docker install step
    # without prompting for the password again.
    if [[ -z "${_SUDO_KEEPALIVE_PID:-}" ]]; then
        ( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &>/dev/null &
        _SUDO_KEEPALIVE_PID=$!
        disown "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

extract_semver() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# Semantic version comparison: returns 0 if $1 >= $2
version_gte() {
    local v1="$1" v2="$2"
    if [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]; then
        return 0
    fi
    return 1
}

# Run a command, honouring --dry-run.
# When the detail log is active, command output is captured there (silent on terminal).
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] $*"
        return 0
    fi
    log_detail ""
    log_detail "[$(date '+%H:%M:%S')] \$ $*"
    if [[ -n "${_JISHU_DETAIL_LOG:-}" ]]; then
        local _rc=0 _tmp
        _tmp="$(mktemp)"
        "$@" > "${_tmp}" 2>&1 || _rc=$?
        [[ -s "${_tmp}" ]] && sed 's/^/  /' "${_tmp}" >> "${_JISHU_DETAIL_LOG}"
        rm -f "${_tmp}"
        log_detail "  \u2192 exit ${_rc}"
        return $_rc
    fi
    "$@"
}

# Run a command with sudo, honouring --dry-run.
# When the detail log is active, command output is captured there (silent on terminal).
run_sudo() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] ${SUDO:+sudo }$*"
        return 0
    fi
    log_detail ""
    log_detail "[$(date '+%H:%M:%S')] \$ ${SUDO:+${SUDO} }$*"
    if [[ -n "${_JISHU_DETAIL_LOG:-}" ]]; then
        local _rc=0 _tmp
        _tmp="$(mktemp)"
        ${SUDO} "$@" > "${_tmp}" 2>&1 || _rc=$?
        [[ -s "${_tmp}" ]] && sed 's/^/  /' "${_tmp}" >> "${_JISHU_DETAIL_LOG}"
        rm -f "${_tmp}"
        log_detail "  \u2192 exit ${_rc}"
        return $_rc
    fi
    ${SUDO} "$@"
}

# Wait for apt/dpkg locks to be released
wait_for_apt_lock() {
    if [[ "${PKG_MANAGER:-}" != "apt" ]]; then
        return 0
    fi

    local max_wait=60
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
        if [[ $waited -eq 0 ]]; then
            ui_info "Waiting for apt lock to be released..."
        fi
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge $max_wait ]]; then
            ui_error "Timed out waiting for apt lock (${max_wait}s). Check for other running package managers."
            exit 1
        fi
    done
}

# Run the package index update once per invocation.
# Safe to call multiple times — only executes on the first call.
pkg_update() {
    if [[ "$PKG_UPDATED" == "1" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would update package index"
        PKG_UPDATED=1
        return 0
    fi

    wait_for_apt_lock

    ui_info "Updating package index..."
    case "$PKG_MANAGER" in
        apt)
            if ! retry_net "apt-get update" 3 _log_sudo apt-get update; then
                ui_warn "apt-get update failed — package index may be stale, continuing anyway"
            fi
            ;;
        dnf)
            retry_net "dnf check-update" 3 _log_sudo dnf check-update 2>/dev/null || true
            ;;
        yum)
            retry_net "yum check-update" 3 _log_sudo yum check-update 2>/dev/null || true
            ;;
        brew)
            retry_net "brew update" 3 log_cmd brew update 2>/dev/null || true
            ;;
        none)
            ;;
    esac

    PKG_UPDATED=1
}

# Install system packages, ensuring the index is up to date first.
pkg_install() {
    pkg_update
    wait_for_apt_lock
    case "$PKG_MANAGER" in
        apt)
            if ! retry_net "apt-get install $*" 3 run_sudo apt-get install -y "$@"; then
                ui_error "apt-get install failed for: $*"
                return 1
            fi
            ;;
        dnf)
            if ! retry_net "dnf install $*" 3 run_sudo dnf install -y "$@"; then
                ui_error "dnf install failed for: $*"
                return 1
            fi
            ;;
        yum)
            if ! retry_net "yum install $*" 3 run_sudo yum install -y "$@"; then
                ui_error "yum install failed for: $*"
                return 1
            fi
            ;;
        brew)
            if ! retry_net "brew install $*" 3 brew install "$@" 2>/dev/null; then
                ui_warn "brew install failed for: $* (may already be installed)"
            fi
            ;;
        none)
            ui_warn "No package manager available — skipping install of: $*"
            ;;
    esac
}

# Check whether a system package is installed
_pkg_is_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)    dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' ;;
        dnf)    rpm -q "$pkg" &>/dev/null ;;
        yum)    rpm -q "$pkg" &>/dev/null ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# npm install failure detection and auto-fix
# ═══════════════════════════════════════════════════════════════════════════════
npm_log_indicates_missing_build_tools() {
    local log="$1"
    if [[ -z "$log" || ! -f "$log" ]]; then
        return 1
    fi
    grep -Eiq "(not found: make|make: command not found|cmake: command not found|CMAKE_MAKE_PROGRAM is not set|Could not find CMAKE|gyp ERR! find Python|no developer tools were found|is not able to compile a simple test program|Failed to build|It seems that \"make\" is not installed|It seems that the used \"cmake\" doesn't work properly)" "$log"
}

# Detect Arch-based distributions
is_arch_linux() {
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        case "$os_id" in
            arch|manjaro|endeavouros|arcolinux|garuda|archarm|cachyos|archcraft)
                return 0
        esac
        local os_id_like
        os_id_like="$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        if [[ "$os_id_like" == *arch* ]]; then
            return 0
        fi
    fi
    if command -v pacman &> /dev/null; then
        return 0
    fi
    return 1
}

install_build_tools_linux() {
    if command -v apt-get &> /dev/null; then
        if is_root; then
            run_quiet_step "Updating package index" apt-get update -qq
            run_quiet_step "Installing build tools" apt-get install -y -qq build-essential python3 make g++ cmake
        else
            run_quiet_step "Updating package index" sudo apt-get update -qq
            run_quiet_step "Installing build tools" sudo apt-get install -y -qq build-essential python3 make g++ cmake
        fi
        return 0
    fi
    if command -v pacman &> /dev/null || is_arch_linux; then
        if is_root; then
            run_quiet_step "Installing build tools" pacman -Sy --noconfirm base-devel python make cmake gcc
        else
            run_quiet_step "Installing build tools" sudo pacman -Sy --noconfirm base-devel python make cmake gcc
        fi
        return 0
    fi
    if command -v dnf &> /dev/null; then
        if is_root; then
            run_quiet_step "Installing build tools" dnf install -y -q gcc gcc-c++ make cmake python3
        else
            run_quiet_step "Installing build tools" sudo dnf install -y -q gcc gcc-c++ make cmake python3
        fi
        return 0
    fi
    if command -v yum &> /dev/null; then
        if is_root; then
            run_quiet_step "Installing build tools" yum install -y -q gcc gcc-c++ make cmake python3
        else
            run_quiet_step "Installing build tools" sudo yum install -y -q gcc gcc-c++ make cmake python3
        fi
        return 0
    fi
    if command -v apk &> /dev/null; then
        if is_root; then
            run_quiet_step "Installing build tools" apk add --no-cache build-base python3 cmake
        else
            run_quiet_step "Installing build tools" sudo apk add --no-cache build-base python3 cmake
        fi
        return 0
    fi
    ui_warn "Could not detect package manager for auto-installing build tools"
    return 1
}

install_build_tools_macos() {
    local ok=true
    if ! xcode-select -p >/dev/null 2>&1; then
        ui_info "Installing Xcode Command Line Tools (required for make/clang)"
        xcode-select --install >/dev/null 2>&1 || true
        if ! xcode-select -p >/dev/null 2>&1; then
            ui_warn "Xcode Command Line Tools are not ready yet"
            ui_info "Complete the installer dialog, then re-run this installer"
            ok=false
        fi
    fi
    if ! command -v cmake >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            run_quiet_step "Installing cmake" brew install cmake
        else
            ui_warn "Homebrew not available; cannot auto-install cmake"
            ok=false
        fi
    fi
    if ! command -v make >/dev/null 2>&1; then
        ui_warn "make is still unavailable"
        ok=false
    fi
    if ! command -v cmake >/dev/null 2>&1; then
        ui_warn "cmake is still unavailable"
        ok=false
    fi
    [[ "$ok" == "true" ]]
}

is_root() {
    [[ $EUID -eq 0 ]]
}

run_quiet_step() {
    local title="$1"
    shift
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] $title"
        return 0
    fi
    log_detail ""
    log_detail "[$(date '+%H:%M:%S')] \$ $*  # ${title}"
    if "$@"; then
        return 0
    fi
    ui_error "${title} failed"
    return 1
}

auto_install_build_tools_for_npm_failure() {
    local log="$1"
    if ! npm_log_indicates_missing_build_tools "$log"; then
        return 1
    fi
    ui_warn "Detected missing native build tools; attempting automatic setup"
    if [[ "$OS" == "linux" ]]; then
        install_build_tools_linux || return 1
    elif [[ "$OS" == "macos" ]]; then
        install_build_tools_macos || return 1
    else
        return 1
    fi
    ui_success "Build tools setup complete"
    return 0
}

extract_npm_error_code() {
    local log="$1"
    sed -n -E 's/^npm (ERR!|error) code[[:space:]]+([^[:space:]]+).*$/\2/p' "$log" | head -n1
}

print_npm_failure_diagnostics() {
    local spec="$1"
    local log="$2"
    local error_code=""
    ui_warn "npm install failed for ${spec}"
    error_code="$(extract_npm_error_code "$log")"
    if [[ -n "$error_code" ]]; then
        echo "  npm code: ${error_code}"
    fi
    if [[ -s "$log" ]]; then
        echo "  Last lines of log:"
        tail -n 20 "$log" | sed 's/^/    /' || true
    fi
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
ensure_prerequisites() {
    local missing=()

    for cmd in curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        ui_info "Installing prerequisites: ${missing[*]}"
        pkg_install "${missing[@]}"
    fi

    if ! command -v curl &>/dev/null; then
        ui_error "Failed to install curl. Please install it manually and retry."
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Component installation functions
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 1. Node.js (via nvm) ────────────────────────────────────────────────────

_load_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        \. "$NVM_DIR/nvm.sh"
        return 0
    fi
    return 1
}

install_node() {
    ui_stage "Node.js (via nvm)"

    _load_nvm 2>/dev/null || true

    if command -v node &>/dev/null; then
        local current_version
        current_version="$(node --version 2>/dev/null | sed 's/^v//')"
        local current_major="${current_version%%.*}"

        if [[ "$current_major" -ge "$NODE_VERSION" ]]; then
            ui_success "Node.js already installed: v${current_version} (satisfies >= v${NODE_VERSION})"
            if command -v npm &>/dev/null; then
                ui_success "npm: $(npm --version 2>/dev/null)"
            fi
            _ensure_nvm_shell_config
            return 0
        else
            ui_warn "Node.js version too old: v${current_version} (need >= v${NODE_VERSION})"
            ui_info "Upgrading Node.js via nvm..."
        fi
    else
        ui_info "Node.js not found — installing via nvm..."
    fi

    _do_install_node
}

_do_install_node() {
    ui_info "Installing nvm v${NVM_VERSION} and Node.js ${NODE_VERSION}..."

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install nvm v${NVM_VERSION}"
        ui_info "[dry-run] Would run: nvm install ${NODE_VERSION}"
        return 0
    fi

    local nvm_install_script
    nvm_install_script="$(mktemp)"
    trap "rm -f '$nvm_install_script'" RETURN

    local nvm_url="https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh"
    if ! retry_net "Download nvm install script" 3 curl -fsSL "$nvm_url" -o "$nvm_install_script"; then
        ui_error "Failed to download nvm install script from: $nvm_url"
        return 1
    fi

    if ! bash "$nvm_install_script"; then
        ui_error "nvm install script failed"
        return 1
    fi

    rm -f "$nvm_install_script"
    trap - RETURN

    if ! _load_nvm; then
        ui_error "nvm was installed but could not be loaded (NVM_DIR=$NVM_DIR)"
        return 1
    fi

    ui_success "nvm loaded: $(nvm --version 2>/dev/null)"

    ui_info "Running: nvm install ${NODE_VERSION}"
    if ! retry_net "nvm install ${NODE_VERSION}" 3 nvm install "${NODE_VERSION}"; then
        ui_error "nvm install ${NODE_VERSION} failed"
        return 1
    fi

    nvm alias default "${NODE_VERSION}" >/dev/null 2>&1 || true

    local installed_version
    installed_version="$(node --version 2>/dev/null)"
    if [[ -z "$installed_version" ]]; then
        ui_error "Node.js installation verification failed"
        return 1
    fi
    ui_success "Node.js installed: ${installed_version}"

    if command -v npm &>/dev/null; then
        ui_success "npm: $(npm --version 2>/dev/null)"
    else
        ui_warn "npm was not found after installation — check manually"
    fi

    _ensure_nvm_shell_config
}

_ensure_nvm_shell_config() {
    local init_block
    init_block='\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

    local rc_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc")
    local added=0
    for rc in "${rc_files[@]}"; do
        if [[ -f "$rc" ]] && ! grep -q 'NVM_DIR' "$rc" 2>/dev/null; then
            printf '%b\n' "$init_block" >> "$rc"
            ui_info "nvm init added to $rc"
            added=1
        fi
    done
    if [[ $added -eq 0 ]]; then
        :
    fi
}

# ─── 2. Docker ───────────────────────────────────────────────────────────────

install_docker() {
    ui_stage "Docker"

    # ── macOS: use private Colima instance ─────────────────────────────────────
    if [[ "$OS" == "macos" ]]; then
        local need_brew=0
        local need_profile=0

        if ! command -v docker &>/dev/null || ! command -v colima &>/dev/null; then
            need_brew=1
            need_profile=1
        elif ! _colima list 2>/dev/null | grep -q "${_COLIMA_PROFILE}"; then
            need_profile=1
        fi

        if [[ $need_brew -eq 1 ]]; then
            if ! _do_install_docker; then
                ui_error "Colima installation failed"
                return 1
            fi
        elif [[ $need_profile -eq 1 ]]; then
            ui_info "Starting Colima VM (profile: ${_COLIMA_PROFILE})..."
            mkdir -p "${_COLIMA_HOME}"
            _colima start "${_COLIMA_PROFILE}" \
                --vm-type vz --mount-type virtiofs --network-address \
                --activate=false --cpu 2 --memory 4 --disk 60 >/dev/null \
                || { ui_warn "colima start failed — run 'COLIMA_HOME=${_COLIMA_HOME} colima start ${_COLIMA_PROFILE}' manually"; return 1; }
            export DOCKER_HOST="unix://${_COLIMA_SOCKET}"
            ui_success "Colima is running"
        else
            ui_success "Docker and Colima already configured"
        fi

        _ensure_docker_running
        return 0
    fi

    # ── Linux: standard Docker Engine ──────────────────────────────────────────
    local need_install_docker=0
    local need_install_compose=0

    if command -v docker &>/dev/null; then
        local docker_version
        docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null | extract_semver || \
                         docker --version 2>/dev/null | extract_semver || \
                         echo "unknown")"

        if [[ "$docker_version" != "unknown" ]]; then
            ui_success "Docker already installed: v${docker_version}"
        else
            ui_warn "Docker command found but version unavailable (daemon may not be running)"
            _ensure_docker_running
        fi
    else
        need_install_docker=1
    fi

    if docker compose version &>/dev/null 2>&1; then
        :
    elif command -v docker-compose &>/dev/null; then
        :
    else
        need_install_compose=1
    fi

    if [[ $need_install_docker -eq 0 && $need_install_compose -eq 0 ]]; then
        _ensure_docker_running
        _ensure_docker_group
        return 0
    fi

    if [[ $need_install_docker -eq 1 ]]; then
        ui_info "Docker not found — installing..."
        if ! _do_install_docker; then
            ui_warn "Official Docker install script failed — trying system package manager fallback..."
            if ! _do_install_docker_apt_fallback; then
                ui_error "All Docker installation methods failed — skipping group setup"
                return 1
            fi
        fi
        need_install_compose=0
    fi

    if [[ $need_install_compose -eq 1 ]]; then
        if ! docker compose version &>/dev/null 2>&1; then
            ui_info "Docker Compose V2 not detected — installing plugin..."
            if ! _do_install_compose_plugin; then
                ui_warn "Docker Compose V2 plugin installation failed — Compose features may be unavailable"
            fi
        fi
    fi

    _ensure_docker_running
    _ensure_docker_group
}

_do_install_docker() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install Docker via get.docker.com"
        return 0
    fi

    if [[ "$OS" == "macos" ]]; then
        ui_info "Installing docker and colima via Homebrew..."
        if ! command -v brew &>/dev/null; then
            ui_warn "Homebrew not found. Install it from https://brew.sh then re-run this script."
            return 1
        fi
        brew install -q docker colima || { ui_warn "brew install failed"; return 1; }
        ui_success "docker and colima installed"

        mkdir -p "${_COLIMA_HOME}"
        ui_info "Starting Colima VM (profile: ${_COLIMA_PROFILE})..."
        _colima start "${_COLIMA_PROFILE}" \
            --vm-type vz --mount-type virtiofs --network-address \
            --activate=false --cpu 2 --memory 4 --disk 60 >/dev/null \
            || { ui_warn "colima start failed — run 'COLIMA_HOME=${_COLIMA_HOME} colima start ${_COLIMA_PROFILE}' manually"; return 1; }
        ui_success "Colima is running"
        export DOCKER_HOST="unix://${_COLIMA_SOCKET}"
        return 0
    fi

    # Step 1: download
    local docker_script
    docker_script="$(mktemp)"
    mv "$docker_script" "${docker_script}.sh"
    docker_script="${docker_script}.sh"
    ui_info "Downloading Docker install script from https://get.docker.com ..."
    if ! retry_net "Download Docker install script" 3 curl -fsSL https://get.docker.com -o "$docker_script"; then
        ui_error "Failed to download Docker install script"
        rm -f "$docker_script"
        return 1
    fi

    # Step 2: preview (first 5 lines so the user can see what will run)
    ui_info "Install script preview (first 5 lines):"
    head -n 5 "$docker_script" | sed 's/^/    /' || true

    # Step 3: run with sudo sh (as recommended by get.docker.com)
    ui_info "Running: sudo sh install-docker.sh ..."
    if ! ${SUDO} sh "$docker_script"; then
        ui_error "Docker install script failed"
        rm -f "$docker_script"
        return 1
    fi
    rm -f "$docker_script"

    # ── Post-install steps ────────────────────────────────────────────────────
    # Always add REAL_USER (the non-root user who invoked sudo), not whoami which
    # may return "root" when running via "sudo bash install.sh".
    local user="${REAL_USER:-$(whoami)}"

    # 1. sudo usermod -aG docker $REAL_USER
    ui_info "Running: sudo usermod -aG docker ${user}"
    if ${SUDO} usermod -aG docker "${user}"; then
        ui_success "User ${user} added to docker group"
        DOCKER_GROUP_JUST_ADDED=1
    else
        ui_warn "usermod failed — run manually: sudo usermod -aG docker ${user}"
    fi

    # 2. sudo systemctl start docker
    ui_info "Running: sudo systemctl start docker"
    ${SUDO} systemctl start docker 2>/dev/null || \
        ${SUDO} service docker start 2>/dev/null || true

    _ensure_docker_running

    # 3. newgrp docker  (in a script 'sg docker -c' is the non-interactive equivalent)
    #    Activates group membership without requiring re-login
    ui_info "Activating docker group (newgrp docker equivalent via 'sg docker') ..."
    if command -v sg &>/dev/null && sg docker -c "docker info" &>/dev/null 2>&1; then
        DOCKER_CMD_PREFIX="sg docker -c"
        ui_success "docker group activated for this session"
    else
        DOCKER_USE_SUDO=1
        ui_info "sg docker unavailable — using sudo docker for this session"
    fi

    # 4. docker ps
    ui_info "Running: docker ps"
    local docker_ps_out
    if [[ -n "${DOCKER_CMD_PREFIX:-}" ]]; then
        docker_ps_out="$(${DOCKER_CMD_PREFIX} "docker ps" 2>&1)" && {
            ui_success "docker ps succeeded:"
            echo "$docker_ps_out" | sed 's/^/    /'
        } || ui_warn "docker ps returned non-zero (daemon may still be warming up)"
    elif ${SUDO} docker ps &>/dev/null 2>&1; then
        docker_ps_out="$(${SUDO} docker ps 2>&1)"
        ui_success "docker ps succeeded (via sudo):"
        echo "$docker_ps_out" | sed 's/^/    /'
    else
        ui_warn "docker ps failed — run 'sudo docker ps' to check daemon status"
    fi

    if ! command -v docker &>/dev/null; then
        ui_error "Docker installation verification failed"
        return 1
    fi

    local installed_version
    installed_version="$(docker --version 2>/dev/null | extract_semver || echo "unknown")"
    ui_success "Docker installed: v${installed_version}"
}

# Fallback Docker installer that uses the system package manager (apt/dnf/yum).
# Called when the get.docker.com script fails (network issues, GPG errors, etc.).
_do_install_docker_apt_fallback() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install Docker via system package manager (apt/dnf/yum)"
        return 0
    fi

    if [[ "$OS" == "macos" ]]; then
        ui_warn "No apt/dnf fallback available on macOS — install via Homebrew: brew install docker colima"
        return 1
    fi

    case "${PKG_MANAGER:-apt}" in
        apt)
            ui_info "Attempting: apt-get install docker.io ..."
            ${SUDO} apt-get update -qq 2>/dev/null || true
            if ${SUDO} apt-get install -y docker.io docker-compose; then
                ui_success "Docker installed via apt (docker.io)"
                # Ensure service is started
                ${SUDO} systemctl start docker 2>/dev/null || \
                    ${SUDO} service docker start 2>/dev/null || true
                _ensure_docker_running
                return 0
            fi
            ui_error "apt-get install docker.io failed"
            return 1
            ;;
        dnf|yum)
            ui_info "Attempting: ${PKG_MANAGER} install docker ..."
            if ${SUDO} "${PKG_MANAGER}" install -y docker; then
                ui_success "Docker installed via ${PKG_MANAGER}"
                ${SUDO} systemctl start docker 2>/dev/null || true
                _ensure_docker_running
                return 0
            fi
            ui_error "${PKG_MANAGER} install docker failed"
            return 1
            ;;
        *)
            ui_error "No fallback Docker install method for package manager: ${PKG_MANAGER:-unknown}"
            return 1
            ;;
    esac
}

_do_install_compose_plugin() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install docker-compose-plugin"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)     pkg_install docker-compose-plugin ;;
        dnf|yum) pkg_install docker-compose-plugin ;;
    esac

    if docker compose version &>/dev/null 2>&1; then
        ui_success "Docker Compose V2 installed: $(docker compose version --short 2>/dev/null)"
    else
        ui_warn "Docker Compose V2 plugin installed but not yet active — please check manually"
    fi
}

_ensure_docker_running() {
    if [[ "$DRY_RUN" == "1" ]]; then
        return 0
    fi

    if [[ "$OS" == "macos" ]]; then
        export DOCKER_HOST="unix://${_COLIMA_SOCKET}"
        if ! docker info &>/dev/null 2>&1; then
            ui_info "Starting Colima VM..."
            mkdir -p "${_COLIMA_HOME}"
            if ! _colima start "${_COLIMA_PROFILE}" \
                --vm-type vz --mount-type virtiofs --network-address \
                --activate=false --cpu 2 --memory 4 --disk 60 >/dev/null; then
                ui_warn "colima start failed"
                ui_info "Run manually: COLIMA_HOME=${_COLIMA_HOME} colima start ${_COLIMA_PROFILE}"
                return 1
            fi
        fi
        local waited=0
        local timeout=120
        while ! docker info &>/dev/null 2>&1; do
            if [[ $waited -ge $timeout ]]; then
                ui_warn "Docker daemon did not become ready within ${timeout} seconds"
                ui_info "Run: COLIMA_HOME=${_COLIMA_HOME} colima status ${_COLIMA_PROFILE}"
                return 1
            fi
            sleep 2
            (( waited += 2 )) || true
        done
        ui_success "Docker daemon is ready"
        return 0
    fi

    if command -v systemctl &>/dev/null; then
        # Reset any failed state left by previous install attempts
        ${SUDO} systemctl reset-failed docker.socket docker.service 2>/dev/null || true

        # Start socket-activated unit first (prevents "dependency failed" errors)
        if ! systemctl is-active --quiet docker.socket 2>/dev/null; then
            ui_info "Starting Docker socket..."
            run_sudo systemctl start docker.socket 2>/dev/null || true
            sleep 1
        fi

        if ! systemctl is-active --quiet docker 2>/dev/null; then
            ui_info "Starting Docker service..."
            if ! ${SUDO} systemctl start docker; then
                ui_error "Failed to start Docker service — check: sudo journalctl -xe"
            else
                ui_success "Docker service started"
            fi
        fi
        if ! systemctl is-enabled --quiet docker 2>/dev/null; then
            ui_info "Enabling Docker on startup..."
            ${SUDO} systemctl enable docker 2>/dev/null || true
        fi
        if ! systemctl is-enabled --quiet docker.socket 2>/dev/null; then
            ${SUDO} systemctl enable docker.socket 2>/dev/null || true
        fi

        # Wait up to 15s for Docker daemon to be ready to accept connections
        local waited=0
        while ! ${SUDO} docker info &>/dev/null 2>&1; do
            if [[ $waited -ge 15 ]]; then
                ui_warn "Docker daemon did not become ready within 15 seconds"
                break
            fi
            sleep 1
            (( waited++ )) || true
        done
        [[ $waited -lt 15 ]] && ui_success "Docker daemon is ready"
    else
        if ! ${SUDO} service docker status &>/dev/null; then
            ui_info "Starting Docker service..."
            run_sudo service docker start || true
        fi
    fi
}

_ensure_docker_group() {
    if [[ "$DRY_RUN" == "1" || $EUID -eq 0 || "$OS" == "macos" ]]; then
        return 0
    fi

    # Always operate on the real (non-root) user — not whoami, which may return
    # "root" when the script was launched with "sudo bash install.sh".
    local user="${REAL_USER:-$(id -un)}"

    # Ensure docker group exists (may be missing when Docker was installed differently)
    if ! getent group docker &>/dev/null 2>&1; then
        ui_info "Creating docker group..."
        run_sudo groupadd docker 2>/dev/null || true
    fi

    # Use getent to check group membership rather than the shell-builtin `groups`
    # command, which reflects the login-session groups and may not include groups
    # added earlier in the same install run (especially under sudo).
    if ! getent group docker 2>/dev/null | grep -qw "${user}"; then
        ui_info "Adding ${user} to the docker group..."
        if ${SUDO} usermod -aG docker "${user}"; then
            ui_success "User ${user} added to docker group"
        else
            ui_warn "Failed to add ${user} to docker group — run manually: sudo usermod -aG docker ${user}"
        fi
        DOCKER_GROUP_JUST_ADDED=1
    else
        ui_info "User ${user} is already in the docker group"
    fi

    # Check if docker is already accessible directly
    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    # Try activating the docker group for the current session via "sg docker"
    # This avoids requiring the user to log out and back in within the same install run
    if command -v sg &>/dev/null 2>/dev/null && sg docker -c "docker info" &>/dev/null 2>&1; then
        DOCKER_CMD_PREFIX="sg docker -c"
        ui_success "Docker group activated for this session (via 'sg docker')"
        ui_info "Future terminals will have Docker access automatically"
        return 0
    fi

    # sg docker failed or unavailable — try ACL grant on the docker socket
    # (requires the 'acl' package; harmless if absent)
    if command -v setfacl &>/dev/null 2>&1 && [[ -S /var/run/docker.sock ]]; then
        ui_info "Trying ACL grant on /var/run/docker.sock for ${user} ..."
        if ${SUDO} setfacl -m "user:${user}:rw" /var/run/docker.sock 2>/dev/null; then
            if docker info &>/dev/null 2>&1; then
                ui_success "Docker access granted via socket ACL (current session)"
                ui_info "Future terminals will have Docker access automatically (group membership active on next login)"
                return 0
            fi
        fi
    fi

    # Last resort — fall back to sudo docker for this session
    # This ensures OpenClaw image pull can proceed without requiring re-login
    DOCKER_USE_SUDO=1
    if [[ "${DOCKER_GROUP_JUST_ADDED:-0}" == "1" ]]; then
        ui_warn "Docker group assigned but not yet active in this shell session."
        ui_warn "Please log out and log back in (or run: newgrp docker) for group membership to take effect."
    fi
    ui_info "Using 'sudo docker' for this session; future terminals will have direct access."
}

# Run a docker command, with automatic fallback priority:
#   1. "sg docker -c"  — group activated in-session (DOCKER_CMD_PREFIX set)
#   2. sudo docker     — sudo fallback when group not yet active (DOCKER_USE_SUDO=1)
#   3. docker          — direct access (group already active or running as root)
#
# Usage:  docker_exec info
#         docker_exec pull image:tag
#         docker_exec image inspect tag
docker_exec() {
    if [[ -n "${DOCKER_CMD_PREFIX:-}" ]]; then
        # sg docker -c expects a single string argument
        ${DOCKER_CMD_PREFIX} "docker $*"
    elif [[ "${DOCKER_USE_SUDO:-0}" == "1" ]]; then
        ${SUDO} docker "$@"
    else
        docker "$@"
    fi
}

# Private Colima wrapper — runs colima with COLIMA_HOME scoped to JishuShell's
# data directory so the VM, socket, and all state are fully isolated from any
# user-level Docker Desktop or default Colima installation.
#
# Usage:  _colima start jishushell --vm-type vz ...
#         _colima stop jishushell
#         _colima status jishushell
_COLIMA_HOME="${JISHUSHELL_HOME}/colima"
_COLIMA_PROFILE="jishushell"
_COLIMA_SOCKET="${_COLIMA_HOME}/${_COLIMA_PROFILE}/docker.sock"

_colima() {
    COLIMA_HOME="${_COLIMA_HOME}" command colima "$@"
}

# ─── 3. Nomad ────────────────────────────────────────────────────────────────

install_nomad() {
    ui_stage "Nomad"

    local local_bin="${JISHUSHELL_BIN_DIR}/nomad"

    # ── 1. Check local user-space install ────────────────────────────────────
    if [[ -e "$local_bin" ]]; then
        if [[ ! -f "$local_bin" ]]; then
            ui_warn "Path ${local_bin} exists but is not a regular file — removing..."
            rm -rf "$local_bin" 2>/dev/null || true
        elif [[ ! -x "$local_bin" ]]; then
            ui_warn "Nomad found at ${local_bin} but is not executable — fixing permissions..."
            if ! chmod 755 "$local_bin" 2>/dev/null; then
                ui_warn "Could not fix permissions — removing and reinstalling"
                rm -f "$local_bin"
            fi
        fi

        if [[ -x "$local_bin" ]]; then
            local current_version
            current_version="$("$local_bin" version 2>/dev/null | head -n1 | extract_semver || echo "")"

            if [[ -z "$current_version" ]]; then
                ui_warn "Nomad at ${local_bin} is not functional (wrong arch or corrupt) — reinstalling..."
                rm -f "$local_bin"
            elif [[ "$current_version" == "$NOMAD_VERSION" ]]; then
                ui_success "Nomad already at target version: v${current_version} → ${local_bin}"
                _ensure_jishushell_bin_in_path
                return 0
            elif version_gte "$current_version" "$NOMAD_VERSION"; then
                # current > target (the == case was handled above). JishuShell
                # pins Nomad to a specific version on purpose (license downgrade
                # from BSL 1.1 to MPL 2.0). Raft state is not backward compatible
                # across the jump, so we auto-migrate: download + verify the new
                # binary first (safe-first), then stop services, back up the old
                # data_dir, wipe it, clean orphaned containers, and swap the
                # binary. JishuShell re-bootstraps ACL and resubmits jobs from
                # on-disk instance configs on the next start.
                _migrate_nomad_to_target "$current_version" || return 1
                _ensure_jishushell_bin_in_path
                return 0
            else
                ui_warn "Nomad version too old: v${current_version} (need v${NOMAD_VERSION}) — upgrading..."
                rm -f "$local_bin"
            fi
        fi
    fi

    # ── 2. Check system nomad (informational only) ────────────────────────────
    if [[ ! -e "$local_bin" ]] && command -v nomad &>/dev/null; then
        local sys_ver
        sys_ver="$(nomad version 2>/dev/null | head -n1 | extract_semver || echo "?")"
        ui_info "System Nomad found (v${sys_ver}) — installing local copy to ${local_bin} for JishuShell..."
    else
        ui_info "Installing Nomad v${NOMAD_VERSION} to ${local_bin}..."
    fi

    _do_install_nomad
}

_do_install_nomad() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install Nomad v${NOMAD_VERSION} to ${JISHUSHELL_BIN_DIR}/nomad"
        ui_info "[dry-run] Would add ${JISHUSHELL_BIN_DIR} to PATH in shell configs"
        return 0
    fi

    # Install directly to ~/.jishushell/bin — no sudo required
    _install_nomad_binary
}

_install_nomad_via_repo() {
    case "$PKG_MANAGER" in
        apt)
            if ! pkg_install gpg; then
                return 1
            fi

            local keyring="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
            if [[ ! -f "$keyring" ]]; then
                ui_info "Adding HashiCorp GPG key..."
                if ! retry_net "Download HashiCorp GPG key" 3 bash -c "curl -fsSL https://apt.releases.hashicorp.com/gpg | ${SUDO} gpg --dearmor -o '$keyring' 2>/dev/null"; then
                    return 1
                fi
            fi

            local sources_file="/etc/apt/sources.list.d/hashicorp.list"
            if [[ ! -f "$sources_file" ]]; then
                ui_info "Adding HashiCorp APT repository..."
                echo "deb [signed-by=${keyring}] https://apt.releases.hashicorp.com $(lsb_release -cs 2>/dev/null || echo stable) main" | \
                    ${SUDO} tee "$sources_file" >/dev/null
            fi

            wait_for_apt_lock
            run_sudo apt-get update
            run_sudo apt-get install -y nomad
            ;;
        dnf|yum)
            local repo_file="/etc/yum.repos.d/hashicorp.repo"
            if [[ ! -f "$repo_file" ]]; then
                ui_info "Adding HashiCorp YUM repository..."
                ${SUDO} tee "$repo_file" >/dev/null <<'REPO'
[hashicorp]
name=HashiCorp Stable - $basearch
baseurl=https://rpm.releases.hashicorp.com/RHEL/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
REPO
            fi

            run_sudo "$PKG_MANAGER" install -y nomad
            ;;
        *)
            return 1
            ;;
    esac

    if command -v nomad &>/dev/null; then
        local ver
        ver="$(nomad version 2>/dev/null | head -n1 | extract_semver || echo "unknown")"
        ui_success "Nomad installed (via system package): v${ver}"
        return 0
    fi

    return 1
}

# Auto-migrate from a higher Nomad version (e.g. 1.11.3 BSL) back to the
# jishushell target (1.6.5 MPL). Called when install_nomad detects a local
# binary whose semver is > NOMAD_VERSION. The migration is destructive to
# Nomad's raft state (schema is not backward compatible) but preserves
# instance configs under ~/.jishushell/instances/*, which is what jishushell
# uses to resubmit jobs after reboot. A single tar.gz snapshot of the old
# data_dir is kept under ~/.jishushell/nomad/backups/ for forensic inspection
# — it is not a user-recovery mechanism (the schema can't be replayed).
_migrate_nomad_to_target() {
    local current_version="$1"
    local local_bin="${JISHUSHELL_BIN_DIR}/nomad"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would migrate Nomad v${current_version} → v${NOMAD_VERSION}:"
        ui_info "[dry-run]   1. Stage + verify new binary in /tmp"
        ui_info "[dry-run]   2. Stop jishushell + nomad services"
        ui_info "[dry-run]   3. Tar backup ${JISHUSHELL_HOME}/nomad/data → nomad/backups/data-<ts>.tar.gz"
        ui_info "[dry-run]   4. Wipe raft state + nomad.env files (schema incompatible)"
        ui_info "[dry-run]   5. Remove orphaned gateway-<alloc> containers"
        ui_info "[dry-run]   6. Swap binary into ${local_bin}"
        return 0
    fi

    ui_warn "Nomad v${current_version} > target v${NOMAD_VERSION} — auto-migrating (BSL → MPL)..."
    ui_info "  Raft state is not backward-compatible; allocation history will be reset."
    ui_info "  Instance configs under ${JISHUSHELL_HOME}/instances/ are preserved."

    # ── Stage 1: download + verify new binary before touching anything ────
    local stage_dir
    stage_dir="$(mktemp -d)" || { ui_error "mktemp failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$stage_dir'" RETURN

    local platform
    platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
    local download_url="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_${platform}_${ARCH}.zip"
    local sums_url="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS"

    ui_info "Staging Nomad v${NOMAD_VERSION} (${platform}/${ARCH})..."
    if ! retry_net "Download Nomad binary" 3 curl -fsSL "$download_url" -o "${stage_dir}/nomad.zip"; then
        ui_error "Failed to download Nomad v${NOMAD_VERSION} — keeping existing v${current_version}"
        return 1
    fi
    if ! retry_net "Download Nomad checksums" 3 curl -fsSL "$sums_url" -o "${stage_dir}/SHA256SUMS"; then
        ui_error "Failed to download Nomad checksum file — aborting migration for security"
        return 1
    fi

    local expected_hash actual_hash
    expected_hash="$(grep "nomad_${NOMAD_VERSION}_${platform}_${ARCH}.zip" "${stage_dir}/SHA256SUMS" | awk '{print $1}')"
    if [[ -z "$expected_hash" ]]; then
        ui_error "No checksum entry for nomad_${NOMAD_VERSION}_${platform}_${ARCH}.zip — aborting"
        return 1
    fi
    if command -v sha256sum &>/dev/null; then
        actual_hash="$(sha256sum "${stage_dir}/nomad.zip" | awk '{print $1}')"
    else
        actual_hash="$(shasum -a 256 "${stage_dir}/nomad.zip" | awk '{print $1}')"
    fi
    if [[ "$expected_hash" != "$actual_hash" ]]; then
        ui_error "Nomad checksum mismatch — download may have been tampered with!"
        ui_error "  Expected: $expected_hash"
        ui_error "  Got:      $actual_hash"
        return 1
    fi
    ui_info "Checksum verified ✓"

    if ! command -v unzip &>/dev/null; then
        ui_info "Installing unzip..."
        pkg_install unzip >/dev/null 2>&1
    fi
    if ! unzip -o "${stage_dir}/nomad.zip" nomad -d "${stage_dir}" >/dev/null 2>&1; then
        if ! unzip -o "${stage_dir}/nomad.zip" -d "${stage_dir}" >/dev/null 2>&1; then
            ui_error "Failed to extract staged Nomad archive"
            return 1
        fi
    fi
    chmod 755 "${stage_dir}/nomad" 2>/dev/null

    local staged_version
    staged_version="$("${stage_dir}/nomad" version 2>/dev/null | head -n1 | extract_semver || echo "")"
    if [[ "$staged_version" != "$NOMAD_VERSION" ]]; then
        ui_error "Staged binary reports v${staged_version:-unknown}, expected v${NOMAD_VERSION} — aborting"
        return 1
    fi
    ui_success "Staged new Nomad binary v${staged_version}"

    # ── Stage 2: destructive state changes begin ──────────────────────────
    ui_info "Stopping services..."
    ${SUDO} systemctl stop jishushell 2>/dev/null || true
    ${SUDO} systemctl stop nomad 2>/dev/null || true
    # pkill -f 'nomad agent' matches its own cmdline ("pkill -f nomad agent"
    # literally contains the pattern) and self-terminates before reaching the
    # real nomad process. Use pgrep -x nomad instead (exact proc-name match,
    # pgrep's own comm is "pgrep" not "nomad").
    local nomad_pids
    nomad_pids="$(pgrep -x nomad 2>/dev/null | tr '\n' ' ')"
    if [[ -n "$nomad_pids" ]]; then
        # shellcheck disable=SC2086
        ${SUDO} kill -TERM $nomad_pids 2>/dev/null || kill -TERM $nomad_pids 2>/dev/null || true
        sleep 2
        nomad_pids="$(pgrep -x nomad 2>/dev/null | tr '\n' ' ')"
        if [[ -n "$nomad_pids" ]]; then
            # shellcheck disable=SC2086
            ${SUDO} kill -KILL $nomad_pids 2>/dev/null || kill -KILL $nomad_pids 2>/dev/null || true
        fi
    fi

    # ── Stage 3: tar backup (single snapshot, overwrite any previous) ─────
    local backup_file=""
    local backup_dir="${JISHUSHELL_HOME}/nomad/backups"
    if [[ -d "${JISHUSHELL_HOME}/nomad/data" ]]; then
        mkdir -p "$backup_dir"
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        backup_file="${backup_dir}/data-${ts}.tar.gz"
        ui_info "Backing up raft state → ${backup_file}"
        if ! tar czf "$backup_file" -C "${JISHUSHELL_HOME}/nomad" data 2>/dev/null; then
            ui_warn "Backup tar failed — continuing (raft state will still be wiped)"
            backup_file=""
        else
            # Keep only the most recent snapshot to avoid unbounded disk growth
            ls -t "${backup_dir}"/data-*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -f
        fi
    fi

    # ── Stage 4: wipe raft state + env files ─────────────────────────────
    ${SUDO} rm -rf "${JISHUSHELL_HOME}/nomad/data"
    rm -f "${JISHUSHELL_HOME}/nomad.env"
    ${SUDO} rm -f /etc/jishushell/nomad.env

    # ── Stage 5: orphaned gateway containers (alloc ids gone with raft) ──
    # sudo npm install -g runs postinstall as the invoking user (typically pi),
    # whose login shell may not have docker group access — the legacy install
    # only granted docker to the nomad.service via SupplementaryGroups, not to
    # the login shell. Try unprivileged first, fall back to sudo docker so this
    # step works regardless of group membership.
    if command -v docker &>/dev/null; then
        local _docker="docker"
        if ! docker ps >/dev/null 2>&1; then
            _docker="${SUDO} docker"
        fi
        local gw_containers
        gw_containers="$($_docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^gateway-' || true)"
        if [[ -n "$gw_containers" ]]; then
            local gw_count
            gw_count="$(echo "$gw_containers" | wc -l)"
            echo "$gw_containers" | xargs -r $_docker rm -f >/dev/null 2>&1 || true
            ui_info "Removed ${gw_count} orphaned gateway container(s)"
        fi
    fi

    # ── Stage 6: swap binary into place (atomic via temp name + rename) ──
    mkdir -p "${JISHUSHELL_BIN_DIR}"
    local dest_tmp="${local_bin}.tmp.$$"
    if ! cp "${stage_dir}/nomad" "$dest_tmp"; then
        ui_error "Failed to copy new Nomad binary into place"
        [[ -n "$backup_file" ]] && ui_error "  Backup preserved at: ${backup_file}"
        return 1
    fi
    chmod 755 "$dest_tmp"
    if ! mv -f "$dest_tmp" "$local_bin"; then
        ui_error "Failed to swap Nomad binary"
        [[ -n "$backup_file" ]] && ui_error "  Backup preserved at: ${backup_file}"
        rm -f "$dest_tmp"
        return 1
    fi

    ui_success "Nomad migrated to v${NOMAD_VERSION}"
    [[ -n "$backup_file" ]] && ui_info "  Backup (forensic, not self-recovery): ${backup_file}"
    ui_info "  JishuShell will re-bootstrap ACL and resubmit jobs from instance configs on next start."
    return 0
}

_install_nomad_binary() {
    local dest="${JISHUSHELL_BIN_DIR}/nomad"

    # Ensure destination directory exists (no sudo needed — it's in $HOME)
    if ! mkdir -p "${JISHUSHELL_BIN_DIR}"; then
        ui_error "Failed to create directory: ${JISHUSHELL_BIN_DIR}"
        return 1
    fi

    # Remove stale/non-executable leftover
    if [[ -e "$dest" && ! -x "$dest" ]]; then
        ui_warn "Removing non-executable Nomad binary at ${dest}"
        rm -f "$dest" 2>/dev/null || true
    fi

    local platform
    platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
    local download_url="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_${platform}_${ARCH}.zip"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    ui_info "Downloading Nomad v${NOMAD_VERSION} (${platform}/${ARCH})..."

    if ! retry_net "Download Nomad binary" 3 curl -fsSL "$download_url" -o "${tmp_dir}/nomad.zip"; then
        ui_error "Failed to download Nomad: $download_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    local checksums_url="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS"
    if retry_net "Download Nomad checksums" 3 curl -fsSL "$checksums_url" -o "${tmp_dir}/SHA256SUMS" 2>/dev/null; then
        local expected_hash
        expected_hash="$(grep "nomad_${NOMAD_VERSION}_${platform}_${ARCH}.zip" "${tmp_dir}/SHA256SUMS" | awk '{print $1}')"
        if [[ -n "$expected_hash" ]]; then
            local actual_hash
            if command -v sha256sum &>/dev/null; then
                actual_hash="$(sha256sum "${tmp_dir}/nomad.zip" | awk '{print $1}')"
            else
                actual_hash="$(shasum -a 256 "${tmp_dir}/nomad.zip" | awk '{print $1}')"
            fi
            if [[ "$expected_hash" != "$actual_hash" ]]; then
                ui_error "Nomad checksum mismatch — download may have been tampered with!"
                ui_error "  Expected: $expected_hash"
                ui_error "  Got:      $actual_hash"
                rm -rf "$tmp_dir"
                return 1
            fi
            ui_info "Checksum verified ✓"
        fi
    else
        ui_error "Could not download Nomad checksum file — aborting installation for security"
        ui_error "If this is a network issue, retry. To skip verification (not recommended), use --skip-verify."
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! command -v unzip &>/dev/null; then
        ui_info "Installing unzip..."
        pkg_install unzip
    fi

    if ! unzip -o "${tmp_dir}/nomad.zip" nomad -d "${tmp_dir}" >/dev/null 2>&1; then
        # Fallback: extract all (some zips don't support file-specific extraction)
        if ! unzip -o "${tmp_dir}/nomad.zip" -d "${tmp_dir}" >/dev/null 2>&1; then
            ui_error "Failed to extract Nomad archive"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    if [[ ! -f "${tmp_dir}/nomad" ]]; then
        ui_error "Nomad binary not found in downloaded archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Atomic install: write to temp name then rename to avoid partial reads during install
    local dest_tmp="${dest}.tmp.$$"
    if ! cp "${tmp_dir}/nomad" "$dest_tmp"; then
        ui_error "Failed to copy Nomad binary to ${JISHUSHELL_BIN_DIR}"
        rm -rf "$tmp_dir" "$dest_tmp" 2>/dev/null || true
        return 1
    fi
    chmod 755 "$dest_tmp"
    if ! mv -f "$dest_tmp" "$dest"; then
        ui_error "Failed to move Nomad binary to ${dest}"
        rm -f "$dest_tmp" 2>/dev/null || true
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    # Verify the installed binary is executable and actually runs
    if [[ ! -x "$dest" ]]; then
        ui_error "Nomad binary at ${dest} is not executable after install"
        return 1
    fi

    local installed_version
    installed_version="$("$dest" version 2>/dev/null | head -n1 | extract_semver || echo "")"
    if [[ -z "$installed_version" ]]; then
        ui_error "Nomad binary at ${dest} does not run — possibly wrong architecture (${ARCH})"
        rm -f "$dest" 2>/dev/null || true
        return 1
    fi

    _ensure_jishushell_bin_in_path
    ui_success "Nomad installed: v${installed_version} → ${dest}"
}

# Add ~/.jishushell/bin and npm global bin to PATH in shell startup files and current session
_ensure_jishushell_bin_in_path() {
    local bin_dir="${JISHUSHELL_BIN_DIR}"
    local marker="# jishushell-bin-path"

    # Also ensure npm global bin is in PATH (for `npm install -g` with custom prefix)
    local npm_bin=""
    if command -v npm &>/dev/null; then
        npm_bin="$(npm config get prefix 2>/dev/null)/bin"
    fi

    # Build PATH line: include npm global bin if it differs from jishushell bin
    local init_line="export PATH=\"${bin_dir}:\$PATH\""
    if [[ -n "$npm_bin" && "$npm_bin" != "$bin_dir" && -d "$npm_bin" ]]; then
        init_line="export PATH=\"${bin_dir}:${npm_bin}:\$PATH\""
        export PATH="${npm_bin}:${PATH}"
    fi

    # Export for the current running shell immediately
    export PATH="${bin_dir}:${PATH}"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would add PATH entries in shell startup files"
        return 0
    fi

    local rc_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc")
    local added=0
    for rc in "${rc_files[@]}"; do
        if [[ -f "$rc" ]] && ! grep -qF "$marker" "$rc" 2>/dev/null; then
            printf '\n%s\n%s\n' "$marker" "$init_line" >> "$rc"
            ui_info "Added PATH entries in ${rc}"
            added=1
        fi
    done

    if [[ $added -eq 0 ]]; then
        ui_info "JishuShell bin PATH already configured"
    fi
    ui_info "Tip: run 'source ~/.bashrc' or open a new terminal to activate PATH"
}

# Check if a TCP port is in LISTEN state (cross-platform: Linux ss, macOS lsof)
_port_is_listening() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"${port}" -sTCP:LISTEN &>/dev/null 2>&1
    else
        nc -z 127.0.0.1 "${port}" &>/dev/null 2>&1
    fi
}

# Write nomad.hcl if it does not already exist.
# Safe to call multiple times — never overwrites an existing config.
_ensure_nomad_hcl() {
    local nomad_config_dir="${JISHUSHELL_HOME}/nomad"
    local nomad_data_dir="${JISHUSHELL_HOME}/nomad/data"
    local nomad_alloc_dir="${JISHUSHELL_HOME}/nomad/data/alloc"
    local config_file="${nomad_config_dir}/nomad.hcl"

    [[ -f "$config_file" ]] && return 0

    mkdir -p "$nomad_config_dir" "$nomad_data_dir" "$nomad_alloc_dir"
    # Dirs are created by the current user — no sudo needed
    chown -R "${REAL_USER}:${REAL_GID:-${REAL_USER}}" "${JISHUSHELL_HOME}" 2>/dev/null || true

    # Loopback interface name: lo0 on macOS, lo on Linux.
    # Forces Nomad to fingerprint 127.0.0.1 as the node IP so Docker port
    # publishing binds to loopback instead of the LAN IP.  On macOS+Colima the
    # LAN IP doesn't exist inside the Lima VM, causing "cannot assign requested
    # address" when Docker tries to bind to it.
    local loopback_iface="lo"
    [[ "$OS" == "macos" ]] && loopback_iface="lo0"

    cat > "$config_file" << NOMAD_HCL
data_dir = "${nomad_data_dir}"

bind_addr = "127.0.0.1"

leave_on_terminate = false

advertise {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

server {
  enabled = true
  bootstrap_expect = 1
}

client {
  enabled = true
  servers = ["127.0.0.1:4647"]
  network_interface = "${loopback_iface}"
  alloc_dir = "${nomad_alloc_dir}"

  drain_on_shutdown {
    deadline           = "30s"
    force              = true
    ignore_system_jobs = true
  }
}

plugin "docker" {
  config {
    disable_log_collection = true
    volumes {
      enabled = true
    }
  }
}

acl {
  enabled = true
}
NOMAD_HCL
}

# Start Nomad agent (matches setup-manager.ts startNomad())
start_nomad() {
    local nomad_bin="${JISHUSHELL_BIN_DIR}/nomad"
    local nomad_config_dir="${JISHUSHELL_HOME}/nomad"
    local config_file="${nomad_config_dir}/nomad.hcl"

    # Check if already running (port 4646)
    if _port_is_listening 4646; then
        ui_success "Nomad is already running on port 4646"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would write ${config_file} and start nomad agent"
        return 0
    fi

    # On Linux with systemd: the single path for starting Nomad.
    # First kill any stale non-systemd Nomad processes that may hold the port.
    if command -v systemctl &>/dev/null && systemctl is-enabled nomad &>/dev/null 2>&1; then
        local stale_pids
        stale_pids="$(pgrep -f 'nomad agent' 2>/dev/null || true)"
        if [[ -n "$stale_pids" ]]; then
            local systemd_pid
            systemd_pid="$(systemctl show nomad --property=MainPID --value 2>/dev/null || echo "")"
            local pid
            for pid in $stale_pids; do
                if [[ "$pid" != "$systemd_pid" ]]; then
                    ui_info "Killing stale Nomad process (PID ${pid}) before systemd start..."
                    kill "$pid" 2>/dev/null || true
                fi
            done
            sleep 1
        fi

        ui_info "Starting Nomad via systemd..."
        ${SUDO} systemctl start nomad 2>/dev/null || true
        local i
        for i in $(seq 1 30); do
            sleep 1
            if _port_is_listening 4646; then
                ui_success "Nomad started (systemd)"
                return 0
            fi
        done
        ui_warn "Nomad did not start within 30s — port 4646 not listening"
        ui_info "Check: sudo journalctl -u nomad -n 30"
        return 1
    fi

    # On macOS with launchd: plist is already loaded with RunAtLoad=true, so launchd
    # started Nomad. Just wait for the port — do NOT spawn a competing nohup process.
    local plist_path="${HOME}/Library/LaunchAgents/com.jishushell.nomad.plist"
    if [[ "$OS" == "macos" ]] && [[ -f "$plist_path" ]]; then
        ui_info "Waiting for Nomad (launchd)..."
        local i
        for i in $(seq 1 30); do
            sleep 1
            if _port_is_listening 4646; then
                ui_success "Nomad started"
                return 0
            fi
        done
        ui_warn "Nomad did not start within 30s — port 4646 not listening"
        ui_info "Check log: ${JISHUSHELL_HOME}/nomad/nomad.log"
        return 1
    fi

    # Fallback: non-systemd environments (minimal containers without launchd).
    _ensure_nomad_hcl

    ui_info "Starting Nomad agent..."
    local log_path="${nomad_config_dir}/nomad.log"
    # Run as the current (non-root) user — Nomad only binds to 127.0.0.1:4646/4647/4648
    # (non-privileged ports), and all data dirs live under ~/.jishushell/, so root is not needed.
    nohup "${nomad_bin}" agent -config="${config_file}" > "${log_path}" 2>&1 &

    local i
    for i in $(seq 1 30); do
        sleep 1
        if _port_is_listening 4646; then
            ui_success "Nomad started"
            return 0
        fi
    done

    ui_warn "Nomad did not start within 30s — port 4646 not listening"
    ui_info "Check log: ${log_path}"
    return 1
}

# Install Nomad as a system service (systemd on Linux, launchd on macOS)
install_nomad_systemd() {
    local nomad_bin="${JISHUSHELL_BIN_DIR}/nomad"
    local nomad_config_dir="${JISHUSHELL_HOME}/nomad"
    local config_file="${nomad_config_dir}/nomad.hcl"

    if [[ "$OS" == "macos" ]]; then
        _install_nomad_launchd
        return $?
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install /etc/systemd/system/nomad.service"
        return 0
    fi

    _ensure_nomad_hcl

    # Nomad 1.6.5's docker driver fingerprint requires euid==0 (PR #18197 lifted
    # the root requirement only in 1.7+, which is BSL). The panel stays as the
    # installing user via a separate unit; it talks to this agent over HTTP so
    # ~/.jishushell/nomad/data/ can be root-owned without breaking anything.
    local service_content="[Unit]
Description=Nomad Agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=root
Type=simple
EnvironmentFile=-/etc/jishushell/nomad.env
ExecStart=${nomad_bin} agent -config=${config_file}
Restart=on-failure
RestartSec=3
ProtectSystem=full
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target"

    # Only update the service file if it changed (avoids unnecessary restarts)
    local svc_path="/etc/systemd/system/nomad.service"
    local need_reload=0
    if [[ ! -f "$svc_path" ]] || ! echo "$service_content" | diff -q - "$svc_path" &>/dev/null; then
        ${SUDO} mkdir -p /etc/jishushell
        echo "$service_content" > /tmp/nomad.service.$$
        ${SUDO} mv /tmp/nomad.service.$$ "$svc_path"
        need_reload=1
    fi

    # Keep the real user owning ~/.jishushell except for Nomad's own state,
    # which must be root-owned because the agent runs as root for driver fingerprinting.
    chown -R "${REAL_USER}:${REAL_GID:-${REAL_USER}}" "${JISHUSHELL_HOME}" 2>/dev/null || true
    if [[ -d "${nomad_config_dir}/data" ]]; then
        ${SUDO} chown -R root:root "${nomad_config_dir}/data" 2>/dev/null || true
    fi

    if [[ $need_reload -eq 1 ]]; then
        ${SUDO} systemctl daemon-reload
    fi

    # Enable but do NOT start here — start_nomad() handles startup + waiting.
    # This avoids double-waiting (install_nomad_systemd 15s + start_nomad 30s).
    if ! systemctl is-enabled nomad &>/dev/null 2>&1; then
        ${SUDO} systemctl enable nomad 2>/dev/null || \
            ui_warn "Could not enable nomad systemd service — Nomad may not auto-start on reboot"
    fi
}

_install_nomad_launchd() {
    local nomad_bin="${JISHUSHELL_BIN_DIR}/nomad"
    local nomad_config_dir="${JISHUSHELL_HOME}/nomad"
    local config_file="${nomad_config_dir}/nomad.hcl"
    local plist_label="com.jishushell.nomad"
    local plist_path="${HOME}/Library/LaunchAgents/${plist_label}.plist"
    local log_path="${nomad_config_dir}/nomad.log"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would install launchd agent: ${plist_path}"
        return 0
    fi

    mkdir -p "${HOME}/Library/LaunchAgents"

    # Always use JishuShell's private Colima socket — hardcoded, not runtime-detected.
    # Colima may not be running yet when the plist is written; runtime fallback would
    # pick the wrong socket (Docker Desktop or /var/run/docker.sock).
    local docker_sock="${_COLIMA_SOCKET}"

    cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${nomad_bin}</string>
        <string>agent</string>
        <string>-config=${config_file}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DOCKER_HOST</key>
        <string>unix://${docker_sock}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_path}</string>
    <key>StandardErrorPath</key>
    <string>${log_path}</string>
</dict>
</plist>
PLIST

    _ensure_nomad_hcl

    launchctl unload "$plist_path" 2>/dev/null || true
    if launchctl load -w "$plist_path" 2>/dev/null; then
        ui_success "Nomad launchd agent installed and started"
    else
        ui_warn "Could not load nomad launchd agent"
    fi
}

# ─── 4. OpenClaw (docker pull official image) ─────────────────────────────────
# For Docker mode: pull the official OpenClaw image from ghcr.io.
# For non-Docker modes (process manager / raw_exec): npm install as before.

_save_openclaw_image_to_panel() {
    local image="$1"
    local panel_file="${JISHUSHELL_HOME}/panel.json"
    node -e "
const fs = require('fs');
const p = '${panel_file}';
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(p, 'utf8')); } catch {}
cfg.openclaw_image = '${image}';
fs.mkdirSync(require('path').dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
" 2>/dev/null || true
}

_read_openclaw_image_from_panel() {
    local panel_file="${JISHUSHELL_HOME}/panel.json"
    node -e "
const fs = require('fs');
const p = '${panel_file}';
try {
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  if (typeof cfg.openclaw_image === 'string' && cfg.openclaw_image.trim()) {
    process.stdout.write(cfg.openclaw_image.trim());
  }
} catch {}
" 2>/dev/null || true
}

_pin_openclaw_image_if_needed() {
    local image="$1"
    if [[ -z "${image}" ]]; then
        return 1
    fi
    if [[ ! "${image}" =~ :(latest|slim)$ ]]; then
        printf '%s' "${image}"
        return 0
    fi

    local version=""
    version="$(docker_exec run --rm --entrypoint node "${image}" -p "require('/app/node_modules/openclaw/package.json').version" 2>/dev/null | tr -d '\r\n')"
    if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf '%s' "${image}"
        return 0
    fi

    local repo="${image%:*}"
    local pinned="${repo}:${version}"
    if docker_exec image inspect "${pinned}" &>/dev/null 2>&1; then
        printf '%s' "${pinned}"
        return 0
    fi

    if docker_exec tag "${image}" "${pinned}" &>/dev/null 2>&1; then
        docker_exec rmi "${image}" &>/dev/null 2>&1 || true
        printf '%s' "${pinned}"
        return 0
    fi

    printf '%s' "${image}"
    return 0
}

# Install OpenClaw npm package on the host (for process manager / raw_exec modes).
# Skipped when using official Docker image.
_install_openclaw_npm() {
    local pkg_dir="${JISHUSHELL_HOME}/packages/openclaw"

    local local_bin="${pkg_dir}/bin/openclaw"
    local local_pkg="${pkg_dir}/lib/node_modules/openclaw/package.json"
    local _need_install=0
    if [[ -f "$local_bin" ]]; then
        local current_ver
        current_ver="$(node -p "require('${local_pkg}').version" 2>/dev/null || echo "")"
        if [[ "${OPENCLAW_NPM_VERSION}" != "latest" && "${current_ver}" != "${OPENCLAW_NPM_VERSION}" ]]; then
            ui_info "OpenClaw installed version (v${current_ver:-unknown}) differs from requested (${OPENCLAW_NPM_VERSION}) — reinstalling..."
            _need_install=1
        else
            ui_success "OpenClaw npm package already installed: v${current_ver:-unknown}"
        fi
    else
        _need_install=1
    fi
    if [[ "$_need_install" == "1" ]]; then
        if ! command -v npm &>/dev/null; then
            ui_error "npm not found — install Node.js first"
            return 1
        fi
        ui_info "Installing OpenClaw npm package (openclaw@${OPENCLAW_NPM_VERSION})..."
        mkdir -p "$pkg_dir"
        log_detail ""
        log_detail "[$(date '+%H:%M:%S')] npm install -g --prefix ${pkg_dir} openclaw@${OPENCLAW_NPM_VERSION}"
        if ! retry_net "npm install -g --prefix openclaw@${OPENCLAW_NPM_VERSION}" 3 \
            log_cmd env -u npm_config_global -u npm_config_prefix -u npm_config_location \
                npm install -g --prefix "$pkg_dir" "openclaw@${OPENCLAW_NPM_VERSION}"; then
            ui_error "Failed to install OpenClaw npm package"
            return 1
        fi
    fi
}

install_openclaw() {
    ui_stage "OpenClaw"

    if [[ "${SKIP_OPENCLAW}" == "1" ]]; then
        ui_info "Skipped (--skip-openclaw / default)"
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        ui_error "Docker is not installed — cannot build OpenClaw image"
        return 1
    fi

    local docker_tag="${OPENCLAW_DOCKER_TAG}"
    local configured_tag=""

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would: docker pull ${docker_tag} (fallback: local build)"
        return 0
    fi

    # ── Step 1: Ensure Docker daemon is accessible ────────────────────────────
    if ! docker_exec info &>/dev/null 2>&1; then
        if command -v sg &>/dev/null 2>/dev/null && sg docker -c "docker info" &>/dev/null 2>&1; then
            DOCKER_CMD_PREFIX="sg docker -c"
            ui_info "Docker group activated via 'sg docker'"
        elif ${SUDO} docker info &>/dev/null 2>&1; then
            DOCKER_USE_SUDO=1
            ui_info "Using 'sudo docker' (docker group not yet active in this shell)"
        else
            ui_warn "Docker daemon is not reachable"
            if [[ "$OS" == "macos" ]]; then
                ui_warn "Run: COLIMA_HOME=${_COLIMA_HOME} colima start ${_COLIMA_PROFILE}"
            else
                ui_warn "Ensure Docker is running: sudo systemctl start docker"
            fi
            return 1
        fi
    fi

    # ── Step 2: Reuse the currently configured pinned image if it already
    # exists locally. This avoids re-pulling :latest on machines where the
    # running JishuShell service has already migrated panel.json from a mutable
    # tag (e.g. :latest) to an immutable version tag (e.g. :2026.4.9).
    configured_tag="$(_read_openclaw_image_from_panel)"
    if [[ -n "${configured_tag}" ]] && docker_exec image inspect "${configured_tag}" &>/dev/null 2>&1; then
        OPENCLAW_IMAGE="$(_pin_openclaw_image_if_needed "${configured_tag}")"
        _save_openclaw_image_to_panel "${OPENCLAW_IMAGE}"
        ui_success "Docker image ${OPENCLAW_IMAGE} already exists — reusing configured image"
        return 0
    fi

    # ── Step 3: Skip if the requested install tag already exists ─────────────
    if docker_exec image inspect "${docker_tag}" &>/dev/null 2>&1; then
        OPENCLAW_IMAGE="$(_pin_openclaw_image_if_needed "${docker_tag}")"
        _save_openclaw_image_to_panel "${OPENCLAW_IMAGE}"
        ui_success "Docker image ${OPENCLAW_IMAGE} already exists — skipping"
        return 0
    fi

    # ── Step 4: Pull from registry, fallback to local build ──────────────────
    ui_info "Pulling OpenClaw Docker image: ${docker_tag} ..."
    log_detail ""
    log_detail "[$(date '+%H:%M:%S')] docker pull ${docker_tag}"
    if log_cmd docker_exec pull "${docker_tag}"; then
        OPENCLAW_IMAGE="$(_pin_openclaw_image_if_needed "${docker_tag}")"
        _save_openclaw_image_to_panel "${OPENCLAW_IMAGE}"
        ui_success "OpenClaw Docker image pulled: ${OPENCLAW_IMAGE}"
        return 0
    fi

    # ── Step 3b: Fallback — build locally using bundled Dockerfile ────
    ui_warn "Pull failed, falling back to local build..."

    # Locate the bundled Dockerfile.openclaw-slim + openclaw-entry.sh.
    # Both ship at the npm package root, alongside the install/ directory,
    # so from this script's perspective they are one level up.
    local script_dir
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        script_dir="${PWD}"
    fi
    local dockerfile_src="${script_dir}/../Dockerfile.openclaw-slim"
    local entrypoint_src="${script_dir}/../openclaw-entry.sh"

    if [[ ! -f "${dockerfile_src}" || ! -f "${entrypoint_src}" ]]; then
        ui_error "Bundled build files not found near ${script_dir}/.."
        ui_error "Expected: Dockerfile.openclaw-slim and openclaw-entry.sh"
        return 1
    fi

    local build_ctx
    build_ctx="$(mktemp -d)"
    trap "rm -rf '${build_ctx}'" EXIT

    cp "${dockerfile_src}" "${build_ctx}/Dockerfile.openclaw-slim"
    cp "${entrypoint_src}" "${build_ctx}/openclaw-entry.sh"

    # Query current OpenClaw version from npm so the --build-arg busts the
    # Docker layer cache for the `RUN npm install openclaw@${ver}` step.
    # Fall back to "latest" if npm is unreachable.
    local openclaw_ver
    openclaw_ver="$(npm view openclaw version 2>/dev/null)"
    if [[ -z "${openclaw_ver}" ]]; then
        openclaw_ver="latest"
    fi
    log_detail "Resolved OpenClaw version for build: ${openclaw_ver}"

    ui_info "Building OpenClaw Docker image locally: ${docker_tag} (openclaw@${openclaw_ver}) ..."
    log_detail ""
    log_detail "[$(date '+%H:%M:%S')] docker build --network=host --build-arg OPENCLAW_VERSION=${openclaw_ver} -f Dockerfile.openclaw-slim -t ${docker_tag} ${build_ctx}"
    if log_cmd docker_exec build --network=host \
        --build-arg "OPENCLAW_VERSION=${openclaw_ver}" \
        -f "${build_ctx}/Dockerfile.openclaw-slim" \
        -t "${docker_tag}" "${build_ctx}"; then
        OPENCLAW_IMAGE="${docker_tag}"
        _save_openclaw_image_to_panel "${docker_tag}"
        rm -rf "${build_ctx}"
        trap - EXIT
        ui_success "OpenClaw Docker image built: ${docker_tag}"
    else
        rm -rf "${build_ctx}"
        trap - EXIT
        ui_error "Failed to build OpenClaw Docker image"
        return 1
    fi
}

_prompt_openclaw_skip() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        SKIP_OPENCLAW=0
        ui_info "Non-interactive shell detected — OpenClaw will be installed by default"
        return 0
    fi

    local answer
    echo ""
    echo -e "${ACCENT}${BOLD}OpenClaw${NC}"
    echo -e "${INFO}  Installs the OpenClaw npm package and builds a Docker image with Python.${NC}"
    echo -e "${INFO}  Requires Docker to be running; the build may take a few minutes.${NC}"
    echo ""
    local answer answer_lc
    read -r -p "$(echo -e "${MUTED}  Install OpenClaw and build Docker image? [Y/n]: ${NC}")" answer </dev/tty || answer="y"
    answer_lc="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer_lc" in
        n|no) SKIP_OPENCLAW=1 ;;
        *)    SKIP_OPENCLAW=0 ;;
    esac
}

jishushell_package_spec() {
    if [[ "${JISHUSHELL_VERSION_OVERRIDE}" == "1" || "${JISHUSHELL_NPM_VERSION}" != "latest" ]]; then
        printf 'jishushell@%s' "${JISHUSHELL_NPM_VERSION}"
        return 0
    fi
    printf 'jishushell'
}

# show_install_plan [--with-jishushell]
show_install_plan() {
    local with_jishushell=0
    [[ "${1:-}" == "--with-jishushell" ]] && with_jishushell=1

    echo ""
    echo -e "${ACCENT}${BOLD}Install Plan${NC}"
    echo -e "${MUTED}────────────────────────────────${NC}"
    ui_kv "OS"              "$OS_NAME"
    ui_kv "Package manager" "$PKG_MANAGER"
    ui_kv "Architecture"    "$ARCH"
    echo ""
    ui_kv "Node.js"     "$(if [[ $SKIP_NODE   -eq 1 ]]; then echo 'skip'; else echo "v${NODE_VERSION} via nvm v${NVM_VERSION}"; fi)"
    ui_kv "Docker"      "$(if [[ $SKIP_DOCKER -eq 1 ]]; then echo 'skip'; else echo 'latest stable'; fi)"
    ui_kv "Nomad"       "$(if [[ $SKIP_NOMAD  -eq 1 ]]; then echo 'skip'; else echo "v${NOMAD_VERSION}"; fi)"
    ui_kv "OpenClaw"    "$(if [[ "${SKIP_OPENCLAW}" == "1" ]]; then echo 'skip'; else echo "docker pull ${OPENCLAW_DOCKER_TAG}"; fi)"
    if [[ $with_jishushell -eq 1 ]]; then
        local _plan_jishu
        if [[ $SKIP_JISHUSHELL -eq 1 ]]; then
            _plan_jishu="skip"
        else
            local _plan_tgz=""
            if [[ "${JISHUSHELL_VERSION_OVERRIDE}" != "1" && "${JISHUSHELL_NPM_VERSION}" == "latest" ]]; then
                for _c in "${JISHU_SCRIPT_DIR}"/jishushell-*.tgz; do
                    [[ -f "$_c" ]] && { _plan_tgz="$(basename "$_c")"; break; }
                done
            fi
            _plan_jishu="${_plan_tgz:+npm install -g ${_plan_tgz} (local)}${_plan_tgz:-npm install -g $(jishushell_package_spec)}"
        fi
        ui_kv "JishuShell"         "$_plan_jishu"
        ui_kv "JishuShell service" "$(if [[ $SKIP_JISHUSHELL_SERVICE -eq 1 ]]; then echo 'skip'; else echo 'register autostart'; fi)"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo ""
        ui_warn "Dry-run mode: no changes will be made to this system"
    fi
    echo ""
}

# show_summary [--with-jishushell]
show_summary() {
    local with_jishushell=0
    [[ "${1:-}" == "--with-jishushell" ]] && with_jishushell=1

    echo ""
    echo -e "${ACCENT}${BOLD}Summary${NC}"
    echo -e "${MUTED}────────────────────────────────${NC}"

    local all_ok=1

    if [[ $SKIP_NODE -eq 0 ]]; then
        if command -v node &>/dev/null; then
            ui_kv "Node.js"  "✓ $(node --version 2>/dev/null)"
        else
            ui_kv "Node.js"  "✗ not installed"
            all_ok=0
        fi
    fi

    if [[ $SKIP_DOCKER -eq 0 ]]; then
        if command -v docker &>/dev/null; then
            local _docker_ver
            _docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null | extract_semver || docker --version 2>/dev/null | extract_semver || echo 'installed')"
            ui_kv "Docker"   "✓ v${_docker_ver}"
        else
            ui_kv "Docker"   "✗ not installed"
            all_ok=0
        fi
    fi

    if [[ $SKIP_NOMAD -eq 0 ]]; then
        local _nomad_bin="${JISHUSHELL_BIN_DIR}/nomad"
        if [[ -x "$_nomad_bin" ]]; then
            local _nomad_ver
            _nomad_ver="$("$_nomad_bin" version 2>/dev/null | head -n1 | extract_semver || echo 'installed')"
            ui_kv "Nomad"    "✓ v${_nomad_ver} (${_nomad_bin})"
        elif command -v nomad &>/dev/null; then
            local _nomad_ver
            _nomad_ver="$(nomad version 2>/dev/null | head -n1 | extract_semver || echo 'installed')"
            ui_kv "Nomad"    "✓ v${_nomad_ver} (system: $(command -v nomad))"
        else
            ui_kv "Nomad"    "✗ not installed"
            all_ok=0
        fi
    fi

    if [[ "${SKIP_OPENCLAW}" != "1" ]]; then
        local _summary_openclaw_image=""
        _summary_openclaw_image="$(_read_openclaw_image_from_panel)"
        if [[ -z "${_summary_openclaw_image}" && -n "${OPENCLAW_IMAGE}" ]]; then
            _summary_openclaw_image="${OPENCLAW_IMAGE}"
        fi

        if [[ -n "${_summary_openclaw_image}" ]] && docker_exec image inspect "${_summary_openclaw_image}" &>/dev/null 2>&1; then
            ui_kv "OpenClaw" "✓ ${_summary_openclaw_image}"
        elif [[ -n "${OPENCLAW_IMAGE}" ]] && docker_exec image inspect "${OPENCLAW_IMAGE}" &>/dev/null 2>&1; then
            ui_kv "OpenClaw" "✓ ${OPENCLAW_IMAGE}"
        elif [[ "$DRY_RUN" == "1" ]]; then
            ui_kv "OpenClaw" "- dry-run"
        else
            ui_kv "OpenClaw" "✗ image not found locally"
            all_ok=0
        fi
    fi

    if [[ $with_jishushell -eq 1 && $SKIP_JISHUSHELL -eq 0 ]]; then
        local _wrapper="${JISHUSHELL_BIN_DIR}/jishushell-panel-start"
        if [[ -x "$_wrapper" ]]; then
            ui_kv "JishuShell" "✓ ${_wrapper}"
        elif command -v jishushell &>/dev/null; then
            ui_kv "JishuShell" "✓ $(command -v jishushell)"
        else
            ui_kv "JishuShell" "✗ not found"
            all_ok=0
        fi
    fi

    echo ""
    if [[ $all_ok -eq 1 ]]; then
        echo -e "${SUCCESS}${BOLD}All components installed successfully!${NC}"
    else
        echo -e "${WARN}${BOLD}One or more components failed — review the log above.${NC}"
    fi
    # Remind the user to re-login if docker group was added and sg could not
    # activate it in-session (DOCKER_CMD_PREFIX would be set if sg succeeded).
    if [[ "${DOCKER_GROUP_JUST_ADDED:-0}" == "1" && -z "${DOCKER_CMD_PREFIX:-}" ]]; then
        echo ""
        echo -e "${WARN}${BOLD}Action required — Docker group membership:${NC}"
        echo -e "${WARN}  User '${REAL_USER:-$(id -un)}' was added to the 'docker' group, but the"
        echo -e "${WARN}  change is not active in the current shell session.${NC}"
        echo -e "${WARN}  Please log out and log back in, or run:${NC}"
        echo -e "${ACCENT}    newgrp docker${NC}"
        echo -e "${WARN}  to use Docker without sudo.${NC}"
    fi
    if [[ -n "${JISHU_LOG_FILE:-}" ]]; then
        echo ""
        ui_kv "Log file" "${JISHU_LOG_FILE}"
    fi
    echo ""
    if [[ $all_ok -eq 1 && $with_jishushell -eq 1 && $SKIP_JISHUSHELL -eq 0 ]]; then
        # Detect the primary non-loopback LAN IP address.
        # Use || true on every substitution to prevent set -e from firing when
        # the command does not exist on this OS (e.g. "ip" is Linux-only).
        local _local_ip=""
        if [[ "$(uname -s)" == "Darwin" ]]; then
            local _iface
            _iface="$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')" || true
            if [[ -n "$_iface" ]]; then
                _local_ip="$(ipconfig getifaddr "$_iface" 2>/dev/null)" || true
            fi
            if [[ -z "$_local_ip" ]]; then
                _local_ip="$(ipconfig getifaddr en0 2>/dev/null)" || true
            fi
            if [[ -z "$_local_ip" ]]; then
                _local_ip="$(ipconfig getifaddr en1 2>/dev/null)" || true
            fi
        else
            _local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')" || true
            if [[ -z "$_local_ip" ]]; then
                _local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
            fi
        fi

        echo -e "${SUCCESS}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${SUCCESS}${BOLD}  ║  Installation complete!                              ║${NC}"
        echo -e "${SUCCESS}${BOLD}  ║                                                      ║${NC}"
        echo -e "${SUCCESS}${BOLD}  ║  Open your browser and navigate to:                  ║${NC}"
        echo -e "${SUCCESS}${BOLD}  ║    http://localhost:${JISHUSHELL_PORT}/$(printf '%*s' $((32 - ${#JISHUSHELL_PORT})) '')║${NC}"
        if [[ -n "$_local_ip" ]]; then
        echo -e "${SUCCESS}${BOLD}  ║    http://${_local_ip}:${JISHUSHELL_PORT}/$(printf '%*s' $((28 - ${#_local_ip} - ${#JISHUSHELL_PORT})) '')║${NC}"
        fi
        echo -e "${SUCCESS}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Core install orchestration
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 6. JishuShell backend (npm install -g jishushell) ───────────────────────

install_jishushell() {
    ui_stage "JishuShell"

    if [[ $SKIP_JISHUSHELL -eq 1 ]]; then
        ui_info "Skipped (--skip-jishushell)"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        local jishushell_pkg_spec
        jishushell_pkg_spec="$(jishushell_package_spec)"
        local _dry_reg=""
        [[ -n "${NPM_REGISTRY:-}" ]] && _dry_reg=" --registry ${NPM_REGISTRY}"
        local _dry_tgz=""
        if [[ "${JISHUSHELL_VERSION_OVERRIDE}" != "1" && "${JISHUSHELL_NPM_VERSION}" == "latest" ]]; then
            for _c in "${JISHU_SCRIPT_DIR}"/jishushell-*.tgz; do
                [[ -f "$_c" ]] && { _dry_tgz="$_c"; break; }
            done
        fi
        if [[ -n "$_dry_tgz" ]]; then
            ui_info "[dry-run] Would: npm install -g ${_dry_tgz}  (local package)"
        else
            ui_info "[dry-run] Would: npm install -g ${jishushell_pkg_spec}${_dry_reg}"
        fi
        ui_info "[dry-run] Would write wrapper: ${JISHUSHELL_BIN_DIR}/jishushell-panel-start"
        return 0
    fi

    local node_bin
    node_bin="$(command -v node 2>/dev/null || true)"
    # When running as root via sudo, node may only be in the real user's nvm.
    if [[ -z "$node_bin" && -n "${REAL_HOME}" ]]; then
        local nvm_node_dir="${REAL_HOME}/.nvm/versions/node"
        if [[ -d "$nvm_node_dir" ]]; then
            node_bin="$(find "$nvm_node_dir" -name node -type f 2>/dev/null | sort -V | tail -1 || true)"
        fi
    fi
    if [[ -z "$node_bin" ]]; then
        ui_error "Cannot locate node — wrapper cannot be written"
        return 1
    fi

    # Locate npm sibling to the node binary (works with nvm-managed installs)
    local npm_bin
    npm_bin="$(dirname "$node_bin")/npm"
    if [[ ! -x "$npm_bin" ]]; then
        npm_bin="$(command -v npm 2>/dev/null || true)"
    fi
    if [[ -z "$npm_bin" ]]; then
        ui_error "Cannot locate npm — cannot install jishushell"
        return 1
    fi

    local jishushell_pkg_spec
    jishushell_pkg_spec="$(jishushell_package_spec)"
    local npm_registry_args=()
    if [[ -n "${NPM_REGISTRY:-}" ]]; then
        if [[ ! "$NPM_REGISTRY" =~ ^https?:// ]]; then
            ui_error "NPM_REGISTRY must be a valid URL starting with http:// or https://"
            return 1
        fi
        npm_registry_args=("--registry" "${NPM_REGISTRY}")
        ui_info "Installing ${jishushell_pkg_spec} from ${NPM_REGISTRY}..."
    else
        ui_info "Installing ${jishushell_pkg_spec} from public npm registry..."
    fi

    # When jishushell is already installed (e.g. running as npm postinstall hook),
    # skip the npm install step and only write the wrapper + service.
    if [[ "${JISHUSHELL_SKIP_NPM_INSTALL:-0}" != "1" ]]; then
        # Prefer a local .tgz package in the same directory as this script.
        local tgz_path=""
        local _tgz_candidate
        if [[ "${JISHUSHELL_VERSION_OVERRIDE}" != "1" && "${JISHUSHELL_NPM_VERSION}" == "latest" ]]; then
            for _tgz_candidate in "${JISHU_SCRIPT_DIR}"/jishushell-*.tgz; do
                if [[ -f "$_tgz_candidate" ]]; then
                    tgz_path="$_tgz_candidate"
                    break
                fi
            done
        fi

        # Export a sentinel so post-install.sh (triggered by npm's postinstall
        # lifecycle hook) knows it was launched from inside jishu-install.sh and
        # must not re-run Docker/Nomad/OpenClaw installation steps again.
        export JISHU_RUNNING_IN_INSTALLER=1

        if [[ -n "$tgz_path" ]]; then
            ui_info "Found local package: ${tgz_path} — installing offline..."
            log_detail "[$(date '+%H:%M:%S')] ${npm_bin} install -g ${tgz_path}"
            if ! log_cmd "$npm_bin" install -g "${tgz_path}"; then
                unset JISHU_RUNNING_IN_INSTALLER
                ui_error "npm install -g ${tgz_path} failed"
                return 1
            fi
        else
            log_detail "[$(date '+%H:%M:%S')] ${npm_bin} install -g ${jishushell_pkg_spec} ${npm_registry_args[*]:-}"
            if ! log_cmd "$npm_bin" install -g "${jishushell_pkg_spec}" "${npm_registry_args[@]}"; then
                unset JISHU_RUNNING_IN_INSTALLER
                ui_error "npm install -g ${jishushell_pkg_spec} failed"
                return 1
            fi
        fi
        unset JISHU_RUNNING_IN_INSTALLER
    else
        ui_info "Skipping npm install (already installed by caller)"
    fi

    # Resolve the installed cli.js path via the npm that did the install
    local npm_root
    npm_root="$("$npm_bin" root -g 2>/dev/null || true)"
    if [[ -z "$npm_root" ]]; then
        ui_error "Cannot locate npm root — wrapper cannot be written"
        return 1
    fi
    local jishushell_bin="${npm_root}/jishushell/dist/cli.js"
    ui_success "JishuShell installed ($(${node_bin} -p "require('${npm_root}/jishushell/package.json').version" 2>/dev/null || echo 'version unknown'))"
    local wrapper="${JISHUSHELL_BIN_DIR}/jishushell-panel-start"
    mkdir -p "${JISHUSHELL_BIN_DIR}"

    # The wrapper resolves node at runtime — it does NOT hardcode the path so
    # the binary stays valid if nvm is upgraded or node is reinstalled.
    cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
set -euo pipefail

_find_node() {
    command -v node 2>/dev/null && return
    local nvm_dir="\${NVM_DIR:-\${HOME}/.nvm}"
    [ -s "\$nvm_dir/nvm.sh" ] && . "\$nvm_dir/nvm.sh" --no-use 2>/dev/null || true
    command -v node 2>/dev/null && return
    local ndir="\${HOME}/.nvm/versions/node"
    [ -d "\$ndir" ] && find "\$ndir" -name node -type f 2>/dev/null | sort -V | tail -1 || true
}
NODE_BIN="\$(_find_node || true)"
if [ -z "\$NODE_BIN" ]; then
    NODE_BIN="/opt/homebrew/bin/node"
fi
if [ ! -x "\$NODE_BIN" ]; then
    echo "[jishushell-panel-start] ERROR: cannot locate node binary" >&2
    exit 1
fi

# Data directory: honour explicit env override, otherwise use the real
# user home embedded at install time (avoids /root when run as root).
JISHUSHELL_HOME="\${JISHUSHELL_HOME:-${REAL_HOME}/.jishushell}"
NOMAD_ENV="\${JISHUSHELL_HOME}/nomad.env"

[ -f "\$NOMAD_ENV" ] && source "\$NOMAD_ENV"

if [ ! -f "${jishushell_bin}" ]; then
    echo "[jishushell-panel-start] ERROR: could not find jishushell at ${jishushell_bin}" >&2
    exit 1
fi

exec "\$NODE_BIN" "${jishushell_bin}" "\$@"
WRAPPER
    chmod +x "$wrapper"
    ui_success "JishuShell installed — wrapper: ${wrapper}"
}

install_jishushell_service() {
    ui_stage "JishuShell service"

    if [[ $SKIP_JISHUSHELL_SERVICE -eq 1 ]]; then
        ui_info "Skipped (--skip-jishushell-service)"
        return 0
    fi

    local wrapper="${JISHUSHELL_BIN_DIR}/jishushell-panel-start"
    local log_path="${JISHUSHELL_HOME}/jishushell.log"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would register jishushell as a system service"
        return 0
    fi

    if [[ "$OS" == "macos" ]]; then
        local plist_label="com.jishushell.panel"
        local plist_path="${HOME}/Library/LaunchAgents/${plist_label}.plist"

        mkdir -p "${HOME}/Library/LaunchAgents"
        cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${wrapper}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_path}</string>
    <key>StandardErrorPath</key>
    <string>${log_path}</string>
</dict>
</plist>
PLIST

        launchctl unload "$plist_path" 2>/dev/null || true
        if launchctl load -w "$plist_path" 2>/dev/null; then
            ui_success "JishuShell backend service installed and started"
        else
            ui_warn "Could not load jishushell launchd agent"
        fi
        return 0
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        return 0
    fi

    local service_content="[Unit]
Description=JishuShell Backend
After=network-online.target nomad.service
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
SupplementaryGroups=docker
EnvironmentFile=-/etc/jishushell/nomad.env
ExecStart=${wrapper} serve
Restart=on-failure
RestartSec=3
Environment=HOME=${REAL_HOME}
Environment=JISHUSHELL_HOME=${JISHUSHELL_HOME}
ProtectSystem=strict
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=${JISHUSHELL_HOME} /etc/jishushell

[Install]
WantedBy=multi-user.target"

    # Only update the service file if it changed (avoids unnecessary restarts)
    local svc_path="/etc/systemd/system/jishushell.service"
    local need_reload=0
    if [[ ! -f "$svc_path" ]] || ! echo "$service_content" | diff -q - "$svc_path" &>/dev/null; then
        echo "$service_content" > /tmp/jishushell.service.$$
        ${SUDO} mv /tmp/jishushell.service.$$ "$svc_path"
        need_reload=1
    fi

    if [[ $need_reload -eq 1 ]]; then
        ${SUDO} systemctl daemon-reload
    fi

    # Enable the service (auto-start on boot).
    # Use 'enable --now' to also start it immediately — jishushell is the final
    # component so there is no double-wait concern unlike Nomad.
    if ! systemctl is-enabled jishushell &>/dev/null 2>&1; then
        if ${SUDO} systemctl enable --now jishushell 2>/dev/null; then
            ui_success "JishuShell systemd service installed and started"
        else
            ui_warn "Could not enable jishushell systemd service"
        fi
    elif [[ $need_reload -eq 1 ]]; then
        # Service file changed — restart to pick up new config
        ${SUDO} systemctl restart jishushell 2>/dev/null || true
        ui_success "JishuShell systemd service updated and restarted"
    else
        # Package may have been upgraded — always restart to pick up new code
        ${SUDO} systemctl restart jishushell 2>/dev/null || true
        ui_success "JishuShell systemd service restarted"
    fi
}

# ─── run_install_components ───────────────────────────────────────────────────
# Runs the standard install sequence.  Returns non-zero if any component fails.
run_install_components() {
    local with_jishushell=0
    [[ "${1:-}" == "--with-jishushell" ]] && with_jishushell=1

    local has_error=0

    if [[ $SKIP_NODE -eq 0 ]]; then
        if ! install_node; then
            ui_error "Node.js installation failed"
            has_error=1
        fi
    else
        ui_stage "Node.js"
        ui_info "Skipped (--skip-node)"
    fi

    local docker_ok=0
    if [[ $SKIP_DOCKER -eq 0 ]]; then
        if ! install_docker; then
            ui_error "Docker installation failed"
            has_error=1
        else
            docker_ok=1
        fi
    else
        ui_stage "Docker"
        ui_info "Skipped (--skip-docker)"
        command -v docker &>/dev/null && docker_ok=1
    fi

    if [[ $SKIP_NOMAD -eq 0 ]]; then
        if ! install_nomad; then
            ui_error "Nomad installation failed"
            has_error=1
        else
            install_nomad_systemd || true
            # Ensure Nomad is actually running (mirrors install.ts startNomad() call).
            # start_nomad() is idempotent: on Linux it defers to systemd (no competing nohup);
            # on macOS/non-systemd it starts a background process.
            # A slow start (timeout) is non-fatal — systemd will retry on next boot and
            # 'jishushell doctor --fix' can recover it.  Do not fail the entire npm install
            # just because Nomad took longer than expected to bind its port.
            if ! start_nomad; then
                ui_warn "Nomad could not be started — run 'jishushell doctor --fix' to diagnose"
            fi
        fi
    else
        ui_stage "Nomad"
        ui_info "Skipped (--skip-nomad)"
    fi

    if [[ $docker_ok -eq 1 ]]; then
        if ! install_openclaw; then
            ui_error "OpenClaw installation failed"
            has_error=1
        fi
    else
        ui_stage "OpenClaw"
        ui_warn "Skipped — Docker is not available (installation failed or not installed)"
    fi

    if [[ $with_jishushell -eq 1 ]]; then
        if [[ $SKIP_JISHUSHELL -eq 1 ]]; then
            ui_stage "JishuShell"
            ui_info "Skipped (--skip-jishushell)"
        elif ! install_jishushell; then
            ui_error "JishuShell installation failed"
            has_error=1
        fi

        if [[ $SKIP_JISHUSHELL -eq 0 && $SKIP_JISHUSHELL_SERVICE -eq 1 ]]; then
            ui_stage "JishuShell service"
            ui_info "Skipped (--skip-jishushell-service)"
        elif [[ $SKIP_JISHUSHELL -eq 0 ]]; then
            install_jishushell_service || true
        fi
    fi

    # ── Fix .jishushell ownership & permissions ───────────────────────────────
    # Ensure the data dir is readable/writable by both root and the real user.
    # - Root owns the dir (service runs as root)
    # - REAL_USER is in the owning group; dirs are g+rwx so normal-user tools work
    if [[ -d "${JISHUSHELL_HOME}" && -n "${REAL_USER}" ]]; then
        ui_info "Fixing ${JISHUSHELL_HOME} ownership for ${REAL_USER}..."
        # Both Nomad and JishuShell now run as REAL_USER — make REAL_USER own everything
        ${SUDO} chown -R "${REAL_USER}:${REAL_GID:-${REAL_USER}}" "${JISHUSHELL_HOME}" 2>/dev/null || true
        # Dirs: rwxr-xr-x
        ${SUDO} find "${JISHUSHELL_HOME}" -type d -exec chmod 755 {} + 2>/dev/null || true
        # Files: rw-r--r-- by default
        ${SUDO} find "${JISHUSHELL_HOME}" -type f -exec chmod 644 {} + 2>/dev/null || true
        # Executables in bin/ must keep the execute bit
        ${SUDO} find "${JISHUSHELL_BIN_DIR}" -type f -exec chmod 755 {} + 2>/dev/null || true
        # Sensitive files: owner-only read (600)
        for f in auth.json jwt-secret panel.json nomad.env encryption-key; do
            local fp="${JISHUSHELL_HOME}/${f}"
            [[ -f "$fp" ]] && ${SUDO} chmod 600 "$fp" 2>/dev/null || true
        done
        # Sync nomad.env from /etc/jishushell if missing in JISHUSHELL_HOME
        if [[ ! -f "${JISHUSHELL_HOME}/nomad.env" && -f /etc/jishushell/nomad.env ]]; then
            ${SUDO} cp /etc/jishushell/nomad.env "${JISHUSHELL_HOME}/nomad.env"
            ${SUDO} chown "${REAL_USER}:${REAL_GID:-${REAL_USER}}" "${JISHUSHELL_HOME}/nomad.env"
            ${SUDO} chmod 600 "${JISHUSHELL_HOME}/nomad.env"
        fi
        ui_success "Permissions set: ${REAL_USER}:${REAL_USER} on ${JISHUSHELL_HOME}"
    fi

    return $has_error
}

# ═══════════════════════════════════════════════════════════════════════════════
# Installer entry point — argument parsing, banner, main
# ═══════════════════════════════════════════════════════════════════════════════

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose)        VERBOSE=1 ;;
            --dry-run)        DRY_RUN=1 ;;
            --skip-node)      SKIP_NODE=1 ;;
            --skip-docker)    SKIP_DOCKER=1 ;;
            --skip-nomad)     SKIP_NOMAD=1 ;;
            --skip-openclaw)           SKIP_OPENCLAW=1 ;;
            --openclaw-version)
                shift
                OPENCLAW_NPM_VERSION="${1:?--openclaw-version requires a version argument (e.g. 3.24)}"
                ;;
            --openclaw-docker-tag)
                shift
                OPENCLAW_DOCKER_TAG="${1:?--openclaw-docker-tag requires a tag argument (e.g. ghcr.io/x-aijishu/openclaw-runtime:2026.4.9)}"
                ;;
            --skip-jishushell)         SKIP_JISHUSHELL=1 ;;
            --skip-jishushell-service) SKIP_JISHUSHELL_SERVICE=1 ;;
            --jishushell-version)
                shift
                JISHUSHELL_NPM_VERSION="${1:?--jishushell-version requires a version argument (e.g. 0.4.9)}"
                JISHUSHELL_VERSION_OVERRIDE=1
                ;;
            --skip)
                shift
                IFS=',' read -ra _steps <<< "${1:-}"
                for _s in "${_steps[@]}"; do
                    case "$_s" in
                        1) SKIP_NODE=1 ;;
                        2) SKIP_DOCKER=1 ;;
                        3) SKIP_NOMAD=1 ;;
                        4) SKIP_OPENCLAW=1 ;;
                        5) SKIP_JISHUSHELL=1 ;;
                        6) SKIP_JISHUSHELL_SERVICE=1 ;;
                        *) ui_warn "Unknown step number: $_s (valid: 1-6)" ;;
                    esac
                done
                ;;
            --run)
                # --run N,M  → skip all steps NOT in the list
                # First set all to skip, then re-enable only the listed steps
                SKIP_NODE=1; SKIP_DOCKER=1; SKIP_NOMAD=1
                SKIP_OPENCLAW=1; SKIP_JISHUSHELL=1; SKIP_JISHUSHELL_SERVICE=1
                shift
                IFS=',' read -ra _steps <<< "${1:-}"
                for _s in "${_steps[@]}"; do
                    case "$_s" in
                        1) SKIP_NODE=0 ;;
                        2) SKIP_DOCKER=0 ;;
                        3) SKIP_NOMAD=0 ;;
                        4) SKIP_OPENCLAW=0 ;;
                        5) SKIP_JISHUSHELL=0 ;;
                        6) SKIP_JISHUSHELL_SERVICE=0 ;;
                        *) ui_warn "Unknown step number: $_s (valid: 1-6)" ;;
                    esac
                done
                ;;
            --registry)
                shift
                NPM_REGISTRY="${1:?--registry requires a URL argument}"
                if [[ ! "$NPM_REGISTRY" =~ ^https?:// ]]; then
                    ui_error "--registry must be a valid URL starting with http:// or https://"
                    exit 1
                fi
                ;;
            --yes|-y)                  AUTO_YES=1 ;;
            --help|-h)        usage; exit 0 ;;
            *)                ui_warn "Unknown argument: $1" ;;
        esac
        shift
    done
}

usage() {
    cat <<EOF
Usage: bash jishu-install.sh [options]

Default (no options): runs steps 1,2,3,4,5,6

Options:
  --verbose         Show verbose output
  --dry-run         Show install plan only, do not execute
  --run <steps>     Run only the specified steps (comma-separated, e.g. --run 1,2,3)
  --skip <steps>    Skip steps by number (comma-separated, e.g. --skip 4)
  --skip-node                Skip step 1: Node.js installation
  --skip-docker              Skip step 2: Docker installation
  --skip-nomad               Skip step 3: Nomad installation
  --skip-openclaw            Skip step 4: OpenClaw installation
    --openclaw-docker-tag <tag>
                                                         Pull a specific OpenClaw image tag
                                                         (e.g. --openclaw-docker-tag ghcr.io/x-aijishu/openclaw-runtime:2026.4.9)
  --skip-jishushell          Skip step 5: JishuShell installation
  --skip-jishushell-service  Skip step 6: JishuShell service registration
    --jishushell-version <ver>
                                                         Install a specific jishushell version
                                                         (e.g. --jishushell-version 0.4.9)
  --registry <url>           Use a custom npm registry for all installs
                             (e.g. --registry http://127.0.0.1:4873/)
  --yes, -y                  Skip all confirmation prompts
  --help, -h                 Show this help message

Steps:
  1  Node.js   (via nvm)
  2  Docker
  3  Nomad
  4  OpenClaw  (docker pull / local build)
  5  JishuShell
  6  JishuShell service registration (autostart)

Environment variables:
  JISHU_NODE_VERSION    Specify Node.js major version (default: ${NODE_VERSION})
  JISHU_NVM_VERSION     Specify nvm version         (default: ${NVM_VERSION})
  JISHU_NOMAD_VERSION   Specify Nomad version       (default: ${NOMAD_VERSION})
    JISHUSHELL_NPM_VERSION
                                                 Specify jishushell npm package version (default: latest)
  OPENCLAW_NPM_VERSION  Specify openclaw npm package version (default: latest)
    OPENCLAW_DOCKER_TAG   Override OpenClaw Docker image tag   (default: ${OPENCLAW_DOCKER_TAG})
  NPM_REGISTRY          Custom npm registry URL (same as --registry flag)

Version flags:
    --jishushell-version <ver>  Install a specific jishushell version, e.g. --jishushell-version 0.4.9
    --openclaw-version <ver>    Install a specific openclaw version, e.g. --openclaw-version 3.24
    --openclaw-docker-tag <tag> Pull a specific OpenClaw image tag, e.g. --openclaw-docker-tag ghcr.io/x-aijishu/openclaw-runtime:2026.4.9
  NO_PROMPT             Set to 1 to skip interactive prompts
  VERBOSE               Set to 1 for verbose output

Examples:
  curl -fsSL https://www.aijishu.com/jishu-install.sh | bash
  NO_PROMPT=1 bash jishu-install.sh --dry-run
EOF
}

print_banner() {
    echo -e "${ACCENT}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║        JishuShell Installer          ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}${INFO}  ${TAGLINE}${NC}"
    echo ""
}

# ─── Install mode selection ───────────────────────────────────────────────────
_prompt_install_confirm() {
    if [[ "${AUTO_YES:-0}" == "1" || "${NO_PROMPT:-0}" == "1" ]]; then
        return 0
    fi
    # Check /dev/tty directly — stdout/stdin may be redirected to the log FIFO
    # so the standard -t 0/-t 1 tests are unreliable here.
    if [[ ! -w /dev/tty || ! -r /dev/tty ]]; then
        AUTO_YES=1
        ui_info "Non-interactive shell detected — proceeding automatically"
        return 0
    fi

    # Write everything directly to /dev/tty so output bypasses the log FIFO
    # and is guaranteed to appear on screen before `read` blocks for input.
    {
        echo -e "${ACCENT}${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
        echo -e "${ACCENT}${BOLD}│           THIRD-PARTY SOFTWARE NOTICE                   │${NC}"
        echo -e "${ACCENT}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  JishuShell assists in downloading and configuring the following"
        echo -e "  third-party software packages for personal and internal use only."
        echo -e "  Each package is governed solely by its own license. JishuShell"
        echo -e "  does not modify, relicense, or assert ownership over any of them."
        echo ""
        echo -e "  You are the end user of these packages. You are solely"
        echo -e "  responsible for ensuring that your use of each package complies"
        echo -e "  with its respective license terms, including any restrictions on"
        echo -e "  commercial use, competitive offerings, or redistribution."
        echo ""

        if [[ $SKIP_DOCKER -eq 0 && "$OS" == "linux" ]]; then
            echo -e "  ${BOLD}Docker Engine${NC}"
            echo -e "  ${MUTED}  Docker Engine (container runtime — Linux)${NC}"
            echo -e "  ${MUTED}    URL     : https://github.com/moby/moby${NC}"
            echo -e "  ${MUTED}    License : Apache License, Version 2.0${NC}"
            echo -e "  ${MUTED}    Author  : Docker, Inc.${NC}"
            echo -e "  ${MUTED}  https://github.com/moby/moby/blob/master/LICENSE${NC}"
            echo ""
        fi
        if [[ $SKIP_DOCKER -eq 0 && "$OS" == "macos" ]]; then
            echo -e "  ${BOLD}Colima${NC}"
            echo -e "  ${MUTED}  Colima (container runtime — macOS)${NC}"
            echo -e "  ${MUTED}    URL     : https://github.com/abiosoft/colima${NC}"
            echo -e "  ${MUTED}    License : MIT License${NC}"
            echo -e "  ${MUTED}              https://github.com/abiosoft/colima/blob/main/LICENSE${NC}"
            echo -e "  ${MUTED}    Author  : Abiola Ibrahim${NC}"
            echo ""
        fi
        if [[ $SKIP_NOMAD -eq 0 ]]; then
            echo -e "  ${BOLD}Nomad${NC}"
            echo -e "  ${MUTED}  Nomad v${NOMAD_VERSION} (last MPL 2.0 release in the 1.6.x line)${NC}"
            echo -e "  ${MUTED}    URL     : https://github.com/hashicorp/nomad/tree/v${NOMAD_VERSION}${NC}"
            echo -e "  ${MUTED}    License : Mozilla Public License 2.0${NC}"
            echo -e "  ${MUTED}              https://github.com/hashicorp/nomad/blob/v${NOMAD_VERSION}/LICENSE${NC}"
            echo -e "  ${MUTED}    Author  : HashiCorp, Inc.${NC}"
            echo ""
        fi
        echo -e "  ${ACCENT}─────────────────────────────────────────────────────────${NC}"
        echo -e "  By continuing you acknowledge that you have read the above"
        echo -e "  notices and agree to each package's license terms."
        echo ""
    } >/dev/tty

    local answer
    read -r -p "$(echo -e "  ${WARN}I have read and accept the above notices. Continue? [Y/n]: ${NC}")" answer </dev/tty || answer="y"
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        n|no)
            echo "Installation cancelled." >/dev/tty
            exit 0
            ;;
    esac

    echo "" >/dev/tty
    echo -e "  ${INFO}sudo privileges are required to write to system directories.${NC}" >/dev/tty
    echo "" >/dev/tty
}

# Finalize the install log: restore fds, wait for tee, strip ANSI codes.
# Called from the EXIT trap so it runs on normal exit, Ctrl+C, and errors.
_jishu_finalize_log() {
    set +e
    [[ -z "${_JISHU_RAW_LOG:-}" ]] && return 0  # not started or already finalized
    local _raw="${_JISHU_RAW_LOG}"
    local _log="${JISHU_LOG_FILE}"
    local _fifo="${_JISHU_LOG_FIFO:-}"
    local _tee_pid="${_JISHU_TEE_PID:-}"
    # Mark as done to prevent re-entry
    local _detail="${_JISHU_DETAIL_LOG:-}"
    _JISHU_RAW_LOG=""; _JISHU_TEE_PID=""; _JISHU_LOG_FIFO=""; _JISHU_DETAIL_LOG=""

    # ── Step 1: kill the sudo keepalive background process ────────────────────
    # The keepalive is spawned before the FIFO redirect (so it does NOT hold
    # the FIFO write-end).  We still kill it here for clean process accounting.
    if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "${_SUDO_KEEPALIVE_PID}" 2>/dev/null || true
        _SUDO_KEEPALIVE_PID=""
    fi

    # ── Step 2: restore original fds ─────────────────────────────────────────
    # Closing our fd1 (the FIFO write-end) now sends EOF to tee because the
    # keepalive (the only other writer) is already dead.
    exec 1>&3 2>/dev/null
    exec 2>&4 2>/dev/null
    exec 3>&- 2>/dev/null
    exec 4>&- 2>/dev/null

    # ── Step 3: wait for tee with a 5-second safety timeout ──────────────────
    if [[ -n "$_tee_pid" ]]; then
        local _n=0
        while kill -0 "$_tee_pid" 2>/dev/null && [[ $_n -lt 50 ]]; do
            sleep 0.1
            _n=$((_n + 1))
        done
        # Safety kill if tee is somehow still alive (e.g. another process held
        # the FIFO open), so this function never hangs the terminal.
        if kill -0 "$_tee_pid" 2>/dev/null; then
            kill    "$_tee_pid" 2>/dev/null || true
            sleep 0.2
            kill -9 "$_tee_pid" 2>/dev/null || true
        fi
    fi

    # ── Step 4: remove the FIFO ───────────────────────────────────────────────
    [[ -n "$_fifo" ]] && rm -f "$_fifo" 2>/dev/null || true

    # ── Step 5: produce the clean log ────────────────────────────────────────
    # Strip ANSI escape codes AND decorative box-drawing characters
    # (╔══╗, ╚══╝, ════, ────, ── text ──) so the log is plain readable text.
    if [[ -f "${_raw}" ]]; then
        sed \
            -e 's/\x1B\[[0-9;]*[A-Za-z]//g' \
            -e 's/\r//g' \
            -e 's/[╔╗╚╝╠╣╦╩╬║│]//g' \
            -e 's/[═─]\{2,\}//g' \
            -e '/^[[:space:]]*$/d' \
            "${_raw}" > "${_log}" 2>/dev/null
        rm -f "${_raw}"
    fi
    # ── Step 6: append detailed command output ────────────────────────────────
    if [[ -f "${_detail}" && -s "${_detail}" ]]; then
        {
            printf '\n\n--- DETAILED COMMAND OUTPUT ---\n'
            cat "${_detail}"
        } >> "${_log}" 2>/dev/null
        rm -f "${_detail}"
    fi
    echo "Log saved to: ${_log}"
}

_jishu_install_main() {
    parse_args "$@"

    # ── Set up log file ───────────────────────────────────────────────────────
    # Strategy:
    #   1. Create a named FIFO so we get an unambiguous tee PID via $!.
    #   2. Start tee with SIGINT/SIGTERM ignored — Ctrl+C won't kill it mid-write.
    #      tee inherits the current (real terminal) stdout, so screen output is
    #      preserved.  Its stdin comes from the FIFO.
    #   3. Redirect all script output into the FIFO.
    #   4. EXIT trap calls _jishu_finalize_log which closes the FIFO write-end,
    #      waits for tee with 'wait $PID', then strips ANSI codes to produce the
    #      clean log.  Works for normal exit, Ctrl+C, and set -e errors.
    local _log_ts
    _log_ts="$(date +%Y-%m-%d-%H-%M-%S)"
    JISHU_LOG_FILE="${JISHU_SCRIPT_DIR}/jishu-install-${_log_ts}.log"
    # Fall back to $PWD when the script directory is not writable (e.g. curl|bash).
    if [[ ! -w "${JISHU_SCRIPT_DIR}" ]]; then
        JISHU_LOG_FILE="${PWD}/jishu-install-${_log_ts}.log"
    fi
    _JISHU_RAW_LOG="${JISHU_LOG_FILE}.tmp"
    _JISHU_DETAIL_LOG="${JISHU_LOG_FILE}.detail"

    # Create FIFO — $$ makes it unique per invocation, no mktemp race needed.
    _JISHU_LOG_FIFO="${TMPDIR:-/tmp}/jishu_log_$$.fifo"
    mkfifo "${_JISHU_LOG_FIFO}"

    # Launch tee BEFORE redirecting so it inherits the real terminal as stdout.
    # trap '' INT TERM makes it immune to Ctrl+C and termination signals.
    ( trap '' INT TERM; exec tee "${_JISHU_RAW_LOG}" ) < "${_JISHU_LOG_FIFO}" &
    _JISHU_TEE_PID=$!

    # Override EXIT trap: finalize log first, then run normal temp-file cleanup.
    trap '_jishu_finalize_log; cleanup_tmpfiles' EXIT

    # ── Pre-FIFO keepalive: must be spawned BEFORE the exec redirect below so
    # that it inherits the real terminal as fd 1 rather than the FIFO write-end.
    # A keepalive holding the FIFO open would prevent tee from ever seeing EOF
    # and cause _jishu_finalize_log to hang.  Credentials are acquired later,
    # inside check_sudo() (which runs after the user confirms the install plan),
    # so the keepalive's early sudo -n true calls are intentional no-ops.
    if [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null; then
        if [[ -z "${_SUDO_KEEPALIVE_PID:-}" ]]; then
            ( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &>/dev/null &
            _SUDO_KEEPALIVE_PID=$!
            disown "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
        fi
    fi

    # Save original terminal fds, then redirect everything into the FIFO.
    exec 3>&1 4>&2
    exec > "${_JISHU_LOG_FIFO}" 2>&1

    print_banner
    ui_info "Logging to: ${JISHU_LOG_FILE}"
    detect_os
    detect_arch
    show_install_plan --with-jishushell
    _prompt_install_confirm
    check_sudo
    ensure_prerequisites
    run_install_components --with-jishushell
    local rc=$?
    show_summary --with-jishushell
    exit $rc
}

# Only run main() when executed directly or piped via curl|bash (not when sourced).
# When piped, BASH_SOURCE[0] is unset; when sourced it differs from $0.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    _jishu_install_main "$@"
fi
