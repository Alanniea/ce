#!/bin/bash

# install_ce.sh - 流量限速管理系统 (Traffic Limiting Management System)
# 系统要求: Ubuntu 24.04.2 LTS (用户提供信息: Ubuntu 24.04, vnStat 2.12)
# 功能: vnStat + tc 流量监控与限速 (Traffic Monitoring and Limiting with vnStat + tc)
# 新增功能: 每月流量统计与管理 (Monthly traffic statistics and management)

# ==============================================================================
# 脚本配置和变量定义
# ==============================================================================

# 设置严格模式以提高脚本健壮性
# -e: 如果命令以非零状态退出，立即退出
# -u: 将未设置的变量视为错误并退出
# -o pipefail: 管道的退出状态是最后一个失败命令的退出状态
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m' # 新增洋红色
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/etc/ce_traffic_limit.conf"
SERVICE_FILE="/etc/systemd/system/ce-traffic-monitor.service"
TIMER_FILE="/etc/systemd/system/ce-traffic-monitor.timer"
MONITOR_SCRIPT="/usr/local/bin/ce-monitor"
SCRIPT_PATH="/usr/local/bin/ce" # 用户交互快捷命令
INSTALLER_PATH="/usr/local/bin/install_ce.sh" # 安装脚本本身被复制到这里
TRAFFIC_LOG="/var/log/ce-daily-traffic.log" # 流量日志文件

# 脚本更新的远程URL
SCRIPT_REMOTE_URL="https://raw.githubusercontent.com/Alanniea/ce/main/install_ce.sh"

# 全局配置变量，将从 CONFIG_FILE 中加载
# 用于缓存配置，避免冗余的文件I/O
DAILY_LIMIT=
SPEED_LIMIT=
MONTHLY_LIMIT=
INTERFACE=
LIMIT_ENABLED=
LAST_RESET_DATE=
DAILY_START_RX=
DAILY_START_TX=
LAST_MONTHLY_RESET_DATE=
MONTHLY_START_RX=
MONTHLY_START_TX=

# 缓存系统信息，避免重复调用外部命令
CACHED_OS_VERSION=""
CACHED_KERNEL_VERSION=""

# ==============================================================================
# 核心函数定义
# ==============================================================================

# 日志函数
log_message() {
    local type="$1" # 例如：INFO, WARN, ERROR
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${type}: $message" >> "$TRAFFIC_LOG"
}

# 显示进度动画
show_progress() {
    local pid=$1
    local delay=0.1
    local spin_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" # 更现代的旋转字符
    local i=0
    echo -n " "
    while ps -p "$pid" > /dev/null; do
        i=$(( (i+1) % ${#spin_chars} ))
        printf "\b${BLUE}%c${NC}" "${spin_chars:$i:1}"
        sleep "$delay"
    done
    printf "\b \b" # 清除旋转符
}

# 获取系统信息
get_system_info() {
    echo -e "${BLUE}✨ 检测系统信息...${NC}" # Detecting system information...
    CACHED_OS_VERSION=$(lsb_release -d | cut -f2 || echo "未知")
    CACHED_KERNEL_VERSION=$(uname -r || echo "未知")
    echo -e "${GREEN}  ✅ 系统版本: $CACHED_OS_VERSION${NC}" # System version:
    echo -e "${GREEN}  ✅ 内核版本: $CACHED_KERNEL_VERSION${NC}" # Kernel version:
}

# 自动检测网络接口
detect_interface() {
    echo -e "${BLUE}🔎 自动检测网络接口...${NC}" # Auto-detecting network interface...
    # 获取默认路由的接口
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1 || true)
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}❌ 无法自动检测网卡，请手动选择:${NC}" # Unable to auto-detect interface, please select manually:
        ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo || echo "无可用网卡"
        read -rp "${YELLOW}请输入网卡名称: ${NC}" INTERFACE # Please enter the interface name:
        if [ -z "$INTERFACE" ]; then
            echo -e "${RED}🛑 未输入网卡名称，安装中止。${NC}" # No interface name entered, installation aborted.
            log_message "ERROR" "未输入网卡名称，安装中止。"
            exit 1
        fi
        # 验证用户输入的接口名称是否有效
        if ! ip link show "$INTERFACE" &>/dev/null; then
            echo -e "${RED}❌ 错误: 输入的网卡 '$INTERFACE' 无效，安装中止。${NC}" # Error: Entered interface '$INTERFACE' is invalid, installation aborted.
            log_message "ERROR" "输入的网卡 '$INTERFACE' 无效，安装中止。"
            exit 1
        fi
    fi
    echo -e "${GREEN}  🌐 使用网卡: $INTERFACE${NC}" # Using interface:
    log_message "INFO" "检测到并使用网卡: $INTERFACE"
}

# 安装依赖包
install_dependencies() {
    echo -e "${BLUE}📦 安装依赖包...${NC} (这可能需要一些时间)" # Installing dependency packages... (This may take some time)
    (
        apt update && \
        apt install -y vnstat iproute2 bc coreutils jq sqlite3 curl # 添加 curl 用于更新功能
    ) &
    show_progress $!
    wait $!
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 错误: 依赖包安装失败，请检查网络或apt源。${NC}" # Error: Dependency package installation failed, please check network or apt sources.
        log_message "ERROR" "依赖包安装失败。"
        exit 1
    fi
    
    # 配置 vnStat
    if [ -f "/etc/vnstat.conf" ]; then
        cp "/etc/vnstat.conf" "/etc/vnstat.conf.backup" || log_message "WARN" "备份 /etc/vnstat.conf 失败。"
        echo -e "${YELLOW}  ℹ️ 已备份 /etc/vnstat.conf 到 /etc/vnstat.conf.backup${NC}" # Backed up /etc/vnstat.conf to /etc/vnstat.conf.backup
    fi
    
    # 修改 vnStat 配置以提高精度
    cat > "/etc/vnstat.conf" << 'EOF'
# vnStat configuration
DatabaseDir "/var/lib/vnstat"
Locale "-"
MonthRotate 1
DayFormat "%Y-%m-%d"
MonthFormat "%Y-%m"
TopFormat "%Y-%m-%d"
RXCharacter "%"
TXCharacter ":"
RXHourCharacter "r"
TXHourCharacter "t"
UnitMode 0
RateUnit 1
DefaultDecimals 2
HourlyDecimals 1
OutputFormat 1
QueryMode 0
CheckDiskSpace 1
BootVariation 15
TrafficUnit 0
DatabaseSynchronizeAll 1
DatabaseWriteAheadLogging 0
UpdateFileOwner 1
PollInterval 5
OfflineSaveInterval 30
BandwidthDetection 1
MaxBandwidth 1000
Sampletime 5
EOF
    log_message "INFO" "vnStat 配置已更新。"

    # 启动 vnStat 服务
    systemctl enable vnstat || log_message "WARN" "启用 vnstat 服务失败。"
    systemctl restart vnstat || log_message "WARN" "重启 vnstat 服务失败。"
    
    # 为接口添加到 vnStat，如果不存在则创建
    vnstat -i "$INTERFACE" --create 2>/dev/null || log_message "WARN" "为接口 $INTERFACE 创建 vnStat 数据库失败或已存在。"
    
    # 等待 vnStat 初始化
    echo -e "${YELLOW}⏳ 等待vnStat初始化...${NC}" # Waiting for vnStat initialization...
    sleep 5 # 减少等待时间，5秒通常足够
    
    echo -e "${GREEN}✅ 依赖安装完成${NC}" # Dependencies installed.
    log_message "INFO" "所有依赖安装完成。"
}

# 初始化每日流量计数器
init_daily_counter() {
    local today=$(date +%Y-%m-%d)
    # 尝试读取系统网卡字节数，如果失败则默认为 0
    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 直接更新全局变量
    DAILY_START_RX=$current_rx
    DAILY_START_TX=$current_tx
    LAST_RESET_DATE=$today

    # 更新配置文件中的起始值和日期
    # 使用临时文件进行原子更新，避免并发问题或文件损坏
    sed -i.bak "s/^DAILY_START_RX=.*/DAILY_START_RX=$current_rx/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 DAILY_START_RX 失败。"
    sed -i.bak "s/^DAILY_START_TX=.*/DAILY_START_TX=$current_tx/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 DAILY_START_TX 失败。"
    sed -i.bak "s/^LAST_RESET_DATE=.*/LAST_RESET_DATE=$today/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 LAST_RESET_DATE 失败。"
    
    log_message "INFO" "初始化每日计数器: RX=$(format_traffic "$current_rx"), TX=$(format_traffic "$current_tx")"
}

# 初始化每月流量计数器
init_monthly_counter() {
    local this_month=$(date +%Y-%m)
    # 尝试读取系统网卡字节数，如果失败则默认为 0
    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 直接更新全局变量
    MONTHLY_START_RX=$current_rx
    MONTHLY_START_TX=$current_tx
    LAST_MONTHLY_RESET_DATE=$this_month

    # 更新配置文件中的起始值和日期
    sed -i.bak "s/^MONTHLY_START_RX=.*/MONTHLY_START_RX=$current_rx/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 MONTHLY_START_RX 失败。"
    sed -i.bak "s/^MONTHLY_START_TX=.*/MONTHLY_START_TX=$current_tx/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 MONTHLY_START_TX 失败。"
    sed -i.bak "s/^LAST_MONTHLY_RESET_DATE=.*/LAST_MONTHLY_RESET_DATE=$this_month/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 LAST_MONTHLY_RESET_DATE 失败。"
    
    log_message "INFO" "初始化每月计数器: RX=$(format_traffic "$current_rx"), TX=$(format_traffic "$current_tx")"
}

# 创建配置文件
create_config() {
    local today=$(date +%Y-%m-%d)
    local this_month=$(date +%Y-%m)
    # 使用 here-document 写入配置文件，确保变量正确展开
    cat > "$CONFIG_FILE" << EOF
DAILY_LIMIT=${DAILY_LIMIT:-30}
SPEED_LIMIT=${SPEED_LIMIT:-512}
MONTHLY_LIMIT=${MONTHLY_LIMIT:-$(echo "${DAILY_LIMIT:-30} * 10" | bc)}
INTERFACE=$INTERFACE
LIMIT_ENABLED=false
LAST_RESET_DATE=$today
DAILY_START_RX=0
DAILY_START_TX=0
LAST_MONTHLY_RESET_DATE=$this_month
MONTHLY_START_RX=0
MONTHLY_START_TX=0
EOF
    
    # 初始化每日和每月流量计数器
    init_daily_counter
    init_monthly_counter
    
    echo -e "${GREEN}📄 配置文件已创建: $CONFIG_FILE${NC}" # Configuration file created:
    log_message "INFO" "配置文件 $CONFIG_FILE 已创建并初始化。"
}

# 加载配置
load_config() {
    # 确保文件存在且可读，然后加载
    if [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"

        # 将读取的值同步到全局变量
        DAILY_LIMIT=${DAILY_LIMIT}
        SPEED_LIMIT=${SPEED_LIMIT}
        MONTHLY_LIMIT=${MONTHLY_LIMIT}
        INTERFACE=${INTERFACE}
        LIMIT_ENABLED=${LIMIT_ENABLED}
        LAST_RESET_DATE=${LAST_RESET_DATE}
        DAILY_START_RX=${DAILY_START_RX}
        DAILY_START_TX=${DAILY_START_TX}
        LAST_MONTHLY_RESET_DATE=${LAST_MONTHLY_RESET_DATE}
        MONTHLY_START_RX=${MONTHLY_START_RX}
        MONTHLY_START_TX=${MONTHLY_START_TX}

    else
        # 如果在交互模式下找不到配置文件，则提示用户安装
        if [[ "$*" == *"--interactive"* ]]; then
            echo -e "${RED}❌ 错误: 配置文件 $CONFIG_FILE 不存在或无法读取。${NC}" # Error: Configuration file does not exist or is unreadable.
            echo -e "${YELLOW}💡 请先运行安装脚本来初始化系统。${NC}" # Please run the installation script first to initialize the system.
            log_message "ERROR" "配置文件 $CONFIG_FILE 不存在或无法读取，交互模式中止。"
            exit 1
        else
            # 对于非交互式调用，直接退出
            log_message "ERROR" "配置文件 $CONFIG_FILE 不存在或无法读取，脚本中止。"
            exit 1
        fi
    fi
}

# 获取每日流量使用量 (字节) - 优先使用系统网卡统计，负值或异常时回退到 vnStat
# 注意：此函数不再负责触发每日重置。重置逻辑由 monitor_script 处理。
get_daily_usage_bytes() {
    # 确保 INTERFACE 变量已加载，否则重新加载
    if [ -z "$INTERFACE" ]; then
        load_config
    fi

    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    local daily_rx=$((current_rx - DAILY_START_RX))
    local daily_tx=$((current_tx - DAILY_START_TX))
    local daily_total=$((daily_rx + daily_tx))
    
    # 如果流量计算结果为负数（可能发生了网卡计数器重置但未被脚本处理）
    if [ "$daily_total" -lt 0 ]; then
        log_message "WARN" "今日流量计算出现负数，尝试使用vnStat备选。"
        daily_total=$(get_vnstat_daily_bytes)
    fi
    # 注意：如果 DAILY_START_RX/TX 为 0 且 current_rx/tx 不为 0，这是新一天或初次计数
    # 这种情况无需回退到 vnStat，直接使用系统计数即可。
    
    echo "$daily_total"
}

# 获取每月流量使用量 (字节) - 优先使用系统网卡统计，负值或异常时回退到 vnStat
# 注意：此函数不再负责触发每月重置。重置逻辑由 monitor_script 处理。
get_monthly_usage_bytes() {
    # 确保 INTERFACE 变量已加载，否则重新加载
    if [ -z "$INTERFACE" ]; then
        load_config
    fi

    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    local monthly_rx=$((current_rx - MONTHLY_START_RX))
    local monthly_tx=$((current_tx - MONTHLY_START_TX))
    local monthly_total=$((monthly_rx + monthly_tx))

    # 如果流量计算结果为负数
    if [ "$monthly_total" -lt 0 ]; then
        log_message "WARN" "当月流量计算出现负数，尝试使用vnStat备选。"
        monthly_total=$(get_vnstat_monthly_bytes)
    fi
    
    echo "$monthly_total"
}

# vnStat 备选方法 - 获取每日流量字节数
get_vnstat_daily_bytes() {
    local today=$(date +%Y-%m-%d)
    local vnstat_bytes=0
    
    # 优先使用 JSON 输出 (vnStat 2.x 版本支持)
    if command -v jq &> /dev/null; then
        local json_output
        json_output=$(vnstat -i "$INTERFACE" --json d 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output" ] && echo "$json_output" | jq -e '.interfaces[0].traffic.day | length > 0' &>/dev/null; then
            # 查找今日数据，确保 rx/tx 存在，否则默认为 0
            local rx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .rx // 0" 2>/dev/null || echo 0)
            local tx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .tx // 0" 2>/dev/null || echo 0)
            
            # 确保 jq 输出是数字
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                vnstat_bytes=$((rx_bytes + tx_bytes))
            else
                log_message "WARN" "vnStat JSON输出的RX/TX不是数字，尝试回退到文本解析。"
            fi
        else
            log_message "WARN" "vnStat JSON输出为空或无效，尝试回退到文本解析。"
        fi
    fi
    
    # 如果 JSON 解析失败或 jq 未安装，则回退到解析文本输出
    if [ "$vnstat_bytes" -eq 0 ]; then
        local vnstat_line
        vnstat_line=$(vnstat -i "$INTERFACE" -d | grep "$today" | tail -1 || true)
        if [ -n "$vnstat_line" ]; then
            local rx_str=$(echo "$vnstat_line" | awk '{print $2}')
            local tx_str=$(echo "$vnstat_line" | awk '{print $3}')
            vnstat_bytes=$(( $(convert_to_bytes "$rx_str") + $(convert_to_bytes "$tx_str") ))
            log_message "INFO" "使用vnStat文本输出获取今日流量: $vnstat_bytes 字节。"
        else
            log_message "WARN" "无法从vnStat文本输出中获取今日流量。"
        fi
    fi
    
    echo "$vnstat_bytes"
}

# vnStat 备选方法 - 获取每月流量字节数
get_vnstat_monthly_bytes() {
    local this_month=$(date +%Y-%m)
    local vnstat_bytes=0
    
    # 优先使用 JSON 输出
    if command -v jq &> /dev/null; then
        local json_output
        json_output=$(vnstat -i "$INTERFACE" --json m 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output" ] && echo "$json_output" | jq -e '.interfaces[0].traffic.month | length > 0' &>/dev/null; then
            local rx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.month[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m)) | .rx // 0" 2>/dev/null || echo 0)
            local tx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.month[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m)) | .tx // 0" 2>/dev/null || echo 0)
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                vnstat_bytes=$((rx_bytes + tx_bytes))
            else
                log_message "WARN" "vnStat JSON输出的RX/TX不是数字，尝试回退到文本解析。"
            fi
        else
            log_message "WARN" "vnStat JSON输出为空或无效，尝试回退到文本解析。"
        fi
    fi
    
    # 如果 JSON 解析失败或 jq 未安装，则回退到解析文本输出
    if [ "$vnstat_bytes" -eq 0 ]; then
        local vnstat_line
        vnstat_line=$(vnstat -i "$INTERFACE" -m | grep "$this_month" | tail -1 || true)
        if [ -n "$vnstat_line" ]; then
            local rx_str=$(echo "$vnstat_line" | awk '{print $2}')
            local tx_str=$(echo "$vnstat_line" | awk '{print $3}')
            vnstat_bytes=$(( $(convert_to_bytes "$rx_str") + $(convert_to_bytes "$tx_str") ))
            log_message "INFO" "使用vnStat文本输出获取当月流量: $vnstat_bytes 字节。"
        else
            log_message "WARN" "无法从vnStat文本输出中获取当月流量。"
        fi
    fi
    
    echo "$vnstat_bytes"
}

# 将流量单位转换为字节
convert_to_bytes() {
    local input="$1"
    if [ -z "$input" ] || [ "$input" = "--" ]; then
        echo 0
        return
    fi
    
    local number=$(echo "$input" | sed 's/[^0-9.]//g')
    local unit=$(echo "$input" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    
    if [ -z "$number" ]; then
        echo 0
        return
    fi
    
    # bc 进行浮点乘法，cut -d. -f1 获取整数部分
    case "$unit" in
        "KIB"|"KB"|"K") echo "$number * 1024" | bc | cut -d. -f1 ;;
        "MIB"|"MB"|"M") echo "$number * 1024 * 1024" | bc | cut -d. -f1 ;;
        "GIB"|"GB"|"G") echo "$number * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        "TIB"|"TB"|"T") echo "$number * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        *) echo "$number" | cut -d. -f1 ;; # 默认为字节
    esac
}

# 格式化流量显示
format_traffic() {
    local bytes=$1
    # 避免除以零
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
        echo "0B"
        return
    fi

    if (( bytes < 1024 )); then
        echo "${bytes}B"
    elif (( bytes < 1048576 )); then
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    elif (( bytes < 1073741824 )); then
        local mb=$(echo "scale=2; $bytes / 1024 / 1024" | bc)
        echo "${mb}MB"
    else
        local gb=$(echo "scale=3; $bytes / 1024 / 1024 / 1024" | bc)
        echo "${gb}GB"
    fi
}

# 强制刷新 vnStat 并重新计算
force_refresh() {
    echo -e "${YELLOW}🔄 强制刷新流量统计...${NC}" # Forcing traffic stats refresh...
    log_message "INFO" "执行强制刷新流量统计。"
    
    # 强制 vnStat 写入数据并重启服务
    vnstat -i "$INTERFACE" --force 2>/dev/null || log_message "WARN" "vnStat --force 失败，接口可能不存在。"
    systemctl restart vnstat 2>/dev/null || log_message "WARN" "重启 vnstat 服务失败。"
    sleep 3 # 给 vnStat 一些时间来更新
    
    # 重新加载配置
    load_config
    
    # 记录当前状态，此处调用 get_daily/monthly_usage_bytes 不会触发内部重置
    local daily_usage=$(get_daily_usage_bytes)
    local monthly_usage=$(get_monthly_usage_bytes)
    
    log_message "INFO" "强制刷新完成: 今日使用=$(format_traffic "$daily_usage"), 本月使用=$(format_traffic "$monthly_usage")"
    
    echo -e "${GREEN}✅ 刷新完成${NC}" # Refresh complete.
}

# 检查是否达到每日限制
check_daily_limit() {
    # 不再传递参数 'false'，因为 get_daily_usage_bytes 内部不再执行重置检查
    local used_bytes=$(get_daily_usage_bytes)
    local used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    local limit_reached=$(echo "$used_gb >= $DAILY_LIMIT" | bc 2>/dev/null || echo "0")
    echo "$limit_reached"
}

# 检查是否达到每月限制 (目前仅用于显示，无自动限速)
check_monthly_limit() {
    # 不再传递参数 'false'，因为 get_monthly_usage_bytes 内部不再执行重置检查
    local used_bytes=$(get_monthly_usage_bytes)
    local used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    local limit_reached=$(echo "$used_gb >= $MONTHLY_LIMIT" | bc 2>/dev/null || echo "0")
    echo "$limit_reached"
}

# 应用限速 (同时限制上传和下载)
apply_speed_limit() {
    echo -e "${YELLOW}🚦 应用限速设置 (上传和下载)...${NC}" # Applying speed limit settings (upload and download)...
    log_message "INFO" "尝试应用上传和下载限速。"
    
    # 检查网络接口是否有效
    if ! ip link show "$INTERFACE" &>/dev/null; then
        echo -e "${RED}❌ 错误: 网卡 '$INTERFACE' 不存在或无效，无法应用限速。${NC}" # Error: Interface '$INTERFACE' does not exist or is invalid, cannot apply speed limit.
        log_message "ERROR" "网卡 '$INTERFACE' 无效，无法应用限速。"
        return 1
    fi

    # 清除现有规则，忽略错误
    echo -n "${YELLOW}🗑️ 清除旧限速规则...${NC}" # Clearing old speed limit rules...
    # 清除 egress (上传) 规则
    tc qdisc del dev "$INTERFACE" root 2>/dev/null && echo -e "${GREEN}完成 egress${NC}" || echo -e "${YELLOW}无旧 egress 规则或失败${NC}"
    # 清除 ingress (下载) 规则
    tc qdisc del dev "$INTERFACE" ingress 2>/dev/null && echo -e "${GREEN}完成 ingress${NC}" || echo -e "${YELLOW}无旧 ingress 规则或失败${NC}"
    log_message "INFO" "删除旧的TC qdisc (egress 和 ingress)。"
    
    # 设置限速 (将 KB/s 转换为 bit/s)
    local speed_bps=$((SPEED_LIMIT * 8 * 1024))
    
    echo -n "${YELLOW}🚀 应用新限速规则 (${SPEED_LIMIT}KB/s，上传和下载)...${NC}" # Applying new speed limit rules (KB/s, upload and download)...
    
    # 应用上传 (egress) 限速
    if tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 && \
       tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${speed_bps}bit" && \
       tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${speed_bps}bit" ceil "${speed_bps}bit" && \
       tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:10; then
        log_message "INFO" "上传限速已应用: ${SPEED_LIMIT}KB/s"
    else
        echo -e "${RED}❌ 失败 (上传)${NC}" # Failed (upload)
        log_message "ERROR" "上传限速规则应用失败。"
        return 1
    fi

    # 应用下载 (ingress) 限速
    # 为 ingress 创建一个 qdisc，然后使用 filter 将所有进入的流量重定向到 ifb 设备进行处理。
    # ifb (Intermediate Functional Block) 是一个虚拟设备，允许对入站流量应用 egress qdisc。
    # 确保 ifb 设备已加载
    if ! lsmod | grep -q ifb; then
        modprobe ifb || { echo -e "${RED}❌ 错误: 无法加载 ifb 模块。请检查内核配置。${NC}"; log_message "ERROR" "无法加载 ifb 模块。"; return 1; }
        ip link add ifb0 type ifb || { echo -e "${RED}❌ 错误: 无法创建 ifb0 设备。${NC}"; log_message "ERROR" "无法创建 ifb0 设备。"; return 1; }
        ip link set dev ifb0 up || { echo -e "${RED}❌ 错误: 无法启用 ifb0 设备。${NC}"; log_message "ERROR" "无法启用 ifb0 设备。"; return 1; }
        log_message "INFO" "ifb0 设备已创建并启用。"
    fi

    if tc qdisc add dev "$INTERFACE" handle ffff: ingress && \
       tc filter add dev "$INTERFACE" parent ffff: protocol ip u32 match u32 0 0 flowid 1:1 action mirred egress redirect dev ifb0 && \
       tc qdisc add dev ifb0 root handle 1: htb default 30 && \
       tc class add dev ifb0 parent 1: classid 1:1 htb rate "${speed_bps}bit" && \
       tc class add dev ifb0 parent 1:1 classid 1:10 htb rate "${speed_bps}bit" ceil "${speed_bps}bit" && \
       tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 match ip src 0.0.0.0/0 flowid 1:10; then
        log_message "INFO" "下载限速已应用: ${SPEED_LIMIT}KB/s"
    else
        echo -e "${RED}❌ 失败 (下载)${NC}" # Failed (download)
        log_message "ERROR" "下载限速规则应用失败。"
        # 如果下载限速失败，应该尝试移除上传限速以保持一致性
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
        return 1
    fi

    echo -e "${GREEN}✅ 完成${NC}" # Complete
    sed -i.bak "s/^LIMIT_ENABLED=.*/LIMIT_ENABLED=true/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 LIMIT_ENABLED 失败。"
    LIMIT_ENABLED="true" # 更新缓存值
    log_message "INFO" "上传和下载限速已启用: ${SPEED_LIMIT}KB/s"
    echo -e "${GREEN}🚀 上传和下载限速已启用: ${SPEED_LIMIT}KB/s${NC}" # Upload and download speed limit enabled:
    return 0
}

# 移除限速 (同时移除上传和下载)
remove_speed_limit() {
    echo -e "${YELLOW}🛑 移除限速设置 (上传和下载)...${NC}" # Removing speed limit settings (upload and download)...
    log_message "INFO" "尝试移除上传和下载限速。"
    echo -n "${YELLOW}🗑️ 清除上传限速规则...${NC}" # Clearing upload speed limit rules...
    if tc qdisc del dev "$INTERFACE" root 2>/dev/null; then
        echo -e "${GREEN}完成${NC}" # Complete
    else
        echo -e "${YELLOW}无规则或失败${NC}" # No rules or failed
        log_message "WARN" "删除旧的TC egress qdisc 失败或不存在。"
    fi

    echo -n "${YELLOW}🗑️ 清除下载限速规则...${NC}" # Clearing download speed limit rules...
    if tc qdisc del dev "$INTERFACE" ingress 2>/dev/null && \
       tc qdisc del dev ifb0 root 2>/dev/null; then # 移除 ifb 上的根 qdisc
        echo -e "${GREEN}完成${NC}" # Complete
    else
        echo -e "${YELLOW}无规则或失败${NC}" # No rules or failed
        log_message "WARN" "删除旧的TC ingress qdisc 或 ifb0 上的 qdisc 失败或不存在。"
    fi

    # 关闭并移除 ifb 设备（如果存在且不再需要）
    if ip link show ifb0 &>/dev/null; then
        ip link set dev ifb0 down 2>/dev/null || log_message "WARN" "关闭 ifb0 设备失败。"
        ip link del ifb0 type ifb 2>/dev/null || log_message "WARN" "删除 ifb0 设备失败。"
        log_message "INFO" "ifb0 设备已关闭并移除。"
    fi

    sed -i.bak "s/^LIMIT_ENABLED=.*/LIMIT_ENABLED=false/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 LIMIT_ENABLED 失败。"
    LIMIT_ENABLED="false" # 更新缓存值
    log_message "INFO" "上传和下载限速已移除。"
    echo -e "${GREEN}✅ 上传和下载限速已移除${NC}" # Upload and download speed limit removed.
}

# 网络速度测试
speed_test() {
    echo -e "${BLUE}⚡ 开始网络速度测试...${NC}" # Starting network speed test...
    echo -e "${YELLOW}⚠️ 注意: 测试会消耗流量，请确认继续 (y/N): ${NC}" # Warning: Test will consume traffic, please confirm to continue (y/N):
    read -rp "${WHITE}请输入 (y/N): ${NC}" confirm_test # Please enter (y/N):
    if [[ ! "$confirm_test" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}🚫 已取消测试${NC}" # Test cancelled.
        log_message "INFO" "用户取消了速度测试。"
        return
    fi
    
    # 记录测试前流量 (不再传递 'true' 给 get_daily_usage_bytes，因为其不再触发重置)
    local before_bytes=$(get_daily_usage_bytes)
    local before_time=$(date '+%Y-%m-%d %H:%M:%S')
    log_message "INFO" "开始速度测试，测试前流量: $(format_traffic "$before_bytes")"

    if ! command -v speedtest-cli &> /dev/null; then
        echo -n "${YELLOW}⬇️ 安装speedtest-cli...${NC}" # Installing speedtest-cli...
        (apt install -y speedtest-cli) &
        show_progress $!
        wait $!
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ 错误: 无法安装 speedtest-cli。请检查网络或apt源。${NC}" # Error: Unable to install speedtest-cli.
            log_message "ERROR" "安装 speedtest-cli 失败。"
            return 1
        else
            echo -e "${GREEN}✅ 完成${NC}" # Complete
        fi
    fi
    
    echo -n "${YELLOW}🏃‍ 运行 speedtest-cli...${NC}" # Running speedtest-cli...
    # 使用匿名管道将 speedtest-cli 输出重定向到后台子进程
    # 这样可以在捕获 speedtest-cli 输出的同时显示进度动画
    local speedtest_output=""
    speedtest_output=$( (speedtest-cli --simple 2>&1) & show_progress $! && wait $! )
    local speedtest_exit_code=$?

    if [ "$speedtest_exit_code" -ne 0 ]; then
        echo -e "${RED}❌ 失败${NC}" # Failed
        echo -e "${RED}❌ 错误: speedtest-cli 运行失败。${NC}" # Error: speedtest-cli failed to run.
        echo -e "${YELLOW}🔍 诊断信息:${NC}\n$speedtest_output" # Diagnostic info:
        log_message "ERROR" "speedtest-cli 运行失败。输出: $speedtest_output"
        return 1
    else
        echo -e "${GREEN}✅ 完成${NC}" # Complete
        echo "$speedtest_output" # 显示实际测速结果
    fi
    
    echo -e "${YELLOW}📊 测试完成，正在计算流量消耗...${NC}" # Test complete, calculating traffic consumption...
    sleep 2 # 给系统一些时间更新统计数据
    
    # 强制刷新并计算消耗
    force_refresh
    local after_bytes=$(get_daily_usage_bytes) # 不再传递 'true'
    local test_usage=$((after_bytes - before_bytes))
    
    if [ "$test_usage" -gt 0 ]; then
        echo -e "${GREEN}📈 本次测试消耗流量: $(format_traffic "$test_usage")${NC}" # Traffic consumed by this test:
        log_message "INFO" "速度测试消耗: $(format_traffic "$test_usage")"
    else
        echo -e "${YELLOW}⚠️ 流量消耗计算可能不准确（可能为0）。请查看总使用量或稍后重试。${NC}" # Traffic consumption calculation might be inaccurate (possibly 0). Please check total usage or try again later.
        log_message "WARN" "速度测试后流量消耗计算结果不准确 ($test_usage 字节)。"
    fi
}

# 执行系统更新
perform_system_update() {
    echo -e "${BLUE}⬆️ 开始系统更新 (apt update && apt upgrade -y)...${NC} (这可能需要一些时间)" # Starting system update... (This may take some time)
    log_message "INFO" "开始执行系统更新。"
    
    echo -n "${YELLOW}📜 更新软件包列表 (apt update)...${NC}" # Updating package lists...
    (apt update) &
    show_progress $!
    wait $!
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 失败${NC}" # Failed
        echo -e "${RED}❌ 错误: apt update 失败。请检查网络或apt源。${NC}" # Error: apt update failed. Please check network or apt sources.
        log_message "ERROR" "apt update 失败。"
        return 1
    else
        echo -e "${GREEN}✅ 完成${NC}" # Complete
    fi

    echo -n "${YELLOW}✨ 升级已安装软件包 (apt upgrade -y)...${NC}" # Upgrading installed packages...
    (apt upgrade -y) &
    show_progress $!
    wait $!
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 失败${NC}" # Failed
        echo -e "${RED}⚠️ 警告: apt upgrade 失败。可能存在未解决的依赖关系或错误。${NC}" # Warning: apt upgrade failed. There may be unresolved dependencies or errors.
        log_message "WARN" "apt upgrade -y 失败。"
        # 不是致命错误，允许继续
    else
        echo -e "${GREEN}✅ 完成${NC}" # Complete
    fi
    
    echo -e "${GREEN}✅ 系统更新完成。${NC}" # System update complete.
    log_message "INFO" "系统更新操作完成。"
}

# 实时网速显示
show_realtime_speed() {
    load_config "--interactive" # 确保配置已加载
    clear
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                  🌐 实时网速显示 🌐                          ║${NC}" # Real-time Network Speed Display
    echo -e "${MAGENTA}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║  ${WHITE}按 Ctrl+C 退出${NC}                                            ${MAGENTA}║${NC}" # Press Ctrl+C to exit
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local interval=1 # 更新间隔，单位秒
    local rx_bytes_prev=0
    local tx_bytes_prev=0
    
    # 捕获 Ctrl+C，并在退出时恢复光标
    trap 'echo -e "\n${YELLOW}👋 退出实时网速显示...${NC}"; tput cnorm; return' INT
    tput civis # 隐藏光标

    echo -e "${BLUE}⏱️ 正在获取初始数据...${NC}" # Getting initial data...
    # 获取初始字节数
    rx_bytes_prev=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx_bytes_prev=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 初始显示位置
    echo ""
    echo -e "${WHITE}⬇️ 下载速度: calculating...${NC}" # Download Speed:
    echo -e "${WHITE}⬆️ 上传速度: calculating...${NC}" # Upload Speed:
    echo ""

    while true; do
        sleep "$interval"
        
        local rx_bytes_curr=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
        local tx_bytes_curr=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
        
        local rx_diff=$((rx_bytes_curr - rx_bytes_prev))
        local tx_diff=$((tx_bytes_curr - tx_bytes_prev))

        # 处理计数器重置的可能性（如果当前值小于之前的值，则认为计数器已重置）
        if (( rx_diff < 0 )); then rx_diff=$rx_bytes_curr; fi
        if (( tx_diff < 0 )); then tx_diff=$tx_bytes_curr; fi
        
        local download_speed=$(echo "scale=2; $rx_diff / $interval" | bc 2>/dev/null || echo "0")
        local upload_speed=$(echo "scale=2; $tx_diff / $interval" | bc 2>/dev/null || echo "0")

        # 将字节/秒转换为 MB/s 或 KB/s
        local download_speed_fmt=$(format_speed "$download_speed")
        local upload_speed_fmt=$(format_speed "$upload_speed")

        # 移动光标并更新显示
        tput cuu 3 # 向上移动 3 行
        tput el # 清除当前行
        echo -e "${WHITE}⬇️ 下载速度: ${GREEN}${download_speed_fmt}${NC}"
        tput el # 清除当前行
        echo -e "${WHITE}⬆️ 上传速度: ${GREEN}${upload_speed_fmt}${NC}"
        tput el # 清除当前行
        echo "" # 在底部保留空行

        rx_bytes_prev=$rx_bytes_curr
        tx_bytes_prev=$tx_bytes_curr
    done
    tput cnorm # 恢复光标
    trap - INT # 恢复默认的 Ctrl+C 行为
}

# 格式化速度显示 (字节/秒到 KB/s, MB/s)
format_speed() {
    local bytes_per_sec=$1
    if [ -z "$bytes_per_sec" ] || (( $(echo "$bytes_per_sec < 0.01" | bc -l) )); then
        echo "0.00KB/s"
        return
    fi
    
    if (( $(echo "$bytes_per_sec < 1024" | bc -l) )); then
        local kbps=$(echo "scale=2; $bytes_per_sec / 1024" | bc)
        echo "${kbps}KB/s"
    elif (( $(echo "$bytes_per_sec < 1048576" | bc -l) )); then
        local mbps=$(echo "scale=2; $bytes_per_sec / 1024 / 1024" | bc)
        echo "${mbps}MB/s"
    else
        local gbps=$(echo "scale=3; $bytes_per_sec / 1024 / 1024 / 1024" | bc)
        echo "${gbps}GB/s"
    fi
}


# 高级流量统计视图
show_advanced_vnstat_stats() {
    load_config "--interactive" # 确保配置已加载
    clear
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                  📈 高级流量统计 📊                          ║${NC}" # Advanced Traffic Statistics
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${WHITE}--- 📅 最近24小时流量 (Hourly Traffic for Last 24 Hours) ---${NC}"
    echo -e "${YELLOW}ℹ️ 通过vnstat -h获取，可能存在延迟，仅供参考。${NC}" # Obtained via vnstat -h, may have delay, for reference only.
    if ! vnstat -i "$INTERFACE" -h; then
        echo -e "${RED}❌ 无法获取小时统计数据，请检查vnStat是否正常工作。${NC}" # Unable to get hourly statistics, please check if vnStat is working correctly.
    fi
    read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
    clear # 在下一节之前清屏

    echo -e "${WHITE}--- 🗓️ 最近30天流量 (Daily Traffic for Last 30 Days) ---${NC}"
    echo -e "${YELLOW}ℹ️ 通过vnstat -d获取，可能存在延迟，仅供参考。${NC}" # Obtained via vnstat -d, may have delay, for reference only.
    if ! vnstat -i "$INTERFACE" -d; then
        echo -e "${RED}❌ 无法获取每日统计数据，请检查vnStat是否正常工作。${NC}" # Unable to get daily statistics, please check if vnStat is working correctly.
    fi
    read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
    clear # 在下一节之前清屏

    echo -e "${WHITE}--- 📆 最近12个月流量 (Monthly Traffic for Last 12 Months) ---${NC}"
    echo -e "${YELLOW}ℹ️ 通过vnstat -m获取，可能存在延迟，仅供参考。${NC}" # Obtained via vnstat -m, may have delay, for reference only.
    if ! vnstat -i "$INTERFACE" -m; then
        echo -e "${RED}❌ 无法获取每月统计数据，请检查vnStat是否正常工作。${NC}" # Unable to get monthly statistics, please check if vnStat is working correctly.
    fi
    read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
    clear # 清屏
    echo -e "${GREEN}✅ 高级流量统计显示完成。${NC}" # Advanced traffic statistics display complete.
}


# 显示详细流量统计
show_detailed_stats() {
    load_config "--interactive" # 确保在交互模式下加载配置
    
    clear # 清屏以获得更好的显示效果

    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                  📋 详细流量统计 📊                          ║${NC}" # Detailed Traffic Statistics
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 获取精确的每日/每月流量使用量 (带有备选逻辑)
    local precise_daily_total=$(get_daily_usage_bytes)
    local precise_monthly_total=$(get_monthly_usage_bytes)

    echo -e "${WHITE}🌐 系统网卡统计 ($INTERFACE):${NC}" # System Network Interface Statistics
    local current_rx_raw=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo "0")
    local current_tx_raw=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo "0")
    echo -e "  📥 总接收: ${GREEN}$(format_traffic "$current_rx_raw")${NC}" # Total received:
    echo -e "  📤 总发送: ${GREEN}$(format_traffic "$current_tx_raw")${NC}" # Total sent:
    echo ""

    echo -e "${WHITE}📅 今日统计 (${LAST_RESET_DATE}):${NC}" # Today's Statistics:
    echo -e "  ➡️ 今日总计: ${GREEN}$(format_traffic "$precise_daily_total")${NC}" # Today's total:
    echo -e "  (通过系统网卡计数与vnStat备选精确计算)${NC}" # (Precisely calculated via system interface counters and vnStat fallback)
    echo ""

    echo -e "${WHITE}🗓️ 本月统计 (${LAST_MONTHLY_RESET_DATE}):${NC}" # This Month's Statistics:
    echo -e "  ➡️ 本月总计: ${GREEN}$(format_traffic "$precise_monthly_total")${NC}" # This month's total:
    echo -e "  (通过系统网卡计数与vnStat备选精确计算)${NC}" # (Precisely calculated via system interface counters and vnStat fallback)
    echo ""
    
    # vnStat 原始统计 (仅供参考)
    local vnstat_daily_bytes=$(get_vnstat_daily_bytes)
    local vnstat_monthly_bytes=$(get_vnstat_monthly_bytes)
    echo -e "${WHITE}ℹ️ vnStat 原始统计 (仅供参考):${NC}" # vnStat Raw Statistics (for reference only):
    echo -e "  今日 vnStat 显示: ${CYAN}$(format_traffic "$vnstat_daily_bytes")${NC}" # Today's vnStat display:
    echo -e "  本月 vnStat 显示: ${CYAN}$(format_traffic "$vnstat_monthly_bytes")${NC}" # This month's vnStat display:
    echo ""
    
    # 显示最近日志
    echo -e "${WHITE}📜 最近活动日志:${NC}" # Recent Activity Log:
    if [ -f "$TRAFFIC_LOG" ]; then
        if [ "$(wc -l < "$TRAFFIC_LOG")" -gt 0 ]; then
            tail -n 5 "$TRAFFIC_LOG" | while IFS= read -r line; do
                echo -e "  ${YELLOW}$line${NC}"
            done
        else
            echo -e "  ${YELLOW}暂无日志记录${NC}" # No log records yet.
        fi
    else
        echo -e "  ${YELLOW}日志文件不存在: $TRAFFIC_LOG${NC}" # Log file does not exist:
    fi
    echo ""
    
    # 配置信息
    echo -e "${WHITE}⚙️ 当前配置:${NC}" # Current Configuration:
    echo -e "  每日限制: ${GREEN}${DAILY_LIMIT}GB${NC}" # Daily Limit:
    echo -e "  每月限制: ${GREEN}${MONTHLY_LIMIT}GB${NC}" # Monthly Limit:
    echo -e "  限速速度: ${GREEN}${SPEED_LIMIT}KB/s${NC}" # Speed Limit:
    echo -e "  网络接口: ${CYAN}$INTERFACE${NC}" # Network Interface:
    echo -e "  今日计数起始日期: ${WHITE}$LAST_RESET_DATE${NC}" # Daily Count Start Date:
    echo -e "  今日起始RX: ${CYAN}$(format_traffic "$DAILY_START_RX")${NC}" # Daily Start RX:
    echo -e "  今日起始TX: ${CYAN}$(format_traffic "$DAILY_START_TX")${NC}" # Daily Start TX:
    echo -e "  本月计数起始日期: ${WHITE}$LAST_MONTHLY_RESET_DATE${NC}" # Monthly Count Start Date:
    echo -e "  本月起始RX: ${CYAN}$(format_traffic "$MONTHLY_START_RX")${NC}" # Monthly Start RX:
    echo -e "  本月起始TX: ${CYAN}$(format_traffic "$MONTHLY_START_TX")${NC}" # Monthly Start TX:
    echo ""
    echo -e "${YELLOW}💡 提示: 您可以使用菜单中的'修改配置'选项来更改限制值。${NC}" # Hint: You can use the 'Modify Configuration' option in the menu to change limit values.
    echo ""
}

# 修改配置
modify_config() {
    load_config "--interactive" # 确保加载最新配置
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                      🔧 修改配置 ⚙️                          ║${NC}" # Modify Configuration
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}当前每日流量限制: ${GREEN}${DAILY_LIMIT}GB${NC}" # Current daily traffic limit:
    read -rp "${CYAN}请输入新的每日流量限制 (GB, 0为无限制，回车跳过): ${NC}" new_daily_limit # Enter new daily traffic limit (GB, 0 for unlimited, press Enter to skip):
    if [[ -n "$new_daily_limit" ]]; then
        if [[ "$new_daily_limit" =~ ^[0-9]+$ ]] && [ "$new_daily_limit" -ge 0 ]; then
            DAILY_LIMIT="$new_daily_limit"
            sed -i.bak "s/^DAILY_LIMIT=.*/DAILY_LIMIT=$DAILY_LIMIT/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 DAILY_LIMIT 失败。"
            log_message "INFO" "每日流量限制已更新为: ${DAILY_LIMIT}GB"
            echo -e "${GREEN}✅ 每日流量限制已更新为: ${DAILY_LIMIT}GB${NC}"
        else
            echo -e "${RED}❌ 输入无效，每日流量限制未更改。${NC}" # Invalid input, daily traffic limit not changed.
        fi
    fi

    echo ""
    echo -e "${WHITE}当前每月流量限制: ${GREEN}${MONTHLY_LIMIT}GB${NC}" # Current monthly traffic limit:
    read -rp "${CYAN}请输入新的每月流量限制 (GB, 0为无限制，回车跳过): ${NC}" new_monthly_limit # Enter new monthly traffic limit (GB, 0 for unlimited, press Enter to skip):
    if [[ -n "$new_monthly_limit" ]]; then
        if [[ "$new_monthly_limit" =~ ^[0-9]+$ ]] && [ "$new_monthly_limit" -ge 0 ]; then
            MONTHLY_LIMIT="$new_monthly_limit"
            sed -i.bak "s/^MONTHLY_LIMIT=.*/MONTHLY_LIMIT=$MONTHLY_LIMIT/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 MONTHLY_LIMIT 失败。"
            log_message "INFO" "每月流量限制已更新为: ${MONTHLY_LIMIT}GB"
            echo -e "${GREEN}✅ 每月流量限制已更新为: ${MONTHLY_LIMIT}GB${NC}"
        else
            echo -e "${RED}❌ 输入无效，每月流量限制未更改。${NC}" # Invalid input, monthly traffic limit not changed.
        fi
    fi

    echo ""
    echo -e "${WHITE}当前限速速度: ${GREEN}${SPEED_LIMIT}KB/s${NC}" # Current speed limit:
    read -rp "${CYAN}请输入新的限速速度 (KB/s, 0为无限制，回车跳过): ${NC}" new_speed_limit # Enter new speed limit (KB/s, 0 for unlimited, press Enter to skip):
    if [[ -n "$new_speed_limit" ]]; then
        if [[ "$new_speed_limit" =~ ^[0-9]+$ ]] && [ "$new_speed_limit" -ge 0 ]; then
            SPEED_LIMIT="$new_speed_limit"
            sed -i.bak "s/^SPEED_LIMIT=.*/SPEED_LIMIT=$SPEED_LIMIT/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_message "ERROR" "更新 SPEED_LIMIT 失败。"
            log_message "INFO" "限速速度已更新为: ${SPEED_LIMIT}KB/s"
            echo -e "${GREEN}✅ 限速速度已更新为: ${SPEED_LIMIT}KB/s${NC}"
            # 如果限速当前已启用，则重新应用以使新速度生效
            if [ "$LIMIT_ENABLED" = "true" ]; then
                echo -e "${YELLOW}🔄 限速速度已更改，正在重新应用限速规则...${NC}" # Speed limit changed, reapplying speed limit rules...
                apply_speed_limit # 重新应用限速
            fi
        else
            echo -e "${RED}❌ 输入无效，限速速度未更改。${NC}" # Invalid input, speed limit not changed.
        fi # Adjusted to align with other if-else blocks
    fi
    echo ""
    echo -e "${GREEN}✅ 配置修改完成。${NC}" # Configuration modification complete.
    log_message "INFO" "配置修改操作完成。"
}

# 创建监控服务
create_monitor_service() {
    # Systemd 服务文件
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=CE Traffic Monitor Service
After=network.target

[Service]
Type=oneshot
ExecStart=$MONITOR_SCRIPT
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

    # 监控脚本 (由 systemd 执行)
    # 此处的逻辑是从主脚本中复制并调整的，以确保监控脚本的独立性。
    # 每日和每月流量的重置逻辑也集中在此处处理。
    cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
# 注意: 此脚本在 systemd 服务中运行，必须确保其独立性
set -euo pipefail

CONFIG_FILE="/etc/ce_traffic_limit.conf"
TRAFFIC_LOG="/var/log/ce-daily-traffic.log"

# 监控脚本的日志函数
log_monitor_message() {
    local type="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ce-monitor ${type}: $message" >> "$TRAFFIC_LOG"
}

# 加载配置
load_monitor_config() {
    if [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log_monitor_message "ERROR" "配置文件 $CONFIG_FILE 不存在或无法读取，监控服务无法运行。"
        exit 1
    fi
}

# 流量统计函数 (从主脚本的关键逻辑复制)
get_current_usage_bytes_raw_monitor() {
    local current_rx_b=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx_b=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    echo "$current_rx_b $current_tx_b"
}

# 将流量单位转换为字节 (从主脚本的关键逻辑复制)
convert_to_bytes_monitor() {
    local input="$1"
    if [ -z "$input" ] || [ "$input" = "--" ]; then echo 0; return; fi
    local number=$(echo "$input" | sed 's/[^0-9.]//g')
    local unit=$(echo "$input" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    if [ -z "$number" ]; then echo 0; return; fi
    case "$unit" in
        "KIB"|"KB"|"K") echo "$number * 1024" | bc | cut -d. -f1 ;;
        "MIB"|"MB"|"M") echo "$number * 1024 * 1024" | bc | cut -d. -f1 ;;
        "GIB"|"GB"|"G") echo "$number * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        "TIB"|"TB"|"T") echo "$number * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        *) echo "$number" | cut -d. -f1 ;;
    esac
}

# vnStat 备选方法 - 每日 (从主脚本的关键逻辑复制)
get_vnstat_daily_bytes_monitor() {
    local today_m=$(date +%Y-%m-%d)
    local vnstat_bytes_m=0
    if command -v jq &> /dev/null; then
        local json_output_m=$(vnstat -i "$INTERFACE" --json d 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output_m" ] && echo "$json_output_m" | jq -e '.interfaces[0].traffic.day | length > 0' &>/dev/null; then
            local rx_bytes_m=$(echo "$json_output_m" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .rx // 0" 2>/dev/null || echo 0)
            local tx_bytes_m=$(echo "$json_output_m" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .tx // 0" 2>/dev/null || echo 0)
            if [[ "$rx_bytes_m" =~ ^[0-9]+$ ]] && [[ "$tx_bytes_m" =~ ^[0-9]+$ ]]; then vnstat_bytes_m=$((rx_bytes_m + tx_bytes_m)); fi
        fi
    fi
    if [ "$vnstat_bytes_m" -eq 0 ]; then
        local vnstat_line_m=$(vnstat -i "$INTERFACE" -d | grep "$today_m" | tail -1 || true)
        if [ -n "$vnstat_line_m" ]; then
            local rx_str_m=$(echo "$vnstat_line_m" | awk '{print $2}')
            local tx_str_m=$(echo "$vnstat_line_m" | awk '{print $3}')
            vnstat_bytes_m=$(($(convert_to_bytes_monitor "$rx_str_m") + $(convert_to_bytes_monitor "$tx_str_m")))
        fi
    fi
    echo "$vnstat_bytes_m"
}

# vnStat 备选方法 - 每月 (从主脚本的关键逻辑复制)
get_vnstat_monthly_bytes_monitor() {
    local this_month_m=$(date +%Y-%m)
    local vnstat_bytes_m=0
    if command -v jq &> /dev/null; then
        local json_output_m=$(vnstat -i "$INTERFACE" --json m 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output_m" ] && echo "$json_output_m" | jq -e '.interfaces[0].traffic.month | length > 0' &>/dev/null; then
            local rx_bytes_m=$(echo "$json_output_m" | jq -r ".interfaces[0].traffic.month[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m)) | .rx // 0" 2>/dev/null || echo 0)
            local tx_bytes_m=$(echo "$json_output_m" | jq -r ".interfaces[0].traffic.month[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m)) | .tx // 0" 2>/dev/null || echo 0)
            if [[ "$rx_bytes_m" =~ ^[0-9]+$ ]] && [[ "$tx_bytes_m" =~ ^[0-9]+$ ]]; then vnstat_bytes_m=$((rx_bytes_m + tx_bytes_m)); fi
        fi
    fi
    if [ "$vnstat_bytes_m" -eq 0 ]; then
        local vnstat_line_m=$(vnstat -i "$INTERFACE" -m | grep "$this_month_m" | tail -1 || true)
        if [ -n "$vnstat_line_m" ]; then
            local rx_str_m=$(echo "$vnstat_line_m" | awk '{print $2}')
            local tx_str_m=$(echo "$vnstat_line_m" | awk '{print $3}')
            vnstat_bytes_m=$(($(convert_to_bytes_monitor "$rx_str_m") + $(convert_to_bytes_monitor "$tx_str_m")))
        fi
    fi
    echo "$vnstat_bytes_m"
}

# 主要监控逻辑
load_monitor_config

# --- 每日重置逻辑 ---
current_day=$(date +%Y-%m-%d)
if [ "$current_day" != "$LAST_RESET_DATE" ]; then
    log_monitor_message "INFO" "检测到新的一天 ($current_day)，重置每日计数器和限速状态。"
    current_stats=($(get_current_usage_bytes_raw_monitor))
    current_rx_for_reset=${current_stats[0]}
    current_tx_for_reset=${current_stats[1]}

    # 更新配置文件中的起始值和日期
    sed -i.bak "s/^DAILY_START_RX=.*/DAILY_START_RX=$current_rx_for_reset/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 DAILY_START_RX 失败。"
    sed -i.bak "s/^DAILY_START_TX=.*/DAILY_START_TX=$current_tx_for_reset/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 DAILY_START_TX 失败。"
    sed -i.bak "s/^LAST_RESET_DATE=.*/LAST_RESET_DATE=$current_day/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 LAST_RESET_DATE 失败。"
    
    # 如果限速在昨天是启用的，则在新的一天自动解除
    if [ "$LIMIT_ENABLED" = "true" ]; then
        # 移除 egress (上传) 规则
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || log_monitor_message "WARN" "monitor: 删除旧的TC egress qdisc 失败或不存在。"
        # 移除 ingress (下载) 规则
        tc qdisc del dev "$INTERFACE" ingress 2>/dev/null || log_monitor_message "WARN" "monitor: 删除旧的TC ingress qdisc 失败或不存在。"
        tc qdisc del dev ifb0 root 2>/dev/null || log_monitor_message "WARN" "monitor: 删除 ifb0 上的 qdisc 失败或不存在。"
        
        # 关闭并移除 ifb 设备（如果存在）
        if ip link show ifb0 &>/dev/null; then
            ip link set dev ifb0 down 2>/dev/null || log_monitor_message "WARN" "monitor: 关闭 ifb0 设备失败。"
            ip link del ifb0 type ifb 2>/dev/null || log_monitor_message "WARN" "monitor: 删除 ifb0 设备失败。"
            log_monitor_message "INFO" "ifb0 设备已关闭并移除。"
        fi

        sed -i.bak 's/^LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 LIMIT_ENABLED 失败。"
        log_monitor_message "INFO" "新的一天，自动解除限速。"
    fi
    # 重新加载配置，确保后续操作使用最新值
    load_monitor_config
fi

# --- 每月重置逻辑 ---
current_month=$(date +%Y-%m)
if [ "$current_month" != "$LAST_MONTHLY_RESET_DATE" ]; then
    log_monitor_message "INFO" "检测到新的月份 ($current_month)，重置每月计数器。"
    current_stats=($(get_current_usage_bytes_raw_monitor))
    current_rx_for_reset=${current_stats[0]}
    current_tx_for_reset=${current_stats[1]}

    sed -i.bak "s/^MONTHLY_START_RX=.*/MONTHLY_START_RX=$current_rx_for_reset/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 MONTHLY_START_RX 失败。"
    sed -i.bak "s/^MONTHLY_START_TX=.*/MONTHLY_START_TX=$current_tx_for_reset/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 MONTHLY_START_TX 失败。"
    sed -i.bak "s/^LAST_MONTHLY_RESET_DATE=.*/LAST_MONTHLY_RESET_DATE=$current_month/" "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 LAST_MONTHLY_RESET_DATE 失败。"
    # 重新加载配置，确保后续操作使用最新值
    load_monitor_config
fi


# 获取每日流量使用量
daily_current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
daily_current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
daily_total_bytes=$(( (daily_current_rx - DAILY_START_RX) + (daily_current_tx - DAILY_START_TX) ))

# 如果系统统计数据为负数，则使用 vnStat 作为备选
if [ "$daily_total_bytes" -lt 0 ]; then
    log_monitor_message "WARN" "每日流量计算出现负数，使用vnStat备选。"
    daily_total_bytes=$(get_vnstat_daily_bytes_monitor)
fi

# 确保 bc 处理除以零的情况
used_gb=$(echo "scale=3; $daily_total_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
limit_reached=$(echo "$used_gb >= $DAILY_LIMIT" | bc 2>/dev/null || echo "0")

if [ "$limit_reached" -eq 1 ] && [ "$LIMIT_ENABLED" != "true" ]; then
    # 自动启用限速
    local speed_bps=$((SPEED_LIMIT * 8 * 1024))
    
    # 清除旧规则（如果存在）
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || log_monitor_message "WARN" "monitor: 删除旧的TC egress qdisc 失败或不存在 (自动限速前)。"
    tc qdisc del dev "$INTERFACE" ingress 2>/dev/null || log_monitor_message "WARN" "monitor: 删除旧的TC ingress qdisc 失败或不存在 (自动限速前)。"
    tc qdisc del dev ifb0 root 2>/dev/null || log_monitor_message "WARN" "monitor: 删除 ifb0 上的 qdisc 失败或不存在 (自动限速前)。"

    # 应用上传 (egress) 限速
    if tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 && \
       tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${speed_bps}bit" && \
       tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${speed_bps}bit" ceil "${speed_bps}bit" && \
       tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:10; then
        log_monitor_message "INFO" "自动上传限速触发: ${SPEED_LIMIT}KB/s"
    else
        log_monitor_message "ERROR" "monitor: 自动上传限速规则应用失败。"
        # 如果上传限速失败，标记为未启用
        sed -i.bak 's/^LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 LIMIT_ENABLED 失败。"
        return # 退出，因为限速未完全应用
    fi

    # 应用下载 (ingress) 限速
    if ! lsmod | grep -q ifb; then
        modprobe ifb || { log_monitor_message "ERROR" "monitor: 无法加载 ifb 模块。"; return 1; }
        ip link add ifb0 type ifb || { log_monitor_message "ERROR" "monitor: 无法创建 ifb0 设备。"; return 1; }
        ip link set dev ifb0 up || { log_monitor_message "ERROR" "monitor: 无法启用 ifb0 设备。"; return 1; }
        log_monitor_message "INFO" "monitor: ifb0 设备已创建并启用。"
    fi

    if tc qdisc add dev "$INTERFACE" handle ffff: ingress && \
       tc filter add dev "$INTERFACE" parent ffff: protocol ip u32 match u32 0 0 flowid 1:1 action mirred egress redirect dev ifb0 && \
       tc qdisc add dev ifb0 root handle 1: htb default 30 && \
       tc class add dev ifb0 parent 1: classid 1:1 htb rate "${speed_bps}bit" && \
       tc class add dev ifb0 parent 1:1 classid 1:10 htb rate "${speed_bps}bit" ceil "${speed_bps}bit" && \
       tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 match ip src 0.0.0.0/0 flowid 1:10; then
        sed -i.bak 's/^LIMIT_ENABLED=.*/LIMIT_ENABLED=true/' "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 LIMIT_ENABLED 失败 (自动限速)。"
        log_monitor_message "INFO" "自动下载限速触发: 使用量=${used_gb}GB, 速度=${SPEED_LIMIT}KB/s"
    else
        log_monitor_message "ERROR" "monitor: 自动下载限速规则应用失败。"
        # 如果下载限速失败，尝试移除上传限速以保持一致性
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
        sed -i.bak 's/^LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' "$CONFIG_FILE" && rm "$CONFIG_FILE.bak" || log_monitor_message "ERROR" "monitor: 更新 LIMIT_ENABLED 失败。"
    fi
fi
EOF

    chmod +x "$MONITOR_SCRIPT" || log_message "ERROR" "设置监控脚本可执行权限失败。"
    systemctl daemon-reload || log_message "ERROR" "daemon-reload 失败。"
    echo -e "${GREEN}✅ 监控服务脚本已创建: $MONITOR_SCRIPT${NC}" # Monitor script created:
    echo -e "${GREEN}✅ Systemd 服务文件已创建: $SERVICE_FILE${NC}" # Systemd service file created:
    log_message "INFO" "监控服务脚本和Systemd服务文件已创建。"
}

# 创建定时器
create_timer() {
    cat > "$TIMER_FILE" << EOF
[Unit]
Description=CE Traffic Monitor Timer
Requires=ce-traffic-monitor.service

[Timer]
# 每3分钟运行一次服务
OnCalendar=*:0/3
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload || log_message "ERROR" "daemon-reload 失败。"
    systemctl enable ce-traffic-monitor.timer || log_message "ERROR" "启用定时器失败。"
    systemctl start ce-traffic-monitor.timer || log_message "ERROR" "启动定时器失败。"
    echo -e "${GREEN}⏰ Systemd 定时器已创建并启动: $TIMER_FILE${NC}" # Systemd timer created and started:
    log_message "INFO" "Systemd 定时器已创建并启动。"
}

# 更新脚本本身的功能
update_script() {
    echo -e "${BLUE}⬆️ 开始更新脚本...${NC}" # Starting script update...
    log_message "INFO" "开始执行脚本更新。"

    # 检查 curl 是否安装
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}📦 curl 未安装。正在安装 curl...${NC}" # curl is not installed. Installing curl...
        (apt update && apt install -y curl) &
        show_progress $!
        wait $!
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ 错误: 无法安装 curl。请检查网络或apt源，更新失败。${NC}" # Error: Unable to install curl. Please check network or apt sources, update failed.
            log_message "ERROR" "安装 curl 失败，脚本更新中止。"
            return 1
        else
            echo -e "${GREEN}✅ curl 安装完成。${NC}" # curl installed.
        fi
    fi

    local temp_script_file="/tmp/install_ce_new.sh"
    echo -n "${YELLOW}🌐 正在从 $SCRIPT_REMOTE_URL 下载新版本脚本...${NC}" # Downloading new version of script from $SCRIPT_REMATE_URL...
    
    # 下载脚本
    if ! curl -sSL "$SCRIPT_REMOTE_URL" -o "$temp_script_file" &>/dev/null; then
        echo -e "${RED}❌ 失败${NC}" # Failed
        echo -e "${RED}❌ 错误: 下载新版本脚本失败。请检查网络连接或 $SCRIPT_REMOTE_URL 是否可访问。${NC}" # Error: Failed to download new version of script. Please check network connection or if $SCRIPT_REMOTE_URL is accessible.
        log_message "ERROR" "从 $SCRIPT_REMOTE_URL 下载脚本失败。"
        return 1
    else
        echo -e "${GREEN}✅ 完成${NC}" # Complete
    fi

    # 基本检查: 确保下载的文件不为空
    if [ ! -s "$temp_script_file" ]; then
        echo -e "${RED}❌ 错误: 下载的脚本文件为空。更新失败。${NC}" # Error: Downloaded script file is empty. Update failed.
        log_message "ERROR" "下载的脚本文件为空，更新失败。"
        rm -f "$temp_script_file"
        return 1
    fi

    echo -n "${YELLOW}💾 正在备份当前脚本并替换...${NC}" # Backing up current script and replacing...
    # 备份当前脚本
    cp "$INSTALLER_PATH" "${INSTALLER_PATH}.bak.$(date +%Y%m%d%H%M%S)" || log_message "WARN" "备份旧脚本失败。"
    
    # 用新脚本替换当前脚本
    mv "$temp_script_file" "$INSTALLER_PATH" || log_message "ERROR" "移动新脚本失败。"
    chmod +x "$INSTALLER_PATH" || log_message "ERROR" "设置新脚本可执行权限失败。"

    # 重新创建 'ce' 快捷命令，确保它指向可能已更新的安装程序路径
    create_ce_command # 这将确保快捷方式指向更新后的脚本

    echo -e "${GREEN}✅ 完成${NC}" # Complete
    echo -e "${GREEN}🎉 脚本更新成功！${NC}" # Script update successful!
    echo -e "${YELLOW}💡 提示: 您可能需要退出当前 'ce' 交互模式并重新运行 'ce' 命令以加载最新功能。${NC}" # Hint: You may need to exit the current 'ce' interactive mode and rerun the 'ce' command to load the latest features.
    log_message "INFO" "脚本更新成功。新的脚本已保存到 $INSTALLER_PATH。"
    
    # 更新后，重新启动监控服务是很好的做法，以防其逻辑发生变化
    echo -e "${YELLOW}🔄 正在尝试重启流量监控服务以应用更新...${NC}" # Attempting to restart traffic monitor service to apply updates...
    systemctl restart ce-traffic-monitor.service 2>/dev/null || log_message "WARN" "更新后重启监控服务失败。"
    systemctl restart ce-traffic-monitor.timer 2>/dev/null || log_message "WARN" "更新后重启定时器失败。"
    echo -e "${GREEN}✅ 流量监控服务重启完成。${NC}" # Traffic monitor service restart complete.
}

# 显示实时状态
show_status() {
    clear # 清屏以获得更好的显示效果
    load_config "--interactive" # 确保在交互模式下加载配置
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                🚀 CE 流量限速管理系统 🚀                   ║${NC}" # CE Traffic Limiting Management System
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 系统信息
    echo -e "${WHITE}🖥️ 系统版本:${NC} ${CACHED_OS_VERSION:-$(lsb_release -d | cut -f2 || echo "未知")}" # System version: (如果可用则使用缓存值)
    echo -e "${WHITE}🌐 网络接口:${NC} ${CYAN}$INTERFACE${NC}" # Network interface:
    echo -e "${WHITE}📊 vnStat版本:${NC} ${CYAN}$(vnstat --version 2>/dev/null | head -1 | awk '{print $2}' || echo "未知")${NC}" # vnStat version: (Unknown)
    echo -e "${WHITE}⏱️ 更新时间:${NC} ${WHITE}$(date '+%Y-%m-%d %H:%M:%S')${NC}" # Update time:
    echo ""
    
    # 流量使用 - 每日
    # 此处不再调用 check_and_reset_daily，因为重置逻辑已集中到 monitor_script
    local used_daily_bytes=$(get_daily_usage_bytes)
    local used_daily_gb=$(echo "scale=3; $used_daily_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    local remaining_daily_gb=$(echo "scale=3; $DAILY_LIMIT - $used_daily_gb" | bc 2>/dev/null || echo "$DAILY_LIMIT")
    local percentage_daily=$(echo "scale=1; $used_daily_gb * 100 / $DAILY_LIMIT" | bc 2>/dev/null || echo "0")
    
    echo -e "${WHITE}📅 今日流量使用 (精确统计 - ${LAST_RESET_DATE}):${NC}" # Today's traffic usage (Precise statistics - ):
    echo -e "  ➡️ 已用: ${GREEN}${used_daily_gb}GB${NC} / ${YELLOW}${DAILY_LIMIT}GB${NC} (${percentage_daily}%)" # Used: / (percentage)%
    echo -e "  ⏳ 剩余: ${CYAN}${remaining_daily_gb}GB${NC}" # Remaining:
    echo -e "  ∑ 总计: ${MAGENTA}$(format_traffic "$used_daily_bytes")${NC}" # Total:
    
    # 每日进度条
    local bar_length=50
    local filled_length=$(printf "%.0f" "$(echo "$percentage_daily * $bar_length / 100" | bc 2>/dev/null)")
    [ -z "$filled_length" ] && filled_length=0
    
    local bar_daily=""
    local bar_daily_color=""
    if (( $(echo "$percentage_daily >= 90" | bc -l) )); then # 使用 bc -l 进行浮点比较
        bar_daily_color="$RED"
    elif (( $(echo "$percentage_daily >= 70" | bc -l) )); then
        bar_daily_color="$YELLOW"
    else
        bar_daily_color="$GREEN"
    fi
    
    for ((i=0; i<bar_length; i++)); do
        if [ "$i" -lt "$filled_length" ]; then
            bar_daily+="█"
        else
            bar_daily+="░"
        fi
    done
    echo -e "  [${bar_daily_color}$bar_daily${NC}]"
    echo ""

    # 流量使用 - 每月
    # 此处不再调用 check_and_reset_monthly，因为重置逻辑已集中到 monitor_script
    local used_monthly_bytes=$(get_monthly_usage_bytes)
    local used_monthly_gb=$(echo "scale=3; $used_monthly_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    local remaining_monthly_gb=$(echo "scale=3; $MONTHLY_LIMIT - $used_monthly_gb" | bc 2>/dev/null || echo "$MONTHLY_LIMIT")
    local percentage_monthly=$(echo "scale=1; $used_monthly_gb * 100 / $MONTHLY_LIMIT" | bc 2>/dev/null || echo "0")
    
    echo -e "${WHITE}🗓️ 本月流量使用 (精确统计 - ${LAST_MONTHLY_RESET_DATE}):${NC}" # This month's traffic usage (Precise statistics - ):
    echo -e "  ➡️ 已用: ${GREEN}${used_monthly_gb}GB${NC} / ${YELLOW}${MONTHLY_LIMIT}GB${NC} (${percentage_monthly}%)" # Used: / (percentage)%
    echo -e "  ⏳ 剩余: ${CYAN}${remaining_monthly_gb}GB${NC}" # Remaining:
    echo -e "  ∑ 总计: ${MAGENTA}$(format_traffic "$used_monthly_bytes")${NC}" # Total:

    # 每月进度条
    local monthly_filled_length=$(printf "%.0f" "$(echo "$percentage_monthly * $bar_length / 100" | bc 2>/dev/null)")
    [ -z "$monthly_filled_length" ] && monthly_filled_length=0
    
    local bar_monthly=""
    local bar_monthly_color=""
    if (( $(echo "$percentage_monthly >= 90" | bc -l) )); then
        bar_monthly_color="$RED"
    elif (( $(echo "$percentage_monthly >= 70" | bc -l) )); then
        bar_monthly_color="$YELLOW"
    else
        bar_monthly_color="$GREEN"
    fi
    
    for ((i=0; i<bar_length; i++)); do
        if [ "$i" -lt "$monthly_filled_length" ]; then
            bar_monthly+="█"
        else
            bar_monthly+="░"
        fi
    done
    echo -e "  [${bar_monthly_color}$bar_monthly${NC}]"
    echo ""
    
    # 限速状态
    if [ "$LIMIT_ENABLED" = "true" ]; then
        echo -e "${RED}🔴 限速状态: 已启用 (${SPEED_LIMIT}KB/s - 上传和下载)${NC}" # Speed limit status: Enabled (upload and download)
    else
        echo -e "${GREEN}🟢 限速状态: 未启用${NC}" # Speed limit status: Not enabled
    fi
    echo ""
}

# 主菜单
show_menu() {
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                       🛠️ 操作菜单 ⚙️                          ║${NC}" # Operation Menu
    echo -e "${MAGENTA}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║  ${WHITE}1.${NC} 🚀 开启流量限速 (Enable traffic limiting)                      ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}2.${NC} 🟢 解除流量限速 (Disable traffic limiting)                     ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}3.${NC} ⚡ 实时网速显示 (Real-time Network Speed)                  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}4.${NC} 📊 网络速度测试 (Network speed test)                         ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}5.${NC} 📋 详细流量统计 (Detailed traffic statistics)                ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}6.${NC} 📈 高级流量统计 (Advanced Traffic Statistics)                ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}7.${NC} 🔧 修改配置 (Modify Configuration)                           ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}8.${NC} 🔄 重置今日计数 (Reset daily counter)                        ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}9.${NC} 🔄 重置每月计数 (Reset monthly counter)                      ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}10.${NC} ⬆️ 系统更新 (System Update)                                  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}11.${NC} ⚙️ 更新脚本 (Update script)                                  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}12.${NC} 🗑️ 卸载所有组件 (Uninstall all components)                   ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║  ${WHITE}0.${NC} 👋 退出程序 (Exit program)                                   ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 重置每日计数器
reset_daily_counter() {
    echo -e "${RED}⚠️ 确认重置今日流量计数? 这将重新开始计算今日流量 (y/N): ${NC}" # Confirm reset daily traffic counter? This will restart daily traffic calculation (y/N):
    read -rp "${WHITE}请输入 (y/N): ${NC}" confirm_reset # Please enter (y/N):
    if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}🔄 重置今日流量计数器...${NC}" # Resetting daily traffic counter...
        
        # 记录重置前使用量 (不再传递 true，因为 get_daily_usage_bytes 内部不再执行重置检查)
        local before_usage=$(get_daily_usage_bytes)
        log_message "INFO" "手动重置每日计数器，重置前使用量: $(format_traffic "$before_usage")"
        
        # 重置计数器
        init_daily_counter
        
        # 如果限速当前处于激活状态，询问是否同时解除限速
        if [ "$LIMIT_ENABLED" = "true" ]; then
            echo -e "${YELLOW}🚦 检测到当前有限速，是否同时解除限速? (y/N): ${NC}" # Detected current speed limit, remove it as well? (y/N):
            read -rp "${WHITE}请输入 (y/N): ${NC}" remove_limit # Please enter (y/N):
            if [[ "$remove_limit" =~ ^[Yy]$ ]]; then
                remove_speed_limit
            fi
        fi
        
        echo -e "${GREEN}✅ 今日流量计数器已重置${NC}" # Daily traffic counter reset.
        log_message "INFO" "今日流量计数器已重置。"
    else
        echo -e "${YELLOW}🚫 操作取消。${NC}" # Operation cancelled.
        log_message "INFO" "用户取消了重置今日流量计数。"
    fi
}

# 重置每月计数器
reset_monthly_counter() {
    echo -e "${RED}⚠️ 确认重置每月流量计数? 这将重新开始计算每月流量 (y/N): ${NC}" # Confirm reset monthly traffic counter? This will restart monthly traffic calculation (y/N):
    read -rp "${WHITE}请输入 (y/N): ${NC}" confirm_reset # Please enter (y/N):
    if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}🔄 重置每月流量计数器...${NC}" # Resetting monthly traffic counter...
        
        # 记录重置前使用量 (不再传递 true，因为 get_monthly_usage_bytes 内部不再执行重置检查)
        local before_usage=$(get_monthly_usage_bytes)
        log_message "INFO" "手动重置每月计数器，重置前使用量: $(format_traffic "$before_usage")"
        
        # 重置计数器
        init_monthly_counter
        
        echo -e "${GREEN}✅ 每月流量计数器已重置${NC}" # Monthly traffic counter reset.
        log_message "INFO" "每月流量计数器已重置。"
    else
        echo -e "${YELLOW}🚫 操作取消。${NC}" # Operation cancelled.
        log_message "INFO" "用户取消了重置每月流量计数。"
    fi
}

# 卸载功能
uninstall_all() {
    echo -e "${RED}⚠️ 确认卸载所有组件? (y/N): ${NC}" # Confirm uninstall all components? (y/N):
    read -rp "${WHITE}请输入 (y/N): ${NC}" confirm_uninstall # Please enter (y/N):
    if [[ "$confirm_uninstall" =~ ^[Yy]$ ]]; then
       echo -e "${YELLOW}🗑️ 卸载中...${NC}" # Uninstalling...
       log_message "INFO" "开始卸载所有组件。"
       
       # 停止并禁用服务和定时器
       systemctl stop ce-traffic-monitor.timer 2>/dev/null || log_message "WARN" "停止定时器失败。"
       systemctl disable ce-traffic-monitor.timer 2>/dev/null || log_message "WARN" "禁用定时器失败。"
       systemctl stop ce-traffic-monitor.service 2>/dev/null || log_message "WARN" "停止服务失败。"
       systemctl disable ce-traffic-monitor.service 2>/dev/null || log_message "WARN" "禁用服务失败。"
       
       # 移除限速 (INTERFACE 变量可能已丢失，但 tc 命令通常不依赖于配置文件)
       local current_interface=""
       if [ -f "$CONFIG_FILE" ]; then
           # shellcheck source=/dev/null
           source "$CONFIG_FILE" 2>/dev/null || true
           current_interface="$INTERFACE"
       fi
       
       # 尝试移除现有 qdisc，涵盖常见的接口名称
       local interfaces_to_check=("${current_interface}" "eth0" "enp0s3" "ens33" "wlan0")
       for iface in "${interfaces_to_check[@]}"; do
           if [ -n "$iface" ]; then # 确保接口名称不为空
               tc qdisc del dev "$iface" root 2>/dev/null || true
               tc qdisc del dev "$iface" ingress 2>/dev/null || true
               log_message "INFO" "尝试移除接口 $iface 上的上传和下载限速规则。"
           fi
       done
       
       # 移除 ifb 设备（如果存在）
       if ip link show ifb0 &>/dev/null; then
           ip link set dev ifb0 down 2>/dev/null || log_message "WARN" "卸载: 关闭 ifb0 设备失败。"
           ip link del ifb0 type ifb 2>/dev/null || log_message "WARN" "卸载: 删除 ifb0 设备失败。"
           log_message "INFO" "ifb0 设备已关闭并移除。"
       fi

       # 删除文件
       rm -f "$CONFIG_FILE" || log_message "WARN" "删除配置文件失败。"
       rm -f "$SERVICE_FILE" || log_message "WARN" "删除服务文件失败。"
       rm -f "$TIMER_FILE" || log_message "WARN" "删除定时器文件失败。"
       rm -f "$MONITOR_SCRIPT" || log_message "WARN" "删除监控脚本失败。"
       rm -f "$INSTALLER_PATH" || log_message "WARN" "删除安装器自身失败。"
       rm -f "$SCRIPT_PATH" || log_message "WARN" "删除快捷命令失败。"
       rm -f "$TRAFFIC_LOG" || log_message "WARN" "删除流量日志文件失败。"
       rm -f "/etc/vnstat.conf.backup" || log_message "WARN" "删除 vnStat 备份配置失败。"
       
       systemctl daemon-reload || log_message "ERROR" "daemon-reload 失败。"
       
       # 尝试卸载依赖，但避免删除常用包
       echo -e "${YELLOW}🧹 尝试清理依赖 (vnstat, speedtest-cli, curl)...${NC}" # Attempting to clean up dependencies (vnstat, speedtest-cli, curl)...
       apt remove -y vnstat speedtest-cli curl 2>/dev/null || log_message "WARN" "卸载依赖失败或依赖不存在。"
       apt autoremove -y 2>/dev/null || log_message "WARN" "自动清理不再需要的包失败。"
       
       echo -e "${GREEN}✅ 卸载完成${NC}" # Uninstall complete.
       log_message "INFO" "所有组件已成功卸载。"
       exit 0
    else
        echo -e "${YELLOW}🚫 操作取消。${NC}" # Operation cancelled.
        log_message "INFO" "用户取消了卸载操作。"
    fi
}

# 交互式界面
interactive_mode() {
    # 首次进入交互模式时加载配置
    load_config "--interactive"
    # 缓存系统信息
    CACHED_OS_VERSION=$(lsb_release -d | cut -f2 || echo "未知")
    CACHED_KERNEL_VERSION=$(uname -r || echo "未知")

    while true; do
        show_status
        show_menu
        
        # 修改提示以只使用数字选项
        read -rp "${MAGENTA}请选择操作 [0-12]: ${NC}" choice # Please select an operation [0-12]:
        
        case "$choice" in
            1)
                apply_speed_limit
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            2)
                remove_speed_limit
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            3) # 实时网速显示
                show_realtime_speed
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            4) # 网络速度测试
                speed_test
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            5) # 详细流量统计
                show_detailed_stats
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            6) # 高级流量统计
                show_advanced_vnstat_stats
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            7) # 修改配置
                modify_config
                # 配置修改后，需要重新加载以更新交互界面中的显示
                load_config "--interactive"
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            8) # 重置今日计数
                reset_daily_counter
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            9) # 重置每月计数
                reset_monthly_counter
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            10) # 系统更新
                perform_system_update
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            11) # 更新脚本 - 新选项
                update_script
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
            12) # 卸载 - 移动到 12
                uninstall_all
                ;;
            0)
                echo -e "${GREEN}👋 感谢使用 CE 流量限速管理系统！再见！${NC}" # Thank you for using CE Traffic Limiting Management System. Goodbye!
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效选择，请重新输入${NC}" # Invalid choice, please re-enter.
                read -rp "${CYAN}按回车键继续...${NC}" # Press Enter to continue...
                ;;
        esac
    done
}

# 创建 'ce' 命令
create_ce_command() {
    # 这是一个包装脚本，用于以交互模式启动主脚本
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# 这是一个快捷方式脚本，调用主安装/管理脚本

# 为此包装脚本定义颜色
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 加载配置文件以获取 INTERFACE 等变量
if [ -f "/etc/ce_traffic_limit.conf" ]; then
    # shellcheck source=/dev/null
    source "/etc/ce_traffic_limit.conf" 2>/dev/null || true
fi

# 确定主脚本的路径 (此脚本假设它已被复制)
MAIN_SCRIPT="/usr/local/bin/install_ce.sh"

# 检查主脚本是否存在
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo -e "${RED}❌ 错误: 主脚本 $MAIN_SCRIPT 未找到。请重新运行安装程序。${NC}" # Error: Main script $MAIN_SCRIPT not found. Please rerun the installer.
    exit 1
fi

# 检查是交互式调用还是直接命令调用
if [ "$#" -eq 0 ]; then # 未提供任何参数
    "$MAIN_SCRIPT" --interactive
else
    "$MAIN_SCRIPT" "$@"
fi
EOF
    chmod +x "$SCRIPT_PATH" || log_message "ERROR" "设置ce命令可执行权限失败。"
    echo -e "${GREEN}✅ 'ce' 命令已创建: $SCRIPT_PATH${NC}" # 'ce' command created:
    log_message "INFO" "'ce' 命令已创建。"
}

# 主安装函数
main_install() {
    echo -e "${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║              🌟 CE 流量限速管理系统 - 安装程序 🌟              ║${NC}" # CE Traffic Limiting Management System - Installer
    echo -e "${PURPLE}║                 精确流量统计 & 每月统计版本                  ║${NC}" # Precise Traffic Statistics & Monthly Statistics Version
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_message "INFO" "开始执行主安装程序。"
    
    get_system_info # 获取并缓存系统信息
    detect_interface
    install_dependencies
    # 使用默认值，如果 modify_config 稍后会更新
    DAILY_LIMIT=30
    SPEED_LIMIT=512
    MONTHLY_LIMIT=$(echo "$DAILY_LIMIT * 10" | bc)
    create_config # 创建配置并初始化每日/每月计数器
    create_monitor_service
    create_timer
    
    # 将脚本复制到系统目录，以便后续 'ce' 命令调用和更新
    cp "$0" "$INSTALLER_PATH" || log_message "ERROR" "复制安装脚本到 $INSTALLER_PATH 失败。"
    chmod +x "$INSTALLER_PATH" || log_message "ERROR" "设置安装脚本可执行权限失败。"
    
    create_ce_command
    
    # 创建日志文件并设置权限
    touch "$TRAFFIC_LOG" || log_message "ERROR" "创建流量日志文件失败。"
    chmod 644 "$TRAFFIC_LOG" || log_message "ERROR" "设置流量日志文件权限失败。"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                          🎉 安装完成！ 🎉                      ║${NC}" # Installation Complete!
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  ➡️ 输入 'ce' 命令进入交互界面 (Enter 'ce' command to enter interactive mode)    ║${NC}"
    echo -e "${GREEN}║  ➡️ 每日流量限制: ${DAILY_LIMIT}GB/天 (Daily traffic limit: GB/day)             ║${NC}"
    echo -e "${GREEN}║  ➡️ 每月流量限制: ${MONTHLY_LIMIT}GB/月 (Monthly traffic limit: GB/month)           ║${NC}"
    echo -e "${GREEN}║  ➡️ 限速速度: ${SPEED_LIMIT}KB/s (Speed limit: KB/s)                             ║${NC}"
    echo -e "${GREEN}║  ➡️ 统计方式: 系统网卡精确统计 (支持vnStat备选) (Statistics method: System NIC precise stats (vnStat fallback supported))                 ║${NC}"
    echo -e "${GREEN}║  ➡️ 新增功能: 每月流量统计、详细统计、手动重置 (New features: Monthly stats, detailed stats, manual reset)                  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}💡 提示: 系统已开始精确统计今日及本月流量使用情况${NC}" # Hint: The system has started precisely counting today's and this month's traffic usage.
    log_message "INFO" "主安装程序完成。"
}

# ==============================================================================
# 主程序入口点
# ==============================================================================

# 根据参数或配置文件是否存在，决定是安装还是进入交互模式
case "${1:-}" in # "${1:-}" 防止未提供参数时的错误
    --interactive)
        interactive_mode
        ;;
    --install)
        main_install
        ;;
    --uninstall) # 添加了直接卸载选项
        uninstall_all
        ;;
    *)
        if [ -f "$CONFIG_FILE" ]; then
            interactive_mode
        else
            main_install
        fi
        ;;
esac
