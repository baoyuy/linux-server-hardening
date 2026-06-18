# Linux Server Hardening

新手向 Linux 服务器开荒/加固交互式脚本。

本项目按 LINUX DO 帖子《个人向 Linux 服务器开荒/加固指南》的步骤组织，把高风险命令做成可读、可跳过、可确认的向导。

原帖：
<https://linux.do/t/topic/1549495>

## 适用场景

- 新买的 VPS 一键重装 Linux，并在新系统首次启动后自动开荒加固。
- 默认推荐重装 Ubuntu 24.04 LTS minimal。
- 想按帖子做 SSH、Nginx、ZRAM、Swap、Chrony、nftables、Fail2ban 等基础加固。
- 你是新手，需要每一步都解释“做什么、为什么、会有什么后果”。

## 不适用场景

- 生产业务已经跑满复杂服务，且你不知道哪些端口必须开放。
- 网站没有全部通过 Cloudflare，但你仍想直接套用“80/443 只允许 Cloudflare 回源”的防火墙规则。
- 没有 SSH 密钥登录，也没有服务商 VNC/救援模式入口。
- 非 Debian/Ubuntu 系统。

## 快速使用

### 一键重装 + 开荒加固

这是推荐入口。它会先显示可重装系统表，默认推荐 Ubuntu 24.04 LTS minimal。

```bash
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/reinstall-and-harden.sh
chmod +x reinstall-and-harden.sh
bash ./reinstall-and-harden.sh
```

执行前必须知道：这会清空当前系统盘。

只预览流程和将要执行的重装命令，不真正清盘：

```bash
bash ./reinstall-and-harden.sh --dry-run
```

如果当前系统没有 `curl`，可以先按你的系统安装：

```bash
apt-get update && apt-get install -y ca-certificates curl
```

或：

```bash
dnf install -y ca-certificates curl
```

很多刚重装的最小系统没有 `curl` 和 `sudo`。如果你的命令行前面是 `root@...#`，说明你已经是 root，不需要写 `sudo`。

## 获取本机 SSH 公钥

这一步在你自己的电脑上运行，不是在服务器上运行。

Linux/macOS：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | python3 -
```

Windows PowerShell：

```powershell
irm https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | py -X utf8 -
```

这条命令会先检查本机有没有 SSH 公钥；有就直接显示，没有就新生成一个 `id_ed25519`。它不会留下临时脚本文件；如果新生成了 SSH 密钥，密钥本身会保留，因为以后登录服务器还要用。它不会偷偷清理你的终端历史记录。这里使用固定版本链接，避免 GitHub raw 的 `main` 缓存导致 Windows 继续拿到旧版乱码脚本。

### 只在当前系统开荒，不重装

```bash
apt-get update
apt-get install -y ca-certificates curl
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
chmod +x harden.sh
bash ./harden.sh
```

只看流程、不改系统：

```bash
bash ./harden.sh --dry-run
```

指定 SSH 端口：

```bash
bash ./harden.sh --ssh-port 22122
```

### 普通用户运行当前系统开荒

如果你的命令行前面是 `$`，通常说明你不是 root，需要使用 `sudo`：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
chmod +x harden.sh
sudo bash ./harden.sh
```

如果系统提示 `sudo: command not found`，请先切换到 root：

```bash
su -
```

## 包含哪些步骤

重装入口会先列出可选目标系统，默认推荐 Ubuntu 24.04 LTS minimal。确认后清空系统盘并重装。新系统首次启动后，自动按顺序执行：

1. 安装基础工具。
2. 创建普通 sudo 用户并写入 SSH 公钥。
3. SSH 加固：改端口，禁 root 登录，禁密码登录，禁空密码，禁键盘交互认证，保留公钥登录。
4. IPv6 静态路由检查：只检查和提示，不硬编码不同厂商的 IPv6 网关。
5. Debian cloud 内核：仅 Debian 执行，Ubuntu 和其它系统跳过。
6. Docker：Debian/Ubuntu 走官方源，其它系统暂时跳过。
7. Nginx fallback：未知域名 HTTP/HTTPS 返回 `444`，使用自签 fallback 证书。
8. ZRAM/Swap：配置 `systemd-zram-generator`、`/swapfile`、`vm.swappiness=180`。
9. SSD Trim：启用 `fstrim.timer`。
10. 时间同步：设置 UTC，安装 Chrony，使用 Cloudflare NTP。
11. nftables：默认拒绝入站，只放行 SSH；80/443 只允许 Cloudflare IP 回源；保留 Docker forward 基础规则。
12. Fail2ban：保护 SSH，10 分钟内失败 3 次封 1 天，动作使用 nftables。

## 新手安全设计

每个步骤都会先显示：

- 这一步会做什么。
- 为什么要做。
- 执行后的后果。
- 执行前请确认什么。

高风险步骤需要确认短语：

- SSH 加固：`我确认SSH密钥可用`
- nftables 防火墙：`我确认防火墙规则`

所有配置文件修改前会备份到：

```text
/root/linux-hardening-backup-YYYYMMDD-HHMMSS/
```

## 最重要的防锁机提醒

执行 SSH 加固前，请先确认：

- 你已经能用普通用户加 SSH 密钥登录。
- 服务商安全组已经放行你选择的 SSH 端口，默认 `22122/TCP`。
- 当前 SSH 窗口不要关闭，先另开一个窗口测试新端口。

执行 nftables 前，请先确认：

- 你没有其它必须公网直连的端口。
- 如果网站要开放 80/443，它们确实全部走 Cloudflare。
- 你知道服务商控制台怎么进 VNC 或救援模式。

## 设计原则

这个脚本不是“静默一键梭哈”，而是“交互式开荒向导”：

- 能解释清楚的才执行。
- 危险步骤必须二次确认。
- 修改前备份。
- 能因厂商差异导致断网的配置默认只提示，不硬写。
- 尽量按教程原意执行，但不替用户隐藏风险。

## 许可

MIT
