#!/usr/bin/env python3
"""Fake CLI's MCP turn over the real HTTP endpoint, with file barriers.

Only reads the run token from its environment; never records it. Plans and
receipts contain portable tool arguments, responses, the prompt and run ID.
"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request


def wait(path):
    deadline = time.monotonic() + 60
    while not path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("test barrier timed out")
        time.sleep(0.01)


def write(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value), encoding="utf-8")
    temporary.replace(path)


def post(body, session=None):
    headers = {
        "accept": "application/json",
        "content-type": "application/json",
        "mcp-protocol-version": "2025-06-18",
        "authorization": "Bearer " + os.environ["HELMSMAN_RUN_TOKEN"],
    }
    if session:
        headers["mcp-session-id"] = session
    request = urllib.request.Request(
        os.environ["HELMSMAN_SERVER_URL"].rstrip("/") + "/mcp",
        data=json.dumps(body).encode(), headers=headers, method="POST",
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        raw = response.read()
        return response.headers.get("mcp-session-id"), json.loads(raw) if raw else None


def rpc(method, params, session=None):
    return post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, session)


def main():
    plan_path = Path(sys.argv[1])
    plan = json.loads(plan_path.read_text())
    counter = plan_path.with_suffix(".counter")
    turn = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(turn))
    step = plan[turn - 1]
    directory = Path(sys.argv[2])
    marker = directory / step["name"]
    prompt = sys.stdin.read()
    receipt = {"run_id": int(os.environ["HELMSMAN_RUN_ID"]), "prompt": prompt}
    write(Path(str(marker) + ".ready"), receipt)
    wait(Path(str(marker) + ".release"))
    results = []
    session = None
    try:
        session, _ = rpc("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "spec-workflow-fake-cli", "version": "1.0"},
        })
        post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
        for call in step["calls"]:
            _, response = rpc("tools/call", {
                "name": call["tool"], "arguments": call["args"],
            }, session)
            result = response["result"]
            text = result["content"][0]["text"]
            failed = bool(result.get("isError"))
            if failed != call.get("error", False):
                raise RuntimeError("unexpected outcome for " + call["tool"])
            results.append({"tool": call["tool"], "error": failed,
                            "value": text if failed else json.loads(text)})
        write(Path(str(marker) + ".done"), {**receipt, "results": results})
        wait(Path(str(marker) + ".finish"))
        print(json.dumps({"type": "result", "data": {
            "text": step["name"] + " completed.", "success": True,
        }}), flush=True)
    except Exception as error:
        # Never print request headers or exception representations containing credentials.
        write(Path(str(marker) + ".error"), {"message": str(error), "results": results})
        raise SystemExit(1) from None
    finally:
        if session:
            request = urllib.request.Request(
                os.environ["HELMSMAN_SERVER_URL"].rstrip("/") + "/mcp", method="DELETE",
                headers={"authorization": "Bearer " + os.environ["HELMSMAN_RUN_TOKEN"],
                         "mcp-session-id": session},
            )
            try:
                urllib.request.urlopen(request, timeout=5).close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
