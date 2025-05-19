#!/bin/bash

# At the top of your script
trap "echo 'Cleaning up...'; kill 0; exit" INT TERM EXIT

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

# position values
live_stats_top=4   # one row below "# live stats:"
live_stats_left=4  # inside the box, indented slightly

# Terminal dimensions
rows=$(tput lines)
cols=$(tput cols)

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
title="Network Monitor"
tput cup 1 2
echo "$title"

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

    echo -ne "${white}"
    tput cup $((rows - 2)) 2
    #tput cup $((rows - 2)) $(((cols - ${#status_line}) ))
    echo "$status_line"

    sleep 1
done
) &


# live stats panel 
(
while true; do
    ping_val=$(ping -c1 -W1 1.1.1.1 | grep 'time=' | sed -E 's/.*time=([0-9.]+).*/\1 ms/')
    jitter_val=$(ping -c 5 -i 0.2 1.1.1.1 | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; sumsq+=$1*$1} END {n=NR; if (n>1) {mean=sum/n; stddev=sqrt(sumsq/n - mean^2); printf "%.2f\n", stddev} else {print "N/A"}}')
    loss_val=$(ping -c 4 -W1 1.1.1.1 | grep -oP '\d+(?=% packet loss)')

    # Choose color based on threshold
    if [ "$loss_val" -eq 0 ]; then
        color_packloss=$green
    elif [ "$loss_val" -le 5 ]; then
        color_packloss=$yellow
    else
        color_packloss=$red
    fi

      tput cup $((live_stats_top)) $live_stats_left
    printf "ping:   %-6s" "${ping_val:-N/A}"

    tput cup $((live_stats_top + 1)) $live_stats_left
    printf "jitter: %-6s" "${jitter_val}ms"  

    tput cup $((live_stats_top + 2)) $live_stats_left
    echo -ne "loss:  ${color_packloss}${loss_val}%${reset}"
done 
) 





