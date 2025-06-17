#!/bin/bash

# install_ce.sh - 流量限速管理系统
# 系统要求: Ubuntu 24.04.2 LTS
# 功能: vnStat + tc 流量监控与限速

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 配置文件路径
CONFIG_FILE="/etc/ce_traffic_limit.conf"
SERVICE_FILE="/etc/systemd/system/ce-traffic-monitor.service"
SCRIPT_PATH="/usr/local/bin/ce"
TRAFFIC_LOG="/var/log/ce-daily-traffic.log"

# 默认配置
DAILY_LIMIT=30 # GB
SPEED_LIMIT=512 # KB/s
INTERFACE=""

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
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}无法自动检测网卡，请手动选择:${NC}"
        ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo
        read -p "请输入网卡名称: " INTERFACE
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
    if [ -f /etc/vnstat.conf ]; then
        cp /etc/vnstat.conf /etc/vnstat.conf.backup
    fi
    
    # 修改vnStat配置以提高精度
    cat > /etc/vnstat.conf << 'EOF'
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
    
    # 添加网卡到vnstat
    vnstat -i $INTERFACE --create
    
    # 等待vnstat初始化
    echo -e "${YELLOW}等待vnStat初始化...${NC}"
    sleep 10
    
    echo -e "${GREEN}依赖安装完成${NC}"
}

# 创建配置文件
create_config() {
    local today=$(date +%Y-%m-%d)
    cat > $CONFIG_FILE << EOF
DAILY_LIMIT=$DAILY_LIMIT
SPEED_LIMIT=$SPEED_LIMIT
INTERFACE=$INTERFACE
LIMIT_ENABLED=false
LAST_RESET_DATE=$today
DAILY_START_RX=0
DAILY_START_TX=0
EOF
    
    # 初始化今日流量计数
    init_daily_counter
    
    echo -e "${GREEN}配置文件已创建: $CONFIG_FILE${NC}"
}

# 初始化每日流量计数器
init_daily_counter() {
    local today=$(date +%Y-%m-%d)
    local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    
    # 更新配置文件中的起始值
    sed -i "s/DAILY_START_RX=.*/DAILY_START_RX=$current_rx/" $CONFIG_FILE
    sed -i "s/DAILY_START_TX=.*/DAILY_START_TX=$current_tx/" $CONFIG_FILE
    sed -i "s/LAST_RESET_DATE=.*/LAST_RESET_DATE=$today/" $CONFIG_FILE
    
    # 记录到日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 初始化每日计数器: RX=$current_rx, TX=$current_tx" >> $TRAFFIC_LOG
}

# 读取配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source $CONFIG_FILE
    fi
}

# 检查并重置每日计数器
check_and_reset_daily() {
    local today=$(date +%Y-%m-%d)
    
    if [ "$today" != "$LAST_RESET_DATE" ]; then
        echo -e "${YELLOW}检测到新的一天，重置流量计数器...${NC}"
        
        # 记录昨日总流量
        local yesterday_usage=$(get_daily_usage_bytes)
        local yesterday_gb=$(echo "scale=2; $yesterday_usage / 1024 / 1024 / 1024" | bc)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 昨日($LAST_RESET_DATE)流量统计: ${yesterday_gb}GB" >> $TRAFFIC_LOG
        
        # 重置计数器
        init_daily_counter
        
        # 如果昨日有限速，新的一天自动解除
        if [ "$LIMIT_ENABLED" = "true" ]; then
            remove_speed_limit
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 新的一天，自动解除限速" >> $TRAFFIC_LOG
        fi
    fi
}

# 获取今日流量使用量（字节）- 主要方法
get_daily_usage_bytes() {
    load_config
    check_and_reset_daily
    
    local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    
    # 计算今日使用量
    local daily_rx=$((current_rx - DAILY_START_RX))
    local daily_tx=$((current_tx - DAILY_START_TX))
    local daily_total=$((daily_rx + daily_tx))
    
    # 如果出现负数（可能是网卡重置），使用vnStat作为备选
    if [ $daily_total -lt 0 ]; then
        daily_total=$(get_vnstat_daily_bytes)
    fi
    
    echo $daily_total
}

# vnStat备选方法
get_vnstat_daily_bytes() {
    local today=$(date +%Y-%m-%d)
    local vnstat_bytes=0
    
    # 方法1: JSON输出
    if command -v jq &> /dev/null; then
        local json_output=$(vnstat -i $INTERFACE --json d 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$json_output" ]; then
            # 查找今天的数据
            local rx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.day[] | select(.date == \"$today\") | .rx // 0" 2>/dev/null)
            local tx_bytes=$(echo "$json_output" | jq -r ".interfaces[0].traffic.day[] | select(.date == \"$today\") | .tx // 0" 2>/dev/null)
            
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                vnstat_bytes=$((rx_bytes + tx_bytes))
            fi
        fi
    fi
    
    # 方法2: 解析文本输出
    if [ $vnstat_bytes -eq 0 ]; then
        local vnstat_line=$(vnstat -i $INTERFACE -d | grep "$today" | tail -1)
        if [ -n "$vnstat_line" ]; then
            local rx_str=$(echo "$vnstat_line" | awk '{print $2}')
            local tx_str=$(echo "$vnstat_line" | awk '{print $3}')
            vnstat_bytes=$(($(convert_to_bytes "$rx_str") + $(convert_to_bytes "$tx_str")))
        fi
    fi
    
    echo $vnstat_bytes
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
    
    case "$unit" in
        "KIB"|"KB"|"K") echo "$number * 1024" | bc | cut -d. -f1 ;;
        "MIB"|"MB"|"M") echo "$number * 1024 * 1024" | bc | cut -d. -f1 ;;
        "GIB"|"GB"|"G") echo "$number * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        "TIB"|"TB"|"T") echo "$number * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        *) echo "$number" | cut -d. -f1 ;;
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
    
    # 强制vnStat写入数据
    vnstat -i $INTERFACE --force
    systemctl restart vnstat
    sleep 3
    
    # 重新加载配置
    load_config
    
    # 记录当前状态
    local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    local daily_usage=$(get_daily_usage_bytes)
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 强制刷新: 当前RX=$current_rx, TX=$current_tx, 今日使用=$(format_traffic $daily_usage)" >> $TRAFFIC_LOG
    
    echo -e "${GREEN}刷新完成${NC}"
}

# 检查是否达到限制
check_limit() {
    local used_bytes=$(get_daily_usage_bytes)
    local used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc)
    local limit_reached=$(echo "$used_gb >= $DAILY_LIMIT" | bc)
    echo $limit_reached
}

# 应用限速
apply_speed_limit() {
    echo -e "${YELLOW}应用限速设置...${NC}"
    
    # 清除现有规则
    tc qdisc del dev $INTERFACE root 2>/dev/null
    
    # 设置限速 (转换KB/s到bit/s)
    local speed_bps=$((SPEED_LIMIT * 8 * 1024))
    
    tc qdisc add dev $INTERFACE root handle 1: htb default 30
    tc class add dev $INTERFACE parent 1: classid 1:1 htb rate ${speed_bps}bit
    tc class add dev $INTERFACE parent 1:1 classid 1:10 htb rate ${speed_bps}bit ceil ${speed_bps}bit
    tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:10
    
    sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=true/' $CONFIG_FILE
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动启用限速: ${SPEED_LIMIT}KB/s" >> $TRAFFIC_LOG
    echo -e "${GREEN}限速已启用: ${SPEED_LIMIT}KB/s${NC}"
}

# 移除限速
remove_speed_limit() {
    echo -e "${YELLOW}移除限速设置...${NC}"
    tc qdisc del dev $INTERFACE root 2>/dev/null
    sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' $CONFIG_FILE
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动解除限速" >> $TRAFFIC_LOG
    echo -e "${GREEN}限速已移除${NC}"
}

# 网速测试
speed_test() {
    echo -e "${BLUE}开始网络速度测试...${NC}"
    echo -e "${YELLOW}注意: 测试会消耗流量，请确认继续 (y/N): ${NC}"
    read -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消测试${NC}"
        return
    fi
    
    # 记录测试前的流量
    local before_bytes=$(get_daily_usage_bytes)
    local before_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    if command -v speedtest-cli &> /dev/null; then
        speedtest-cli --simple
    else
        echo -e "${YELLOW}安装speedtest-cli...${NC}"
        apt install -y speedtest-cli
        speedtest-cli --simple
    fi
    
    echo -e "${YELLOW}测试完成，正在计算流量消耗...${NC}"
    sleep 2
    
    # 强制刷新并计算消耗
    force_refresh
    local after_bytes=$(get_daily_usage_bytes)
    local test_usage=$((after_bytes - before_bytes))
    
    if [ "$test_usage" -gt 0 ]; then
        echo -e "${GREEN}本次测试消耗流量: $(format_traffic $test_usage)${NC}"
        echo "$before_time - 速度测试消耗: $(format_traffic $test_usage)" >> $TRAFFIC_LOG
    else
        echo -e "${YELLOW}流量消耗计算可能不准确，请查看总使用量${NC}"
    fi
}

# 显示详细流量统计
show_detailed_stats() {
    load_config
    local today=$(date +%Y-%m-%d)
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    详细流量统计                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 系统网卡统计
    local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    local daily_rx=$((current_rx - DAILY_START_RX))
    local daily_tx=$((current_tx - DAILY_START_TX))
    local daily_total=$((daily_rx + daily_tx))
    
    echo -e "${WHITE}系统网卡统计 ($INTERFACE):${NC}"
    echo -e "  总接收: $(format_traffic $current_rx)"
    echo -e "  总发送: $(format_traffic $current_tx)"
    echo -e "  今日接收: $(format_traffic $daily_rx)"
    echo -e "  今日发送: $(format_traffic $daily_tx)"
    echo -e "  今日总计: $(format_traffic $daily_total)"
    echo ""
    
    # vnStat统计
    local vnstat_bytes=$(get_vnstat_daily_bytes)
    echo -e "${WHITE}vnStat统计 (今日):${NC}"
    echo -e "  vnStat显示: $(format_traffic $vnstat_bytes)"
    echo ""
    
    # 显示最近的日志
    echo -e "${WHITE}最近活动日志:${NC}"
    if [ -f "$TRAFFIC_LOG" ]; then
        tail -5 "$TRAFFIC_LOG" | while read line; do
            echo -e "  ${YELLOW}$line${NC}"
        done
    else
        echo -e "  ${YELLOW}暂无日志记录${NC}"
    fi
    echo ""
    
    # 配置信息
    echo -e "${WHITE}当前配置:${NC}"
    echo -e "  每日限制: ${DAILY_LIMIT}GB"
    echo -e "  限速速度: ${SPEED_LIMIT}KB/s"
    echo -e "  计数起始日期: $LAST_RESET_DATE"
    echo -e "  起始RX: $(format_traffic $DAILY_START_RX)"
    echo -e "  起始TX: $(format_traffic $DAILY_START_TX)"
    echo ""
}

# 创建监控服务
create_monitor_service() {
    cat > $SERVICE_FILE << EOF
[Unit]
Description=CE Traffic Monitor Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ce-monitor
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/bin/ce-monitor << 'EOF'
#!/bin/bash
source /etc/ce_traffic_limit.conf

# 流量统计函数
get_daily_usage_bytes() {
    local today=$(date +%Y-%m-%d)
    
    # 检查是否需要重置
    if [ "$today" != "$LAST_RESET_DATE" ]; then
        local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
        local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
        
        # 更新配置文件
        sed -i "s/DAILY_START_RX=.*/DAILY_START_RX=$current_rx/" /etc/ce_traffic_limit.conf
        sed -i "s/DAILY_START_TX=.*/DAILY_START_TX=$current_tx/" /etc/ce_traffic_limit.conf
        sed -i "s/LAST_RESET_DATE=.*/LAST_RESET_DATE=$today/" /etc/ce_traffic_limit.conf
        
        # 解除限速
        if [ "$LIMIT_ENABLED" = "true" ]; then
            tc qdisc del dev $INTERFACE root 2>/dev/null
            sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' /etc/ce_traffic_limit.conf
        fi
        
        # 重新加载配置
        source /etc/ce_traffic_limit.conf
    fi
    
    local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    local daily_total=$(( (current_rx - DAILY_START_RX) + (current_tx - DAILY_START_TX) ))
    
    echo $daily_total
}

# 检查流量是否超限
used_bytes=$(get_daily_usage_bytes)
used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc)
limit_reached=$(echo "$used_gb >= $DAILY_LIMIT" | bc)

if [ "$limit_reached" -eq 1 ] && [ "$LIMIT_ENABLED" != "true" ]; then
    # 自动启用限速
    speed_bps=$((SPEED_LIMIT * 8 * 1024))
    tc qdisc del dev $INTERFACE root 2>/dev/null
    tc qdisc add dev $INTERFACE root handle 1: htb default 30
    tc class add dev $INTERFACE parent 1: classid 1:1 htb rate ${speed_bps}bit
    tc class add dev $INTERFACE parent 1:1 classid 1:10 htb rate ${speed_bps}bit ceil ${speed_bps}bit
    tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:10
    sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=true/' /etc/ce_traffic_limit.conf
    
    # 记录日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 自动限速触发: 使用量=${used_gb}GB" >> /var/log/ce-daily-traffic.log
fi
EOF

    chmod +x /usr/local/bin/ce-monitor
    systemctl daemon-reload
}

# 创建定时器
create_timer() {
    cat > /etc/systemd/system/ce-traffic-monitor.timer << EOF
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
}

# 显示实时状态
show_status() {
    clear
    load_config
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    CE 流量限速管理系统                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 系统信息
    echo -e "${WHITE}系统版本:${NC} $(lsb_release -d | cut -f2)"
    echo -e "${WHITE}网络接口:${NC} $INTERFACE"
    echo -e "${WHITE}vnStat版本:${NC} $(vnstat --version 2>/dev/null | head -1 | awk '{print $2}' || echo "未知")"
    echo -e "${WHITE}更新时间:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${WHITE}统计起始:${NC} $LAST_RESET_DATE"
    echo ""
    
    # 流量使用情况
    local used_bytes=$(get_daily_usage_bytes)
    local used_gb=$(echo "scale=3; $used_bytes / 1024 / 1024 / 1024" | bc)
    local remaining_gb=$(echo "scale=3; $DAILY_LIMIT - $used_gb" | bc)
    local percentage=$(echo "scale=1; $used_gb * 100 / $DAILY_LIMIT" | bc 2>/dev/null || echo "0")
    
    echo -e "${WHITE}今日流量使用 (精确统计):${NC}"
    echo -e "  已用: ${GREEN}${used_gb}GB${NC} / ${YELLOW}${DAILY_LIMIT}GB${NC} (${percentage}%)"
    echo -e "  剩余: ${CYAN}${remaining_gb}GB${NC}"
    echo -e "  详细: 接收 $(format_traffic $(($(cat /sys/class/net/$INTERFACE/statistics/rx_bytes) - DAILY_START_RX))) | 发送 $(format_traffic $(($(cat /sys/class/net/$INTERFACE/statistics/tx_bytes) - DAILY_START_TX)))"
    
    # 进度条
    local bar_length=50
    local filled_length=$(echo "$percentage * $bar_length / 100" | bc 2>/dev/null | cut -d. -f1)
    [ -z "$filled_length" ] && filled_length=0
    
    local bar=""
    local bar_color=""
    if [ $(echo "$percentage >= 90" | bc) -eq 1 ]; then
        bar_color="$RED"
    elif [ $(echo "$percentage >= 70" | bc) -eq 1 ]; then
        bar_color="$YELLOW"
    else
        bar_color="$GREEN"
    fi
    
    for ((i=0; i<bar_length; i++)); do
        if [ $i -lt $filled_length ]; then
            bar+="█"
        else
            bar+="░"
        fi
    done
    echo -e "  [${bar_color}$bar${NC}]"
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
    echo -e "${CYAN}║                        操作菜单                            ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  ${WHITE}1.${NC} 开启流量限速                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}2.${NC} 解除流量限速                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}3.${NC} 网络速度测试                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}4.${NC} 强制刷新统计                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}5.${NC} 详细流量统计                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}6.${NC} 重置今日计数                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}7.${NC} 卸载所有组件                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}8.${NC} 刷新显示                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}0.${NC} 退出程序                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 重置今日计数
reset_daily_counter() {
    echo -e "${RED}确认重置今日流量计数? 这将重新开始计算今日流量 (y/N): ${NC}"
    read -r confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}重置今日流量计数器...${NC}"
        
        # 记录重置前的使用量
        local before_usage=$(get_daily_usage_bytes)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动重置计数器，重置前使用量: $(format_traffic $before_usage)" >> $TRAFFIC_LOG
        
        # 重置计数器
        init_daily_counter
        
        # 如果当前有限速，询问是否解除
        if [ "$LIMIT_ENABLED" = "true" ]; then
            echo -e "${YELLOW}检测到当前有限速，是否同时解除限速? (y/N): ${NC}"
            read -r remove_limit
            if [[ $remove_limit =~ ^[Yy]$ ]]; then
                remove_speed_limit
            fi
        fi
        
        echo -e "${GREEN}今日流量计数器已重置${NC}"
    fi
}

# 卸载功能
uninstall_all() {
    echo -e "${RED}确认卸载所有组件? (y/N): ${NC}"
    read -r confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
       echo -e "${YELLOW}卸载中...${NC}"
       
       # 停止服务
       systemctl stop ce-traffic-monitor.timer 2>/dev/null
       systemctl disable ce-traffic-monitor.timer 2>/dev/null
       
       # 移除限速
       tc qdisc del dev $INTERFACE root 2>/dev/null
       
       # 删除文件
       rm -f $CONFIG_FILE
       rm -f $SERVICE_FILE
       rm -f /etc/systemd/system/ce-traffic-monitor.timer
       rm -f /usr/local/bin/ce-monitor
       rm -f $SCRIPT_PATH
       rm -f $TRAFFIC_LOG
       rm -f /etc/vnstat.conf.backup
       
       systemctl daemon-reload
       
       echo -e "${GREEN}卸载完成${NC}"
       exit 0
   fi
}

# 交互界面
interactive_mode() {
   while true; do
       show_status
       show_menu
       
       read -p "请选择操作 [0-8]: " choice
       
       case $choice in
           1)
               apply_speed_limit
               read -p "按回车键继续..."
               ;;
           2)
               remove_speed_limit
               read -p "按回车键继续..."
               ;;
           3)
               speed_test
               read -p "按回车键继续..."
               ;;
           4)
               force_refresh
               read -p "按回车键继续..."
               ;;
           5)
               show_detailed_stats
               read -p "按回车键继续..."
               ;;
           6)
               reset_daily_counter
               read -p "按回车键继续..."
               ;;
           7)
               uninstall_all
               ;;
           8)
               continue
               ;;
           0)
               echo -e "${GREEN}感谢使用 CE 流量限速管理系统${NC}"
               exit 0
               ;;
           *)
               echo -e "${RED}无效选择，请重新输入${NC}"
               read -p "按回车键继续..."
               ;;
       esac
   done
}

# 创建ce命令
create_ce_command() {
   cat > $SCRIPT_PATH << 'EOF'
#!/bin/bash
if [ -f /etc/ce_traffic_limit.conf ]; then
   source /etc/ce_traffic_limit.conf 2>/dev/null
fi

# 检查是否是交互模式
if [ "$1" = "" ]; then
   /usr/local/bin/install_ce.sh --interactive
else
   /usr/local/bin/install_ce.sh "$@"
fi
EOF
   chmod +x $SCRIPT_PATH
   echo -e "${GREEN}ce 命令已创建${NC}"
}

# 主安装函数
main_install() {
   echo -e "${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
   echo -e "${PURPLE}║              CE 流量限速管理系统 - 安装程序                 ║${NC}"
   echo -e "${PURPLE}║                    精确流量统计版本                        ║${NC}"
   echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
   echo ""
   
   get_system_info
   detect_interface
   install_dependencies
   create_config
   create_monitor_service
   create_timer
   
   # 复制脚本到系统目录
   cp "$0" /usr/local/bin/install_ce.sh
   chmod +x /usr/local/bin/install_ce.sh
   
   create_ce_command
   
   # 创建日志目录
   touch $TRAFFIC_LOG
   chmod 644 $TRAFFIC_LOG
   
   echo ""
   echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
   echo -e "${GREEN}║                    安装完成！                              ║${NC}"
   echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
   echo -e "${GREEN}║  输入 'ce' 命令进入交互界面                                ║${NC}"
   echo -e "${GREEN}║  流量限制: ${DAILY_LIMIT}GB/天                                        ║${NC}"
   echo -e "${GREEN}║  限速速度: ${SPEED_LIMIT}KB/s                                      ║${NC}"
   echo -e "${GREEN}║  统计方式: 系统网卡精确统计                                ║${NC}"
   echo -e "${GREEN}║  新增功能: 详细统计、手动重置                              ║${NC}"
   echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
   echo ""
   echo -e "${YELLOW}提示: 系统已开始精确统计今日流量使用情况${NC}"
}

# 主程序入口
case "$1" in
   --interactive)
       interactive_mode
       ;;
   --install)
       main_install
       ;;
   *)
       if [ -f "$CONFIG_FILE" ]; then
           interactive_mode
       else
           main_install
       fi
       ;;
esac
    