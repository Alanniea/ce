#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

VERSION="1.0.0"
CONFIG_FILE=/etc/limit_config.conf
source $CONFIG_FILE
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n 1)

get_usage_info() {
  RAW=$(vnstat --oneline -i "$IFACE" 2>/dev/null | cut -d\; -f11 | sed 's/ GiB//')
  USAGE=$(printf "%.1f" "$RAW")
  USAGE_PERCENT=$(awk -v u="$RAW" -v l="$LIMIT_GB" 'BEGIN { printf "%.1f", (u / l) * 100 }')
  echo "$USAGE" "$USAGE_PERCENT"
}

# ======== 命令行参数模式 ========
case "$1" in
  --help)
    echo "用法: ce [选项]"
    echo ""
    echo "无参数       进入交互式面板"
    echo "--check       检查是否需要限速"
    echo "--clear       手动解除限速"
    echo "--status      查看限速状态"
    echo "--set GB RATE 设置每日流量限制和限速（如 20 512kbit）"
    echo "--version     显示脚本版本"
    exit 0
    ;;
  --version)
    echo "ce 限速控制台版本: $VERSION"
    exit 0
    ;;
  --check)
    bash /root/limit_bandwidth.sh
    exit $?
    ;;
  --clear)
    bash /root/clear_limit.sh
    exit $?
    ;;
  --status)
    tc -s qdisc ls dev "$IFACE"
    exit $?
    ;;
  --set)
    if [[ "$2" =~ ^[0-9]+$ ]] && [[ "$3" =~ ^[0-9]+(kbit|mbit)$ ]]; then
      echo "LIMIT_GB=$2" > $CONFIG_FILE
      echo "LIMIT_RATE=$3" >> $CONFIG_FILE
      echo -e "${GREEN}✅ 配置已更新：每日限制 ${2}GiB，限速为 ${3}${RESET}"
      exit 0
    else
      echo -e "${RED}❌ 参数错误，请使用示例：ce --set 20 512kbit${RESET}"
      exit 1
    fi
    ;;
esac

# ======== 交互式控制台 ========
while true; do
  clear
  read USAGE USAGE_PERCENT < <(get_usage_info)

  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║        🚦 流量限速管理控制台（ce）              ║"
  echo -e "╚════════════════════════════════════════════════╝${RESET}"
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
  echo ""
  read -p "👉 请选择操作 [1-7]: " opt
  case "$opt" in
    1) bash /root/limit_bandwidth.sh ;;
    2) bash /root/clear_limit.sh ;;
    3) tc -s qdisc ls dev "$IFACE" ;;
    4) vnstat -d ;;
    5)
      rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh
      rm -f /usr/local/bin/ce
      echo -e "${YELLOW}已删除所有限速相关脚本和控制命令${RESET}"
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
      else
        echo -e "${RED}❌ 输入无效${RESET}"
      fi ;;
    7) break ;;
    *) echo -e "${RED}❌ 无效选项${RESET}" ;;
  esac
  read -p "⏎ 按回车继续..." dummy
done
