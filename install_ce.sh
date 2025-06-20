#!/bin/bash

# install_ce.sh - 流量限速管理系统
# 系统要求: Ubuntu 24.04.2 LTS (用户提供信息: Ubuntu 24.04, vnStat 2.12)
# 功能: vnStat + tc 流量监控与限速
# 新增功能: 每月流量统计与管理

# ==============================================================================
# 脚本配置与变量定义
# ==============================================================================

# 设置严格模式，提高脚本健壮性
# -e: 遇到命令失败时立即退出
# -u: 遇到未设置的变量时视为错误并退出
# -o pipefail: 管道命令中任何一个命令失败时，整个管道失败
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/etc/ce_traffic_limit.conf"
SERVICE_FILE="/etc/systemd/system/ce-traffic-monitor.service"
TIMER_FILE="/etc/systemd/system/ce-traffic-monitor.timer"
MONITOR_SCRIPT="/usr/local/bin/ce-monitor"
SCRIPT_PATH="/usr/local/bin/ce" # 用户交互快捷命令
INSTALLER_PATH="/usr/local/bin/install_ce.sh" # 安装脚本自身复制到此
TRAFFIC_LOG="/var/log/ce-daily-traffic.log"

# 默认配置
DAILY_LIMIT=30 # GB 每日流量限制
SPEED_LIMIT=512 # KB/s 限速速度
INTERFACE="" # 网络接口名称，自动检测或手动指定
# 每月流量限制，默认为每日限制的10倍
MONTHLY_LIMIT=$(echo "$DAILY_LIMIT * 10" | bc) # GB

# ==============================================================================
# 核心函数定义
# ==============================================================================

# 获取系统信息
get_system_info() {
    echo -e "${BLUE}检测系统信息...${NC}"
    OS_VERSION=$(lsb_release -d | cut -f2)
    KERNEL_VERSION=$(uname -r)
    echo -e "${GREEN}系统版本: $OS_VERSION${NC}"
    echo -e "${GREEN}内核版本: $KERNEL_VERSION${NC}"
}

# 自动检测网卡
detect_interface() {
    echo -e "${BLUE}自动检测网络接口...${NC}"
    # 获取默认路由的网卡
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1 || true) # '|| true' 防止grep失败导致set -e退出
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}无法自动检测网卡，请手动选择:${NC}"
        ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo
        read -rp "请输入网卡名称: " INTERFACE
    fi
    echo -e "${GREEN}使用网卡: $INTERFACE${NC}"
}

# 安装依赖
install_dependencies() {
    echo -e "${BLUE}安装依赖包...${NC}"
    apt update
    apt install -y vnstat iproute2 bc coreutils jq sqlite3
    
    # 配置vnStat
    # 备份原配置
    if [ -f "/etc/vnstat.conf" ]; then
        cp "/etc/vnstat.conf" "/etc/vnstat.conf.backup"
    fi
    
    # 修改vnStat配置以提高精度
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

    # 启动vnstat服务
    systemctl enable vnstat
    systemctl restart vnstat
    
    # 添加网卡到vnstat，如果网卡不存在则创建
    vnstat -i "$INTERFACE" --create || true # || true 避免网卡已存在时报错退出
    
    # 等待vnstat初始化
    echo -e "${YELLOW}等待vnStat初始化...${NC}"
    sleep 10
    
    echo -e "${GREEN}依赖安装完成${NC}"
}

# 初始化每日流量计数器
init_daily_counter() {
    local today=$(date +%Y-%m-%d)
    # 尝试读取系统网卡字节数，如果失败则默认为0
    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 更新配置文件中的起始值和日期
    # 使用sed -i 替换配置，确保变量被正确引用
    sed -i "s/DAILY_START_RX=.*/DAILY_START_RX=$current_rx/" "$CONFIG_FILE"
    sed -i "s/DAILY_START_TX=.*/DAILY_START_TX=$current_tx/" "$CONFIG_FILE"
    sed -i "s/LAST_RESET_DATE=.*/LAST_RESET_DATE=$today/" "$CONFIG_FILE"
    
    # 记录到日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 初始化每日计数器: RX=$(format_traffic "$current_rx"), TX=$(format_traffic "$current_tx")" >> "$TRAFFIC_LOG"
}

# 初始化每月流量计数器
init_monthly_counter() {
    local this_month=$(date +%Y-%m)
    # 尝试读取系统网卡字节数，如果失败则默认为0
    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 更新配置文件中的起始值和日期
    sed -i "s/MONTHLY_START_RX=.*/MONTHLY_START_RX=$current_rx/" "$CONFIG_FILE"
    sed -i "s/MONTHLY_START_TX=.*/MONTHLY_START_TX=$current_tx/" "$CONFIG_FILE"
    sed -i "s/LAST_MONTHLY_RESET_DATE=.*/LAST_MONTHLY_RESET_DATE=$this_month/" "$CONFIG_FILE"
    
    # 记录到日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 初始化每月计数器: RX=$(format_traffic "$current_rx"), TX=$(format_traffic "$current_tx")" >> "$TRAFFIC_LOG"
}


# 创建配置文件
create_config() {
    local today=$(date +%Y-%m-%d)
    local this_month=$(date +%Y-%m)
    # 使用here-document写入配置文件，确保变量被正确展开
    cat > "$CONFIG_FILE" << EOF
DAILY_LIMIT=$DAILY_LIMIT
SPEED_LIMIT=$SPEED_LIMIT
MONTHLY_LIMIT=$MONTHLY_LIMIT
INTERFACE=$INTERFACE
LIMIT_ENABLED=false
LAST_RESET_DATE=$today
DAILY_START_RX=0
DAILY_START_TX=0
LAST_MONTHLY_RESET_DATE=$this_month
MONTHLY_START_RX=0
MONTHLY_START_TX=0
EOF
    
    # 初始化今日流量计数和每月流量计数
    init_daily_counter
    init_monthly_counter
    
    echo -e "${GREEN}配置文件已创建: $CONFIG_FILE${NC}"
}

# 读取配置
load_config() {
    # 确保文件存在且可读，然后source它
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        echo -e "${RED}错误: 配置文件 $CONFIG_FILE 不存在。请先运行安装脚本。${NC}"
        exit 1
    fi
}

# 检查并重置每日计数器
# $1: Boolean, true to run check_and_reset_daily, false to skip (for internal use)
check_and_reset_daily() {
    local run_reset=${1:-true} # Default to true if no argument provided
    load_config # 确保加载最新配置
    local today=$(date +%Y-%m-%d)
    
    if [ "$today" != "$LAST_RESET_DATE" ]; then
        echo -e "${YELLOW}检测到新的一天，重置流量计数器...${NC}"
        
        # 记录昨日总流量 (使用vnStat数据，因为系统计数可能已经重置)
        local yesterday_usage=$(get_vnstat_daily_bytes)
        local yesterday_gb=$(echo "scale=2; $yesterday_usage / 1024 / 1024 / 1024" | bc)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 昨日($LAST_RESET_DATE)流量统计: ${yesterday_gb}GB" >> "$TRAFFIC_LOG"
        
        # 重置计数器
        init_daily_counter
        
        # 如果昨日有限速，新的一天自动解除
        if [ "$LIMIT_ENABLED" = "true" ]; then
            remove_speed_limit
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 新的一天，自动解除限速" >> "$TRAFFIC_LOG"
        fi
    fi
}

# 检查并重置每月计数器
# $1: Boolean, true to run check_and_reset_monthly, false to skip (for internal use)
check_and_reset_monthly() {
    local run_reset=${1:-true} # Default to true if no argument provided
    load_config # 确保加载最新配置
    local this_month=$(date +%Y-%m)
    
    if [ "$this_month" != "$LAST_MONTHLY_RESET_DATE" ]; then
        echo -e "${YELLOW}检测到新的月份，重置每月流量计数器...${NC}"
        
        # 记录上月总流量 (使用vnStat数据)
        local last_month_usage=$(get_vnstat_monthly_bytes)
        local last_month_gb=$(echo "scale=2; $last_month_usage / 1024 / 1024 / 1024" | bc)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 上月($LAST_MONTHLY_RESET_DATE)流量统计: ${last_month_gb}GB" >> "$TRAFFIC_LOG"
        
        # 重置计数器
        init_monthly_counter
    fi
}

# 获取今日流量使用量（字节）- 优先使用系统网卡统计，负数时回退到vnStat
# $1: Boolean, true to run check_and_reset_daily, false to skip (for internal use)
get_daily_usage_bytes() {
    local run_reset=${1:-true} # Default to true if no argument provided
    if [ "$run_reset" = "true" ]; then
        check_and_reset_daily false # 避免递归调用，内部调用时跳过reset check
    fi
    load_config # 再次加载配置，确保起始值最新

    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 计算今日使用量
    local daily_rx=$((current_rx - DAILY_START_RX))
    local daily_tx=$((current_tx - DAILY_START_TX))
    local daily_total=$((daily_rx + daily_tx))
    
    # 如果出现负数（可能是网卡重置），或者系统计数为0（新启动），使用vnStat作为备选
    if [ "$daily_total" -lt 0 ] || ([ "$DAILY_START_RX" -eq 0 ] && [ "$DAILY_START_TX" -eq 0 ] && [ "$current_rx" -gt 0 ] ); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 警告: 今日流量计算出现负数或起始值异常，尝试使用vnStat备选。" >> "$TRAFFIC_LOG"
        daily_total=$(get_vnstat_daily_bytes)
    fi
    
    echo "$daily_total"
}

# 获取当月流量使用量（字节）- 优先使用系统网卡统计，负数时回退到vnStat
# $1: Boolean, true to run check_and_reset_monthly, false to skip (for internal use)
get_monthly_usage_bytes() {
    local run_reset=${1:-true} # Default to true if no argument provided
    if [ "$run_reset" = "true" ]; then
        check_and_reset_monthly false # 避免递归调用，内部调用时跳过reset check
    fi
    load_config # 再次加载配置，确保起始值最新

    local current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    
    # 计算当月使用量
    local monthly_rx=$((current_rx - MONTHLY_START_RX))
    local monthly_tx=$((current_tx - MONTHLY_START_TX))
    local monthly_total=$((monthly_rx + monthly_tx))

    # 如果出现负数（可能是网卡重置），或者系统计数为0（新启动），使用vnStat作为备选
    if [ "$monthly_total" -lt 0 ] || ([ "$MONTHLY_START_RX" -eq 0 ] && [ "$MONTHLY_START_TX" -eq 0 ] && [ "$current_rx" -gt 0 ] ); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 警告: 当月流量计算出现负数或起始值异常，尝试使用vnStat备选。" >> "$TRAFFIC_LOG"
        monthly_total=$(get_vnstat_monthly_bytes)
    fi
    
    echo "$monthly_total"
}

# vnStat备选方法 - 获取今日流量字节数
get_vnstat_daily_bytes() {
    local today=$(date +%Y-%m-%d)
    local vnstat_bytes=0
    
    # 优先使用JSON输出 (vnStat 2.x版本支持)
    if command -v jq &> /dev/null; then
        local json_output
        json_output=$(vnstat -i "$INTERFACE" --json d 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output" ]; then
            # 查找今天的数据，确保rx/tx存在，否则默认为0
            local rx_bytes
            rx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .rx // 0" 2>/dev/null || true)
            local tx_bytes
            tx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .tx // 0" 2>/dev/null || true)
            
            # 确保jq输出是数字
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                vnstat_bytes=$((rx_bytes + tx_bytes))
            fi
        fi
    fi
    
    # 如果JSON解析失败或jq未安装，回退到解析文本输出
    if [ "$vnstat_bytes" -eq 0 ]; then
        local vnstat_line
        vnstat_line=$(vnstat -i "$INTERFACE" -d | grep "$today" | tail -1 || true)
        if [ -n "$vnstat_line" ]; then
            local rx_str=$(echo "$vnstat_line" | awk '{print $2}')
            local tx_str=$(echo "$vnstat_line" | awk '{print $3}')
            vnstat_bytes=$(($(convert_to_bytes "$rx_str") + $(convert_to_bytes "$tx_str")))
        fi
    fi
    
    echo "$vnstat_bytes"
}

# vnStat备选方法 - 获取当月流量字节数
get_vnstat_monthly_bytes() {
    local this_month=$(date +%Y-%m)
    local vnstat_bytes=0
    
    # 优先使用JSON输出
    if command -v jq &> /dev/null; then
        local json_output
        json_output=$(vnstat -i "$INTERFACE" --json m 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output" ]; then
            # 查找当月的数据，确保rx/tx存在，否则默认为0
            local rx_bytes
            rx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.month[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m)) | .rx // 0" 2>/dev/null || true)
            local tx_bytes
            tx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.month[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m)) | .tx // 0" 2>/dev/null || true)
            
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                vnstat_bytes=$((rx_bytes + tx_bytes))
            fi
        fi
    fi
    
    # 如果JSON解析失败或jq未安装，回退到解析文本输出
    if [ "$vnstat_bytes" -eq 0 ]; then
        local vnstat_line
        vnstat_line=$(vnstat -i "$INTERFACE" -m | grep "$this_month" | tail -1 || true)
        if [ -n "$vnstat_line" ]; then
            # 假设格式：2023-12 | 100.00 GiB | 50.00 GiB | 150.00 GiB | *
            # awk可能需要根据实际vnStat -m输出调整列数
            local rx_str=$(echo "$vnstat_line" | awk '{print $2}')
            local tx_str=$(echo "$vnstat_line" | awk '{print $3}')
            vnstat_bytes=$(($(convert_to_bytes "$rx_str") + $(convert_to_bytes "$tx_str")))
        fi
    fi
    
    echo "$vnstat_bytes"
}


# 转换流量单位为字节
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
    
    # bc用于浮点数乘法，cut -d. -f1 用于取整数部分
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
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        local mb=$(echo "scale=2; $bytes / 1024 / 1024" | bc)
        echo "${mb}MB"
    else
        local gb=$(echo "scale=3; $bytes / 1024 / 1024 / 1024" | bc)
        echo "${gb}GB"
    fi
}

# 强制刷新vnStat和重新计算
force_refresh() {
    echo -e "${YELLOW}强制刷新流量统计...${NC}"
    
    # 强制vnStat写入数据并重启服务
    vnstat -i "$INTERFACE" --force || true
    systemctl restart vnstat
    sleep 3
    
    # 重新加载配置
    load_config
    
    # 记录当前状态，此处调用get_daily/monthly_usage_bytes会触发内部的check_and_reset_daily/monthly
    local daily_usage=$(get_daily_usage_bytes)
    local monthly_usage=$(get_monthly_usage_bytes)
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 强制刷新: 今日使用=$(format_traffic "$daily_usage"), 本月使用=$(format_traffic "$monthly_usage")" >> "$TRAFFIC_LOG"
    
    echo -e "${GREEN}刷新完成${NC}"
}

# 检查是否达到每日限制
check_daily_limit() {
    local used_bytes=$(get_daily_usage_bytes)
    local used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc)
    local limit_reached=$(echo "$used_gb >= $DAILY_LIMIT" | bc)
    echo "$limit_reached"
}

# 检查是否达到每月限制 (目前仅用于显示，不触发自动限速)
check_monthly_limit() {
    local used_bytes=$(get_monthly_usage_bytes)
    local used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc)
    local limit_reached=$(echo "$used_gb >= $MONTHLY_LIMIT" | bc)
    echo "$limit_reached"
}

# 应用限速
apply_speed_limit() {
    echo -e "${YELLOW}应用限速设置...${NC}"
    
    # 清除现有规则，忽略错误
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    
    # 设置限速 (转换KB/s到bit/s)
    local speed_bps=$((SPEED_LIMIT * 8 * 1024))
    
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${speed_bps}bit"
    tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${speed_bps}bit" ceil "${speed_bps}bit"
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:10
    
    sed -i "s/LIMIT_ENABLED=.*/LIMIT_ENABLED=true/" "$CONFIG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动启用限速: ${SPEED_LIMIT}KB/s" >> "$TRAFFIC_LOG"
    echo -e "${GREEN}限速已启用: ${SPEED_LIMIT}KB/s${NC}"
}

# 移除限速
remove_speed_limit() {
    echo -e "${YELLOW}移除限速设置...${NC}"
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true # 忽略可能不存在的规则删除错误
    sed -i "s/LIMIT_ENABLED=.*/LIMIT_ENABLED=false/" "$CONFIG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动解除限速" >> "$TRAFFIC_LOG"
    echo -e "${GREEN}限速已移除${NC}"
}

# 网速测试
speed_test() {
    echo -e "${BLUE}开始网络速度测试...${NC}"
    echo -e "${YELLOW}注意: 测试会消耗流量，请确认继续 (y/N): ${NC}"
    read -rp "请输入 (y/N): " confirm_test
    if [[ ! "$confirm_test" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消测试${NC}"
        return
    fi
    
    # 记录测试前的流量
    local before_bytes=$(get_daily_usage_bytes false) # 传入false避免测试过程中触发重置
    local before_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    if command -v speedtest-cli &> /dev/null; then
        speedtest-cli --simple
    else
        echo -e "${YELLOW}安装speedtest-cli...${NC}"
        apt install -y speedtest-cli
        speedtest-cli --simple
    fi
    
    echo -e "${YELLOW}测试完成，正在计算流量消耗...${NC}"
    sleep 2 # 给予系统一些时间更新统计数据
    
    # 强制刷新并计算消耗
    force_refresh
    local after_bytes=$(get_daily_usage_bytes false)
    local test_usage=$((after_bytes - before_bytes))
    
    if [ "$test_usage" -gt 0 ]; then
        echo -e "${GREEN}本次测试消耗流量: $(format_traffic "$test_usage")${NC}"
        echo "$before_time - 速度测试消耗: $(format_traffic "$test_usage")" >> "$TRAFFIC_LOG"
    else
        echo -e "${YELLOW}流量消耗计算可能不准确，请查看总使用量或稍后重试${NC}"
    fi
}

# 显示详细流量统计
show_detailed_stats() {
    load_config
    local today=$(date +%Y-%m-%d)
    local this_month=$(date +%Y-%m)
    
    clear # 清屏以获得更好的显示效果

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    详细流量统计                              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 获取精确的今日/本月流量使用量（含回退逻辑）
    local precise_daily_total=$(get_daily_usage_bytes)
    local precise_monthly_total=$(get_monthly_usage_bytes)

    echo -e "${WHITE}系统网卡统计 ($INTERFACE):${NC}"
    # 直接显示当前的系统网卡统计，不涉及起始值
    local current_rx_raw=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx_raw=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    echo -e "  总接收: $(format_traffic "$current_rx_raw")"
    echo -e "  总发送: $(format_traffic "$current_tx_raw")"
    echo ""

    echo -e "${WHITE}今日统计 (${LAST_RESET_DATE}):${NC}"
    # 为了避免复杂的RX/TX拆分和负数问题，这里直接显示精确总计
    echo -e "  今日总计: $(format_traffic "$precise_daily_total")"
    echo -e "  (通过系统网卡计数与vnStat备选精确计算)"
    echo ""

    echo -e "${WHITE}本月统计 (${LAST_MONTHLY_RESET_DATE}):${NC}"
    echo -e "  本月总计: $(format_traffic "$precise_monthly_total")"
    echo -e "  (通过系统网卡计数与vnStat备选精确计算)"
    echo ""
    
    # vnStat统计（原始数据，供参考）
    local vnstat_daily_bytes=$(get_vnstat_daily_bytes)
    local vnstat_monthly_bytes=$(get_vnstat_monthly_bytes)
    echo -e "${WHITE}vnStat 原始统计 (仅供参考):${NC}"
    echo -e "  今日 vnStat 显示: $(format_traffic "$vnstat_daily_bytes")"
    echo -e "  本月 vnStat 显示: $(format_traffic "$vnstat_monthly_bytes")"
    echo ""
    
    # 显示最近的日志
    echo -e "${WHITE}最近活动日志:${NC}"
    if [ -f "$TRAFFIC_LOG" ]; then
        tail -n 5 "$TRAFFIC_LOG" | while read -r line; do # read -r 防止反斜杠转义
            echo -e "  ${YELLOW}$line${NC}"
        done
    else
        echo -e "  ${YELLOW}暂无日志记录${NC}"
    fi
    echo ""
    
    # 配置信息
    echo -e "${WHITE}当前配置:${NC}"
    echo -e "  每日限制: ${DAILY_LIMIT}GB"
    echo -e "  每月限制: ${MONTHLY_LIMIT}GB"
    echo -e "  限速速度: ${SPEED_LIMIT}KB/s"
    echo -e "  今日计数起始日期: $LAST_RESET_DATE"
    echo -e "  今日起始RX: $(format_traffic "$DAILY_START_RX")"
    echo -e "  今日起始TX: $(format_traffic "$DAILY_START_TX")"
    echo -e "  本月计数起始日期: $LAST_MONTHLY_RESET_DATE"
    echo -e "  本月起始RX: $(format_traffic "$MONTHLY_START_RX")"
    echo -e "  本月起始TX: $(format_traffic "$MONTHLY_START_TX")"
    echo ""
}

# 创建监控服务
create_monitor_service() {
    # Systemd Service File
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

    # Monitor Script (executed by systemd)
    cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
# 注意：此脚本在systemd服务中运行，需保证其独立性
set -euo pipefail

CONFIG_FILE="/etc/ce_traffic_limit.conf"
TRAFFIC_LOG="/var/log/ce-daily-traffic.log"

# 加载配置
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# 流量统计函数 (复制主脚本的关键逻辑)
get_current_usage_bytes_raw() {
    local current_rx_b=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
    local current_tx_b=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
    echo "$current_rx_b $current_tx_b"
}

# 转换流量单位为字节 (复制主脚本的关键逻辑)
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

# vnStat备选方法 - 日 (复制主脚本的关键逻辑)
get_vnstat_daily_bytes_monitor() {
    local today_m=$(date +%Y-%m-%d)
    local vnstat_bytes_m=0
    if command -v jq &> /dev/null; then
        local json_output_m=$(vnstat -i "$INTERFACE" --json d 2>/dev/null || true)
        if [ $? -eq 0 ] && [ -n "$json_output_m" ]; then
            local rx_bytes_m=$(echo "$json_output_m" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .rx // 0" 2>/dev/null || true)
            local tx_bytes_m=$(echo "$json_output_m" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $(date +%Y) and .date.month == $(date +%-m) and .date.day == $(date +%-d)) | .tx // 0" 2>/dev/null || true)
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

# --- 每日重置逻辑 ---
current_day=$(date +%Y-%m-%d)
if [ "$current_day" != "$LAST_RESET_DATE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ce-monitor: 检测到新的一天，重置每日计数器和限速状态。" >> "$TRAFFIC_LOG"
    current_stats=($(get_current_usage_bytes_raw))
    current_rx_for_reset=${current_stats[0]}
    current_tx_for_reset=${current_stats[1]}

    # 更新配置文件中的起始值和日期
    sed -i "s/DAILY_START_RX=.*/DAILY_START_RX=$current_rx_for_reset/" "$CONFIG_FILE"
    sed -i "s/DAILY_START_TX=.*/DAILY_START_TX=$current_tx_for_reset/" "$CONFIG_FILE"
    sed -i "s/LAST_RESET_DATE=.*/LAST_RESET_DATE=$current_day/" "$CONFIG_FILE"
    
    if [ "$LIMIT_ENABLED" = "true" ]; then
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
        sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' "$CONFIG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ce-monitor: 新的一天，自动解除限速。" >> "$TRAFFIC_LOG"
    fi
    # 重新加载配置，确保后续操作使用最新值
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# --- 每月重置逻辑 ---
current_month=$(date +%Y-%m)
if [ "$current_month" != "$LAST_MONTHLY_RESET_DATE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ce-monitor: 检测到新的月份，重置每月计数器。" >> "$TRAFFIC_LOG"
    current_stats=($(get_current_usage_bytes_raw))
    current_rx_for_reset=${current_stats[0]}
    current_tx_for_reset=${current_stats[1]}

    sed -i "s/MONTHLY_START_RX=.*/MONTHLY_START_RX=$current_rx_for_reset/" "$CONFIG_FILE"
    sed -i "s/MONTHLY_START_TX=.*/MONTHLY_START_TX=$current_tx_for_reset/" "$CONFIG_FILE"
    sed -i "s/LAST_MONTHLY_RESET_DATE=.*/LAST_MONTHLY_RESET_DATE=$current_month/" "$CONFIG_FILE"
    # 重新加载配置，确保后续操作使用最新值
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi


# 获取当日流量使用量
daily_current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
daily_current_tx=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
daily_total_bytes=$(( (daily_current_rx - DAILY_START_RX) + (daily_current_tx - DAILY_START_TX) ))

# 如果系统统计出现负数，使用vnStat作为备选
if [ "$daily_total_bytes" -lt 0 ] || ([ "$DAILY_START_RX" -eq 0 ] && [ "$DAILY_START_TX" -eq 0 ] && [ "$daily_current_rx" -gt 0 ] ); then
    daily_total_bytes=$(get_vnstat_daily_bytes_monitor)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ce-monitor: 每日流量计算负数或起始值异常，使用vnStat备选: $daily_total_bytes 字节" >> "$TRAFFIC_LOG"
fi

used_gb=$(echo "scale=3; $daily_total_bytes / 1024 / 1024 / 1024" | bc)
limit_reached=$(echo "$used_gb >= $DAILY_LIMIT" | bc)

if [ "$limit_reached" -eq 1 ] && [ "$LIMIT_ENABLED" != "true" ]; then
    # 自动启用限速
    speed_bps=$((SPEED_LIMIT * 8 * 1024))
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${speed_bps}bit"
    tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${speed_bps}bit" ceil "${speed_bps}bit"
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:10
    sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=true/' "$CONFIG_FILE"
    
    # 记录日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 自动限速触发: 使用量=${used_gb}GB" >> "$TRAFFIC_LOG"
fi
EOF

    chmod +x "$MONITOR_SCRIPT"
    systemctl daemon-reload
    echo -e "${GREEN}监控服务脚本已创建: $MONITOR_SCRIPT${NC}"
    echo -e "${GREEN}Systemd 服务文件已创建: $SERVICE_FILE${NC}"
}

# 创建定时器
create_timer() {
    cat > "$TIMER_FILE" << EOF
[Unit]
Description=CE Traffic Monitor Timer
Requires=ce-traffic-monitor.service

[Timer]
OnCalendar=*:0/3
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable ce-traffic-monitor.timer
    systemctl start ce-traffic-monitor.timer
    echo -e "${GREEN}Systemd 定时器已创建并启动: $TIMER_FILE${NC}"
}

# 显示实时状态
show_status() {
    clear # 清屏以获得更好的显示效果
    load_config
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    CE 流量限速管理系统                       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 系统信息
    echo -e "${WHITE}系统版本:${NC} $(lsb_release -d | cut -f2)"
    echo -e "${WHITE}网络接口:${NC} $INTERFACE"
    echo -e "${WHITE}vnStat版本:${NC} $(vnstat --version 2>/dev/null | head -1 | awk '{print $2}' || echo "未知")"
    echo -e "${WHITE}更新时间:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # 流量使用情况 - 日
    local used_daily_bytes=$(get_daily_usage_bytes)
    local used_daily_gb=$(echo "scale=3; $used_daily_bytes / 1024 / 1024 / 1024" | bc)
    local remaining_daily_gb=$(echo "scale=3; $DAILY_LIMIT - $used_daily_gb" | bc)
    local percentage_daily=$(echo "scale=1; $used_daily_gb * 100 / $DAILY_LIMIT" | bc 2>/dev/null || echo "0")
    
    echo -e "${WHITE}今日流量使用 (精确统计 - ${LAST_RESET_DATE}):${NC}"
    echo -e "  已用: ${GREEN}${used_daily_gb}GB${NC} / ${YELLOW}${DAILY_LIMIT}GB${NC} (${percentage_daily}%)"
    echo -e "  剩余: ${CYAN}${remaining_daily_gb}GB${NC}"
    # 这里的详细RX/TX也直接使用基于总字节数的显示，避免负数问题
    echo -e "  总计: $(format_traffic "$used_daily_bytes")"
    
    # 每日进度条
    local bar_length=50
    local filled_length=$(echo "$percentage_daily * $bar_length / 100" | bc 2>/dev/null | cut -d. -f1)
    [ -z "$filled_length" ] && filled_length=0
    
    local bar_daily=""
    local bar_daily_color=""
    if [ "$(echo "$percentage_daily >= 90" | bc)" -eq 1 ]; then
        bar_daily_color="$RED"
    elif [ "$(echo "$percentage_daily >= 70" | bc)" -eq 1 ]; then
        bar_daily_color="$YELLOW"
    else
        bar_daily_color="$GREEN"
    fi
    
    for ((i=0; i<bar_length; i++)); do
        if [ $i -lt "$filled_length" ]; then
            bar_daily+="█"
        else
            bar_daily+="░"
        fi
    done
    echo -e "  [${bar_daily_color}$bar_daily${NC}]"
    echo ""

    # 流量使用情况 - 月
    local used_monthly_bytes=$(get_monthly_usage_bytes)
    local used_monthly_gb=$(echo "scale=3; $used_monthly_bytes / 1024 / 1024 / 1024" | bc)
    local remaining_monthly_gb=$(echo "scale=3; $MONTHLY_LIMIT - $used_monthly_gb" | bc)
    local percentage_monthly=$(echo "scale=1; $used_monthly_gb * 100 / $MONTHLY_LIMIT" | bc 2>/dev/null || echo "0")
    
    echo -e "${WHITE}本月流量使用 (精确统计 - ${LAST_MONTHLY_RESET_DATE}):${NC}"
    echo -e "  已用: ${GREEN}${used_monthly_gb}GB${NC} / ${YELLOW}${MONTHLY_LIMIT}GB${NC} (${percentage_monthly}%)"
    echo -e "  剩余: ${CYAN}${remaining_monthly_gb}GB${NC}"
    echo -e "  总计: $(format_traffic "$used_monthly_bytes")"

    # 每月进度条
    local monthly_filled_length=$(echo "$percentage_monthly * $bar_length / 100" | bc 2>/dev/null | cut -d. -f1)
    [ -z "$monthly_filled_length" ] && monthly_filled_length=0
    
    local bar_monthly=""
    local bar_monthly_color=""
    if [ "$(echo "$percentage_monthly >= 90" | bc)" -eq 1 ]; then
        bar_monthly_color="$RED"
    elif [ "$(echo "$percentage_monthly >= 70" | bc)" -eq 1 ]; then
        bar_monthly_color="$YELLOW"
    else
        bar_monthly_color="$GREEN"
    fi
    
    for ((i=0; i<bar_length; i++)); do
        if [ $i -lt "$monthly_filled_length" ]; then
            bar_monthly+="█"
        else
            bar_monthly+="░"
        fi
    done
    echo -e "  [${bar_monthly_color}$bar_monthly${NC}]"
    echo ""
    
    # 限速状态
    if [ "$LIMIT_ENABLED" = "true" ]; then
        echo -e "${RED}⚠️  限速状态: 已启用 (${SPEED_LIMIT}KB/s)${NC}"
    else
        echo -e "${GREEN}✅ 限速状态: 未启用${NC}"
    fi
    echo ""
}

# 主菜单
show_menu() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                          操作菜单                            ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  ${WHITE}1.${NC} 开启流量限速                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}2.${NC} 解除流量限速                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}3.${NC} 网络速度测试                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}4.${NC} 强制刷新统计                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}5.${NC} 详细流量统计                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}6.${NC} 重置今日计数                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}7.${NC} 重置每月计数                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}8.${NC} 卸载所有组件                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}9.${NC} 刷新显示                                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}0.${NC} 退出程序                                                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 重置今日计数
reset_daily_counter() {
    echo -e "${RED}确认重置今日流量计数? 这将重新开始计算今日流量 (y/N): ${NC}"
    read -rp "请输入 (y/N): " confirm_reset
    if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}重置今日流量计数器...${NC}"
        
        # 记录重置前的使用量
        local before_usage=$(get_daily_usage_bytes false) # 传入false避免递归调用
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动重置每日计数器，重置前使用量: $(format_traffic "$before_usage")" >> "$TRAFFIC_LOG"
        
        # 重置计数器
        init_daily_counter
        
        # 如果当前有限速，询问是否解除
        if [ "$LIMIT_ENABLED" = "true" ]; then
            echo -e "${YELLOW}检测到当前有限速，是否同时解除限速? (y/N): ${NC}"
            read -rp "请输入 (y/N): " remove_limit
            if [[ "$remove_limit" =~ ^[Yy]$ ]]; then
                remove_speed_limit
            fi
        fi
        
        echo -e "${GREEN}今日流量计数器已重置${NC}"
    fi
}

# 重置每月计数
reset_monthly_counter() {
    echo -e "${RED}确认重置每月流量计数? 这将重新开始计算每月流量 (y/N): ${NC}"
    read -rp "请输入 (y/N): " confirm_reset
    if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}重置每月流量计数器...${NC}"
        
        # 记录重置前的使用量
        local before_usage=$(get_monthly_usage_bytes false) # 传入false避免递归调用
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动重置每月计数器，重置前使用量: $(format_traffic "$before_usage")" >> "$TRAFFIC_LOG"
        
        # 重置计数器
        init_monthly_counter
        
        echo -e "${GREEN}每月流量计数器已重置${NC}"
    fi
}

# 卸载功能
uninstall_all() {
    echo -e "${RED}确认卸载所有组件? (y/N): ${NC}"
    read -rp "请输入 (y/N): " confirm_uninstall
    if [[ "$confirm_uninstall" =~ ^[Yy]$ ]]; then
       echo -e "${YELLOW}卸载中...${NC}"
       
       # 停止并禁用服务和定时器
       systemctl stop ce-traffic-monitor.timer 2>/dev/null || true
       systemctl disable ce-traffic-monitor.timer 2>/dev/null || true
       systemctl stop ce-traffic-monitor.service 2>/dev/null || true
       
       # 移除限速 (可能INTERFACE变量已丢失，但tc命令通常不依赖于配置文件)
       tc qdisc del dev "${INTERFACE:-eth0}" root 2>/dev/null || true # 尝试使用默认eth0以防INTERFACE丢失
       
       # 删除文件
       rm -f "$CONFIG_FILE"
       rm -f "$SERVICE_FILE"
       rm -f "$TIMER_FILE"
       rm -f "$MONITOR_SCRIPT"
       rm -f "$INSTALLER_PATH" # 移除安装器本身
       rm -f "$SCRIPT_PATH"    # 移除快捷命令
       rm -f "$TRAFFIC_LOG"
       rm -f "/etc/vnstat.conf.backup"
       
       systemctl daemon-reload # 重新加载systemd配置
       
       # 尝试卸载依赖，但避免误删常用包
       echo -e "${YELLOW}尝试清理依赖 (vnstat, speedtest-cli)...${NC}"
       apt remove -y vnstat speedtest-cli 2>/dev/null || true
       apt autoremove -y 2>/dev/null || true
       
       echo -e "${GREEN}卸载完成${NC}"
       exit 0
    fi
}

# 交互界面
interactive_mode() {
    while true; do
        show_status
        show_menu
        
        read -rp "请选择操作 [0-9]: " choice
        
        case "$choice" in
            1)
                apply_speed_limit
                read -rp "按回车键继续..."
                ;;
            2)
                remove_speed_limit
                read -rp "按回车键继续..."
                ;;
            3)
                speed_test
                read -rp "按回车键继续..."
                ;;
            4)
                force_refresh
                read -rp "按回车键继续..."
                ;;
            5)
                show_detailed_stats
                read -rp "按回车键继续..."
                ;;
            6)
                reset_daily_counter
                read -rp "按回车键继续..."
                ;;
            7) # New option for monthly reset
                reset_monthly_counter
                read -rp "按回车键继续..."
                ;;
            8)
                uninstall_all
                ;;
            9) # New option for refresh display
                continue # 跳过 read -p，直接进入下一轮循环刷新显示
                ;;
            0)
                echo -e "${GREEN}感谢使用 CE 流量限速管理系统${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                read -rp "按回车键继续..."
                ;;
        esac
    done
}

# 创建ce命令
create_ce_command() {
    # This is a wrapper script to launch the main script in interactive mode
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# 这个是快捷启动脚本，调用主安装/管理脚本

# Source the config file to get INTERFACE, etc.
if [ -f "/etc/ce_traffic_limit.conf" ]; then
    # shellcheck source=/dev/null
    source "/etc/ce_traffic_limit.conf" 2>/dev/null || true
fi

# Determine the path to the main script (this script assumes it's copied)
MAIN_SCRIPT="/usr/local/bin/install_ce.sh"

# Check if the main script exists
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo -e "\033[0;31m错误: 主脚本 $MAIN_SCRIPT 未找到。请重新运行安装程序。\033[0m"
    exit 1
fi

# Check if it's an interactive call or a direct command call
if [ "$#" -eq 0 ]; then # No arguments provided
    "$MAIN_SCRIPT" --interactive
else
    "$MAIN_SCRIPT" "$@"
fi
EOF
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}ce 命令已创建: $SCRIPT_PATH${NC}"
}

# 主安装函数
main_install() {
    echo -e "${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║              CE 流量限速管理系统 - 安装程序                  ║${NC}"
    echo -e "${PURPLE}║                 精确流量统计 & 每月统计版本                  ║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    get_system_info
    detect_interface
    install_dependencies
    create_config # 创建配置并初始化今日/每月计数器
    create_monitor_service
    create_timer
    
    # 复制脚本到系统目录，以便后续ce命令调用和更新
    cp "$0" "$INSTALLER_PATH"
    chmod +x "$INSTALLER_PATH"
    
    create_ce_command
    
    # 创建日志文件并设置权限
    touch "$TRAFFIC_LOG"
    chmod 644 "$TRAFFIC_LOG"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                          安装完成！                          ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  输入 'ce' 命令进入交互界面                                  ║${NC}"
    echo -e "${GREEN}║  每日流量限制: ${DAILY_LIMIT}GB/天                             ║${NC}"
    echo -e "${GREEN}║  每月流量限制: ${MONTHLY_LIMIT}GB/月                           ║${NC}"
    echo -e "${GREEN}║  限速速度: ${SPEED_LIMIT}KB/s                                 ║${NC}"
    echo -e "${GREEN}║  统计方式: 系统网卡精确统计 (支持vnStat备选)                 ║${NC}"
    echo -e "${GREEN}║  新增功能: 每月流量统计、详细统计、手动重置                  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}提示: 系统已开始精确统计今日及本月流量使用情况${NC}"
}

# ==============================================================================
# 主程序入口
# ==============================================================================

# 根据参数或配置文件存在与否决定是安装还是进入交互模式
case "${1:-}" in # "${1:-}" 防止参数未提供时报错
    --interactive)
        interactive_mode
        ;;
    --install)
        main_install
        ;;
    --uninstall) # 新增直接卸载选项
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
