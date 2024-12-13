#!/bin/bash

# Required packages: watch, jq, ncurses-utils, bc

# Configuration
DATA_DIR="/var/log/network_monitor/data"
INTERFACES=("wlan0" "eth0")
REFRESH_RATE=2  # seconds

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Clear screen and move cursor to top
clear_screen() {
    clear
    tput cup 0 0
}

# Format numbers to human-readable
format_speed() {
    local speed=$1
    if [ $speed -gt 1000000000 ]; then
        echo "$(echo "scale=2; $speed/1000000000" | bc) Gbps"
    elif [ $speed -gt 1000000 ]; then
        echo "$(echo "scale=2; $speed/1000000" | bc) Mbps"
    else
        echo "$(echo "scale=2; $speed/1000" | bc) Kbps"
    fi
}

# Format bytes to human-readable
format_bytes() {
    local bytes=$1
    if [ $bytes -gt 1073741824 ]; then
        echo "$(echo "scale=2; $bytes/1073741824" | bc) GB"
    elif [ $bytes -gt 1048576 ]; then
        echo "$(echo "scale=2; $bytes/1048576" | bc) MB"
    elif [ $bytes -gt 1024 ]; then
        echo "$(echo "scale=2; $bytes/1024" | bc) KB"
    else
        echo "$bytes B"
    fi
}

# Display header
print_header() {
    echo -e "${BLUE}=== Network Performance Monitor ===${NC}"
    echo -e "${BLUE}Press Ctrl+C to exit${NC}\n"
    date '+%Y-%m-%d %H:%M:%S'
    echo "----------------------------------------"
}

# Display bandwidth metrics
show_bandwidth() {
    echo -e "\n${GREEN}Bandwidth Metrics:${NC}"
    for interface in "${INTERFACES[@]}"; do
        local stats=$(cat "$DATA_DIR/current_metrics.json" | jq ".bandwidth_metrics | select(.interface == \"$interface\")")
        echo -e "Interface: $interface"
        echo -e "Download: $(format_speed $(echo "$stats" | jq '.download_speed'))"
        echo -e "Upload: $(format_speed $(echo "$stats" | jq '.upload_speed'))"
        echo -e "Speed Ratio: $(echo "$stats" | jq '.speed_ratio_to_advertised')x advertised"
    done
}

# Display latency metrics
show_latency() {
    echo -e "\n${GREEN}Latency Metrics:${NC}"
    local latency=$(cat "$DATA_DIR/current_metrics.json" | jq '.latency_metrics')
    for server in $(echo "$latency" | jq -r '.server'); do
        echo -e "Server: $server"
        echo -e "  RTT: $(echo "$latency" | jq ".rtt_avg") ms"
        echo -e "  Jitter: $(echo "$latency" | jq ".jitter") ms"
    done
}

# Display connection stability
show_stability() {
    echo -e "\n${GREEN}Connection Stability:${NC}"
    local stability=$(cat "$DATA_DIR/current_metrics.json" | jq '.stability_metrics')
    local uptime=$(echo "$stability" | jq '.uptime_percentage')
    echo -e "Uptime: $uptime%"
    
    if [ $(echo "$stability" | jq '.current_status') -eq 0 ]; then
        echo -e "Status: ${GREEN}Connected${NC}"
    else
        echo -e "Status: ${RED}Disconnected${NC}"
        echo -e "Interruption Duration: $(echo "$stability" | jq '.interruption_duration') seconds"
    fi
}

# Display network quality
show_network_quality() {
    echo -e "\n${GREEN}Network Quality:${NC}"
    for interface in "${INTERFACES[@]}"; do
        local quality=$(cat "$DATA_DIR/current_metrics.json" | jq ".network_quality | select(.interface == \"$interface\")")
        echo -e "Interface: $interface"
        echo -e "Signal Strength: $(echo "$quality" | jq '.signal_strength') dBm"
        echo -e "SNR: $(echo "$quality" | jq '.snr') dB"
        echo -e "Band: $(echo "$quality" | jq '.freq_band') GHz"
    done
}

# Display interface details
show_interface_details() {
    echo -e "\n${GREEN}Interface Details:${NC}"
    for interface in "${INTERFACES[@]}"; do
        local metrics=$(cat "$DATA_DIR/current_metrics.json" | jq ".interface_metrics | select(.interface == \"$interface\")")
        
        echo -e "\n${YELLOW}$interface:${NC}"
        echo -e "Hardware Configuration:"
        echo -e "  Speed: $(echo "$metrics" | jq -r '.speed') Mbps"
        echo -e "  Duplex: $(echo "$metrics" | jq -r '.duplex')"
        echo -e "  MTU: $(echo "$metrics" | jq -r '.mtu')"
        echo -e "  Queue Length: $(echo "$metrics" | jq -r '.queue_length')"
        echo -e "  Port Type: $(echo "$metrics" | jq -r '.port_type')"
        
        echo -e "\nPower Management:"
        echo -e "  Power Management: $(echo "$metrics" | jq -r '.power_management')"
        echo -e "  EEE Status: $(echo "$metrics" | jq -r '.eee_status')"
        
        echo -e "\nHardware Offload Features:"
        echo -e "  RX Checksumming: $(echo "$metrics" | jq -r '.rx_checksumming')"
        echo -e "  TX Checksumming: $(echo "$metrics" | jq -r '.tx_checksumming')"
        echo -e "  Scatter-Gather: $(echo "$metrics" | jq -r '.scatter_gather')"
        echo -e "  TCP Segmentation: $(echo "$metrics" | jq -r '.tcp_segmentation')"
        
        echo -e "\nTraffic Statistics:"
        echo -e "  RX Bytes: $(format_bytes $(echo "$metrics" | jq '.rx_bytes'))"
        echo -e "  TX Bytes: $(format_bytes $(echo "$metrics" | jq '.tx_bytes'))"
        echo -e "  RX Packets: $(echo "$metrics" | jq '.rx_packets')"
        echo -e "  TX Packets: $(echo "$metrics" | jq '.tx_packets')"
        echo -e "  RX Errors: $(echo "$metrics" | jq '.rx_errors')"
        echo -e "  TX Errors: $(echo "$metrics" | jq '.tx_errors')"
        echo -e "  RX Dropped: $(echo "$metrics" | jq '.rx_dropped')"
        echo -e "  TX Dropped: $(echo "$metrics" | jq '.tx_dropped')"
        
        echo -e "\nBonding:"
        echo -e "  Bond Status: $(echo "$metrics" | jq -r '.bond_status')"
        echo -e "  Auto-Negotiation: $(echo "$metrics" | jq -r '.auto_negotiation')"
    done
}

# Display security metrics
show_security() {
    echo -e "\n${GREEN}Security Metrics:${NC}"
    local security=$(cat "$DATA_DIR/current_metrics.json" | jq '.security_metrics')
    echo -e "Suspicious Connections: $(echo "$security" | jq '.suspicious_connections')"
    echo -e "Potential Scans: $(echo "$security" | jq '.potential_scans')"
    echo -e "RX Errors: $(echo "$security" | jq '.rx_errors')"
    echo -e "TX Errors: $(echo "$security" | jq '.tx_errors')"
}

# Main display loop
main() {
    while true; do
        clear_screen
        print_header
        show_bandwidth
        show_latency
        show_stability
        show_network_quality
        show_interface_details
        show_security
        sleep $REFRESH_RATE
    done
}

# Handle Ctrl+C gracefully
trap 'echo -e "\n${YELLOW}Exiting...${NC}"; exit 0' SIGINT SIGTERM

# Start the display
main
