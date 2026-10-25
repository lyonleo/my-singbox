    local dest="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest"
    [[ ! -e $BASE ]] || cp -a "$BASE" "$dest/"
    [[ ! -e /etc/systemd/system/$SERVICE ]] || cp -a "/etc/systemd/system/$SERVICE" "$dest/"
    msg "旧配置备份：$dest"
  fi
}
load(){ [[ -f $STATE && -f $CFG ]] || { err '未发现本脚本的完整安装记录'; return 1; }; source "$STATE"; }
write_state(){
  # 用 printf %q 转义变量，防止 source 时执行特殊字符
  { local key; for key in SERVER_IP REALITY_PORT HY2_PORT TUIC_PORT SUB_PORT UUID PASSWORD PRIVATE_KEY PUBLIC_KEY SHORT_ID SUB_TOKEN NODE_NAME DEST_DOMAIN; do printf '%s=%q\n' "$key" "${!key}"; done; } > "$STATE"
  chmod 600 "$STATE"
}
write_config(){
  mkdir -p "$BASE" "$CERT" "$SUB"
  jq -n --arg uuid "$UUID" --arg pw "$PASSWORD" --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg dest "$DEST_DOMAIN" --arg cert "$CERT/cert.pem" --arg key "$CERT/private.key" --argjson rp "$REALITY_PORT" --argjson hp "$HY2_PORT" --argjson tp "$TUIC_PORT" '{log:{level:"warn"},inbounds:[{type:"vless",tag:"reality",listen:"::",listen_port:$rp,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$dest,reality:{enabled:true,handshake:{server:$dest,server_port:443},private_key:$pk,short_id:[$sid]}}},{type:"hysteria2",tag:"hy2",listen:"::",listen_port:$hp,users:[{password:$pw}],tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}},{type:"tuic",tag:"tuic",listen:"::",listen_port:$tp,users:[{uuid:$uuid,password:$pw}],congestion_control:"cubic",tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}]}' > "$CFG.new"
  sing-box check -c "$CFG.new" || { rm -f "$CFG.new"; fail '核心配置校验失败，原配置未覆盖'; }
  mv -f "$CFG.new" "$CFG"
  chmod 600 "$CFG"
}
write_sub(){
  local file="$SUB/$SUB_TOKEN.yaml"
  jq -n --arg ip "$SERVER_IP" --arg uuid "$UUID" --arg pw "$PASSWORD" --arg pub "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg dest "$DEST_DOMAIN" --arg name "$NODE_NAME" --argjson rp "$REALITY_PORT" --argjson hp "$HY2_PORT" --argjson tp "$TUIC_PORT" '{"mixed-port":7890,"allow-lan":false,mode:"rule",proxies:[{name:($name+"-Reality"),type:"vless",server:$ip,port:$rp,uuid:$uuid,network:"tcp",tls:true,flow:"xtls-rprx-vision",servername:$dest,"reality-opts":{"public-key":$pub,"short-id":$sid},"client-fingerprint":"chrome"},{name:($name+"-Hy2"),type:"hysteria2",server:$ip,port:$hp,password:$pw,sni:"singbox.local","skip-cert-verify":true},{name:($name+"-TUIC"),type:"tuic",server:$ip,port:$tp,uuid:$uuid,password:$pw,sni:"singbox.local",alpn:["h3"],"skip-cert-verify":true,"congestion-controller":"cubic"}],"proxy-groups":[{name:"PROXY",type:"select",proxies:["AUTO",($name+"-Reality"),($name+"-Hy2"),($name+"-TUIC"),"DIRECT"]},{name:"AUTO",type:"url-test",url:"https://www.gstatic.com/generate_204",interval:300,proxies:[($name+"-Reality"),($name+"-Hy2"),($name+"-TUIC")]}],rules:["MATCH,PROXY"]}' > "$file"
  chmod 600 "$file"
}
write_sub_service(){
  cat > /etc/systemd/system/$SERVICE <<EOF
[Unit]
Description=Sing-box local subscription server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$SUB
ExecStart=/usr/bin/python3 -m http.server $SUB_PORT --bind 0.0.0.0 --directory $SUB
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=$SUB
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
start_all(){
  systemctl enable sing-box.service "$SERVICE" >/dev/null
  systemctl restart sing-box.service
  systemctl restart "$SERVICE"
  if ! systemctl is-active --quiet sing-box.service; then journalctl -u sing-box.service -n 30 --no-pager; fail 'Sing-box 启动失败'; fi
  if ! systemctl is-active --quiet "$SERVICE"; then journalctl -u "$SERVICE" -n 30 --no-pager; fail '订阅服务启动失败'; fi
  msg '核心和订阅服务均运行中'
}
install_core(){
  msg '从 Sing-box 官方安装脚本安装核心（请确认你信任 sing-box.app）'
  local tmp; tmp=$(mktemp)
  curl -fL --retry 2 --max-time 60 https://sing-box.app/install.sh -o "$tmp"
  bash "$tmp"; rm -f "$tmp"
  command -v sing-box >/dev/null || fail '核心安装后找不到 sing-box'
  sing-box version | head -n 2
}
install_all(){
  if [[ -f $CFG ]]; then
    read -rp '检测到现有配置。将备份并覆盖节点配置，继续？[输入 YES]: ' answer
    [[ $answer == YES ]] || return
  fi
  install_deps; backup; install_core; server_ip
  UUID=$(sing-box generate uuid)
  PASSWORD=$(openssl rand -hex 16)
  SUB_TOKEN=$(openssl rand -hex 16)
  SHORT_ID=$(openssl rand -hex 8)
  NODE_NAME=Singbox-Node
  DEST_DOMAIN=www.apple.com
  local keys
  keys=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*//p; s/^[[:space:]]*PrivateKey[[:space:]]*:[[:space:]]*//p; s/^[[:space:]]*PrivateKey[[:space:]]+//p' | head -n1)
  PUBLIC_KEY=$(printf '%s\n' "$keys" | sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*//p; s/^[[:space:]]*PublicKey[[:space:]]*:[[:space:]]*//p; s/^[[:space:]]*PublicKey[[:space:]]+//p' | head -n1)
  [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || fail "Reality 密钥解析失败，实际输出：$keys"
  REALITY_PORT=41001; HY2_PORT=46001; TUIC_PORT=51001; SUB_PORT=21001
  msg '独立 VPS 可以使用默认端口；NAT VPS 请输入服务商分配的内部监听端口。'
  ask_port REALITY_PORT "$REALITY_PORT"; ask_port HY2_PORT "$HY2_PORT"; ask_port TUIC_PORT "$TUIC_PORT"; ask_port SUB_PORT "$SUB_PORT"; check_ports
  mkdir -p "$CERT"; chmod 700 "$CERT"
  if [[ ! -f $CERT/cert.pem || ! -f $CERT/private.key ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$CERT/private.key" -out "$CERT/cert.pem" -days 365 -subj '/CN=singbox.local' -addext 'subjectAltName=DNS:singbox.local' >/dev/null 2>&1
  fi
  write_config; write_state; write_sub; write_sub_service; start_all
  msg '安装完成。请在云平台防火墙放行 Reality TCP、Hy2/TUIC UDP、订阅 TCP 端口。'
  show_info
}
show_info(){
  load || return
  printf '\n服务器：%s\nReality TCP: %s\nHy2 UDP: %s\nTUIC UDP: %s\n订阅 TCP: %s\n' "$SERVER_IP" "$REALITY_PORT" "$HY2_PORT" "$TUIC_PORT" "$SUB_PORT"
  printf 'Clash 订阅（HTTP 明文，含敏感凭证）：http://%s:%s/%s.yaml\n' "$SERVER_IP" "$SUB_PORT" "$SUB_TOKEN"
  printf 'Reality：vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&flow=xtls-rprx-vision#%s-Reality\n' "$UUID" "$SERVER_IP" "$REALITY_PORT" "$PUBLIC_KEY" "$DEST_DOMAIN" "$SHORT_ID" "$NODE_NAME"
  printf 'Hy2：hysteria2://%s@%s:%s/?sni=singbox.local&insecure=1#%s-Hy2\n' "$PASSWORD" "$SERVER_IP" "$HY2_PORT" "$NODE_NAME"
  printf 'TUIC：tuic://%s:%s@%s:%s/?sni=singbox.local&alpn=h3&insecure=1&congestion_control=cubic#%s-TUIC\n' "$UUID" "$PASSWORD" "$SERVER_IP" "$TUIC_PORT" "$NODE_NAME"
  err '以上链接包含敏感凭证，请勿公开分享。订阅 HTTP 明文仅建议临时使用，正式部署请改为 HTTPS。'
}
change_ports(){
  load || return
  ask_port REALITY_PORT "$REALITY_PORT"; ask_port HY2_PORT "$HY2_PORT"; ask_port TUIC_PORT "$TUIC_PORT"; ask_port SUB_PORT "$SUB_PORT"; check_ports
  backup; write_config; write_state; write_sub; write_sub_service; start_all
}
change_name(){ load || return; local n; read -rp '新节点名称（只允许字母、数字、_、-）: ' n; [[ $n =~ ^[a-zA-Z0-9_-]+$ ]] || { err '名称不合法'; return; }; NODE_NAME=$n; write_state; write_sub; msg '已更新，请刷新订阅'; }
change_token(){ load || return; local old=$SUB_TOKEN; SUB_TOKEN=$(openssl rand -hex 16); write_state; write_sub; rm -f "$SUB/$old.yaml"; msg '已轮换订阅 token'; show_info; }
status(){ systemctl --no-pager --full status sing-box.service "$SERVICE" || true; }
logs(){ journalctl -u sing-box.service -u "$SERVICE" -n 80 --no-pager; }
uninstall_all(){
  read -rp '将停止服务并删除本脚本配置与订阅，输入 DELETE 确认：' ans
  [[ $ans == DELETE ]] || return
  backup
  systemctl disable --now sing-box.service "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE"
  rm -rf "$BASE" "$SUB"
  systemctl daemon-reload
  msg '已清理本脚本配置和订阅，保留 sing-box 核心二进制及安装包。'
}
while :; do
  printf '\n==== Sing-box 三合一管理 V2 ====\n1 安装/重装（备份旧配置）\n2 查看节点和订阅\n3 修改端口\n4 修改节点名称\n5 更换订阅令牌\n6 重启服务\n7 查看状态\n8 查看日志\n9 停止服务\n10 卸载配置\n0 退出\n'
  read -rp '请选择: ' choice || exit 0
  case "$choice" in
    1) install_all;; 2) show_info;; 3) change_ports;; 4) change_name;; 5) change_token;;
    6) systemctl restart sing-box.service "$SERVICE" && msg '重启命令执行完成' && status;;
    7) status;; 8) logs;; 9) systemctl stop sing-box.service "$SERVICE";; 10) uninstall_all;; 0) exit 0;; *) err '无效选项';;
  esac
done
