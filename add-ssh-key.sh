#!/usr/bin/env bash
set -Eeuo pipefail

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

read_from_tty() {
  local __var="$1"
  local __prompt="$2"
  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$__prompt" "$__var" < /dev/tty
  else
    die "当前环境没有可交互终端。请下载脚本后运行，或使用 --user 和 --key 参数。"
  fi
}

usage() {
  cat <<'USAGE'
给服务器用户添加 SSH 公钥

用法:
  bash add-ssh-key.sh
  bash add-ssh-key.sh --user USERNAME
  bash add-ssh-key.sh --user USERNAME --key "ssh-ed25519 AAAA..."

参数:
  --user USERNAME  指定要添加公钥的服务器用户
  --key KEY        直接传入 SSH 公钥；不传则交互粘贴
  -h, --help       显示帮助
USAGE
}

TARGET_USER=""
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "--user 需要用户名"
      TARGET_USER="$2"
      shift 2
      ;;
    --key)
      [[ $# -ge 2 ]] || die "--key 需要 SSH 公钥"
      SSH_KEY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

validate_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

validate_ssh_key() {
  local key="$1"
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]] || return 1
  [[ "$(awk '{print NF}' <<<"$key")" -ge 2 ]] || return 1
}

default_user() {
  if [[ "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

prompt_target_user() {
  local current_user
  current_user="$(default_user)"

  if [[ -n "$TARGET_USER" ]]; then
    return
  fi

  if [[ "$current_user" != "root" ]]; then
    TARGET_USER="$current_user"
    return
  fi

  while true; do
    read_from_tty TARGET_USER "你现在是 root。请输入要给哪个用户添加公钥，例如 y 或 admin: "
    if validate_username "$TARGET_USER"; then
      break
    fi
    warn "用户名格式不合法，请重新输入。"
  done
}

prompt_ssh_key() {
  if [[ -n "$SSH_KEY" ]]; then
    return
  fi

  cat <<'EOF'

请粘贴新电脑的 SSH 公钥，必须是一整行，例如：
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your-computer

注意：
- 只粘贴 .pub 公钥，不要粘贴私钥。
- 不要把 PowerShell 提示符、PS C:\... 这类内容一起复制进来。
EOF

  while true; do
    read_from_tty SSH_KEY "SSH 公钥: "
    if validate_ssh_key "$SSH_KEY"; then
      break
    fi
    warn "公钥格式不对。请粘贴以 ssh-ed25519、ssh-rsa 或 ecdsa-sha2- 开头的整行公钥。"
  done
}

ensure_user_exists() {
  validate_username "$TARGET_USER" || die "用户名格式不合法: $TARGET_USER"
  getent passwd "$TARGET_USER" >/dev/null 2>&1 || die "用户不存在: $TARGET_USER"
}

user_home() {
  local home
  home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || die "无法识别用户 $TARGET_USER 的 home 目录"
  printf '%s\n' "$home"
}

user_group() {
  local gid group
  gid="$(getent passwd "$TARGET_USER" | cut -d: -f4)"
  [[ -n "$gid" ]] || die "无法识别用户 $TARGET_USER 的主组"
  group="$(getent group "$gid" | cut -d: -f1)"
  [[ -n "$group" ]] || die "无法识别 gid $gid 对应的组名"
  printf '%s\n' "$group"
}

main() {
  prompt_target_user
  ensure_user_exists
  prompt_ssh_key
  validate_ssh_key "$SSH_KEY" || die "SSH 公钥格式不合法"

  local home_dir primary_group ssh_dir auth_file backup_file
  home_dir="$(user_home)"
  primary_group="$(user_group)"
  ssh_dir="$home_dir/.ssh"
  auth_file="$ssh_dir/authorized_keys"
  backup_file="$auth_file.bak-$(date +%Y%m%d-%H%M%S)"

  info "目标用户: $TARGET_USER"
  info "authorized_keys: $auth_file"

  install -d -m 700 -o "$TARGET_USER" -g "$primary_group" "$ssh_dir"
  touch "$auth_file"
  chown "$TARGET_USER:$primary_group" "$auth_file"
  chmod 600 "$auth_file"

  if grep -Fxq "$SSH_KEY" "$auth_file"; then
    ok "这个公钥已经存在，不重复添加。"
  else
    cp -a "$auth_file" "$backup_file"
    printf '%s\n' "$SSH_KEY" >> "$auth_file"
    chown "$TARGET_USER:$primary_group" "$auth_file"
    chmod 600 "$auth_file"
    ok "已添加新公钥。"
    ok "已备份原文件: $backup_file"
  fi

  cat <<EOF

下一步：
1. 不要关闭当前 SSH 窗口。
2. 用新电脑新开一个窗口测试登录。
3. 如果你的 SSH 端口不是 22，请带上 -p 端口号，例如：
   ssh -p 7019 $TARGET_USER@服务器IP
EOF
}

main "$@"
