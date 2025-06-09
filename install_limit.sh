#!/bin/bash
set -e

# ====== 基本信息 ======
VERSION="1.0.0"
REPO="Alanniea/ce"
CONFIG_FILE="/etc/limit_config.conf"
SCRIPT_INSTALLER_PATH="/root/install_limit.sh" # Path where this script will save itself
LIMIT_BANDWIDTH_SCRIPT="/root/limit_bandwidth.sh"
CLEAR_LIMIT_SCRIPT="/root/clear_limit.sh"
CE_COMMAND_PATH="/usr/local/bin/ce"

# Ensure /etc exists
mkdir -p /etc

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

# ====== 辅助函数 ======

# Function to get network interface
get_interface() {
    IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n 1)
    if [ -z "$IFACE" ]; then
        echo -e "${RED}⚠️ 未检测到有效网卡，请手动设置 IFACE 变量${RESET}"
        exit 1
    fi
    echo "$IFACE"
}

# Function to get usage information for the 'ce' menu
get_usage_info() {
    local iface_arg="$1"
    RAW=$(vnstat --oneline -i "$iface_arg" 2>/dev/null | cut -d';' -f11 | sed 's/ GiB//')
    USAGE=$(printf "%.1f" "$RAW")
    
    # Ensure LIMIT_GB is loaded from config before calculation
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    if [[ -z "$LIMIT_GB" ]]; then
        LIMIT_GB=$DEFAULT_GB
    fi

    USAGE_PERCENT=$(awk -v u="$RAW" -v l="$LIMIT_GB" 'BEGIN { printf "%.1f", (u / l) * 100 }')
    echo "$USAGE" "$USAGE_PERCENT"
}

# Function to get today's traffic for the 'ce' menu
get_today_traffic() {
    local iface_arg="$1"
    # Attempt to get JSON output and parse it
    JSON_OUTPUT=$(vnstat -i "$iface_arg" --json 2>/dev/null)
    
    if command -v jq >/dev/null 2>&1; then
        # If jq is installed, use it for robust parsing
        LAST_DAY_TRAFFIC=$(echo "$JSON_OUTPUT" | jq -r '.interfaces[0].traffic.day[-1] | "\(.rx / (1024*1024*1024)) \(.tx / (1024*1024*1024))"')
        RX_GB=$(echo "$LAST_DAY_TRAFFIC" | awk '{printf "%.2f", $1}')
        TX_GB=$(echo "$LAST_DAY_TRAFFIC" | awk '{printf "%.2f", $2}')
        TOTAL_GB=$(echo "$LAST_DAY_TRAFFIC" | awk '{printf "%.2f", $1 + $2}')
        echo "⬆️ 上行流量: ${TX_GB} GiB"
        echo "⬇️ 下行流量: ${RX_GB} GiB"
        echo "📊 总计流量: ${TOTAL_GB} GiB"
    else
        # Fallback if jq is not installed (less precise, direct parsing from vnstat -d)
        echo "jq is not installed. Displaying raw daily traffic from vnstat -d:"
        vnstat -d -i "$iface_arg" | head -n 5 # Show header and latest day
        echo "(Install 'jq' for more detailed output in the menu: apt install jq or yum install jq)"
    fi
}

# ====== 自动更新函数 ======
check_update() {
    echo -e "${CYAN}📡 正在检查更新...${RESET}"
    LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ "$LATEST" != "$VERSION" ]]; then
        echo -e "${YELLOW}🆕 发现新版本: ${LATEST}，当前版本: ${VERSION}${RESET}"
        read -p "是否立即更新 install_limit.sh？[Y/n] " choice
        if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
            curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_INSTALLER_PATH"
            chmod +x "$SCRIPT_INSTALLER_PATH"
            echo -e "${GREEN}✅ 更新完成，请执行 ${SCRIPT_INSTALLER_PATH} 重新安装/配置${RESET}"
            exit 0
        else
            echo -e "${YELLOW}🚫 已取消更新${RESET}"
        fi
    else
        echo -e "${GREEN}✅ 当前已经是最新版本（${VERSION}）${RESET}"
    fi
}

# ====== 参数支持：--update ======
if [[ "$1" == "--update" ]]; then
    check_update
    exit 0
fi

# ====== 安装部分 ======

# 自我保存
if [ ! -f "$SCRIPT_INSTALLER_PATH" ]; then
    echo -e "${CYAN}💾 正在保存 ${SCRIPT_INSTALLER_PATH} 到本地...${RESET}"
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_INSTALLER_PATH"
    chmod +x "$SCRIPT_INSTALLER_PATH"
fi

# 初始化配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${CYAN}⚙️ 初始化配置文件 ${CONFIG_FILE}...${RESET}"
    echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
    echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
else
    echo -e "${GREEN}✅ 配置文件 ${CONFIG_FILE} 已存在${RESET}"
fi

# Source config now so IFACE can use it if needed for defaults, etc.
source "$CONFIG_FILE"

# 自动识别系统和网卡
echo -e "${CYAN}🛠 [0/6] 自动识别系统和网卡...${RESET}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VER=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VER=$(uname -r)
fi
echo -e "检测到系统：${GREEN}${OS_NAME} ${OS_VER}${RESET}"

IFACE=$(get_interface)
echo -e "检测到主用网卡：${GREEN}${IFACE}${RESET}"

# 安装依赖
echo -e "${CYAN}🛠 [1/6] 安装依赖...${RESET}"
if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y vnstat iproute2 curl jq
elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release && yum install -y vnstat iproute curl jq
else
    echo -e "${RED}⚠️ 未知包管理器，请手动安装 vnstat、iproute2 和 jq${RESET}"
fi

# 初始化 vnstat
echo -e "${CYAN}✅ [2/6] 初始化 vnStat 数据库...${RESET}"
vnstat -u -i "$IFACE" || true # Initialize DB, ignore if already exists
sleep 2 # Give vnstat a moment to create the DB
systemctl enable vnstat || true # Enable service
systemctl restart vnstat || true # Restart service

# 创建限速脚本
echo -e "${CYAN}📝 [3/6] 创建限速脚本...${RESET}"
cat > "$LIMIT_BANDWIDTH_SCRIPT" <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE="$CONFIG_FILE"
source \$CONFIG_FILE

# Get current usage in GiB (float)
USAGE=\$(vnstat --oneline -i "\$IFACE" 2>/dev/null | cut -d';' -f11 | sed 's/ GiB//')
USAGE_FLOAT=\$(printf "%.0f" "\$USAGE") # Convert to integer for comparison

# Ensure LIMIT_GB is treated as an integer for comparison
CURRENT_LIMIT_GB=\$LIMIT_GB

if (( USAGE_FLOAT >= CURRENT_LIMIT_GB )); then
    PERCENT=\$(( USAGE_FLOAT * 100 / CURRENT_LIMIT_GB ))
    echo -e "${RED}[限速]${RESET} 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），已超过限制，开始限速..."
    tc qdisc del dev \$IFACE root 2>/dev/null || true
    tc qdisc add dev \$IFACE root tbf rate \$LIMIT_RATE burst 32kbit latency 400ms
else
    PERCENT=\$(( USAGE_FLOAT * 100 / CURRENT_LIMIT_GB ))
    echo -e "${GREEN}[正常]${RESET} 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），未超过限制"
fi
EOL
chmod +x "$LIMIT_BANDWIDTH_SCRIPT"

# 创建解除限速脚本
echo -e "${CYAN}📝 [4/6] 创建解除限速脚本...${RESET}"
cat > "$CLEAR_LIMIT_SCRIPT" <<EOL
#!/bin/bash
IFACE="$IFACE"
echo -e "${GREEN}✅ 正在解除限速...${RESET}"
tc qdisc del dev \$IFACE root 2>/dev/null || true
echo -e "${GREEN}✅ 限速已解除${RESET}"
EOL
chmod +x "$CLEAR_LIMIT_SCRIPT"

# 添加定时任务
echo -e "${CYAN}📅 [5/6] 写入定时任务...${RESET}"
# Remove existing entries to prevent duplicates and keep the crontab clean
(crontab -l 2>/dev/null | grep -v "$LIMIT_BANDWIDTH_SCRIPT" | grep -v "$CLEAR_LIMIT_SCRIPT") | crontab -
# Add new cron entries
echo "0 * * * * $LIMIT_BANDWIDTH_SCRIPT" | crontab -
echo "0 0 * * * $CLEAR_LIMIT_SCRIPT && vnstat -u -i $IFACE && vnstat --update" | crontab -
echo -e "${GREEN}✅ 定时任务已更新${RESET}"

# 创建交互菜单命令 ce
echo -e "${CYAN}🧩 [6/6] 创建交互菜单命令 ce...${RESET}"
cat > "$CE_COMMAND_PATH" <<EOL
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

CONFIG_FILE="$CONFIG_FILE"
SCRIPT_INSTALLER_PATH="$SCRIPT_INSTALLER_PATH"
LIMIT_BANDWIDTH_SCRIPT="$LIMIT_BANDWIDTH_SCRIPT"
CLEAR_LIMIT_SCRIPT="$CLEAR_LIMIT_SCRIPT"
CE_COMMAND_PATH="$CE_COMMAND_PATH"

# Load config values or use defaults
if [ -f "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
else
    LIMIT_GB=$DEFAULT_GB
    LIMIT_RATE="$DEFAULT_RATE"
fi

# Get the script's version from the installer script
VERSION=\$(grep '^VERSION=' "\$SCRIPT_INSTALLER_PATH" 2>/dev/null | cut -d'"' -f2)
if [ -z "\$VERSION" ]; then
    VERSION="未知"
fi

# Get the network interface
IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n 1)
if [ -z "\$IFACE" ]; then
    IFACE="未检测到"
fi

# Function to get usage information for the 'ce' menu
get_usage_info_ce() {
    local iface_arg="\$1"
    RAW=\$(vnstat --oneline -i "\$iface_arg" 2>/dev/null | cut -d';' -f11 | sed 's/ GiB//')
    USAGE=\$(printf "%.1f" "\$RAW")
    
    # Ensure LIMIT_GB is loaded from config before calculation
    if [ -f "\$CONFIG_FILE" ]; then
        source "\$CONFIG_FILE"
    fi

    if [[ -z "\$LIMIT_GB" ]]; then
        LIMIT_GB=$DEFAULT_GB
    fi

    USAGE_PERCENT=\$(awk -v u="\$RAW" -v l="\$LIMIT_GB" 'BEGIN { printf "%.1f", (u / l) * 100 }')
    echo "\$USAGE" "\$USAGE_PERCENT"
}

# Function to get today's traffic for the 'ce' menu
get_today_traffic_ce() {
    local iface_arg="\$1"
    if command -v jq >/dev/null 2>&1; then
        JSON_OUTPUT=\$(vnstat -i "\$iface_arg" --json 2>/dev/null)
        LAST_DAY_TRAFFIC=\$(echo "\$JSON_OUTPUT" | jq -r '.interfaces[0].traffic.day[-1] | "\(.rx / (1024*1024*1024)) \(.tx / (1024*1024*1024))"')
        RX_GB=\$(echo "\$LAST_DAY_TRAFFIC" | awk '{printf "%.2f", \$1}')
        TX_GB=\$(echo "\$LAST_DAY_TRAFFIC" | awk '{printf "%.2f", \$2}')
        TOTAL_GB=\$(echo "\$LAST_DAY_TRAFFIC" | awk '{printf "%.2f", \$1 + \$2}')
        echo -e "${YELLOW}⬆️ 上行流量: \${TX_GB} GiB${RESET}"
        echo -e "${YELLOW}⬇️ 下行流量: \${RX_GB} GiB${RESET}"
        echo -e "${YELLOW}📊 总计流量: \${TOTAL_GB} GiB${RESET}"
    else
        echo -e "${YELLOW}jq 未安装，无法获取详细每日流量信息。${RESET}"
        echo -e "${YELLOW}请运行 'sudo apt install jq' 或 'sudo yum install jq' 安装。${RESET}"
        vnstat -d -i "\$iface_arg" | head -n 5 # Fallback to raw vnstat output
    fi
}


while true; do
    clear
    read USAGE USAGE_PERCENT < <(get_usage_info_ce "\$IFACE")

    echo -e "${CYAN}╔════════════════════════════════════════════════╗"
    echo -e "║        🚦 流量限速管理控制台（ce）              ║"
    echo -e "╚════════════════════════════════════════════════╝${RESET}"
    echo -e "${YELLOW}当前版本：v\${VERSION}${RESET}"
    echo -e "${YELLOW}当前网卡：\${IFACE}${RESET}"
    echo -e "${GREEN}已用流量：\${USAGE} GiB / \${LIMIT_GB} GiB（\${USAGE_PERCENT}%）${RESET}"
    echo ""
    echo -e "${GREEN}1.${RESET} 检查是否应限速"
    echo -e "${GREEN}2.${RESET} 手动解除限速"
    echo -e "${GREEN}3.${RESET} 查看限速状态"
    echo -e "${GREEN}4.${RESET} 查看每日流量"
    echo -e "${GREEN}5.${RESET} 删除限速脚本和命令"
    echo -e "${GREEN}6.${RESET} 修改限速配置"
    echo -e "${GREEN}7.${RESET} 退出"
    echo -e "${GREEN}8.${RESET} 检查 install_limit.sh 更新"
    echo ""
    read -p "👉 请选择操作 [1-8]: " opt
    case "\$opt" in
        1) bash "\$LIMIT_BANDWIDTH_SCRIPT" ;;
        2) bash "\$CLEAR_LIMIT_SCRIPT" ;;
        3) tc -s qdisc ls dev "\$IFACE" ;;
        4) get_today_traffic_ce "\$IFACE" ;;
        5)
            echo -e "${RED}⚠️ 警告：这将删除所有流量限速相关的脚本、配置文件和定时任务。${RESET}"
            read -p "是否确认删除？[Y/n] " confirm_delete
            if [[ "\$confirm_delete" =~ ^[Yy]$ || -z "\$confirm_delete" ]]; then
                rm -f "\$SCRIPT_INSTALLER_PATH" "\$LIMIT_BANDWIDTH_SCRIPT" "\$CLEAR_LIMIT_SCRIPT"
                rm -f "\$CE_COMMAND_PATH"
                rm -f "\$CONFIG_FILE"
                
                # Remove cron entries
                (crontab -l 2>/dev/null | grep -v "\$LIMIT_BANDWIDTH_SCRIPT" | grep -v "\$CLEAR_LIMIT_SCRIPT") | crontab -
                
                # Optionally remove vnstat (user might want to keep it)
                # echo "是否卸载 vnstat？[Y/n]"
                # read -p "👉 请选择： " uninstall_vnstat
                # if [[ "\$uninstall_vnstat" =~ ^[Yy]$ ]]; then
                #     if command -v apt >/dev/null 2>&1; then
                #         apt autoremove -y vnstat
                #     elif command -v yum >/dev/null 2>&1; then
                #         yum autoremove -y vnstat
                #     fi
                # fi

                echo -e "${GREEN}✅ 已删除所有限速相关脚本、配置文件和控制命令${RESET}"
                echo -e "${YELLOW}请注意：vnstat 服务可能仍然在运行，如果您不再需要，请手动卸载。${RESET}"
                break
            else
                echo -e "${YELLOW}🚫 已取消删除操作${RESET}"
            fi
            ;;
        6)
            echo -e "\n当前限制：${YELLOW}\${LIMIT_GB} GiB${RESET}，限速：${YELLOW}\${LIMIT_RATE}${RESET}"
            read -p "🔧 新的每日流量限制（GiB，例如 20）: " new_gb
            read -p "🚀 新的限速值（例如 512kbit, 1mbit）: " new_rate
            if [[ "\$new_gb" =~ ^[0-9]+$ ]] && [[ "\$new_rate" =~ ^[0-9]+(kbit|mbit)$ ]]; then
                echo "LIMIT_GB=\$new_gb" > "\$CONFIG_FILE"
                echo "LIMIT_RATE=\$new_rate" >> "\$CONFIG_FILE"
                # Reload config in the current shell
                source "\$CONFIG_FILE"
                echo -e "${GREEN}✅ 配置已更新。请注意，限速将在下一个小时或手动运行限速脚本时生效。${RESET}"
            else
                echo -e "${RED}❌ 输入无效。流量限制必须是整数，限速值必须是数字加 'kbit' 或 'mbit'。${RESET}"
            fi ;;
        7) 
            echo -e "${GREEN}👋 退出管理面板。${RESET}"
            break ;;
        8) 
            echo -e "${CYAN}正在检查更新...${RESET}"
            bash "\$SCRIPT_INSTALLER_PATH" --update 
            # If update happens, the script will exit. If not, it will return here.
            ;;
        *) echo -e "${RED}❌ 无效选项，请重新选择。${RESET}" ;;
    esac
    read -p "⏎ 按回车继续..." dummy
done
EOL

chmod +x "$CE_COMMAND_PATH"

# ====== 安装完成提示 ======
echo ""
echo -e "${GREEN}🎉 安装完成！${RESET}"
echo "🎯 使用命令 '${CYAN}ce${RESET}' 进入交互式管理面板"
echo -e "${GREEN}✅ 每小时检测是否超限，超出 ${LIMIT_GB} GiB 自动限速 ${LIMIT_RATE}${RESET}"
echo -e "${GREEN}⏰ 每天 0 点自动解除限速并刷新流量统计${RESET}"
echo -e "${CYAN}📡 可随时运行 '${CE_COMMAND_PATH} --update' 或在 'ce' 菜单中选择 [8] 来检查更新${RESET}"
echo ""

