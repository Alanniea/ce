#!/bin/bash
# A script to limit bandwidth after exceeding a daily traffic quota.
set -e

# ====================
# Basic Information
# ====================
VERSION="1.0.6" # Updated version with fixes
REPO="Alanniea/ce"
SCRIPT_PATH="/root/install_limit.sh"
CONFIG_FILE="/etc/limit_config.conf"
LOG_FILE="/var/log/limit.log"
mkdir -p /etc

# Default values if config file doesn't exist
DEFAULT_GB=20
DEFAULT_RATE="512kbit"

# ====================
# Auto-save Self
# ====================
# Ensures the script is saved to a permanent location for future use.
if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
    echo "💾 Saving install_limit.sh to $SCRIPT_PATH..."
    # Using curl to fetch the latest version from the repository.
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ Saved successfully."
fi

# ====================
# Auto-update Function
# ====================
check_update() {
    echo "📡 Checking for updates..."
    # Fetch the version from the remote script.
    LATEST=$(curl -s "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ "$LATEST" != "$VERSION" ]]; then
        echo "🆕 New version found: $LATEST (current: $VERSION)"
        read -p "Do you want to update now? [Y/n] " choice
        if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
            curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install_limit.sh" -o "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo "✅ Update complete. Please run '$SCRIPT_PATH' again to reinstall."
        else
            echo "🚫 Update cancelled."
        fi
    else
        echo "✅ You are running the latest version ($VERSION)."
    fi
}

# ====================
# Support --update Parameter
# ====================
if [[ "$1" == "--update" ]]; then
    check_update
    exit 0
fi

# ====================
# Initialize Configuration
# ====================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "LIMIT_GB=$DEFAULT_GB" > "$CONFIG_FILE"
    echo "LIMIT_RATE=$DEFAULT_RATE" >> "$CONFIG_FILE"
fi
source "$CONFIG_FILE"

# ====================
# Main Installation
# ====================
echo "🛠️ [0/6] Detecting system and network interface..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VER=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VER=$(uname -r)
fi
echo "System: $OS_NAME $OS_VER"

# Auto-detect the primary network interface.
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)
if [ -z "$IFACE" ]; then
    echo "⚠️ Could not detect a network interface. Please set IFACE manually." >&2
    exit 1
fi
echo "Primary Interface: $IFACE"

echo "🛠️ [1/6] Installing dependencies..."
if command -v apt >/dev/null; then
    apt update -y && apt install -y vnstat iproute2 curl speedtest-cli
elif command -v yum >/dev/null; then
    yum install -y epel-release && yum install -y vnstat iproute curl speedtest-cli
else
    echo "⚠️ Unknown package manager. Please manually install: vnstat, iproute2, curl, speedtest-cli" >&2
fi

echo "✅ [2/6] Initializing vnStat..."
# The -u flag is versatile; it creates the database if it doesn't exist or updates it.
# This simplifies compatibility across different vnstat versions.
vnstat -u -i "$IFACE" || true
sleep 2
# Enable and start the vnstat service, with fallbacks for non-systemd systems.
systemctl enable vnstat --now 2>/dev/null || service vnstat restart 2>/dev/null || true

echo "📝 [3/6] Generating limiting script..."
cat > /root/limit_bandwidth.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
CONFIG_FILE=/etc/limit_config.conf
source "\$CONFIG_FILE"

# Get traffic for the current day
LINE=\$(vnstat -d -i "\$IFACE" | grep "\$(date '+%Y-%m-%d')")
RX=\$(echo "\$LINE" | awk '{print \$3}')
UNIT=\$(echo "\$LINE" | awk '{print \$4}')

# Convert all units to GiB for comparison
case "\$UNIT" in
    KiB) RX=\$(awk "BEGIN{printf \"%.6f\", \$RX/1024/1024}") ;;
    MiB) RX=\$(awk "BEGIN{printf \"%.6f\", \$RX/1024}") ;;
    GiB) RX=\$(awk "BEGIN{printf \"%.6f\", \$RX}") ;;
    TiB) RX=\$(awk "BEGIN{printf \"%.6f\", \$RX*1024}") ;;
    *)   RX=0 ;;
esac

USAGE=\$(awk "BEGIN{printf \"%.2f\", \$RX}")
PCT=\$(awk "BEGIN{printf \"%d\", (\$USAGE/\$LIMIT_GB)*100}")

# Check if usage exceeds the limit
if awk "BEGIN{exit !(\$USAGE >= \$LIMIT_GB)}"; then
    echo "[\$(date)] Limit reached: \${USAGE}GiB (\${PCT}%) -> Throttling enabled."
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
    tc qdisc add dev "\$IFACE" root tbf rate "\$LIMIT_RATE" burst 32kbit latency 400ms
else
    echo "[\$(date)] Status OK: \${USAGE}GiB (\${PCT}%)"
    # Ensure no limit is active if usage is below the threshold
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
fi

# Log the last run time
date '+%Y-%m-%d %H:%M:%S' > /var/log/limit_last_run
EOL
chmod +x /root/limit_bandwidth.sh

echo "📝 [4/6] Generating unlimiting script..."
cat > /root/clear_limit.sh <<EOL
#!/bin/bash
IFACE="$IFACE"
echo "Clearing any existing traffic limits..."
tc qdisc del dev "\$IFACE" root 2>/dev/null || true
echo "Limits cleared."
EOL
chmod +x /root/clear_limit.sh

echo "📅 [5/6] Setting up cron jobs..."
# Safely create or replace the crontab, adding logging for easier debugging.
(crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh|speed_test.sh') > /tmp/crontab.bak
echo "0 * * * * /root/limit_bandwidth.sh >> $LOG_FILE 2>&1" >> /tmp/crontab.bak
echo "0 0 * * * /root/clear_limit.sh && vnstat -u -i $IFACE" >> /tmp/crontab.bak
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

echo "📡 [Bonus] Generating speed test script..."
cat > /root/speed_test.sh <<EOL
#!/bin/bash
echo "🌐 Running speed test..."
speedtest --simple
echo "🔄 Updating vnStat database..."
# Force an update for the specific interface to reflect speed test traffic
vnstat -u -i "$IFACE"
EOL
chmod +x /root/speed_test.sh

echo "🧩 [6/6] Generating interactive command 'ce'..."
# This heredoc creates the main control script.
cat > /usr/local/bin/ce <<EOF
#!/bin/bash
if [[ "\$1" == "--update" ]]; then
    exec "$SCRIPT_PATH" --update
fi

# Color definitions
RED='\\033[0;31m'; GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'
CYAN='\\033[1;36m'; RESET='\\033[0m'

CONFIG_FILE="$CONFIG_FILE"
source "\$CONFIG_FILE"
VERSION=\$(grep '^VERSION=' "$SCRIPT_PATH" | cut -d'"' -f2)
IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -vE '^(lo|docker|br-|veth|tun|vmnet|virbr)' | head -n1)

# Function to convert different units to GiB
convert_to_gib() {
    local value="\$1"
    local unit="\$2"
    case "\$unit" in
        KiB) awk "BEGIN{printf \\"%.6f\\", \$value/1024/1024}" ;;
        MiB) awk "BEGIN{printf \\"%.6f\\", \$value/1024}" ;;
        GiB) awk "BEGIN{printf \\"%.6f\\", \$value}" ;;
        TiB) awk "BEGIN{printf \\"%.6f\\", \$value*1024}" ;;
        *)   echo "0" ;;
    esac
}

# Main loop for the interactive menu
while true; do
    # Fetch current data for display
    DATE=\$(date '+%Y-%m-%d')
    OS_INFO=\$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    IP4=\$(curl -s4 ifconfig.me || echo "Unknown")
    LAST_RUN=\$(cat /var/log/limit_last_run 2>/dev/null || echo "N/A")

    LINE=\$(vnstat -d -i "\$IFACE" | grep "\$DATE")
    if [[ -z "\$LINE" ]]; then
        RX_GB=0.00; TX_GB=0.00
    else
        RX=\$(echo "\$LINE" | awk '{print \$3}'); RX_UNIT=\$(echo "\$LINE" | awk '{print \$4}')
        TX=\$(echo "\$LINE" | awk '{print \$5}'); TX_UNIT=\$(echo "\$LINE" | awk '{print \$6}')
        RX_GB=\$(convert_to_gib "\$RX" "\$RX_UNIT")
        TX_GB=\$(convert_to_gib "\$TX" "\$TX_UNIT")
    fi

    RX_FMT=\$(awk "BEGIN{printf \\"%.2f\\", \$RX_GB}")
    TX_FMT=\$(awk "BEGIN{printf \\"%.2f\\", \$TX_GB}")
    PCT=\$(awk "BEGIN{printf \\"%.1f\\", \$RX_GB/\$LIMIT_GB*100}")

    # Check the current limit status with 'tc'
    TC_OUT=\$(tc qdisc show dev "\$IFACE")
    if echo "\$TC_OUT" | grep -q "tbf"; then
        LIMIT_STATE="\${GREEN}✅ Throttled\${RESET}"
        CUR_RATE=\$(echo "\$TC_OUT" | grep -oP 'rate \\K\\S+')
    else
        LIMIT_STATE="\${YELLOW}🆗 Normal\${RESET}"
        CUR_RATE="-"
    fi

    # Display the dashboard
    clear
    echo -e "\${CYAN}╔════════════════════════════════════════════════╗"
    echo -e "║ 🚦 Traffic Limit Console (ce) v\${VERSION}     ║"
    echo -e "╚════════════════════════════════════════════════╝\${RESET}"
    echo -e "\${YELLOW}📅 Date: \${DATE} 🖥️ System: \${OS_INFO}\${RESET}"
    echo -e "\${YELLOW}🌐 Interface: \${IFACE} Public IP: \${IP4}\${RESET}"
    echo -e "\${GREEN}📊 Today's Traffic: Upload \${TX_FMT} GiB / Download \${RX_FMT} GiB\${RESET}"
    echo -e "\${GREEN}📈 Usage: \${RX_FMT} GiB / \${LIMIT_GB} GiB (\${PCT}%)\${RESET}"
    echo -e "\${GREEN}🚦 Status: \${LIMIT_STATE} 🚀 Rate: \${CUR_RATE}\${RESET}"
    echo -e "\${GREEN}🕒 Last Check: \${LAST_RUN}\${RESET}"

    # Check for script updates in the background
    LATEST=\$(curl -s "https://raw.githubusercontent.com/\$REPO/main/install_limit.sh" | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    if [[ "\$LATEST" != "" && "\$LATEST" != "\$VERSION" ]]; then
        echo -e "\${RED}⚠️ New version available (\$LATEST). Run 'ce --update' to get it.\${RESET}"
    fi

    echo
    echo -e "\${GREEN}1.\${RESET} Force usage check"
    echo -e "\${GREEN}2.\${RESET} Manually remove limit"
    echo -e "\${GREEN}3.\${RESET} Show kernel limit status"
    echo -e "\${GREEN}4.\${RESET} Show daily traffic stats"
    echo -e "\${GREEN}5.\${RESET} Uninstall all scripts"
    echo -e "\${GREEN}6.\${RESET} Modify limit settings"
    echo -e "\${GREEN}7.\${RESET} Exit"
    echo -e "\${GREEN}8.\${RESET} Check for updates"
    echo -e "\${GREEN}9.\${RESET} Run network speed test"
    echo -e "\${GREEN}10.\${RESET} View cron log"
    echo
    read -p "👉 Choose an option [1-10]: " opt
    case "\$opt" in
        1) /root/limit_bandwidth.sh ;;
        2) /root/clear_limit.sh ;;
        3) tc -s qdisc ls dev "\$IFACE" ;;
        4) vnstat -d ;;
        5)
            read -p "Are you sure you want to remove everything? [y/N] " confirm
            if [[ "\$confirm" =~ ^[Yy]\$ ]]; then
                rm -f /root/install_limit.sh /root/limit_bandwidth.sh /root/clear_limit.sh /root/speed_test.sh
                rm -f /usr/local/bin/ce
                (crontab -l 2>/dev/null | grep -vE 'limit_bandwidth.sh|clear_limit.sh' | crontab -)
                echo -e "\${YELLOW}All scripts and cron jobs have been removed.\${RESET}"
                break
            fi
            ;;
        6)
            echo -e "\\nCurrent Config: Daily limit \${LIMIT_GB}GiB, Throttle rate \${LIMIT_RATE}"
            read -p "🔧 Enter new daily limit (GiB, e.g., 30): " ngb
            read -p "🚀 Enter new throttle rate (e.g., 512kbit or 1mbit): " nrt
            if [[ "\$ngb" =~ ^[0-9]+([.][0-9]+)?\$ ]] && [[ "\$nrt" =~ ^[0-9]+(kbit|mbit)\$ ]]; then
                echo "LIMIT_GB=\$ngb" > "\$CONFIG_FILE"
                echo "LIMIT_RATE=\$nrt" >> "\$CONFIG_FILE"
                source "\$CONFIG_FILE"
                echo -e "\${GREEN}Configuration updated!\${RESET}"
            else
                echo -e "\${RED}Invalid input. Check if the limit is a number and the rate is correct (e.g., 512kbit, 1mbit).\${RESET}"
            fi
            ;;
        7) break ;;
        8) "$SCRIPT_PATH" --update ;;
        9) /root/speed_test.sh ;;
        10) tail -n 20 "$LOG_FILE" ;;
        *) echo -e "\${RED}Invalid option, please try again.\${RESET}" ;;
    esac
    read -p "⏎ Press Enter to continue..." dummy
done
EOF

chmod +x /usr/local/bin/ce

echo -e "${GREEN}🎉 Installation complete! You can now use the 'ce' command to manage the traffic limiter.${RESET}"

