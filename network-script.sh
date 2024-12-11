#!/bin/bash

set -euo pipefail

# Define lock file globally
LOCK_FILE="/var/run/network_monitor.lock"

handle_error() {
    echo "Error: $1" >&2
    exit 1
}

INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -m 1 '^e')
if [ -z "$INTERFACE" ]; then
    handle_error "No ethernet interface found"
fi

# Configuration
DATA_DIR="/var/log/network_monitor"
DB_FILE="$DATA_DIR/network_data.db"
OVERALL_JSON="$DATA_DIR/overall_export.json"
THROTTLING_JSON="$DATA_DIR/throttling_test.json"
DNS_LOG="$DATA_DIR/dns_log.json"
BANDWIDTH_LOG="$DATA_DIR/bandwidth_usage.json"
HOURLY_STATS="$DATA_DIR/hourly_stats.json"
DAILY_REPORT="$DATA_DIR/daily_report.txt"
DISK_LIMIT_MB=1024

# Create all necessary directories and files
create_dirs_and_files() {
    local files=(
        "$OVERALL_JSON"
        "$THROTTLING_JSON"
        "$DNS_LOG"
        "$BANDWIDTH_LOG"
        "$HOURLY_STATS"
        "$DAILY_REPORT"
    )

    mkdir -p "$DATA_DIR"
    
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            touch "$file"
            chmod 644 "$file"
        fi
    done
}

# Initialize SQLite database if not exists
init_database() {
    if [[ ! -f "$DB_FILE" ]]; then
        sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS network_stats (
    timestamp TEXT NOT NULL,
    download_speed REAL,
    upload_speed REAL,
    latency REAL,
    jitter REAL,
    packet_loss REAL,
    dns_time REAL,
    bandwidth_usage REAL,
    tcp_connections INTEGER,
    connection_quality TEXT
);

CREATE TABLE IF NOT EXISTS throttling_tests (
    timestamp TEXT NOT NULL,
    test_type TEXT,
    server TEXT,
    latency REAL,
    download_speed REAL,
    upload_speed REAL,
    meets_promised_speed BOOLEAN,
    throttle_detected BOOLEAN,
    test_duration REAL
);

CREATE TABLE IF NOT EXISTS hourly_stats (
    hour TEXT NOT NULL,
    avg_download REAL,
    avg_upload REAL,
    avg_latency REAL,
    peak_bandwidth REAL,
    connection_drops INTEGER
);
EOF
    fi
}

# Function to measure connection quality
measure_connection_quality() {
    echo "Measuring connection quality..."
    local ping_stats
    ping_stats=$(ping -c 20 8.8.8.8 | grep -E 'rtt|packet loss')
    
    local packet_loss
    packet_loss=$(echo "$ping_stats" | grep -oP '\d+(?=% packet loss)')
    
    local jitter
    jitter=$(echo "$ping_stats" | awk -F '/' '{print $7}')
    
    local tcp_conn
    tcp_conn=$(netstat -tn | grep ESTABLISHED | wc -l)
    
    local quality
    if [ "${packet_loss:-100}" -lt 1 ] && [ "${jitter:-1000}" -lt 10 ]; then
        quality="Excellent"
    elif [ "${packet_loss:-100}" -lt 5 ] && [ "${jitter:-1000}" -lt 30 ]; then
        quality="Good"
    else
        quality="Poor"
    fi
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"packet_loss\": $packet_loss,
        \"jitter\": $jitter,
        \"tcp_connections\": $tcp_conn,
        \"quality\": \"$quality\"
    }" > "$DATA_DIR/connection_quality.json"
    
    return 0
}

# Enhanced throttling test
test_throttling() {
    echo "Testing for ISP throttling..."
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    local results="$DATA_DIR/throttle_results.txt"
    echo "ISP Throttling Test Results - $timestamp" > "$results"
    echo "----------------------------------------" >> "$results"
    
    for server in "speed.cloudflare.com" "speedtest.googlefiber.net" "fast.com"; do
        echo "Testing $server..." >> "$results"
        local start_time
        start_time=$(date +%s.%N)
        
        local curl_output
        curl_output=$(curl -w "%{speed_download},%{speed_upload},%{time_total}\n" -o /dev/null -s "https://$server")
        
        local download_speed upload_speed latency
        download_speed=$(echo "$curl_output" | cut -d',' -f1)
        upload_speed=$(echo "$curl_output" | cut -d',' -f2)
        latency=$(echo "$curl_output" | cut -d',' -f3)
        
        local end_time
        end_time=$(date +%s.%N)
        local duration
        duration=$(echo "$end_time - $start_time" | bc)
        
        local throttled
        if (( $(echo "$download_speed < $PROMISED_DOWNLOAD_MBPS * 0.7" | bc -l) )); then
            throttled="Yes"
        else
            throttled="No"
        fi
        
        echo "  Download Speed: ${download_speed} Mbps" >> "$results"
        echo "  Upload Speed: ${upload_speed} Mbps" >> "$results"
        echo "  Latency: ${latency} ms" >> "$results"
        echo "  Throttling Detected: ${throttled}" >> "$results"
        echo "----------------------------------------" >> "$results"
        
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO throttling_tests (
    timestamp, test_type, server, latency, download_speed, 
    upload_speed, meets_promised_speed, throttle_detected, test_duration
) VALUES (
    '$timestamp', 'CDN', '$server', $latency, $download_speed,
    $upload_speed, 
    $(echo "$download_speed >= $PROMISED_DOWNLOAD_MBPS" | bc),
    $(echo "$throttled" | grep -q "Yes" && echo 1 || echo 0),
    $duration
);
EOF
    done
    
    # Create human-readable JSON
    jq -n --arg timestamp "$timestamp" --arg content "$(cat "$results")" \
        '{timestamp: $timestamp, results: $content}' > "$THROTTLING_JSON"
}

# Function to monitor bandwidth usage
monitor_bandwidth() {
    local interval=60  # 1 minute
    local rx_bytes_start tx_bytes_start
    read -r rx_bytes_start < "/sys/class/net/$INTERFACE/statistics/rx_bytes"
    read -r tx_bytes_start < "/sys/class/net/$INTERFACE/statistics/tx_bytes"
    
    sleep "$interval"
    
    local rx_bytes_end tx_bytes_end
    read -r rx_bytes_end < "/sys/class/net/$INTERFACE/statistics/rx_bytes"
    read -r tx_bytes_end < "/sys/class/net/$INTERFACE/statistics/tx_bytes"
    
    local rx_rate tx_rate
    rx_rate=$(echo "scale=2; ($rx_bytes_end - $rx_bytes_start) / $interval / 125000" | bc)  # Convert to Mbps
    tx_rate=$(echo "scale=2; ($tx_bytes_end - $tx_bytes_start) / $interval / 125000" | bc)  # Convert to Mbps
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"rx_mbps\": $rx_rate,
        \"tx_mbps\": $tx_rate,
        \"total_mbps\": $(echo "$rx_rate + $tx_rate" | bc)
    }" > "$BANDWIDTH_LOG"
}


# Function to test overall network performance
test_overall_network() {
    echo "Testing overall network performance..."
    local speedtest_output
    speedtest_output=$(speedtest-cli --json)
    local download_speed upload_speed ping
    download_speed=$(echo "$speedtest_output" | jq '.download' | awk '{print $1/1000000}') # Convert to Mbps
    upload_speed=$(echo "$speedtest_output" | jq '.upload' | awk '{print $1/1000000}')   # Convert to Mbps
    ping=$(echo "$speedtest_output" | jq '.ping')
    
    # Save to JSON
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"download_speed_mbps\": $download_speed,
        \"upload_speed_mbps\": $upload_speed,
        \"latency_ms\": $ping,
        \"promised_download_speed_mbps\": $PROMISED_DOWNLOAD_MBPS,
        \"promised_upload_speed_mbps\": $PROMISED_UPLOAD_MBPS
    }" > "$OVERALL_JSON"

    # Save to database
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, download_speed, upload_speed, latency)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', $download_speed, $upload_speed, $ping);
EOF
}

# Check disk space
check_disk_space() {
    local current_size
    current_size=$(du -sm "$DATA_DIR" | cut -f1)
    if [ "$current_size" -gt "$DISK_LIMIT_MB" ]; then
        echo "Warning: Data directory exceeds size limit. Cleaning old files..."
        find "$DATA_DIR" -type f -name "*.log" -mtime +30 -delete
        find "$DATA_DIR" -type f -name "*.pcap" -mtime +7 -delete
    fi
}

check_dependencies() {
    local dependencies=(sqlite3 speedtest-cli jq curl bc netstat ping)
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            handle_error "Required command '$cmd' not found. Please install it."
        fi
    done
}


# Generate daily report
generate_daily_report() {
    local report="$DAILY_REPORT"
    echo "Network Performance Report - $(date '+%Y-%m-%d')" > "$report"
    echo "================================================" >> "$report"
    
    # Average speeds
    sqlite3 "$DB_FILE" <<EOF >> "$report"
.mode column
.headers on
SELECT 
    round(avg(download_speed), 2) as avg_download_mbps,
    round(avg(upload_speed), 2) as avg_upload_mbps,
    round(avg(latency), 2) as avg_latency_ms,
    round(avg(packet_loss), 2) as avg_packet_loss_percent
FROM network_stats
WHERE timestamp >= datetime('now', '-24 hours');
EOF
    
    echo -e "\nThrottling Incidents Today:" >> "$report"
    sqlite3 "$DB_FILE" <<EOF >> "$report"
SELECT 
    timestamp,
    server,
    round(download_speed, 2) as download_mbps,
    case when throttle_detected = 1 then 'Yes' else 'No' end as throttled
FROM throttling_tests
WHERE timestamp >= datetime('now', '-24 hours')
AND throttle_detected = 1;
EOF
}

# Main routine
main() {
    # Create lock file directory if it doesn't exist
    sudo mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null || true
    
    # Prevent multiple instances using redirection instead of mkdir
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "Script is already running"
        exit 1
    fi
    
    # Setup cleanup traps
    trap 'rm -f "${LOCK_FILE}"; exec 9>&-' EXIT INT TERM
    
    check_dependencies
    create_dirs_and_files
    init_database
    check_disk_space
    
    test_overall_network
    test_throttling
    test_dns_performance
    measure_connection_quality
    monitor_bandwidth
    generate_daily_report
    
    echo "Network monitoring completed successfully"
}

main
