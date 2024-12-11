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

# Constants for promised speeds (in Mbps)
PROMISED_DOWNLOAD=15
PROMISED_UPLOAD=1
THRESHOLD_PERCENT=30

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
    
    for server in "speed.cloudflare.com" "speedtest.googlefiber.net"; do
        echo "Testing $server..."
        local start_time
        start_time=$(date +%s.%N)
        
        local curl_output
        if ! curl_output=$(curl -w "%{speed_download},%{speed_upload},%{time_total}\n" -o /dev/null -s --max-time 30 "https://$server" 2>/dev/null); then
            echo "Warning: Failed to test $server, skipping..."
            continue
        fi
        
        local download_speed upload_speed latency
        download_speed=$(echo "$curl_output" | cut -d',' -f1)
        upload_speed=$(echo "$curl_output" | cut -d',' -f2)
        latency=$(echo "$curl_output" | cut -d',' -f3)
        
        # Validate the values
        download_speed=${download_speed:-0}
        upload_speed=${upload_speed:-0}
        latency=${latency:-0}
        
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
            echo "----------------------------------------"
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
    
    echo "Throttling tests completed"
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

# Function to check for required tools
check_dependencies() {
    local dependencies=(
        "sqlite3"
        "speedtest-cli"
        "jq"
        "curl"
        "bc"
        "netstat"
        "ping"
        "dig"
        "ip"
        "awk"
        "grep"
    )
    
    local missing_deps=0
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Missing dependency: $cmd"
            missing_deps=1
        fi
    done
    
    if [ $missing_deps -eq 1 ]; then
        echo "Please install missing dependencies using:"
        echo "sudo apt-get update"
        echo "sudo apt-get install sqlite3 speedtest-cli jq curl bc net-tools dnsutils iproute2"
        handle_error "Missing dependencies"
    fi
}

# Function to test DNS performance
test_dns_performance() {
    echo "Testing DNS performance..."
    local domains=("google.com" "cloudflare.com" "amazon.com" "microsoft.com")
    local dns_servers=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    local results=()
    
    for domain in "${domains[@]}"; do
        for dns_server in "${dns_servers[@]}"; do
            echo "Testing DNS lookup for $domain using $dns_server..."
            local start_time=$(date +%s.%N)
            
            # Add timeout and error handling to dig command
            if timeout 5 dig "@${dns_server}" "$domain" +short +tries=1 >/dev/null 2>&1; then
                local end_time=$(date +%s.%N)
                local lookup_time
                lookup_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
                results+=("$domain,$dns_server,$lookup_time")
            else
                echo "Warning: DNS lookup failed for $domain using $dns_server"
                results+=("$domain,$dns_server,failed")
            fi
            
            # Add a small delay between tests
            sleep 1
        done
    done
    
    # Save results to JSON with error handling
    {
        echo "{"
        echo "  \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\","
        echo "  \"lookups\": ["
        local first=true
        for result in "${results[@]}"; do
            IFS=',' read -r domain server time <<< "$result"
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            if [ "$time" = "failed" ]; then
                time="null"
            fi
            echo "    {"
            echo "      \"domain\": \"$domain\","
            echo "      \"dns_server\": \"$server\","
            echo "      \"lookup_time\": $time"
            echo -n "    }"
        done
        echo
        echo "  ]"
        echo "}" 
    } > "$DNS_LOG"
    
    # Calculate average lookup time with error handling
    local total=0
    local count=0
    for result in "${results[@]}"; do
        IFS=',' read -r _ _ time <<< "$result"
        if [ "$time" != "failed" ] && [ "$time" != "null" ]; then
            total=$(echo "$total + $time" | bc 2>/dev/null || echo "$total")
            ((count++))
        fi
    done
    
    local avg_lookup_time=0
    if [ $count -gt 0 ]; then
        avg_lookup_time=$(echo "scale=3; $total / $count" | bc 2>/dev/null || echo "0")
    fi
    
    # Save to database with error handling
    if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, dns_time)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', $avg_lookup_time);
EOF
    then
        echo "Warning: Failed to save DNS results to database"
    fi
    
    echo "DNS performance testing completed"
    return 0
}

# Function to detect and report spikes
detect_spikes() {
    local current_download=$1
    local current_upload=$2
    local current_latency=$3
    
    # Get averages from the last hour
    local averages
    averages=$(sqlite3 "$DB_FILE" <<EOF
SELECT 
    avg(download_speed) as avg_download,
    avg(upload_speed) as avg_upload,
    avg(latency) as avg_latency
FROM network_stats
WHERE timestamp >= datetime('now', '-1 hour');
EOF
)
    
    local avg_download avg_upload avg_latency
    IFS='|' read -r avg_download avg_upload avg_latency <<< "$averages"
    
    # Define spike thresholds (50% deviation from average)
    local spike_detected=false
    local spike_message=""
    
    if [ "$(echo "$current_download < $avg_download * 0.5" | bc -l)" -eq 1 ]; then
        spike_detected=true
        spike_message+="Download speed dropped significantly. "
    fi
    
    if [ "$(echo "$current_upload < $avg_upload * 0.5" | bc -l)" -eq 1 ]; then
        spike_detected=true
        spike_message+="Upload speed dropped significantly. "
    fi
    
    if [ "$(echo "$current_latency > $avg_latency * 2" | bc -l)" -eq 1 ]; then
        spike_detected=true
        spike_message+="Latency increased significantly. "
    fi
    
    if [ "$spike_detected" = true ]; then
        local alert_message="ALERT: Network performance spike detected at $(date '+%Y-%m-%d %H:%M:%S')\n$spike_message"
        echo -e "$alert_message" >> "$DATA_DIR/alerts.log"
        echo -e "$alert_message"
    fi
}

# Function to track speed drops
track_speed_drops() {
    local current_download=$1
    local current_upload=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Calculate thresholds
    local download_threshold=$(echo "scale=2; $PROMISED_DOWNLOAD * $THRESHOLD_PERCENT / 100" | bc)
    local upload_threshold=$(echo "scale=2; $PROMISED_UPLOAD * $THRESHOLD_PERCENT / 100" | bc)
    
    # Check if we're in a drop state
    local drop_state_file="$DATA_DIR/drop_state.json"
    local drop_history_file="$DATA_DIR/speed_drops_history.json"
    
    # Initialize drop history file if it doesn't exist
    if [ ! -f "$drop_history_file" ]; then
        echo "[]" > "$drop_history_file"
    fi
    
    if [ "$(echo "$current_download < $download_threshold" | bc -l)" -eq 1 ] || \
       [ "$(echo "$current_upload < $upload_threshold" | bc -l)" -eq 1 ]; then
        
        # Check if this is a new drop
        if [ ! -f "$drop_state_file" ]; then
            # Start new drop tracking
            local drop_data=$(cat <<EOF
{
    "start_time": "$timestamp",
    "start_download": $current_download,
    "start_upload": $current_upload,
    "promised_download": $PROMISED_DOWNLOAD,
    "promised_upload": $PROMISED_UPLOAD,
    "threshold_percent": $THRESHOLD_PERCENT,
    "ongoing": true,
    "samples": []
}
EOF
)
            echo "$drop_data" > "$drop_state_file"
            
            # Log the start of drop
            echo "Speed drop detected at $timestamp" >> "$DATA_DIR/drops.log"
        fi
        
        # Add sample to ongoing drop
        local sample=$(cat <<EOF
    {
        "timestamp": "$timestamp",
        "download": $current_download,
        "upload": $current_upload
    }
EOF
)
        # Append sample to existing drop state
        jq --arg sample "$sample" '.samples += [$sample]' "$drop_state_file" > "${drop_state_file}.tmp" && \
        mv "${drop_state_file}.tmp" "$drop_state_file"
        
    elif [ -f "$drop_state_file" ]; then
        # Drop has ended, finalize the record
        local end_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Calculate duration and averages
        local drop_data=$(cat "$drop_state_file")
        local start_time=$(echo "$drop_data" | jq -r '.start_time')
        local duration_seconds=$(( $(date -d "$end_timestamp" +%s) - $(date -d "$start_time" +%s) ))
        
        # Calculate averages during the drop
        local samples=$(echo "$drop_data" | jq '.samples')
        local avg_download=$(echo "$samples" | jq '[.[].download] | add/length')
        local avg_upload=$(echo "$samples" | jq '[.[].upload] | add/length')
        
        # Create final drop record
        local final_record=$(cat <<EOF
{
    "start_time": "$start_time",
    "end_time": "$end_timestamp",
    "duration_seconds": $duration_seconds,
    "duration_human": "$(printf '%dh:%dm:%ds' $(($duration_seconds/3600)) $(($duration_seconds%3600/60)) $(($duration_seconds%60)))",
    "average_download": $avg_download,
    "average_upload": $avg_upload,
    "promised_download": $PROMISED_DOWNLOAD,
    "promised_upload": $PROMISED_UPLOAD,
    "samples_count": $(echo "$samples" | jq 'length'),
    "percent_of_promised": $(echo "scale=2; $avg_download * 100 / $PROMISED_DOWNLOAD" | bc)
}
EOF
)
        # Append to history
        jq --arg record "$final_record" '. += [$record]' "$drop_history_file" > "${drop_history_file}.tmp" && \
        mv "${drop_history_file}.tmp" "$drop_history_file"
        
        # Remove drop state file
        rm -f "$drop_state_file"
        
        # Log the end of drop
        echo "Speed drop ended at $end_timestamp (Duration: $(printf '%dh:%dm:%ds' $(($duration_seconds/3600)) $(($duration_seconds%3600/60)) $(($duration_seconds%60))))" >> "$DATA_DIR/drops.log"
        
        # Send notification
        if command -v notify-send >/dev/null 2>&1; then
            notify-send "Network Speed Drop Ended" "Duration: $(printf '%dh:%dm:%ds' $(($duration_seconds/3600)) $(($duration_seconds%3600/60)) $(($duration_seconds%60)))\nAvg Download: ${avg_download}Mbps\nAvg Upload: ${avg_upload}Mbps"
        fi
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
        test_dns_performance
        test_throttling
        monitor_bandwidth
        
        # Get latest measurements for spike and drop detection
        local latest
        latest=$(sqlite3 "$DB_FILE" "SELECT download_speed, upload_speed, latency 
            FROM network_stats ORDER BY timestamp DESC LIMIT 1;")
        IFS='|' read -r current_download current_upload current_latency <<< "$latest"
        
        detect_spikes "$current_download" "$current_upload" "$current_latency"
        track_speed_drops "$current_download" "$current_upload"
        
        echo "Tests completed. Waiting 30 minutes before next run..."
        echo "======================================"
        sleep 1800
    done
}

# Start the script
main
