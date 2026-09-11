#!/usr/bin/python3
"""whisper-stream's fixed-window stdout and SIGINT tail-drain contract."""
import os
import signal
import sys
import time


def write(text):
    for byte in text.encode("utf-8"):
        os.write(1, bytes([byte]))


def finish(signum, frame):
    write("\x1b[2K\r 最後の短い発話")  # Exercise EOF without a newline.
    sys.exit(0)


signal.signal(signal.SIGINT, finish)
write("[Start speaking]\n")
for _ in range(2):
    write("\x1b[2K\r" + " " * 100 + "\x1b[2K\r 同じ言葉。\n")
while True:
    time.sleep(0.01)
