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
    
    sqlite3 "$DB_FILE" <<'EOF'
CREATE TABLE IF NOT EXISTS network_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    download_speed REAL DEFAULT 0,
    upload_speed REAL DEFAULT 0,
    latency REAL DEFAULT 0,
    packet_loss REAL DEFAULT 0,
    jitter REAL DEFAULT 0,
    dns_time REAL DEFAULT 0,
    tcp_connections INTEGER DEFAULT 0,
    connection_quality TEXT,
    bandwidth_usage REAL DEFAULT 0
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

CREATE TABLE IF NOT EXISTS routing_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    gateway TEXT,
    hops_to_internet INTEGER,
    gateway_latency REAL
);

CREATE TABLE IF NOT EXISTS wifi_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    signal_strength TEXT,
    noise_level TEXT,
    link_quality TEXT
);

CREATE TABLE IF NOT EXISTS interface_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    rx_errors INTEGER,
    tx_errors INTEGER,
    rx_dropped INTEGER,
    tx_dropped INTEGER
);

CREATE TABLE IF NOT EXISTS tcp_states (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    established INTEGER,
    time_wait INTEGER,
    close_wait INTEGER
);

CREATE TABLE IF NOT EXISTS mtu_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    mtu INTEGER,
    fragmentation_allowed INTEGER
);

CREATE TABLE IF NOT EXISTS ipv6_status (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    has_ipv6 INTEGER,
    ipv6_reachable INTEGER
);

CREATE TABLE IF NOT EXISTS dns_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    record_type TEXT,
    lookup_time REAL
);

CREATE TABLE IF NOT EXISTS tcp_stack_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    tcp_timeouts INTEGER,
    retransmits INTEGER,
    fast_retransmits INTEGER,
    forward_retransmits INTEGER,
    lost_retransmits INTEGER
);

CREATE TABLE IF NOT EXISTS buffer_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    rx_buffer INTEGER,
    tx_buffer INTEGER,
    backlog INTEGER
);

CREATE TABLE IF NOT EXISTS congestion_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    congestion_algorithm TEXT,
    qdisc TEXT,
    queue_drops INTEGER
);

CREATE TABLE IF NOT EXISTS socket_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    used_sockets INTEGER,
    orphaned INTEGER,
    time_wait INTEGER
);

CREATE TABLE IF NOT EXISTS device_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    speed INTEGER,
    duplex TEXT,
    carrier INTEGER,
    driver TEXT
);

CREATE TABLE IF NOT EXISTS protocol_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    ip_forwarding INTEGER,
    ip_fragments INTEGER,
    udp_packets INTEGER,
    icmp_messages INTEGER
);
EOF
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
    # Convert floating point values to integers for comparison
    packet_loss=${packet_loss:-100}  # Default to 100 if empty
    jitter=${jitter:-1000}          # Default to 1000 if empty
    
    # Round jitter to nearest integer for comparison
    jitter_int=${jitter%.*}

    if [ "${packet_loss}" -lt 1 ] && [ "${jitter_int}" -lt 10 ]; then
        quality="Excellent"
    elif [ "${packet_loss}" -lt 5 ] && [ "${jitter_int}" -lt 30 ]; then
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
            local start_time
            local end_time
            local lookup_time
            
            # Ensure start_time is captured
            start_time=$(date +%s.%N) || start_time=$(date +%s)
            
            # Use timeout to prevent hanging
            if timeout 3 dig "@${dns_server}" "$domain" +short +tries=1 +time=2 >/dev/null 2>&1; then
                # Ensure end_time is captured
                end_time=$(date +%s.%N) || end_time=$(date +%s)
                lookup_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
                
                # Validate lookup_time
                if [[ ! "$lookup_time" =~ ^[0-9]*\.?[0-9]*$ ]]; then
                    lookup_time="0"
                fi
                
                echo "Lookup successful: ${lookup_time}s"
            else
                echo "Warning: DNS lookup failed for $domain using $dns_server"
                lookup_time="0"
            fi
            
            results+=("$domain,$dns_server,$lookup_time")
            sleep 0.5  # Small delay between queries
        done
    done
    
    # Ensure we have results before proceeding
    if [ ${#results[@]} -eq 0 ]; then
        echo "Warning: No DNS results collected"
        return 0
    fi
    
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
        if [[ "$time" =~ ^[0-9]*\.?[0-9]*$ ]] && [ "$time" != "0" ]; then
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

# Monitor route changes and latency to gateway
monitor_routing() {
    local gateway=$(ip route | grep default | awk '{print $3}')
    local hops=$(traceroute -n -w 1 8.8.8.8 | wc -l)
    local gateway_latency=$(ping -c 3 "$gateway" | grep 'avg' | awk -F'/' '{print $5}')
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"gateway\": \"$gateway\",
        \"hops_to_internet\": $hops,
        \"gateway_latency\": $gateway_latency
    }" > "$DATA_DIR/routing_info.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO routing_info (timestamp, gateway, hops_to_internet, gateway_latency)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', '$gateway', $hops, $gateway_latency);
EOF
}

# Monitor WiFi signal strength (if applicable)
monitor_wifi() {
    if [[ "$INTERFACE" == wlan* ]]; then
        local signal=$(iwconfig "$INTERFACE" | grep "Signal level" | awk -F"=" '{print $3}')
        local noise=$(iwconfig "$INTERFACE" | grep "Noise level" | awk -F"=" '{print $2}')
        local quality=$(iwconfig "$INTERFACE" | grep "Link Quality" | awk -F"=" '{print $2}')
        
        echo "{
            \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
            \"signal_strength\": \"$signal\",
            \"noise_level\": \"$noise\",
            \"link_quality\": \"$quality\"
        }" > "$DATA_DIR/wifi_stats.json"
        
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO wifi_stats (timestamp, signal_strength, noise_level, link_quality)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', '$signal', '$noise', '$quality');
EOF
    fi
}

# Monitor network interface errors
monitor_interface_errors() {
    local rx_errors=$(cat "/sys/class/net/$INTERFACE/statistics/rx_errors")
    local tx_errors=$(cat "/sys/class/net/$INTERFACE/statistics/tx_errors")
    local rx_dropped=$(cat "/sys/class/net/$INTERFACE/statistics/rx_dropped")
    local tx_dropped=$(cat "/sys/class/net/$INTERFACE/statistics/tx_dropped")
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"rx_errors\": $rx_errors,
        \"tx_errors\": $tx_errors,
        \"rx_dropped\": $rx_dropped,
        \"tx_dropped\": $tx_dropped
    }" > "$DATA_DIR/interface_errors.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO interface_errors (timestamp, rx_errors, tx_errors, rx_dropped, tx_dropped)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', $rx_errors, $tx_errors, $rx_dropped, $tx_dropped);
EOF
}

# Monitor TCP connection states
monitor_tcp_states() {
    local established=$(ss -tn state established | wc -l)
    local time_wait=$(ss -tn state time-wait | wc -l)
    local close_wait=$(ss -tn state close-wait | wc -l)
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"established\": $established,
        \"time_wait\": $time_wait,
        \"close_wait\": $close_wait
    }" > "$DATA_DIR/tcp_states.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO tcp_states (timestamp, established, time_wait, close_wait)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', $established, $time_wait, $close_wait);
EOF
}

# Monitor MTU changes and fragmentation
monitor_mtu() {
    local current_mtu=$(ip link show "$INTERFACE" | grep mtu | awk '{print $5}')
    local fragmentation=$(cat /proc/sys/net/ipv4/ip_no_pmtu_disc)
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"mtu\": $current_mtu,
        \"fragmentation_allowed\": $fragmentation
    }" > "$DATA_DIR/mtu_info.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO mtu_info (timestamp, mtu, fragmentation_allowed)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', $current_mtu, $fragmentation);
EOF
}

# Monitor IPv6 connectivity
test_ipv6() {
    local has_ipv6=$(ip -6 addr show dev "$INTERFACE" 2>/dev/null)
    local ipv6_reachable=0
    
    if ping6 -c 1 2001:4860:4860::8888 >/dev/null 2>&1; then
        ipv6_reachable=1
    fi
    
    echo "{
        \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
        \"has_ipv6\": ${has_ipv6:+1},
        \"ipv6_reachable\": $ipv6_reachable
    }" > "$DATA_DIR/ipv6_status.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO ipv6_status (timestamp, has_ipv6, ipv6_reachable)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', ${has_ipv6:+1}, $ipv6_reachable);
EOF
}

# Monitor DNS resolution times for different record types
test_dns_records() {
    local domain="google.com"
    local start_time end_time
    
    # Test different record types
    for record in A AAAA MX TXT; do
        start_time=$(date +%s.%N)
        dig "$domain" "$record" +short >/dev/null
        end_time=$(date +%s.%N)
        local lookup_time=$(echo "$end_time - $start_time" | bc)
        
        echo "{
            \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
            \"record_type\": \"$record\",
            \"lookup_time\": $lookup_time
        }" >> "$DATA_DIR/dns_records.json"
        
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO dns_records (timestamp, record_type, lookup_time)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', '$record', $lookup_time);
EOF
    done
}

# Additional monitoring functions

# Monitor TCP/IP stack parameters
monitor_tcp_stack() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local tcp_stats=""
    
    # Attempt to get TCP stats with error handling
    if ! tcp_stats=$(cat /proc/net/netstat 2>/dev/null | awk '
        /TcpExt/ { 
            getline; 
            printf "\"tcp_timeouts\": %s,\n\"retransmits\": %s,\n\"fast_retransmits\": %s,\n\"forward_retransmits\": %s,\n\"lost_retransmits\": %s", 
            $13, $45, $46, $47, $48 
        }'); then
        handle_function_error "monitor_tcp_stack" "Failed to read TCP stats"
        tcp_stats="\"tcp_timeouts\": 0,\"retransmits\": 0,\"fast_retransmits\": 0,\"forward_retransmits\": 0,\"lost_retransmits\": 0"
    fi
    
    # Write to JSON with error handling
    if ! echo "{
        \"timestamp\": \"$timestamp\",
        $tcp_stats
    }" > "$DATA_DIR/tcp_stack.json"; then
        handle_function_error "monitor_tcp_stack" "Failed to write JSON file"
    fi
    
    # Write to database with error handling
    if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO tcp_stack_stats (
    timestamp, tcp_timeouts, retransmits, fast_retransmits, 
    forward_retransmits, lost_retransmits
) VALUES (
    '$timestamp',
    $(echo "$tcp_stats" | grep -oP 'tcp_timeouts": \K[0-9]+' || echo "0"),
    $(echo "$tcp_stats" | grep -oP 'retransmits": \K[0-9]+' || echo "0"),
    $(echo "$tcp_stats" | grep -oP 'fast_retransmits": \K[0-9]+' || echo "0"),
    $(echo "$tcp_stats" | grep -oP 'forward_retransmits": \K[0-9]+' || echo "0"),
    $(echo "$tcp_stats" | grep -oP 'lost_retransmits": \K[0-9]+' || echo "0")
);
EOF
    then
        handle_function_error "monitor_tcp_stack" "Failed to write to database"
    fi
    
    return 0  # Ensure function continues even if parts fail
}

# Monitor network buffer statistics
monitor_network_buffers() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local rx_buffer=$(sysctl -n net.core.rmem_default)
    local tx_buffer=$(sysctl -n net.core.wmem_default)
    local backlog=$(sysctl -n net.core.netdev_max_backlog)
    
    echo "{
        \"timestamp\": \"$timestamp\",
        \"rx_buffer\": $rx_buffer,
        \"tx_buffer\": $tx_buffer,
        \"backlog\": $backlog
    }" > "$DATA_DIR/network_buffers.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO buffer_stats (timestamp, rx_buffer, tx_buffer, backlog)
VALUES ('$timestamp', $rx_buffer, $tx_buffer, $backlog);
EOF
}

# Monitor network congestion
monitor_congestion() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    local qdisc=$(tc qdisc show dev "$INTERFACE" | head -n1)
    local queue_drops=$(tc -s qdisc show dev "$INTERFACE" | grep -oP 'dropped \K[0-9]+')
    
    echo "{
        \"timestamp\": \"$timestamp\",
        \"congestion_algorithm\": \"$algorithm\",
        \"qdisc\": \"$qdisc\",
        \"queue_drops\": $queue_drops
    }" > "$DATA_DIR/congestion.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO congestion_stats (
    timestamp, congestion_algorithm, qdisc, queue_drops
) VALUES (
    '$timestamp', '$algorithm', '$qdisc', $queue_drops
);
EOF
}

# Monitor socket statistics
monitor_socket_stats() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local used_sockets=$(ss -s | grep 'TCP:' | awk '{print $2}')
    local orphaned=$(cat /proc/net/sockstat | grep TCP: | awk '{print $4}')
    local time_wait=$(cat /proc/net/sockstat | grep TCP: | awk '{print $6}')
    
    echo "{
        \"timestamp\": \"$timestamp\",
        \"used_sockets\": $used_sockets,
        \"orphaned\": $orphaned,
        \"time_wait\": $time_wait
    }" > "$DATA_DIR/socket_stats.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO socket_stats (timestamp, used_sockets, orphaned, time_wait)
VALUES ('$timestamp', $used_sockets, $orphaned, $time_wait);
EOF
}

# Monitor network device details
monitor_device_details() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local speed=$(cat "/sys/class/net/$INTERFACE/speed" 2>/dev/null || echo "0")
    local duplex=$(cat "/sys/class/net/$INTERFACE/duplex" 2>/dev/null || echo "unknown")
    local carrier=$(cat "/sys/class/net/$INTERFACE/carrier" 2>/dev/null || echo "0")
    local driver=$(ethtool -i "$INTERFACE" 2>/dev/null | grep driver | awk '{print $2}')
    
    echo "{
        \"timestamp\": \"$timestamp\",
        \"speed\": $speed,
        \"duplex\": \"$duplex\",
        \"carrier\": $carrier,
        \"driver\": \"$driver\"
    }" > "$DATA_DIR/device_details.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO device_stats (timestamp, speed, duplex, carrier, driver)
VALUES ('$timestamp', $speed, '$duplex', $carrier, '$driver');
EOF
}

# Monitor network protocol statistics
monitor_protocol_stats() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local ip_stats=$(cat /proc/net/snmp | awk '/Ip:/ {getline; print}')
    local udp_stats=$(cat /proc/net/snmp | awk '/Udp:/ {getline; print}')
    local icmp_stats=$(cat /proc/net/snmp | awk '/Icmp:/ {getline; print}')
    
    echo "{
        \"timestamp\": \"$timestamp\",
        \"ip_forwarding\": $(sysctl -n net.ipv4.ip_forward),
        \"ip_fragments\": $(echo "$ip_stats" | awk '{print $7}'),
        \"udp_packets\": $(echo "$udp_stats" | awk '{print $2}'),
        \"icmp_messages\": $(echo "$icmp_stats" | awk '{print $2}')
    }" > "$DATA_DIR/protocol_stats.json"
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO protocol_stats (
    timestamp, ip_forwarding, ip_fragments, udp_packets, icmp_messages
) VALUES (
    '$timestamp',
    $(sysctl -n net.ipv4.ip_forward),
    $(echo "$ip_stats" | awk '{print $7}'),
    $(echo "$udp_stats" | awk '{print $2}'),
    $(echo "$icmp_stats" | awk '{print $2}')
);
EOF
}

# Error handling wrapper function
handle_function_error() {
    local function_name="$1"
    local error_message="$2"
    echo "Warning: $function_name failed - $error_message" >> "$DATA_DIR/errors.log"
    echo "Warning: $function_name failed - $error_message"
}

# Monitor DNS with error handling
test_dns_performance() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local lookup_time=0
    
    # Attempt DNS lookup with timeout and error handling
    if ! lookup_time=$(timeout 5 dig google.com +tries=1 2>/dev/null | grep "Query time:" | awk '{print $4}'); then
        handle_function_error "test_dns_performance" "DNS lookup failed"
        lookup_time=0
    fi
    
    # Write to JSON with error handling
    if ! echo "{
        \"timestamp\": \"$timestamp\",
        \"lookup_time\": ${lookup_time:-0}
    }" > "$DATA_DIR/dns_performance.json"; then
        handle_function_error "test_dns_performance" "Failed to write JSON file"
    fi
    
    # Write to database with error handling
    if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, dns_time)
VALUES ('$timestamp', ${lookup_time:-0});
EOF
    then
        handle_function_error "test_dns_performance" "Failed to write to database"
    fi
    
    return 0
}

# Monitor bandwidth with error handling
monitor_bandwidth() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local download=0
    local upload=0
    
    # Attempt speedtest with timeout
    if ! speed_result=$(timeout 30 speedtest-cli --json 2>/dev/null); then
        handle_function_error "monitor_bandwidth" "Speed test failed"
    else
        download=$(echo "$speed_result" | jq -r '.download' 2>/dev/null || echo "0")
        upload=$(echo "$speed_result" | jq -r '.upload' 2>/dev/null || echo "0")
    fi
    
    # Write to JSON with error handling
    if ! echo "{
        \"timestamp\": \"$timestamp\",
        \"download\": ${download:-0},
        \"upload\": ${upload:-0}
    }" > "$DATA_DIR/bandwidth.json"; then
        handle_function_error "monitor_bandwidth" "Failed to write JSON file"
    fi
    
    # Write to database with error handling
    if ! sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, download_speed, upload_speed)
VALUES ('$timestamp', ${download:-0}, ${upload:-0});
EOF
    then
        handle_function_error "monitor_bandwidth" "Failed to write to database"
    fi
    
    return 0
}

# Main routine
main() {
    echo "Starting network monitoring script..."
    
    # Create error log if it doesn't exist
    touch "$DATA_DIR/errors.log"
    
    while true; do
        echo "======================================"
        echo "Starting network tests at $(date)"
        
        # Run each monitoring function with error handling
        for function in monitor_tcp_stack test_dns_performance monitor_bandwidth monitor_routing monitor_wifi monitor_interface_errors monitor_tcp_states monitor_mtu test_ipv6 test_dns_records monitor_network_buffers monitor_congestion monitor_socket_stats monitor_device_details monitor_protocol_stats; do
            if ! $function; then
                handle_function_error "$function" "Function failed but continuing script"
            fi
            sleep 1  # Small delay between tests
        done
        
        echo "Tests completed at $(date)"
        echo "Waiting for next run..."
        echo "======================================"
        
        sleep 1800 || {
            handle_function_error "main" "Sleep interrupted"
            break
        }
    done
}

# Start the script with error handling
if ! main; then
    echo "Script failed with error $?" >&2
    exit 1
fi
