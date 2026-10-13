#!/usr/bin/env python3
"""Keep daemon E2E descendants owned and cleanable across process groups."""

import ctypes
import errno
import os
import signal
import subprocess
import sys
import time


PR_SET_CHILD_SUBREAPER = 36
TERM_GRACE_SECONDS = 4.0
POLL_INTERVAL_SECONDS = 0.025
terminate_requested = False


def process_stat(pid):
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stat_file:
            stat = stat_file.read()
    except (FileNotFoundError, ProcessLookupError):
        return None

    closing_paren = stat.rfind(")")
    if closing_paren < 0:
        return None

    fields = stat[closing_paren + 2 :].split()
    try:
        return {
            "state": fields[0],
            "parent_pid": int(fields[1]),
            "process_group_id": int(fields[2]),
            "start_time": int(fields[19]),
        }
    except (IndexError, ValueError):
        return None


def descendants(root_pid):
    found = {}
    parent_pids = {root_pid}
    while parent_pids:
        children = {}
        for parent_pid in parent_pids:
            try:
                task_ids = os.listdir(f"/proc/{parent_pid}/task")
            except (FileNotFoundError, ProcessLookupError):
                continue

            child_pids = set()
            for task_id in task_ids:
                try:
                    with open(
                        f"/proc/{parent_pid}/task/{task_id}/children", encoding="ascii"
                    ) as child_file:
                        child_pids.update(child_file.read().split())
                except (FileNotFoundError, ProcessLookupError):
                    continue

            for child_pid in child_pids:
                pid = int(child_pid)
                if pid not in found and pid != root_pid:
                    info = process_stat(pid)
                    if info is not None:
                        children[pid] = info

        found.update(children)
        parent_pids = set(children)

    return found


def signal_process(pid, expected_start_time, signum):
    """Use a pidfd and start-time check so a recycled PID is never signaled."""
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        info = process_stat(pid)
        if info is not None and info["start_time"] == expected_start_time:
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                pass
        return

    try:
        pidfd = os.pidfd_open(pid)
    except ProcessLookupError:
        return

    try:
        info = process_stat(pid)
        if info is None or info["start_time"] != expected_start_time:
            return
        try:
            signal.pidfd_send_signal(pidfd, signum)
        except ProcessLookupError:
            pass
    finally:
        os.close(pidfd)


def reap_children(primary_child=None):
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return
        if primary_child is not None and pid == primary_child.pid:
            primary_child.returncode = os.waitstatus_to_exitcode(status)


def request_termination(_signum, _frame):
    global terminate_requested
    terminate_requested = True


def write_cleanup_status(status):
    status_file = os.environ["HELMSMAN_E2E_CLEANUP_FILE"]
    temporary_file = f"{status_file}.{os.getpid()}.tmp"
    with open(temporary_file, "w", encoding="ascii") as output:
        output.write(f"{status}\n")
    os.replace(temporary_file, status_file)


def pause_after_first_kill_snapshot():
    snapshot_file = os.environ.get("HELMSMAN_E2E_KILL_SNAPSHOT_FILE")
    continue_file = os.environ.get("HELMSMAN_E2E_KILL_CONTINUE_FILE")
    if snapshot_file is None or continue_file is None:
        return

    with open(snapshot_file, "w", encoding="ascii") as output:
        output.write("ready\n")

    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline and not os.path.exists(continue_file):
        time.sleep(POLL_INTERVAL_SECONDS)


def cleanup_descendants(primary_child):
    deadline = time.monotonic() + TERM_GRACE_SECONDS

    while time.monotonic() < deadline:
        children = descendants(os.getpid())
        if not children:
            reap_children(primary_child)
            return True

        for pid, info in children.items():
            if info["state"] != "Z":
                signal_process(pid, info["start_time"], signal.SIGTERM)

        reap_children(primary_child)
        time.sleep(POLL_INTERVAL_SECONDS)

    deadline = time.monotonic() + 1.0
    first_kill_snapshot = True
    while time.monotonic() < deadline:
        children = descendants(os.getpid())
        if first_kill_snapshot:
            pause_after_first_kill_snapshot()
            first_kill_snapshot = False
            deadline = time.monotonic() + 1.0

        for pid, info in children.items():
            if info["state"] != "Z":
                signal_process(pid, info["start_time"], signal.SIGKILL)

        reap_children(primary_child)
        if not children:
            return True
        time.sleep(POLL_INTERVAL_SECONDS)

    return not descendants(os.getpid())


def main():
    global terminate_requested

    if len(sys.argv) < 2:
        raise SystemExit("daemon process supervisor requires a command")

    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

    signal.signal(signal.SIGTERM, request_termination)
    signal.signal(signal.SIGINT, request_termination)

    group_file = os.environ["HELMSMAN_E2E_PROCESS_GROUP_FILE"]
    stat = process_stat(os.getpid())
    if stat is None or stat["process_group_id"] != os.getpid():
        raise RuntimeError("supervisor did not start as its process-group leader")

    with open(group_file, "w", encoding="ascii") as pid_file:
        pid_file.write(f"{os.getpid()} {stat['start_time']}\n")

    child = subprocess.Popen(sys.argv[1:], close_fds=True)

    while True:
        child.poll()
        children = descendants(os.getpid())

        if terminate_requested:
            if not cleanup_descendants(child):
                write_cleanup_status("error: descendants remained after forced cleanup")
                return 1

            write_cleanup_status("ok")
            break

        if child.returncode is not None and not children:
            write_cleanup_status("ok")
            break

        reap_children(child)
        time.sleep(POLL_INTERVAL_SECONDS)

    return child.wait()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as error:
        if error.errno == errno.ESRCH:
            raise SystemExit(0)
        raise
