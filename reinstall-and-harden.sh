#!/usr/bin/env bash
set -Eeuo pipefail

REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
WORK_DIR="/root/linux-reinstall-hardening"
REINSTALL_SH="$WORK_DIR/reinstall.sh"
DEFAULT_SSH_PORT="22122"
DRY_RUN=0
TARGET_LABEL="Ubuntu 24.04 LTS minimal"
TARGET_ARGS="ubuntu 24.04 --minimal"
ORIGINAL_ARGS=("$@")
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

log() { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Linux 两步式 Ubuntu 重装向导

用法:
  bash reinstall-and-harden.sh
  bash reinstall-and-harden.sh --dry-run

参数:
  --dry-run   只打印重装命令和第二步指引，不执行清盘重装
  -h, --help  显示帮助
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "当前用户不是 root，且系统没有 sudo。请换成 root 或有 sudo 权限的用户运行。"
  fi

  if sudo -n true 2>/dev/null; then
    info "检测到当前用户不是 root，使用免密 sudo 自动提权。"
    exec sudo bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
  fi

  if [[ ! -t 0 ]]; then
    die "当前会话不是交互终端，无法弹出 sudo 密码提示。请直接运行: sudo bash $(printf '%q' "$SCRIPT_PATH") ${ORIGINAL_ARGS[*]}"
  fi

  info "检测到当前用户不是 root，尝试使用 sudo 自动提权。"
  if sudo -v; then
    exec sudo bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
  fi

  die "sudo 提权失败。请确认当前用户拥有 sudo 权限，或改用 root/服务商控制台处理。"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535)) || return 1
}

validate_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

validate_ssh_key() {
  [[ "$1" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]] ]]
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  local ans
  while true; do
    read -r -p "$prompt $suffix " ans
    ans="${ans:-$default}"
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) log "请输入 y 或 n。" ;;
    esac
  done
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo unknown
  fi
}

install_downloaders() {
  command -v curl >/dev/null 2>&1 && return
  command -v wget >/dev/null 2>&1 && return

  local pm
  pm="$(detect_pkg_manager)"
  warn "当前系统没有 curl/wget，尝试先安装 curl。"
  case "$pm" in
    apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl ;;
    dnf|yum) "$pm" install -y ca-certificates curl ;;
    apk) apk add --no-cache ca-certificates curl ;;
    pacman) pacman -Sy --noconfirm ca-certificates curl ;;
    *) die "无法识别包管理器，请先手动安装 curl 或 wget。" ;;
  esac
}

download_file() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget --timeout=20 --tries=3 -qO "$out" "$url"
  else
    die "没有 curl/wget，无法下载: $url"
  fi
}

show_intro() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
  cat <<EOF
${BOLD}Linux 两步式 Ubuntu 重装向导${RESET}

这个脚本现在只负责第 1 步：
1. 调用 bin456789/reinstall 清空系统盘并重装 ${TARGET_LABEL}。
2. 重装完成后，你再登录新系统，手动执行第 2 步开荒加固。

重要后果：
- 当前系统盘会被清空，数据会丢失。
- 当前 SSH 会断开，重装期间只能看服务商 VNC/控制台或安装日志端口。
- 新系统会使用你输入的 SSH 端口、普通用户和 SSH 公钥。
- 重装完成后，系统里暂时没有 Docker、Git 等开荒软件包，这是正常现象。

如果你还没有 SSH 公钥，请先在自己电脑运行：
Windows PowerShell:
  irm https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | py -X utf8 -
Linux/macOS:
  curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | python3 -
EOF
}

show_target_os() {
  printf '\n%s本脚本当前只支持%s\n' "$BOLD" "$RESET"
  printf '  %s\n' "$TARGET_LABEL"
  printf '\n原因:\n'
  printf '  - 之前的自动首启开荒链路不可靠，已改成两步流程。\n'
  printf '  - Ubuntu 24.04 LTS 是当前默认维护目标。\n'
  ok "重装目标固定为: $TARGET_LABEL"
}

collect_inputs() {
  local input_port
  while true; do
    read -r -p "请输入新系统 SSH 端口 [默认 $DEFAULT_SSH_PORT]: " input_port
    SSH_PORT="${input_port:-$DEFAULT_SSH_PORT}"
    validate_port "$SSH_PORT" && break
    warn "端口必须是 1-65535 的数字。"
  done

  while true; do
    read -r -p "请输入新系统普通用户名，例如 admin 或 deploy: " NEW_USER
    validate_username "$NEW_USER" && break
    warn "用户名格式不合法。必须以小写字母或下划线开头，只能包含小写字母、数字、下划线、短横线。"
  done

  cat <<'EOF'

请粘贴你自己电脑上的 SSH 公钥，必须是一整行，例如：
ssh-ed25519 AAAAC3Nza... your-name
EOF
  while true; do
    read -r -p "SSH 公钥: " SSH_KEY
    validate_ssh_key "$SSH_KEY" && break
    warn "公钥格式不对。请粘贴以 ssh-ed25519、sk-ssh-ed25519@openssh.com、ecdsa-sha2-、sk-ecdsa-sha2-nistp256@openssh.com 或 ssh-rsa 开头的整行公钥。"
  done

  if ask_yes_no "你的网站是否全部通过 Cloudflare 访问？防火墙会只允许 Cloudflare 回源 80/443。" "y"; then
    CLOUDFLARE_WEB=1
  else
    CLOUDFLARE_WEB=0
  fi
}

show_second_step() {
  cat <<EOF

${BOLD}第 2 步：新系统登录后手动执行开荒${RESET}

重装完成后，请用下面的形式登录新系统：
  ssh -p $SSH_PORT $NEW_USER@服务器IP

登录成功后执行：
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
  chmod +x harden.sh
  sudo bash ./harden.sh

补充说明：
  - 如果第 2 步运行前没有 git、docker，这是正常的。
  - harden.sh 里会再次询问防火墙和 Cloudflare 相关选项。
  - 你刚才对 Cloudflare 的回答是: $( [[ "$CLOUDFLARE_WEB" == "1" ]] && printf '是，网站全部走 Cloudflare' || printf '否，网站不全部走 Cloudflare' )
EOF
}

confirm_destroy() {
  local cf_label="否"
  [[ "$CLOUDFLARE_WEB" == "1" ]] && cf_label="是"
  cat <<EOF

${RED}${BOLD}危险确认${RESET}

即将清空当前系统盘并重装：
  目标系统: $TARGET_LABEL
  SSH 端口: $SSH_PORT
  普通用户: $NEW_USER
  网站全部走 Cloudflare: $cf_label

这会删除当前系统和磁盘上的数据。确认前请确保：
1. 重要数据已经备份。
2. 服务商控制台/VNC/救援模式可用。
3. 服务商防火墙/安全组已放行新 SSH 端口 $SSH_PORT。
EOF
  ask_yes_no "确认继续并在完成准备后自动重启进入重装吗？" "n" || die "已取消。"
}

reboot_into_installer() {
  local seconds=5
  printf '\n'
  warn "将在 ${seconds} 秒后自动重启进入重装环境。按 Ctrl+C 可以取消。"
  while ((seconds > 0)); do
    printf '  %s...\n' "$seconds"
    sleep 1
    ((seconds--))
  done

  info "开始重启。"
  if command -v reboot >/dev/null 2>&1; then
    reboot
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reboot
  fi
  die "自动重启失败。请立即手动执行: sudo reboot"
}

run_reinstall() {
  install_downloaders
  mkdir -p "$WORK_DIR"
  if [[ "$DRY_RUN" != "1" ]]; then
    info "下载 bin456789/reinstall。"
    download_file "$REINSTALL_URL" "$REINSTALL_SH"
    chmod 700 "$REINSTALL_SH"
  fi

  local reinstall_args=()
  read -r -a reinstall_args <<< "$TARGET_ARGS"

  local -a section_cmd=(
    bash "$REINSTALL_SH"
    "${reinstall_args[@]}"
    --username "$NEW_USER"
    --ssh-key "$SSH_KEY"
    --ssh-port "$SSH_PORT"
  )

  printf '\n将执行重装命令:\n'
  printf ' %q' "${section_cmd[@]}"
  printf '\n\n'
  show_second_step

  if [[ "$DRY_RUN" == "1" ]]; then
    warn "dry-run 模式：不会执行清盘重装。"
    return
  fi

  "${section_cmd[@]}"
  reboot_into_installer
}

main() {
  need_root
  show_intro
  show_target_os
  collect_inputs
  confirm_destroy
  run_reinstall
}

main "$@"
