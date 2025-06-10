#!/bin/bash
set -e

# ==================================================
#               基础信息 (Basic Info)
# ==================================================
# Changelog:
# v1.1.2:
# - Implemented a more robust vnstat command detection by checking the version number.
#   This provides a more reliable way to choose between `--add` (v2.7+) and `--create` (older versions).
# - This fixes the false warning message during installation on modern systems.
# - Standardized the vnstat update command in the helper script.
# v1.1.1:
# - Fixed vnstat initialization for modern versions, improved service detection.
VERSION="1.1.2"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE="/etc/limit_config.conf"
# 确保配置目录存在 (Ensure config directory exists)
mkdir -p /etc

# 默认配置 (Default config)
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
    LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ -n "$LATEST" && "$LATEST" != "$VERSION" ]]; then
        echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
        read -p "是否立即更新？[Y/n] " choice
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

# ==================================================
#           支持 --update 参数 (Handle --update)
# ==================================================
if [[ "$1" == "--update" ]]; then
    check_update
    exit 0
fi

# ==================================================
#             初始化配置 (Initialize Config)
# ==================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
    echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi
source "$CONFIG_FILE"

# ==================================================
#             步骤 0: 检测系统与网卡
# ==================================================
echo "🛠️ [0/6] 检测系统与网卡..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VER=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VER=$(uname -r)
fi
echo "  - 系统 (OS): $OS_NAME $OS_VER"

IFACE=$(ip -4 route get 1.1.1.1 | awk '{print $5}' | head -n1)
if [ -z "$IFACE" ]; then
    echo "⚠️ 无法通过路由表自动检测到主网卡，尝试备用方法..."
    IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
fi

if [ -z "$IFACE" ]; then
    echo "❌ 错误：未检测到有效网卡，请手动在脚本中设置 IFACE 变量。"
    exit 1
fi
echo "  - 主网卡 (Interface): $IFACE"

# ==================================================
#                 步骤 1: 安装依赖
# ==================================================
echo "🛠️ [1/6] 安装依赖..."
if command -v apt >/dev/null; then
    apt update -y && apt install -y vnstat iproute2 curl jq speedtest-cli
elif command -v yum >/dev/null; then
    yum install -y epel-release && yum install -y vnstat iproute curl jq speedtest-cli
else
    echo "⚠️ 未知包管理器，请手动安装 vnstat, iproute2, curl, jq, speedtest-cli"
fi

# ==================================================
#               步骤 2: 初始化 vnStat
# ==================================================
echo "🛠️ [2/6] 初始化 vnStat..."
VNSTAT_ADD_CMD=""

# *** FIX START v1.1.2: 更稳健的 vnstat 命令检测 ***
# 优先通过版本号判断
VNSTAT_VERSION=$(vnstat --version 2>/dev/null | head -n1 | awk '{print $2}')

# 版本比较函数 (A is greater/equal to B)
version_ge() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2"
}

# 根据版本号确定正确的添加网卡命令
# vnstat >= 2.7 使用 --add
if version_ge "${VNSTAT_VERSION:-0}" "2.7"; then
    VNSTAT_ADD_CMD="vnstat --add -i"
# 旧版本（如 1.x）使用 --create 或 -u
elif [ -n "$VNSTAT_VERSION" ]; then
    VNSTAT_ADD_CMD="vnstat --create -i"
# 如果无法获取版本号，则回退到检查 --help 输出
else
    echo "  - 无法检测 vnstat 版本，尝试解析 help 命令..."
    if vnstat --help 2>&1 | grep -q -- '--add'; then
        VNSTAT_ADD_CMD="vnstat --add -i"
    elif vnstat --help 2>&1 | grep -q -- '--create'; then
        VNSTAT_ADD_CMD="vnstat --create -i"
    fi
fi

if [ -n "$VNSTAT_ADD_CMD" ]; then
    echo "  - 检测到适用命令，准备将网卡添加到 vnStat: '$VNSTAT_ADD_CMD $IFACE'"
    # 添加网卡到 vnstat 数据库，`|| true` 确保即使已存在也不会报错退出
    $VNSTAT_ADD_CMD "$IFACE" || true
else
    echo "⚠️ 警告: 无法自动找到添加网卡的 vnstat 命令。"
    echo "   如果之后出现错误，请手动尝试 'vnstat --add -i $IFACE'。"
fi

# 确保 vnstat 服务已启动并设置为开机自启
if systemctl list-units --type=service | grep -q 'vnstatd.service'; then
    SERVICE_NAME="vnstatd"
else
    SERVICE_NAME="vnstat"
fi

echo "  - 启用并重启服务: $SERVICE_NAME"
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 2

# 验证数据库是否为网卡创建成功
if ! vnstat -i "$IFACE" >/dev/null 2>&1; then
    echo "❌ 错误: vnstat 数据库似乎仍未为网卡 '$IFACE' 初始化。"
    echo "   安装将继续，但请务必手动解决此问题。"
else
    echo "✅ vnstat 已成功监控网卡 '$IFACE'。"
fi
# *** FIX END ***


# ==================================================
#               步骤 3: 生成限速脚本
# ==================================================
echo "📝 [3/6] 生成限速脚本 (limit_bandwidth.sh)..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "\$CONFIG_FILE"
TODAY=\$(date '+%Y-%m-%d')
RX_KIB=\$(vnstat --json d -i "\$IFACE" | jq --arg d "\$TODAY" '.interfaces[0].traffic.days[] | select(.id == \$d) | .rx // 0')
USAGE_GB=\$(awk "BEGIN{printf \"%.2f\", \$RX_KIB/1024/1024}")
PCT=\$(awk "BEGIN{printf \"%d\", (\$USAGE_GB/\$LIMIT_GB)*100}")
if awk "BEGIN{exit !(\$USAGE_GB >= \$LIMIT_GB)}"; then
    echo "[限速] \${USAGE_GB}GiB (\${PCT}%) → 达到阈值，开始限速至 \$LIMIT_RATE"
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
    tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
    echo "[正常] \${USAGE_GB}GiB (\${PCT}%) → 未达到阈值，解除限速"
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
fi
date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

# ==================================================
#            步骤 4: 生成解除限速脚本
# ==================================================
echo "📝 [4/6] 生成解除限速脚本 (clear_limit.sh)..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
echo "正在清除网卡 \$IFACE 上的所有 tc 限速规则..."
tc qdisc del dev "\$IFACE" root 2>/dev/null || true
echo "✅ 清除完成。"
EOL
chmod +x /root/clear_limit.sh

# ==================================================
#               步骤 5: 写入 cron 任务
# ==================================================
echo "📅 [5/6] 设置 cron 定时任务..."
(crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh|speed_test.sh') > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh >> /var/log/limit.log 2>&1" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat --update -i $IFACE" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

# ==================================================
#               附加功能: 测速脚本
# ==================================================
echo "📡 [附加] 生成测速脚本 (speed_test.sh)..."
cat > /root/speed_test.sh <<EOF
#!/bin/bash
echo "🌐 正在使用 speedtest-cli 进行测速..."
speedtest --simple
echo "🔄 测速完成，更新 vnStat 数据库..."
# 为确保数据被采集，明确更新指定网卡
vnstat --update -i "$IFACE"
EOF
chmod +x /root/speed_test.sh

# ==================================================
#               步骤 6: 生成交互命令 ce
# ==================================================
echo "🧩 [6/6] 生成交互式控制台命令 (ce)..."
cat > /usr/local/bin/ce <<EOF
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; RESET='\033[0m'

if [[ "\$1" == "--update" ]]; then
    exec /root/install_limit.sh --update
fi

CONFIG_FILE=/etc/limit_config.conf
source "\$CONFIG_FILE"
VERSION=\$(grep '^VERSION=' /root/install_limit.sh | cut -d'"' -f2)
IFACE=\$(ip -4 route get 1.1.1.1 | awk '{print \$5}' | head -n1)
[ -z "\$IFACE" ] && IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)

show_menu() {
    clear
    TODAY=\$(date '+%Y-%m-%d')
    OS_INFO=\$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "N/A")
    IP4=\$(curl -s4 ifconfig.me || echo "未知")
    LAST_RUN=\$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")

    JSON_DATA=\$(vnstat --json d -i "\$IFACE" 2>/dev/null)
    if [[ -n "\$JSON_DATA" ]]; then
        TODAY_DATA=\$(echo "\$JSON_DATA" | jq --arg d "\$TODAY" '.interfaces[0].traffic.days[] | select(.id == \$d)')
        if [[ -z "\$TODAY_DATA" ]]; then
            RX_GB=0.00; TX_GB=0.00;
        else
            RX_KIB=\$(echo "\$TODAY_DATA" | jq '.rx'); TX_KIB=\$(echo "\$TODAY_DATA" | jq '.tx');
            RX_GB=\$(awk "BEGIN{printf \"%.2f\", \$RX_KIB/1024/1024}"); TX_GB=\$(awk "BEGIN{printf \"%.2f\", \$TX_KIB/1024/1024}");
        fi
        PCT=\$(awk "BEGIN{printf \"%.1f\", \$RX_GB/\$LIMIT_GB*100}")
    else
        RX_GB="N/A"; TX_GB="N/A"; PCT="N/A";
    fi

    TC_OUT=\$(tc qdisc show dev "\$IFACE" 2>/dev/null)
    if echo "\$TC_OUT" | grep -q "tbf"; then
        LIMIT_STATE="\${GREEN}✅ 正在限速\${RESET}"; CUR_RATE=\$(echo "\$TC_OUT" | grep -oP 'rate \K\S+');
    else
        LIMIT_STATE="\${YELLOW}🆗 未限速\${RESET}"; CUR_RATE="-";
    fi

    echo -e "\${CYAN}╔════════════════════════════════════════════════════════════╗"
    echo -e "║             🚦 流量限速管理控制台 (ce) v\${VERSION} ║"
    echo -e "╚════════════════════════════════════════════════════════════╝\${RESET}"
    echo -e "\${YELLOW}📅 日期: \${TODAY}   🖥️ 系统: \${OS_INFO}\${RESET}"
    echo -e "\${YELLOW}🌐 网卡: \${IFACE}   🌍 公网 IP: \${IP4}\${RESET}"
    echo -e "--------------------------------------------------------------"
    echo -e "\${GREEN}📊 今日流量: 上行 \${TX_GB} GiB / 下行 \${RX_GB} GiB\${RESET}"
    echo -e "\${GREEN}📈 已用额度: \${RX_GB} GiB / \${LIMIT_GB} GiB (\${PCT}%)\${RESET}"
    echo -e "\${GREEN}🚦 当前状态: \${LIMIT_STATE} (速率: \${CUR_RATE})\${RESET}"
    echo -e "\${GREEN}🕒 上次检测: \${LAST_RUN}\${RESET}"
    echo -e "--------------------------------------------------------------"

    LATEST=\$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ -n "\$LATEST" && "\$LATEST" != "\$VERSION" ]]; then
        echo -e "\${RED}⚠️  检测到新版本(\$LATEST)，建议运行 'ce --update' 更新。\${RESET}"
        echo -e "--------------------------------------------------------------"
    fi

    echo -e "${GREEN}1.${RESET} 立即检查并应用规则"
    echo -e "${GREEN}2.${RESET} 手动解除所有限速"
    echo -e "${GREEN}3.${RESET} 查看 tc 限速状态"
    echo -e "${GREEN}4.${RESET} 查看 vnStat 每日流量"
    echo -e "${GREEN}5.${RESET} ${RED}卸载限速脚本和任务${RESET}"
    echo -e "${GREEN}6.${RESET} 修改限速配置"
    echo -e "${GREEN}7.${RESET} 退出"
    echo -e "${GREEN}8.${RESET} 检查脚本更新"
    echo -e "${GREEN}9.${RESET} 网络测速 (speedtest)"
    echo
}

while true; do
    show_menu
    read -p "👉 请选择操作 [1-9]: " opt
    echo
    case \$opt in
        1) /root/limit_bandwidth.sh;;
        2) /root/clear_limit.sh;;
        3) tc qdisc show dev "\$IFACE" || echo "当前无活动的 tc 规则。";;
        4) vnstat -d -i "\$IFACE";;
        5)
            read -p "$(echo -e "${RED}警告：此操作将删除所有相关脚本和 cron 任务。确定吗？[y/N] ${RESET}")" confirm
            if [[ "\$confirm" =~ ^[Yy]$ ]]; then
                (crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh|speed_test.sh') | crontab -
                rm -f /root/limit_bandwidth.sh /root/clear_limit.sh /root/speed_test.sh /usr/local/bin/ce /etc/limit_config.conf
                echo "✅ 卸载完成。"; exit 0;
            else
                echo "🚫 已取消卸载。";
            fi;;
        6)
            read -p "新流量限额 (GiB) [回车跳过: \$LIMIT_GB]: " new_gb
            read -p "新限速速率 (如 512kbit) [回车跳过: \$LIMIT_RATE]: " new_rate
            if [[ -n "\$new_gb" ]]; then sed -i "s/LIMIT_GB=.*/LIMIT_GB=\$new_gb/" "\$CONFIG_FILE"; fi
            if [[ -n "\$new_rate" ]]; then sed -i "s/LIMIT_RATE=.*/LIMIT_RATE=\$new_rate/" "\$CONFIG_FILE"; fi
            source "\$CONFIG_FILE"; echo "✅ 配置已更新。";;
        7) echo "👋 告辞！"; exit 0;;
        8) /root/install_limit.sh --update;;
        9) /root/speed_test.sh;;
        *) echo -e "\${RED}❌ 无效输入\${RESET}";;
    esac
    echo; read -p "按 [Enter] 键返回主菜单...";
done
EOF
chmod +x /usr/local/bin/ce

echo -e "\n🎉 全部完成！"
echo "您现在可以通过执行 \`${GREEN}ce${RESET}\` 命令来管理流量限速。"
echo "主要脚本和日志："
echo "  - 控制台: /usr/local/bin/ce"
echo "  - 配置文件: $CONFIG_FILE"
echo "  - 限速脚本: /root/limit_bandwidth.sh"
echo "  - 定时任务日志: /var/log/limit.log"

