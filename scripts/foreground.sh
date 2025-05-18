#!/bin/bash

while true; do
  tput clear

  tput cup 0 10
  tput bold
  echo "📡 NETMON DASHBOARD ($(date +%H:%M:%S))"
  tput sgr0

  # Ping
  ping_result=$(ping -c 1 1.1.1.1 | grep time= | awk -F"time=" '{print $2}' | cut -d" " -f1)
  tput cup 2 2
  echo "Ping: ${ping_result:-N/A} ms"

  # Download Speed
  down_speed=$(speedtest-cli --simple | grep "Download" | awk '{print $2 " " $3}')
  tput cup 3 2
  echo "Download Speed: ${down_speed:-N/A}"

  # Upload Speed
  up_speed=$(speedtest-cli --simple | grep "Upload" | awk '{print $2 " " $3}')
  tput cup 4 2
  echo "Upload Speed: ${up_speed:-N/A}"

  # Signal Strength (Wi-Fi only)
  signal=$(iw dev wlan0 link | grep signal | awk '{print $2 " " $3}')
  tput cup 5 2
  echo "Signal Strength: ${signal:-N/A}"

  sleep 5
done

