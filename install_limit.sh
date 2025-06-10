#!/bin/bash

umask 022
set -e

VERSION="1.0.5"
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE="/root/limit_config.conf"

# 默认配置
IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
LIMIT_GB=20
LIMIT_RATE="512kbit"

# 自动保存并重启自身
if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
  echo "💾 正在保存 install_limit.sh 到 $SCRIPT_PATH..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "✅ 已保存，正在重新执行脚本..."
  exec "$SCRIPT_PATH" "$@"
fi

# 保存配置
save_config() {
  cat > "$CONFIG_FILE" <<EOF
IFACE="$IFACE"
LIMIT_GB=$LIMIT_GB
LIMIT_RATE="$LIMIT_RATE"
EOF
}

# 读取配置
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
}

# 安装依赖
install_dependencies() {
  echo "🛠 安装依赖..."
  apt update -y && apt install -y vnstat iproute2 curl jq
  if command -v systemctl >/dev/null; then
    systemctl enable vnstat
    systemctl restart vnstat
  else
    service vnstat restart || true
  fi
}

# 限速逻辑
limit_bandwidth() {
  echo "🚦 开始限速检测..."
  TODAY=$(date +"%Y-%m-%d")
  RX=$(vnstat --json | jq -r ".interfaces[] | select(.name==\"$IFACE\") | .traffic.day[] | select(.date==\"$TODAY\") | .rx")
  TX=$(vnstat --json | jq -r ".interfaces[] | select(.name==\"$IFACE\") | .traffic.day[] | select(.date==\"$TODAY\") | .tx")

  USED_MB=$((RX + TX))
  USED_GB=$(awk 'BEGIN {printf "%.2f", val/1024/1024}' val="$USED_MB")

  echo "📊 今日已用流量：$USED_GB GiB / 限额 ${LIMIT_GB}GiB"

  if (( $(echo "$USED_GB >= $LIMIT_GB" | bc -l) )); then
    echo "🚫 超出流量，限制速率为 $LIMIT_RATE"
    tc qdisc replace dev "$IFACE" root tbf rate "$LIMIT_RATE" burst 32kbit latency 400ms
  else
    echo "✅ 流量未超限，清除限速..."
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
  fi
}

# 清除限速
clear_limit() {
  echo "🧹 清除限速规则..."
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  echo "✅ 已清除"
}

# 添加定时任务
add_cron_jobs() {
  (crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh';
   echo "*/5 * * * * bash /root/limit_bandwidth.sh") | crontab -
  (crontab -l 2>/dev/null | grep -v 'clear_limit.sh$';
   echo "59 23 * * * bash /root/clear_limit.sh") | crontab -
  echo "⏰ 定时任务已添加：每5分钟检查限速，23:59 清除限速"
}

# 控制台命令
create_console_entry() {
  cat > /usr/local/bin/ce <<EOF
#!/bin/bash
load_config() {
  source "$CONFIG_FILE"
}
load_config
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'
echo -e "\${GREEN}流量限速管理控制台 v$VERSION\${RESET}"
echo -e "\${YELLOW}当前网卡：\$IFACE  限额：\$LIMIT_GB GiB  限速：\$LIMIT_RATE\${RESET}"
echo "----------------------------------"
echo -e "\${GREEN}0.\${RESET} 查看当前配置"
echo -e "\${GREEN}1.\${RESET} 手动检查限速"
echo -e "\${GREEN}2.\${RESET} 清除限速"
echo -e "\${GREEN}3.\${RESET} 运行测速脚本"
echo -e "\${GREEN}4.\${RESET} 检查版本并更新"
echo -e "\${GREEN}5.\${RESET} 退出"
echo -n "请输入选项 [0-5]: "
read opt
case "\$opt" in
  0)
    echo -e "\${YELLOW}当前配置：\${RESET}"
    cat "$CONFIG_FILE"
    ;;
  1)
    bash /root/limit_bandwidth.sh
    ;;
  2)
    bash /root/clear_limit.sh
    ;;
  3)
    bash /root/speed_test.sh
    ;;
  4)
    bash "$SCRIPT_PATH" --update
    ;;
  *)
    echo "Bye!"
    ;;
esac
EOF
  chmod +x /usr/local/bin/ce
}

# 下载运行脚本
generate_runtime_scripts() {
  cat > /root/limit_bandwidth.sh <<EOF
#!/bin/bash
source "$CONFIG_FILE"
$(declare -f limit_bandwidth)
limit_bandwidth
EOF

  cat > /root/clear_limit.sh <<EOF
#!/bin/bash
source "$CONFIG_FILE"
$(declare -f clear_limit)
clear_limit
EOF

  cat > /root/speed_test.sh <<EOF
#!/bin/bash
apt install -y curl jq >/dev/null
curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -
EOF

  chmod +x /root/*.sh
}

# 检查更新
check_for_update() {
  LATEST_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d '"' -f2)
  if [[ "$LATEST_VERSION" != "$VERSION" ]]; then
    echo "🔄 有新版本：$LATEST_VERSION，正在更新..."
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ 更新完成，重启中..."
    exec "$SCRIPT_PATH"
  else
    echo "✅ 当前已是最新版本 ($VERSION)"
  fi
}

# 主入口
main() {
  if [[ "$1" == "--update" ]]; then
    check_for_update
    exit
  fi

  load_config
  install_dependencies
  save_config
  generate_runtime_scripts
  add_cron_jobs
  create_console_entry

  echo -e "\n🎉 脚本安装完成，可使用命令 \033[1;32mce\033[0m 启动控制台"
  bash /root/limit_bandwidth.sh
}

main "$@"
