#!/usr/bin/env bash
# Sing-Box-Plus standalone SOCKS5 server (IPv4 outbound)
set -Eeuo pipefail

SCRIPT_NAME="sing-box-plus-socks5"
SCRIPT_VERSION="v1.0.0-socks5-ipv4"
SB_VERSION="${SB_VERSION:-1.8.14}"
SB_DIR="${SB_DIR:-/etc/sing-box-socks5}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/sing-box}"
CONF_JSON="$SB_DIR/config.json"
ENV_FILE="$SB_DIR/socks5.env"
LOG_FILE="$SB_DIR/sing-box.log"
PID_FILE="$SB_DIR/sing-box.pid"
SERVICE_NAME="sing-box-socks5.service"
SYSCTL_FILE="/etc/sysctl.d/99-sing-box-socks5-performance.conf"
LISTEN_ADDR="${LISTEN_ADDR:-::}"

C_RESET='\033[0m'; C_GREEN='\033[32m'; C_RED='\033[31m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_YELLOW='\033[33m'
ok(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
info(){ echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err(){ echo -e "${C_RED}[ERR]${C_RESET} $*"; }
die(){ err "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "$(id -u)" = 0 ] || die "请用 root 运行"; }

pm_install(){
  if has apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends ca-certificates curl wget tar gzip openssl iproute2 procps >/dev/null 2>&1 || true
  elif has apk; then
    apk add --no-cache ca-certificates curl wget tar gzip openssl iproute2 procps >/dev/null 2>&1 || true
  else
    warn "未识别包管理器，跳过依赖安装"
  fi
  update-ca-certificates >/dev/null 2>&1 || true
}

arch(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l|armv7) echo armv7;; i386|i686) echo 386;; *) die "不支持的架构: $(uname -m)";; esac; }
dl(){ if has curl; then curl -4 -fL --retry 3 --connect-timeout 15 -o "$2" "$1"; else wget -4 -O "$2" "$1"; fi; }
install_singbox(){
  if [ -x "$BIN_PATH" ] && "$BIN_PATH" version 2>/dev/null | grep -q "sing-box version $SB_VERSION"; then ok "已存在: $($BIN_PATH version | head -n1)"; return; fi
  local tmp pkg bin a
  a="$(arch)"; tmp="$(mktemp -d)"; pkg="$tmp/sing-box.tgz"
  info "下载 sing-box v${SB_VERSION} linux-$a ..."
  dl "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${a}.tar.gz" "$pkg" || die "下载 sing-box 失败"
  tar -xzf "$pkg" -C "$tmp" || die "解压失败"
  bin="$(find "$tmp" -type f -name sing-box | head -n1)"; [ -n "$bin" ] || die "未找到 sing-box 二进制"
  install -m 0755 "$bin" "$BIN_PATH"; rm -rf "$tmp"; ok "安装完成: $($BIN_PATH version | head -n1)"
}

gen_port(){ shuf -i 20000-55000 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(20000+rand()*35000)}'; }
rand_credential(){ openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-28; }
urlenc(){ python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null || printf '%s' "$1"; }
public_ip4(){ curl -4 -fsSL https://api.ipify.org 2>/dev/null || wget -4 -qO- https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }
fmt_host(){ case "$1" in *:*) printf '[%s]' "$1";; *) printf '%s' "$1";; esac; }
load_env(){ [ -f "$ENV_FILE" ] && . "$ENV_FILE" || true; }
save_env(){ umask 077; mkdir -p "$SB_DIR"; cat > "$ENV_FILE" <<EOF
SOCKS_PORT='$SOCKS_PORT'
SOCKS_USER='$SOCKS_USER'
SOCKS_PASS='$SOCKS_PASS'
EOF
}
ensure_vars(){ load_env; [ -n "${SOCKS_PORT:-}" ] || SOCKS_PORT="$(gen_port)"; [ -n "${SOCKS_USER:-}" ] || SOCKS_USER="socks$(rand_credential | cut -c1-10)"; [ -n "${SOCKS_PASS:-}" ] || SOCKS_PASS="$(rand_credential)"; save_env; }

write_config(){
  ensure_vars
  cat > "$CONF_JSON" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "$LISTEN_ADDR",
      "listen_port": $SOCKS_PORT,
      "users": [ { "username": "$SOCKS_USER", "password": "$SOCKS_PASS" } ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct-ipv4", "domain_strategy": "ipv4_only" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "final": "direct-ipv4" }
}
EOF
}

open_firewall(){
  if has ufw && ufw status 2>/dev/null | grep -qi active; then ufw allow "$SOCKS_PORT/tcp" >/dev/null 2>&1 || true; fi
  if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$SOCKS_PORT/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
  if has iptables; then iptables -C INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || true; fi
}
write_systemd(){
  has systemctl || return 1
  cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=Sing-Box standalone SOCKS5 server
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
  systemctl daemon-reload >/dev/null 2>&1 || true; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}
start_service(){
  if has systemctl && [ -d /run/systemd/system ]; then write_systemd; systemctl restart "$SERVICE_NAME" || die "systemd 启动失败";
  else
    [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" >/dev/null 2>&1 || true
    nohup "$BIN_PATH" run -c "$CONF_JSON" -D "$SB_DIR" >>"$LOG_FILE" 2>&1 & echo $! > "$PID_FILE"; sleep 1
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || { tail -80 "$LOG_FILE" 2>/dev/null || true; die "启动失败"; }
  fi
}
stop_service(){ if has systemctl && [ -d /run/systemd/system ]; then systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; fi; [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" >/dev/null 2>&1 || true; }
status(){ if has systemctl && [ -d /run/systemd/system ]; then systemctl --no-pager status "$SERVICE_NAME" | sed -n '1,12p' || true; elif [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then echo "running pid=$(cat "$PID_FILE")"; else echo "not running"; fi; }
print_link(){ load_env; local ip host; ip="${1:-$(public_ip4)}"; host="$(fmt_host "$ip")"; echo -e "${C_CYAN}${C_BOLD}SOCKS5 分享链接${C_RESET}"; echo "socks5://$(urlenc "$SOCKS_USER"):$(urlenc "$SOCKS_PASS")@${host}:${SOCKS_PORT}#socks5-ipv4"; }

tune_network(){
  local cc; cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  printf '%s\n' "$cc" | tr ' ' '\n' | grep -qx bbr || { warn "当前内核不支持 BBR（${cc:-unknown}）"; return 1; }
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
EOF
  sysctl --system >/dev/null || die "应用网络参数失败"; ok "已启用 FQ + BBR"
}
deploy(){ need_root; mkdir -p "$SB_DIR"; pm_install; install_singbox; write_config; "$BIN_PATH" check -c "$CONF_JSON" || die "配置检查失败"; open_firewall; start_service; ok "SOCKS5 部署完成，出站强制 IPv4"; print_link; }
rotate(){ load_env; SOCKS_PORT="$(gen_port)"; save_env; write_config; "$BIN_PATH" check -c "$CONF_JSON" || die "配置检查失败"; open_firewall; start_service; print_link; }
uninstall_all(){ stop_service; if has systemctl; then systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/$SERVICE_NAME"; systemctl daemon-reload >/dev/null 2>&1 || true; fi; rm -rf "$SB_DIR"; ok "已卸载 SOCKS5 服务和配置；保留 sing-box 二进制"; }
menu(){
  clear 2>/dev/null || true; echo -e "${C_CYAN}${C_BOLD}$SCRIPT_NAME $SCRIPT_VERSION${C_RESET}"
  echo "1) 安装/部署 SOCKS5"; echo "2) 查看分享链接"; echo "3) 重启服务"; echo "4) 更换端口"; echo "5) 查看状态"; echo "6) 启用 TCP 性能调优（FQ + BBR）"; echo "7) 卸载"; echo "0) 退出"
  read -rp "选择: " op || true
  case "${op:-}" in 1) deploy;; 2) print_link;; 3) write_config; start_service;; 4) rotate;; 5) status;; 6) tune_network;; 7) uninstall_all;; 0) exit 0;; *) deploy;; esac
}
case "${1:-menu}" in install|deploy) deploy;; links) print_link "${2:-}";; restart) write_config; start_service;; stop) stop_service;; status) status;; tune) tune_network;; rotate) rotate;; uninstall) uninstall_all;; *) menu;; esac
