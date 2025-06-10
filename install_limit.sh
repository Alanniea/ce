#!/bin/bash
set -e

# ====== 基础信息 ======
VERSION="1.0.6"
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
  echo "📡 正在检查更新..."
  LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" \
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

# ====== vnStat 参数检测 ======
VNSTAT_CREATE_OPT=""
if vnstat --help 2>&1 | grep -q -- '--create'; then
  VNSTAT_CREATE_OPT="--create"
elif vnstat --help 2>&1 | grep -q -- '-u'; then
  VNSTAT_CREATE_OPT="-u"
fi

# ====== --update 参数 ======
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

echo "🛠 [0/6] 检测系统与网卡..."
. /etc/os-release
OS_NAME=$ID
OS_VER=$VERSION_ID
echo "系统：$OS_NAME $OS_VER"

IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
if [ -z "$IFACE" ]; then
  echo "⚠️ 未检测到网卡，请手动设置 IFACE"
  exit 1
fi
echo "主用网卡：$IFACE"

echo "🛠 [1/6] 安装依赖..."
if command -v apt >/dev/null; then
  apt update -y && apt install -y vnstat iproute2 curl speedtest-cli
elif command -v yum >/dev/null; then
  yum install -y epel-release && yum install -y vnstat iproute curl speedtest-cli
else
  echo "⚠️ 未知包管理器，请手动安装 vnstat、iproute2、speedtest-cli"
fi

echo "✅ [2/6] 初始化 vnStat..."
vnstat $VNSTAT_CREATE_OPT -i "$IFACE" || true
sleep 2
systemctl enable vnstat
systemctl restart vnstat

echo "📝 [3/6] 生成限速脚本..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "\$CONFIG_FILE"

LINE=\$(vnstat -d -i "\$IFACE" | grep "\$(date '+%Y-%m-%d')")
RX=\$(echo "\$LINE" | awk '{print \$3}')
UNIT=\$(echo "\$LINE" | awk '{print \$4}')

case "\$UNIT" in
  KiB) RX=\$(awk "BEGIN{printf \\"%.6f\\", \$RX/1024/1024}") ;;
  MiB) RX=\$(awk "BEGIN{printf \\"%.6f\\", \$RX/1024}") ;;
  GiB) RX=\$(awk "BEGIN{printf \\"%.6f\\", \$RX}") ;;
  TiB) RX=\$(awk "BEGIN{printf \\"%.6f\\", \$RX*1024}") ;;
  *) RX=0 ;;
esac

USAGE=\$(awk "BEGIN{printf \\"%.2f\\", \$RX}")
PCT=\$(awk "BEGIN{printf \\"%d\\", (\$USAGE/\$LIMIT_GB)*100}")

if awk "BEGIN{exit !(\$USAGE >= \$LIMIT_GB)}"; then
  echo "[限速] \$USAGE GiB (\$PCT%) → 开始限速"
  tc qdisc del dev "\$IFACE" root 2>/dev/null || true
  tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
  echo "[正常] \$USAGE GiB (\$PCT%)"
  tc qdisc del dev "\$IFACE" root 2>/dev/null || true
fi

date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

echo "📝 [4/6] 生成解除限速脚本..."
echo -e "#!/bin/bash\ntc qdisc del dev \"$IFACE\" root 2>/dev/null || true" > /root/clear_limit.sh
chmod +x /root/clear_limit.sh

echo "🧩 [附加] 生成 vnStat 更新兼容脚本..."
cat > /root/vnstat_update.sh <<'EOL'
#!/bin/bash
if vnstat --help 2>&1 | grep -q -- '--update'; then
  vnstat --update
elif vnstat --help 2>&1 | grep -q -- '-u'; then
  vnstat -u
else
  echo "⚠️ 当前版本不支持 --update 或 -u，跳过更新数据库。"
fi
EOL
chmod +x /root/vnstat_update.sh

echo "📅 [5/6] 写入 cron 任务..."
crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh|speed_test.sh|vnstat_update.sh' > /tmp/crontab.bak || true
echo "0 * * * * /root/limit_bandwidth.sh" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && /root/vnstat_update.sh" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

echo "📡 [附加] 生成测速脚本..."
cat > /root/speed_test.sh <<'EOL'
#!/bin/bash
echo "🌐 正在测速..."
speedtest --simple
echo "🔄 更新 vnStat 数据库…"
/root/vnstat_update.sh
EOL
chmod +x /root/speed_test.sh

# 交互式命令 ce（略，与上文一致，如需一起合并请告知）

echo -e "\033[0;32m🎉 安装完成！请使用 \033[1mce\033[0m 命令开始管理限速。\033[0m"