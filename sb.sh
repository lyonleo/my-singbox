cat <<'EOF' > /usr/local/bin/singbox-menu
#!/usr/bin/env bash

# =========================================================
# Sing-box 三合一聚合管理脚本 (支持 NAT 小鸡端口自定义)
# =========================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/cert"
SUB_DIR="/var/www/singbox-sub"
SUB_INFO_FILE="/etc/singbox_sub_info.conf"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：必须使用 root 权限运行此脚本！${PLAIN}"
        exit 1
    fi
}

get_server_ip() {
    SERVER_IP=$(curl -4 -s --connect-timeout 5 https://api.ipify.org || \
                curl -4 -s --connect-timeout 5 https://ifconfig.me || \
                curl -4 -s --connect-timeout 5 https://icanhazip.com | tr -d ' \r\n')

    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d'/' -f1 | head -n 1 | tr -d ' \r\n')
    fi

    if [[ -z "$SERVER_IP" ]]; then
        echo -e "${RED}错误：未能检测到可用的公网 IPv4 地址！${PLAIN}"
        exit 1
    fi
}

optimize_bbr() {
    echo -e "${GREEN}>>> 正在优化系统网络与 BBR 参数...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
SYSCTL_EOF
    sysctl -p > /dev/null 2>&1
}

generate_cert() {
    mkdir -p ${CERT_DIR}
    if [[ ! -f "${CERT_DIR}/cert.pem" || ! -f "${CERT_DIR}/private.key" ]]; then
        echo -e "${GREEN}>>> 正在生成 Self-Signed 证书 (用于 Hy2 / TUIC)...${PLAIN}"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "${CERT_DIR}/private.key" -out "${CERT_DIR}/cert.pem" \
            -days 3650 -subj "/CN=bing.com" > /dev/null 2>&1
    fi
}

generate_clash_yaml() {
    local ip=$1
    local reality_port=$2
    local hy2_port=$3
    local tuic_port=$4
    local uuid=$5
    local password=$6
    local pubkey=$7
    local sid=$8
    local sni=$9
    local token=${10}
    local base_name=${11}

    local name_reality="${base_name}-Reality"
    local name_hy2="${base_name}-Hy2"
    local name_tuic="${base_name}-TUIC"

    mkdir -p ${SUB_DIR}
    rm -f ${SUB_DIR}/*.yaml

    cat > "${SUB_DIR}/${token}.yaml" << SUB_EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
unified-delay: true

proxies:
  - name: "${name_reality}"
    type: vless
    server: "${ip}"
    port: ${reality_port}
    uuid: ${uuid}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${sni}
    reality-opts:
      public-key: ${pubkey}
      short-id: ${sid}
    client-fingerprint: chrome

  - name: "${name_hy2}"
    type: hysteria2
    server: "${ip}"
    port: ${hy2_port}
    password: "${password}"
    sni: bing.com
    skip-cert-verify: true
    fast-open: true

  - name: "${name_tuic}"
    type: tuic
    server: "${ip}"
    port: ${tuic_port}
    uuid: ${uuid}
    password: "${password}"
    sni: bing.com
    alpn:
      - h3
    skip-cert-verify: true
    congestion-controller: cubic
    udp-relay-mode: native
    reduce-rtt: true

proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - "AUTO-自动选择"
      - "${name_reality}"
      - "${name_hy2}"
      - "${name_tuic}"
      - DIRECT

  - name: "AUTO-自动选择"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
      - "${name_reality}"
      - "${name_hy2}"
      - "${name_tuic}"

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXIES
SUB_EOF
}

setup_sub_service() {
    local sub_port=$1
    cat > /etc/systemd/system/singbox-sub.service << SERVICE_EOF
[Unit]
Description=Lightweight Sing-box Clash Subscription Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/python3 -m http.server ${sub_port} --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl restart singbox-sub
    systemctl enable singbox-sub > /dev/null 2>&1
}

validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

install_singbox() {
    check_root

    echo -e "${GREEN}>>> 正在安装基础依赖与工具...${PLAIN}"
    apt update -y && apt install -y curl wget tar jq openssl python3 ufw

    optimize_bbr
    generate_cert

    echo -e "${GREEN}>>> 正在拉取 Sing-box 官方最新核心...${PLAIN}"
    curl -fsSL https://sing-box.app/install.sh | sh || true

    get_server_ip

    UUID=$(sing-box generate uuid)
    PASSWORD=$(openssl rand -hex 10)
    SUB_TOKEN=$(openssl rand -hex 8)
    NODE_NAME="Singbox-Node"
    DEST_DOMAIN="www.apple.com"

    echo -e "\n${CYAN}================ 端口配置选项 (适合普通/NAT VPS) ================${PLAIN}"
    echo -e "1. ${GREEN}系统随机生成高位端口${PLAIN} (常规独立 IP 机器推荐，直接回车默认)"
    echo -e "2. ${YELLOW}手动自定义指定端口${PLAIN} (NAT 小鸡 / 只有特定端口可用推荐)"
    read -rp "请选择配置方式 [1/2, 默认 1]: " PORT_CHOICE

    if [[ "$PORT_CHOICE" == "2" ]]; then
        while true; do
            read -rp "请输入 Reality 监听端口 (TCP，例如 10001): " REALITY_PORT
            validate_port "$REALITY_PORT" && break || echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${PLAIN}"
        done
        while true; do
            read -rp "请输入 Hysteria 2 监听端口 (UDP，例如 10002): " HY2_PORT
            validate_port "$HY2_PORT" && break || echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${PLAIN}"
        done
        while true; do
            read -rp "请输入 TUIC V5 监听端口 (UDP，例如 10003): " TUIC_PORT
            validate_port "$TUIC_PORT" && break || echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${PLAIN}"
        done
        while true; do
            read -rp "请输入 Clash 订阅下载服务端口 (TCP，例如 10004): " SUB_PORT
            validate_port "$SUB_PORT" && break || echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${PLAIN}"
        done
    else
        REALITY_PORT=$((RANDOM % 5000 + 40000))
        HY2_PORT=$((RANDOM % 5000 + 45001))
        TUIC_PORT=$((RANDOM % 5000 + 50001))
        SUB_PORT=$((RANDOM % 5000 + 20000))
    fi

    KEYPAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "${KEYPAIR}" | grep -i "PrivateKey" | awk -F ':' '{print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "${KEYPAIR}" | grep -i "PublicKey" | awk -F ':' '{print $2}' | tr -d ' \r\n')
    SHORT_ID=$(openssl rand -hex 8)

    mkdir -p ${CONFIG_DIR}
    cat > ${CONFIG_FILE} << CONFIG_EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DEST_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${DEST_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_DIR}/cert.pem",
        "key_path": "${CERT_DIR}/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${PASSWORD}"
        }
      ],
      "congestion_control": "cubic",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_DIR}/cert.pem",
        "key_path": "${CERT_DIR}/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CONFIG_EOF

    cat > ${SUB_INFO_FILE} << INFO_EOF
SUB_PORT=${SUB_PORT}
SUB_TOKEN=${SUB_TOKEN}
NODE_NAME="${NODE_NAME}"
REALITY_PORT=${REALITY_PORT}
HY2_PORT=${HY2_PORT}
TUIC_PORT=${TUIC_PORT}
PASSWORD="${PASSWORD}"
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
DEST_DOMAIN=${DEST_DOMAIN}
INFO_EOF

    generate_clash_yaml "${SERVER_IP}" "${REALITY_PORT}" "${HY2_PORT}" "${TUIC_PORT}" "${UUID}" "${PASSWORD}" "${PUBLIC_KEY}" "${SHORT_ID}" "${DEST_DOMAIN}" "${SUB_TOKEN}" "${NODE_NAME}"
    setup_sub_service "${SUB_PORT}"

    systemctl restart sing-box
    systemctl enable sing-box > /dev/null 2>&1

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow ${REALITY_PORT}/tcp > /dev/null 2>&1
        ufw allow ${HY2_PORT}/udp > /dev/null 2>&1
        ufw allow ${TUIC_PORT}/udp > /dev/null 2>&1
        ufw allow ${SUB_PORT}/tcp > /dev/null 2>&1
    fi

    echo -e "\n${GREEN}================== 安装完成 ==================${PLAIN}"
    view_config
}

modify_ports() {
    if [[ ! -f ${CONFIG_FILE} || ! -f ${SUB_INFO_FILE} ]]; then
        echo -e "${RED}未检测到安装记录，请先安装！${PLAIN}"
        return
    fi

    source ${SUB_INFO_FILE}
    get_server_ip

    echo -e "\n${CYAN}================ 修改各协议监听端口 ================${PLAIN}"
    echo -e "当前端口 -> Reality(TCP): ${YELLOW}${REALITY_PORT}${PLAIN} | Hy2(UDP): ${YELLOW}${HY2_PORT}${PLAIN} | TUIC(UDP): ${YELLOW}${TUIC_PORT}${PLAIN} | 订阅(TCP): ${YELLOW}${SUB_PORT}${PLAIN}"
    echo -e "(直接回车表示保持原端口不变)"
    
    read -rp "请输入新 Reality 端口 [当前: ${REALITY_PORT}]: " NEW_REALITY
    [[ -n "$NEW_REALITY" ]] && validate_port "$NEW_REALITY" && REALITY_PORT=$NEW_REALITY

    read -rp "请输入新 Hysteria 2 端口 [当前: ${HY2_PORT}]: " NEW_HY2
    [[ -n "$NEW_HY2" ]] && validate_port "$NEW_HY2" && HY2_PORT=$NEW_HY2

    read -rp "请输入新 TUIC V5 端口 [当前: ${TUIC_PORT}]: " NEW_TUIC
    [[ -n "$NEW_TUIC" ]] && validate_port "$NEW_TUIC" && TUIC_PORT=$NEW_TUIC

    read -rp "请输入新 Clash 订阅端口 [当前: ${SUB_PORT}]: " NEW_SUB
    [[ -n "$NEW_SUB" ]] && validate_port "$NEW_SUB" && SUB_PORT=$NEW_SUB

    jq ".inbounds[0].listen_port = ${REALITY_PORT} | .inbounds[1].listen_port = ${HY2_PORT} | .inbounds[2].listen_port = ${TUIC_PORT}" ${CONFIG_FILE} > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}

    sed -i "s/REALITY_PORT=.*/REALITY_PORT=${REALITY_PORT}/" ${SUB_INFO_FILE}
    sed -i "s/HY2_PORT=.*/HY2_PORT=${HY2_PORT}/" ${SUB_INFO_FILE}
    sed -i "s/TUIC_PORT=.*/TUIC_PORT=${TUIC_PORT}/" ${SUB_INFO_FILE}
    sed -i "s/SUB_PORT=.*/SUB_PORT=${SUB_PORT}/" ${SUB_INFO_FILE}

    UUID=$(jq -r '.inbounds[0].users[0].uuid' ${CONFIG_FILE})
    generate_clash_yaml "${SERVER_IP}" "${REALITY_PORT}" "${HY2_PORT}" "${TUIC_PORT}" "${UUID}" "${PASSWORD}" "${PUBLIC_KEY}" "${SHORT_ID}" "${DEST_DOMAIN}" "${SUB_TOKEN}" "${NODE_NAME}"
    setup_sub_service "${SUB_PORT}"

    systemctl restart sing-box

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow ${REALITY_PORT}/tcp > /dev/null 2>&1
        ufw allow ${HY2_PORT}/udp > /dev/null 2>&1
        ufw allow ${TUIC_PORT}/udp > /dev/null 2>&1
        ufw allow ${SUB_PORT}/tcp > /dev/null 2>&1
    fi

    echo -e "${GREEN}>>> 端口已更新并已重启服务！${PLAIN}"
    view_config
}

view_config() {
    if [[ ! -f ${CONFIG_FILE} || ! -f ${SUB_INFO_FILE} ]]; then
        echo -e "${RED}未检测到安装记录，请先安装！${PLAIN}"
        return
    fi

    get_server_ip
    source ${SUB_INFO_FILE}
    [[ -z "$NODE_NAME" ]] && NODE_NAME="Singbox-Node"

    UUID=$(jq -r '.inbounds[0].users[0].uuid' ${CONFIG_FILE})
    SUB_URL="http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}.yaml"

    HY2_LINK="hysteria2://${PASSWORD}@${SERVER_IP}:${HY2_PORT}/?sni=bing.com&insecure=1#${NODE_NAME}-Hy2"
    TUIC_LINK="tuic://${UUID}:${PASSWORD}@${SERVER_IP}:${TUIC_PORT}/?sni=bing.com&congestion_control=cubic&alpn=h3&insecure=1#${NODE_NAME}-TUIC"
    REALITY_LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DEST_DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${NODE_NAME}-Reality"

    echo -e "\n${GREEN}================ 节点配置详情 ================${PLAIN}"
    echo -e "${YELLOW}服务器 IP 地址:      ${PLAIN} ${SERVER_IP}"
    echo -e "${YELLOW}节点通用前缀名称:    ${PLAIN} ${NODE_NAME}"
    echo -e "${YELLOW}Reality 端口 (TCP):  ${PLAIN} ${REALITY_PORT}"
    echo -e "${YELLOW}Hysteria2 端口 (UDP):${PLAIN} ${HY2_PORT}"
    echo -e "${YELLOW}TUIC V5 端口 (UDP):  ${PLAIN} ${TUIC_PORT}"
    echo -e "${YELLOW}通用 UUID:           ${PLAIN} ${UUID}"
    echo -e "${YELLOW}Hy2/TUIC 认证密码:   ${PLAIN} ${PASSWORD}"
    echo -e "${YELLOW}订阅服务端口 (TCP):  ${PLAIN} ${SUB_PORT}"
    echo -e "${YELLOW}订阅文件名称:        ${PLAIN} ${SUB_TOKEN}.yaml"
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}[🌟 Clash (Mihomo) 在线订阅链接]:${PLAIN}"
    echo -e "${CYAN}${SUB_URL}${PLAIN}"
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}[Hysteria 2 单节点链接]:${PLAIN}"
    echo -e "${CYAN}${HY2_LINK}${PLAIN}"
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}[TUIC V5 单节点链接]:${PLAIN}"
    echo -e "${CYAN}${TUIC_LINK}${PLAIN}"
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}[Reality 单节点链接]:${PLAIN}"
    echo -e "${CYAN}${REALITY_LINK}${PLAIN}"
    echo -e "====================================================\n"
}

change_sub_name() {
    if [[ ! -f ${CONFIG_FILE} || ! -f ${SUB_INFO_FILE} ]]; then
        echo -e "${RED}未检测到安装记录，请先安装！${PLAIN}"
        return
    fi

    get_server_ip
    source ${SUB_INFO_FILE}
    [[ -z "$NODE_NAME" ]] && NODE_NAME="Singbox-Node"

    echo -e "\n当前订阅文件名: ${YELLOW}${SUB_TOKEN}.yaml${PLAIN}"
    read -rp "请输入新的订阅名称 (仅限英文/数字/下划线，无需输入.yaml): " NEW_TOKEN

    if [[ ! "$NEW_TOKEN" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}输入格式错误！只能包含英文、数字、下划线或减号。${PLAIN}"
        return
    fi

    UUID=$(jq -r '.inbounds[0].users[0].uuid' ${CONFIG_FILE})
    sed -i "s/SUB_TOKEN=.*/SUB_TOKEN=${NEW_TOKEN}/" ${SUB_INFO_FILE}

    generate_clash_yaml "${SERVER_IP}" "${REALITY_PORT}" "${HY2_PORT}" "${TUIC_PORT}" "${UUID}" "${PASSWORD}" "${PUBLIC_KEY}" "${SHORT_ID}" "${DEST_DOMAIN}" "${NEW_TOKEN}" "${NODE_NAME}"

    SUB_URL="http://${SERVER_IP}:${SUB_PORT}/${NEW_TOKEN}.yaml"
    echo -e "${GREEN}订阅文件名修改成功！${PLAIN}"
    echo -e "${GREEN}新的 Clash 在线订阅链接为:${PLAIN} ${CYAN}${SUB_URL}${PLAIN}\n"
}

change_node_name() {
    if [[ ! -f ${CONFIG_FILE} || ! -f ${SUB_INFO_FILE} ]]; then
        echo -e "${RED}未检测到安装记录，请先安装！${PLAIN}"
        return
    fi

    get_server_ip
    source ${SUB_INFO_FILE}
    [[ -z "$NODE_NAME" ]] && NODE_NAME="Singbox-Node"

    echo -e "\n当前节点显示前缀: ${YELLOW}${NODE_NAME}${PLAIN}"
    read -rp "请输入新的节点显示名称 (如 香港 01 / 日本-专线): " NEW_NODE_NAME

    if [[ -z "$NEW_NODE_NAME" ]]; then
        echo -e "${RED}节点名称不能为空！${PLAIN}"
        return
    fi

    UUID=$(jq -r '.inbounds[0].users[0].uuid' ${CONFIG_FILE})

    if grep -q "NODE_NAME=" ${SUB_INFO_FILE}; then
        sed -i "s/NODE_NAME=.*/NODE_NAME=\"${NEW_NODE_NAME}\"/" ${SUB_INFO_FILE}
    else
        echo "NODE_NAME=\"${NEW_NODE_NAME}\"" >> ${SUB_INFO_FILE}
    fi

    generate_clash_yaml "${SERVER_IP}" "${REALITY_PORT}" "${HY2_PORT}" "${TUIC_PORT}" "${UUID}" "${PASSWORD}" "${PUBLIC_KEY}" "${SHORT_ID}" "${DEST_DOMAIN}" "${SUB_TOKEN}" "${NEW_NODE_NAME}"

    echo -e "${GREEN}节点名称已成功修改为: ${YELLOW}${NEW_NODE_NAME}${PLAIN}"
    echo -e "${CYAN}提示：已同步更新订阅文件！请在客户端刷新订阅即可。${PLAIN}\n"
}

restart_services() {
    echo -e "${GREEN}>>> 正在重启 Sing-box 与订阅服务...${PLAIN}"
    systemctl restart sing-box
    systemctl restart singbox-sub
    echo -e "${GREEN}服务已成功重启！${PLAIN}"
}

stop_services() {
    echo -e "${YELLOW}>>> 正在停止 Sing-box 与订阅服务...${PLAIN}"
    systemctl stop sing-box
    systemctl stop singbox-sub
    echo -e "${YELLOW}服务已停止！${PLAIN}"
}

uninstall_all() {
    check_root
    read -rp "确定要彻底卸载 Sing-box 及订阅服务吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}>>> 正在停止并卸载服务...${PLAIN}"
        systemctl stop sing-box singbox-sub > /dev/null 2>&1
        systemctl disable sing-box singbox-sub > /dev/null 2>&1

        rm -rf /etc/sing-box
        rm -rf /var/lib/sing-box
        rm -rf /var/www/singbox-sub
        rm -f /etc/systemd/system/singbox-sub.service
        rm -f /etc/systemd/system/sing-box.service
        rm -f ${SUB_INFO_FILE}
        rm -f /usr/local/bin/sing-box
        rm -f /usr/local/bin/singbox-menu
        rm -f /usr/local/bin/singbox
        rm -f /usr/local/bin/sb
        systemctl daemon-reload

        echo -e "${GREEN}卸载完成，所有相关文件与服务已清理干净！${PLAIN}"
        exit 0
    else
        echo -e "${CYAN}已取消卸载。${PLAIN}"
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}======================================================${PLAIN}"
    echo -e "${GREEN}   Sing-box 聚合管理脚本 (Reality+Hy2+TUIC+Clash订阅)   ${PLAIN}"
    echo -e "${CYAN}======================================================${PLAIN}"
    echo -e "${GREEN} 1.${PLAIN} 安装 / 重新安装节点服务 (支持自定义/随机端口)"
    echo -e "${GREEN} 2.${PLAIN} 查看当前节点配置与 Clash 在线订阅链接"
    echo -e "${GREEN} 3.${PLAIN} 单独修改节点监听端口 (适合 NAT 端口调整)"
    echo -e "${GREEN} 4.${PLAIN} 修改节点显示前缀名称 (如: 🇭🇰 香港 01)"
    echo -e "${GREEN} 5.${PLAIN} 修改 Clash 订阅文件名称"
    echo -e "${GREEN} 6.${PLAIN} 重启所有服务"
    echo -e "${GREEN} 7.${PLAIN} 停止所有服务"
    echo -e "${GREEN} 8.${PLAIN} 彻底卸载清理"
    echo -e "${GREEN} 0.${PLAIN} 退出菜单"
    echo -e "${CYAN}======================================================${PLAIN}"

    if systemctl is-active --quiet sing-box; then
        echo -e "Sing-box 状态: ${GREEN}运行中${PLAIN}"
    else
        echo -e "Sing-box 状态: ${RED}未运行 / 未安装${PLAIN}"
    fi

    if systemctl is-active --quiet singbox-sub; then
        echo -e "订阅服务状态:  ${GREEN}运行中${PLAIN}"
    else
        echo -e "订阅服务状态:  ${RED}未运行 / 未安装${PLAIN}"
    fi
    echo -e "${CYAN}======================================================${PLAIN}"

    read -rp "请输入操作编号 [0-8]: " num
    case "$num" in
        1) install_singbox ;;
        2) view_config ;;
        3) modify_ports ;;
        4) change_node_name ;;
        5) change_sub_name ;;
        6) restart_services ;;
        7) stop_services ;;
        8) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入有效编号！${PLAIN}" ;;
    esac
}

ln -sf /usr/local/bin/singbox-menu /usr/local/bin/singbox
ln -sf /usr/local/bin/singbox-menu /usr/local/bin/sb

show_menu
EOF

chmod +x /usr/local/bin/singbox-menu
/usr/local/bin/singbox-menu
