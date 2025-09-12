#!/bin/bash

LOG_FILE="/var/log/v2bx_init.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] 脚本启动时间: $(date)"

# === 2. 自动安装 unzip、zip、socat（含重试）===
echo "[INFO] 安装 unzip/zip/socat..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    for i in {1..5}; do
        apt-get install -y unzip zip socat && break
        echo "[WARN] apt 被锁定或失败，等待重试...($i/5)"
        sleep 5
    done
elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release
    yum install -y unzip zip socat
else
    echo "[ERROR] 未知的包管理器，无法自动安装必需依赖"
    exit 1
fi

# === 5. 安装哪啦 Agent，设置每 60 秒上报 ===
echo "[INFO] 安装哪啦 Agent..."
cd /root
curl -L https://raw.githubusercontent.com/acyuncf/acawsjp/refs/heads/main/nezha.sh -o nezha.sh
chmod +x nezha.sh
./nezha.sh install_agent 65.109.75.122 5555 BLvgD1hxoSjIr0mYrD -u 60

# === 4. 安装 nyanpass 客户端 ===
echo "[INFO] 安装 nyanpass 客户端..."
S=nyanpass OPTIMIZE=1 bash <(curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh) rel_nodeclient "-o -t e1fa8b04-f707-41d6-b443-326a0947fa2f -u https://ny.321337.xyz"

cd /root
curl -fsSL https://raw.githubusercontent.com/acyuncf/acawssg/refs/heads/main/v2bx-repair.sh -o v2bx-repair.sh
chmod +x v2bx-repair.sh

install -d -m 755 /usr/local/bin
cat >/usr/local/bin/port_forward_env.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PORT="${PORT:?missing PORT}"
TARGET_HOST="${TARGET_HOST:?missing TARGET_HOST}"
TARGET_PORT="${TARGET_PORT:?missing TARGET_PORT}"

echo "[INFO] socat $(date) 0.0.0.0:${PORT} => ${TARGET_HOST}:${TARGET_PORT}"
# reuseaddr: 避免 TIME_WAIT 绑定失败
# fork: 支持多并发
# nodelay/keepalive: 降低时延、保持连接
exec socat -d -d \
  TCP-LISTEN:${PORT},reuseaddr,fork,nodelay,keepalive \
  TCP:${TARGET_HOST}:${TARGET_PORT},nodelay,keepalive
EOF
chmod +x /usr/local/bin/port_forward_env.sh

# --- 2) 创建 systemd 模板单元 -------------------------------------------------
cat >/etc/systemd/system/port-forward@.service <<'EOF'
[Unit]
Description=TCP Forward (0.0.0.0:%i -> TARGET_HOST:TARGET_PORT)
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

# --- 3) 需要批量配置的映射 (本地端口 目标主机 目标端口) ----------------------
declare -a MAPS=(
"35269 tw1-vds8.anyhk.co 20590"
"25837 awshk.acyun.eu.org 20230"
"42048 kr1.acyun.eu.org 48644"
"35261 awsjp.acyun.eu.org 48803"
"35263 jp1.acyun.eu.org 15659"
"35245 sg2.acyun.eu.org 15644"
"35271 us1.acyun.eu.org 27367"
"41243 sg13.111165.xyz 41243"
)

# --- 4) 防火墙开端口函数 -------------------------------------------------------
open_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" || true
    firewall-cmd --add-port="${port}/tcp" || true
    firewall-cmd --reload || true
  else
    warn "未检测到 ufw/firewalld，跳过开端口 ${port}/tcp（若无防火墙可忽略）"
  fi
}

# --- 5) 写 env、处理旧服务、开端口并启用实例 -----------------------------------
install -d -m 755 /etc/port-forward

for line in "${MAPS[@]}"; do
  read -r PORT HOST RPORT <<<"$line"

  # 写入环境文件
  cat >"/etc/port-forward/${PORT}.env" <<EOF
PORT=${PORT}
TARGET_HOST=${HOST}
TARGET_PORT=${RPORT}
EOF

  # 若存在旧的单实例服务名（非模板）则尝试停用，避免端口占用
  systemctl disable --now "port-forward-${PORT}.service" 2>/dev/null || true

  # 开放防火墙
  open_port "${PORT}"

  # 启用并启动该实例
  systemctl enable --now "port-forward@${PORT}.service"
  log "已启动：0.0.0.0:${PORT} => ${HOST}:${RPORT}"
done

echo
log "全部完成！常用命令："
echo "  systemctl status port-forward@41243 --no-pager"
echo "  journalctl -u port-forward@41243 -f"
echo "  systemctl disable --now port-forward@35269"

# === 3. 安装 V2bX ===
echo "[INFO] 从 GitHub Releases 下载 V2bX 主程序..."
mkdir -p /etc/V2bX
cd /etc/V2bX

wget -O V2bX https://github.com/acyuncf/acawsjp/releases/download/123/V2bX || {
    echo "[ERROR] V2bX 下载失败，退出"
    exit 1
}
chmod +x V2bX

# 下载配置文件
echo "[INFO] 下载其余配置文件..."
config_url="https://wd1.acyun.eu.org/awssg"
for file in LICENSE README.md config.json custom_inbound.json custom_outbound.json dns.json geoip.dat geosite.dat route.json; do
    wget "$config_url/$file" || {
        echo "[ERROR] 下载 $file 失败"
        exit 1
    }
done

# === 启动 V2bX（后台运行）===
echo "[INFO] 启动 V2bX..."
nohup /etc/V2bX/V2bX server -c /etc/V2bX/config.json > /etc/V2bX/v2bx.log 2>&1 &

# === 注册 V2bX 为 systemd 服务 ===
echo "[INFO] 注册 V2bX 为 systemd 服务..."
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable v2bx
systemctl start v2bx

echo "[SUCCESS] 所有组件安装完成，日志保存在 $LOG_FILE"
