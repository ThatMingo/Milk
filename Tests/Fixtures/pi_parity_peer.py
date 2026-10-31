#!/usr/bin/python3
"""Deterministic external RPC peer; not an agent implementation or model provider."""
import json
import os
import sys

def log(kind, **fields):
    path = os.environ.get("MILK_COMPAT_LOG")
    if path:
        with open(path, "a") as output:
            output.write(json.dumps(dict(kind=kind, **fields)) + "\n")


def emit(value):
    print(json.dumps(value), flush=True)

if "--version" in sys.argv:
    print(os.environ.get("MILK_PARITY_VERSION", "1.4.0"))
    sys.exit(0)

log("launch", args=sys.argv[1:], cwd=os.getcwd(), agentDir=os.environ.get("PI_CODING_AGENT_DIR"), path=os.environ.get("PATH"), pid=os.getpid())
if sys.argv[1] in ["install", "remove"]:
    sys.exit(0)
if os.environ.get("MILK_COMPAT_VERSION_ONLY") == "1":
    sys.exit(3)

if os.environ.get("MILK_PARITY_READY") == "1":
    emit({"type": "extension_ui_request", "method": "setStatus",
          "statusKey": "milk-integration-ready", "statusText": "1"})

for line in sys.stdin:
    request = json.loads(line)
    kind = request["type"]
    log("request", command=kind)
    if os.environ.get("MILK_COMPAT_HANG") == "1":
        continue
    data = {"get_state": {"sessionId": "peer", "isStreaming": False},
            "get_commands": {"commands": []},
            "get_available_models": {"models": []},
            "get_available_thinking_levels": {"levels": ["off"]},
            "get_messages": {"messages": []}}.get(kind, {})
    if kind == os.environ.get("MILK_COMPAT_BAD_COMMAND"):
        data = {}
    if kind == "prompt":
        if request["message"] == "notifications":
            for event in [{"type": "agent_start"}, {"type": "compaction_start"},
                          {"type": "auto_retry_start", "attempt": 2, "errorMessage": "fixture overload"},
                          {"type": "auto_retry_end", "success": True},
                          {"type": "agent_end"}, {"type": "future_compatible_event"},
                          {"type": "auto_retry_end", "success": False, "finalError": "fixture retry exhausted"}]:
                emit(event)
        else:
            emit({"type": "agent_settled", "aborted": False})
    emit({"type": "response", "id": request["id"], "success": True, "data": data})
