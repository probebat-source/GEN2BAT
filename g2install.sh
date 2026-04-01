#!/bin/bash

# --- Configuration Paths ---
AGENT_BIN="/usr/local/bin/g2agent"
CONFIG_FILE="/etc/g2agent.conf"
SVC_FILE="/etc/systemd/system/g2agent.service"
TMR_FILE="/etc/systemd/system/g2agent.timer"

echo "=========================================="
echo "      G2 Probe Agent Setup Manager        "
echo "=========================================="

# --- Core Functions ---

optimize_wifi() {
    echo "Optimizing Raspberry Pi WiFi stability..."
    sudo iw dev wlan0 set power_save off 2>/dev/null || true
    if ! grep -q "iw dev wlan0 set power_save off" /etc/rc.local 2>/dev/null; then
        sudo sed -i -e '$i \/sbin/iw dev wlan0 set power_save off\n' /etc/rc.local 2>/dev/null || true
    fi
}

install_dependencies() {
    echo "Installing required dependencies (jq, curl)..."
    sudo apt-get update -qq && sudo apt-get install -y jq curl > /dev/null
}

generate_agent() {
    echo "Writing resilient agent script to $AGENT_BIN..."
    sudo bash -c "cat > $AGENT_BIN" << 'EOF'
#!/bin/bash

CONFIG_FILE="/etc/g2agent.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    exit 1
fi

N8N_WEBHOOK_URL="https://nscl.tailc52c94.ts.net/webhook/ps1"

for entry in "${TARGETS[@]}"; do
    MONITOR_NAME="${entry%%|*}"
    TARGET="${entry#*|}"

    PING_STATUS="n/a"
    PING_LATENCY=0
    HTTP_STATUS="n/a"
    HTTP_LATENCY=0

    if [[ "$TARGET" == http* ]]; then
        # NATIVE HTTP CHECK
        HTTP_RESULT=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}" --connect-timeout 3 -m 5 --retry 1 "$TARGET")
        HTTP_CODE="${HTTP_RESULT%|*}"
        HTTP_TIME_SEC="${HTTP_RESULT#*|}"

        if [[ "$HTTP_CODE" =~ ^[23] ]]; then
            HTTP_STATUS="up"
            HTTP_LATENCY=$(awk "BEGIN {print int($HTTP_TIME_SEC * 1000)}")
            [[ -z "$HTTP_LATENCY" ]] && HTTP_LATENCY=0
        else
            HTTP_STATUS="down"
        fi
    else
        # NATIVE PING CHECK: 3 packets, 0.2s apart.
        PING_RESULT=$(ping -c 3 -i 0.2 -W 2 "$TARGET" 2>/dev/null)
        if [ $? -eq 0 ]; then
            PING_STATUS="up"
            PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.')
            [[ -z "$PING_LATENCY" ]] && PING_LATENCY=0
        else
            PING_STATUS="down"
        fi
    fi

    PAYLOAD=$(jq -n \
      --arg sid "$SERVER_ID" \
      --arg mon "$MONITOR_NAME" \
      --arg tar "$TARGET" \
      --arg p_sta "$PING_STATUS" \
      --argjson p_lat "${PING_LATENCY:-0}" \
      --arg h_sta "$HTTP_STATUS" \
      --argjson h_lat "${HTTP_LATENCY:-0}" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        server_id: $sid,
        monitor: $mon,
        target: $tar,
        ping_status: $p_sta,
        ping_latency_ms: $p_lat,
        http_status: $h_sta,
        http_latency_ms: $h_lat,
        timestamp: $ts
      }')

    # WEBHOOK DELIVERY
    curl -X POST "$N8N_WEBHOOK_URL" -H "Content-Type: application/json" -d "$PAYLOAD" --connect-timeout 5 --max-time 10 --retry 2 -s -o /dev/null
    
    sleep 1 
done
EOF
    sudo chmod +x "$AGENT_BIN"
}

setup_systemd() {
    echo "Configuring systemd service and timer..."
    
    # Extract interval from config, default to 1 if missing
    local timer_interval="1"
    if grep -q "^INTERVAL=" "$CONFIG_FILE" 2>/dev/null; then
        timer_interval=$(grep "^INTERVAL=" "$CONFIG_FILE" | cut -d'"' -f2)
    fi
    # Fallback to 1 if empty
    timer_interval=${timer_interval:-1}

    sudo bash -c "cat > $SVC_FILE" << EOF
[Unit]
Description=G2 Probe Network Agent
After=network.target

[Service]
Type=oneshot
ExecStart=$AGENT_BIN
EOF

    # Dynamically generate timer interval (*:0/5 means every 5 minutes)
    sudo bash -c "cat > $TMR_FILE" << EOF
[Unit]
Description=Run G2 Probe Agent every $timer_interval minute(s)

[Timer]
OnCalendar=*:0/$timer_interval
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable g2agent.timer >/dev/null 2>&1
    sudo systemctl restart g2agent.timer
    
    # Clean up old cron if it exists
    (crontab -l 2>/dev/null | grep -v "$AGENT_BIN") | crontab - 2>/dev/null
}

do_uninstall() {
    echo "Stopping and disabling services..."
    sudo systemctl stop g2agent.timer g2agent.service 2>/dev/null
    sudo systemctl disable g2agent.timer 2>/dev/null
    
    echo "Removing files..."
    sudo rm -f "$SVC_FILE" "$TMR_FILE" "$AGENT_BIN" "$CONFIG_FILE"
    sudo systemctl daemon-reload
    
    echo " [✓] G2 Probe Agent has been completely uninstalled."
}

# --- Main Logic ---

if [ -f "$AGENT_BIN" ] && [ -f "$CONFIG_FILE" ]; then
    echo " [!] Existing installation detected."
    echo ""
    echo " Please select an option:"
    echo "   1) Manage Monitors & Interval (Edit Config)"
    echo "   2) Repair/Update Installation"
    echo "   3) Uninstall Completely"
    echo "   4) Cancel"
    echo ""
    read -p " Choice [1-4]: " menu_choice
    
    case $menu_choice in
        1)
            echo "Opening configuration file. Press Ctrl+X, then Y, then Enter to save."
            sleep 2
            sudo nano "$CONFIG_FILE"
            echo "Applying changes and restarting services..."
            # Re-run systemd setup to apply any interval changes made in the config file
            setup_systemd
            echo " [✓] Configuration updated."
            exit 0
            ;;
        2)
            echo "------------------------------------------"
            echo "Repairing installation (Config will be kept)..."
            optimize_wifi
            install_dependencies
            generate_agent
            setup_systemd
            echo " [✓] Repair complete."
            exit 0
            ;;
        3)
            echo "------------------------------------------"
            read -p "Are you sure you want to uninstall? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                do_uninstall
            else
                echo "Uninstall aborted."
            fi
            exit 0
            ;;
        *)
            echo "Canceled."
            exit 0
            ;;
    esac
fi

# --- Initial Fresh Installation ---
echo " Starting fresh installation..."

read -p "Site name [BDXX00]: " input_site
SITE_NAME=${input_site:-BDXX00}

# Ask for Interval
read -p "Check Interval in minutes (1, 2, 5, 10) [1]: " input_interval
INTERVAL=${input_interval:-1}
if [[ ! "$INTERVAL" =~ ^(1|2|5|10)$ ]]; then
    echo " Invalid interval selected. Defaulting to 1 minute."
    INTERVAL=1
fi

TARGETS_BLOCK=""
while true; do
    echo "------------------------------------------"
    read -p "Monitor name [${SITE_NAME}-PING]: " input_monitor
    MONITOR_NAME=${input_monitor:-${SITE_NAME}-PING}

    read -p "Target (IP or URL): " input_target
    while [[ -z "$input_target" ]]; do
        read -p " Target cannot be empty. Target: " input_target
    done
    TARGET=$input_target
    
    TARGETS_BLOCK+="    \"${MONITOR_NAME}|${TARGET}\"\n"
    
    echo ""
    read -p "Add another target? (y/N): " add_more
    if [[ ! "$add_more" =~ ^[Yy]$ ]]; then
        break
    fi
done

echo "------------------------------------------"
echo "Creating configuration at $CONFIG_FILE..."
sudo bash -c "cat > $CONFIG_FILE" << EOF
# G2 Probe Agent Configuration
SERVER_ID="${SITE_NAME}"
INTERVAL="${INTERVAL}"
TARGETS=(
$(echo -e "$TARGETS_BLOCK")
)
EOF

optimize_wifi
install_dependencies
generate_agent
setup_systemd

echo "=========================================="
echo " Installation complete!"
echo " The agent is running every $INTERVAL minute(s)."
echo " To check status: sudo systemctl status g2agent.timer"
echo "=========================================="
