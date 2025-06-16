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
    apt install -y vnstat iproute2 bc coreutils jq
    
    # 启动vnstat服务
    systemctl enable vnstat
    systemctl start vnstat
    
    # 添加网卡到vnstat
    vnstat -i $INTERFACE --create
    
    # 等待vnstat初始化
    echo -e "${YELLOW}等待vnStat初始化...${NC}"
    sleep 5
    
    echo -e "${GREEN}依赖安装完成${NC}"
}

# 创建配置文件
create_config() {
    cat > $CONFIG_FILE << EOF
DAILY_LIMIT=$DAILY_LIMIT
SPEED_LIMIT=$SPEED_LIMIT
INTERFACE=$INTERFACE
LIMIT_ENABLED=false
LAST_RESET_DATE=$(date +%Y-%m-%d)
EOF
    echo -e "${GREEN}配置文件已创建: $CONFIG_FILE${NC}"
}

# 读取配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source $CONFIG_FILE
    fi
}

# 强制刷新vnStat数据
refresh_vnstat() {
    echo -e "${YELLOW}刷新流量统计数据...${NC}"
    # 强制vnStat更新数据库
    vnstat -i $INTERFACE --force
    systemctl restart vnstat
    sleep 2
    echo -e "${GREEN}数据已刷新${NC}"
}

# 获取今日流量使用量 (字节)
get_daily_usage() {
    # 尝试多种方式获取流量数据
    local usage_bytes=0
    
    # 方法1: 使用vnStat JSON输出
    if command -v jq &> /dev/null; then
        local json_output=$(vnstat -i $INTERFACE --json d 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$json_output" ]; then
            local rx_bytes=$(echo "$json_output" | jq -r '.interfaces[0].traffic.day[0].rx // 0' 2>/dev/null)
            local tx_bytes=$(echo "$json_output" | jq -r '.interfaces[0].traffic.day[0].tx // 0' 2>/dev/null)
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                usage_bytes=$((rx_bytes + tx_bytes))
            fi
        fi
    fi
    
    # 方法2: 如果JSON方式失败，使用传统方式
    if [ "$usage_bytes" -eq 0 ]; then
        local vnstat_output=$(vnstat -i $INTERFACE -d | grep "$(date +%Y-%m-%d)" | tail -1)
        if [ -n "$vnstat_output" ]; then
            # 解析vnStat输出
            local rx_str=$(echo "$vnstat_output" | awk '{print $2}')
            local tx_str=$(echo "$vnstat_output" | awk '{print $3}')
            
            # 转换为字节
            usage_bytes=$(($(convert_to_bytes "$rx_str") + $(convert_to_bytes "$tx_str")))
        fi
    fi
    
    # 方法3: 从系统文件获取接口统计
    if [ "$usage_bytes" -eq 0 ]; then
        if [ -f "/sys/class/net/$INTERFACE/statistics/rx_bytes" ] && [ -f "/sys/class/net/$INTERFACE/statistics/tx_bytes" ]; then
            local rx_bytes=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
            local tx_bytes=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
            
            # 检查是否需要重置每日计数
            local today=$(date +%Y-%m-%d)
            if [ "$today" != "$LAST_RESET_DATE" ]; then
                # 新的一天，重置计数
                echo "$rx_bytes" > /tmp/ce_rx_start
                echo "$tx_bytes" > /tmp/ce_tx_start
                sed -i "s/LAST_RESET_DATE=.*/LAST_RESET_DATE=$today/" $CONFIG_FILE
            fi
            
            # 计算今日使用量
            local rx_start=$(cat /tmp/ce_rx_start 2>/dev/null || echo 0)
            local tx_start=$(cat /tmp/ce_tx_start 2>/dev/null || echo 0)
            usage_bytes=$(( (rx_bytes - rx_start) + (tx_bytes - tx_start) ))
        fi
    fi
    
    echo "$usage_bytes"
}

# 转换流量单位为字节
convert_to_bytes() {
    local input="$1"
    local number=$(echo "$input" | sed 's/[^0-9.]//g')
    local unit=$(echo "$input" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    
    case "$unit" in
        "KB"|"K") echo "$number * 1024" | bc | cut -d. -f1 ;;
        "MB"|"M") echo "$number * 1024 * 1024" | bc | cut -d. -f1 ;;
        "GB"|"G") echo "$number * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        "TB"|"T") echo "$number * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
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
        local gb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc)
        echo "${gb}GB"
    fi
}

# 检查是否达到限制
check_limit() {
    local used_bytes=$(get_daily_usage)
    local used_gb=$(echo "scale=2; $used_bytes / 1024 / 1024 / 1024" | bc)
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
    echo -e "${GREEN}限速已启用: ${SPEED_LIMIT}KB/s${NC}"
}

# 移除限速
remove_speed_limit() {
    echo -e "${YELLOW}移除限速设置...${NC}"
    tc qdisc del dev $INTERFACE root 2>/dev/null
    sed -i 's/LIMIT_ENABLED=.*/LIMIT_ENABLED=false/' $CONFIG_FILE
    echo -e "${GREEN}限速已移除${NC}"
}

# 网速测试
speed_test() {
    echo -e "${BLUE}开始网络速度测试...${NC}"
    echo -e "${YELLOW}注意: 测试完成后请等待数据更新...${NC}"
    
    # 记录测试前的流量
    local before_bytes=$(get_daily_usage)
    
    if command -v speedtest-cli &> /dev/null; then
        speedtest-cli --simple
    else
        echo -e "${YELLOW}安装speedtest-cli...${NC}"
        apt install -y speedtest-cli
        speedtest-cli --simple
    fi
    
    echo -e "${YELLOW}测试完成，正在更新流量统计...${NC}"
    
    # 强制刷新数据
    refresh_vnstat
    
    # 显示测试后的流量变化
    local after_bytes=$(get_daily_usage)
    local test_usage=$((after_bytes - before_bytes))
    
    if [ "$test_usage" -gt 0 ]; then
        echo -e "${GREEN}本次测试消耗流量: $(format_traffic $test_usage)${NC}"
    fi
    
    echo -e "${GREEN}流量统计已更新${NC}"
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

# 获取今日流量使用量
get_daily_usage() {
    local usage_bytes=0
    
    if command -v jq &> /dev/null; then
        local json_output=$(vnstat -i $INTERFACE --json d 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$json_output" ]; then
            local rx_bytes=$(echo "$json_output" | jq -r '.interfaces[0].traffic.day[0].rx // 0' 2>/dev/null)
            local tx_bytes=$(echo "$json_output" | jq -r '.interfaces[0].traffic.day[0].tx // 0' 2>/dev/null)
            if [[ "$rx_bytes" =~ ^[0-9]+$ ]] && [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                usage_bytes=$((rx_bytes + tx_bytes))
            fi
        fi
    fi
    
    echo "$usage_bytes"
}

# 检查流量是否超限
used_bytes=$(get_daily_usage)
used_gb=$(echo "scale=2; $used_bytes / 1024 / 1024 / 1024" | bc)
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
    echo "$(date): 流量超限自动启用限速 - 使用量: ${used_gb}GB" >> /var/log/ce-traffic.log
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
OnCalendar=*:0/5
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
    echo -e "${WHITE}vnStat版本:${NC} $(vnstat --version 2>/dev/null | head -1 || echo "未知")"
    echo -e "${WHITE}更新时间:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # 流量使用情况
    local used_bytes=$(get_daily_usage)
    local used_gb=$(echo "scale=2; $used_bytes / 1024 / 1024 / 1024" | bc)
    local percentage=$(echo "scale=1; $used_gb * 100 / $DAILY_LIMIT" | bc 2>/dev/null || echo "0")
    
    echo -e "${WHITE}今日流量使用:${NC}"
    echo -e "  已用: ${GREEN}${used_gb}GB${NC} / ${YELLOW}${DAILY_LIMIT}GB${NC} (${percentage}%)"
    echo -e "  剩余: ${CYAN}$(echo "$DAILY_LIMIT - $used_gb" | bc)GB${NC}"
    
    # 进度条
    local bar_length=50
    local filled_length=$(echo "$percentage * $bar_length / 100" | bc 2>/dev/null | cut -d. -f1)
    [ -z "$filled_length" ] && filled_length=0
    
    local bar=""
    for ((i=0; i<bar_length; i++)); do
        if [ $i -lt $filled_length ]; then
            bar+="█"
        else
            bar+="░"
        fi
    done
    echo -e "  [${GREEN}$bar${NC}]"
    echo ""
    
    # 限速状态
    if [ "$LIMIT_ENABLED" = "true" ]; then
        echo -e "${RED}⚠️  限速状态: 已启用 (${SPEED_LIMIT}KB/s)${NC}"
    else
        echo -e "${GREEN}✅ 限速状态: 未启用${NC}"
    fi
    
    # 显示当前网络状态
    local current_rx=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    local current_tx=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    echo -e "${WHITE}网卡统计:${NC} 接收 $(format_traffic $current_rx) | 发送 $(format_traffic $current_tx)"
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
    echo -e "${CYAN}║  ${WHITE}4.${NC} 刷新流量统计                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}5.${NC} 卸载所有组件                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}6.${NC} 刷新显示                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║  ${WHITE}0.${NC} 退出程序                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
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
        rm -f /tmp/ce_rx_start
        rm -f /tmp/ce_tx_start
        rm -f /var/log/ce-traffic.log
        
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
        
        read -p "请选择操作 [0-6]: " choice
        
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
                refresh_vnstat
                read -p "按回车键继续..."
                ;;
            5)
                uninstall_all
                ;;
            6)
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
source /etc/ce_traffic_limit.conf 2>/dev/null

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
    
    # 初始化流量计数器
    if [ -f "/sys/class/net/$INTERFACE/statistics/rx_bytes" ]; then
        cat /sys/class/net/$INTERFACE/statistics/rx_bytes > /tmp/ce_rx_start
        cat /sys/class/net/$INTERFACE/statistics/tx_bytes > /tmp/ce_tx_start
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    安装完成！                              ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  输入 'ce' 命令进入交互界面                                ║${NC}"
    echo -e "${GREEN}║  流量限制: ${DAILY_LIMIT}GB/天                                        ║${NC}"
    echo -e "${GREEN}║  限速速度: ${SPEED_LIMIT}KB/s                                      ║${NC}"
    echo -e "${GREEN}║  新增功能: 强制刷新流量统计                                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
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