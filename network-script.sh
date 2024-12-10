#!/bin/bash

set -euo pipefail

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
DISK_LIMIT_MB=1024  # Reduced to 1GB since we're storing less data

# Promised ISP speed (in Mbps)
PROMISED_DOWNLOAD_MBPS=15
PROMISED_UPLOAD_MBPS=1

# Ensure directories exist
mkdir -p "$DATA_DIR"
if ! touch "$DB_FILE" 2>/dev/null; then
    handle_error "Cannot write to $DB_FILE"
fi

# Initialize SQLite database if not exists
if [[ ! -f "$DB_FILE" ]]; then
  sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS network_stats (
    timestamp TEXT NOT NULL,
    download_speed REAL,
    upload_speed REAL,
    latency REAL,
    dns_time REAL
);

CREATE TABLE IF NOT EXISTS throttling_tests (
    timestamp TEXT NOT NULL,
    test_type TEXT,
    server TEXT,
    latency REAL,
    meets_promised_speed BOOLEAN
);
EOF
fi

check_dependencies() {
    local dependencies=(sqlite3 speedtest-cli jq dig curl ip)
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            handle_error "Required command '$cmd' not found. Please install it."
        fi
    done
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
        \"promised_upload_speed_mbps\": $PROMISED_UPLOAD_MBPS,
        \"download_meets_promise\": $(awk -v a=$download_speed -v b=$PROMISED_DOWNLOAD_MBPS 'BEGIN {print (a >= b) ? "true" : "false"}'),
        \"upload_meets_promise\": $(awk -v a=$upload_speed -v b=$PROMISED_UPLOAD_MBPS 'BEGIN {print (a >= b) ? "true" : "false"}')
    }" > "$OVERALL_JSON"

    # Save to database
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, download_speed, upload_speed, latency)
VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', $download_speed, $upload_speed, $ping);
EOF
}

# Function to test DNS performance
test_dns_performance() {
    echo "Testing DNS performance..."
    local dns_servers=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    for dns in "${dns_servers[@]}"; do
        local dns_time
        dns_time=$(dig @"$dns" google.com | grep "Query time:" | awk '{print $4}')
        
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, dns_time)
VALUES ('$timestamp', $dns_time);
EOF
    done
}

# Function to test ISP throttling
test_throttling() {
    echo "Testing for ISP throttling..."
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    for server in "speed.cloudflare.com" "speedtest.googlefiber.net"; do
        local curl_output
        curl_output=$(curl -w "%{time_total}\n" -o /dev/null -s "https://$server")
        local latency
        latency=$(echo "$curl_output" | awk '{print $1}')
        
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO throttling_tests (timestamp, test_type, server, latency)
VALUES ('$timestamp', 'CDN', '$server', $latency);
EOF
    done
}

# Check disk space
check_disk_space() {
    local current_size
    current_size=$(du -sm "$DATA_DIR" | cut -f1)
    if [ "$current_size" -gt "$DISK_LIMIT_MB" ]; then
        echo "Warning: Data directory exceeds size limit. Cleaning old files..."
        find "$DATA_DIR" -type f -mtime +30 -delete
    fi
}

# Main routine
main() {
    local lock_file="/tmp/network_monitor.lock"
    
    # Prevent multiple instances
    if ! mkdir "$lock_file" 2>/dev/null; then
        echo "Script is already running"
        exit 1
    fi
    
    # Setup cleanup traps
    trap 'rm -rf "$lock_file"' EXIT INT TERM
    
    check_dependencies
    check_disk_space
    
    test_overall_network
    test_throttling
    test_dns_performance
    
    echo "Network monitoring completed successfully"
}

main
