# Sing-box 四合一聚合管理脚本

基于 Sing-box 内核的一键部署脚本，支持 **VLESS-Reality、Hysteria 2、TUIC V5、AnyTLS**，内置 Clash / Mihomo 在线订阅服务及 BBR 优化功能。

支持 Ubuntu / Debian、自定义端口、NAT VPS、节点及订阅管理。

## 一键安装

使用 root 用户执行：

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -fL --retry 3 --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github.raw+json' "https://api.github.com/repos/lyonleo/my-singbox/contents/sb.sh?ref=main&t=$(date +%s)" -o /root/sb-download.sh && bash -n /root/sb-download.sh && mv -f /root/sb-download.sh /root/sb.sh && bash /root/sb.sh
```

进入菜单后：

- **选 1**：全新安装 / 重装四种协议。
- **选 11**：给本脚本旧版三合一安装追加 AnyTLS，保留原节点凭证和订阅地址。

重装会更换 UUID、密码和订阅地址，请按提示确认。

## 快捷管理

运行脚本后，可通过以下命令进入管理菜单：

```bash
sb
```

## 支持功能

- VLESS + Reality + Vision（TCP）
- Hysteria 2（UDP）
- TUIC V5（UDP）
- AnyTLS（TCP）
- Clash / Mihomo 在线订阅及节点链接输出
- 自定义监听端口及 NAT 公网映射端口
- 给现有三合一安装追加 AnyTLS
- 修改节点名称、订阅文件名称
- 服务重启、停止、状态及日志查看
- BBR + fq 一键开启与状态查看
- 配置备份及卸载清理

## 使用要求

- 系统：Ubuntu / Debian，使用 root 运行。
- AnyTLS 需要 sing-box 1.12.0 或更新版本；已有核心过旧时需先升级。
- 客户端需要支持对应协议，AnyTLS 建议使用新版 Mihomo 客户端。
- 当前脚本需要公网 IPv4，不支持纯 IPv6 VPS。

## 端口放行

请在系统防火墙、云安全组及 NAT 映射中放行实际设置的端口：

| 服务 | 传输协议 |
| --- | --- |
| VLESS-Reality | TCP |
| Hysteria 2 | UDP |
| TUIC V5 | UDP |
| AnyTLS | TCP |
| 在线订阅 | TCP |

甲骨文 VPS 还需要在安全列表或网络安全组中添加对应入站规则。

## 注意事项

1. 安装或更新前请备份已有配置。
2. NAT VPS 请正确填写内部监听端口与公网映射端口。
3. 添加 AnyTLS 后，客户端需要刷新订阅。
4. 当前 Hy2、TUIC、AnyTLS 使用自签名证书，生成的客户端配置已开启跳过证书验证。
5. 完整订阅链接及节点链接包含访问凭证，请勿公开。
6. 在线订阅默认使用 HTTP，建议另行配置 HTTPS。
7. BBR 是否可用取决于当前系统内核。
8. 执行一键安装前，请确认新版脚本已上传至仓库 main 分支的 `sb.sh`。

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
