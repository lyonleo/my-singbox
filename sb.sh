#!/usr/bin/env bash
# Sing-box Reality + Hysteria2 + TUIC + Mihomo subscription manager
set -o pipefail
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RESET='\033[0m'
DIR=/etc/sing-box
CONF=$DIR/config.json
CERT=$DIR/cert
WEB=/var/www/singbox-sub
INFO=/etc/singbox_sub_info.conf
UNIT=/etc/systemd/system/singbox-sub.service
SELF=/usr/local/bin/singbox-menu
say(){ printf '%b\n' "$*"; }
err(){ say "${RED}错误: $*${RESET}" >&2; }
need_root(){ (( EUID == 0 )) || { err '请使用 root 运行'; exit 1; }; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "缺少命令: $1"; return 1; }; }
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
ask_port(){ local result_var=$1 label=$2 current=$3 input; while :; do read -r -p "$label [$current]: " input; input=${input:-$current}; if valid_port "$input"; then printf -v "$result_var" '%s' "$input"; return; fi; err '端口必须为 1-65535'; done; }
ports_unique(){ local a=$1 b=$2 c=$3 d=$4; [[ $a != "$b" && $a != "$c" && $a != "$d" && $b != "$c" && $b != "$d" && $c != "$d" ]]; }
server_ip(){ SERVER_IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true); [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err '无法获取公网 IPv4，请检查网络'; return 1; }; }
load(){ [[ -s $CONF && -s $INFO ]] || { err '未找到完整安装记录，请先安装'; return 1; }; source "$INFO"; need jq || return 1; UUID=$(jq -er '.inbounds[] | select(.type=="vless") | .users[0].uuid' "$CONF") || return 1; }
backup(){ local stamp; stamp=$(date +%Y%m%d-%H%M%S); mkdir -p /root/singbox-backups; tar -czf "/root/singbox-backups/backup-${stamp}.tar.gz" -C / etc/sing-box etc/singbox_sub_info.conf var/www/singbox-sub 2>/dev/null || true; say "备份目录: /root/singbox-backups/"; }
install_deps(){ need apt-get || { err '目前仅支持 Debian/Ubuntu'; return 1; }; apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl jq python3 tar; }
install_core(){ if command -v sing-box >/dev/null 2>&1; then say '检测到现有 Sing-box 核心'; return 0; fi; local temp; temp=$(mktemp); curl -fsSL --retry 2 https://sing-box.app/install.sh -o "$temp" || { rm -f "$temp"; return 1; }; bash "$temp"; local rc=$?; rm -f "$temp"; (( rc == 0 )) && need sing-box; }
make_cert(){ mkdir -p "$CERT"; if [[ ! -s $CERT/cert.pem || ! -s $CERT/private.key ]]; then openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$CERT/private.key" -out "$CERT/cert.pem" -days 3650 -subj '/CN=bing.com' >/dev/null 2>&1 || return 1; chmod 600 "$CERT/private.key"; fi; }
make_yaml(){ mkdir -p "$WEB"; chmod 700 "$WEB"; local temp="$WEB/.${SUB_TOKEN}.yaml.tmp"; cat > "$temp" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
proxies:
  - name: "${NODE_NAME}-Reality"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PUBLIC_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${DEST_DOMAIN}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome
  - name: "${NODE_NAME}-Hy2"
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY2_PUBLIC_PORT}
    password: "${PASSWORD}"
    sni: bing.com
    skip-cert-verify: true
  - name: "${NODE_NAME}-TUIC"
    type: tuic
    server: ${SERVER_IP}
    port: ${TUIC_PUBLIC_PORT}
    uuid: ${UUID}
    password: "${PASSWORD}"
    sni: bing.com
    alpn: [h3]
    skip-cert-verify: true
    congestion-controller: cubic
    udp-relay-mode: native
proxy-groups:
  - name: PROXIES
    type: select
    proxies: [AUTO, "${NODE_NAME}-Reality", "${NODE_NAME}-Hy2", "${NODE_NAME}-TUIC", DIRECT]
  - name: AUTO
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies: ["${NODE_NAME}-Reality", "${NODE_NAME}-Hy2", "${NODE_NAME}-TUIC"]
rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXIES
EOF
 mv -f "$temp" "$WEB/${SUB_TOKEN}.yaml"; chmod 600 "$WEB/${SUB_TOKEN}.yaml"; }
write_info(){ cat > "$INFO" <<EOF
SUB_PORT=$SUB_PORT
SUB_PUBLIC_PORT=$SUB_PUBLIC_PORT
SUB_TOKEN=$SUB_TOKEN
NODE_NAME=$(printf '%q' "$NODE_NAME")
REALITY_PORT=$REALITY_PORT
HY2_PORT=$HY2_PORT
TUIC_PORT=$TUIC_PORT
REALITY_PUBLIC_PORT=$REALITY_PUBLIC_PORT
HY2_PUBLIC_PORT=$HY2_PUBLIC_PORT
TUIC_PUBLIC_PORT=$TUIC_PUBLIC_PORT
PASSWORD=$PASSWORD
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
DEST_DOMAIN=$DEST_DOMAIN
EOF
chmod 600 "$INFO"; }
write_config(){ mkdir -p "$DIR"; local tmp="$CONF.tmp"; cat > "$tmp" <<EOF
{
 "log":{"level":"warn"},
 "inbounds":[
  {"type":"vless","tag":"vless-in","listen":"::","listen_port":${REALITY_PORT},"users":[{"uuid":"${UUID}","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"${DEST_DOMAIN}","reality":{"enabled":true,"handshake":{"server":"${DEST_DOMAIN}","server_port":443},"private_key":"${PRIVATE_KEY}","short_id":["${SHORT_ID}"]}}},
  {"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":${HY2_PORT},"users":[{"password":"${PASSWORD}"}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"${CERT}/cert.pem","key_path":"${CERT}/private.key"}},
  {"type":"tuic","tag":"tuic-in","listen":"::","listen_port":${TUIC_PORT},"users":[{"uuid":"${UUID}","password":"${PASSWORD}"}],"congestion_control":"cubic","tls":{"enabled":true,"alpn":["h3"],"certificate_path":"${CERT}/cert.pem","key_path":"${CERT}/private.key"}}
 ],
 "outbounds":[{"type":"direct","tag":"direct"}]
}
EOF
 jq empty "$tmp" && sing-box check -c "$tmp" || { rm -f "$tmp"; err '配置校验失败，未覆盖原配置'; return 1; }; mv -f "$tmp" "$CONF"; chmod 600 "$CONF"; }
sub_unit(){ cat > "$UNIT" <<EOF
[Unit]
Description=Sing-box Mihomo Subscription HTTP Server
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=${WEB}
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT} --bind 0.0.0.0 --directory ${WEB}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
 systemctl daemon-reload && systemctl enable --now singbox-sub >/dev/null 2>&1 && systemctl restart singbox-sub; }
start_services(){ systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1 || true; if ! systemctl restart sing-box; then err 'Sing-box 启动失败'; journalctl -u sing-box -n 15 --no-pager; return 1; fi; if ! sub_unit; then err '订阅服务启动失败'; journalctl -u singbox-sub -n 15 --no-pager; return 1; fi; systemctl is-active --quiet sing-box && systemctl is-active --quiet singbox-sub || { err '服务未全部运行'; return 1; }; say "${GREEN}两个服务均已启动${RESET}"; }
firewall_ports(){ if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow "$REALITY_PORT/tcp"; ufw allow "$HY2_PORT/udp"; ufw allow "$TUIC_PORT/udp"; ufw allow "$SUB_PORT/tcp"; fi; }
keypair(){ local output; output=$(sing-box generate reality-keypair) || return 1; PRIVATE_KEY=$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*[Pp]rivate[Kk]ey[[:space:]_]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1); PUBLIC_KEY=$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*[Pp]ublic[Kk]ey[[:space:]_]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1); [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || { err 'Reality 密钥解析失败，核心输出为:'; printf '%s\n' "$output"; return 1; }; }
install_all(){ need_root; if [[ -e $CONF || -e $INFO ]]; then say "${YELLOW}检测到旧配置。重装将更换 UUID、密码和订阅地址。${RESET}"; read -r -p '确认备份并重装? (输入 YES): ' confirm; [[ $confirm == YES ]] || return; backup; fi; install_deps || return 1; install_core || { err 'Sing-box 核心安装失败'; return 1; }; make_cert || return 1; server_ip || return 1; UUID=$(sing-box generate uuid) || return 1; PASSWORD=$(openssl rand -hex 16); SUB_TOKEN=$(openssl rand -hex 16); NODE_NAME=Singbox-Node; DEST_DOMAIN=www.apple.com; keypair || return 1; SHORT_ID=$(openssl rand -hex 8); read -r -p '使用自定义端口? NAT VPS 推荐 y (y/N): ' choice; if [[ $choice =~ ^[yY]$ ]]; then ask_port REALITY_PORT 'Reality TCP 内部监听端口' 10001; ask_port HY2_PORT 'Hy2 UDP 内部监听端口' 10002; ask_port TUIC_PORT 'TUIC UDP 内部监听端口' 10003; ask_port SUB_PORT '订阅 TCP 内部监听端口' 10004; else REALITY_PORT=$((40000+RANDOM%5000)); HY2_PORT=$((45000+RANDOM%5000)); TUIC_PORT=$((50000+RANDOM%5000)); SUB_PORT=$((20000+RANDOM%5000)); fi; ports_unique "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" "$SUB_PORT" || { err '四个内部端口不能重复'; return 1; }; REALITY_PUBLIC_PORT=$REALITY_PORT; HY2_PUBLIC_PORT=$HY2_PORT; TUIC_PUBLIC_PORT=$TUIC_PORT; SUB_PUBLIC_PORT=$SUB_PORT; read -r -p '公网端口与内部端口不同（NAT 映射）? (y/N): ' nat; if [[ $nat =~ ^[yY]$ ]]; then ask_port REALITY_PUBLIC_PORT 'Reality 公网 TCP 端口' "$REALITY_PORT"; ask_port HY2_PUBLIC_PORT 'Hy2 公网 UDP 端口' "$HY2_PORT"; ask_port TUIC_PUBLIC_PORT 'TUIC 公网 UDP 端口' "$TUIC_PORT"; ask_port SUB_PUBLIC_PORT '订阅公网 TCP 端口' "$SUB_PORT"; fi; write_config || return 1; write_info; make_yaml || return 1; start_services || return 1; firewall_ports; say "${GREEN}安装完成${RESET}"; view; }
view(){ load || return 1; server_ip || return 1; say "${CYAN}======== 节点详情 ========${RESET}"; say "IP: $SERVER_IP | 节点名: $NODE_NAME"; say "Reality TCP: 内部 $REALITY_PORT / 公网 ${REALITY_PUBLIC_PORT:-$REALITY_PORT}"; say "Hy2 UDP: 内部 $HY2_PORT / 公网 ${HY2_PUBLIC_PORT:-$HY2_PORT}"; say "TUIC UDP: 内部 $TUIC_PORT / 公网 ${TUIC_PUBLIC_PORT:-$TUIC_PORT}"; say "订阅 TCP: 内部 $SUB_PORT / 公网 ${SUB_PUBLIC_PORT:-$SUB_PORT}"; say "${YELLOW}订阅链接包含访问凭证，请勿公开分享。HTTP 明文传输，建议另行配置 HTTPS。${RESET}"; say "http://${SERVER_IP}:${SUB_PUBLIC_PORT:-$SUB_PORT}/${SUB_TOKEN}.yaml"; say "${CYAN}Reality:${RESET}"; say "vless://${UUID}@${SERVER_IP}:${REALITY_PUBLIC_PORT:-$REALITY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DEST_DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${NODE_NAME}-Reality"; say "${CYAN}Hysteria2:${RESET}"; say "hysteria2://${PASSWORD}@${SERVER_IP}:${HY2_PUBLIC_PORT:-$HY2_PORT}/?sni=bing.com&insecure=1#${NODE_NAME}-Hy2"; say "${CYAN}TUIC:${RESET}"; say "tuic://${UUID}:${PASSWORD}@${SERVER_IP}:${TUIC_PUBLIC_PORT:-$TUIC_PORT}/?sni=bing.com&alpn=h3&insecure=1#${NODE_NAME}-TUIC"; }
modify_ports(){ load || return 1; server_ip || return 1; local old_sub=$SUB_PORT; ask_port REALITY_PORT 'Reality 内部 TCP 端口' "$REALITY_PORT"; ask_port HY2_PORT 'Hy2 内部 UDP 端口' "$HY2_PORT"; ask_port TUIC_PORT 'TUIC 内部 UDP 端口' "$TUIC_PORT"; ask_port SUB_PORT '订阅内部 TCP 端口' "$SUB_PORT"; ports_unique "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" "$SUB_PORT" || { err '内部端口重复'; return 1; }; ask_port REALITY_PUBLIC_PORT 'Reality 公网 TCP 端口' "${REALITY_PUBLIC_PORT:-$REALITY_PORT}"; ask_port HY2_PUBLIC_PORT 'Hy2 公网 UDP 端口' "${HY2_PUBLIC_PORT:-$HY2_PORT}"; ask_port TUIC_PUBLIC_PORT 'TUIC 公网 UDP 端口' "${TUIC_PUBLIC_PORT:-$TUIC_PORT}"; ask_port SUB_PUBLIC_PORT '订阅公网 TCP 端口' "${SUB_PUBLIC_PORT:-$SUB_PORT}"; backup; local tmp="$CONF.tmp"; jq --argjson r "$REALITY_PORT" --argjson h "$HY2_PORT" --argjson t "$TUIC_PORT" '.inbounds[0].listen_port=$r | .inbounds[1].listen_port=$h | .inbounds[2].listen_port=$t' "$CONF" > "$tmp" && sing-box check -c "$tmp" || { rm -f "$tmp"; err '新配置校验失败'; return 1; }; mv -f "$tmp" "$CONF"; write_info; make_yaml; start_services && firewall_ports && view; }
change_name(){ load || return 1; server_ip || return 1; local name; read -r -p '新节点名称（不建议使用引号或特殊符号）: ' name; [[ $name =~ ^[a-zA-Z0-9_一-龥.-]+$ ]] || { err '名称仅允许中英文、数字、下划线、点和横线'; return 1; }; NODE_NAME=$name; write_info; make_yaml; say '节点名称已更新，客户端请刷新订阅'; }
