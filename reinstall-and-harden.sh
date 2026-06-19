#!/usr/bin/env bash
set -Eeuo pipefail

REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
HARDEN_URL="https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh"
WORK_DIR="/root/linux-reinstall-hardening"
REINSTALL_SH="$WORK_DIR/reinstall.sh"
CLOUD_DIR="$WORK_DIR/cloud-data"
HARDEN_LOCAL="$WORK_DIR/harden.sh"
DEFAULT_SSH_PORT="22122"
DRY_RUN=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

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
Linux 一键重装 + 开荒加固向导

用法:
  bash reinstall-and-harden.sh
  bash reinstall-and-harden.sh --dry-run

参数:
  --dry-run   只生成配置并打印重装命令，不执行清盘重装
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
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行，例如: bash reinstall-and-harden.sh"
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

shell_quote() {
  printf '%q' "$1"
}

show_intro() {
  clear || true
  cat <<EOF
${BOLD}Linux 一键重装 + 开荒加固向导${RESET}

这个脚本会做两件事：
1. 调用 bin456789/reinstall 清空系统盘并重装你选择的 Linux 系统。
2. 通过 cloud-init 安排新系统首次启动后自动执行开荒加固。

重要后果：
- 当前系统盘会被清空，数据会丢失。
- 当前 SSH 会断开，重装期间只能看服务商 VNC/控制台或安装日志端口。
- 新系统会使用你输入的 SSH 端口和 SSH 公钥。

如果你还没有 SSH 公钥，请先在自己电脑运行：
Windows PowerShell:
  irm https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | py -X utf8 -
Linux/macOS:
  curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | python3 -
EOF
}

choose_target_os() {
  local default_choice=1
  OS_LABELS=(
    "Ubuntu 24.04 LTS minimal"
    "Ubuntu 22.04 LTS minimal"
    "Ubuntu 20.04 LTS minimal"
    "Debian 13 cloud image"
    "Debian 12 cloud image"
    "Rocky Linux 9 cloud image"
    "AlmaLinux 9 cloud image"
    "Fedora 44 cloud image"
  )
  OS_NOTES=(
    "推荐；默认选择；完整开荒适配"
    "老机器兼容性更保守；完整开荒适配"
    "更老的 LTS；完整开荒适配"
    "教程原始方向；完整开荒适配"
    "Debian 稳定旧版本；完整开荒适配"
    "RHEL 系；基础加固适配，Docker/Fail2ban 可能需手动补"
    "RHEL 系；基础加固适配，Docker/Fail2ban 可能需手动补"
    "较新；基础加固适配，不推荐新手"
  )
  OS_ARGS=(
    "ubuntu 24.04 --minimal --ci"
    "ubuntu 22.04 --minimal --ci"
    "ubuntu 20.04 --minimal --ci"
    "debian 13 --ci"
    "debian 12 --ci"
    "rocky 9"
    "almalinux 9"
    "fedora 44"
  )

  printf '\n%s可重装系统列表%s\n' "$BOLD" "$RESET"
  printf '%-4s %-30s %s\n' "编号" "系统" "说明"
  printf '%-4s %-30s %s\n' "----" "------------------------------" "------------------------------"
  local i
  for i in "${!OS_LABELS[@]}"; do
    printf '%-4s %-30s %s\n' "$((i + 1))" "${OS_LABELS[$i]}" "${OS_NOTES[$i]}"
  done

  local choice
  while true; do
    read -r -p "请选择要重装的系统编号 [默认 $default_choice]: " choice
    choice="${choice:-$default_choice}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#OS_LABELS[@]})); then
      TARGET_INDEX=$((choice - 1))
      TARGET_LABEL="${OS_LABELS[$TARGET_INDEX]}"
      TARGET_ARGS="${OS_ARGS[$TARGET_INDEX]}"
      ok "你选择的是: $TARGET_LABEL"
      break
    fi
    warn "请输入 1-${#OS_LABELS[@]} 之间的编号。"
  done
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

prepare_cloud_data() {
  install_downloaders
  rm -rf "$WORK_DIR"
  mkdir -p "$CLOUD_DIR"
  chmod 700 "$WORK_DIR"

  info "下载开荒脚本并嵌入新系统首次启动配置。"
  if [[ -f "$SCRIPT_DIR/harden.sh" ]]; then
    cp "$SCRIPT_DIR/harden.sh" "$HARDEN_LOCAL"
  else
    download_file "$HARDEN_URL" "$HARDEN_LOCAL"
  fi
  chmod 700 "$HARDEN_LOCAL"

  local harden_b64
  harden_b64="$(base64 "$HARDEN_LOCAL" | fold -w 76 | sed 's/^/      /')"

  cat > "$CLOUD_DIR/meta-data" <<EOF
instance-id: linux-reinstall-hardening
local-hostname: linux-server
EOF

  cat > "$CLOUD_DIR/user-data" <<EOF
#cloud-config
write_files:
  - path: /root/harden.sh.b64
    permissions: '0600'
    content: |
$harden_b64
  - path: /root/linux-hardening.env
    permissions: '0600'
    content: |
      LH_SSH_PORT=$(shell_quote "$SSH_PORT")
      LH_NEW_USER=$(shell_quote "$NEW_USER")
      LH_NEW_USER_PUBKEY=$(shell_quote "$SSH_KEY")
      LH_ENABLE_CLOUDFLARE_WEB=$(shell_quote "$CLOUDFLARE_WEB")
runcmd:
  - [ bash, -lc, "base64 -d /root/harden.sh.b64 > /root/harden.sh && chmod 700 /root/harden.sh && bash /root/harden.sh --one-shot --config /root/linux-hardening.env > /root/linux-hardening-firstboot.log 2>&1" ]
EOF

  ok "已生成 cloud-init 配置: $CLOUD_DIR"
}

confirm_destroy() {
  cat <<EOF

${RED}${BOLD}危险确认${RESET}

即将清空当前系统盘并重装：
  目标系统: $TARGET_LABEL
  SSH 端口: $SSH_PORT
  普通用户: $NEW_USER
  Cloudflare 回源限制: $CLOUDFLARE_WEB

这会删除当前系统和磁盘上的数据。确认前请确保：
1. 重要数据已经备份。
2. 服务商控制台/VNC/救援模式可用。
3. 服务商防火墙/安全组已放行新 SSH 端口 $SSH_PORT。
EOF

  local phrase="我确认清空并重装"
  local input
  read -r -p "请输入确认短语「$phrase」: " input
  [[ "$input" == "$phrase" ]] || die "确认短语不匹配，已取消。"
}

run_reinstall() {
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
    --cloud-data "$CLOUD_DIR"
  )

  printf '\n将执行重装命令:\n'
  printf ' %q' "${section_cmd[@]}"
  printf '\n\n'

  if [[ "$DRY_RUN" == "1" ]]; then
    warn "dry-run 模式：不会执行清盘重装。"
    return
  fi

  "${section_cmd[@]}"
}

main() {
  need_root
  show_intro
  choose_target_os
  collect_inputs
  prepare_cloud_data
  confirm_destroy
  run_reinstall
}

main "$@"
