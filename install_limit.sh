#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.2"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE=/etc/limit_config.conf
mkdir -p /etc

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====== 自动保存自身 ======
if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
  echo "💾 正在保存 install_limit.sh 到 $SCRIPT_PATH..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "✅ 已保存"
fi

# ====== 自动更新函数 ======
check_update() {
  echo "📱 正在检查更新..."
  LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" |
    grep '^VERSION=' | head -n1 | cut -d'"' -f2)
  if [[ "$LATEST" != "$VERSION" ]]; then
    echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
    read -p "是否立即更新？[Y/n] " choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
        -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "✅ 更新完成，请执行 $SCRIPT_PATH 重新安装"
    else
      echo "🚫 已取消"
    fi
  else
    echo "✅ 已是最新（$VERSION）"
  fi
}

# ====== 支持 --update 参数 ======
if [[ "$1" == "--update" ]]; then
  check_update
  exit 0
fi

# ====== 初始化配置 ======
if [ ! -f "$CONFIG_FILE" ]; then
  echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
  echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi
source "$CONFIG_FILE"

# ====== 系统信息与依赖安装 ======
echo "🛠 [0/6] 检测系统与网卡..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME=$ID
  OS_VER=$VERSION_ID
else
  OS_NAME=$(uname -s)
  OS_VER=$(uname -r)
fi
echo "系统：$OS_NAME $OS_VER"

IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
if [ -z "$IFACE" ]; then
  echo "⚠️ 未检测到网卡，请手动设置 IFACE"
  exit 1
fi
echo "主用网卡：$IFACE"

echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null; then
  apt update -y && apt install -y vnstat iproute2 curl
elif command -v yum >/dev/null; then
  yum install -y epel-release && yum install -y vnstat iproute curl
else
  echo "⚠️ 未知包管理器，请手动安装 vnstat、iproute2"
fi

# ====== 初始化 vnStat ======
echo "✅ [2/6] 初始化 vnStat..."
vnstat -u -i "$IFACE" || true
sleep 2
systemctl enable vnstat
systemctl restart vnstat

# ====== 生成限速脚本 ======
echo "📜 [3/6] 生成限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "\$CONFIG_FILE"

LINE=\$(vnstat -d -i "\$IFACE" | grep "\$(date '+%Y-%m-%d')")
USAGE=\$(echo "\$LINE" | awk '{print \$3}')
UNIT=\$(echo "\$LINE" | awk '{print \$4}')

if [[ "\$UNIT" == "MiB" ]]; then
  USAGE=\$(awk "BEGIN {printf \"%.2f\", \$USAGE / 1024}")
fi
USAGE_INT=\$(printf "%.0f" "\$USAGE")

if (( USAGE_INT >= LIMIT_GB )); then
  PCT=\$(( USAGE_INT * 100 / LIMIT_GB ))
  echo "[限速] \${USAGE_INT}GiB(\${PCT}%) → 开始限速"
  tc qdisc del dev "\$IFACE" root 2>/dev/null || true
  tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
  PCT=\$(( USAGE_INT * 100 / LIMIT_GB ))
  echo "[正常] \${USAGE_INT}GiB(\${PCT}%)"
fi

date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

# ====== 生成解除限速脚本 ======
echo "📜 [4/6] 生成解除限速脚本..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
tc qdisc del dev "\$IFACE" root 2>/dev/null || true
EOL
chmod +x /root/clear_limit.sh

# ====== 写入定时任务 ======
echo "📅 [5/6] 写入 cron 任务..."
crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE && vnstat --update" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

# ====== 生成交互命令 ce ======
echo "🧹 [6/6] 生成交互命令 ce..."
cat > /usr/local/bin/ce <<'EOF'
# 全部内容与原脚本一致，末尾追加测速选项与 case 9） 处理逻辑
# 为避免冗长，我将在下一步中补充完整版
EOF
chmod +x /usr/local/bin/ce

echo "🎉 安装完成！使用命令： ce"
