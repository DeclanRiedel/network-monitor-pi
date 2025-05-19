## Overall breakdown

there will be a foreground and background script running independetly. The foreground script will contain a cli with potentially ncurses and the background script will run with no cli and record the data to a sqlite3 database.

### Dependencies:

sqlite3, ping, 


# checklists: foreground/background

## Foreground script checklist.
- [ ] ping
- [ ] jitter
- [ ] download speed
- [ ] upload speed
- [ ] packet loss
- [ ] retransmissions
- [ ] RTT
- [ ] TCP Conn time
- [ ] DNS Lookup time
- [ ] TLS Handshake time
- [ ] session duration, record connection drops counter
- [ ] 

### live panel:
- ping
- jitter
-  packet loss
- download
- upload
- RSSI (if connected)
- cpu load
- memory usage
- ps aux

## tput

| Code | Color   |
| ---- | ------- |
| 0    | Black   |
| 1    | Red     |
| 2    | Green   |
| 3    | Yellow  |
| 4    | Blue    |
| 5    | Magenta |
| 6    | Cyan    |
| 7    | White   |


## Background script checklist.
