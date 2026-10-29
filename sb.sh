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

make_yaml(){
  local any_node= any_group=
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
  mkdir -p "$WEB"; chmod 700 "$WEB"
  local temp="$WEB/.${SUB_TOKEN}.yaml.tmp"
  cat > "$temp" <<EOF
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
  mv -f "$temp" "$WEB/${SUB_TOKEN}.yaml" && chmod 600 "$WEB/${SUB_TOKEN}.yaml"
}

write_info(){
  cat > "$INFO" <<EOF
SUB_PORT=$SUB_PORT
SUB_PUBLIC_PORT=$SUB_PUBLIC_PORT
SUB_TOKEN=$SUB_TOKEN
NODE_NAME="${NODE_NAME}"
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
  chmod 600 "$INFO"
}

anytls_json(){ jq -n --argjson port "$ANYTLS_PORT" --arg password "$PASSWORD" --arg cert "$CERT/cert.pem" --arg key "$CERT/private.key" '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:"anytls",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}'; }

write_config(){
  mkdir -p "$DIR"
  local tmp="$CONF.tmp"
  cat > "$tmp" <<EOF
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
  local any
  any=$(anytls_json) || return 1
  jq --argjson any "$any" '.inbounds += [$any]' "$tmp" > "$tmp.any" && mv -f "$tmp.any" "$tmp" || return 1
  jq empty "$tmp" && sing-box check -c "$tmp" || { rm -f "$tmp"; err '配置校验失败，未覆盖原配置'; return 1; }
  mv -f "$tmp" "$CONF"
  chmod 600 "$CONF"
}

sub_unit(){
  cat > "$UNIT" <<EOF
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
  systemctl daemon-reload && systemctl enable --now singbox-sub >/dev/null 2>&1 && systemctl restart singbox-sub
}

start_services(){ systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1 || true; if ! systemctl restart sing-box; then err 'Sing-box 启动失败'; journalctl -u sing-box -n 15 --no-pager; return 1; fi; if ! sub_unit; then err '订阅服务启动失败'; journalctl -u singbox-sub -n 15 --no-pager; return 1; fi; systemctl is-active --quiet sing-box && systemctl is-active --quiet singbox-sub || { err '服务未全部运行'; return 1; }; say "${GREEN}两个服务均已启动${RESET}"; }
firewall_ports(){ if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow "$REALITY_PORT/tcp"; ufw allow "$HY2_PORT/udp"; ufw allow "$TUIC_PORT/udp"; ufw allow "$SUB_PORT/tcp"; [[ -z ${ANYTLS_PORT:-} ]] || ufw allow "$ANYTLS_PORT/tcp"; fi; }
keypair(){ local output; output=$(sing-box generate reality-keypair) || return 1; PRIVATE_KEY=$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*[Pp]rivate[Kk]ey[[:space:]_]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1); PUBLIC_KEY=$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*[Pp]ublic[Kk]ey[[:space:]_]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1); [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || { err 'Reality 密钥解析失败，核心输出为:'; printf '%s\n' "$output"; return 1; }; }

install_all(){ need_root; if [[ -e $CONF || -e $INFO ]]; then say "${YELLOW}检测到旧配置。重装将更换 UUID、密码和订阅地址。${RESET}"; read -r -p '确认备份并重装? (输入 YES): ' confirm; [[ $confirm == YES ]] || return; backup; fi; install_deps || return 1; install_core || { err 'Sing-box 核心安装失败'; return 1; }; make_cert || return 1; server_ip || return 1; UUID=$(sing-box generate uuid) || return 1; PASSWORD=$(openssl rand -hex 16); SUB_TOKEN=$(openssl rand -hex 16); NODE_NAME=Singbox-Node; DEST_DOMAIN=www.apple.com; keypair || return 1; SHORT_ID=$(openssl rand -hex 8); read -r -p '使用自定义端口? NAT VPS 推荐 y (y/N): ' choice; if [[ $choice =~ ^[yY]$ ]]; then ask_port REALITY_PORT 'Reality TCP 内部监听端口' 10001; ask_port HY2_PORT 'Hy2 UDP 内部监听端口' 10002; ask_port TUIC_PORT 'TUIC UDP 内部监听端口' 10003; ask_port SUB_PORT '订阅 TCP 内部监听端口' 10004; ask_port ANYTLS_PORT 'AnyTLS TCP 内部监听端口' 10005; else REALITY_PORT=$((40000+RANDOM%5000)); HY2_PORT=$((45000+RANDOM%5000)); TUIC_PORT=$((50000+RANDOM%5000)); SUB_PORT=$((20000+RANDOM%5000)); ANYTLS_PORT=$((55000+RANDOM%5000)); fi; ports_unique "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" "$SUB_PORT" "${ANYTLS_PORT:-}" || { err '五个内部端口不能重复'; return 1; }; REALITY_PUBLIC_PORT=$REALITY_PORT; HY2_PUBLIC_PORT=$HY2_PORT; TUIC_PUBLIC_PORT=$TUIC_PORT; SUB_PUBLIC_PORT=$SUB_PORT; ANYTLS_PUBLIC_PORT=$ANYTLS_PORT; read -r -p '公网端口与内部端口不同（NAT 映射）? (y/N): ' nat; if [[ $nat =~ ^[yY]$ ]]; then ask_port REALITY_PUBLIC_PORT 'Reality 公网 TCP 端口' "$REALITY_PORT"; ask_port HY2_PUBLIC_PORT 'Hy2 公网 UDP 端口' "$HY2_PORT"; ask_port TUIC_PUBLIC_PORT 'TUIC 公网 UDP 端口' "$TUIC_PORT"; ask_port SUB_PUBLIC_PORT '订阅公网 TCP 端口' "$SUB_PORT"; ask_port ANYTLS_PUBLIC_PORT 'AnyTLS 公网 TCP 端口' "$ANYTLS_PORT"; fi; write_config || return 1; write_info; make_yaml || return 1; start_services || return 1; firewall_ports; say "${GREEN}安装完成${RESET}"; view; }

view(){ load || return 1; server_ip || return 1; say "${CYAN}======== 节点详情 ========${RESET}"; say "IP: $SERVER_IP | 节点名: $NODE_NAME"; say "Reality TCP: 内部 $REALITY_PORT / 公网 ${REALITY_PUBLIC_PORT:-$REALITY_PORT}"; say "Hy2 UDP: 内部 $HY2_PORT / 公网 ${HY2_PUBLIC_PORT:-$HY2_PORT}"; say "TUIC UDP: 内部 $TUIC_PORT / 公网 ${TUIC_PUBLIC_PORT:-$TUIC_PORT}"; say "订阅 TCP: 内部 $SUB_PORT / 公网 ${SUB_PUBLIC_PORT:-$SUB_PORT}"; say "${YELLOW}订阅链接包含访问凭证，请勿公开分享。HTTP 明文传输，建议另行配置 HTTPS。${RESET}"; say "http://${SERVER_IP}:${SUB_PUBLIC_PORT:-$SUB_PORT}/${SUB_TOKEN}.yaml"; if [[ -n ${ANYTLS_PORT:-} ]]; then say "AnyTLS TCP: 内部 $ANYTLS_PORT / 公网 ${ANYTLS_PUBLIC_PORT:-$ANYTLS_PORT}"; say "anytls://${PASSWORD}@${SERVER_IP}:${ANYTLS_PUBLIC_PORT:-$ANYTLS_PORT}/?sni=bing.com&insecure=1#${NODE_NAME}-AnyTLS"; fi; say "${CYAN}Reality:${RESET}"; say "vless://${UUID}@${SERVER_IP}:${REALITY_PUBLIC_PORT:-$REALITY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DEST_DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${NODE_NAME}-Reality"; say "${CYAN}Hysteria2:${RESET}"; say "hysteria2://${PASSWORD}@${SERVER_IP}:${HY2_PUBLIC_PORT:-$HY2_PORT}/?sni=bing.com&insecure=1#${NODE_NAME}-Hy2"; say "${CYAN}TUIC:${RESET}"; say "tuic://${UUID}:${PASSWORD}@${SERVER_IP}:${TUIC_PUBLIC_PORT:-$TUIC_PORT}/?sni=bing.com&alpn=h3&insecure=1#${NODE_NAME}-TUIC"; }

modify_ports(){ load || return 1; server_ip || return 1; local old_sub=$SUB_PORT; ask_port REALITY_PORT 'Reality 内部 TCP 端口' "$REALITY_PORT"; ask_port HY2_PORT 'Hy2 内部 UDP 端口' "$HY2_PORT"; ask_port TUIC_PORT 'TUIC 内部 UDP 端口' "$TUIC_PORT"; ask_port SUB_PORT '订阅内部 TCP 端口' "$SUB_PORT"; if [[ -n ${ANYTLS_PORT:-} ]]; then ask_port ANYTLS_PORT 'AnyTLS 内部 TCP 端口' "$ANYTLS_PORT"; ask_port ANYTLS_PUBLIC_PORT 'AnyTLS 公网 TCP 端口' "${ANYTLS_PUBLIC_PORT:-$ANYTLS_PORT}"; fi; ports_unique "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" "$SUB_PORT" "${ANYTLS_PORT:-}" || { err '内部端口重复'; return 1; }; ask_port REALITY_PUBLIC_PORT 'Reality 公网 TCP 端口' "${REALITY_PUBLIC_PORT:-$REALITY_PORT}"; ask_port HY2_PUBLIC_PORT 'Hy2 公网 UDP 端口' "${HY2_PUBLIC_PORT:-$HY2_PORT}"; ask_port TUIC_PUBLIC_PORT 'TUIC 公网 UDP 端口' "${TUIC_PUBLIC_PORT:-$TUIC_PORT}"; ask_port SUB_PUBLIC_PORT '订阅公网 TCP 端口' "${SUB_PUBLIC_PORT:-$SUB_PORT}"; backup; local tmp="$CONF.tmp"; jq --argjson r "$REALITY_PORT" --argjson h "$HY2_PORT" --argjson a "${ANYTLS_PORT:-0}" --argjson t "$TUIC_PORT" '(.inbounds[] | select(.type=="vless").listen_port)=$r | (.inbounds[] | select(.type=="hysteria2").listen_port)=$h | (.inbounds[] | select(.type=="tuic").listen_port)=$t | (.inbounds[] | select(.type=="anytls").listen_port)=$a' "$CONF" > "$tmp" && sing-box check -c "$tmp" || { rm -f "$tmp"; err '新配置校验失败'; return 1; }; mv -f "$tmp" "$CONF"; write_info; make_yaml; start_services && firewall_ports && view; }

add_anytls(){
  load || return 1
  if jq -e '.inbounds[] | select(.type=="anytls")' "$CONF" >/dev/null; then err '已存在 AnyTLS，请通过菜单 3 修改端口'; return 1; fi
  server_ip || return 1
  ask_port ANYTLS_PORT 'AnyTLS 内部 TCP 端口' 10005
  ports_unique "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" "$SUB_PORT" "$ANYTLS_PORT" || { err '内部端口重复'; return 1; }
  ask_port ANYTLS_PUBLIC_PORT 'AnyTLS 公网 TCP 端口（无 NAT 填相同端口）' "$ANYTLS_PORT"
  make_cert || return 1
  local tmp="$CONF.anytls.tmp" any
  any=$(anytls_json) || return 1
  jq --argjson any "$any" '.inbounds += [$any]' "$CONF" > "$tmp" || return 1
  sing-box check -c "$tmp" || { rm -f "$tmp"; err '配置校验失败，原配置未改动。AnyTLS 需要 sing-box 1.12.0 或更新版本，请先升级核心'; return 1; }
  backup
  cp -p "$CONF" "$CONF.before-anytls" || return 1
  mv -f "$tmp" "$CONF"; chmod 600 "$CONF"
  if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    cp -p "$CONF.before-anytls" "$CONF"; systemctl restart sing-box
    err '启动失败，已恢复原核心配置'; return 1
  fi
  write_info && make_yaml || return 1
  firewall_ports
  say 'AnyTLS 已添加，客户端请刷新订阅；云安全组/NAT 请放行对应 TCP 端口'
  view
}

change_name(){
  load || return 1
  server_ip || return 1
  local name
  read -r -p "新节点名称 [当前: ${NODE_NAME}]: " name
  # 去除首尾空格
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  if [[ -z $name ]]; then
    err '节点名称不能为空'
    return 1
  fi
  # 拦截引号、反斜杠、美元符、反引号及控制字符，防止破坏配置文件和 YAML 结构
  if [[ $name =~ [\"\'\\$\`] || $name =~ [[:cntrl:]] ]]; then
    err '名称不能包含引号、反斜杠、$ 或反引号等特殊符号'
    return 1
  fi
  NODE_NAME=$name
  write_info
  if make_yaml; then
    say "${GREEN}节点名称已更新为: ${NODE_NAME}，客户端请刷新订阅${RESET}"
  else
    err '更新订阅文件失败'
    return 1
  fi
}

change_token(){ load || return 1; server_ip || return 1; local token old=$SUB_TOKEN; read -r -p '新订阅文件名（英文数字下划线横线，不含 .yaml）: ' token; [[ $token =~ ^[a-zA-Z0-9_-]+$ ]] || { err '订阅名不合法'; return 1; }; SUB_TOKEN=$token; write_info; make_yaml; [[ $old == "$token" ]] || rm -f "$WEB/$old.yaml"; view; }
restart_all(){ systemctl restart sing-box singbox-sub && systemctl is-active --quiet sing-box && systemctl is-active --quiet singbox-sub && say '服务重启成功' || { err '重启失败'; journalctl -u sing-box -n 15 --no-pager; }; }
stop_all(){ systemctl stop sing-box singbox-sub && say '两个服务已停止'; }
status_logs(){ systemctl --no-pager --full status sing-box singbox-sub || true; say '---- Sing-box 最近日志 ----'; journalctl -u sing-box -n 30 --no-pager; say '---- 订阅最近日志 ----'; journalctl -u singbox-sub -n 15 --no-pager; }
uninstall_all(){ need_root; read -r -p '卸载会删除全部节点和订阅文件。输入 DELETE 确认: ' answer; [[ $answer == DELETE ]] || return; backup; systemctl disable --now sing-box singbox-sub >/dev/null 2>&1 || true; rm -rf "$DIR" "$WEB"; rm -f "$INFO" "$UNIT"; systemctl daemon-reload; say '已清理本脚本配置及订阅服务；保留 Sing-box 核心程序和脚本。'; }
setup_shortcuts(){ need_root; mkdir -p /usr/local/bin; if [[ -f $0 && $(readlink -f -- "$0") != "$SELF" ]]; then cp -f -- "$0" "$SELF" || return 1; fi; chmod +x "$SELF"; ln -sfn "$SELF" /usr/local/bin/sb; ln -sfn "$SELF" /usr/local/bin/singbox; }
bbr_status(){ say "当前内核: $(uname -r)"; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true; say '可用 TCP 拥塞算法:'; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true; }
bbr_enable(){ need_root; if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then modprobe tcp_bbr 2>/dev/null || true; fi; if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then err '当前内核不支持 BBR，请勿强行启用'; return 1; fi; mkdir -p /etc/sysctl.d; local target=/etc/sysctl.d/99-singbox-bbr.conf; if [[ -f $target ]]; then cp -p "$target" "${target}.bak.$(date +%Y%m%d%H%M%S)"; fi; printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$target" || return 1; sysctl -w net.core.default_qdisc=fq || return 1; sysctl -w net.ipv4.tcp_congestion_control=bbr || return 1; if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr && $(sysctl -n net.core.default_qdisc) == fq ]]; then say "${GREEN}BBR + fq 已启用并写入持久化配置${RESET}"; else err '参数验证失败'; return 1; fi; say '注意：其他 sysctl 文件可能覆盖这些参数；重启后可再次检查。'; }
bbr_menu(){ local choice; while :; do say '=== BBR 网络优化 ==='; say '1. 一键开启 BBR + fq'; say '2. 查看 BBR 状态'; say '0. 返回主菜单'; read -r -p '请选择: ' choice || return; case $choice in 1) bbr_enable;; 2) bbr_status;; 0) return;; *) err '无效选项';; esac; done; }

main(){
  need_root
  setup_shortcuts || { err '创建快捷命令失败'; exit 1; }
  while :; do
    say "${CYAN}==============================================${RESET}"
    say "${GREEN} Sing-box 四合一管理 V3 | Reality + Hy2 + TUIC + AnyTLS${RESET}"
    say ' 1. 安装 / 重装（支持 NAT）'
    say ' 2. 查看节点及 Clash 订阅'
    say ' 3. 修改端口'
    say ' 4. 修改节点名称'
    say ' 5. 修改订阅文件名'
    say ' 6. 重启服务'
    say ' 7. 停止服务'
    say ' 8. 卸载配置'
    say ' 9. 查看状态和日志'
    say '10. BBR 一键优化 / 查看状态'
    say '11. 给现有安装添加 AnyTLS（保留原节点）'
    say ' 0. 退出'
    if systemctl is-active --quiet sing-box; then say "核心: ${GREEN}运行中${RESET}"; else say "核心: ${RED}未运行${RESET}"; fi
    if systemctl is-active --quiet singbox-sub; then say "订阅: ${GREEN}运行中${RESET}"; else say "订阅: ${RED}未运行${RESET}"; fi
    read -r -p '请选择 [0-11]: ' choice || exit 0
    case $choice in
      1) install_all;;
      2) view;;
      3) modify_ports;;
      4) change_name;;
      5) change_token;;
      6) restart_all;;
      7) stop_all;;
      8) uninstall_all;;
      9) status_logs;;
      10) bbr_menu;;
      11) add_anytls;;
      0) exit 0;;
      *) err '无效选项';;
    esac
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
