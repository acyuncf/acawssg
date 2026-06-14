#!/bin/bash
set -Eeuo pipefail

LOG_FILE="/var/log/v2node_init.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
echo "[INFO] $*"
}

warn() {
echo "[WARN] $*"
}

error() {
echo "[ERROR] $*"
}

log "脚本启动时间: $(date)"

# === 1. 自动安装 unzip、zip、socat、curl、wget、pv ===

log "安装 unzip/zip/socat/curl/wget/pv..."

if command -v apt-get >/dev/null 2>&1; then
apt-get update -y
for i in {1..5}; do
apt-get install -y unzip zip socat curl wget ca-certificates pv && break
warn "apt 被锁定或失败，等待重试...($i/5)"
sleep 5
done
elif command -v yum >/dev/null 2>&1; then
yum install -y epel-release || true
yum install -y unzip zip socat curl wget ca-certificates pv
elif command -v dnf >/dev/null 2>&1; then
dnf install -y epel-release || true
dnf install -y unzip zip socat curl wget ca-certificates pv
elif command -v apk >/dev/null 2>&1; then
apk update
apk add --no-cache unzip zip socat curl wget ca-certificates pv bash
else
error "未知的包管理器，无法自动安装必需依赖"
exit 1
fi

# === 2. 安装哪吒 Agent，设置每 60 秒上报 ===

log "安装哪吒 Agent..."

cd /root || exit 1
rm -f nezha.sh

curl -L https://raw.githubusercontent.com/acyuncf/acawsjp/refs/heads/main/nezha.sh -o nezha.sh
chmod +x nezha.sh

./nezha.sh install_agent 65.109.75.122 5555 SjhrynJdRaR4S2pCUE -u 60

# === 3. 安装 nyanpass 客户端 ===

log "安装 nyanpass 客户端..."

S=nyanpass OPTIMIZE=1 bash <(curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh) rel_nodeclient "-o -t e1fa8b04-f707-41d6-b443-326a0947fa2f -u https://ny.321337.xyz"

# === 5. 创建 TCP 端口转发脚本 ===

log "创建 TCP 端口转发脚本..."

install -d -m 755 /usr/local/bin

cat >/usr/local/bin/port_forward_env.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:?missing PORT}"
TARGET_HOST="${TARGET_HOST:?missing TARGET_HOST}"
TARGET_PORT="${TARGET_PORT:?missing TARGET_PORT}"

echo "[INFO] socat $(date) 0.0.0.0:${PORT} => ${TARGET_HOST}:${TARGET_PORT}"

exec socat -d -d 
TCP-LISTEN:${PORT},reuseaddr,fork,nodelay,keepalive 
TCP:${TARGET_HOST}:${TARGET_PORT},nodelay,keepalive
EOF

chmod +x /usr/local/bin/port_forward_env.sh

# === 6. 创建 systemd 端口转发模板服务 ===

log "创建 [port-forward@.service](mailto:port-forward@.service) 模板..."

cat >/etc/systemd/system/port-forward@.service <<'EOF'
[Unit]
Description=TCP Forward 0.0.0.0:%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/port-forward/%i.env
ExecStart=/usr/local/bin/port_forward_env.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# === 7. 批量配置端口转发 ===

log "配置端口转发..."

declare -a MAPS=(
"31725 gb1.acyun.eu.org 15657"
"32265 tr.acyun.eu.org 8801"
"42048 kr1.acyun.eu.org 48644"
"35262 jp1.acyun.eu.org 23453"
"33351 tr.acyun.eu.org 12001"
"37265 hkaw.111165.xyz 39230"
"35245 sg1.acyun.eu.org 12337"
"37238 de1.acyun.eu.org 20160"
"25837 hkt-1.ddns-go.de 20470"
"37263 45.192.249.145 53798"
"51638 5.253.36.85 53798"
"31566 65.109.75.122 3388"
"51321 157.85.105.193 20230"
"26807 in.acyun.eu.org 20520"
"51054 he1.acyun.eu.org 8888"
"35279 us2.acyun.eu.org 20100"
"38745 160.250.132.160 20300"
"41244 154.83.85.155 38878"
"47364 140.238.58.217 38878"
"36515 160.250.132.160 15654"
"46512 sg01.acyun.eu.org 15456"
"53561 103.178.153.86 20140"
"35270 akile-hinet-chfb73.645781.xyz 20620"
)

open_port() {
local port="$1"

if command -v ufw >/dev/null 2>&1; then
ufw allow "${port}/tcp" || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
firewall-cmd --permanent --add-port="${port}/tcp" || true
firewall-cmd --add-port="${port}/tcp" || true
firewall-cmd --reload || true
else
warn "未检测到 ufw/firewalld，跳过开端口 ${port}/tcp。如果服务器没有防火墙，可以忽略。"
fi
}

install -d -m 755 /etc/port-forward

for line in "${MAPS[@]}"; do
read -r PORT HOST RPORT <<<"$line"

cat >"/etc/port-forward/${PORT}.env" <<EOF
PORT=${PORT}
TARGET_HOST=${HOST}
TARGET_PORT=${RPORT}
EOF

systemctl disable --now "port-forward-${PORT}.service" 2>/dev/null || true
systemctl disable --now "port-forward@${PORT}.service" 2>/dev/null || true

open_port "${PORT}"

systemctl enable --now "port-forward@${PORT}.service"

log "已启动端口转发：0.0.0.0:${PORT} => ${HOST}:${RPORT}"
done

log "端口转发全部配置完成。"

# === 8. 安装 v2node ===

log "安装 v2node..."

cd /root || exit 1

rm -f install.sh

wget -N https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh && \
bash install.sh \
--api-host 'https://yyds.acyun.eu.org' \
--node-id 24 \
--api-key 'kjdfbsfvbbiinbi@#@$'

systemctl enable v2node || true
systemctl restart v2node || true

# === 9. 最终状态检查 ===

log "检查 v2node 状态..."
systemctl status v2node --no-pager -l || true

log "检查端口转发示例状态..."
systemctl status port-forward@31725 --no-pager -l || true

echo
log "全部完成！日志保存在：$LOG_FILE"
echo
echo "常用命令："
echo "  systemctl status v2node --no-pager -l"
echo "  journalctl -u v2node -f"
echo "  systemctl status port-forward@31725 --no-pager"
echo "  journalctl -u port-forward@31725 -f"
echo "  systemctl disable --now port-forward@31725"
echo
log "脚本结束时间: $(date)"
