#!/usr/bin/env python3
import curses
import time
import subprocess
import threading
import json
from datetime import datetime

class NetworkMonitor:
    def __init__(self, stdscr):
        self.screen = stdscr
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_BLUE, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_RED, -1)
        
        self.GREEN = curses.color_pair(1)
        self.BLUE = curses.color_pair(2)
        self.YELLOW = curses.color_pair(3)
        self.RED = curses.color_pair(4)
        
        self.spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
        self.spinner_idx = 0
        
        # Initialize data containers
        self.bandwidth_data = {"status": "Initializing...", "data": None}
        self.latency_data = {"status": "Initializing...", "data": None}
        self.stability_data = {"status": "Initializing...", "data": None}
        self.routing_data = {"status": "Initializing...", "data": None}
        self.protocol_data = {"status": "Initializing...", "data": None}
        
        # Start update threads
        self.running = True
        self.threads = []
        self.start_update_threads()

    def get_spinner(self):
        char = self.spinner[self.spinner_idx]
        self.spinner_idx = (self.spinner_idx + 1) % len(self.spinner)
        return char

    def draw_borders(self):
        max_y, max_x = self.screen.getmaxyx()
        mid_y, mid_x = max_y // 2, max_x // 2

        # Draw horizontal lines
        for x in range(max_x):
            self.screen.addch(mid_y, x, curses.ACS_HLINE)
        
        # Draw vertical line
        for y in range(max_y):
            self.screen.addch(y, mid_x, curses.ACS_VLINE)
        
        # Draw intersections
        self.screen.addch(mid_y, mid_x, curses.ACS_PLUS)

    def update_bandwidth(self):
        while self.running:
            self.bandwidth_data["status"] = "Updating..."
            try:
                result = subprocess.run(['speedtest-cli', '--simple'], 
                                     capture_output=True, text=True)
                self.bandwidth_data["data"] = result.stdout
                self.bandwidth_data["status"] = "OK"
            except Exception as e:
                self.bandwidth_data["status"] = f"Error: {str(e)}"
            time.sleep(300)  # Update every 5 minutes

    def update_latency(self):
        while self.running:
            self.latency_data["status"] = "Updating..."
            try:
                ping = subprocess.run(['ping', '-c', '3', '8.8.8.8'], 
                                   capture_output=True, text=True)
                self.latency_data["data"] = ping.stdout
                self.latency_data["status"] = "OK"
            except Exception as e:
                self.latency_data["status"] = f"Error: {str(e)}"
            time.sleep(5)

    def draw_panel(self, title, data, y, x, height, width):
        spinner = self.get_spinner() if data["status"] == "Updating..." else " "
        status_color = self.GREEN if data["status"] == "OK" else self.RED
        
        # Draw title
        self.screen.addstr(y, x, f"=== {title} === ", self.BLUE)
        self.screen.addstr(f"{spinner}", self.YELLOW)
        self.screen.addstr(f"[{data['status']}]", status_color)
        
        # Draw data
        if data["data"]:
            lines = str(data["data"]).split('\n')
            for i, line in enumerate(lines[:height-2]):
                if y + i + 1 < height:
                    self.screen.addstr(y + i + 1, x, line[:width-2])

    def draw_screen(self):
        self.screen.clear()
        max_y, max_x = self.screen.getmaxyx()
        mid_y, mid_x = max_y // 2, max_x // 2
        
        self.draw_borders()
        
        # Draw title
        title = "Network Performance Monitor"
        self.screen.addstr(0, (max_x - len(title)) // 2, title, self.GREEN | curses.A_BOLD)
        
        # Draw panels
        self.draw_panel("Bandwidth", self.bandwidth_data, 2, 1, mid_y-1, mid_x-1)
        self.draw_panel("Latency", self.latency_data, 2, mid_x+1, mid_y-1, mid_x-1)
        self.draw_panel("Stability", self.stability_data, mid_y+1, 1, mid_y-1, mid_x-1)
        self.draw_panel("Routing", self.routing_data, mid_y+1, mid_x+1, mid_y-1, mid_x-1)
        
        # Draw timestamp
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.screen.addstr(max_y-1, 1, f"Last update: {timestamp}")
        
        self.screen.refresh()

    def start_update_threads(self):
        threads = [
            threading.Thread(target=self.update_bandwidth),
            threading.Thread(target=self.update_latency),
            # Add other update threads here
        ]
        for thread in threads:
            thread.daemon = True
            thread.start()
        self.threads = threads

    def run(self):
        try:
            while True:
                self.draw_screen()
                time.sleep(0.1)
        except KeyboardInterrupt:
            self.running = False
            for thread in self.threads:
                thread.join()

def main(stdscr):
    curses.curs_set(0)  # Hide cursor
    monitor = NetworkMonitor(stdscr)
    monitor.run()

if __name__ == "__main__":
    curses.wrapper(main)
