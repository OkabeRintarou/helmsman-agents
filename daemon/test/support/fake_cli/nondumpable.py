# Test helper: a process whose environment its own user cannot read.
# argv: PID_FILE [PARENT_PID: wait until no longer its child]
import ctypes
import os
import sys
import time

if len(sys.argv) > 2:
    while os.getppid() == int(sys.argv[2]):
        time.sleep(0.01)

PR_SET_DUMPABLE = 4
ctypes.CDLL(None).prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)
with open(sys.argv[1] + ".tmp", "w") as out:
    out.write(str(os.getpid()))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])

while True:
    time.sleep(1)
