#!/usr/bin/env bash
# Sing-box Reality + Hysteria2 + TUIC + AnyTLS + Mihomo subscription manager
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
ports_unique(){ local p; local -A seen=(); for p in "$@"; do [[ -z $p ]] && continue; valid_port "$p" || return 1; [[ ${seen[$p]+yes} ]] && return 1; seen[$p]=1; done; }

server_ip(){ SERVER_IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true); [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err '无法获取公网 IPv4，请检查网络'; return 1; }; }
load(){ [[ -s $CONF && -s $INFO ]] || { err '未找到完整安装记录，请先安装'; return 1; }; ANYTLS_PORT=; ANYTLS_PUBLIC_PORT=; source "$INFO"; need jq || return 1; UUID=$(jq -er '.inbounds[] | select(.type=="vless") | .users[0].uuid' "$CONF") || return 1; }
backup(){ local stamp; stamp=$(date +%Y%m%d-%H%M%S); mkdir -p /root/singbox-backups; tar -czf "/root/singbox-backups/backup-${stamp}.tar.gz" -C / etc/sing-box etc/singbox_sub_info.conf var/www/singbox-sub 2>/dev/null || true; say "备份目录: /root/singbox-backups/"; }
install_deps(){ need apt-get || { err '目前仅支持 Debian/Ubuntu'; return 1; }; apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl jq python3 tar; }
install_core(){ if command -v sing-box >/dev/null 2>&1; then say '检测到现有 Sing-box 核心'; return 0; fi; local temp; temp=$(mktemp); curl -fsSL --retry 2 https://sing-box.app/install.sh -o "$temp" || { rm -f "$temp"; return 1; }; bash "$temp"; local rc=$?; rm -f "$temp"; (( rc == 0 )) && need sing-box; }
make_cert(){ mkdir -p "$CERT"; if [[ ! -s $CERT/cert.pem || ! -s $CERT/private.key ]]; then openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$CERT/private.key" -out "$CERT/cert.pem" -days 3650 -subj '/CN=bing.com' >/dev/null 2>&1 || return 1; chmod 600 "$CERT/private.key"; fi; }
make_yaml(){ local any_node= any_group=
if [[ -n ${ANYTLS_PORT:-} ]]; then
any_group=", \"${NODE_NAME}-AnyTLS\""
any_node=$(cat <<EOF
  - name: "${NODE_NAME}-AnyTLS"
    type: anytls
    server: ${SERVER_IP}
    port: ${ANYTLS_PUBLIC_PORT:-$ANYTLS_PORT}
    password: "${PASSWORD}"
    sni: bing.com
    skip-cert-verify: true
    client-fingerprint: chrome
    udp: true
EOF
)
fi
mkdir -p "$WEB"; chmod 700 "$WEB"; local temp="$WEB/.${SUB_TOKEN}.yaml.tmp"; cat > "$temp" <<EOF
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
${any_node}
proxy-groups:
  - name: PROXIES
    type: select
    proxies: [AUTO, "${NODE_NAME}-Reality", "${NODE_NAME}-Hy2", "${NODE_NAME}-TUIC"${any_group}, DIRECT]
  - name: AUTO
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies: ["${NODE_NAME}-Reality", "${NODE_NAME}-Hy2", "${NODE_NAME}-TUIC"${any_group}]
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
ANYTLS_PORT=${ANYTLS_PORT:-}
ANYTLS_PUBLIC_PORT=${ANYTLS_PUBLIC_PORT:-}
REALITY_PUBLIC_PORT=$REALITY_PUBLIC_PORT
HY2_PUBLIC_PORT=$HY2_PUBLIC_PORT
TUIC_PUBLIC_PORT=$TUIC_PUBLIC_PORT
PASSWORD=$PASSWORD
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
DEST_DOMAIN=$DEST_DOMAIN
EOF
chmod 600 "$INFO"; }
anytls_json(){ jq -n --argjson port "$ANYTLS_PORT" --arg password "$PASSWORD" --arg cert "$CERT/cert.pem" --arg key "$CERT/private.key" '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:"anytls",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}'; }
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
 local any; any=$(anytls_json) || return 1
 jq --argjson any "$any" '.inbounds += [$any]' "$tmp" > "$tmp.any" && mv -f "$tmp.any" "$tmp" || return 1
