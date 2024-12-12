#!/bin/bash

# Required packages: speedtest-cli, iw, sqlite3, jq, iperf3, nmap, tcpdump, ethtool, 
# mtr, bmon, nethogs, iftop, wondershaper, nicstat, vnstat, vnstat, ifstat, netstat-nat, curl, bc, net-tools, traceroute, mtr

# Directory Setup
BASE_DIR="/var/log/network_monitor"
LOG_DIR="$BASE_DIR/logs"
DATA_DIR="$BASE_DIR/data"
ERROR_LOG="$LOG_DIR/error.log"
DEBUG_LOG="$LOG_DIR/debug.log"

# Create necessary directories
mkdir -p "$LOG_DIR" "$DATA_DIR"

# Configuration
INTERFACES=("eth0" "wlan0")  # Prioritize ethernet
PRIMARY_INTERFACE="eth0"     # Used for tests that only need one interface
ADVERTISED_DOWNLOAD=100      # Your advertised download speed in Mbps
ADVERTISED_UPLOAD=20         # Your advertised upload speed in Mbps
TEST_SERVERS=(
    "8.8.8.8"           # Google DNS
    "1.1.1.1"           # Cloudflare
    "9.9.9.9"           # Quad9
    "192.168.1.1"       # Local gateway
)
HTTP_TEST_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com"
    "https://www.amazon.com"
)

# Initialize SQLite database
init_database() {
    sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
CREATE TABLE IF NOT EXISTS bandwidth_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    interface TEXT,
    download_speed REAL,
    upload_speed REAL,
    speed_ratio_to_advertised REAL,
    peak_speed REAL,
    consistency_score REAL
);

CREATE TABLE IF NOT EXISTS latency_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    server TEXT,
    ping_time REAL,
    jitter REAL,
    rtt_avg REAL,
    rtt_min REAL,
    rtt_max REAL
);

CREATE TABLE IF NOT EXISTS network_quality (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    interface TEXT,
    signal_strength REAL,
    snr REAL,
    freq_band TEXT,
    tx_rate REAL,
    rx_rate REAL
);

CREATE TABLE IF NOT EXISTS protocol_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    domain TEXT,
    dns_resolution_time REAL,
    tcp_connect_time REAL,
    tcp_retrans INTEGER
);

CREATE TABLE IF NOT EXISTS http_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    url TEXT,
    response_time REAL
);

CREATE TABLE IF NOT EXISTS stability_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    uptime_percentage REAL,
    current_status INTEGER,
    interruption_duration INTEGER
);

CREATE TABLE IF NOT EXISTS load_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    concurrent_connections INTEGER,
    bandwidth_utilization REAL,
    incoming_traffic REAL,
    outgoing_traffic REAL
);

CREATE TABLE IF NOT EXISTS security_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    suspicious_connections INTEGER,
    potential_scans INTEGER,
    rx_errors INTEGER,
    tx_errors INTEGER
);

CREATE TABLE IF NOT EXISTS advanced_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    mtu_size INTEGER,
    tcp_window_scaling INTEGER,
    buffer_bloat REAL,
    congestion_control TEXT
);

CREATE TABLE IF NOT EXISTS interface_metrics (
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    interface TEXT,
    rx_bytes REAL,
    tx_bytes REAL,
    rx_packets INTEGER,
    tx_packets INTEGER,
    rx_errors INTEGER,
    tx_errors INTEGER,
    rx_dropped INTEGER,
    tx_dropped INTEGER,
    mtu INTEGER,
    queue_length INTEGER,
    power_management TEXT,
    rx_checksumming TEXT,
    tx_checksumming TEXT,
    scatter_gather TEXT,
    tcp_segmentation TEXT,
    bond_status TEXT,
    speed TEXT,
    duplex TEXT,
    auto_negotiation TEXT,
    port_type TEXT,
    eee_status TEXT
);
EOF
}

# Error handling function
log_error() {
    local error_msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $error_msg" >> "$ERROR_LOG"
}

# Debug logging function
log_debug() {
    local debug_msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] DEBUG: $debug_msg" >> "$DEBUG_LOG"
}

# Error handling function for commands
handle_error() {
    local exit_code=$?
    local command="$1"
    if [ $exit_code -ne 0 ]; then
        log_error "Command '$command' failed with exit code $exit_code"
        return $exit_code
    fi
    return 0
}

# Bandwidth Metrics Collection
collect_bandwidth_metrics() {
    result=$(speedtest-cli --interface $PRIMARY_INTERFACE --json 2>/dev/null)
    if ! handle_error "speedtest-cli"; then
        log_error "Speedtest failed on $PRIMARY_INTERFACE"
        return 1
    fi
    
    download=$(echo "$result" | jq '.download')
    upload=$(echo "$result" | jq '.upload')
    
    # Calculate speed ratio
    download_ratio=$(echo "scale=2; $download / ($ADVERTISED_DOWNLOAD * 1000000)" | bc)
    upload_ratio=$(echo "scale=2; $upload / ($ADVERTISED_UPLOAD * 1000000)" | bc)
    
    # Store in database
    sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
    INSERT INTO bandwidth_metrics (
        interface,
        download_speed,
        upload_speed,
        speed_ratio_to_advertised
    ) VALUES (
        '$PRIMARY_INTERFACE',
        $download,
        $upload,
        $download_ratio
    );
EOF
    if [ $? -ne 0 ]; then
        log_error "Failed to insert bandwidth metrics into database"
        return 1
    fi
}

# Latency Measurements
collect_latency_metrics() {
    for server in "${TEST_SERVERS[@]}"; do
        ping_result=$(ping -c 10 -i 0.2 "$server" 2>/dev/null)
        if ! handle_error "ping $server"; then
            log_error "Ping to $server failed"
            continue
        fi
        
        rtt_avg=$(echo "$ping_result" | awk -F '/' 'END {print $5}')
        rtt_min=$(echo "$ping_result" | awk -F '/' 'END {print $4}')
        rtt_max=$(echo "$ping_result" | awk -F '/' 'END {print $6}')
        
        # Calculate jitter
        jitter=$(echo "$ping_result" | awk -F '=' '/rtt/ {split($2,a,"/"); print a[3]}')
        
        sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
        INSERT INTO latency_metrics (
            server,
            ping_time,
            jitter,
            rtt_avg,
            rtt_min,
            rtt_max
        ) VALUES (
            '$server',
            $rtt_avg,
            $jitter,
            $rtt_avg,
            $rtt_min,
            $rtt_max
        );
EOF
        if [ $? -ne 0 ]; then
            log_error "Failed to insert latency metrics for $server into database"
        fi
    done
}

# Network Quality Indicators
collect_network_quality() {
    for interface in "${INTERFACES[@]}"; do
        # Different collection methods for wireless vs ethernet
        if [[ $interface == wlan* ]]; then
            # Wireless metrics
            if command -v iw >/dev/null; then
                signal_info=$(iw dev $interface station dump 2>/dev/null)
                if [ $? -eq 0 ]; then
                    signal_strength=$(echo "$signal_info" | grep 'signal:' | awk '{print $2}')
                    tx_bitrate=$(echo "$signal_info" | grep 'tx bitrate:' | awk '{print $3}')
                    freq_band=$(iw dev $interface info | grep 'channel' | awk '{print $2}')
                    
                    # Calculate SNR
                    noise_floor=-95  # Typical noise floor in dBm
                    snr=$(( signal_strength - noise_floor ))
                else
                    log_error "Failed to get wireless metrics for $interface"
                    signal_strength="NULL"
                    tx_bitrate="NULL"
                    freq_band="NULL"
                    snr="NULL"
                fi
            else
                log_error "iw command not found"
                signal_strength="NULL"
                tx_bitrate="NULL"
                freq_band="NULL"
                snr="NULL"
            fi
        else
            # Ethernet metrics using ethtool
            if command -v ethtool >/dev/null; then
                eth_info=$(ethtool $interface 2>/dev/null)
                if [ $? -eq 0 ]; then
                    speed=$(echo "$eth_info" | grep 'Speed:' | awk '{print $2}' | tr -d 'Mb/s')
                    tx_bitrate=$speed
                else
                    log_error "Failed to get ethernet metrics for $interface"
                    speed="NULL"
                    tx_bitrate="NULL"
                fi
                signal_strength="NULL"  # Not applicable for ethernet
                freq_band="NULL"        # Not applicable for ethernet
                snr="NULL"              # Not applicable for ethernet
            else
                log_error "ethtool command not found"
                speed="NULL"
                tx_bitrate="NULL"
                signal_strength="NULL"
                freq_band="NULL"
                snr="NULL"
            fi
        fi

        sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
        INSERT INTO network_quality (
            interface,
            signal_strength,
            snr,
            freq_band,
            tx_rate
        ) VALUES (
            '$interface',
            ${signal_strength:-NULL},
            ${snr:-NULL},
            '${freq_band:-NULL}',
            ${tx_bitrate:-NULL}
        );
EOF
        if [ $? -ne 0 ]; then
            log_error "Failed to insert network quality metrics for $interface"
        fi
    done
}

# Protocol-Specific Metrics Collection
collect_protocol_metrics() {
    # TCP connection establishment time
    tcp_connect_time=$(timeout 2 time nc -zv google.com 443 2>&1 | grep 'real' | awk '{print $2}')
    if [ $? -ne 0 ]; then
        log_error "Failed to measure TCP connection time"
        tcp_connect_time="NULL"
    fi
    
    # TCP retransmission stats
    tcp_retrans=$(ss -ti | grep -c 'retrans' 2>/dev/null || echo "NULL")
    
    # DNS resolution times
    dns_domains=("google.com" "facebook.com" "amazon.com" "microsoft.com")
    for domain in "${dns_domains[@]}"; do
        dns_time=$(dig "@8.8.8.8" "$domain" | grep "Query time:" | awk '{print $4}')
        if [ $? -eq 0 ]; then
            sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
            INSERT INTO protocol_metrics (
                timestamp,
                domain,
                dns_resolution_time
            ) VALUES (
                CURRENT_TIMESTAMP,
                '$domain',
                ${dns_time:-NULL}
            );
EOF
            if [ $? -ne 0 ]; then
                log_error "Failed to insert DNS metrics for $domain"
            fi
        else
            log_error "Failed to measure DNS resolution time for $domain"
        fi
    done

    # HTTP/HTTPS latency measurements
    for url in "${HTTP_TEST_URLS[@]}"; do
        http_latency=$(curl -o /dev/null -s -w '%{time_total}\n' "$url")
        if [ $? -eq 0 ]; then
            sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
            INSERT INTO http_metrics (
                timestamp,
                url,
                response_time
            ) VALUES (
                CURRENT_TIMESTAMP,
                '$url',
                $http_latency
            );
EOF
            if [ $? -ne 0 ]; then
                log_error "Failed to insert HTTP metrics for $url"
            fi
        else
            log_error "Failed to measure HTTP latency for $url"
        fi
    done
}

# Connection Stability Monitoring
collect_stability_metrics() {
    # Check current connection status
    ping -c 1 8.8.8.8 >/dev/null 2>&1
    current_status=$?
    
    # Update connection log
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$current_status" >> "$DATA_DIR/connection_log.csv"
    
    # Calculate stability metrics
    if [ -f "$DATA_DIR/connection_log.csv" ]; then
        total_checks=$(wc -l < "$DATA_DIR/connection_log.csv")
        failures=$(grep -c ",1" "$DATA_DIR/connection_log.csv" || echo "0")
        uptime_percentage=$(echo "scale=2; (($total_checks-$failures)/$total_checks)*100" | bc)
        
        # Calculate interruption duration if currently disconnected
        interruption_duration=0
        if [ $current_status -ne 0 ]; then
            last_success=$(grep ",0" "$DATA_DIR/connection_log.csv" | tail -n 1)
            if [ ! -z "$last_success" ]; then
                last_success_time=$(echo "$last_success" | cut -d',' -f1)
                interruption_duration=$(( $(date +%s) - $(date -d "$last_success_time" +%s) ))
            fi
        fi
        
        sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
        INSERT INTO stability_metrics (
            timestamp,
            uptime_percentage,
            current_status,
            interruption_duration
        ) VALUES (
            CURRENT_TIMESTAMP,
            $uptime_percentage,
            $current_status,
            $interruption_duration
        );
EOF
        if [ $? -ne 0 ]; then
            log_error "Failed to insert stability metrics"
        fi
    else
        log_error "Connection log file not found"
    fi
}

# Network Load Characteristics
collect_load_metrics() {
    # Get current connections count
    concurrent_connections=$(netstat -an | grep ESTABLISHED | wc -l)
    if [ $? -ne 0 ]; then
        log_error "Failed to get connection count"
        concurrent_connections=0
    fi
        
    # Get bandwidth utilization
    if command -v vnstat >/dev/null; then
        bandwidth_util=$(vnstat -tr 2 | grep "rx" | awk '{print $2}')
        if [ $? -ne 0 ]; then
            log_error "Failed to get bandwidth utilization"
            bandwidth_util=0
        fi
    fi
        
    # Get interface statistics
    if command -v ifstat >/dev/null; then
        interface_stats=$(ifstat -i "$PRIMARY_INTERFACE" 1 1)
        if [ $? -eq 0 ]; then
            in_traffic=$(echo "$interface_stats" | tail -n 1 | awk '{print $1}')
            out_traffic=$(echo "$interface_stats" | tail -n 1 | awk '{print $2}')
        else
            log_error "Failed to get interface statistics"
            in_traffic=0
            out_traffic=0
        fi
    fi
        
    sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
    INSERT INTO load_metrics (
        timestamp,
        concurrent_connections,
        bandwidth_utilization,
        incoming_traffic,
        outgoing_traffic
    ) VALUES (
        CURRENT_TIMESTAMP,
        $concurrent_connections,
        ${bandwidth_util:-0},
        ${in_traffic:-0},
        ${out_traffic:-0}
    );
EOF
    if [ $? -ne 0 ]; then
        log_error "Failed to insert load metrics"
    fi
}

# Advanced Technical Metrics
collect_advanced_metrics() {
    # MTU size check
    mtu_size=$(ip link show "$PRIMARY_INTERFACE" | grep mtu | awk '{print $5}')
    if [ $? -ne 0 ]; then
        log_error "Failed to get MTU size"
        mtu_size=0
    fi
        
    # TCP window scaling
    tcp_window=$(sysctl net.ipv4.tcp_window_scaling | awk '{print $3}')
    if [ $? -ne 0 ]; then
        log_error "Failed to get TCP window scaling"
        tcp_window=0
    fi
        
    # Buffer bloat test using ping under load
    start_ping=$(ping -c 1 8.8.8.8 | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
    dd if=/dev/zero of=/dev/null bs=1M count=100 2>/dev/null & # Generate load
    load_ping=$(ping -c 1 8.8.8.8 | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
    kill $! 2>/dev/null # Stop load
    bloat_difference=$(echo "$load_ping - $start_ping" | bc)
        
    # Congestion control info
    congestion_control=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ $? -ne 0 ]; then
        log_error "Failed to get congestion control info"
        congestion_control="unknown"
    fi
        
    sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
    INSERT INTO advanced_metrics (
        timestamp,
        mtu_size,
        tcp_window_scaling,
        buffer_bloat,
        congestion_control
    ) VALUES (
        CURRENT_TIMESTAMP,
        $mtu_size,
        $tcp_window,
        $bloat_difference,
        '$congestion_control'
    );
EOF
    if [ $? -ne 0 ]; then
        log_error "Failed to insert advanced metrics"
    fi
}

# Security Metrics
collect_security_metrics() {
    # Check for unusual connection patterns
    suspicious_connections=$(netstat -an | grep -c "SYN_RECV" || echo "0")
    
    # Monitor for port scans
    potential_scans=$(grep "port scan" /var/log/syslog 2>/dev/null | wc -l || echo "0")
    
    # Check packet errors
    if [ -x "$(command -v ifconfig)" ]; then
        rx_errors=$(ifconfig "$PRIMARY_INTERFACE" | grep "RX errors" | awk '{print $3}' || echo "0")
        tx_errors=$(ifconfig "$PRIMARY_INTERFACE" | grep "TX errors" | awk '{print $3}' || echo "0")
    else
        rx_errors=0
        tx_errors=0
        log_error "ifconfig not found"
    fi
    
    sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
    INSERT INTO security_metrics (
        timestamp,
        suspicious_connections,
        potential_scans,
        rx_errors,
        tx_errors
    ) VALUES (
        CURRENT_TIMESTAMP,
        $suspicious_connections,
        $potential_scans,
        $rx_errors,
        $tx_errors
    );
EOF
    if [ $? -ne 0 ]; then
        log_error "Failed to insert security metrics"
    fi
}

# Enhanced interface metrics collection
collect_interface_metrics() {
    for interface in "${INTERFACES[@]}"; do
        # Basic interface statistics
        stats=$(ip -s link show $interface 2>/dev/null)
        if ! handle_error "ip -s link show $interface"; then
            log_error "Failed to get stats for $interface"
            continue
        fi

        # Parse basic statistics
        rx_bytes=$(echo "$stats" | awk '/RX:/{getline; print $1}')
        tx_bytes=$(echo "$stats" | awk '/TX:/{getline; print $1}')
        rx_packets=$(echo "$stats" | awk '/RX:/{getline; print $2}')
        tx_packets=$(echo "$stats" | awk '/TX:/{getline; print $2}')
        rx_errors=$(echo "$stats" | awk '/RX:/{getline; print $3}')
        tx_errors=$(echo "$stats" | awk '/TX:/{getline; print $3}')
        rx_dropped=$(echo "$stats" | awk '/RX:/{getline; print $4}')
        tx_dropped=$(echo "$stats" | awk '/TX:/{getline; print $4}')

        # Get MTU settings
        mtu=$(ip link show $interface | grep -oP 'mtu \K\d+' || echo "0")

        # Get queue length
        queue_length=$(ip link show $interface | grep -oP 'qlen \K\d+' || echo "0")

        # Get power management state
        power_mgmt=$(ethtool --show-features $interface 2>/dev/null | grep "Power Management:" | awk '{print $3}' || echo "unknown")

        # Get hardware offload capabilities
        rx_checksumming=$(ethtool --show-features $interface 2>/dev/null | grep "rx-checksumming:" | awk '{print $3}' || echo "unknown")
        tx_checksumming=$(ethtool --show-features $interface 2>/dev/null | grep "tx-checksumming:" | awk '{print $3}' || echo "unknown")
        scatter_gather=$(ethtool --show-features $interface 2>/dev/null | grep "scatter-gather:" | awk '{print $3}' || echo "unknown")
        tcp_segmentation=$(ethtool --show-features $interface 2>/dev/null | grep "tcp-segmentation-offload:" | awk '{print $3}' || echo "unknown")

        # Check link aggregation status
        bond_status="none"
        if [ -d "/sys/class/net/$interface/bonding" ]; then
            bond_status=$(cat /sys/class/net/$interface/bonding/mode 2>/dev/null || echo "active")
        fi

        # Interface specific advanced metrics
        if [[ $interface == eth* ]]; then
            # Ethernet specific
            eth_info=$(ethtool $interface 2>/dev/null)
            speed=$(echo "$eth_info" | grep 'Speed:' | awk '{print $2}' | tr -d 'Mb/s' || echo "0")
            duplex=$(echo "$eth_info" | grep 'Duplex:' | awk '{print $2}' || echo "unknown")
            auto_negotiation=$(echo "$eth_info" | grep 'Auto-negotiation:' | awk '{print $2}' || echo "unknown")
            port_type=$(echo "$eth_info" | grep 'Port:' | awk '{print $2}' || echo "unknown")
            
            # Get EEE (Energy Efficient Ethernet) status
            eee_status=$(ethtool --show-eee $interface 2>/dev/null | grep "EEE status:" | awk '{print $3}' || echo "unknown")
            
        elif [[ $interface == wlan* ]]; then
            # Wireless specific
            wifi_info=$(iwconfig $interface 2>/dev/null)
            speed="$(echo "$wifi_info" | grep 'Bit Rate' | awk '{print $2}' | cut -d= -f2 || echo "0")"
            duplex="full"
            auto_negotiation="on"
            port_type="wireless"
            eee_status="n/a"
        fi

        # Use default values if variables are empty
        speed=${speed:-0}
        duplex=${duplex:-unknown}
        auto_negotiation=${auto_negotiation:-unknown}
        port_type=${port_type:-unknown}
        eee_status=${eee_status:-unknown}

        # Insert into database with error handling
        sqlite3 "$DATA_DIR/network_metrics.db" <<EOF
        INSERT INTO interface_metrics (
            timestamp,
            interface,
            rx_bytes,
            tx_bytes,
            rx_packets,
            tx_packets,
            rx_errors,
            tx_errors,
            rx_dropped,
            tx_dropped,
            mtu,
            queue_length,
            power_management,
            rx_checksumming,
            tx_checksumming,
            scatter_gather,
            tcp_segmentation,
            bond_status,
            speed,
            duplex,
            auto_negotiation,
            port_type,
            eee_status
        ) VALUES (
            CURRENT_TIMESTAMP,
            '$interface',
            ${rx_bytes:-0},
            ${tx_bytes:-0},
            ${rx_packets:-0},
            ${tx_packets:-0},
            ${rx_errors:-0},
            ${tx_errors:-0},
            ${rx_dropped:-0},
            ${tx_dropped:-0},
            ${mtu:-0},
            ${queue_length:-0},
            '${power_mgmt:-unknown}',
            '${rx_checksumming:-unknown}',
            '${tx_checksumming:-unknown}',
            '${scatter_gather:-unknown}',
            '${tcp_segmentation:-unknown}',
            '${bond_status:-none}',
            '${speed}',
            '${duplex}',
            '${auto_negotiation}',
            '${port_type}',
            '${eee_status}'
        );
EOF
        if [ $? -ne 0 ]; then
            log_error "Failed to insert metrics for $interface into database"
        fi
    done
}

# Main monitoring loop
main() {
    # Ensure database is initialized first
    if ! init_database; then
        log_error "Failed to initialize database"
        exit 1
    fi
    
    log_debug "Database initialized successfully"
    
    while true; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        log_debug "Starting metrics collection cycle at $timestamp"
        
        collect_interface_metrics
        collect_network_quality
        collect_bandwidth_metrics
        collect_latency_metrics
        collect_stability_metrics
        collect_protocol_metrics
        collect_load_metrics
        collect_advanced_metrics
        collect_security_metrics
        
        export_current_metrics_json
        
        sleep 300
    done
}

# Export current metrics to JSON for foreground script
export_current_metrics_json() {
    sqlite3 -json "$DATA_DIR/network_metrics.db" "
        SELECT * FROM bandwidth_metrics 
        WHERE timestamp >= datetime('now', '-5 minutes')
        UNION ALL
        SELECT * FROM latency_metrics
        WHERE timestamp >= datetime('now', '-5 minutes')
        -- Add other tables as needed
    " > "$DATA_DIR/current_metrics.json"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to export metrics to JSON"
        return 1
    fi
}

# Trap signals for clean exit
trap 'echo "Exiting..."; exit 0' SIGINT SIGTERM

# Start the monitoring
main