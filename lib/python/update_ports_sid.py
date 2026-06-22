import os
import sys
import fcntl

PORTS_FILE = "/tmp/cerebro-ports"

def main():
    if len(sys.argv) < 3:
        print("Usage: update_ports_sid.py <session_dir> <sid>", file=sys.stderr)
        sys.exit(1)

    session_dir = sys.argv[1]
    sid = sys.argv[2]

    if not os.path.exists(PORTS_FILE):
        return

    # We need an exclusive lock to avoid race conditions
    with open(PORTS_FILE, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        
        try:
            # Read all lines
            f.seek(0)
            lines = f.readlines()
            
            updated_lines = []
            
            for line in lines:
                parts = line.strip().split()
                if len(parts) >= 3 and parts[0] == "pending":
                    s_dir = " ".join(parts[1:-1])
                    if s_dir == session_dir:
                        # Replace 'pending' with the real sid
                        parts[0] = sid
                        updated_lines.append(" ".join(parts) + "\n")
                        continue
                
                updated_lines.append(line)
            
            # Write back
            f.seek(0)
            f.truncate()
            f.writelines(updated_lines)
            
            # Flush changes before unlocking
            f.flush()
            
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

if __name__ == "__main__":
    main()
