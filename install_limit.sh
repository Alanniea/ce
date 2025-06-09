#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.2"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE=/etc/limit_config.conf
mkdir -p /etc

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====== 自动保存自身 ======
if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
  echo "💾 正在保存 install_limit.sh 到 $SCRIPT_PATH..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "✅ 已保存"
fi

# ====== 自动更新函数 ======
check_update() {
  echo "📡 正在检查更新..."
  LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
           | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
  if [[ "$LATEST" != "$VERSION" ]]; then
    echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
    read -p "是否立即更新？[Y/n] " choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "✅ 更新完成，请执行 $SCRIPT_PATH 重新安装"
    else
      echo "🚫 已取消"
    fi
  else
    echo "✅ 已是最新（$VERSION）"
  fi
}

# ====== 支持 --update 参数 ======
if [[ "$1" == "--update" ]]; then
  check_update
  exit 0
fi

# ====== 初始化配置 ======
if [ ! -f "$CONFIG_FILE" ]; then
  echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
  echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi
source "$CONFIG_FILE"

echo "🛠 [0/6] 检测系统与网卡..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME=$ID
  OS_VER=$VERSION_ID
else
  OS_NAME=$(uname -s)
  OS_VER=$(uname -r)
fi
echo "系统：$OS_NAME $OS_VER"

IFACE=$(ip -o link show \
        | awk -F': ' '{print $2}' \
        | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
        | head -n1)
if [ -z "$IFACE" ]; then
  echo "⚠️ 未检测到网卡，请手动设置 IFACE"
  exit 1
fi
echo "主用网卡：$IFACE"

echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null; then
  apt update -y && apt install -y vnstat iproute2 curl
elif command -v yum >/dev/null; then
  yum install -y epel-release && yum install -y vnstat iproute curl
else
  echo "⚠️ 未知包管理器，请手动安装 vnstat、iproute2"
fi

echo "✅ [2/6] 初始化 vnStat..."
vnstat -u -i "$IFACE" || true
sleep 2
systemctl enable vnstat
systemctl restart vnstat

echo "📝 [3/6] 生成限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "\$CONFIG_FILE"

LINE=\$(vnstat -d -i "\$IFACE" | grep "\$(date '+%Y-%m-%d')")
USAGE=\$(echo "\$LINE" | awk '{print \$3}')
UNIT=\$(echo "\$LINE" | awk '{print \$4}')

if [[ "\$UNIT" == "MiB" ]]; then
  USAGE=\$(awk "BEGIN {printf \"%.2f\", \$USAGE / 1024}")
fi
USAGE_INT=\$(printf "%.0f" "\$USAGE")

if (( USAGE_INT >= LIMIT_GB )); then
  PCT=\$(( USAGE_INT * 100 / LIMIT_GB ))
  echo "[限速] \${USAGE_INT}GiB(\${PCT}%) → 开始限速"
  tc qdisc del dev "\$IFACE" root 2>/dev/null || true
  tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
  PCT=\$(( USAGE_INT * 100 / LIMIT_GB ))
  echo "[正常] \${USAGE_INT}GiB(\${PCT}%)"
fi

date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

echo "📝 [4/6] 生成解除限速脚本..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
tc qdisc del dev "\$IFACE" root 2>/dev/null || true
EOL
chmod +x /root/clear_limit.sh

echo "📅 [5/6] 写入 cron 任务..."
crontab -l 2>/dev/null \
  | grep -vE 'limit_bandwidth.sh|clear_limit.sh' \
  > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE && vnstat --update" \
     >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

echo "🧩 [6/6] 生成交互命令 ce..."
cat > /usr/local/bin/ce <<'EOF'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; RESET='\033[0m'

CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE"
VERSION=$(grep '^VERSION=' /root/install_limit.sh | cut -d'"' -f2)
IFACE=$(ip -o link show | awk -F': ' '{print $2}' \
        | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
        | head -n1)

while true; do
  DATE=$(date '+%Y-%m-%d')
  OS_INFO=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
  IP4=$(curl -s ifconfig.me || echo "未知")
  LAST_RUN=$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")

  LINE=$(vnstat -d -i "$IFACE" | grep "$DATE")
  if [[ -z "$LINE" ]]; then
    RX_GB=0; TX_GB=0
  else
    RX=$(echo "$LINE" | awk '{print $3}')
    RX_UNIT=$(echo "$LINE" | awk '{print $4}')
    TX=$(echo "$LINE" | awk '{print $5}')
    TX_UNIT=$(echo "$LINE" | awk '{print $6}')

    RX_GB=$RX
    TX_GB=$TX
    [[ "$RX_UNIT" == "MiB" ]] && RX_GB=$(awk "BEGIN{printf \"%.2f\", $RX/1024}")
    [[ "$TX_UNIT" == "MiB" ]] && TX_GB=$(awk "BEGIN{printf \"%.2f\", $TX/1024}")
  fi

  UP_STR="上行: ${TX_GB:-0} GiB"
  DOWN_STR="下行: ${RX_GB:-0} GiB"
  PCT=$(awk -v u="$RX_GB" -v l="$LIMIT_GB" 'BEGIN{printf "%.1f", u/l*100}')

  TC_OUT=$(tc qdisc show dev "$IFACE")
  if echo "$TC_OUT" | grep -q "tbf"; then
    LIMIT_STATE="✅ 正在限速"
    CUR_RATE=$(echo "$TC_OUT" | grep -oP 'rate \K\S+')
  else
    LIMIT_STATE="🆗 未限速"
    CUR_RATE="-"
  fi

  clear
  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║        🚦 流量限速管理控制台（ce） v${VERSION}        ║"
  echo -e "╚════════════════════════════════════════════════╝${RESET}"
  echo -e "${YELLOW}📅 日期：${DATE}    🖥 系统：${OS_INFO}${RESET}"
  echo -e "${YELLOW}🌐 网卡：${IFACE}    公网 IP：${IP4}${RESET}"
  echo -e "${GREEN}📊 今日流量：${UP_STR} / ${DOWN_STR}${RESET}"
  echo -e "${GREEN}📈 已用：${RX_GB} GiB / ${LIMIT_GB} GiB (${PCT}%)${RESET}"
  echo -e "${GREEN}🚦 状态：${LIMIT_STATE}    🚀 速率：${CUR_RATE}${RESET}"
  echo -e "${GREEN}🕒 上次检测：${LAST_RUN}${RESET}"
  echo
  echo -e "${GREEN}1.${RESET} 检查是否应限速"
  echo -e "${GREEN}2.${RESET} 手动解除限速"
  echo -e "${GREEN}3.${RESET} 查看限速状态"
  echo -e "${GREEN}4.${RESET} 查看每日流量"
  echo -e "${GREEN}5.${RESET} 删除限速脚本"
  echo -e "${GREEN}6.${RESET} 修改限速配置"
  echo -e "${GREEN}7.${RESET} 退出"
  echo -e "${GREEN}8.${RESET} 检查 install_limit.sh 更新"
  echo -e "${GREEN}9.${RESET} 运行 Speedtest 测速"
  echo
  read -p "👉 请选择操作 [1-9]: " opt
  case "$opt" in
    1) /root/limit_bandwidth.sh ;;
    2) /root/clear_limit.sh ;;
    3) tc -s qdisc ls dev "$IFACE" ;;
    4) vnstat -d ;;
    5)
      rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh
      rm -f /usr/local/bin/ce
      echo -e "${YELLOW}已删除所有脚本${RESET}"
      break ;;
    6)
      echo -e "\n当前：${LIMIT_GB}GiB，${LIMIT_RATE}"
      read -p "🔧 新每日流量（GiB）: " ngb
      read -p "🚀 新限速（如512kbit）: " nrt
      if [[ "$ngb" =~ ^[0-9]+$ ]] && [[ "$nrt" =~ ^[0-9]+(kbit|mbit)$ ]]; then
        echo "LIMIT_GB=$ngb" > /etc/limit_config.conf
        echo "LIMIT_RATE=$nrt" >> /etc/limit_config.conf
        echo -e "${GREEN}已更新${RESET}"
      else
        echo -e "${RED}输入无效${RESET}"
      fi
      ;;
    7) break ;;
    8) /root/install_limit.sh --update ;;
    9)
      if ! command -v speedtest &>/dev/null; then
        echo -e "${YELLOW}正在安装 speedtest-cli...${RESET}"
        if command -v apt &>/dev/null; then
          apt update && apt install -y curl
          curl -s https://install.speedtest.net/app/cli/install.deb -o /tmp/speedtest.deb
          dpkg -i /tmp/speedtest.deb
        elif command -v yum &>/dev/null; then
          curl -s https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.rpm \
            -o /tmp/speedtest.rpm
          yum localinstall -y /tmp/speedtest.rpm
        else
          echo -e "${RED}❌ 不支持的系统，无法自动安装 speedtest${RESET}"
          continue
        fi
      fi
      echo -e "${CYAN}开始运行 Speedtest...${RESET}"
      speedtest
      ;;
    *) echo -e "${RED}无效${RESET}" ;;
  esac
  read -p "⏎ 回车继续..." dummy
done
EOF

chmod +x /usr/local/bin/ce

echo "🎉 安装完成！使用命令： ce"