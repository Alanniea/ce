#!/usr/bin/env bash
set -euo pipefail

# ====== 基础信息 ======
VERSION="1.0.3"
REPO="Alanniea/ce"
SCRIPT_PATH="/usr/local/bin/install_limit"
CONFIG_FILE="/etc/limit_config.conf"
DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====== 日志函数 ======
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# ====== 自身保存与更新 ======
save_self() {
  if [[ $(basename "$0") != install_limit ]] || [[ ! -f "$SCRIPT_PATH" ]]; then
    info "正在保存脚本到 $SCRIPT_PATH..."
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
      -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    info "脚本已保存"
  fi
}

check_update() {
  info "检查新版本..."
  local latest
n  latest=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
             | grep -E '^VERSION=' | head -1 | cut -d'\"' -f2)
  if [[ "$latest" != "$VERSION" ]]; then
    info "发现新版本: $latest (当前: $VERSION)"
    read -rp "是否更新? [Y/n]: " reply
    if [[ "$reply" =~ ^[Yy]?$ ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      info "已更新至 $latest，请重新运行 $SCRIPT_PATH"
      exit;
    else
      warn "已取消更新"
    fi
  else
    info "当前已是最新版本 ($VERSION)"
  fi
}

# ====== 参数解析 ======
if [[ ${1:-} == "--update" ]]; then
  check_update
  exit
fi

# ====== 安装依赖 ======
install_deps() {
  info "安装依赖: vnstat, iproute2, curl, speedtest-cli"
  if command -v apt &>/dev/null; then
    apt update -y && apt install -y vnstat iproute2 curl speedtest-cli
  elif command -v yum &>/dev/null; then
    yum install -y epel-release && yum install -y vnstat iproute curl speedtest-cli
  else
    warn "未识别包管理器，请手动安装依赖"
  fi
}

# ====== 初始化配置 ======
init_config() {
  info "初始化配置文件"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
LIMIT_GB=$DEFAULT_GB
LIMIT_RATE=$DEFAULT_RATE
EOF
  source "$CONFIG_FILE"
}

# ====== 系统与网卡检测 ======
detect_iface() {
  info "检测网络接口"
  local iface_list
  iface_list=$(ip -o link show | awk -F': ' '{print $2}' \
               | grep -Ev '^(lo|docker|br-|veth|tun|vmnet|virbr)')
  IFACE=${iface_list%%$'\n'*}
  [[ -z "$IFACE" ]] && error "未检测到有效网卡，请手动设置" || info "主用网卡: $IFACE"
}

# ====== 脚本生成 ======
generate_limit_script() {
  info "生成限速脚本"
  cat > /usr/local/bin/limit_bandwidth <<'EOL'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE"
IFACE="$(awk '/^[^#]*IFACE/ {print $2}' <<< "$(ip -o link show)")"

# 获取今日流量
LINE=$(vnstat -d -i "$IFACE" | grep "$(date '+%Y-%m-%d')")
RX=$(awk '{print $3}' <<< "$LINE")
UNIT=$(awk '{print $4}' <<< "$LINE")
[[ "$UNIT" == "MiB" ]] && RX=$(awk "BEGIN{printf \"%.2f\", $RX/1024}")
USAGE=${RX%.*}
if (( USAGE >= LIMIT_GB )); then
  tc qdisc del dev "$IFACE" root &>/dev/null || true
  tc qdisc add dev "$IFACE" root tbf rate "$LIMIT_RATE" burst 32kbit latency 400ms
  echo "[限速] ${USAGE}GiB → 限速生效"
else
  echo "[正常] ${USAGE}GiB"
fi

date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
  chmod +x /usr/local/bin/limit_bandwidth
}

generate_clear_script() {
  info "生成解除限速脚本"
  cat > /usr/local/bin/clear_limit <<EOF
#!/usr/bin/env bash
tc qdisc del dev "$IFACE" root &>/dev/null || true
EOF
  chmod +x /usr/local/bin/clear_limit
}

generate_speed_test() {
  info "生成测速脚本"
  cat > /usr/local/bin/speed_test <<EOF
#!/usr/bin/env bash
echo "正在测速..."
speedtest --simple
EOF
  chmod +x /usr/local/bin/speed_test
}

# ====== 写入 cron ======
setup_cron() {
  info "配置 cron 作业"
  (crontab -l 2>/dev/null | grep -vE 'limit_bandwidth|clear_limit';
   echo "0 * * * * /usr/local/bin/limit_bandwidth";
   echo "0 0 * * * /usr/local/bin/clear_limit && vnstat -u -i $IFACE && vnstat --update") \
   | crontab -
}

# ====== 安装 ce 控制台 ======
install_ce_console() {
  info "生成交互命令 ce"
  cat > /usr/local/bin/ce <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/limit_config.conf
IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -1)"

show_status() {
  DATE=$(date '+%Y-%m-%d')
  LINE=$(vnstat -d -i "$IFACE" | grep "$DATE")
  RX=$(awk '{print $3}' <<< "$LINE")
  RX_UNIT=$(awk '{print $4}' <<< "$LINE")
  [[ "$RX_UNIT" == "MiB" ]] && RX=$(awk "BEGIN{printf \"%.2f\", $RX/1024}")
  PCT=$(awk "BEGIN{printf \"%.1f\", $RX/($LIMIT_GB)*100}")
  RUNLOG=$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")
  TC=$(tc qdisc show dev "$IFACE")
  STATE=$(grep -q tbf <<< "$TC" && echo "限速中" || echo "未限速")
  RATE=$(grep -oP 'rate \K\S+' <<< "$TC" || echo "-")

  cat <<STATUS
日期: $DATE
今日使用: ${RX} GiB ($PCT%)
状态: $STATE 速率: $RATE
上次检测: $RUNLOG
STATUS
}

PS3="请选择操作: "
options=("检查是否应限速" "解除限速" "查看状态" "测速" "退出" )
select opt in "${options[@]}"; do
  case $opt in
    "检查是否应限速") /usr/local/bin/limit_bandwidth;;
    "解除限速")   /usr/local/bin/clear_limit;;
    "查看状态")     show_status;;
    "测速")       /usr/local/bin/speed_test;;
    "退出")       break;;
    *) echo "无效选项";;
  esac
done
EOF
  chmod +x /usr/local/bin/ce
}

# ====== 执行安装流程 ======
main() {
  save_self
  init_config
  detect_iface
  install_deps
  generate_limit_script
  generate_clear_script
  generate_speed_test
  setup_cron
  install_ce_console
  info "安装完成！运行 'ce' 启动控制台"
}

main "$@"
