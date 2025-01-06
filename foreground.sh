#!/bin/bash

# ANSI color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Display rotation counter
current_display=1
max_displays=5

display_bandwidth_metrics() {
    echo -e "${BLUE}=== Bandwidth Metrics ===${NC}"
    speedtest_result=$(speedtest-cli --simple)
    echo "$speedtest_result"
    
    echo -e "\n${BLUE}Network Load:${NC}"
    netstat -i | head -n 2
    netstat -i | grep eth0
}

display_latency_metrics() {
    echo -e "${BLUE}=== Latency Metrics ===${NC}"
    echo -e "${YELLOW}Local Ping (Gateway):${NC}"
    gateway=$(ip route | grep default | awk '{print $3}')
    ping -c 3 $gateway | tail -n 1
    
    echo -e "\n${YELLOW}Remote Ping (Google DNS):${NC}"
    ping -c 3 8.8.8.8 | tail -n 1
    
    echo -e "\n${YELLOW}Average RTT:${NC}"
    mtr -n --report 8.8.8.8 | tail -n 1
}

display_connection_stability() {
    echo -e "${BLUE}=== Connection Stability ===${NC}"
    echo -e "${YELLOW}Interface Status:${NC}"
    ethtool eth0 | grep "Link detected"
    
    echo -e "\n${YELLOW}Packet Loss Test:${NC}"
    ping -c 10 8.8.8.8 | grep "packet loss"
}

display_routing_metrics() {
    echo -e "${BLUE}=== Routing Performance ===${NC}"
    echo -e "${YELLOW}Path to Google DNS:${NC}"
    traceroute -n -w 1 8.8.8.8 | head -n 5
}

display_protocol_metrics() {
    echo -e "${BLUE}=== Protocol Metrics ===${NC}"
    echo -e "${YELLOW}TCP Connections:${NC}"
    netstat -tn | grep ESTABLISHED | wc -l
    
    echo -e "\n${YELLOW}Current Connections:${NC}"
    ss -s | head -n 3
}

rotate_display() {
    clear
    echo -e "${GREEN}=== Network Performance Monitor ===${NC}"
    echo -e "Display $current_display of $max_displays\n"
    
    case $current_display in
        1) display_bandwidth_metrics ;;
        2) display_latency_metrics ;;
        3) display_connection_stability ;;
        4) display_routing_metrics ;;
        5) display_protocol_metrics ;;
    esac
    
    current_display=$((current_display % max_displays + 1))
}

# Main display loop
while true; do
    rotate_display
    sleep 5
done
