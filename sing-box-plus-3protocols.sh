#!/usr/bin/env bash
# ============================================================
#  Sing-Box-Plus Lite 3 Protocols (No WARP)
#  Protocols: Hysteria2+OBFS salamander / VLESS TLS TCP / Trojan TLS TCP
#  Target: Debian / Alpine / low-memory Docker (~96MB)
# ============================================================
set -Eeuo pipefail

SCRIPT_NAME="sing-box-plus-3protocols"
SCRIPT_VERSION="v1.3.0-3protocols-sb1.8.14-ipv4"
SB_VERSION="${SB_VERSION:-1.8.14}"
SB_DIR="${SB_DIR:-/etc/sing-box}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/sing-box}"
CONF_JSON="$SB_DIR/config.json"
ENV_FILE="$SB_DIR/lite.env"
CERT_DIR="$SB_DIR/cert"
LOG_FILE="$SB_DIR/sing-box.log"
PID_FILE="$SB_DIR/sing-box.pid"
SERVICE_NAME="sing-box.service"
SYSCTL_FILE="/etc/sysctl.d/99-sing-box-plus-performance.conf"
REALITY_SERVER="${REALITY_SERVER:-gateway.icloud.com}"
REALITY_SERVER_PORT="${REALITY_SERVER_PORT:-443}"
LISTEN_ADDR="${LISTEN_ADDR:-::}"

C_RESET='\033[0m'; C_GREEN='\033[32m'; C_RED='\033[31m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_YELLOW='\033[33m'
ok(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
info(){ echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err(){ echo -e "${C_RED}[ERR]${C_RESET} $*"; }
die(){ err "$*"; exit 1; }

need_root(){ [ "$(id -u)" = 0 ] || die "请用 root 运行"; }
has(){ command -v "$1" >/dev/null 2>&1; }
mkdirs(){ mkdir -p "$SB_DIR" "$CERT_DIR"; }

pm_install(){
  if has apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends ca-certificates curl wget tar gzip openssl iproute2 procps jq python3 >/dev/null 2>&1 || true
  elif has apk; then
    apk add --no-cache ca-certificates curl wget tar gzip openssl iproute2 procps jq python3 >/dev/null 2>&1 || true
  else
    warn "未识别包管理器，跳过依赖安装；需要 ca-certificates curl/wget tar gzip openssl"
  fi
  update-ca-certificates >/dev/null 2>&1 || true
}

arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64;;
    aarch64|arm64) echo arm64;;
    armv7l|armv7) echo armv7;;
    i386|i686) echo 386;;
    *) echo amd64;;
  esac
}

dl(){
  local url="$1" out="$2"
  if has curl; then curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
  elif has wget; then wget -O "$out" "$url"
  else return 1; fi
}

install_singbox(){
  if [ -x "$BIN_PATH" ] && "$BIN_PATH" version 2>/dev/null | grep -q "sing-box version $SB_VERSION"; then
    ok "已存在: $($BIN_PATH version | head -n1)"
    return 0
  fi
  local a tmp url pkg bin
  a="$(arch)"; tmp="$(mktemp -d)"; pkg="$tmp/sing-box.tgz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${a}.tar.gz"
  info "下载固定版本 sing-box v${SB_VERSION} linux-$a ..."
  dl "$url" "$pkg" || die "下载 sing-box 失败: $url"
  tar -xzf "$pkg" -C "$tmp" || die "解压失败"
  bin="$(find "$tmp" -type f -name sing-box | head -n1)"
  [ -n "$bin" ] || die "未找到 sing-box 二进制"
  install -m 0755 "$bin" "$BIN_PATH"
  rm -rf "$tmp"
  ok "安装完成: $($BIN_PATH version | head -n1)"
}

rand_hex(){ openssl rand -hex "${1:-8}"; }
rand_b64(){ openssl rand -base64 "${1:-24}" | tr -d '\n=+/ ' | cut -c1-32; }
gen_port(){ shuf -i 20000-55000 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(20000+rand()*35000)}'; }
new_uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || "$BIN_PATH" generate uuid 2>/dev/null || uuidgen 2>/dev/null; }
b64url(){ openssl rand -base64 18 | tr '+/' '-_' | tr -d '=\n'; }

load_env(){ [ -f "$ENV_FILE" ] && . "$ENV_FILE" || true; }
save_env(){
  umask 077
  cat > "$ENV_FILE" <<EOF
UUID='$UUID'
PORT_HY2_OBFS='$PORT_HY2_OBFS'
PORT_VLESS_TLS='$PORT_VLESS_TLS'
PORT_TROJAN_TLS='$PORT_TROJAN_TLS'
HY2_PWD='$HY2_PWD'
HY2_OBFS_PWD='$HY2_OBFS_PWD'
TROJAN_PWD='$TROJAN_PWD'
EOF
}

ensure_vars(){
  load_env
  [ -n "${UUID:-}" ] || UUID="$(new_uuid)"
  [ -n "${PORT_HY2_OBFS:-}" ] || PORT_HY2_OBFS="$(gen_port)"
  [ -n "${PORT_VLESS_TLS:-}" ] || PORT_VLESS_TLS="$(gen_port)"
  [ -n "${PORT_TROJAN_TLS:-}" ] || PORT_TROJAN_TLS="$(gen_port)"
  while [ "$PORT_VLESS_TLS" = "$PORT_HY2_OBFS" ] || [ "$PORT_TROJAN_TLS" = "$PORT_HY2_OBFS" ] || [ "$PORT_TROJAN_TLS" = "$PORT_VLESS_TLS" ]; do PORT_TROJAN_TLS="$(gen_port)"; done
  [ -n "${HY2_PWD:-}" ] || HY2_PWD="$(b64url)"
  [ -n "${HY2_OBFS_PWD:-}" ] || HY2_OBFS_PWD="$(b64url)"
  [ -n "${TROJAN_PWD:-}" ] || TROJAN_PWD="$(b64url)"
  save_env
}
mk_cert(){
  [ -s "$CERT_DIR/fullchain.pem" ] && [ -s "$CERT_DIR/key.pem" ] && return 0
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=$REALITY_SERVER" \
    -addext "subjectAltName=DNS:$REALITY_SERVER" >/dev/null 2>&1
}

write_config(){
  mkdirs; ensure_vars; mk_cert
  cat > "$CONF_JSON" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-obfs",
      "listen": "$LISTEN_ADDR",
      "listen_port": $PORT_HY2_OBFS,
      "users": [ { "name": "hy2", "password": "$HY2_PWD" } ],
      "obfs": { "type": "salamander", "password": "$HY2_OBFS_PWD" },
      "tls": { "enabled": true, "server_name": "$REALITY_SERVER", "certificate_path": "$CERT_DIR/fullchain.pem", "key_path": "$CERT_DIR/key.pem", "alpn": ["h3"] }
    },
    {
      "type": "vless",
      "tag": "vless-tls",
      "listen": "$LISTEN_ADDR",
      "listen_port": $PORT_VLESS_TLS,
      "users": [ { "uuid": "$UUID" } ],
      "tls": { "enabled": true, "server_name": "$REALITY_SERVER", "certificate_path": "$CERT_DIR/fullchain.pem", "key_path": "$CERT_DIR/key.pem" }
    },
    {
      "type": "trojan",
      "tag": "trojan-tls",
      "listen": "$LISTEN_ADDR",
      "listen_port": $PORT_TROJAN_TLS,
      "users": [ { "name": "trojan", "password": "$TROJAN_PWD" } ],
      "tls": { "enabled": true, "server_name": "$REALITY_SERVER", "certificate_path": "$CERT_DIR/fullchain.pem", "key_path": "$CERT_DIR/key.pem" }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct-ipv4", "domain_strategy": "ipv4_only" },
    { "type": "direct", "tag": "direct-ipv6", "domain_strategy": "ipv6_only" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_version": 4, "outbound": "direct-ipv4" },
      { "ip_version": 6, "outbound": "direct-ipv6" }
    ],
    "final": "direct-ipv4"
  }
}
EOF
}
public_ip4(){ curl -4 -fsSL https://api.ipify.org 2>/dev/null || wget -qO- https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }
fmt_host(){ case "$1" in *:*) printf '[%s]' "$1";; *) printf '%s' "$1";; esac; }
urlenc(){ python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null || printf '%s' "$1"; }
b64(){ printf '%s' "$1" | openssl base64 -A; }

print_links(){
  load_env; local ip host
  ip="${1:-}"; [ -n "$ip" ] || ip="$(public_ip4)"; host="$(fmt_host "$ip")"
  echo -e "${C_CYAN}${C_BOLD}分享链接（3 个，sing-box v${SB_VERSION}）${C_RESET}"
  echo "1) Hysteria2 + OBFS salamander"
  echo "hysteria2://$(urlenc "$HY2_PWD")@${host}:${PORT_HY2_OBFS}?security=tls&sni=${REALITY_SERVER}&insecure=1&allowInsecure=1&alpn=h3&obfs=salamander&obfs-password=$(urlenc "$HY2_OBFS_PWD")#hy2-obfs"
  echo "hy2://$(urlenc "$HY2_PWD")@${host}:${PORT_HY2_OBFS}?security=tls&sni=${REALITY_SERVER}&insecure=1&allowInsecure=1&alpn=h3&obfs=salamander&obfs-password=$(urlenc "$HY2_OBFS_PWD")#hy2-obfs"
  echo
  echo "2) VLESS TLS TCP"
  echo "vless://${UUID}@${host}:${PORT_VLESS_TLS}?encryption=none&security=tls&sni=${REALITY_SERVER}&allowInsecure=1&type=tcp#vless-tls"
  echo
  echo "3) Trojan TLS TCP"
  echo "trojan://$(urlenc "$TROJAN_PWD")@${host}:${PORT_TROJAN_TLS}?security=tls&sni=${REALITY_SERVER}&allowInsecure=1&type=tcp#trojan-tls"
}
open_firewall(){
  # Docker/Alpine 通常无防火墙；有 ufw/firewalld/iptables 则尽量放行，失败不影响。
  for item in "$PORT_HY2_OBFS/udp" "$PORT_VLESS_TLS/tcp" "$PORT_TROJAN_TLS/tcp"; do
    local p="${item%/*}" proto="${item#*/}"
    if has ufw && ufw status 2>/dev/null | grep -qi active; then ufw allow "$item" >/dev/null 2>&1 || true; fi
    if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$item" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
    if has iptables; then iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true; fi
  done
}

write_systemd(){
  has systemctl || return 1
  cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=sing-box plus 3 protocols no WARP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONF_JSON -D $SB_DIR
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

start_service(){
  if has systemctl && [ -d /run/systemd/system ]; then
    write_systemd || true
    systemctl restart "$SERVICE_NAME" || die "systemd 启动失败，可手动运行: $BIN_PATH run -c $CONF_JSON"
  else
    [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" >/dev/null 2>&1 || true
    nohup "$BIN_PATH" run -c "$CONF_JSON" -D "$SB_DIR" >>"$LOG_FILE" 2>&1 & echo $! > "$PID_FILE"
    sleep 1
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || { tail -80 "$LOG_FILE" 2>/dev/null || true; die "前台/容器模式启动失败"; }
    ok "已用后台模式启动 PID=$(cat "$PID_FILE")，日志: $LOG_FILE"
  fi
}

stop_service(){
  if has systemctl && [ -d /run/systemd/system ]; then systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
  [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" >/dev/null 2>&1 || true
}

status(){
  if has systemctl && [ -d /run/systemd/system ]; then systemctl --no-pager status "$SERVICE_NAME" | sed -n '1,12p' || true
  elif [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then echo "running pid=$(cat "$PID_FILE")"
  else echo "not running"; fi
}

network_report(){
  echo "== sing-box =="
  "$BIN_PATH" version 2>/dev/null | head -n1 || true
  status
  echo
  echo "== TCP tuning =="
  printf 'available congestion controls: '; sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  printf 'active congestion control: '; sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
  printf 'default qdisc: '; sysctl -n net.core.default_qdisc 2>/dev/null || true
  printf 'MTU probing: '; sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true
  echo
  echo "== Listening ports =="
  ss -lntup 2>/dev/null | grep -E "(${PORT_HY2_OBFS:-0}|${PORT_VLESS_TLS:-0}|${PORT_TROJAN_TLS:-0})" || true
  echo
  echo "提示：VLESS TLS TCP 不会绕过服务器带宽、国际线路拥塞或 TCP 丢包。测速请分别测试 VLESS 与 HY2；若 HY2 明显更快，通常是 TCP 丢包/拥塞，而不是 VLESS 配置错误。"
}

tune_network(){
  need_root
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! printf '%s\n' "$available" | tr ' ' '\n' | grep -qx 'bbr'; then
    warn "当前内核未提供 BBR（可用：${available:-unknown}），未写入调优。请升级/更换支持 BBR 的内核后重试。"
    return 1
  fi
  cat > "$SYSCTL_FILE" <<'EOF'
# Sing-Box TCP throughput tuning. Applies to VLESS/Trojan TCP, not a bandwidth cap.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
EOF
  sysctl --system >/dev/null || die "应用内核网络参数失败"
  ok "已启用 FQ + BBR，并开启 MTU 探测和 TCP Fast Open"
  network_report
}

rotate_ports(){
  load_env
  PORT_HY2_OBFS="$(gen_port)"; PORT_VLESS_TLS="$(gen_port)"; PORT_TROJAN_TLS="$(gen_port)"
  while [ "$PORT_VLESS_TLS" = "$PORT_HY2_OBFS" ] || [ "$PORT_TROJAN_TLS" = "$PORT_HY2_OBFS" ] || [ "$PORT_TROJAN_TLS" = "$PORT_VLESS_TLS" ]; do PORT_TROJAN_TLS="$(gen_port)"; done
  save_env; write_config; open_firewall; start_service; print_links
}

uninstall_all(){
  stop_service
  if has systemctl; then systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/$SERVICE_NAME"; systemctl daemon-reload >/dev/null 2>&1 || true; fi
  rm -rf "$SB_DIR"
  ok "已卸载配置与服务；sing-box 二进制保留在 $BIN_PATH"
}

deploy(){
  need_root; mkdirs; pm_install; install_singbox; write_config
  "$BIN_PATH" check -c "$CONF_JSON" || die "配置检查失败"
  open_firewall; start_service
  ok "部署完成：HY2+OBFS / VLESS TLS / Trojan TLS，sing-box 固定版本"
  print_links
}

menu(){
  clear 2>/dev/null || true
  echo -e "${C_CYAN}${C_BOLD}$SCRIPT_NAME $SCRIPT_VERSION${C_RESET}"
  echo "1) 安装/部署（HY2+OBFS / VLESS TLS / Trojan TLS）"
  echo "2) 查看分享链接"
  echo "3) 重启服务"
  echo "4) 更换端口"
  echo "5) 查看状态"
  echo "6) 网络诊断（查看 BBR/FQ、端口与服务状态）"
  echo "7) 启用 TCP 性能调优（FQ + BBR）"
  echo "8) 卸载"
  echo "0) 退出"
  read -rp "选择: " op || true
  case "${op:-}" in
    1) deploy;;
    2) load_env; print_links;;
    3) write_config; start_service;;
    4) rotate_ports;;
    5) status;;
    6) load_env; network_report;;
    7) tune_network;;
    8) uninstall_all;;
    0) exit 0;;
    *) deploy;;
  esac
}

case "${1:-menu}" in
  install|deploy) deploy;;
  links) load_env; print_links "${2:-}";;
  restart) write_config; start_service;;
  stop) stop_service;;
  status) status;;
  diagnose) load_env; network_report;;
  tune) tune_network;;
  rotate) rotate_ports;;
  uninstall) uninstall_all;;
  *) menu;;
esac
