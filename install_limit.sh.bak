#!/bin/bash
VERSION="1.0"

# 确保以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root用户运行"
    exit 1
fi

# 脚本自身路径
SELF=$(readlink -f "$0")
if [ "$SELF" != "/root/install_limit.sh" ]; then
    echo "将脚本复制到 /root/install_limit.sh"
    cp "$SELF" /root/install_limit.sh
    chmod +x /root/install_limit.sh
    echo "脚本已保存至 /root/install_limit.sh"
fi

# 自动检查更新（请根据实际情况修改更新地址）
UPDATE_URL="https://example.com/install_limit.sh"
VERSION_URL="https://example.com/version.txt"
check_update() {
    echo "检查脚本更新..."
    if command -v curl >/dev/null 2>&1; then
        remote_version=$(curl -s "$VERSION_URL")
    elif command -v wget >/dev/null 2>&1; then
        remote_version=$(wget -qO- "$VERSION_URL")
    else
        echo "请安装curl或wget以检查更新"
        return
    fi
    if [ -n "$remote_version" ] && [ "$remote_version" != "$VERSION" ]; then
        echo "发现新版本 $remote_version，即将更新脚本..."
        if command -v curl >/dev/null 2>&1; then
            curl -s -o /root/install_limit.sh "$UPDATE_URL"
        else
            wget -q -O /root/install_limit.sh "$UPDATE_URL"
        fi
        chmod +x /root/install_limit.sh
        echo "更新完成，请重新运行脚本"
        exit 0
    else
        echo "当前已是最新版本 ($VERSION)"
    fi
}
check_update

# 检测主网卡（用于限速）
INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(route -n | awk '/^0.0.0.0/ {print $8; exit}')
fi
echo "主网卡接口: $INTERFACE"

# 辅助函数：获取今日总流量的字节数
get_today_traffic_bytes() {
    data=$(vnstat --oneline -i $INTERFACE)
    total=$(echo "$data" | cut -d';' -f6)
    num=$(echo $total | sed -E 's/([0-9]+\.[0-9]+|[0-9]+)(.*)/\1/')
    unit=$(echo $total | sed -E 's/([0-9]+\.[0-9]+|[0-9]+)(.*)/\2/')
    case "$unit" in
        B) factor=1 ;;
        KiB) factor=1024 ;;
        MiB) factor=$((1024**2)) ;;
        GiB) factor=$((1024**3)) ;;
        TiB) factor=$((1024**4)) ;;
        *) factor=1 ;;
    esac
    echo $(echo "$num * $factor" | bc)
}

# 每小时检测是否超过流量阈值，超出则限速
limit_check() {
    source /etc/limit_config.conf
    today_bytes=$(get_today_traffic_bytes)
    limit_bytes=$(echo "$LIMIT_GB * 1024 * 1024 * 1024" | bc)
    if [ -n "$today_bytes" ] && [ "$today_bytes" -ge "$limit_bytes" ]; then
        echo "今日流量已超过阈值 ($LIMIT_GB GB)，开始限速"
        /root/limit_bandwidth.sh
    fi
}

# 每日解除限速并更新流量统计
clear_limit() {
    /root/clear_limit.sh
    echo "流量已重置，正在更新vnstat统计..."
    vnstat -u
}

# 如果脚本以参数运行，用于定时任务
case "$1" in
    limit_check) limit_check; exit 0 ;;
    clear_limit) clear_limit; exit 0 ;;
esac

# 初始化配置文件
if [ ! -f /etc/limit_config.conf ]; then
    echo "初始化配置文件 /etc/limit_config.conf"
    cat >/etc/limit_config.conf <<EOF
# 流量限制阈值 (单位: GB)
LIMIT_GB=100
# 网络限速 (单位: kbit/s 或 mbit/s，如1Mbit)
LIMIT_RATE=1Mbit
EOF
    echo "配置文件已创建 (/etc/limit_config.conf)"
fi

# 检测系统类型
if [ -f /etc/debian_version ]; then
    echo "检测到 Debian/Ubuntu 系统"
    PKG_MANAGER="apt-get"
elif [ -f /etc/redhat-release ]; then
    echo "检测到 CentOS/RedHat 系统"
    PKG_MANAGER="yum"
else
    echo "不支持的操作系统"
    exit 1
fi

# 安装依赖
echo "安装依赖: vnstat, bc"
if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt-get update -y
    apt-get install -y vnstat bc
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install -y epel-release
    yum install -y vnstat bc
fi

# 初始化 vnstat
echo "初始化 vnstat 数据库"
vnstat --add -i $INTERFACE 2>/dev/null
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable vnstat >/dev/null 2>&1
    systemctl restart vnstat
else
    service vnstat restart
fi
echo "vnstat 服务已启动"

# 创建限速脚本
echo "创建限速脚本 /root/limit_bandwidth.sh"
cat <<'EOF' > /root/limit_bandwidth.sh
#!/bin/bash
source /etc/limit_config.conf
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}')
tc qdisc del dev $INTERFACE root 2>/dev/null
tc qdisc add dev $INTERFACE root tbf rate ${LIMIT_RATE} latency 50ms burst 1540
echo "已设置限速: ${LIMIT_RATE}"
EOF
chmod +x /root/limit_bandwidth.sh

# 创建解除限速脚本
echo "创建清除限速脚本 /root/clear_limit.sh"
cat <<'EOF' > /root/clear_limit.sh
#!/bin/bash
source /etc/limit_config.conf
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}')
tc qdisc del dev $INTERFACE root 2>/dev/null
echo "已解除限速"
EOF
chmod +x /root/clear_limit.sh

# 创建交互式命令 ce
echo "创建交互式管理命令 ce (/usr/local/bin/ce)"
cat <<'EOF' > /usr/local/bin/ce
#!/bin/bash
source /etc/limit_config.conf
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}')
get_today_traffic() {
    data=$(vnstat --oneline -i $INTERFACE)
    rx=$(echo "$data" | cut -d';' -f4)
    tx=$(echo "$data" | cut -d';' -f5)
    total=$(echo "$data" | cut -d';' -f6)
    echo "今日流量: 下载 $rx, 上传 $tx, 合计 $total"
}
get_limit_status() {
    status=$(tc qdisc show dev $INTERFACE 2>/dev/null)
    if echo "$status" | grep -q 'tbf'; then
        echo "当前状态: 已限速 (限速速率: $LIMIT_RATE)"
    else
        echo "当前状态: 未限速"
    fi
}
get_usage_info() {
    data=$(vnstat --oneline -i $INTERFACE)
    rx_month=$(echo "$data" | cut -d';' -f9)
    tx_month=$(echo "$data" | cut -d';' -f10)
    total_month=$(echo "$data" | cut -d';' -f11)
    echo "本月流量: 下载 $rx_month, 上传 $tx_month, 合计 $total_month"
}
modify_config() {
    read -p "请输入新的流量限制 (GB): " newgb
    read -p "请输入新的限速 (如1Mbit): " newrate
    if [[ "$newgb" =~ ^[0-9]+$ ]]; then
        sed -i "s/^LIMIT_GB=.*/LIMIT_GB=$newgb/" /etc/limit_config.conf
    fi
    if [[ -n "$newrate" ]]; then
        sed -i "s/^LIMIT_RATE=.*/LIMIT_RATE=$newrate/" /etc/limit_config.conf
    fi
    echo "配置已更新"
}
show_menu() {
    echo "========== 流量限速管理脚本 =========="
    echo "1. 查看今日流量"
    echo "2. 查看限速状态"
    echo "3. 手动限速"
    echo "4. 手动解除限速"
    echo "5. 修改配置"
    echo "6. 删除脚本"
    echo "0. 退出"
    read -p "请输入选项: " opt
    case $opt in
        1) get_today_traffic ;;
        2) get_limit_status ;;
        3) /root/limit_bandwidth.sh ;;
        4) /root/clear_limit.sh ;;
        5) modify_config ;;
        6)
            read -p "确认删除所有脚本和配置? (y/n): " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh /usr/local/bin/ce
                rm -f /etc/limit_config.conf
                crontab -l | grep -v 'install_limit.sh' | grep -v 'limit_bandwidth.sh' | grep -v 'clear_limit.sh' | crontab -
                echo "已删除所有相关脚本和配置"
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}
show_menu
EOF
chmod +x /usr/local/bin/ce

# 设置定时任务
echo "设置定时任务: 每小时检查限速，每天0点解除限速并更新统计"
(
    crontab -l 2>/dev/null | grep -v 'install_limit.sh' | grep -v 'limit_bandwidth.sh' | grep -v 'clear_limit.sh'
    echo "0 * * * * /root/install_limit.sh limit_check"
    echo "0 0 * * * /root/install_limit.sh clear_limit"
    echo "0 0 * * * $(command -v vnstat) -u"
) | crontab -

echo "安装完成，请使用命令 ce 进行管理"