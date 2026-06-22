import os
import sys
import socket
import fcntl

PORTS_FILE = "/tmp/cerebro-ports"

def is_port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.1)
        try:
            s.connect(('127.0.0.1', port))
            return True
        except (ConnectionRefusedError, TimeoutError, OSError):
            return False

def main():
    if len(sys.argv) < 2:
        print("Usage: reserve_orchestrator_port.py <session_dir>", file=sys.stderr)
        sys.exit(1)

    session_dir = sys.argv[1]

    # Create file if it doesn't exist
    if not os.path.exists(PORTS_FILE):
        open(PORTS_FILE, 'a').close()

    # We need an exclusive lock to avoid race conditions
    with open(PORTS_FILE, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        
        try:
            # Read all lines
            f.seek(0)
            lines = f.readlines()
            
            valid_entries = []
            used_ports = set()
            
            for line in lines:
                parts = line.strip().split()
                if len(parts) >= 3:
                    session_id = parts[0]
                    port_str = parts[-1]
                    s_dir = " ".join(parts[1:-1])
                    try:
                        port = int(port_str)
                    except ValueError:
                        continue
                    
                    if is_port_in_use(port):
                        valid_entries.append((session_id, s_dir, port))
                        used_ports.add(port)
            
            # Find first free port >= 8100
            port = 8100
            while port in used_ports or is_port_in_use(port):
                port += 1
            
            # Append new entry
            valid_entries.append(('pending', session_dir, port))
            
            # Write back
            f.seek(0)
            f.truncate()
            for entry in valid_entries:
                f.write(f"{entry[0]} {entry[1]} {entry[2]}\n")
            
            # Flush changes before unlocking
            f.flush()
            
            print(port)
            
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

if __name__ == "__main__":
    main()
