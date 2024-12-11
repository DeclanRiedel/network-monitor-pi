#!/bin/bash

set -euo pipefail

# Define lock file globally
LOCK_FILE="/var/run/network_monitor.lock"

# Directory and file setup
DATA_DIR="/var/log/network_monitor"
DB_FILE="$DATA_DIR/network_data.db"
OVERALL_JSON="$DATA_DIR/overall_export.json"
THROTTLING_JSON="$DATA_DIR/throttling_test.json"
DNS_LOG="$DATA_DIR/dns_log.json"
BANDWIDTH_LOG="$DATA_DIR/bandwidth_usage.json"
HOURLY_STATS="$DATA_DIR/hourly_stats.json"
DAILY_REPORT="$DATA_DIR/daily_report.txt"
DISK_LIMIT_MB=1024

# Error handling
handle_error() {
    echo "Error: $1" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >> "$DATA_DIR/error.log"
    exit 1
}

# Find ethernet interface
INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -m 1 '^e')
if [ -z "$INTERFACE" ]; then
    handle_error "No ethernet interface found"
fi

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

    sudo mkdir -p "$DATA_DIR"
    sudo chown "$(whoami):$(whoami)" "$DATA_DIR"
    
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            touch "$file"
            chmod 644 "$file"
        fi
    done
}

# Initialize SQLite database
init_database() {
    echo "Initializing database..."
    # Ensure directory exists
    mkdir -p "$(dirname "$DB_FILE")"
    
    # Create database with proper permissions
    if [[ ! -f "$DB_FILE" ]]; then
        touch "$DB_FILE"
        chmod 666 "$DB_FILE"
        
        sqlite3 "$DB_FILE" <<'EOF'
CREATE TABLE IF NOT EXISTS network_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    download_speed REAL DEFAULT 0,
    upload_speed REAL DEFAULT 0,
    latency REAL DEFAULT 0,
    jitter REAL DEFAULT 0,
    packet_loss REAL DEFAULT 0,
    dns_time REAL DEFAULT 0,
    bandwidth_usage REAL DEFAULT 0,
    tcp_connections INTEGER DEFAULT 0,
    connection_quality TEXT
);

CREATE TABLE IF NOT EXISTS throttling_tests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    test_type TEXT,
    server TEXT,
    latency REAL DEFAULT 0,
    download_speed REAL DEFAULT 0,
    upload_speed REAL DEFAULT 0,
    meets_promised_speed INTEGER DEFAULT 0,
    throttle_detected INTEGER DEFAULT 0,
    test_duration REAL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS hourly_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hour TEXT NOT NULL,
    avg_download REAL DEFAULT 0,
    avg_upload REAL DEFAULT 0,
    avg_latency REAL DEFAULT 0,
    peak_bandwidth REAL DEFAULT 0,
    connection_drops INTEGER DEFAULT 0
);
EOF
    fi
    echo "Database initialization completed"
}

# Function to measure connection quality
measure_connection_quality() {
    echo "Measuring connection quality..."
    local ping_stats
    local packet_loss=100
    local jitter=0
    local tcp_conn=0
    local quality="Poor"

    # Try to get ping statistics with error handling
    if ! ping_stats=$(ping -I "$INTERFACE" -c 20 8.8.8.8 2>/dev/null | grep -E 'rtt|packet loss'); then
        echo "Warning: Ping test failed, using default values"
    else
        # Extract packet loss with fallback
        packet_loss=$(echo "$ping_stats" | grep -oP '\d+(?=% packet loss)' || echo "100")
        
        # Extract jitter with fallback (remove 'ms' and handle floating point)
        jitter=$(echo "$ping_stats" | awk -F '/' '{gsub(/ms/,"",$7); print $7}' || echo "0")
    fi

    # Get TCP connections with error handling
    if ! tcp_conn=$(netstat -ant | grep ESTABLISHED | wc -l 2>/dev/null); then
        tcp_conn=0
        echo "Warning: Could not get TCP connection count"
    fi

    # Determine quality with more defensive checks
    packet_loss=${packet_loss:-100}  # Default to 100 if empty
    jitter=${jitter:-1000}          # Default to 1000 if empty

    if [ "${packet_loss}" -lt 1 ] && [ "${jitter%.*}" -lt 10 ]; then
        quality="Excellent"
    elif [ "${packet_loss}" -lt 5 ] && [ "${jitter%.*}" -lt 30 ]; then
        quality="Good"
    else
        quality="Poor"
    fi

    # Create JSON output with error handling
    local json_data
    json_data=$(cat <<EOF
{
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
    "packet_loss": ${packet_loss},
    "jitter": ${jitter},
    "tcp_connections": ${tcp_conn},
    "quality": "${quality}"
}
EOF
)
    echo "$json_data" > "$DATA_DIR/connection_quality.json"

    # Save to database with error handling
    if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (
    timestamp,
    packet_loss,
    jitter,
    tcp_connections,
    connection_quality
) VALUES (
    '$(date '+%Y-%m-%d %H:%M:%S')',
    ${packet_loss},
    ${jitter},
    ${tcp_conn},
    '${quality}'
);
EOF
    then
        echo "Warning: Failed to save to database. Error: $?"
        echo "Attempting to create tables..."
        init_database
    fi

    echo "Connection quality measurement completed"
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
    
    # Ensure the throttling_tests table exists
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS throttling_tests (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        test_type TEXT,
        server TEXT,
        latency REAL DEFAULT 0,
        download_speed REAL DEFAULT 0,
        upload_speed REAL DEFAULT 0,
        meets_promised_speed INTEGER DEFAULT 0,
        throttle_detected INTEGER DEFAULT 0,
        test_duration REAL DEFAULT 0
    );"
    
    for server in "speed.cloudflare.com" "speedtest.googlefiber.net" "fast.com"; do
        echo "Testing $server..."
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
        
        local throttled="No"
        if (( $(echo "$download_speed < 15 * 0.7" | bc -l) )); then
            throttled="Yes"
        fi
        
        # Save results to text file
        {
            echo "  Download Speed: ${download_speed} Mbps"
            echo "  Upload Speed: ${upload_speed} Mbps"
            echo "  Latency: ${latency} ms"
            echo "  Throttling Detected: ${throttled}"
        } >> "$results"
        
        # Save to database with error handling
        if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO throttling_tests (
    timestamp,
    test_type,
    server,
    latency,
    download_speed,
    upload_speed,
    meets_promised_speed,
    throttle_detected,
    test_duration
) VALUES (
    '$timestamp',
    'CDN',
    '$server',
    $latency,
    $download_speed,
    $upload_speed,
    $(echo "$download_speed >= 15" | bc),
    $(echo "$throttled" | grep -q "Yes" && echo 1 || echo 0),
    $duration
);
EOF
        then
            echo "Warning: Failed to save throttling test to database for $server"
        fi
    done
    
    # Create JSON summary
    jq -n --arg timestamp "$timestamp" --arg content "$(cat "$results")" \
        '{timestamp: $timestamp, results: $content}' > "$THROTTLING_JSON"
}

# Monitor bandwidth usage
monitor_bandwidth() {
    echo "Monitoring bandwidth usage..."
    local interval=60  # 1 minute
    local rx_bytes_start tx_bytes_start
    read -r rx_bytes_start < "/sys/class/net/$INTERFACE/statistics/rx_bytes"
    read -r tx_bytes_start < "/sys/class/net/$INTERFACE/statistics/tx_bytes"
    
    sleep "$interval"
    
    local rx_bytes_end tx_bytes_end
    read -r rx_bytes_end < "/sys/class/net/$INTERFACE/statistics/rx_bytes"
    read -r tx_bytes_end < "/sys/class/net/$INTERFACE/statistics/tx_bytes"
    
    local rx_rate tx_rate
    rx_rate=$(echo "scale=2; ($rx_bytes_end - $rx_bytes_start) / $interval / 125000" | bc)
    tx_rate=$(echo "scale=2; ($tx_bytes_end - $tx_bytes_start) / $interval / 125000" | bc)
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"rx_mbps\": $rx_rate,
        \"tx_mbps\": $tx_rate,
        \"total_mbps\": $(echo "$rx_rate + $tx_rate" | bc)
    }" > "$BANDWIDTH_LOG"
}

# Check disk space
check_disk_space() {
    local current_size
    current_size=$(du -sm "$DATA_DIR" | cut -f1)
    if [ "$current_size" -gt "$DISK_LIMIT_MB" ]; then
        echo "Warning: Data directory exceeds size limit. Cleaning old files..."
        find "$DATA_DIR" -type f -name "*.log" -mtime +30 -delete
        find "$DATA_DIR" -type f -name "*.json" -mtime +30 -delete
    fi
}

# Main routine
main() {
    # Create lock file directory if it doesn't exist
    sudo mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null || true
    
    # Prevent multiple instances
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "Script is already running"
        exit 1
    fi
    
    # Setup cleanup trap
    trap 'rm -f "${LOCK_FILE}"; exec 9>&-' EXIT INT TERM
    
    check_dependencies
    create_dirs_and_files
    init_database
    
    while true; do
        echo "======================================"
        echo "Starting network tests at $(date)"
        echo "Interface: $INTERFACE"
        echo "======================================"
        
        check_disk_space
        measure_connection_quality
        test_throttling
        monitor_bandwidth
        
        echo "Tests completed. Waiting 30 minutes before next run..."
        echo "======================================"
        sleep 1800
    done
}

# Start the script
main
