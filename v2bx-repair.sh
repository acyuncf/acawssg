#!/usr/bin/env bash
# v2bx-repair.sh
# 作用：
#   - 检测 V2bX 是否在运行；若未运行，认为可能安装不完整 → 清空并重装 /etc/V2bX → 注册并启动 systemd 服务
#   - 可选参数：
#       --force     无论是否在运行，都强制重装
#       --no-backup 重装前不备份旧目录，直接删除
#
# 日志：/var/log/v2bx_repair.log
# 锁： /var/lock/v2bx-repair.lock
# 退出码：0 成功（已运行或修复成功），非 0 失败

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# —— 总是重启 nezha-agent（无论成功/失败/在哪退出）——
NEZHA_SERVICE="nezha-agent"

# ---------------- 用户可按需修改的参数 ----------------
V2BX_DIR="/etc/V2bX"
V2BX_BIN="${V2BX_DIR}/V2bX"
V2BX_CFG="${V2BX_DIR}/config.json"
SERVICE_NAME="v2bx.service"

# 下载源（沿用你给的地址）
BIN_URL="https://github.com/acyuncf/acawsjp/releases/download/123/V2bX"
CFG_BASE="https://wd1.acyun.eu.org/awssg"
FILES=( "LICENSE" "README.md" "V2bX" "config.json" "custom_inbound.json" "custom_outbound.json" "dns.json" "geoip.dat" "geosite.dat" "route.json" )

# ---------------- 运行控制 ----------------
FORCE=false       # --force 时改为 true
BACKUP_OLD=true   # --no-backup 时改为 false

# ---------------- 日志与锁 ----------------
LOG_FILE="/var/log/v2bx_repair.log"
LOCK_FILE="/var/lock/v2bx-repair.lock"

# ---------------- 参数解析 ----------------
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --no-backup) BACKUP_OLD=false ;;
    *) echo "[WARN] 忽略未知参数：$arg" ;;
  esac
done

# ---------------- 前置检查 ----------------
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] 请以 root 运行本脚本"
  exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")" /var/lock
exec 9>"$LOCK_FILE" || true
if ! flock -n 9; then
  echo "[WARN] another repair instance is running, exit"
  exit 0
fi

# 将 stdout/stderr 追加写入日志
exec > >(tee -a "$LOG_FILE") 2>&1
echo "========== [START] $(date '+%F %T') v2bx-repair (FORCE=$FORCE, BACKUP_OLD=$BACKUP_OLD) =========="

# ---------------- 工具函数 ----------------
have() { command -v "$1" >/dev/null 2>&1; }

have_systemd() {
  if have systemctl; then
    systemctl is-system-running >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

wait_net() {
  echo "[INFO] 等待网络就绪..."
  for i in {1..6}; do
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
      echo "[OK] 网络可用"; return 0
    fi
    echo "[WARN] 网络未就绪 ($i/6)"; sleep 5
  done
  echo "[WARN] 无法确认网络是否可用，继续尝试（由后续下载成败决定是否退出）"
}

install_pkg() {
  local pkgs=("$@")
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    for i in {1..2}; do apt-get update -y && break || sleep 3; done
    for i in {1..5}; do
      if apt-get install -y "${pkgs[@]}"; then return 0; fi
      echo "[WARN] apt 安装失败或被锁定，重试 ($i/5)"; sleep 5
    done
    echo "[ERROR] apt 安装失败：${pkgs[*]}"; return 1
  elif have yum; then
    yum install -y epel-release || true
    yum install -y "${pkgs[@]}"
  elif have dnf; then
    dnf install -y "${pkgs[@]}"
  else
    echo "[ERROR] 未知包管理器，无法安装：${pkgs[*]}"; return 1
  fi
}

need_bin() { have "$1" || install_pkg "$2"; }

clean_and_recreate_dir() {
  mkdir -p /etc
  if [[ -d "$V2BX_DIR" ]]; then
    if $BACKUP_OLD; then
      local ts; ts=$(date +%Y%m%d-%H%M%S)
      echo "[INFO] 备份旧目录 ${V2BX_DIR} -> ${V2BX_DIR}.bak-${ts}"
      mv "$V2BX_DIR" "${V2BX_DIR}.bak-${ts}" || true
    else
      echo "[INFO] 删除旧目录 ${V2BX_DIR}"
      rm -rf "${V2BX_DIR}"
    fi
  fi
  mkdir -p "$V2BX_DIR"
}

register_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=V2bX Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${V2BX_DIR}
ExecStart=${V2BX_BIN} server -c ${V2BX_CFG}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

start_and_verify() {
  echo "[INFO] 启动 ${SERVICE_NAME}..."
  systemctl restart "${SERVICE_NAME}" || true
  sleep 2

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "[OK] systemd 服务处于 active"
  else
    echo "[WARN] 服务未 active，尝试 nohup 兜底拉起一次"
    nohup "${V2BX_BIN}" server -c "${V2BX_CFG}" >/dev/null 2>&1 &
    sleep 2
  fi

  if pgrep -x "V2bX" >/dev/null 2>&1; then
    echo "[OK] V2bX 进程已运行"
    return 0
  else
    echo "[ERROR] V2bX 启动失败"
    return 1
  fi
}

# -------- Nezha-Agent 稳定重启函数（处理 ENOTCONN 等） --------
restart_nezha() {
  echo "[INFO] 重启 ${NEZHA_SERVICE}..."

  if ! have_systemd; then
    echo "[WARN] 未检测到可用的 systemd，跳过 systemctl 流程"
    return 0
  fi

  systemctl daemon-reload || true
  systemctl reset-failed "${NEZHA_SERVICE}.service" || true

  local errf; errf="$(mktemp)"
  if systemctl restart --no-ask-password --job-mode=replace-irreversibly "${NEZHA_SERVICE}.service" 2>"$errf"; then
    systemctl is-active "${NEZHA_SERVICE}.service" --quiet && { echo "[OK] nezha-agent 已重启"; rm -f "$errf"; return 0; }
  fi

  local err_msg; err_msg="$(cat "$errf" || true)"; rm -f "$errf"
  if echo "$err_msg" | grep -qi "Transport endpoint is not connected"; then
    echo "[WARN] systemd 通信断开，执行 daemon-reexec 后重试..."
    systemctl daemon-reexec || true
    sleep 1
    if systemctl restart --no-ask-password "${NEZHA_SERVICE}.service"; then
      systemctl is-active "${NEZHA_SERVICE}.service" --quiet && { echo "[OK] nezha-agent 已重启（reexec 后）"; return 0; }
    fi
  fi

  echo "[WARN] 使用 systemd-run 在独立 scope 中重启..."
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --quiet --collect --unit=nezha-restart-$$ --property=After=network-online.target \
      /bin/sh -c 'systemctl restart --no-ask-password nezha-agent.service'
    sleep 1
    systemctl is-active "${NEZHA_SERVICE}.service" --quiet && { echo "[OK] nezha-agent 已重启（scope）"; return 0; }
  fi

  echo "[WARN] 进入兜底流程，尝试直接按 ExecStart 启动 nezha-agent..."
  local exec_line cmd
  exec_line="$(systemctl show -p ExecStart --value "${NEZHA_SERVICE}.service" 2>/dev/null || true)"
  if [ -n "$exec_line" ]; then
    cmd="$(printf '%s' "$exec_line" | sed 's/^[^=]*=//; s/;.*$//; s/^-[[:space:]]*//')"
    if [ -n "$cmd" ]; then
      echo "[INFO] ExecStart: $cmd"
      pkill -f nezha-agent || true
      nohup sh -c "$cmd" >/var/log/nezha-agent.fallback.log 2>&1 &
      sleep 1
      pgrep -f nezha-agent >/dev/null 2>&1 && { echo "[OK] 兜底直启成功（未通过 systemctl）"; return 0; }
    fi
  fi

  echo "[ERROR] nezha-agent 重启失败，请手动执行："
  echo "  systemctl status nezha-agent.service -l"
  echo "  journalctl -xeu nezha-agent.service"
  return 1
}

# —— 确保脚本在任何退出路径都会尝试一次稳定重启 nezha-agent ——
on_exit() {
  restart_nezha || true
  echo "========== [DONE] $(date '+%F %T') =========="
}
trap 'on_exit' EXIT

# ---------------- 1) 运行中则判断是否需要退出 ----------------
if ! $FORCE; then
  if pgrep -x "V2bX" >/dev/null 2>&1; then
    echo "[OK] V2bX 正在运行，无需修复"
    exit 0
  fi
  echo "[WARN] 未检测到 V2bX 进程 → 将执行全量重装"
else
  echo "[INFO] FORCE 模式：无条件执行全量重装"
fi

# ---------------- 2) 准备环境 ----------------
wait_net
need_bin curl curl
need_bin wget wget
need_bin unzip unzip
need_bin zip zip

# ---------------- 3) 清空并重装 ----------------
clean_and_recreate_dir
cd "$V2BX_DIR"

echo "[INFO] 下载 V2bX 二进制：$BIN_URL"
if ! wget -O "V2bX" "$BIN_URL"; then
  echo "[ERROR] 下载 V2bX 失败：$BIN_URL"
  exit 10
fi
chmod +x "V2bX"

echo "[INFO] 下载配置文件..."
for f in "${FILES[@]}"; do
  [[ "$f" == "V2bX" ]] && continue
  url="${CFG_BASE}/${f}"
  echo "  - $f"
  if ! wget -O "$f" "$url"; then
    echo "[ERROR] 下载失败：$url"
    exit 11
  fi
done

# ---------------- 4) 注册服务并启动 ----------------
if have_systemd; then
  register_service
  start_and_verify || exit 12
else
  echo "[WARN] 无 systemd 环境，直接前台拉起（请自行放入守护）"
  nohup "${V2BX_BIN}" server -c "${V2BX_CFG}" >/var/log/v2bx.nosystemd.log 2>&1 &
  sleep 2
  pgrep -x "V2bX" >/dev/null 2>&1 || { echo "[ERROR] V2bX 启动失败（无 systemd）"; exit 12; }
fi
