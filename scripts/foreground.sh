#!/bin/bash

# Get terminal size
rows=$(tput lines)
cols=$(tput cols)

# Set color to white (ANSI white = 7)
tput setaf 7

# Draw outer border
for ((i=0; i<cols; i++)); do
    tput cup 0 $i; printf "─"
    tput cup $((rows-1)) $i; printf "─"
done

for ((i=0; i<rows; i++)); do
    tput cup $i 0; printf "│"
    tput cup $i $((cols-1)); printf "│"
done

tput cup 0 0; printf "┌"
tput cup 0 $((cols-1)); printf "┐"
tput cup $((rows-1)) 0; printf "└"
tput cup $((rows-1)) $((cols-1)); printf "┘"

# Section sizes (approximate)
sec1_w=$((cols / 4))
sec2_w=$((cols / 4))
sec3_w=$((cols / 4))
sec4_w=$((cols - sec1_w - sec2_w - sec3_w - 6)) # remaining space
sec_h=$((rows / 2 - 2))
graph_h=$((rows - sec_h - 5))

# Coordinates
top_margin=2
left_margin=2

# Draw boxes
draw_box() {
    local top=$1
    local left=$2
    local height=$3
    local width=$4

    # Top border
    for ((i=0; i<width; i++)); do
        tput cup $top $((left+i)); printf "─"
    done

    # Bottom border
    for ((i=0; i<width; i++)); do
        tput cup $((top+height-1)) $((left+i)); printf "─"
    done

    # Left & right
    for ((i=1; i<height-1; i++)); do
        tput cup $((top+i)) $left; printf "│"
        tput cup $((top+i)) $((left+width-1)); printf "│"
    done

    # Corners
    tput cup $top $left; printf "┌"
    tput cup $top $((left+width-1)); printf "┐"
    tput cup $((top+height-1)) $left; printf "└"
    tput cup $((top+height-1)) $((left+width-1)); printf "┘"
}

# Draw 3 top boxes
draw_box $top_margin $left_margin $sec_h $sec1_w
draw_box $top_margin $((left_margin + sec1_w + 1)) $sec_h $sec2_w
draw_box $top_margin $((left_margin + sec1_w + sec2_w + 2)) $sec_h $sec3_w

# Draw large right box
draw_box $top_margin $((left_margin + sec1_w + sec2_w + sec3_w + 3)) $((rows - 4)) $sec4_w

# Draw bottom graph box
draw_box $((top_margin + sec_h + 1)) $left_margin $graph_h $((cols - sec4_w - 6))

# Add labels (orange color)
tput setaf 3
tput cup $((top_margin)) $((left_margin + 2)); echo "# live stats:"
tput cup $((top_margin)) $((left_margin + sec1_w + 3)); echo "# connection info"
tput cup $((top_margin)) $((left_margin + sec1_w + sec2_w + 4)); echo "# averages"
tput cup $((top_margin)) $((left_margin + sec1_w + sec2_w + sec3_w + 5)); echo "# issues"
tput cup $((top_margin + sec_h + 2)) $((left_margin + 2)); echo "# graph"

# Reset color
tput sgr0

