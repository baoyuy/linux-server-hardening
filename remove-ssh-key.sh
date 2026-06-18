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
    die "当前环境没有可交互终端。请下载脚本后运行，或使用 --user 参数。"
  fi
}

usage() {
  cat <<'USAGE'
交互式删除服务器用户的 SSH 公钥

用法:
  bash remove-ssh-key.sh
  bash remove-ssh-key.sh --user USERNAME
  bash remove-ssh-key.sh --user USERNAME --index N --yes

参数:
  --user USERNAME  指定要管理公钥的服务器用户
  --index N        非交互删除指定编号
  --yes            非交互确认；删除最后一个公钥仍需 --confirm-last
  --confirm-last   允许非交互删除最后一个公钥
  -h, --help       显示帮助
USAGE
}

TARGET_USER=""
SELECTED_INDEX=""
ASSUME_YES=0
CONFIRM_LAST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "--user 需要用户名"
      TARGET_USER="$2"
      shift 2
      ;;
    --index)
      [[ $# -ge 2 ]] || die "--index 需要编号"
      [[ "$2" =~ ^[0-9]+$ ]] || die "--index 必须是数字"
      SELECTED_INDEX="$(($2 - 1))"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --confirm-last)
      CONFIRM_LAST=1
      shift
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

is_key_line() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]]
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
    read_from_tty TARGET_USER "你现在是 root。请输入要管理哪个用户的公钥，例如 y 或 admin: "
    if validate_username "$TARGET_USER"; then
      break
    fi
    warn "用户名格式不合法，请重新输入。"
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

file_mtime() {
  local file="$1"
  if stat -c '%y' "$file" >/dev/null 2>&1; then
    stat -c '%y' "$file" | cut -d. -f1
  else
    date -r "$file" '+%Y-%m-%d %H:%M:%S'
  fi
}

key_type() {
  awk '{print $1}' <<<"$1"
}

key_comment() {
  local comment
  comment="$(cut -d' ' -f3- <<<"$1")"
  [[ "$comment" != "$1" ]] || comment=""
  [[ -n "$comment" ]] || comment="(无备注)"
  printf '%s\n' "$comment"
}

key_fingerprint() {
  local key="$1"
  if command -v ssh-keygen >/dev/null 2>&1; then
    printf '%s\n' "$key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true
  fi
}

load_keys() {
  local auth_file="$1"
  local file_time="$2"
  KEY_LINES=()
  KEY_ADDED_AT=()
  KEY_TIME_SOURCE=()
  KEY_TYPES=()
  KEY_COMMENTS=()
  KEY_FPS=()
  KEY_LINE_NUMS=()
  KEY_COMMENT_LINE_NUMS=()

  local line line_no=0 pending_time="" pending_comment_line=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if [[ "$line" =~ ^#[[:space:]]added-by[[:space:]]linux-server-hardening[[:space:]]at[[:space:]](.+)$ ]]; then
      pending_time="${BASH_REMATCH[1]}"
      pending_comment_line="$line_no"
      continue
    fi
    if is_key_line "$line"; then
      KEY_LINES+=("$line")
      if [[ -n "$pending_time" ]]; then
        KEY_ADDED_AT+=("$pending_time")
        KEY_TIME_SOURCE+=("准确")
        KEY_COMMENT_LINE_NUMS+=("$pending_comment_line")
      else
        KEY_ADDED_AT+=("$file_time")
        KEY_TIME_SOURCE+=("文件时间/历史key")
        KEY_COMMENT_LINE_NUMS+=("0")
      fi
      KEY_TYPES+=("$(key_type "$line")")
      KEY_COMMENTS+=("$(key_comment "$line")")
      KEY_FPS+=("$(key_fingerprint "$line")")
      KEY_LINE_NUMS+=("$line_no")
      pending_time=""
      pending_comment_line=0
    elif [[ -n "$line" && ! "$line" =~ ^# ]]; then
      pending_time=""
      pending_comment_line=0
    fi
  done < "$auth_file"
}

show_keys() {
  local i
  printf '\n%s当前 authorized_keys 里的公钥%s\n' "$BOLD" "$RESET"
  printf '%-4s %-24s %-18s %-12s %s\n' "编号" "添加时间" "时间来源" "类型" "备注"
  printf '%-4s %-24s %-18s %-12s %s\n' "----" "------------------------" "------------------" "------------" "----------------"
  for i in "${!KEY_LINES[@]}"; do
    printf '%-4s %-24s %-18s %-12s %s\n' "$((i + 1))" "${KEY_ADDED_AT[$i]}" "${KEY_TIME_SOURCE[$i]}" "${KEY_TYPES[$i]}" "${KEY_COMMENTS[$i]}"
    if [[ -n "${KEY_FPS[$i]}" ]]; then
      printf '     fingerprint: %s\n' "${KEY_FPS[$i]}"
    fi
  done
}

choose_key() {
  if [[ -n "$SELECTED_INDEX" ]]; then
    if ((SELECTED_INDEX >= 0 && SELECTED_INDEX < ${#KEY_LINES[@]})); then
      return
    fi
    die "--index 编号超出范围。"
  fi

  local choice
  while true; do
    read_from_tty choice "请输入要删除的编号，或输入 q 退出: "
    case "$choice" in
      q|Q) exit 0 ;;
      ''|*[!0-9]*)
        warn "请输入编号或 q。"
        ;;
      *)
        if ((choice >= 1 && choice <= ${#KEY_LINES[@]})); then
          SELECTED_INDEX=$((choice - 1))
          return
        fi
        warn "编号超出范围。"
        ;;
    esac
  done
}

confirm_delete() {
  local key_count="$1"
  local phrase input
  if ((key_count <= 1)); then
    if [[ "$ASSUME_YES" == "1" && "$CONFIRM_LAST" == "1" ]]; then
      return
    fi
    phrase="我确认删除最后一个公钥"
    cat <<EOF

${RED}${BOLD}危险：这是该用户最后一个 SSH 公钥。${RESET}
删除后，如果没有其它登录方式，你可能无法再用 SSH 登录这个用户。
EOF
    read_from_tty input "请输入确认短语「$phrase」: "
    [[ "$input" == "$phrase" ]] || die "确认短语不匹配，已取消。"
  else
    [[ "$ASSUME_YES" == "1" ]] && return
    read_from_tty input "确认删除编号 $((SELECTED_INDEX + 1)) 的公钥？输入 y 继续: "
    [[ "$input" == "y" || "$input" == "Y" ]] || die "已取消。"
  fi
}

remove_selected_key() {
  local auth_file="$1"
  local backup_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  cp -a "$auth_file" "$backup_file"

  local line_no=0 skip_key_line="${KEY_LINE_NUMS[$SELECTED_INDEX]}" skip_comment_line="${KEY_COMMENT_LINE_NUMS[$SELECTED_INDEX]}" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if [[ "$line_no" == "$skip_key_line" || ( "$skip_comment_line" != "0" && "$line_no" == "$skip_comment_line" ) ]]; then
      continue
    fi
    printf '%s\n' "$line" >> "$tmp_file"
  done < "$auth_file"

  cat "$tmp_file" > "$auth_file"
  rm -f "$tmp_file"
}

main() {
  prompt_target_user
  ensure_user_exists

  local home_dir primary_group ssh_dir auth_file backup_file file_time
  home_dir="$(user_home)"
  primary_group="$(user_group)"
  ssh_dir="$home_dir/.ssh"
  auth_file="$ssh_dir/authorized_keys"
  backup_file="$auth_file.bak-$(date +%Y%m%d-%H%M%S)"

  [[ -f "$auth_file" ]] || die "没有找到 authorized_keys: $auth_file"

  file_time="$(file_mtime "$auth_file")"
  load_keys "$auth_file" "$file_time"
  ((${#KEY_LINES[@]} > 0)) || die "authorized_keys 里没有可识别的 SSH 公钥。"

  info "目标用户: $TARGET_USER"
  info "authorized_keys: $auth_file"
  show_keys
  choose_key

  cat <<EOF

将删除：
  编号: $((SELECTED_INDEX + 1))
  添加时间: ${KEY_ADDED_AT[$SELECTED_INDEX]} (${KEY_TIME_SOURCE[$SELECTED_INDEX]})
  类型: ${KEY_TYPES[$SELECTED_INDEX]}
  备注: ${KEY_COMMENTS[$SELECTED_INDEX]}
EOF
  confirm_delete "${#KEY_LINES[@]}"
  remove_selected_key "$auth_file" "$backup_file"

  chown "$TARGET_USER:$primary_group" "$auth_file"
  chmod 600 "$auth_file"
  chmod 700 "$ssh_dir"

  ok "已删除公钥。"
  ok "已备份原文件: $backup_file"
  cat <<EOF

建议：
1. 不要关闭当前 SSH 窗口。
2. 新开一个窗口测试仍然能用保留的公钥登录。
3. 如果误删，可以从备份恢复：
   cp '$backup_file' '$auth_file'
EOF
}

main "$@"
