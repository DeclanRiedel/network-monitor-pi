#!/bin/bash

# Add at the beginning of the script
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
PER_IP_JSON="$DATA_DIR/per_ip_export.json"
OVERALL_JSON="$DATA_DIR/overall_export.json"
THROTTLING_JSON="$DATA_DIR/throttling_test.json"
DNS_LOG="$DATA_DIR/dns_log.json"
TRAFFIC_CAPTURE="$DATA_DIR/traffic.pcap"
DISK_LIMIT_MB=102400  # 100GB limit for logs

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
    ip TEXT,
    device_name TEXT,
    download_speed REAL,
    upload_speed REAL,
    latency REAL,
    packet_loss REAL,
    dns_time REAL,
    traffic_rx REAL,
    traffic_tx REAL,
    protocol TEXT
);

CREATE TABLE IF NOT EXISTS throttling_tests (
    timestamp TEXT NOT NULL,
    test_type TEXT,
    server TEXT,
    download_speed REAL,
    upload_speed REAL,
    latency REAL,
    meets_promised_download BOOLEAN,
    meets_promised_upload BOOLEAN
);
EOF
fi

# Function to scan active devices
scan_devices() {
  echo "Scanning for active devices..."
  arp-scan -l | awk '/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1, $2}' > "$DATA_DIR/active_ips.txt"
  while read -r ip mac; do
    local hostname
    hostname=$(nmap -sP "$ip" | grep "for" | awk '{print $NF}')
    echo "$ip $mac $hostname"
  done <"$DATA_DIR/active_ips.txt" >>"$DATA_DIR/device_list.log"
}

check_dependencies() {
    local dependencies=(sqlite3 arp-scan nmap tshark speedtest-cli jq dig curl ip)
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found. Please install it."
            exit 1
        fi
    done
}

# Function to log traffic by IP
log_traffic() {
  echo "Logging per-IP traffic..."
  tshark -i "$INTERFACE" -a duration:30 -q -z conv,ip | awk '{if ($1 ~ /^[0-9]+\./) print $1, $2, $3}' >"$DATA_DIR/traffic_stats.log"
}

# Function to log latency, packet loss, and per-IP upload/download
log_latency_and_speeds() {
  echo "Logging latency, packet loss, and speeds..."
  while read -r ip _; do
    local ping_output
    ping_output=$(ping -c 10 "$ip")
    local avg_latency
    avg_latency=$(echo "$ping_output" | grep avg | awk -F '/' '{print $5}')
    local packet_loss
    packet_loss=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)')
    
    local traffic_stats
    traffic_stats=$(grep "$ip" "$DATA_DIR/traffic_stats.log")
    local upload_speed download_speed
    upload_speed=$(echo "$traffic_stats" | awk '{print $3}')  # Outgoing traffic
    download_speed=$(echo "$traffic_stats" | awk '{print $2}') # Incoming traffic
    
    if [ -z "$avg_latency" ] || [ -z "$packet_loss" ] || [ -z "$upload_speed" ] || [ -z "$download_speed" ]; then
        echo "Warning: Missing data for IP $ip, skipping..."
        continue
    fi
    
    echo "$ip $avg_latency $packet_loss $upload_speed $download_speed"
  done <"$DATA_DIR/active_ips.txt" >"$DATA_DIR/ip_stats.log"
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
INSERT INTO throttling_tests (timestamp, test_type, server, download_speed, upload_speed, latency, meets_promised_download, meets_promised_upload)
VALUES ('$timestamp', 'CDN', '$server', NULL, NULL, $latency, NULL, NULL);
EOF
  done
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
INSERT INTO network_stats (timestamp, ip, dns_time, protocol)
VALUES ('$timestamp', '$dns', $dns_time, 'DNS');
EOF
    done
}

# Function to analyze network protocols
analyze_protocols() {
    echo "Analyzing network protocols..."
    tshark -i "$INTERFACE" -a duration:30 -z io,phs \
        | awk '/^[[:space:]]*[0-9]/ {print $2, $3}' \
        > "$DATA_DIR/protocol_stats.log"
    
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    while read -r protocol bytes; do
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, protocol, traffic_rx)
VALUES ('$timestamp', '$protocol', $bytes);
EOF
    done < "$DATA_DIR/protocol_stats.log"
}

# Periodic export to JSON
export_json() {
  sqlite3 "$DB_FILE" "SELECT * FROM network_stats;" | jq -R -s -c 'split("\n") | .[:-1] | map(split("|"))' >"$PER_IP_JSON"
  sqlite3 "$DB_FILE" "SELECT * FROM throttling_tests;" | jq -R -s -c 'split("\n") | .[:-1] | map(split("|"))' >"$THROTTLING_JSON"
}

# Save data into SQLite
save_to_db() {
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  while read -r ip latency packet_loss upload_speed download_speed; do
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO network_stats (timestamp, ip, download_speed, upload_speed, latency, packet_loss)
VALUES ('$timestamp', '$ip', $download_speed, $upload_speed, $latency, $packet_loss);
EOF
  done <"$DATA_DIR/ip_stats.log"
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

# Main routine
main() {
    local lock_file="/tmp/network_monitor.lock"
    
    # Prevent multiple instances
    if ! mkdir "$lock_file" 2>/dev/null; then
        echo "Script is already running"
        exit 1
    fi
    
    # Setup cleanup traps
    trap 'rm -f "$DATA_DIR"/*.log; rm -rf "$lock_file"' EXIT INT TERM
    
    check_dependencies
    rotate_database
    check_disk_space
    
    scan_devices
    log_traffic
    log_latency_and_speeds
    test_overall_network
    test_throttling
    test_dns_performance
    analyze_protocols
    save_to_db
    export_json
    
    # Cleanup temporary files
    find "$DATA_DIR" -name "*.log" -type f -mmin +60 -delete
}

main
