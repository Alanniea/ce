#!/bin/bash
set -e

# ==================== 基础信息 ====================

VERSION="1.0.3"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE=/etc/limit_config.conf
mkdir -p /etc

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ==================== 自动保存自身 ====================

# 检查当前脚本是否位于预期的路径，如果不在且目标路径不存在，则从 GitHub 下载
if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
    echo "💾 正在保存 install_limit.sh 到 $SCRIPT_PATH..."
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ 已保存"
fi

# ==================== 自动更新函数 ====================

check_update() {
    echo "📡 正在检查更新..."
    # 从 GitHub 获取最新版本号
    LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
    | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    
    # 比较当前版本与最新版本
    if [[ "$LATEST" != "$VERSION" ]]; then
        echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
        read -p "是否立即更新？[Y/n] " choice
        if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
            # 下载并替换当前脚本
            curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo "✅ 更新完成，请执行 $SCRIPT_PATH 重新安装"
        else
            echo "🚫 已取消更新"
        fi
    else
        echo "✅ 已是最新版本（$VERSION）"
    fi
}

# ==================== 支持 --update 参数 ====================

# 如果第一个参数是 --update，则执行更新检查并退出
if [[ "$1" == "--update" ]]; then
    check_update
    exit 0
fi

# ==================== 初始化配置 ====================

# 如果配置文件不存在，则创建并写入默认配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
    echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi
# 加载配置文件
source "$CONFIG_FILE"

echo "🛠 [0/6] 检测系统与网卡..."
# 检测操作系统信息
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VER=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VER=$(uname -r)
fi
echo "系统：$OS_NAME $OS_VER"

# 检测主用网卡，排除虚拟和循环接口
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
if [ -z "$IFACE" ]; then
    echo "⚠️ 未检测到网卡，请手动设置 IFACE 变量或检查网络配置。"
    exit 1
fi
echo "主用网卡：$IFACE"

echo "🛠 [1/6] 安装依赖..."
# 根据系统包管理器安装所需依赖
if command -v apt >/dev/null; then
    apt update -y && apt install -y vnstat iproute2 curl speedtest-cli
elif command -v yum >/dev/null; then
    yum install -y epel-release && yum install -y vnstat iproute curl speedtest-cli
else
    echo "⚠️ 未知包管理器，请手动安装 vnstat、iproute2、speedtest-cli。"
    exit 1
fi

echo "✅ [2/6] 初始化 vnStat..."
# 初始化 vnStat 数据库并启用服务
vnstat -u -i "$IFACE" || true # 如果数据库已存在，此命令可能报错，所以加 || true
sleep 2 # 等待 vnStat 初始化
systemctl enable vnstat --now # 启用并立即启动 vnStat 服务
systemctl restart vnstat # 确保 vnStat 服务正在运行

echo "📝 [3/6] 生成限速脚本..."
# 生成限速逻辑脚本
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE" # 加载限速配置

LINE=$(vnstat -d -i "$IFACE" | grep "$(date '+%Y-%m-%d')")
# 提取今日接收流量和单位
RX=$(echo "$LINE" | awk '{print \$3}')
UNIT=$(echo "$LINE" | awk '{print \$4}')

# 如果单位是 MiB，则转换为 GiB
if [[ "$UNIT" == "MiB" ]]; then
    # 修正：确保 awk 仅处理数字部分
    RX=$(echo "\$RX" | awk '{printf "%.2f", \$1 / 1024}')
fi
# 将流量使用量转换为整数以便比较
USAGE_INT=$(printf "%.0f" "\$RX")

# 判断是否达到限速阈值
if (( USAGE_INT >= LIMIT_GB )); then
    PCT=\$\$(( USAGE_INT * 100 / LIMIT_GB ))
    echo "[限速] \${USAGE_INT}GiB(\${PCT}%) → 开始限速"
    # 删除旧的限速规则（如果存在）
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
    # 添加新的限速规则
    tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
    PCT=\$\$(( USAGE_INT * 100 / LIMIT_GB ))
    echo "[正常] \${USAGE_INT}GiB(\${PCT}%)"
    # 如果未限速，确保没有限速规则
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
fi

# 记录上次运行时间
date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

echo "📝 [4/6] 生成解除限速脚本..."
# 生成解除限速脚本
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
tc qdisc del dev "\$IFACE" root 2>/dev/null || true # 删除所有限速规则
EOL
chmod +x /root/clear_limit.sh

echo "📅 [5/6] 写入 cron 任务..."
# 清理旧的 cron 任务，并添加新的任务
crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' > /tmp/crontab.bak || true
# 每小时运行限速检查
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
# 每日午夜解除限速，并更新 vnStat 数据库
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i \$IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

echo "📡 [附加] 生成测速脚本..."
# 生成测速脚本
cat > /root/speed_test.sh <<EOF
#!/bin/bash
echo "🌐 正在测速..."
speedtest --simple # 执行 speedtest 简单模式
EOF
chmod +x /root/speed_test.sh

echo "🧩 [6/6] 生成交互命令 ce..."
# 生成交互式控制台命令
cat > /usr/local/bin/ce <<'EOF'
#!/bin/bash
# 定义颜色代码
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; RESET='\033[0m'

CONFIG_FILE=/etc/limit_config.conf
source "$CONFIG_FILE" # 加载配置
VERSION=$(grep '^VERSION=' /root/install_limit.sh | cut -d'"' -f2) # 从安装脚本获取版本
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1) # 获取网卡名称

while true; do
    DATE=$(date '+%Y-%m-%d')
    OS_INFO=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "未知系统")
    IP4=$(curl -s ifconfig.me || echo "未知") # 获取公网 IP
    LAST_RUN=$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A") # 获取上次限速检测时间

    LINE=$(vnstat -d -i "$IFACE" | grep "$DATE")
    if [[ -z "$LINE" ]]; then
        RX_GB=0; TX_GB=0 # 如果今天没有流量数据，则设置为 0
    else
        RX=$(echo "$LINE" | awk '{print $3}')
        RX_UNIT=$(echo "$LINE" | awk '{print $4}')
        TX=$(echo "$LINE" | awk '{print $5}')
        TX_UNIT=$(echo "$LINE" | awk '{print $6}')

        RX_GB=$RX  
        TX_GB=$TX  
        # 修正：确保 awk 仅处理数字部分进行 MiB 到 GiB 的转换
        [[ "$RX_UNIT" == "MiB" ]] && RX_GB=$(echo "$RX" | awk '{printf "%.2f", $1/1024}')  
        [[ "$TX_UNIT" == "MiB" ]] && TX_GB=$(echo "$TX" | awk '{printf "%.2f", $1/1024}')

    fi

    UP_STR="上行: ${TX_GB:-0} GiB"
    DOWN_STR="下行: ${RX_GB:-0} GiB"
    PCT=$(awk -v u="$RX_GB" -v l="$LIMIT_GB" 'BEGIN{printf "%.1f", u/l*100}') # 计算已用百分比

    TC_OUT=$(tc qdisc show dev "$IFACE" 2>/dev/null) # 获取限速状态
    if echo "$TC_OUT" | grep -q "tbf"; then
        LIMIT_STATE="✅ 正在限速"
        CUR_RATE=$(echo "$TC_OUT" | grep -oP 'rate \K\S+') # 提取当前限速速率
    else
        LIMIT_STATE="🆗 未限速"
        CUR_RATE="-"
    fi

    clear # 清屏
    echo -e "${CYAN}╔════════════════════════════════════════════════╗"
    echo -e "║        🚦 流量限速管理控制台（ce） v${VERSION}        ║"
    echo -e "╚════════════════════════════════════════════════╝${RESET}"
    echo -e "${YELLOW}📅 日期：${DATE}    🖥 系统：${OS_INFO}${RESET}"
    echo -e "${YELLOW}🌐 网卡：${IFACE}    公网 IP：${IP4}${RESET}"
    echo -e "${GREEN}📊 今日流量：${UP_STR} / ${DOWN_STR}${RESET}"
    echo -e "${GREEN}📈 已用：${RX_GB} GiB / ${LIMIT_GB} GiB (${PCT}%)${RESET}"
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
        1) /root/limit_bandwidth.sh ;;  # 检查是否应限速
        2) /root/clear_limit.sh ;;      # 手动解除限速
        3) tc -s qdisc ls dev "$IFACE" ;; # 查看限速状态详情
        4) vnstat -d ;;                 # 查看每日流量详情
        5) # 删除所有脚本和命令
            rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh
            rm -f /usr/local/bin/ce
            # 清除 cron 任务中与本脚本相关的行
            (crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh') | crontab -
            echo -e "${YELLOW}已删除所有相关脚本和配置。${RESET}"
            break ;;
        6) # 修改限速配置
            echo -e "
当前配置：${LIMIT_GB}GiB，${LIMIT_RATE}"
            read -p "🔧 输入新的每日流量限制（GiB，仅数字）: " ngb
            read -p "🚀 输入新的限速速率（例如 512kbit, 1mbit）: " nrt
            # 验证输入格式
            if [[ "$ngb" =~ ^[0-9]+$ ]] && [[ "$nrt" =~ ^[0-9]+(kbit|mbit)$ ]]; then
                echo "LIMIT_GB=$ngb" > "$CONFIG_FILE"
                echo "LIMIT_RATE=$nrt" >> "$CONFIG_FILE"
                # 重新加载配置以使更改立即生效
                source "$CONFIG_FILE" 
                echo -e "${GREEN}配置已更新。${RESET}"
            else
                echo -e "${RED}输入无效。请确保流量是数字，速率格式正确（如 512kbit）。${RESET}"
            fi
            ;;  
        7) break ;; # 退出
        8) /root/install_limit.sh --update ;; # 检查更新
        9) /root/speed_test.sh ;; # 网络测速
        *) echo -e "${RED}输入无效，请选择 1-9 的数字。${RESET}" ;;
    esac
    read -p "⏎ 按回车键继续..." dummy # 等待用户按键
done
EOF

chmod +x /usr/local/bin/ce

echo "🎉 安装完成！现在您可以使用 'ce' 命令管理流量限速。"

