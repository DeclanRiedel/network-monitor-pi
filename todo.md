# foreground script
create averages values, complete issues tab, graph view, 








## throwaway notes
live panel:
ping
jitter
packetloss (in & out)
download
upload
Wi-Fi Signal Strength (RSSI) – iwconfig or iw dev
CPU Load – top / mpstat
Memory Usage – free -h
Active Processes – ps aux


# connection info
Wi-Fi Channel – iwlist wlan0 channel (return Not Connected if !Connected)
MAC Address – ip link 
SSID / BSSID – iw dev wlan0 link
Public IP – curl ifconfig.me
Network Type (e.g., Wi-Fi/Ethernet) – nmcli / ip a
ISP / Carrier Name – curl ipinfo.io/org

# averages	
ping
jitter
packet loss

Traceroute hop count	Can show extra/misrouted hops added by ISP.
#issues
ICMP Throttling	If pings are deprioritized, it may indicate shaping.
Route Fluctuation	Changes in traceroute route over time may suggest ISP instability or policy shifts.
#issues

DNS Resolution Time	Shows how long name resolution takes. Long times = slow or overloaded DNS servers.
TLS Handshake Time	Extended handshakes may indicate SSL inspection or inefficient routing.
TCP Connect Time	Delay establishing TCP = ISP routing/congestion issues.
Download/Upload Speed	Measures ISP’s delivered bandwidth compared to advertised rate.

## below might be included in TTFB
tcp connections (may indicate ISP routing issues)
dns resolution times (ISP dns server speed/efficiency)
tls handshake time: see if ISP does SSL inspection 

graph:(meant for game perf analytics)
ping
jitter (maybe?)

issues:
ping spikes
high jitter
retransmissions (tcp dump) count + timestamp latest
counter: out of order packets, dupe packets
counter: connection drops
spike in hop count -> indicates issue with routing/somebody's router



## side notes
does download upload graph tell us naything about perf that we can't interpolate from connection cuts/jitter etc?
what to test round trip delay on? MTC servers somehow?
gateway ip? does this matter to track? (static info, notice when 'not working')

for hop count & see issues with route continuously, use: mtr to see where issues arise




## problems
ipv6 not pasting
securtity not pasting
gateway pastes twice, once on wrong location
