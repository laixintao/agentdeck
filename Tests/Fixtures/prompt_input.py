"""A raw TUI prompt with bracketed paste and a post-typing Enter suppression window."""
import json
import os
from pathlib import Path
import sys
import termios
import time
import tty

destination = Path(sys.argv[1])
original = termios.tcgetattr(sys.stdin.fileno())
text = bytearray()
pending = bytearray()
pasting = False
last_text = 0.0
paste_count = 0
try:
    tty.setraw(sys.stdin.fileno())
    os.write(sys.stdout.fileno(), b"\x1b[?2004hprompt-ready\r\n")
    while True:
        pending.extend(os.read(sys.stdin.fileno(), 4096))
        while pending:
            if pending.startswith(b"\x1b"):
                if len(pending) < 6:
                    break
                marker = bytes(pending[:6])
                del pending[:6]
                if marker == b"\x1b[200~":
                    pasting = True
                    paste_count += 1
                elif marker == b"\x1b[201~":
                    pasting = False
                else:
                    raise ValueError("Unexpected terminal escape")
                continue
            char = pending.pop(0)
            if char in (10, 13):
                if pasting or time.monotonic() - last_text < 0.12:
                    text.extend(b"\n")
                else:
                    destination.write_text(json.dumps({"message": text.decode(), "pastes": paste_count}))
                    os.write(sys.stdout.fileno(), b"submitted\r\n")
                    sys.exit(0)
            else:
                text.append(char)
                last_text = time.monotonic()
finally:
    os.write(sys.stdout.fileno(), b"\x1b[?2004l")
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)
