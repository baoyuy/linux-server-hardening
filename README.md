# Linux Server Hardening

新手向 Ubuntu 服务器重装/开荒交互式脚本。

本项目按 LINUX DO 帖子《个人向 Linux 服务器开荒/加固指南》的步骤组织，把高风险命令做成可读、可跳过、可确认的向导。

原帖：
<https://linux.do/t/topic/1549495>

## 适用场景

- 新买的 VPS，先重装 `Ubuntu 24.04 LTS minimal`，再手动执行开荒加固。
- 想按帖子做 SSH、Nginx、ZRAM、Swap、Chrony、nftables、Fail2ban 等基础加固。
- 你是新手，需要每一步都解释“做什么、为什么、会有什么后果”。

## 不适用场景

- 生产业务已经跑满复杂服务，且你不知道哪些端口必须开放。
- 网站没有全部通过 Cloudflare，但你仍想直接套用“80/443 只允许 Cloudflare 回源”的防火墙规则。
- 没有 SSH 密钥登录，也没有服务商 VNC/救援模式入口。
- 非 Ubuntu 24.04 系统。

## 快速使用

### 第 1 步：重装 Ubuntu 24.04

```bash
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/reinstall-and-harden.sh
chmod +x reinstall-and-harden.sh
bash ./reinstall-and-harden.sh
```

如果你当前登录的是普通用户，只要这个用户有 `sudo` 权限，脚本会自动尝试提权后继续运行。

执行前必须知道：这会清空当前系统盘。

危险确认现在使用 `y/N`。确认后，脚本会显示 5 秒倒计时，并自动重启进入重装环境；倒计时期间可以用 `Ctrl+C` 取消。

只预览流程、重装命令和第 2 步指引，不真正清盘：

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

这个脚本现在只负责重装，不再依赖 cloud-init 自动首启开荒。

重装完成后，系统里暂时没有 `git`、`docker` 等软件包，这是正常现象。请继续执行第 2 步。

### 第 2 步：登录新系统后执行开荒

先用你在第 1 步里设置的用户名、SSH 端口和公钥登录新系统，例如：

```bash
ssh -p 22122 y@服务器IP
```

登录成功后执行：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
chmod +x harden.sh
bash ./harden.sh
```

如果你当前登录的是普通用户，只要它有 `sudo` 权限，`harden.sh` 会自动尝试提权。

`harden.sh` 会优先检测当前系统里的 SSH 端口和当前登录用户，把它们作为默认值继续使用。只有你明确选择修改时，才会重新输入。第 1 步已经配置过的 SSH 公钥，在第 2 步默认也不会重复询问。

如果系统提示 `sudo: command not found`，先切到 root，再安装 `sudo` 或直接用 root 执行第 2 步命令。

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

## 给服务器添加新的电脑公钥

这一步在服务器上运行。它会把新电脑的 SSH 公钥追加到目标用户的 `authorized_keys`，不会覆盖已有公钥。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/add-ssh-key.sh)
```

如果你是 root 登录，脚本会问你要给哪个用户添加；如果你是普通用户登录，默认给当前用户添加。添加前会自动备份原来的 `authorized_keys`。

## 删除服务器上的某个公钥

这一步在服务器上运行。它会列出当前用户的公钥，让你输入编号选择删除。通过本项目添加的新公钥会显示准确添加时间；历史公钥只能显示 `authorized_keys` 文件时间。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/remove-ssh-key.sh)
```

删除前会自动备份 `authorized_keys`。如果只剩最后一个公钥，会要求输入确认短语，避免误删导致无法登录。

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

如果你的命令行前面是 `$`，通常说明你不是 root。只要当前用户有 `sudo` 权限，也可以直接运行：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
chmod +x harden.sh
bash ./harden.sh
```

脚本会自动尝试 `sudo` 提权。如果系统提示 `sudo: command not found`，请先切换到 root：

```bash
su -
```

## 两步流程说明

第 1 步 `reinstall-and-harden.sh` 会做：

1. 固定重装 `Ubuntu 24.04 LTS minimal`。
2. 收集 SSH 端口、普通用户、SSH 公钥等重装信息。
3. 打印重装命令和第 2 步要执行的准确指引。
4. 调用重装工具清空系统盘并重装。

第 2 步 `harden.sh` 会按顺序执行：

1. 检测当前 SSH 端口和当前登录用户，默认沿用现状，避免和第 1 步重复。
2. 安装基础工具。
3. 维护普通 sudo 用户；如果你明确提供新公钥，才会追加写入。
4. SSH 加固：改端口，禁 root 登录，禁密码登录，禁空密码，禁键盘交互认证，保留公钥登录。
5. IPv6 静态路由检查：只检查和提示，不硬编码不同厂商的 IPv6 网关。
6. Debian cloud 内核：仅 Debian 执行，Ubuntu 会跳过。
7. Docker：Ubuntu 走官方源安装。
8. Nginx fallback：未知域名 HTTP/HTTPS 返回 `444`，使用自签 fallback 证书。
9. ZRAM/Swap：配置 `systemd-zram-generator`、`/swapfile`、`vm.swappiness=180`。
10. SSD Trim：启用 `fstrim.timer`。
11. 时间同步：设置 UTC，安装 Chrony，使用 Cloudflare NTP。
12. nftables：默认拒绝入站，只放行 SSH；80/443 只允许 Cloudflare IP 回源；保留 Docker forward 基础规则。
13. Fail2ban：保护 SSH，10 分钟内失败 3 次封 1 天，动作使用 nftables。

## 新手安全设计

每个步骤都会先显示：

- 这一步会做什么。
- 为什么要做。
- 执行后的后果。
- 执行前请确认什么。

高风险步骤需要确认短语：

- SSH 加固：改成 `y/N` 确认
- nftables 防火墙：改成 `y/N` 确认

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

这个项目不是“静默一键梭哈”，而是“两步式重装 + 交互式开荒向导”：

- 能解释清楚的才执行。
- 危险步骤必须二次确认。
- 修改前备份。
- 能因厂商差异导致断网的配置默认只提示，不硬写。
- 尽量按教程原意执行，但不替用户隐藏风险。

## 许可

MIT
