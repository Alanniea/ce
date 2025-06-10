#!/bin/bash
set -e

# ====== 基础信息 ======

VERSION="1.0.4" # 更新版本号
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
            exit 0 # 更新后退出，提示用户重新执行
        else
            echo "🚫 已取消更新"
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
    # 尝试使用dnf (Fedora 22+)
    if command -v dnf >/dev/null; then
        dnf install -y vnstat iproute curl speedtest-cli
    else
        echo "⚠️ 无法自动安装依赖。请手动安装 vnstat、iproute2 (或iproute)、curl、speedtest-cli。"
        read -p "是否继续安装？(可能会失败) [Y/n] " cont_choice
        if [[ "$cont_choice" =~ ^[Nn]$ ]]; then
            exit 1
        fi
    fi
fi

echo "✅ [2/6] 初始化 vnStat..."
# 确保 vnstat 数据库文件存在并初始化接口，移除 -u 参数
vnstat -i "$IFACE" || true
sleep 2
systemctl enable vnstat
systemctl restart vnstat

echo "📝 [3/6] 生成限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE"

# 获取今天的日期
TODAY=$(date '+%Y-%m-%d')

# 获取今天的 vnstat 流量数据
LINE=$(vnstat -d -i "\$IFACE" 2>/dev/null | grep "\$TODAY")

RX_GB_FLOAT=0 # 初始化接收流量（GiB）为浮点数

if [[ -n "\$LINE" ]]; then
    # 提取接收流量值和单位（第3和第4字段）
    RX_RAW=\$(echo "\$LINE" | awk '{print \$3}')
    RX_UNIT=\$(echo "\$LINE" | awk '{print \$4}')

    # 验证 RX_RAW 是否为数字
    if [[ "\$RX_RAW" =~ ^[0-9]+(\.[0-9]+)?\$ ]]; then
        if [[ "\$RX_UNIT" == "MiB" ]]; then
            RX_GB_FLOAT=\$(awk -v val="\$RX_RAW" 'BEGIN {printf "%.2f", val / 1024}')
        elif [[ "\$RX_UNIT" == "KiB" ]]; then
            RX_GB_FLOAT=\$(awk -v val="\$RX_RAW" 'BEGIN {printf "%.2f", val / (1024 * 1024)}')
        else # 默认为 GiB 或其他未知单位
            RX_GB_FLOAT=\$(awk -v val="\$RX_RAW" 'BEGIN {printf "%.2f", val}')
        fi
    else
        echo "Warning: vnstat 接收流量值 ('\$RX_RAW') 非数字，默认为 0."
    fi
else
    echo "Warning: 未找到 \$TODAY 在 \$IFACE 上的 vnstat 数据，默认为 0 流量使用。"
fi

# 将流量值转换为整数用于比较
USAGE_INT=\$(printf "%.0f" "\$RX_GB_FLOAT") # 四舍五入到最近的整数 GiB

if (( USAGE_INT >= LIMIT_GB )); then
    PCT=\$(awk -v used="\$USAGE_INT" -v limit="\$LIMIT_GB" 'BEGIN{printf "%.0f", used / limit * 100}')
    echo "[限速] \${USAGE_INT}GiB(\${PCT}%) → 开始限速"
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
    tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
    PCT=\$(awk -v used="\$USAGE_INT" -v limit="\$LIMIT_GB" 'BEGIN{printf "%.0f", used / limit * 100}')
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
crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
# 移除了 vnstat -u，只保留 vnstat -i 和 vnstat --update
echo "0 0 * * * /root/clear_limit.sh && vnstat -i \$IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

echo "📡 [附加] 生成测速脚本..."
cat > /root/speed_test.sh <<EOF
#!/bin/bash
echo "🌐 正在测速..."
speedtest --simple
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

while true; do
DATE=$(date '+%Y-%m-%d')
OS_INFO=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2 2>/dev/null || echo "未知")
IP4=$(curl -s ifconfig.me || echo "N/A")
LAST_RUN=$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")

# 获取今天的 vnstat 流量数据
LINE=$(vnstat -d -i "$IFACE" 2>/dev/null | grep "$DATE")

RX_GB_FLOAT=0 # 初始化接收流量（GiB）为浮点数
TX_GB_FLOAT=0 # 初始化发送流量（GiB）为浮点数

if [[ -n "$LINE" ]]; then
    # 提取接收流量值和单位（第3和第4字段）
    RX_RAW=$(echo "$LINE" | awk '{print \$3}')
    RX_UNIT=$(echo "$LINE" | awk '{print \$4}')
    
    # 提取发送流量值和单位（第5和第6字段）
    TX_RAW=$(echo "$LINE" | awk '{print \$5}')
    TX_UNIT=$(echo "$LINE" | awk '{print \$6}')

    # 验证并转换接收流量到 GiB
    if [[ "$RX_RAW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [[ "$RX_UNIT" == "MiB" ]]; then
            RX_GB_FLOAT=$(awk -v val="$RX_RAW" 'BEGIN {printf "%.2f", val / 1024}')
        elif [[ "$RX_UNIT" == "KiB" ]]; then
            RX_GB_FLOAT=$(awk -v val="$RX_RAW" 'BEGIN {printf "%.2f", val / (1024 * 1024)}')
        else # 默认为 GiB
            RX_GB_FLOAT=$(awk -v val="$RX_RAW" 'BEGIN {printf "%.2f", val}')
        fi
    fi

    # 验证并转换发送流量到 GiB
    if [[ "$TX_RAW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [[ "$TX_UNIT" == "MiB" ]]; then
            TX_GB_FLOAT=$(awk -v val="$TX_RAW" 'BEGIN {printf "%.2f", val / 1024}')
        elif [[ "$TX_UNIT" == "KiB" ]]; then
            TX_GB_FLOAT=$(awk -v val="$TX_RAW" 'BEGIN {printf "%.2f", val / (1024 * 1024)}')
        else # 默认为 GiB
            TX_GB_FLOAT=$(awk -v val="$TX_RAW" 'BEGIN {printf "%.2f", val}')
        fi
    fi
fi

UP_STR="上行: ${TX_GB_FLOAT:-0} GiB" # 使用 :-0 确保为空时显示 0
DOWN_STR="下行: ${RX_GB_FLOAT:-0} GiB" # 使用 :-0 确保为空时显示 0
# 计算百分比，确保使用数值且避免除零
PCT=$(awk -v u="${RX_GB_FLOAT:-0}" -v l="$LIMIT_GB" 'BEGIN{ if (l == 0) print "0.0"; else printf "%.1f", u/l*100 }')


TC_OUT=$(tc qdisc show dev "$IFACE" 2>/dev/null)
if echo "$TC_OUT" | grep -q "tbf"; then
    LIMIT_STATE="✅ 正在限速"
    CUR_RATE=$(echo "$TC_OUT" | grep -oP 'rate \K\S+' | head -n1) # 获取第一个匹配的速率
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
echo -e "${GREEN}📈 已用：${RX_GB_FLOAT} GiB / ${LIMIT_GB} GiB (${PCT}%)${RESET}"
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
        echo -e "${YELLOW}正在删除所有脚本、配置和 cron 任务...${RESET}"
        rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh
        rm -f /usr/local/bin/ce
        rm -f /etc/limit_config.conf
        # 清理 crontab 中相关的任务
        crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' | crontab -
        echo -e "${GREEN}✅ 已删除所有脚本和配置${RESET}"
        break ;;
    6)
        echo -e "
当前：${LIMIT_GB}GiB，${LIMIT_RATE}"
        read -p "🔧 新每日流量（GiB，仅输入数字）: " ngb
        read -p "🚀 新限速（例如：512kbit, 1mbit）: " nrt
        # 验证输入格式
        if [[ "$ngb" =~ ^[0-9]+$ ]] && [[ "$nrt" =~ ^[0-9]+(kbit|mbit)$ ]]; then
            echo "LIMIT_GB=$ngb" > "$CONFIG_FILE"
            echo "LIMIT_RATE=$nrt" >> "$CONFIG_FILE"
            echo -e "${GREEN}✅ 配置已更新${RESET}"
            source "$CONFIG_FILE" # 立即加载新配置
        else
            echo -e "${RED}❌ 输入无效。每日流量限额必须是整数，限速必须是数字后跟 'kbit' 或 'mbit' (例如: 512kbit, 1mbit)。${RESET}"
        fi
        ;;
    7) break ;;
    8) /root/install_limit.sh --update ;;
    9) /root/speed_test.sh ;;
    *) echo -e "${RED}❌ 无效选项，请选择 1-9 的数字${RESET}" ;;
esac
read -p "⏎ 回车继续..." dummy
done
EOF

