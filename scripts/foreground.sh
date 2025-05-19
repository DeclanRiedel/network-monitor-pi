#!/bin/bash

# At the top of your script
trap "echo 'Cleaning up...'; kill 0; exit" INT TERM EXIT

# Create a lockfile for safe terminal drawing
lockfile="/tmp/term-draw.lock"
touch "$lockfile"

# Save original terminal settings & ensure cleanup on exit
cleanup() {
    tput cnorm        # Restore cursor
    stty "$saved_stty"
    tput sgr0
    clear
    exit
}
trap cleanup INT TERM

saved_stty=$(stty -g)
stty -echo -icanon time 0 min 0  # Disable input echo and buffering
tput civis                      # Hide cursor

clear




# Terminal dimensions
rows=$(tput lines)
cols=$(tput cols)
cpu_cores=$(nproc)

# averages
avg_ping=0
avg_jitter=0
avg_packet_loss=0
traceroute_hop_count=0
avg_dns_resolution_time=0
avg_tls_handshake_time=0
avg_tcp_connect_time=0
avg_down_speed=0
avg_upl_speed=0



# Colors
white=$(tput setaf 7)
orange=$(tput setaf 3)
blue=$(tput setaf 4)
red=$(tput setaf 1)
yellow=$(tput setaf 3)
green=$(tput setaf 2)
reset=$(tput sgr0)

# Draw outer border instantly
tput cup 0 0; printf "┌"
tput cup 0 $((cols-1)); printf "┐"
tput cup $((rows-1)) 0; printf "└"
tput cup $((rows-1)) $((cols-1)); printf "┘"

# Top & bottom edges
tput cup 0 1
printf '─%.0s' $(seq 1 $((cols - 2)))

tput cup $((rows - 1)) 1
printf '─%.0s' $(seq 1 $((cols - 2)))

# Left & right edges
for ((i=1; i<rows-1; i++)); do
    tput cup $i 0; printf "│"
    tput cup $i $((cols-1)); printf "│"
done

# Section sizes
sec1_w=$((cols / 4))
sec2_w=$((cols / 4))
sec3_w=$((cols / 4))
sec4_w=$((cols - sec1_w - sec2_w - sec3_w - 6))
sec_h=$((rows / 2 - 0))
graph_h=$((rows - sec_h - 6))  # leave one line for title

# Margins
top_margin=3
left_margin=2


# position values
live_stats_top=4   # one row below "# live stats:"
live_stats_left=4  # inside the box, indented slightly
conn_info_top=$((top_margin + 1))  # one row below the label
conn_info_left=$((left_margin + sec1_w + 3))  # same as the label's X position
avg_stats_top=$((top_margin +1))
avg_stats_left=$((left_margin + sec1_w + sec2_w + 3))


# Box drawing function (instant)
draw_box() {
    local top=$1
    local left=$2
    local height=$3
    local width=$4

    tput cup $top $left; printf "┌"; printf '─%.0s' $(seq 1 $((width-2))); printf "┐"
    tput cup $((top+height-1)) $left; printf "└"; printf '─%.0s' $(seq 1 $((width-2))); printf "┘"

    for ((i=1; i<height-1; i++)); do
        tput cup $((top+i)) $left; printf "│"
        tput cup $((top+i)) $((left+width-1)); printf "│"
    done
}

# Draw internal boxes
draw_box $top_margin $left_margin $sec_h $sec1_w
draw_box $top_margin $((left_margin + sec1_w + 1)) $sec_h $sec2_w
draw_box $top_margin $((left_margin + sec1_w + sec2_w + 2)) $sec_h $sec3_w
draw_box $top_margin $((left_margin + sec1_w + sec2_w + sec3_w + 3)) $((rows - 5)) $sec4_w
draw_box $((top_margin + sec_h + 1)) $left_margin $graph_h $((cols - sec4_w - 4))

# Section labels
echo -ne "${orange}"
tput cup $top_margin $((left_margin + 2)); echo "# live stats"
tput cup $top_margin $((left_margin + sec1_w + 3)); echo "# connection info"
tput cup $top_margin $((left_margin + sec1_w + sec2_w + 4)); echo "# averages"
tput cup $top_margin $((left_margin + sec1_w + sec2_w + sec3_w + 5)); echo "# issues"
tput cup $((top_margin + sec_h + 1)) $((left_margin + 2)); echo "# graph"

# Title (centered between border and boxes)
echo -ne "${white}"

isp=$(curl -s https://ipinfo.io/org | sed 's/^.*: //')
title="Network Monitor"
tput cup 1 2
echo "$title  |  $isp"

# Start timer
start_time=$(date +%s)

#wait Main display loop + static border
(
while true; do
    now=$(date +%s)
    elapsed=$((now - start_time))
    hrs=$((elapsed / 3600))
    mins=$(((elapsed % 3600) / 60))
    secs=$((elapsed % 60))



    uptime_text=$(printf "Session uptime: %02d:%02d:%02d" $hrs $mins $secs)
    background="Background script running: false"
    status_line="$uptime_text    |    $background    |    Press Ctrl+C to exit"


{
flock 200	
    echo -ne "${white}"
    tput cup $((rows - 2)) 2
    #tput cup $((rows - 2)) $(((cols - ${#status_line}) ))
    echo "$status_line"

} 200>"$lockfile"
    sleep 1

done
) &


# live stats panel - ping, jitter, packetloss  
(
while true; do
    ping_val=$(ping -c1 -W1 1.1.1.1 | grep 'time=' | sed -E 's/.*time=([0-9.]+).*/\1/')
    jitter_val=$(ping -c 5 -i 0.2 1.1.1.1 | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; sumsq+=$1*$1} END {n=NR; if (n>1) {mean=sum/n; stddev=sqrt(sumsq/n - mean^2); printf "%.2f\n", stddev} else {print "N/A"}}')
    loss_val=$(ping -c 4 -W1 1.1.1.1 | grep -oP '\d+(?=% packet loss)')

    #ping avg



    # Choose color based on threshold
    if [ "$loss_val" -eq 0 ]; then
        color_packloss=$green
    elif [ "$loss_val" -le 5 ]; then
        color_packloss=$yellow
    else
        color_packloss=$red
    fi

     # Color for ping
    if [[ "$ping_val" == "N/A" ]]; then
        color_ping=$white
    elif (( $(echo "$ping_val > 100" | bc -l) )); then
        color_ping=$red
    elif (( $(echo "$ping_val > 30" | bc -l) )); then
        color_ping=$yellow
    else
        color_ping=$green
    fi

    # Color for jitter
    if [[ "$jitter_val" == "N/A" ]]; then
        color_jitter=$white
    elif (( $(echo "$jitter_val > 30" | bc -l) )); then
        color_jitter=$red
    elif (( $(echo "$jitter_val > 10" | bc -l) )); then
        color_jitter=$yellow
    else
        color_jitter=$green
    fi


{ flock 200
    tput cup $((live_stats_top)) $live_stats_left
    echo -ne "ping:   ${color_ping}$(printf %-6s "$ping_val") ms${reset}"

## averages compute but print else where? save refreshes
    tput cup $((avg_stats_top + 0)) $avg_stats_left
    echo -ne "avg ping:         ${avg_ping}"

    tput cup $((avg_stats_top + 1)) $avg_stats_left
    echo -ne "avg jitter:         ${avg_jitter}"

    tput cup $((avg_stats_top + 2)) $avg_stats_left
    echo -ne "avg loss:         ${avg_packet_loss}"

    tput cup $((avg_stats_top + 3)) $avg_stats_left
    echo -ne "avg hop count:         ${traceroute_hop_count}"

    tput cup $((avg_stats_top + 4)) $avg_stats_left
    echo -ne "avg dns res time:         ${avg_dns_resolution_time}"

    tput cup $((avg_stats_top + 5)) $avg_stats_left
    echo -ne "avg tls h time:         ${avg_tls_handshake_time}"
    
    tput cup $((avg_stats_top + 6)) $avg_stats_left
    echo -ne "avg tcp conn time:         ${avg_tcp_connect_time}"
	
    tput cup $((avg_stats_top + 7)) $avg_stats_left
    echo -ne "avg download:         ${avg_down_speed}"

    tput cup $((avg_stats_top + 8)) $avg_stats_left
    echo -ne "avg upload:         ${avg_upl_speed}"

##-----##

    tput cup $((live_stats_top + 1)) $live_stats_left
    echo -ne "jitter: ${color_jitter}$(printf %-6s "$jitter_val") ms${reset}"
    
    tput cup $((live_stats_top + 2)) $live_stats_left
    echo -ne "loss:  ${color_packloss}${loss_val}%${reset}"

} 200>"$lockfile"

sleep 0.5
done 
) &

(
while true; do
    # Download/Upload (dummy values from /proc/net/dev)
    download=$(awk '/wlan|eth/ {down += $2} END {print down}' /proc/net/dev)
    upload=$(awk '/wlan|eth/ {up += $10} END {print up}' /proc/net/dev)

    download_kbps=$((download / 1024))
    upload_kbps=$((upload / 1024))

    # RSSI (Wi-Fi signal strength)
    rssi=$(iwconfig 2>/dev/null | grep -i --color=never 'Signal level' | sed -n 's/.*Signal level=\([-0-9]*\).*/\1/p')

    # CPU Load
    cpu_load=$(awk '{print $1}' /proc/loadavg)

    # Memory Usage
    mem_usage=$(free -m | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')

    # Colors for CPU
    if (( $(echo "$cpu_load > 2.0" | bc -l) )); then
        cpu_color=$red
    elif (( $(echo "$cpu_load > 1.0" | bc -l) )); then
        cpu_color=$yellow
    else
        cpu_color=$green
    fi

    # Colors for Memory
    if (( mem_usage > 80 )); then
        mem_color=$red
    elif (( mem_usage > 60 )); then
        mem_color=$yellow
    else
        mem_color=$green
    fi

    # Colors for RSSI
    if [[ "$rssi" -lt -80 ]]; then
        rssi_color=$red
    elif [[ "$rssi" -lt -60 ]]; then
        rssi_color=$yellow
    else
        rssi_color=$green
    fi

	{ flock 200
    # Output positions starting from +3
    tput cup $((live_stats_top + 3)) $live_stats_left
    echo -ne "Download: ${green}${download_kbps:-0} KB/s${reset}"

    tput cup $((live_stats_top + 4)) $live_stats_left
    echo -ne "Upload:   ${green}${upload_kbps:-0} KB/s${reset}"

    tput cup $((live_stats_top + 5)) $live_stats_left
    echo -ne "RSSI:     ${rssi_color}${rssi:-N/A} dBm${reset}"

    tput cup $((live_stats_top + 6)) $live_stats_left
    echo -ne "CPU Load: ${cpu_color}${cpu_load}${reset} / ${cpu_cores} cores"
    
    tput cup $((live_stats_top + 7)) $live_stats_left
    echo -ne "Memory:   ${mem_color}${mem_usage}%${reset}"

} 200>"$lockfile"
    sleep 2
done
) &

(



while true; do
    interface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    if iw dev "$interface" info &>/dev/null; then
        ssid=$(iw dev "$interface" link | awk -F ': ' '/SSID/ {print $2}')
        ssid_display="${green}${ssid}${reset}"
    else
        ssid_display="${yellow}Wired${reset}"
    fi

    #bssid=$(iw dev "$interface" link | awk '/Connected to/ {print $3}')
#	channel=$(iw dev "$interface" info | awk '/channel/ {print $2}')
       speed=$(iw dev "$interface" link | awk '/tx bitrate/ {print $3, $4}')
        lan_ip=$(hostname -I | awk '{print $1}')
                public_ip=$(curl -s https://ifconfig.me)
        
#gateway=$(ip route | awk '/default/ {print $3}')
        dns_server=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
        dns_check=$(dig +short google.com @$dns_server >/dev/null && echo "✓" || echo "⚠")
   active_iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
	security=$(nmcli -f active,ssid,security dev wifi | grep '^yes' | awk '{print $3}')
    dhcp_expiry=$(sudo dhclient -v "$interface" 2>&1 | grep -i 'renew' | awk '{print $5, $6, $7}' | head -1)
    ipv6=$(ip -6 addr show "$interface" | awk '/inet6/ && !/fe80/ {print $2}' | cut -d/ -f1 | head -1)

{ flock 200;	
# Display
tput cup $((conn_info_top + 0)) $conn_info_left
echo -ne "SSID:         ${ssid_display}"

tput cup $((conn_info_top + 1)) $conn_info_left
echo -ne "Lan IP: ${green}${lan_ip}${reset}"

tput cup $((conn_info_top + 2)) $conn_info_left
echo -ne "Public IP:    ${green}${public_ip}${reset}"

tput cup $((conn_info_top + 3)) $conn_info_left
echo -ne "Conn Speed:         ${green}${speed}${reset}"

tput cup $((conn_info_top + 4)) $conn_info_left
echo -ne "ipv6:         ${ipv6}"

#tput cup $((conn_info_top + 5)) $conn_info_left
#echo -ne "channel:         ${channel}"

tput cup $((conn_info_top + 6)) $conn_info_left
echo -ne "dhcp_expiry:         ${dhcp_expiry}"

tput cup $((conn_info_top + 7)) $conn_info_left
echo -ne "security:         ${security}"

tput cup $((conn_info_top + 8)) $conn_info_left
echo -ne "iface:         ${active_iface}"


#tput cup $((conn_info_top + 9)) $conn_info_left
#echo -ne "gateway:         ${green}${gateway}${reset}"

tput cup $((conn_info_top + 10)) $conn_info_left
echo -ne "dns server:         ${dns_server}"

tput cup $((conn_info_top + 11)) $conn_info_left
echo -ne "dns check:         ${dns_check}"




} 200>"$lockfile"
sleep 1
done
) &


## averages section 
(
while true; do
	{ flock 200;
#tput cup $((avg_stats_top + 0)) $avg_stats_left
#echo -ne ":         ${ssid_display}"
} 200>"$lockfile"

sleep 1 
done
)



