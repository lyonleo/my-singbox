# Sing-box 三合一聚合管理脚本

基于 Sing-box 最新内核的一键部署脚本，同时支持 **VLESS-Reality**、**Hysteria 2**、**TUIC V5**，并内置轻量 Clash 在线订阅服务。

### 🚀 一键安装命令（支持 curl / wget 自动兼容）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lyonleo/my-singbox/main/sb.sh || wget -qO- https://raw.githubusercontent.com/lyonleo/my-singbox/main/sb.sh)
### 🌐 纯 IPv6 专用一键安装命令

适合纯 IPv6（IPv6-Only）机器，或希望强制走 IPv6 的 VPS：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lyonleo/my-singbox/main/sb6.sh || wget -qO- https://raw.githubusercontent.com/lyonleo/my-singbox/main/sb6.sh)
