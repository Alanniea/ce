#!/usr/bin/env bash
set -eo pipefail

# ==================================================
#               基础信息 (Basic Info)
# ==================================================
VERSION="1.1.3"  # 更新于 2025-06-10
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE="/etc/limit_config.conf"

# 确保配置目录存在
mkdir -p "$(dirname "$CONFIG_FILE")"

# 默认配置
DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ==================================================
#              自动保存自身 (Self-Save)
# ==================================================
if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
    echo "💾 正在保存 install_limit.sh 到 $SCRIPT_PATH..."
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ 已保存。请通过执行 $SCRIPT_PATH 运行新脚本。"
    exit 0
fi

# ==================================================
#              自动更新函数 (Update Function)
# ==================================================
check_update() {
    echo "📡 正在检查更新..."
    LATEST=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
             | grep -E '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ -n "$LATEST" && "$LATEST" != "$VERSION" ]]; then
        echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
        read -rp "是否立即更新？[Y/n] " choice
        if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
            curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo "✅ 更新完成，请重新执行 $SCRIPT_PATH 以使用新版本。"
            exit 0
        else
            echo "🚫 已取消更新。"
        fi
    else
        echo "✅ 当前已是最新版本 ($VERSION)。"
    fi
}

# 支持 --update 参数
if [[ "$1" == "--update" ]]; then
    check_update
    exit 0
fi

# ==================================================
#             初始化配置 (Initialize Config)
# ==================================================
if [[ ! -f "$CONFIG_FILE" ]]; then
    {
      echo "LIMIT_GB=$DEFAULT_GB"
      echo "LIMIT_RATE=$DEFAULT_RATE"
    } > "$CONFIG_FILE"
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ==================================================
#             步骤 0: 检测系统与网卡
# ==================================================
echo "🛠️ [0/6] 检测系统与网卡..."
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VER=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VER=$(uname -r)
fi
echo "  - 系统 (OS): $OS_NAME $OS_VER"

# 自动检测主网卡
IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
if [[ -z "$IFACE" ]]; then
    IFACE=$(ip -o link show | awk -F': ' '{print $2}' \
             | grep -Ev '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
fi
if [[ -z "$IFACE" ]]; then
    echo "❌ 错误：未检测到有效网卡，请手动在脚本中设置 IFACE 变量。"
    exit 1
fi
echo "  - 主网卡 (Interface): $IFACE"

# ==================================================
#                 步骤 1: 安装依赖
# ==================================================
echo "🛠️ [1/6] 安装依赖..."
if command -v apt >/dev/null; then
    apt update -y
    apt install -y vnstat iproute2 curl jq speedtest-cli
elif command -v yum >/dev/null; then
    yum install -y epel-release
    yum install -y vnstat iproute curl jq speedtest-cli
else
    echo "⚠️ 未知包管理器，请手动安装 vnstat, iproute2, curl, jq, speedtest-cli"
fi

# ==================================================
#               步骤 2: 初始化 vnStat
# ==================================================
echo "🛠️ [2/6] 初始化 vnStat..."
# 检测 vnstat 版本
VNSTAT_VERSION=$(vnstat --version 2>/dev/null | head -n1 | awk '{print $2}')
version_ge() {
    printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1 | grep -qx "$2"
}

if version_ge "${VNSTAT_VERSION:-0}" "2.7"; then
    VNSTAT_ADD_CMD="vnstat --add -i"
else
    VNSTAT_ADD_CMD="vnstat --create -i"
fi

echo "  - 准备执行: $VNSTAT_ADD_CMD $IFACE"
$VNSTAT_ADD_CMD "$IFACE" || true

# 启用并重启服务
if systemctl list-unit-files | grep -q 'vnstatd.service'; then
    SERVICE_NAME="vnstatd"
else
    SERVICE_NAME="vnstat"
fi
echo "  - 启用并重启服务: $SERVICE_NAME"
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 2

if ! vnstat -i "$IFACE" >/dev/null 2>&1; then
    echo "❌ 警告: vnstat 数据库未成功为 '$IFACE' 初始化，请手动检查。"
else
    echo "✅ vnstat 已成功监控 '$IFACE'。"
fi

# ==================================================
#               步骤 3: 生成限速脚本
# ==================================================
echo "📝 [3/6] 生成限速脚本 (limit_bandwidth.sh)..."
cat > /root/limit_bandwidth.sh <<'EOL'
#!/usr/bin/env bash
set -eo pipefail

IFACE="'"$IFACE"'"
CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE"

TODAY=$(date '+%Y-%m-%d')
RX_KIB=$(vnstat --json d -i "$IFACE" \
         | jq --arg d "$TODAY" '.interfaces[0].traffic.days[] \
         | select(.id == $d).rx // 0')
USAGE_GB=$(awk "BEGIN{printf \"%.2f\", $RX_KIB/1024/1024}")
PCT=$(awk "BEGIN{printf \"%d\", ($USAGE_GB/$LIMIT_GB)*100}")

if (( $(awk "BEGIN{print ($USAGE_GB >= $LIMIT_GB)}") )); then
    echo "[限速] ${USAGE_GB}GiB (${PCT}%) → 达到阈值，限速至 $LIMIT_RATE"
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root tbf rate "$LIMIT_RATE" burst 32kbit latency 400ms
else
    echo "[正常] ${USAGE_GB}GiB (${PCT}%) → 未达到阈值，解除限速"
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
fi

date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

# ==================================================
#            步骤 4: 生成解除限速脚本
# ==================================================
echo "📝 [4/6] 生成解除限速脚本 (clear_limit.sh)..."
cat > /root/clear_limit.sh <<EOL
#!/usr/bin/env bash
set -e
IFACE="$IFACE"
echo "正在清除网卡 $IFACE 的限速规则..."
tc qdisc del dev "$IFACE" root 2>/dev/null || true
echo "✅ 已清除限速。"
EOL
chmod +x /root/clear_limit.sh

# ==================================================
#               步骤 5: 写入 cron 任务
# ==================================================
echo "📅 [5/6] 设置 cron 定时任务..."
crontab -l 2>/dev/null \
  | grep -Ev 'limit_bandwidth\.sh|clear_limit\.sh|speed_test\.sh' \
  > /tmp/cron.bak || true

cat >> /tmp/cron.bak <<EOF
0 * * * * /root/limit_bandwidth.sh >> /var/log/limit.log 2>&1
0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE
EOF

crontab /tmp/cron.bak
rm -f /tmp/cron.bak

# ==================================================
#               附加功能: 测速脚本
# ==================================================
echo "📡 [附加] 生成测速脚本 (speed_test.sh)..."
cat > /root/speed_test.sh <<'EOF'
#!/usr/bin/env bash
set -eo pipefail

echo "🌐 正在进行 speedtest..."
speedtest --simple

echo "🔄 测速完成，更新 vnStat 数据库..."
vnstat -u -i "'"$IFACE"'"
EOF
chmod +x /root/speed_test.sh

# ==================================================
#               步骤 6: 生成交互命令 ce
# ==================================================
echo "🧩 [6/6] 生成控制台命令 (ce)..."
cat > /usr/local/bin/ce <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; RESET='\033[0m'

if [[ "$1" == "--update" ]]; then
    exec /root/install_limit.sh --update
fi

CONFIG_FILE=/etc/limit_config.conf
# shellcheck disable=SC1090
source "$CONFIG_FILE"

VERSION=$(grep '^VERSION=' /root/install_limit.sh | cut -d'"' -f2)
IFACE=$(ip -4 route get 1.1.1.1 | awk '{print $5; exit}')
[[ -z "$IFACE" ]] && IFACE=$(ip -o link show | awk -F': ' '{print $2}' \
                     | grep -Ev '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)

show_menu() {
    clear
    TODAY=$(date '+%Y-%m-%d')
    OS_INFO=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    IP4=$(curl -s4 ifconfig.me || echo "N/A")
    LAST_RUN=$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")

    JSON=$(vnstat --json d -i "$IFACE" 2>/dev/null)
    if [[ -n "$JSON" ]]; then
        DATA=$(echo "$JSON" | jq --arg d "$TODAY" '.interfaces[0].traffic.days[] | select(.id==$d)')
        RX_GB=$(echo "$DATA" | jq -r '.rx // 0' | awk '{printf "%.2f", $1/1024/1024}')
        TX_GB=$(echo "$DATA" | jq -r '.tx // 0' | awk '{printf "%.2f", $1/1024/1024}')
        PCT=$(awk "BEGIN{printf \"%.1f\", $RX_GB/$LIMIT_GB*100}")
    else
        RX_GB="N/A"; TX_GB="N/A"; PCT="N/A"
    fi

    TC_OUT=$(tc qdisc show dev "$IFACE" 2>/dev/null)
    if grep -q "tbf" <<<"$TC_OUT"; then
        LIMIT_STATE="${GREEN}✅ 限速中${RESET}"
        CUR_RATE=$(grep -oP 'rate \K\S+' <<<"$TC_OUT")
    else
        LIMIT_STATE="${YELLOW}🆗 未限速${RESET}"
        CUR_RATE="-"
    fi

    cat <<-MENU
    ${CYAN}╔═════════════════════════════════╗
    ║   🚦 流量限速管理 (ce) v${VERSION}   ║
    ╚═════════════════════════════════╝${RESET}
    ${YELLOW}📅 日期: ${TODAY}   🌐 网卡: ${IFACE}${RESET}
    ────────────────────────────────────
    ${GREEN}📊 今日: TX ${TX_GB}GiB / RX ${RX_GB}GiB${RESET}
    ${GREEN}📈 使用: ${RX_GB}GiB / ${LIMIT_GB}GiB (${PCT}%)${RESET}
    ${GREEN}🚦 状态: ${LIMIT_STATE} (速率: ${CUR_RATE})${RESET}
    ${GREEN}🕒 上次: ${LAST_RUN}${RESET}
    ────────────────────────────────────
MENU

    # 检查更新提示
    LATEST=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
             | grep -E '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ -n "$LATEST" && "$LATEST" != "$VERSION" ]]; then
        echo -e "${RED}⚠️ 检测到新版本 ${LATEST}，请执行 'ce --update' 更新。${RESET}"
        echo "────────────────────────────────────"
    fi

    cat <<-'OPTIONS'
    ${GREEN}1.${RESET} 立即应用限速
    ${GREEN}2.${RESET} 解除所有限速
    ${GREEN}3.${RESET} 查看 tc 状态
    ${GREEN}4.${RESET} 查看 vnStat 流量
    ${GREEN}5.${RESET} 卸载脚本 & 任务
    ${GREEN}6.${RESET} 修改限速配置
    ${GREEN}7.${RESET} 退出
    ${GREEN}8.${RESET} 检查脚本更新
    ${GREEN}9.${RESET} 执行测速
OPTIONS
}

while true; do
    show_menu
    read -rp "👉 选择 [1-9]: " opt
    case $opt in
        1) /root/limit_bandwidth.sh ;;
        2) /root/clear_limit.sh ;;
        3) tc qdisc show dev "$IFACE" || echo "无限速规则。" ;;
        4) vnstat -d -i "$IFACE" ;;
        5)
            read -rp "❗ 确认卸载所有脚本与任务？[y/N] " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                crontab -l 2>/dev/null \
                  | grep -Ev 'limit_bandwidth\.sh|clear_limit\.sh|speed_test\.sh' \
                  | crontab -
                rm -f /root/limit_*.sh /usr/local/bin/ce "$CONFIG_FILE"
                echo "✅ 已卸载。"
                exit 0
            fi
            ;;
        6)
            read -rp "新流量限额 (GiB) [回车跳过: $LIMIT_GB]: " new_gb
            read -rp "新限速 (e.g. 512kbit) [回车跳过: $LIMIT_RATE]: " new_rate
            [[ -n "$new_gb" ]] && sed -i "s/^LIMIT_GB=.*/LIMIT_GB=$new_gb/" "$CONFIG_FILE"
            [[ -n "$new_rate" ]] && sed -i "s|^LIMIT_RATE=.*|LIMIT_RATE=$new_rate|" "$CONFIG_FILE"
            echo "✅ 配置已更新，重启脚本生效。"
            ;;
        7) echo "👋 再见！"; exit 0 ;;
        8) /root/install_limit.sh --update ;;
        9) /root/speed_test.sh ;;
        *) echo "❌ 无效选项。" ;;
    esac
    echo
    read -rp "按 Enter 返回菜单..."
done
EOF
chmod +x /usr/local/bin/ce

echo -e "\n🎉 全部完成！"
echo "使用 `ce` 命令管理流量限速。主要路径："
echo "  • 控制台: /usr/local/bin/ce"
echo "  • 配置 : $CONFIG_FILE"
echo "  • 限速脚本: /root/limit_bandwidth.sh"
echo "  • 日志   : /var/log/limit.log"