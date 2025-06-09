#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.0"
REPO="Alanniea/ce"
CONFIG_FILE=/etc/limit_config.conf
SCRIPT_PATH="/root/install_limit.sh"
mkdir -p /etc

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====== 自动更新函数 ======
check_update() {
  echo "📡 正在检查更新..."
  LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
  if [[ "$LATEST" != "$VERSION" ]]; then
    echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
    read -p "是否立即更新 install_limit.sh？[Y/n] " choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "✅ 更新完成，请执行 ./install_limit.sh 重新安装"
    else
      echo "🚫 已取消更新"
    fi
  else
    echo "✅ 当前已经是最新版本（$VERSION）"
  fi
}

if [[ "$1" == "--update" ]]; then
  check_update
  exit 0
fi

# ====== 自我保存 ======
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "💾 正在保存 install_limit.sh 到本地..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
fi

# ====== 初始化配置文件 ======
if [ ! -f "$CONFIG_FILE" ]; then
  echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
  echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi

source "$CONFIG_FILE"

# ====== 自动识别系统和网卡 ======
echo "🛠 [0/6] 自动识别系统和网卡..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME=$ID
  OS_VER=$VERSION_ID
else
  OS_NAME=$(uname -s)
  OS_VER=$(uname -r)
fi
echo "检测到系统：$OS_NAME $OS_VER"

IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n 1)
if [ -z "$IFACE" ]; then
  echo "⚠️ 未检测到有效网卡，请手动设置 IFACE 变量"
  exit 1
fi
echo "检测到主用网卡：$IFACE"

# ====== 安装依赖 ======
echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null 2>&1; then
  apt update -y && apt install -y vnstat iproute2 curl jq
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release && yum install -y vnstat iproute curl jq
else
  echo "⚠️ 未知包管理器，请手动安装 vnstat、iproute2、jq"
fi

# ====== 初始化 vnstat ======
echo "✅ [2/6] 初始化 vnStat 数据库..."
vnstat -u -i "$IFACE" || true
sleep 2
systemctl enable vnstat
systemctl restart vnstat

# ====== 创建限速脚本 ======
echo "📝 [3/6] 创建限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
set -e
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source \$CONFIG_FILE

USAGE=\$(vnstat --oneline -i "\$IFACE" | cut -d\; -f11 | sed 's/ GiB//')
USAGE_FLOAT=\$(printf "%.0f" "\$USAGE")

if (( USAGE_FLOAT >= LIMIT_GB )); then
  PERCENT=\$(( USAGE_FLOAT * 100 / LIMIT_GB ))
  echo "[限速] 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），已超过限制，开始限速..."
  tc qdisc del dev \$IFACE root 2>/dev/null || true
  tc qdisc add dev \$IFACE root tbf rate \$LIMIT_RATE burst 32kbit latency 400ms
else
  PERCENT=\$(( USAGE_FLOAT * 100 / LIMIT_GB ))
  echo "[正常] 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），未超过限制"
fi
EOL
chmod +x /root/limit_bandwidth.sh

# ====== 创建解除限速脚本 ======
echo "📝 [4/6] 创建解除限速脚本..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
tc qdisc del dev $IFACE root 2>/dev/null || true
EOL
chmod +x /root/clear_limit.sh

# ====== 添加定时任务 ======
echo "📅 [5/6] 写入定时任务..."
crontab -l 2>/dev/null | grep -v "limit_bandwidth.sh" | grep -v "clear_limit.sh" > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

# ====== 创建交互命令 ce ======
echo "🧩 [6/6] 创建交互菜单命令 ce..."
cat > /usr/local/bin/ce <<'EOL'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

CONFIG_FILE=/etc/limit_config.conf
source $CONFIG_FILE
VERSION=$(grep '^VERSION=' /root/install_limit.sh | cut -d'"' -f2)
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n 1)

get_usage_info() {
  RAW=$(vnstat --oneline -i "$IFACE" 2>/dev/null | cut -d\; -f11 | sed 's/ GiB//')
  USAGE=$(printf "%.1f" "$RAW")
  USAGE_PERCENT=$(awk -v u="$RAW" -v l="$LIMIT_GB" 'BEGIN { printf "%.1f", (u / l) * 100 }')
  echo "$USAGE" "$USAGE_PERCENT"
}

get_today_traffic() {
  vnstat -i "$IFACE" --json | jq -r '.interfaces[0].traffic.day[-1] | "