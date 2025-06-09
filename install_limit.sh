#!/bin/bash
set -e

# 基础信息
VERSION="1.0.0"
REPO="Alanniea/ce"
CONFIG_FILE=/etc/limit_config.conf
SCRIPT_PATH="$(readlink -f "$0")"

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

# 自动更新函数
check_update() {
  echo "📡 正在检查更新..."
  LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
  if [[ "$LATEST" != "$VERSION" ]]; then
    echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
    read -p "是否立即更新脚本？[Y/n] " choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo -e "${GREEN}✅ 更新完成，请重新执行本脚本${RESET}"
      exit 0
    else
      echo "🚫 已取消更新"
    fi
  else
    echo "✅ 当前已经是最新版本（$VERSION）"
  fi
}

# 判断参数 --update 只做更新检查
if [[ "$1" == "--update" ]]; then
  check_update
  exit 0
fi

# 自动识别系统和网卡
echo "🛠 [0/6] 自动识别系统和网卡..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME=$ID
  OS_VER=$VERSION_ID
else
  OS_NAME=$(uname -s)
  OS_VER=$(uname -r)
fi
echo "检测到系统：$OS_NAME $OS_VER"

IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n 1)
if [ -z "$IFACE" ]; then
  echo -e "${RED}⚠️ 未检测到有效网卡，请手动设置 IFACE 变量${RESET}"
  exit 1
fi
echo "检测到主用网卡：$IFACE"

# 安装依赖
echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null 2>&1; then
  apt update -y && apt install -y vnstat iproute2 curl jq
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release && yum install -y vnstat iproute curl jq
else
  echo -e "${YELLOW}⚠️ 未知包管理器，请手动安装 vnstat、iproute2、curl、jq${RESET}"
fi

# 初始化配置文件
if [ ! -f "$CONFIG_FILE" ]; then
  echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
  echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi

source "$CONFIG_FILE"

# 初始化 vnstat
echo "✅ [2/6] 初始化 vnStat 数据库..."
vnstat -u -i "$IFACE" || true
sleep 2
systemctl enable vnstat 2>/dev/null || true
systemctl restart vnstat 2>/dev/null || true

# 创建限速脚本
echo "📝 [3/6] 创建限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source \$CONFIG_FILE

USAGE=\$(vnstat --oneline -i "\$IFACE" | cut -d\; -f11 | sed 's/ GiB//')
USAGE_FLOAT=\$(printf "%.0f" "\$USAGE")

if (( USAGE_FLOAT >= LIMIT_GB )); then
  PERCENT=\$(( USAGE_FLOAT * 100 / LIMIT_GB ))
  echo "[限速] 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），已超过限制，开始限速..."
  tc qdisc del dev \$IFACE root 2>/dev/null || true
  tc qdisc add dev \$IFACE root tbf rate \$LIMIT_RATE burst 32kbit latency 400ms
else
  PERCENT=\$(( USAGE_FLOAT * 100 / LIMIT_GB ))
  echo "[正常] 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），未超过限制"
fi
EOL
chmod +x /root/limit_bandwidth.sh

# 创建解除限速脚本
echo "📝 [4/6] 创建解除限速脚本..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
tc qdisc del dev \$IFACE root 2>/dev/null || true
EOL
chmod +x /root/clear_limit.sh

# 添加定时任务
echo "📅 [5/6] 写入定时任务..."
crontab -l 2>/dev/null | grep -v "limit_bandwidth.sh" | grep -v "clear_limit.sh" > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

# 交互菜单函数
ce_menu() {
  get_usage_info() {
    RAW=$(vnstat --oneline -i "$IFACE" 2>/dev/null | cut -d\; -f11 | sed 's/ GiB//')
    USAGE=$(printf "%.1f" "$RAW")
    USAGE_PERCENT=$(awk -v u="$RAW" -v l="$LIMIT_GB" 'BEGIN { printf "%.1f", (u / l) * 100 }')
    echo "$USAGE" "$USAGE_PERCENT"
  }

  while true; do
    clear
    read USAGE USAGE_PERCENT < <(get_usage_info)

    echo -e "${CYAN}╔════════════════════════════════════════════════╗"
    echo -e "║        🚦 流量限速管理控制台（ce）              ║"
    echo -e "╚════════════════════════════════════════════════╝${RESET}"
    echo -e "${YELLOW}当前版本：v${VERSION}${RESET}"
    echo -e "${YELLOW}当前网卡：${IFACE}${RESET}"
    echo -e "${GREEN}已用流量：${USAGE} GiB / ${LIMIT_GB} GiB（${USAGE_PERCENT}%）${RESET}"
    echo ""
    echo -e "${GREEN}1.${RESET} 检查是否应限速"
    echo -e "${GREEN}2.${RESET} 手动解除限速"
    echo -e "${GREEN}3.${RESET} 查看限速状态"
    echo -e "${GREEN}4.${RESET} 查看每日流量"
    echo -e "${GREEN}5.${RESET} 删除限速脚本"
    echo -e "${GREEN}6.${RESET} 修改限速配置"
    echo -e "${GREEN}7.${RESET} 退出"
    echo -e "${GREEN}8.${RESET} 检查脚本更新"
    echo ""
    read -p "👉 请选择操作 [1-8]: " opt
    case "$opt" in
      1) bash /root/limit_bandwidth.sh ;;
      2) bash /root/clear_limit.sh ;;
      3) tc -s qdisc ls dev "$IFACE" ;;
      4) vnstat -d ;;
      5)
        rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh
        echo -e "${YELLOW}已删除所有限速相关脚本${RESET}"
        echo -e "${YELLOW}请手动删除本脚本文件：$SCRIPT_PATH${RESET}"
        break
        ;;
      6)
        echo -e "\n当前限制：${YELLOW}${LIMIT_GB} GiB${RESET}，限速：${YELLOW}${LIMIT_RATE}${RESET}"
        read -p "🔧 新的每日流量限制（GiB）: " new_gb
        read -p "🚀 新的限速值（如 512kbit、1mbit）: " new_rate
        if [[ "$new_gb" =~ ^[0-9]+$ ]] && [[ "$new_rate" =~ ^[0-9]+(kbit|mbit)$ ]]; then
          echo "LIMIT_GB=$new_gb" > $CONFIG_FILE
          echo "LIMIT_RATE=$new_rate" >> $CONFIG_FILE
          echo -e "${GREEN}✅ 配置已更新${RESET}"
          source "$CONFIG_FILE"
        else
          echo -e "${RED}❌ 输入无效${RESET}"
        fi
        ;;
      7) break ;;
      8) check_update ;;
      *) echo -e "${RED}❌ 无效选项${RESET}" ;;
    esac
    read -p "⏎ 按回车继续..." dummy
  done
}

# 安装完成提示
echo -e "${GREEN}🎉 安装完成！${RESET}"
echo "🎯 使用命令 'bash $SCRIPT_PATH' 进入交互式管理面板"
echo "✅ 每小时检测是否超限，超出 $LIMIT_GB GiB 自动限速 $LIMIT_RATE"
echo "⏰ 每天 0 点自动解除限速并刷新流量统计"
echo "📡 可随时运行 '$0 --update' 来检查脚本更新"

# 启动交互菜单
ce_menu