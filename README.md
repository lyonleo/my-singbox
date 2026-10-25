# Sing-box 三合一聚合管理脚本

基于 Sing-box 内核的一键部署脚本，同时支持 **VLESS-Reality、Hysteria 2、TUIC V5**，并内置轻量 Clash（Mihomo）在线订阅服务。

支持 Ubuntu / Debian，支持自定义端口、NAT VPS、节点名称修改、订阅管理及服务日志查看。

## 通用双栈 / IPv4 优先安装命令

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/lyonleo/my-singbox/main/singbox-menu-v2.sh -o /root/singbox-menu-v2.sh && bash -n /root/singbox-menu-v2.sh && bash /root/singbox-menu-v2.sh
```

## 纯 IPv6 专用安装命令

仅在新版脚本已实现 IPv6 地址检测和节点链接支持时使用。`curl -6` 只控制下载使用 IPv6，不保证脚本支持纯 IPv6 VPS。

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -6 -fsSL https://raw.githubusercontent.com/lyonleo/my-singbox/main/singbox-menu-v2.sh -o /root/singbox-menu-v2.sh && bash -n /root/singbox-menu-v2.sh && bash /root/singbox-menu-v2.sh
```

## 快捷管理命令

安装完成并配置 `sb` 快捷入口后：

```bash
sb
```

## 支持功能

- VLESS + Reality + Vision（TCP）
- Hysteria 2（UDP）
- TUIC V5（UDP）
- Clash / Mihomo 在线订阅
- 自定义端口及 NAT VPS 端口配置
- 节点名称、订阅文件名称修改
- 服务重启、停止、状态检查及日志查看
- 卸载清理

## 注意事项

1. 安装前建议备份已有 Sing-box 配置。
2. NAT VPS 需要正确配置服务商提供的公网端口映射。
3. 不要将包含节点密码、UUID、密钥或完整订阅链接的配置公开发布。
4. 订阅若使用 HTTP，建议升级为 HTTPS。
5. 更新前请确认新版脚本已上传至仓库 main 分支。
