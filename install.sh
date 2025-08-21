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

# === 2.1 开放本机防火墙端口（若存在防火墙）===
echo "[INFO] 开放 41243/tcp（如果启用防火墙）..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 41243/tcp || true
elif systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=41243/tcp || true
    firewall-cmd --reload || true
fi

cd /root
curl -fsSL https://raw.githubusercontent.com/acyuncf/acawssg/refs/heads/main/v2bx-repair.sh -o v2bx-repair.sh
chmod +x v2bx-repair.sh

# === 2.2 创建端口转发脚本与 systemd 服务 ===
echo "[INFO] 创建端口转发服务（0.0.0.0:41243 -> sg13.111165.xyz:41243）..."
cat >/usr/local/bin/port_forward_41243.sh <<'EOF'
#!/bin/bash
LOG="/var/log/port_forward_41243.log"
exec >> "$LOG" 2>&1
echo "[INFO] port_forward_41243 启动于 $(date)"
# 使用循环保证异常退出后自动重启
while true; do
    # -d -d 输出诊断日志；reuseaddr 避免 TIME_WAIT 绑定失败；fork 多并发
    socat -d -d TCP-LISTEN:41243,reuseaddr,fork TCP:sg13.111165.xyz:41243
    code=$?
    echo "[WARN] socat 退出（code=$code），2s 后重启 $(date)"
    sleep 2
done
EOF
chmod +x /usr/local/bin/port_forward_41243.sh

cat >/etc/systemd/system/port-forward-41243.service <<'EOF'
[Unit]
Description=TCP Forward 0.0.0.0:41243 -> sg13.111165.xyz:41243
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/port_forward_41243.sh
Restart=always
RestartSec=2
# 提高文件描述符上限，避免高并发报错
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now port-forward-41243

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
