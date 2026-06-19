#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="linux-server-hardening"
DEFAULT_SSH_PORT="22122"
BACKUP_ROOT="/root/linux-hardening-backup-$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="/tmp/linux-hardening-summary-$$.log"
DRY_RUN=0
ASSUME_YES=0
AUTO_CONFIRM=0
MENU_MODE=0
NON_INTERACTIVE=0
CONFIG_FILE=""
SSH_PORT="$DEFAULT_SSH_PORT"
NEW_USER=""
NEW_USER_PUBKEY=""
ENABLE_CLOUDFLARE_WEB=1
PKG_MANAGER=""
SUDO_GROUP="sudo"
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
Linux 服务器开荒/加固交互式脚本

用法:
  bash harden.sh
  bash harden.sh --one-shot --config /root/linux-hardening.env
  bash harden.sh --dry-run

参数:
  --dry-run      只展示会执行的命令，不修改系统
  --yes          降低普通步骤确认频率；危险步骤默认继续
  --one-shot     按顺序执行开荒加固，不显示主菜单
  --menu         显示旧版菜单模式
  --config PATH  读取重装后自动开荒配置
  --ssh-port N   设置默认 SSH 端口，默认 22122
  -h, --help     显示帮助
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --one-shot) NON_INTERACTIVE=1; ASSUME_YES=1; AUTO_CONFIRM=1; shift ;;
    --menu) MENU_MODE=1; shift ;;
    --config)
      [[ $# -ge 2 ]] || die "--config 需要文件路径"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port 需要端口号"
      SSH_PORT="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -r "$CONFIG_FILE" ]] || die "无法读取配置文件: $CONFIG_FILE"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  SSH_PORT="${LH_SSH_PORT:-$SSH_PORT}"
  NEW_USER="${LH_NEW_USER:-$NEW_USER}"
  NEW_USER_PUBKEY="${LH_NEW_USER_PUBKEY:-$NEW_USER_PUBKEY}"
  ENABLE_CLOUDFLARE_WEB="${LH_ENABLE_CLOUDFLARE_WEB:-$ENABLE_CLOUDFLARE_WEB}"
fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_bash() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] bash -c %q\n' "$1"
  else
    bash -c "$1"
  fi
}

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

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    PKG_MANAGER="unknown"
  fi
  if getent group sudo >/dev/null 2>&1; then
    SUDO_GROUP="sudo"
  elif getent group wheel >/dev/null 2>&1; then
    SUDO_GROUP="wheel"
  else
    SUDO_GROUP="sudo"
  fi
  info "检测到系统: $OS_ID $OS_VERSION_ID，包管理器: $PKG_MANAGER"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1
}

ensure_backup_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    info "备份目录将会是: $BACKUP_ROOT"
    return
  fi
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
}

backup_path() {
  local path="$1"
  ensure_backup_root
  if [[ -e "$path" || -L "$path" ]]; then
    local dest="$BACKUP_ROOT${path}"
    if [[ "$DRY_RUN" == "1" ]]; then
      info "将备份 $path 到 $dest"
    else
      mkdir -p "$(dirname "$dest")"
      cp -a "$path" "$dest"
      ok "已备份 $path -> $dest"
    fi
  fi
}

append_summary() {
  printf '%s\n' "$*" >> "$SUMMARY_FILE"
}

pause_enter() {
  [[ "$NON_INTERACTIVE" == "1" ]] && return
  [[ "$ASSUME_YES" == "1" ]] && return
  read -r -p "按 Enter 继续..."
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  if [[ "$ASSUME_YES" == "1" ]]; then
    [[ "$default" == "y" ]]
    return
  fi
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

confirm_danger() {
  local prompt="$1"
  if [[ "$AUTO_CONFIRM" == "1" || "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  ask_yes_no "$prompt" "n"
}

section() {
  printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"
  printf '%*s\n' "${#1}" '' | tr ' ' '-'
}

explain() {
  local title="$1"
  local what="$2"
  local why="$3"
  local impact="$4"
  local check="$5"
  section "$title"
  cat <<EOF
这一步会做什么:
$what

为什么要做:
$why

执行后的后果:
$impact

执行前请确认:
$check
EOF
}

install_packages() {
  local packages=("$@")
  local mapped=()
  local pkg
  case "$PKG_MANAGER" in
    apt)
      run apt-get update
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf|yum)
      for pkg in "${packages[@]}"; do
        case "$pkg" in
          gnupg) mapped+=("gnupg2") ;;
          lsb-release) ;;
          dnsutils) mapped+=("bind-utils") ;;
          systemd-zram-generator) mapped+=("zram-generator") ;;
          docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin) ;;
          *) mapped+=("$pkg") ;;
        esac
      done
      ((${#mapped[@]} > 0)) && run "$PKG_MANAGER" install -y "${mapped[@]}"
      ;;
    pacman)
      for pkg in "${packages[@]}"; do
        case "$pkg" in
          ca-certificates) mapped+=("ca-certificates") ;;
          dnsutils) mapped+=("bind") ;;
          net-tools) mapped+=("net-tools") ;;
          systemd-zram-generator) mapped+=("zram-generator") ;;
          *) mapped+=("$pkg") ;;
        esac
      done
      run pacman -Sy --noconfirm "${mapped[@]}"
      ;;
    apk)
      for pkg in "${packages[@]}"; do
        case "$pkg" in
          dnsutils) mapped+=("bind-tools") ;;
          systemd-zram-generator|fail2ban) ;;
          *) mapped+=("$pkg") ;;
        esac
      done
      ((${#mapped[@]} > 0)) && run apk add --no-cache "${mapped[@]}"
      ;;
    *)
      die "不支持的包管理器，无法安装软件包。"
      ;;
  esac
}

write_file() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local content="$4"
  backup_path "$path"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "将写入 $path"
    return
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
  chown "$owner" "$path"
}

service_restart_or_reload() {
  local service="$1"
  local action="${2:-restart}"
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1 || systemctl status "$service" >/dev/null 2>&1; then
    run systemctl "$action" "$service"
  else
    warn "未找到 systemd 服务: $service"
  fi
}

show_intro() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
  cat <<EOF
${BOLD}Linux 服务器开荒/加固新手向导${RESET}

这个脚本按 LINUX DO 帖子《个人向 Linux 服务器开荒/加固指南》的步骤组织。
它会把每一步的目的、收益、风险和执行后果讲清楚，再让你选择是否执行。

重要提醒:
1. SSH 和防火墙配置错误可能导致你无法登录服务器。
2. 所有会改配置文件的步骤都会先备份到:
   $BACKUP_ROOT
3. 建议在服务商控制台保留 VNC/救援模式入口。
4. 如果你不理解某一步，选择跳过，不要硬做。

当前模式:
  dry-run: $DRY_RUN
  默认 SSH 端口: $SSH_PORT
EOF
  pause_enter
}

collect_basics() {
  [[ "$NON_INTERACTIVE" == "1" ]] && return
  section "基础输入"
  while true; do
    read -r -p "请输入你想使用的 SSH 端口 [默认 $SSH_PORT]: " input_port
    SSH_PORT="${input_port:-$SSH_PORT}"
    if validate_port "$SSH_PORT"; then
      break
    fi
    warn "端口必须是 1-65535 的数字。"
  done

  if ask_yes_no "是否创建一个普通 sudo 用户？" "y"; then
    while true; do
      read -r -p "请输入用户名，例如 admin 或 deploy；不要输入 Y/N；留空则不创建: " NEW_USER
      if [[ -z "$NEW_USER" ]]; then
        warn "已选择不创建普通用户。"
        break
      fi
      if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        break
      fi
      warn "用户名格式不合法: $NEW_USER"
      log "用户名需要以小写字母或下划线开头，只能包含小写字母、数字、下划线、短横线，末尾可带 $。"
    done
  fi

  if [[ -n "$NEW_USER" ]]; then
    cat <<EOF

你可以现在粘贴 SSH 公钥，脚本会写入 /home/$NEW_USER/.ssh/authorized_keys。
如果留空，脚本只创建用户，不配置密钥。
EOF
    read -r -p "SSH 公钥: " NEW_USER_PUBKEY
  fi

  if ask_yes_no "你的网站是否全部通过 Cloudflare 访问？教程的防火墙只允许 Cloudflare 回源 80/443。" "y"; then
    ENABLE_CLOUDFLARE_WEB=1
  else
    ENABLE_CLOUDFLARE_WEB=0
  fi
}

show_reinstall_notice() {
  explain \
    "[可选] 重装系统提示" \
    "展示教程提到的自定义 ISO、bin456789/reinstall、bohanyang/debi 思路；不会默认执行重装。" \
    "教程把纯净系统作为开荒起点，减少服务商预装内容带来的不确定性。" \
    "真正执行 DD/重装会清空系统，当前 SSH 会断开，磁盘数据可能全部丢失。" \
    "你已经备份所有数据，并且有服务商控制台或救援模式。"

  cat <<'EOF'
教程方向:
1. 优先用服务商后台的自定义 ISO 重装。
2. 不支持自定义 ISO 时，可研究:
   - https://github.com/bin456789/reinstall
   - https://github.com/bohanyang/debi

本脚本不会替你无脑 DD。若你一定要在当前机器执行 debi，一定先读项目 README。
EOF

  if ask_yes_no "是否生成一条 debi 示例命令供你复制研究？" "n"; then
    cat <<'EOF'

示例，仅供研究，不要直接粘贴执行:
bash <(curl -fsSL https://raw.githubusercontent.com/bohanyang/debi/master/debi.sh) \
  --version 13 \
  --ethx \
  --bbr \
  --user root \
  --password '请改成强密码'
EOF
    append_summary "已展示 debi 重装示例，未执行。"
  else
    append_summary "跳过重装系统提示。"
  fi
}

setup_user() {
  [[ -n "$NEW_USER" ]] || { append_summary "跳过创建普通用户。"; return; }
  explain \
    "[用户] 创建普通 sudo 用户" \
    "创建用户 $NEW_USER，加入 sudo 组；如果你提供了 SSH 公钥，会写入 authorized_keys。" \
    "日常用普通用户登录，再通过 sudo 提权，比长期使用 root 更稳妥。" \
    "用户创建后不会删除 root；后续 SSH 加固步骤可能禁止 root 直接登录。" \
    "用户名正确；如果粘贴公钥，请确认是以 ssh-ed25519、sk-ssh-ed25519@openssh.com、ecdsa-sha2-、sk-ecdsa-sha2-nistp256@openssh.com 或 ssh-rsa 开头的整行公钥。"

  ask_yes_no "继续创建用户 $NEW_USER 吗？" "y" || { append_summary "跳过创建普通用户。"; return; }

  if id "$NEW_USER" >/dev/null 2>&1; then
    warn "用户 $NEW_USER 已存在，跳过 useradd。"
  else
    if [[ "$PKG_MANAGER" == "apt" ]] && command -v adduser >/dev/null 2>&1; then
      run adduser --disabled-password --gecos "" "$NEW_USER"
    else
      run useradd -m -s /bin/bash "$NEW_USER"
    fi
  fi
  run usermod -aG "$SUDO_GROUP" "$NEW_USER"

  if [[ -n "$NEW_USER_PUBKEY" ]]; then
    if [[ ! "$NEW_USER_PUBKEY" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]] ]]; then
      warn "公钥格式看起来不标准，仍会按你的输入写入。"
    fi
    local home_dir
    home_dir="$(getent passwd "$NEW_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "$home_dir" ]] || home_dir="/home/$NEW_USER"
    run mkdir -p "$home_dir/.ssh"
    if [[ "$DRY_RUN" == "1" ]]; then
      info "将写入 $home_dir/.ssh/authorized_keys"
    else
      printf '%s\n' "$NEW_USER_PUBKEY" >> "$home_dir/.ssh/authorized_keys"
      chown -R "$NEW_USER:$NEW_USER" "$home_dir/.ssh"
      chmod 700 "$home_dir/.ssh"
      chmod 600 "$home_dir/.ssh/authorized_keys"
    fi
  fi
  append_summary "已创建/配置普通 sudo 用户: $NEW_USER"
}

setup_ssh() {
  explain \
    "[SSH] 修改端口并禁止 root/密码登录" \
    "把 SSH 端口设置为 $SSH_PORT；禁止 root 登录；禁止密码、空密码和键盘交互认证；保留公钥登录。" \
    "降低 SSH 被扫描和密码爆破的风险，这是教程里的核心加固项。" \
    "如果你的 SSH 密钥或普通用户没有配置好，执行后可能再也连不上服务器，只能靠服务商控制台救援。" \
    "请另开一个 SSH 窗口，确认你能用普通用户 + 密钥登录；确认服务商安全组已放行 $SSH_PORT/TCP。"

  cat <<EOF
脚本会写入 /etc/ssh/sshd_config.d/99-hardening.conf:
Port $SSH_PORT
LoginGraceTime 1m
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

  if ! confirm_danger "我已经确认 SSH 密钥、普通用户和端口放行都没问题，继续 SSH 加固吗？"; then
    warn "已取消 SSH 加固。"
    append_summary "跳过 SSH 加固。"
    return
  fi

  local ssh_content
  ssh_content="$(cat <<EOF
Port $SSH_PORT
LoginGraceTime 1m
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
)"
  write_file "/etc/ssh/sshd_config.d/99-hardening.conf" "0644" "root:root" "$ssh_content"

  if command -v sshd >/dev/null 2>&1; then
    run sshd -t
  fi
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run systemctl reload ssh || run systemctl restart ssh
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    run systemctl reload sshd || run systemctl restart sshd
  else
    warn "未找到 ssh/sshd systemd 服务，请手动重载 SSH。"
  fi
  append_summary "已配置 SSH 加固，端口: $SSH_PORT"
}

setup_ipv6_route() {
  explain \
    "[IPv6] 静态路由检查/提示" \
    "检测当前 IPv6 默认路由；如果系统没有默认 IPv6 路由，只给出手动排查提示。" \
    "教程里包含 IPv6 静态路由处理，不同 VPS 厂商网关差异很大，不能安全地硬编码。" \
    "本步骤默认不改网络配置，避免把服务器网络改断。" \
    "如果你确实需要静态 IPv6，请先从服务商后台确认 IPv6 地址、前缀和网关。"

  ip -6 route show default || true
  append_summary "已检查 IPv6 默认路由；未自动修改。"
  pause_enter
}

install_cloud_kernel() {
  explain \
    "[内核] 安装 Debian cloud 内核" \
    "在 Debian 上安装 linux-image-cloud-amd64；Ubuntu 或非 Debian 会跳过。" \
    "教程使用 Debian cloud 内核，通常更适合云服务器场景。" \
    "安装新内核后需要重启才会生效；旧内核不会在本步骤自动删除。" \
    "确认当前系统是 Debian，并且你接受之后自行安排重启。"

  if [[ "$OS_ID" != "debian" ]]; then
    warn "当前不是 Debian，跳过 cloud 内核安装。"
    append_summary "跳过 cloud 内核安装：非 Debian。"
    return
  fi
  ask_yes_no "继续安装 linux-image-cloud-amd64 吗？" "y" || { append_summary "跳过 cloud 内核安装。"; return; }
  install_packages linux-image-cloud-amd64
  append_summary "已安装 linux-image-cloud-amd64；需要重启后生效。"
}

install_basic_tools() {
  explain \
    "[基础包] 安装常用工具" \
    "安装 curl、wget、ca-certificates、gnupg、lsb-release、sudo、vim、nano、git、unzip、htop、jq、dnsutils、net-tools、nftables 等基础工具。" \
    "后续 Docker、Nginx、Fail2ban、防火墙等步骤需要这些工具或依赖。" \
    "会执行 apt update，并通过 apt 安装软件包。" \
    "确认服务器 apt 源可用，磁盘空间充足。"
  ask_yes_no "继续安装基础包吗？" "y" || { append_summary "跳过基础包安装。"; return; }
  install_packages curl wget ca-certificates gnupg lsb-release sudo vim nano git unzip htop jq dnsutils net-tools nftables openssl
  append_summary "已安装基础工具。"
}

install_docker() {
  explain \
    "[Docker] 安装 Docker 官方源版本" \
    "添加 Docker 官方 apt 源，安装 docker-ce、docker-ce-cli、containerd.io、docker-buildx-plugin、docker-compose-plugin。" \
    "教程包含 Docker；官方源通常比系统源版本更新。" \
    "会新增 /etc/apt/keyrings/docker.asc 和 Docker apt source；安装后 Docker 服务会启动。" \
    "确认你确实需要 Docker；如果已有 Docker，本步骤可能升级相关组件。"

  ask_yes_no "继续安装 Docker 吗？" "y" || { append_summary "跳过 Docker 安装。"; return; }

  if [[ "$PKG_MANAGER" != "apt" ]]; then
    warn "Docker 官方源自动配置目前只完整支持 Debian/Ubuntu，当前系统跳过 Docker。"
    append_summary "跳过 Docker：当前包管理器 $PKG_MANAGER 未完整适配官方 Docker 源。"
    return
  fi

  run install -m 0755 -d /etc/apt/keyrings
  if [[ "$DRY_RUN" == "1" ]]; then
    info "将下载 Docker GPG key 和 apt source"
  else
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename="$OS_CODENAME"
    if [[ -z "$codename" ]]; then
      codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    fi
    [[ -n "$codename" ]] || die "无法识别系统 codename，不能配置 Docker 源。"
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${codename} stable
EOF
  fi
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run systemctl enable --now docker
  append_summary "已安装 Docker 官方源版本。"
}

install_nginx_fallback() {
  explain \
    "[Nginx] 安装 Nginx 并配置默认 fallback" \
    "安装 Nginx，生成自签 deny.pem/deny.key，写入默认站点；未知域名访问 HTTP/HTTPS 直接返回 444。" \
    "教程用 fallback 虚拟主机减少未知域名、扫站请求命中真实服务的机会。" \
    "会覆盖 /etc/nginx/conf.d/00-default.conf；不会配置你的真实业务站点。" \
    "确认你需要 Nginx；如果已有 Nginx 配置，脚本会先备份再写入 fallback。"

  ask_yes_no "继续安装并配置 Nginx fallback 吗？" "y" || { append_summary "跳过 Nginx fallback。"; return; }
  install_packages nginx openssl
  run mkdir -p /etc/nginx/ssl
  backup_path "/etc/nginx/conf.d/00-default.conf"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "将生成 /etc/nginx/ssl/deny.pem 和 deny.key"
  else
    if [[ ! -f /etc/nginx/ssl/deny.pem || ! -f /etc/nginx/ssl/deny.key ]]; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout /etc/nginx/ssl/deny.key \
        -out /etc/nginx/ssl/deny.pem \
        -subj "/CN=deny.invalid" >/dev/null 2>&1
      chmod 600 /etc/nginx/ssl/deny.key
    fi
    cat > /etc/nginx/conf.d/00-default.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;

    ssl_certificate /etc/nginx/ssl/deny.pem;
    ssl_certificate_key /etc/nginx/ssl/deny.key;

    return 444;
}
EOF
  fi
  run nginx -t
  run systemctl enable --now nginx
  run systemctl reload nginx
  append_summary "已安装 Nginx 并配置 fallback 444。"
}

setup_memory() {
  explain \
    "[内存] 配置 ZRAM、swapfile 和 swappiness" \
    "安装 systemd-zram-generator，配置 zram 大小为内存的一半；创建 /swapfile；设置 vm.swappiness=180。" \
    "教程同时使用 ZRAM 和 swapfile，降低小内存 VPS 在压力下直接 OOM 的概率。" \
    "会启用压缩内存交换；会占用一部分磁盘作为 swapfile。" \
    "确认磁盘空间足够；如果你已有复杂 swap 配置，请谨慎。"

  ask_yes_no "继续配置 ZRAM/Swap 吗？" "y" || { append_summary "跳过 ZRAM/Swap。"; return; }
  install_packages systemd-zram-generator

  local zram_content
  zram_content="$(cat <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
)"
  write_file "/etc/systemd/zram-generator.conf" "0644" "root:root" "$zram_content"

  local mem_kb swap_size_gb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  if (( mem_kb <= 1048576 )); then
    swap_size_gb=2
  elif (( mem_kb <= 2097152 )); then
    swap_size_gb=2
  else
    swap_size_gb=4
  fi

  if [[ ! -f /swapfile ]]; then
    run fallocate -l "${swap_size_gb}G" /swapfile
    run chmod 600 /swapfile
    run mkswap /swapfile
  else
    warn "/swapfile 已存在，跳过创建。"
  fi
  if ! grep -qE '^[^#].*\s/swapfile\s' /etc/fstab 2>/dev/null; then
    backup_path "/etc/fstab"
    run_bash "printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi
  run swapon /swapfile || true

  local sysctl_content
  sysctl_content="$(cat <<'EOF'
vm.swappiness=180
EOF
)"
  write_file "/etc/sysctl.d/99-swappiness.conf" "0644" "root:root" "$sysctl_content"
  run sysctl --system
  run systemctl daemon-reload
  run systemctl restart systemd-zram-setup@zram0.service || true
  append_summary "已配置 ZRAM、/swapfile 和 vm.swappiness=180。"
}

setup_fstrim() {
  explain \
    "[磁盘] 启用 SSD Trim" \
    "启用 systemd 自带的 fstrim.timer。" \
    "定期通知 SSD/云盘哪些块已不再使用，有助于长期性能和空间回收。" \
    "通常风险很低；极少数老旧或异常存储环境可能不支持。" \
    "确认系统使用的是常见云盘/SSD。"
  ask_yes_no "继续启用 fstrim.timer 吗？" "y" || { append_summary "跳过 fstrim。"; return; }
  run systemctl enable --now fstrim.timer
  append_summary "已启用 fstrim.timer。"
}

setup_chrony() {
  explain \
    "[时间] 配置 UTC 和 Chrony" \
    "把系统时区设置为 UTC；安装 Chrony；使用 Cloudflare NTP: time.cloudflare.com。" \
    "教程统一 UTC 时区并使用 Chrony，减少日志、证书、定时任务因时间漂移出问题。" \
    "系统显示时间会变成 UTC；如果你习惯本地时区，需要自己换算。" \
    "确认你接受服务器使用 UTC。"

  ask_yes_no "继续配置 UTC + Chrony 吗？" "y" || { append_summary "跳过 Chrony。"; return; }
  run timedatectl set-timezone UTC
  install_packages chrony
  local chrony_conf="/etc/chrony/chrony.conf"
  local chrony_service="chrony"
  if [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]]; then
    chrony_conf="/etc/chrony.conf"
    chrony_service="chronyd"
  fi
  local chrony_content
  chrony_content="$(cat <<'EOF'
pool time.cloudflare.com iburst

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
keyfile /etc/chrony/chrony.keys
leapsectz right/UTC
logdir /var/log/chrony
EOF
)"
  write_file "$chrony_conf" "0644" "root:root" "$chrony_content"
  run systemctl enable --now "$chrony_service"
  run systemctl restart "$chrony_service"
  append_summary "已设置 UTC 时区并配置 Chrony 使用 Cloudflare NTP。"
}

cloudflare_sets() {
  cat <<'EOF'
define cloudflare_ipv4 = {
    173.245.48.0/20,
    103.21.244.0/22,
    103.22.200.0/22,
    103.31.4.0/22,
    141.101.64.0/18,
    108.162.192.0/18,
    190.93.240.0/20,
    188.114.96.0/20,
    197.234.240.0/22,
    198.41.128.0/17,
    162.158.0.0/15,
    104.16.0.0/13,
    104.24.0.0/14,
    172.64.0.0/13,
    131.0.72.0/22
}

define cloudflare_ipv6 = {
    2400:cb00::/32,
    2606:4700::/32,
    2803:f800::/32,
    2405:b500::/32,
    2405:8100::/32,
    2a06:98c0::/29,
    2c0f:f248::/32
}
EOF
}

setup_nftables() {
  explain \
    "[防火墙] 配置 nftables" \
    "启用 nftables；入站默认 drop；允许 lo、已建立连接、ICMP/ICMPv6、SSH 端口 $SSH_PORT；80/443 只允许 Cloudflare IP 回源；保留 Docker forward 基础规则。" \
    "教程用 nftables 做默认拒绝策略，减少公网暴露面。" \
    "如果你有面板、数据库、WireGuard、直连网站或其它端口，本配置会把它们挡掉，除非你之后手动放行。" \
    "确认服务商安全组已放行 $SSH_PORT；确认你的网站真的走 Cloudflare；确认没有其它必须直连的端口。"

  if [[ "$ENABLE_CLOUDFLARE_WEB" != "1" ]]; then
    warn "你前面选择了网站不全走 Cloudflare，本步骤默认不建议执行。"
    ask_yes_no "仍然继续写入教程风格 nftables 配置吗？" "n" || { append_summary "跳过 nftables：未启用 Cloudflare 回源模式。"; return; }
  fi

  if ! confirm_danger "我已经确认防火墙规则不会挡住自己或业务，继续写入 nftables 吗？"; then
    warn "已取消 nftables。"
    append_summary "跳过 nftables。"
    return
  fi

  install_packages nftables
  backup_path "/etc/nftables.conf"

  local cf_sets nft_content
  cf_sets="$(cloudflare_sets)"
  nft_content="$(cat <<EOF
#!/usr/sbin/nft -f
flush ruleset

$cf_sets

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        tcp dport $SSH_PORT accept

        ip saddr \$cloudflare_ipv4 tcp dport { 80, 443 } accept
        ip6 saddr \$cloudflare_ipv6 tcp dport { 80, 443 } accept

        counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        iifname "docker0" accept
        oifname "docker0" accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
)"
  write_file "/etc/nftables.conf" "0755" "root:root" "$nft_content"
  run nft -c -f /etc/nftables.conf
  run systemctl enable nftables
  run systemctl restart nftables
  append_summary "已启用 nftables：默认拒绝入站，SSH $SSH_PORT，80/443 仅 Cloudflare。"
}

setup_fail2ban() {
  explain \
    "[防爆破] 配置 Fail2ban" \
    "安装 Fail2ban；用 nftables-multiport 动作保护 SSH；10 分钟内失败 3 次封禁 1 天；端口跟随 $SSH_PORT。" \
    "教程用 Fail2ban 降低 SSH 爆破尝试的持续影响。" \
    "如果你自己输错密码/密钥太多，也可能把自己的 IP 暂时封掉。" \
    "确认 SSH 端口正确；确认日志路径为常见 Debian/Ubuntu SSH 日志。"

  ask_yes_no "继续安装并配置 Fail2ban 吗？" "y" || { append_summary "跳过 Fail2ban。"; return; }
  if [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]]; then
    warn "RHEL/Fedora 系可能需要先启用 EPEL 才能安装 Fail2ban；如果安装失败，请重装后手动处理。"
  fi
  install_packages fail2ban
  local jail_content
  jail_content="$(cat <<EOF
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 3
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
backend = systemd
EOF
)"
  write_file "/etc/fail2ban/jail.d/sshd-hardening.local" "0644" "root:root" "$jail_content"
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
  append_summary "已配置 Fail2ban 保护 SSH，maxretry=3，findtime=10m，bantime=1d。"
}

run_all_steps() {
  install_basic_tools
  setup_user
  setup_ssh
  setup_ipv6_route
  install_cloud_kernel
  install_docker
  install_nginx_fallback
  setup_memory
  setup_fstrim
  setup_chrony
  setup_nftables
  setup_fail2ban
}

final_report() {
  section "执行汇总"
  if [[ -f "$SUMMARY_FILE" ]]; then
    cat "$SUMMARY_FILE"
  fi
  cat <<EOF

备份目录:
$BACKUP_ROOT

重要后续检查:
1. 不要关闭当前 SSH 窗口，先新开窗口测试:
   ssh -p $SSH_PORT 用户名@服务器IP
2. 如果启用了 nftables，确认业务端口没有被误挡。
3. 如果安装了 cloud 内核，需要重启后才会生效。
4. 如果你的网站不走 Cloudflare，不要使用“80/443 只允许 Cloudflare”的防火墙规则。
EOF
}

main_menu() {
  local choices=(
    "show_reinstall_notice"
    "setup_user"
    "setup_ssh"
    "setup_ipv6_route"
    "install_cloud_kernel"
    "install_basic_tools"
    "install_docker"
    "install_nginx_fallback"
    "setup_memory"
    "setup_fstrim"
    "setup_chrony"
    "setup_nftables"
    "setup_fail2ban"
  )
  local labels=(
    "重装系统提示，不自动 DD"
    "创建普通 sudo 用户"
    "SSH 加固：改端口、禁 root、禁密码"
    "IPv6 静态路由检查提示"
    "安装 Debian cloud 内核"
    "安装基础工具"
    "安装 Docker"
    "安装 Nginx fallback 444"
    "配置 ZRAM、swapfile、swappiness"
    "启用 fstrim.timer"
    "配置 UTC + Chrony + Cloudflare NTP"
    "配置 nftables 防火墙"
    "配置 Fail2ban"
  )

  while true; do
    section "主菜单"
    log "建议新手按顺序执行；看不懂的步骤可以跳过。"
    for i in "${!labels[@]}"; do
      printf '%2d) %s\n' "$((i + 1))" "${labels[$i]}"
    done
    log " a) 按顺序执行全部步骤"
    log " q) 退出并显示汇总"
    read -r -p "请选择: " choice
    case "$choice" in
      q|Q) break ;;
      a|A)
        for fn in "${choices[@]}"; do
          "$fn"
        done
        break
        ;;
      ''|*[!0-9]*)
        warn "请输入编号、a 或 q。"
        ;;
      *)
        if (( choice >= 1 && choice <= ${#choices[@]} )); then
          "${choices[$((choice - 1))]}"
        else
          warn "编号超出范围。"
        fi
        ;;
    esac
  done
}

main() {
  need_root
  detect_os
  : > "$SUMMARY_FILE"
  show_intro
  collect_basics
  if [[ "$MENU_MODE" == "1" ]]; then
    main_menu
  else
    run_all_steps
  fi
  final_report
}

main "$@"
