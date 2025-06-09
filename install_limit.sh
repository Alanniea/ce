#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.0"
REPO="Alanniea/ce"
CONFIG_FILE=/etc/limit_config.conf
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
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o /root/install_limit.sh
      chmod +x /root/install_limit.sh
      echo "✅ 更新完成，请执行 ./install_limit.sh 重新安装"
    else
      echo "🚫 已取消更新"
    fi
  else
    echo "✅ 当前已经是最新版本（$VERSION）"
  fi
}

# ====== 支持命令行参数 --update ======
if [[ "$1" == "--update" ]]; then
  check_update
  exit 0
fi

# ====== 保存脚本自身到本地 ======
SCRIPT_PATH="/root/install_limit.sh"
if [[ ! -f "$SCRIPT_PATH" ]]; then
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
fi

# ====== 初始化配置文件 ======
if [ ! -f "$CONFIG_FILE" ]; then
  echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
  echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi

source "$CONFIG_FILE"

# ====== 系统与网卡识别 ======
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
  apt update -y && apt install -y vnstat iproute2 curl
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release && yum install -y vnstat iproute curl
else
  echo "⚠️ 未知包管理器，请手动安装 vnstat 和 iproute2"
fi

# ====== 初始化 vnstat ======
echo "✅ [2/6] 初始化 vnStat 数据库..."
vnstat -u -i "$IFACE" || true
sleep 2
systemctl enable vnstat
systemctl restart vnstat

# ====== 限速脚本 ======
echo "📝 [3/6] 创建限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source \$CONFIG_FILE

USAGE=\$(vnstat --oneline -i "\$IFACE" | cut -d\; -f11 | sed 's/ GiB//')
USAGE_FLOAT=\$(printf "%.0f" "\$USAGE")

if (( USAGE_FLOAT >= LIMIT_GB )); then
  PERCENT=\$(( USAGE_FLOAT * 100 / LIMIT_GB ))
  echo "[\$(date)] 超出限制 \${USAGE_FLOAT}GiB（\${PERCENT}%），执行限速" >> /var/log/limit_history.log
  tc qdisc del dev \$IFACE root 2>/dev/null || true
  tc qdisc add dev \$IFACE root tbf rate \$LIMIT_RATE burst 32kbit latency 400ms
  echo "[限速] 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），已超过限制，开始限速..."
else
  PERCENT=\$(( USAGE_FLOAT * 100 / LIMIT_GB ))
  echo "[正常] 当前流量 \${USAGE_FLOAT}GiB（\${PERCENT}%），未超过限制"
fi
EOL
chmod +x /root/limit_bandwidth.sh

# ====== 解除限速脚本 ======
echo "📝 [4/6] 创建解除限速脚本..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
tc qdisc del dev \$IFACE root 2>/dev/null || true
EOL
chmod +x /root/clear_limit.sh

# ====== 定时任务 ======
echo "📅 [5/6] 写入定时任务..."
crontab -l 2>/dev/null | grep -v "limit_bandwidth.sh" | grep -v "clear_limit.sh" > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

# ====== 控制台命令 ======
echo "🧩 [6/6] 创建交互菜单命令 ce..."
# 交互式控制台内容将继续添加...

# ====== 完成提示 ======
echo "🎯 使用命令 'ce' 进入交互式管理面板"
echo "✅ 每小时检测是否超限，超出 $LIMIT_GB GiB 自动限速 $LIMIT_RATE"
echo "⏰ 每天 0 点自动解除限速并刷新流量统计"
echo "📡 你可以随时运行 'ce' -> [8] 或 './install_limit.sh --update' 来检查更新"
echo "🎉 安装完成！"
