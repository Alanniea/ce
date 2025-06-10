#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.5"
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

# ====== 确认 vnstat 初始化参数 ======
if vnstat --help 2>&1 | grep -q -- '--create'; then
  VNSTAT_CREATE_OPT="--create"
elif vnstat --help 2>&1 | grep -q -- '-u'; then
  VNSTAT_CREATE_OPT="-u"
else
  echo "⚠️ 无法找到 vnstat 初始化标志，请手动初始化数据库" >&2
  VNSTAT_CREATE_OPT=""
fi

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

IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
if [ -z "$IFACE" ]; then
  echo "⚠️ 未检测到网卡，请手动设置 IFACE"
  exit 1
fi
echo "主用网卡：$IFACE"

echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null; then
  apt update -y && apt install -y vnstat iproute2 curl speedtest-cli
elif command -v yum >/dev/null; then
  yum install -y epel-release && yum install -y vnstat iproute curl speedtest-cli
else
  echo "⚠️ 未知包管理器，请手动安装 vnstat、iproute2、speedtest-cli"
fi

echo "✅ [2/6] 初始化 vnStat..."
vnstat $VNSTAT_CREATE_OPT -i "$IFACE" || true
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
RX=\$(echo "\$LINE" | awk '{print \$3}')
UNIT=\$(echo "\$LINE" | awk '{print \$4}')

if [[ "\$UNIT" == "KiB" ]]; then
  RX=\$(awk "BEGIN {printf \"%.2f\", \$RX / 1024 / 1024}")
elif [[ "\$UNIT" == "MiB" ]]; then
  RX=\$(awk "BEGIN {printf \"%.2f\", \$RX / 1024}")
elif [[ "\$UNIT" == "GiB" ]]; then
  true
elif [[ "\$UNIT" == "TiB" ]]; then
  RX=\$(awk "BEGIN {printf \"%.2f\", \$RX * 1024}")
else
  RX="0.00"
fi

USAGE=\$(awk "BEGIN {printf \"%.2f\", \$RX}")

if awk "BEGIN {exit !(\$USAGE >= LIMIT_GB)}"; then
  PCT=\$(awk "BEGIN {printf \"%d\", \$USAGE / LIMIT_GB * 100}")
  echo "[限速] \${USAGE}GiB(\${PCT}%) → 开始限速"
  tc qdisc del dev "\$IFACE" root 2>/dev/null || true
  tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
  PCT=\$(awk "BEGIN {printf \"%d\", \$USAGE / LIMIT_GB * 100}")
  echo "[正常] \${USAGE}GiB(\${PCT}%)"
  tc qdisc del dev "\$IFACE" root 2>/dev/null || true
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
crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat $VNSTAT_CREATE_OPT -i $IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

echo "📡 [附加] 生成测速脚本..."
cat > /root/speed_test.sh <<EOF
#!/bin/bash
echo "🌐 正在测速..."
speedtest --simple
echo "🔄 正在更新 vnStat 数据库..."
vnstat --update
EOF
chmod +x /root/speed_test.sh

echo "🧩 [6/6] 生成交互命令 ce..."
cat > /usr/local/bin/ce <<'EOF'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; RESET='\033[0m'

CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE"
VERSION=$(grep '^VERSION=' /root/install_limit.sh | cut -d'"' -f2)
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)

convert_to_gib() {
  local value="$1"
  local unit="$2"
  if [[ "$unit" == "KiB" ]]; then
    awk "BEGIN {printf \"%.2f\", $value / 1024 / 1024}"
  elif [[ "$unit" == "MiB" ]]; then
    awk "BEGIN {printf \"%.2f\", $value / 1024}"
  elif [[ "$unit" == "GiB" ]]; then
    echo "$value"
  elif [[ "$unit" == "TiB" ]]; then
    awk "BEGIN {printf \"%.2f\", $value * 1024}"
  else
    echo "0.00"
  fi
}

while true; do
  DATE=$(date '+%Y-%m-%d')
  OS_INFO=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
  IP4=$(curl -s ifconfig.me || echo "未知")
  LAST_RUN=$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")

  LINE=$(vnstat -d -i "$IFACE" | grep "$DATE")
  if [[ -z "$LINE" ]]; then
    RX_GB=0.00; TX_GB=0.00
  else
    RX=$(echo "$LINE" | awk '{print $3}')
    RX_UNIT=$(echo "$LINE" | awk '{print $4}')
    TX=$(echo "$LINE" | awk '{print $5}')
    TX_UNIT=$(echo "$LINE" | awk '{print $6}')
    RX_GB=$(convert_to_gib "$RX" "$RX_UNIT")
    TX_GB=$(convert_to_gib "$TX" "$TX_UNIT")
  fi

  PCT=$(awk -v u="$RX_GB" -v l="$LIMIT_GB" 'BEGIN{printf "%.1f", u/l*100}')

  TC_OUT=$(tc qdisc show dev "$IFACE")
  if echo "$TC_OUT" | grep -q "tbf"; then
    LIMIT_STATE="${GREEN}✅ 正在限速${RESET}"
    CUR_RATE=$(echo "$TC_OUT" | grep -oP 'rate \K\S+')
  else
    LIMIT_STATE="${YELLOW}🆗 未限速${RESET}"
    CUR_RATE="-"
  fi

  clear
  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║        🚦 流量限速管理控制台（ce） v${VERSION}        ║"
  echo -e "╚════════════════════════════════════════════════╝${RESET}"
  echo -e "${YELLOW}📅 日期：${DATE}    🖥 系统：${OS_INFO}${RESET}"
  echo -e "${YELLOW}🌐 网卡：${IFACE}    公网 IP：${IP4}${RESET}"
  echo -e "${GREEN}📊 今日流量：上行: ${TX_GB} GiB / 下行: ${RX_GB} GiB${RESET}"
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
  echo -e "${GREEN}9.${RESET} 网络测速"
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
      crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' | crontab -
      echo -e "${YELLOW}已删除所有脚本和 cron 任务${RESET}"
      break ;;
    6)
      echo -e "
当前配置：每日流量限额 ${LIMIT_GB}GiB，限速速率 ${LIMIT_RATE}"
      read -p "🔧 请输入新的每日流量限额（GiB，例如：30）: " ngb
      read -p "🚀 请输入新的限速速率（例如：512kbit 或 1mbit）: " nrt
      if [[ "$ngb" =~ ^[0-9]+$ ]] && [[ "$nrt" =~ ^[0-9]+(kbit|mbit)$ ]]; then
        echo "LIMIT_GB=$ngb" > "$CONFIG_FILE"
        echo "LIMIT_RATE=$nrt" >> "$CONFIG_FILE"
        source "$CONFIG_FILE"
        echo -e "${GREEN}配置已更新！${RESET}"
      else
        echo -e "${RED}输入无效，请检查流量值是否为数字，速率格式是否正确（如 512kbit, 1mbit）。${RESET}"
      fi
      ;;
    7) break ;;
    8) /root/install_limit.sh --update ;;
    9) /root/speed_test.sh ;;
    *) echo -e "${RED}无效选项，请重新输入。${RESET}" ;;
  esac
  read -p "⏎ 按回车键继续..." dummy
done
EOF

chmod +x /usr/local/bin/ce

echo "🎉 安装完成！现在可以使用命令：${GREEN}ce${RESET} 来管理流量限速。"