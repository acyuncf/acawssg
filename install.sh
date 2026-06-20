#!/bin/bash
set -Eeuo pipefail

LOG_FILE="/var/log/v2bx_v2node_init.log"
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


# === 1. 安装基础依赖：curl / wget / unzip / zip / socat / pv ===

log "安装 curl/wget/unzip/zip/socat/pv..."

if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  for i in {1..5}; do
    if apt-get install -y curl wget unzip zip socat ca-certificates pv; then
      break
    fi
    warn "apt 被锁定或安装失败，等待重试...($i/5)"
    sleep 5
  done
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release || true
  yum install -y curl wget unzip zip socat ca-certificates pv
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y epel-release || true
  dnf install -y curl wget unzip zip socat ca-certificates pv
elif command -v apk >/dev/null 2>&1; then
  apk update
  apk add --no-cache curl wget unzip zip socat ca-certificates pv bash
else
  error "未知的包管理器，无法自动安装必需依赖"
  exit 1
fi


# === 2. 安装哪吒 Agent，设置每 60 秒上报 ===

log "安装哪吒 Agent..."

cd /root || exit 1
rm -f agent.sh

curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh

NZ_SERVER=65.109.75.122:38888 \
NZ_TLS=false \
NZ_CLIENT_SECRET='UskD1XcYXcswqafCuTEI8EiPANRE8tDl' \
NZ_UUID='6ca12cbd-458c-7795-6eb2-9002d25f3b7e' \
./agent.sh

# === 3. 下载 v2bx-repair.sh ===

log "下载 v2bx-repair.sh..."

cd /root || exit 1
rm -f v2bx-repair.sh

curl -fsSL https://raw.githubusercontent.com/acyuncf/acawssg/refs/heads/main/v2bx-repair.sh -o v2bx-repair.sh
chmod +x v2bx-repair.sh


# === 4. 创建 TCP 端口转发脚本 ===

log "创建 TCP/IPv4+IPv6 端口转发脚本..."

install -d -m 755 /usr/local/bin

cat >/usr/local/bin/port_forward_env.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:?missing PORT}"
TARGET_HOST="${TARGET_HOST:?missing TARGET_HOST}"
TARGET_PORT="${TARGET_PORT:?missing TARGET_PORT}"

echo "[INFO] socat $(date) [::]:${PORT} => ${TARGET_HOST}:${TARGET_PORT}"

exec socat -d -d \
  TCP6-LISTEN:${PORT},ipv6only=0,reuseaddr,fork,nodelay,keepalive \
  TCP:${TARGET_HOST}:${TARGET_PORT},nodelay,keepalive
EOF

chmod +x /usr/local/bin/port_forward_env.sh


# === 5. 创建 systemd 端口转发模板服务 ===

log "创建 port-forward@.service 模板..."

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


# === 6. 批量配置端口转发 ===

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
"41235 154.83.85.155 35265"
"57682 jp.acyun.eu.org:15456"
"41654 160.250.132.160 35265"
"39514 129.154.217.251 42322"
"29366 sg1.acyun.eu.org:32132"
"34523 awshk.acyun.eu.org:37265"
"34340 akile-hinet-chfb73.645781.xyz 20620"
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


# === 7. 安装 V2bX ===

log "从 GitHub Releases 下载 V2bX 主程序..."

mkdir -p /etc/V2bX
cd /etc/V2bX || exit 1

systemctl stop v2bx 2>/dev/null || true
pkill -f "/etc/V2bX/V2bX server -c /etc/V2bX/config.json" 2>/dev/null || true

rm -f V2bX

wget -O V2bX https://github.com/acyuncf/acawsjp/releases/download/123/V2bX || {
  error "V2bX 下载失败，退出"
  exit 1
}

chmod +x V2bX


# === 8. 下载 V2bX 配置文件 ===

log "下载 V2bX 配置文件..."

config_url="https://wd1.acyun.eu.org/awssg"

for file in LICENSE README.md config.json custom_inbound.json custom_outbound.json dns.json geoip.dat geosite.dat route.json; do
  rm -f "$file"
  wget "$config_url/$file" || {
    error "下载 $file 失败"
    exit 1
  }
done


# === 9. 注册 V2bX 为 systemd 服务 ===

log "注册 V2bX 为 systemd 服务..."

cat > /etc/systemd/system/v2bx.service <<'EOF'
[Unit]
Description=V2bX Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/V2bX
ExecStart=/etc/V2bX/V2bX server -c /etc/V2bX/config.json
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable v2bx
systemctl restart v2bx


# === 10. 安装 v2node ===

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


# === 11. 最终状态检查 ===

log "检查 V2bX 状态..."
systemctl status v2bx --no-pager -l || true

log "检查 v2node 状态..."
systemctl status v2node --no-pager -l || true

log "检查端口转发示例状态..."
systemctl status port-forward@31725 --no-pager -l || true


# === 12. 最后启用 root 登录 ===

log "最后启用 root 登录..."

echo "root:d9aEPC!bDzF:g6Jdse,-th" | chpasswd

if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
else
  warn "未找到 /etc/ssh/sshd_config，跳过 SSH 配置修改。"
fi


echo
log "全部完成！日志保存在：$LOG_FILE"
echo
echo "常用命令："
echo "  systemctl status v2bx --no-pager -l"
echo "  journalctl -u v2bx -f"
echo "  systemctl status v2node --no-pager -l"
echo "  journalctl -u v2node -f"
echo "  systemctl status port-forward@31725 --no-pager"
echo "  journalctl -u port-forward@31725 -f"
echo "  systemctl disable --now port-forward@31725"
echo
log "脚本结束时间: $(date)"
