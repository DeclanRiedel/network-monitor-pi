#!/bin/bash

# ANSI color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Terminal control sequences
SAVE_CURSOR='\033[s'
RESTORE_CURSOR='\033[u'
MOVE_TO='\033[%d;%dH'

# Get terminal size
TERM_ROWS=$(tput lines)
TERM_COLS=$(tput cols)

# Calculate split screen positions
LEFT_WIDTH=$((TERM_COLS/2))
RIGHT_WIDTH=$((TERM_COLS/2))
TOP_HEIGHT=$((TERM_ROWS/2))
BOTTOM_HEIGHT=$((TERM_ROWS/2))

log_error() {
    local row=$((TERM_ROWS-1))
    printf "${MOVE_TO}${RED}ERROR: %s${NC}" "$row" 0 "$1"
    sleep 2
}

draw_borders() {
    clear
    # Draw horizontal line in the middle
    printf "${MOVE_TO}" $((TOP_HEIGHT)) 0
    printf '%*s' "$TERM_COLS" '' | tr ' ' '-'
    
    # Draw vertical line in the middle
    for ((i=0; i<TERM_ROWS; i++)); do
        printf "${MOVE_TO}|" "$i" "$LEFT_WIDTH"
    done
}

update_bandwidth_metrics() {
    printf "${MOVE_TO}" 1 1
    echo -e "${BLUE}=== Bandwidth Metrics ===${NC}"
    
    if ! speedtest_result=$(speedtest-cli --simple); then
        echo -e "${RED}Failed to get speedtest results${NC}"
    else
        echo "$speedtest_result"
    fi
    
    echo -e "\n${BLUE}Network Load:${NC}"
    if ! netstat -i &>/dev/null; then
        echo -e "${RED}Failed to get network interface statistics${NC}"
    else
        netstat -i | head -n 2
        netstat -i | grep eth0 || echo -e "${RED}eth0 interface not found${NC}"
    fi
}

update_latency_metrics() {
    printf "${MOVE_TO}" 1 $((LEFT_WIDTH+2))
    echo -e "${BLUE}=== Latency Metrics ===${NC}"
    
    echo -e "${YELLOW}Local Ping (Gateway):${NC}"
    if ! gateway=$(ip route | grep default | awk '{print $3}'); then
        echo -e "${RED}Failed to determine gateway${NC}"
    else
        ping -c 3 $gateway | tail -n 1 || echo -e "${RED}Failed to ping gateway${NC}"
    fi
    
    echo -e "\n${YELLOW}Remote Ping (Google DNS):${NC}"
    ping -c 3 8.8.8.8 | tail -n 1 || echo -e "${RED}Failed to ping Google DNS${NC}"
}

update_connection_stability() {
    printf "${MOVE_TO}" $((TOP_HEIGHT+1)) 1
    echo -e "${BLUE}=== Connection Stability ===${NC}"
    echo -e "${YELLOW}Interface Status:${NC}"
    ethtool eth0 | grep "Link detected"
    
    echo -e "\n${YELLOW}Packet Loss Test:${NC}"
    ping -c 10 8.8.8.8 | grep "packet loss"
}

update_routing_metrics() {
    printf "${MOVE_TO}" $((TOP_HEIGHT+1)) $((LEFT_WIDTH+2))
    echo -e "${BLUE}=== Routing Performance ===${NC}"
    echo -e "${YELLOW}Path to Google DNS:${NC}"
    traceroute -n -w 1 8.8.8.8 | head -n 5
}

update_protocol_metrics() {
    # Calculate position for protocol metrics (bottom center)
    local start_row=$((TERM_ROWS-10))
    printf "${MOVE_TO}" "$start_row" $((LEFT_WIDTH/2))
    echo -e "${BLUE}=== Protocol Metrics ===${NC}"
    echo -e "${YELLOW}TCP Connections:${NC}"
    netstat -tn | grep ESTABLISHED | wc -l
    
    echo -e "\n${YELLOW}Current Connections:${NC}"
    ss -s | head -n 3
}

update_header() {
    printf "${MOVE_TO}" 0 0
    echo -e "${GREEN}=== Network Performance Monitor === (Press Ctrl+C to exit)${NC}"
    echo -e "Last update: $(date '+%Y-%m-%d %H:%M:%S')"
}

# Trap cleanup for graceful exit
cleanup() {
    clear
    tput cnorm  # Show cursor
    exit 0
}
trap cleanup EXIT
trap cleanup SIGINT
trap cleanup SIGTERM

# Initialize display
tput civis  # Hide cursor
draw_borders

# Main display loop
while true; do
    update_header
    update_bandwidth_metrics &
    update_latency_metrics &
    update_connection_stability &
    update_routing_metrics &
    update_protocol_metrics &
    wait
    sleep 5
done
