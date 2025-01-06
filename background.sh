#!/bin/bash

# Create directories for data storage
DATA_DIR="/var/log/network_monitor"
JSON_DIR="$DATA_DIR/json"
mkdir -p "$JSON_DIR"

# Initialize SQLite database
DB_FILE="$DATA_DIR/network_metrics.db"

init_database() {
    sqlite3 "$DB_FILE" <<EOF
    CREATE TABLE IF NOT EXISTS bandwidth_metrics (
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        download_speed FLOAT,
        upload_speed FLOAT,
        packet_loss FLOAT
    );
    
    CREATE TABLE IF NOT EXISTS latency_metrics (
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        ping_local FLOAT,
        ping_remote FLOAT,
        jitter FLOAT,
        rtt_avg FLOAT
    );
    
    CREATE TABLE IF NOT EXISTS routing_metrics (
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        hop_count INTEGER,
        path_latency FLOAT,
        path_consistency FLOAT
    );
    
    CREATE TABLE IF NOT EXISTS protocol_metrics (
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        tcp_connections INTEGER,
        tcp_retransmissions FLOAT,
        dns_resolution_time FLOAT
    );
    
    CREATE TABLE IF NOT EXISTS network_load (
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        bandwidth_utilization FLOAT,
        connection_count INTEGER,
        interface_errors INTEGER
    );
EOF
}

collect_bandwidth_metrics() {
    speedtest_result=$(speedtest-cli --json)
    echo "$speedtest_result" >> "$JSON_DIR/bandwidth_metrics.json"
    
    download_speed=$(echo "$speedtest_result" | jq '.download')
    upload_speed=$(echo "$speedtest_result" | jq '.upload')
    packet_loss=$(ping -c 10 8.8.8.8 | grep "packet loss" | awk '{print $6}' | tr -d '%')
    
    sqlite3 "$DB_FILE" "INSERT INTO bandwidth_metrics (download_speed, upload_speed, packet_loss) 
                        VALUES ($download_speed, $upload_speed, $packet_loss);"
}

collect_latency_metrics() {
    gateway=$(ip route | grep default | awk '{print $3}')
    ping_local=$(ping -c 3 $gateway | tail -n 1 | awk '{print $4}' | cut -d '/' -f 2)
    ping_remote=$(ping -c 3 8.8.8.8 | tail -n 1 | awk '{print $4}' | cut -d '/' -f 2)
    rtt_avg=$(mtr -n --report 8.8.8.8 | tail -n 1 | awk '{print $6}')
    jitter=$(ping -c 10 8.8.8.8 | tail -n 1 | awk '{print $7}' | cut -d '/' -f 2)
    
    metrics=$(jq -n \
        --arg pl "$ping_local" \
        --arg pr "$ping_remote" \
        --arg rt "$rtt_avg" \
        --arg jt "$jitter" \
        '{ping_local: $pl, ping_remote: $pr, rtt_avg: $rt, jitter: $jt}')
    
    echo "$metrics" >> "$JSON_DIR/latency_metrics.json"
    
    sqlite3 "$DB_FILE" "INSERT INTO latency_metrics (ping_local, ping_remote, jitter, rtt_avg) 
                        VALUES ($ping_local, $ping_remote, $jitter, $rtt_avg);"
}

collect_protocol_metrics() {
    tcp_connections=$(netstat -tn | grep ESTABLISHED | wc -l)
    tcp_retrans=$(netstat -s | grep "segments retransmitted" | awk '{print $1}')
    dns_time=$(dig google.com | grep "Query time" | awk '{print $4}')
    
    metrics=$(jq -n \
        --arg tc "$tcp_connections" \
        --arg tr "$tcp_retrans" \
        --arg dt "$dns_time" \
        '{tcp_connections: $tc, tcp_retransmissions: $tr, dns_resolution_time: $dt}')
    
    echo "$metrics" >> "$JSON_DIR/protocol_metrics.json"
    
    sqlite3 "$DB_FILE" "INSERT INTO protocol_metrics (tcp_connections, tcp_retransmissions, dns_resolution_time) 
                        VALUES ($tcp_connections, $tcp_retrans, $dns_time);"
}

# Main collection loop
init_database

while true; do
    collect_bandwidth_metrics
    collect_latency_metrics
    collect_protocol_metrics
    sleep 300
done
