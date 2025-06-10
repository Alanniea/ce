#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.6"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE="/etc/limit_config.conf"
mkdir -p /etc

DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====== 自动保存自身 ======
if [[ "${BASH_SOURCE[0]}" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
  echo "💾 正在保存 install_limit.sh 到 $SCRIPT_PATH..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "✅ 已保存"
fi

# ====== 自动更新函数 ======
check_update() {
  echo "📡 正在检查更新..."
  LATEST=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
           | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
  if [[ "$LATEST" != "$VERSION" ]]; then
    echo "🆕 发现新版本: $LATEST，当前版本: $VERSION"
    read -p "是否立即更新？[Y/n] " choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "✅ 更新完成，请执行 $SCRIPT_PATH 重新安装"
    else
      echo "🚫 已取消"
    fi
  else
    echo "✅ 已是最新（$VERSION）"
  fi
}

# ====== 确认 vnstat 初始化参数 ======
if vnstat --help 2>&1 | grep -q -- '--create'; then
  VNSTAT_CREATE_OPT='--create'
elif vnstat --help 2>&1 | grep -q -E '^-u'; then
  VNSTAT_CREATE_OPT='-u'
else
  echo "⚠️ 无法找到 vnstat 初始化标志，请手动初始化数据库" >&2
  VNSTAT_CREATE_OPT=''
fi

# ====== 支持 --update 参数 ======
if [[ "$1" == "--update" ]]; then
  check_update
  exit 0
fi

# ====== 初始化配置 ======
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<-'EOC'
LIMIT_GB=20
LIMIT_RATE="512kbit"
EOC
fi
source "$CONFIG_FILE"

echo "🛠 [0/6] 检测系统与网卡..."
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_NAME=$ID
  OS_VER=$VERSION_ID
else
  OS_NAME=$(uname -s)
  OS_VER=$(uname -r)
fi
 echo "系统：$OS_NAME $OS_VER"

# 自动选取主用网卡
IFACE=$(ip -o link show | awk -F': ' '{print $2}' \
         | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' \
         | head -n1)
if [[ -z "$IFACE" ]]; then
  echo "⚠️ 未检测到网卡，请手动设置 IFACE" >&2
  exit 1
fi
 echo "主用网卡：$IFACE"

echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null; then
  apt update -y && apt install -y vnstat iproute2 curl speedtest-cli
elif command -v yum >/dev/null; then
  yum install -y epel-release && yum install -y vnstat iproute curl speedtest-cli
else
  echo "⚠️ 未知包管理器，请手动安装: vnstat, iproute/iproute2, curl, speedtest-cli" >&2
fi

echo "✅ [2/6] 初始化 vnStat..."
if [[ -n "$VNSTAT_CREATE_OPT" ]]; then
  vnstat $VNSTAT_CREATE_OPT -i "$IFACE" || true
fi
systemctl enable vnstat
systemctl restart vnstat

echo "📝 [3/6] 生成限速脚本..."
cat > /root/limit_bandwidth.sh <<-'EOL'
#!/bin/bash
set -e
IFACE=""${IFACE}""
source /etc/limit_config.conf

# 获取今日下行流量 (GiB)
LINE=$(vnstat -d -i "$IFACE" | grep "$(date '+%Y-%m-%d')")
if [[ -z "$LINE" ]]; then
  RX_GB=0
else
  read -r _ _ RX UNIT <<< "$LINE"
  case "$UNIT" in
    KiB) RX_GB=$(awk "BEGIN{print $RX/1024/1024}") ;;
    MiB) RX_GB=$(awk "BEGIN{print $RX/1024}") ;;
    GiB) RX_GB=$RX ;;
    TiB) RX_GB=$(awk "BEGIN{print $RX*1024}") ;;
    *) RX_GB=0 ;;
  esac
fi
PCT=$(awk "BEGIN{printf \"%d\", ($RX_GB/$LIMIT_GB)*100}")

if (( $(awk "BEGIN{print ($RX_GB>=$LIMIT_GB)}") )); then
  echo "[限速] ${RX_GB}GiB (${PCT}%) → 开始限速"
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc add dev "$IFACE" root tbf rate "$LIMIT_RATE" burst 32kbit latency 400ms
else
  echo "[正常] ${RX_GB}GiB (${PCT}%)"
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
fi

date '+%F %T' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

echo "📝 [4/6] 生成解除限速脚本..."
cat > /root/clear_limit.sh <<-'EOL'
#!/bin/bash
set -e
IFACE=""${IFACE}""
# 删除限速规则
tc qdisc del dev "$IFACE" root 2>/dev/null || true
EOL
chmod +x /root/clear_limit.sh

echo "📅 [5/6] 写入 cron 任务..."
# 备份旧任务并添加新任务
(crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh|speed_test.sh'; \
 echo "0 * * * * /root/limit_bandwidth.sh"; \
 echo "0 0 * * * /root/clear_limit.sh && vnstat $VNSTAT_CREATE_OPT -i $IFACE && vnstat --update") | crontab -

echo "📡 [6/6] 生成测速脚本..."
cat > /root/speed_test.sh <<-'EOF'
#!/bin/bash
set -e
echo "🌐 正在测速..."
speedtest-cli --simple
echo "🔄 更新 vnStat 数据库..."
vnstat --update
EOF
chmod +x /root/speed_test.sh

echo "🎉 安装完成！现在可以使用命令：ce 或 ce --update 来管理限速系统。"
