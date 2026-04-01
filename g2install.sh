#!/bin/bash

# Configuration paths
AGENT_BIN="/usr/local/bin/g2agent"
CONFIG_FILE="/etc/g2agent.conf"

echo "=========================================="
echo "      G2 Probe Agent - Native Setup       "
echo "=========================================="

# --- 1. Interactive Prompts ---
read -p "Site name [BDXX00]: " input_site
SITE_NAME=${input_site:-BDXX00}

read -p "Monitor name [${SITE_NAME}-PING]: " input_monitor
MONITOR_NAME=${input_monitor:-${SITE_NAME}-PING}

read -p "Target (IP or URL): " input_target
while [[ -z "$input_target" ]]; do
    read -p "Target cannot be empty. Target (IP or URL): " input_target
done
TARGET=$input_target

if [[ "$TARGET" == http* ]]; then
    echo " [✓] HTTP/HTTPS detected. Using native cURL."
else
    echo " [✓] IP/Plain URL detected. Using native PING."
fi
echo "------------------------------------------"

# --- 2. System Optimization & Dependencies ---
echo "Optimizing Raspberry Pi WiFi stability..."
sudo iw dev wlan0 set power_save off
if ! grep -q "iw dev wlan0 set power_save off" /etc/rc.local; then
    sudo sed -i -e '$i \/sbin/iw dev wlan0 set power_save off\n' /etc/rc.local
fi

# Removed httping. Only installing jq and ensuring curl is present.
echo "Ensuring dependencies are installed..."
sudo apt-get update -qq && sudo apt-get install -y jq curl awk > /dev/null

# --- 3. Generate Configuration File ---
echo "Creating configuration at $CONFIG_FILE..."
sudo bash -c "cat > $CONFIG_FILE" << EOF
# G2 Probe Agent Configuration
SERVER_ID="${SITE_NAME}"
TARGETS=(
    "${MONITOR_NAME}|${TARGET}"
)
EOF

# --- 4. Generate the Agent Script ---
echo "Creating agent script at $AGENT_BIN..."
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
        # HTTP CHECK: Native cURL extraction
        # Extracts HTTP Status Code and Total Time in seconds (e.g., 200|0.145)
        HTTP_RESULT=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}" --connect-timeout 2 -m 3 "$TARGET")
        
        HTTP_CODE="${HTTP_RESULT%|*}"
        HTTP_TIME_SEC="${HTTP_RESULT#*|}"

        # If HTTP code is 2xx or 3xx, consider it UP
        if [[ "$HTTP_CODE" =~ ^[23] ]]; then
            HTTP_STATUS="up"
            # Convert decimal seconds to whole milliseconds using awk
            HTTP_LATENCY=$(awk "BEGIN {print int($HTTP_TIME_SEC * 1000)}")
            [[ -z "$HTTP_LATENCY" ]] && HTTP_LATENCY=0
        else
            HTTP_STATUS="down"
        fi
    else
        # PING CHECK: Native single-packet ICMP
        PING_RESULT=$(ping -c 1 -W 1 "$TARGET" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            PING_STATUS="up"
            PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.')
            [[ -z "$PING_LATENCY" ]] && PING_LATENCY=0
        else
            PING_STATUS="down"
        fi
    fi

    # Build Individual Payload
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

    # Send Request to n8n
    curl -X POST "$N8N_WEBHOOK_URL" \
         -H "Content-Type: application/json" \
         -d "$PAYLOAD" \
         --connect-timeout 2 \
         --max-time 3 \
         --retry 0 \
         -s -o /dev/null
         
    sleep 0.5 
done
EOF

sudo chmod +x "$AGENT_BIN"

# --- 5. Systemd Setup (Replacing Cron) ---
echo "Configuring systemd service and timer..."

# Create the Service file
sudo bash -c "cat > /etc/systemd/system/g2agent.service" << 'EOF'
[Unit]
Description=G2 Probe Network Agent
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/g2agent
EOF

# Create the Timer file (Runs every 1 minute)
sudo bash -c "cat > /etc/systemd/system/g2agent.timer" << 'EOF'
[Unit]
Description=Run G2 Probe Agent every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload systemd, enable and start the timer
sudo systemctl daemon-reload
sudo systemctl enable g2agent.timer
sudo systemctl start g2agent.timer

# Remove any old cron jobs if they exist to prevent double-execution
(crontab -l 2>/dev/null | grep -v "$AGENT_BIN") | crontab -

echo "=========================================="
echo " Installation complete!"
echo " The agent is now managed by systemd."
echo " To check status: sudo systemctl status g2agent.timer"
echo " To view logs:    sudo journalctl -u g2agent.service"
echo "=========================================="
