#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.0"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE="/etc/limit_config.conf"

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====== 更新检查 ======
check_update() {
  echo "📡 正在检查更新..."
  LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
           | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
  if [[ "$LATEST" != "$VERSION" ]]; then
    echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
    read -p "是否立即更新？[Y/n] " choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
           -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "✅ 更新完成，请重新运行 ./install_limit.sh"
      exit 0
    else
      echo "🚫 已取消更新"
    fi
  else
    echo "✅ 当前已经是最新版本（$VERSION）"
  fi
}

# ====== 交互式管理面板 ======
run_console() {
  # 载入配置与环境
  source "$CONFIG_FILE"
  IFACE=$(ip -o link show \
           | awk -F': ' '{print $2}' \
           | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
           | head -n1)

  get_usage_info() {
    RAW=$(vnstat --oneline -i "$IFACE" | cut -d\; -f11 | sed 's/ GiB//')
    USAGE=$(printf "%.1f" "$RAW")
    PERCENT=$(awk -v u="$RAW" -v l="$LIMIT_GB" 'BEGIN{ printf "%.1f", u*100/l }')
    echo "$USAGE" "$PERCENT"
  }

  while true; do
    clear
    read USAGE USAGE_PERCENT < <(get_usage_info)
    echo -e "\033[1;36m╔══════════ 流量限速管理控制台 (ce) ══════════╗\033[0m"
    echo -e "  版本：v$VERSION    网卡：$IFACE"
    echo -e "  已用：$USAGE GiB / $LIMIT_GB GiB ($USAGE_PERCENT%)"
    echo ""
    echo " 1) 检查限速状态并执行限速"
    echo " 2) 手动解除限速"
    echo " 3) 查看限速规则"
    echo " 4) 查看每日流量"
    echo " 5) 删除所有限速脚本"
    echo " 6) 修改流量/速率配置"
    echo " 7) 退出"
    echo " 8) 检查脚本更新"
    echo ""
    read -p "请选择 [1-8]: " opt
    case "$opt" in
      1) bash "$SCRIPT_PATH" limit ;;
      2) bash "$SCRIPT_PATH" clear ;;
      3) tc -s qdisc ls dev "$IFACE" ;;
      4) vnstat -d ;;
      5)
        rm -f "$SCRIPT_PATH" /root/limit_bandwidth.sh /root/clear_limit.sh
        echo "✅ 已删除所有限速相关脚本"
        exit 0
        ;;
      6)
        echo "当前：${LIMIT_GB}GiB，${LIMIT_RATE}"
        read -p "新每日流量(GiB): " new_gb
        read -p "新限速(如512kbit): " new_rate
        if [[ "$new_gb" =~ ^[0-9]+$ ]] && [[ "$new_rate" =~ ^[0-9]+(kbit|mbit)$ ]]; then
          echo "LIMIT_GB=$new_gb" > "$CONFIG_FILE"
          echo "LIMIT_RATE=$new_rate" >> "$CONFIG_FILE"
          echo "✅ 配置已更新"
        else
          echo "❌ 输入无效"
        fi
        ;;
      7) exit 0 ;;
      8) bash "$SCRIPT_PATH" --update ;;
      *) echo "❌ 无效选项" ;;
    esac
    read -p "按回车继续..." dummy
  done
}

# ====== 限速逻辑 ======
do_limit() {
  source "$CONFIG_FILE"
  IFACE=$(ip -o link show \
           | awk -F': ' '{print $2}' \
           | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
           | head -n1)
  USAGE=$(vnstat --oneline -i "$IFACE" | cut -d\; -f11 | sed 's/ GiB//' | xargs printf "%.0f")
  if (( USAGE >= LIMIT_GB )); then
    echo "[限速] 已用 $USAGE GiB ，开始限速 $LIMIT_RATE"
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root tbf rate "$LIMIT_RATE" burst 32kbit latency 400ms
  else
    echo "[正常] 已用 $USAGE GiB ，未超过限制"
  fi
}

# ====== 解除限速 ======
do_clear() {
  IFACE=$(ip -o link show \
           | awk -F': ' '{print $2}' \
           | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
           | head -n1)
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
}

# ====== 主流程 ======
case "$1" in
  --update) check_update ;;
  ce) run_console ;;
  limit) do_limit ;;
  clear) do_clear ;;
  *)
    # 安装/初始化流程
    echo "🛠 开始安装限速脚本 (v$VERSION)..."

    # 自我保存
    if [ ! -f "$SCRIPT_PATH" ]; then
      echo "💾 保存脚本到 $SCRIPT_PATH"
      cp "$0" "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
    fi

    # 初始化配置
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ ! -f "$CONFIG_FILE" ]; then
      echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
      echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
    fi

    # 安装依赖
    echo "📦 安装依赖 vnstat/iproute2/curl..."
    if command -v apt >/dev/null; then
      apt update -y && apt install -y vnstat iproute2 curl jq
    elif command -v yum >/dev/null; then
      yum install -y epel-release && yum install -y vnstat iproute curl jq
    else
      echo "⚠️ 未知包管理器，请自行安装 vnstat/iproute2/curl/jq"
    fi

    # 初始化 vnstat
    echo "🔧 初始化 vnstat..."
    IFACE=$(ip -o link show \
             | awk -F': ' '{print $2}' \
             | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
             | head -n1)
    vnstat -u -i "$IFACE" || true
    systemctl enable vnstat
    systemctl restart vnstat

    # 写入定时任务
    echo "⏰ 写入 crontab..."
    ( crontab -l 2>/dev/null | grep -v "install_limit.sh" ; echo "0 * * * * $SCRIPT_PATH limit" ; echo "0 0 * * * $SCRIPT_PATH clear && vnstat -u -i $IFACE && vnstat --update" ) \
      | crontab -

    echo ""
    echo "🎉 安装完成！"
    echo "  - 每小时自动限速检测"
    echo "  - 每天 0 点解除限速并刷新"
    echo "  - 使用 'bash install_limit.sh ce' 进入管理面板"
    echo "  - 使用 '--update' 检查脚本新版本"
    ;;
esac