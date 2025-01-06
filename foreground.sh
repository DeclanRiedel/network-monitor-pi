#!/bin/bash

# ANSI color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Spinner characters for update indication
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spinner_idx=0

# Terminal control sequences
SAVE_CURSOR='\033[s'
RESTORE_CURSOR='\033[u'
MOVE_TO='\033[%d;%dH'
CLEAR_LINE='\033[K'

# Get terminal size
TERM_ROWS=$(tput lines)
TERM_COLS=$(tput cols)

# Calculate split screen positions
LEFT_WIDTH=$((TERM_COLS/2 - 1))
RIGHT_START=$((LEFT_WIDTH + 3))
TOP_HEIGHT=$((TERM_ROWS/2))

get_spinner() {
    echo "${SPINNER[$((spinner_idx % 10))]}"
    spinner_idx=$((spinner_idx + 1))
}

clear_section() {
    local start_row=$1
    local start_col=$2
    local height=$3
    local width=$4
    
    for ((i=0; i<height; i++)); do
        printf "${MOVE_TO}${CLEAR_LINE}" $((start_row + i)) "$start_col"
    done
}

draw_borders() {
    clear
    # Draw horizontal line in the middle
    printf "${MOVE_TO}" "$TOP_HEIGHT" 0
    printf '%*s' "$TERM_COLS" '' | tr ' ' '-'
    
    # Draw vertical line in the middle
    for ((i=0; i<TERM_ROWS; i++)); do
        printf "${MOVE_TO}|" "$i" "$LEFT_WIDTH"
    done
}

update_bandwidth_metrics() {
    local spinner=$(get_spinner)
    clear_section 1 1 $((TOP_HEIGHT-1)) "$LEFT_WIDTH"
    
    printf "${MOVE_TO}" 1 1
    echo -e "${BLUE}=== Bandwidth Metrics === ${YELLOW}$spinner${NC}"
    
    # Pre-allocate space with empty lines
    for ((i=0; i<6; i++)); do
        printf "${MOVE_TO}%${LEFT_WIDTH}s" $((i+2)) 1 ""
    done
    
    printf "${MOVE_TO}" 2 1
    if ! speedtest_result=$(speedtest-cli --simple); then
        echo -e "${RED}Failed to get speedtest results${NC}"
    else
        echo "$speedtest_result"
    fi
}

update_latency_metrics() {
    local spinner=$(get_spinner)
    clear_section 1 "$RIGHT_START" $((TOP_HEIGHT-1)) "$LEFT_WIDTH"
    
    printf "${MOVE_TO}" 1 "$RIGHT_START"
    echo -e "${BLUE}=== Latency Metrics === ${YELLOW}$spinner${NC}"
    
    # Pre-allocate space
    for ((i=0; i<6; i++)); do
        printf "${MOVE_TO}%${LEFT_WIDTH}s" $((i+2)) "$RIGHT_START" ""
    done
    
    printf "${MOVE_TO}" 2 "$RIGHT_START"
    if ! gateway=$(ip route | grep default | awk '{print $3}'); then
        echo -e "${RED}Failed to determine gateway${NC}"
    else
        echo -e "${YELLOW}Local Ping (Gateway):${NC}"
        ping -c 1 "$gateway" | tail -n 1
        echo -e "\n${YELLOW}Remote Ping (Google DNS):${NC}"
        ping -c 1 8.8.8.8 | tail -n 1
    fi
}

update_connection_stability() {
    local spinner=$(get_spinner)
    clear_section $((TOP_HEIGHT+1)) 1 $((TERM_ROWS-TOP_HEIGHT-2)) "$LEFT_WIDTH"
    
    printf "${MOVE_TO}" $((TOP_HEIGHT+1)) 1
    echo -e "${BLUE}=== Connection Stability === ${YELLOW}$spinner${NC}"
    
    # Pre-allocate space
    for ((i=0; i<6; i++)); do
        printf "${MOVE_TO}%${LEFT_WIDTH}s" $((TOP_HEIGHT+2+i)) 1 ""
    done
    
    printf "${MOVE_TO}" $((TOP_HEIGHT+2)) 1
    echo -e "${YELLOW}Interface Status:${NC}"
    ethtool eth0 | grep "Link detected"
    echo -e "\n${YELLOW}Packet Loss Test:${NC}"
    ping -c 3 8.8.8.8 | grep "packet loss"
}

update_routing_metrics() {
    local spinner=$(get_spinner)
    clear_section $((TOP_HEIGHT+1)) "$RIGHT_START" $((TERM_ROWS-TOP_HEIGHT-2)) "$LEFT_WIDTH"
    
    printf "${MOVE_TO}" $((TOP_HEIGHT+1)) "$RIGHT_START"
    echo -e "${BLUE}=== Routing Performance === ${YELLOW}$spinner${NC}"
    
    # Pre-allocate space
    for ((i=0; i<6; i++)); do
        printf "${MOVE_TO}%${LEFT_WIDTH}s" $((TOP_HEIGHT+2+i)) "$RIGHT_START" ""
    done
    
    printf "${MOVE_TO}" $((TOP_HEIGHT+2)) "$RIGHT_START"
    echo -e "${YELLOW}Path to Google DNS:${NC}"
    traceroute -n -w 1 8.8.8.8 | head -n 4
}

update_protocol_metrics() {
    local spinner=$(get_spinner)
    local start_row=$((TERM_ROWS-8))
    clear_section "$start_row" $((TERM_COLS/4)) 6 $((TERM_COLS/2))
    
    printf "${MOVE_TO}" "$start_row" $((TERM_COLS/4))
    echo -e "${BLUE}=== Protocol Metrics === ${YELLOW}$spinner${NC}"
    
    # Pre-allocate space
    for ((i=0; i<4; i++)); do
        printf "${MOVE_TO}%${TERM_COLS/2}s" $((start_row+1+i)) $((TERM_COLS/4)) ""
    done
    
    printf "${MOVE_TO}" $((start_row+1)) $((TERM_COLS/4))
    echo -e "${YELLOW}TCP Connections:${NC} $(netstat -tn | grep ESTABLISHED | wc -l)"
    echo -e "${YELLOW}Current Connections:${NC}"
    ss -s | head -n 2
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
