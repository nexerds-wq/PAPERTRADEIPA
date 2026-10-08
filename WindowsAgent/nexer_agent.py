"""
NEXER Windows agent: Ollama tool calling with a strict command allowlist.
Python 3.10+; Windows 10/11; no third-party packages.
Default listener is localhost only. --allow-lan is required for phone access.
"""
from __future__ import annotations
import argparse
import base64
import hmac
import http.server
import json
import os
import platform
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(os.getenv("LOCALAPPDATA") or Path.home()) / "NexerRepair"
ROOT.mkdir(parents=True, exist_ok=True)
KEY_FILE = ROOT / "pairing.key"
HISTORY_FILE = ROOT / "history.jsonl"
OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
MAX_BODY = 8_000_000
MAX_OUTPUT = 12_000
KEY = KEY_FILE.read_text(encoding="utf-8").strip() if KEY_FILE.exists() else ""
if not KEY:
    KEY = secrets.token_urlsafe(32)
    KEY_FILE.write_text(KEY, encoding="utf-8")

SYSTEM_ROOT = os.environ.get("SystemRoot", r"C:\Windows")
PS = str(Path(SYSTEM_ROOT) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")
PNPUTIL = str(Path(SYSTEM_ROOT) / "System32" / "pnputil.exe")
SFC = str(Path(SYSTEM_ROOT) / "System32" / "sfc.exe")
DISM = str(Path(SYSTEM_ROOT) / "System32" / "dism.exe")
IPCONFIG = str(Path(SYSTEM_ROOT) / "System32" / "ipconfig.exe")
NETSH = str(Path(SYSTEM_ROOT) / "System32" / "netsh.exe")
CHKDSK = str(Path(SYSTEM_ROOT) / "System32" / "chkdsk.exe")

def ps(script: str) -> list[str]:
    return [PS, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script]

# All commands are authored here. NO arbitrary shell, parameters, file paths,
# network targets, or model-generated code are passed into the execution engine.
TOOLS = {
    "system_info": ("System overview", "green", "OS version, computer and memory information.",
        ps("Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime,TotalVisibleMemorySize,FreePhysicalMemory | Format-List"), 20),
    "hardware": ("Hardware inventory", "green", "CPU, motherboard, RAM, and graphics hardware.",
        ps("Get-CimInstance Win32_ComputerSystem | Select Manufacturer,Model,TotalPhysicalMemory | Format-List; Get-CimInstance Win32_Processor | Select Name | Format-List; Get-CimInstance Win32_BaseBoard | Select Manufacturer,Product | Format-List; Get-CimInstance Win32_VideoController | Select Name,DriverVersion | Format-List"), 25),
    "problem_devices": ("Device errors", "green", "Find devices with problems in Device Manager.",
        [PNPUTIL, "/enum-devices", "/problem"], 25),
    "drivers": ("Installed drivers", "green", "Enumerate third-party driver packages.",
        [PNPUTIL, "/enum-drivers"], 30),
    "network": ("Network diagnostics", "green", "Inspect adapters, IP, DNS and gateways.",
        ps("Get-NetAdapter | Select Name,InterfaceDescription,Status,LinkSpeed | Format-Table -AutoSize; Get-DnsClientServerAddress | Select InterfaceAlias,ServerAddresses | Format-List; ipconfig /all"), 25),
    "bluetooth": ("Bluetooth diagnostics", "green", "Check Bluetooth devices and service state.",
        ps("Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Select FriendlyName,Status,InstanceId | Format-List; Get-Service bthserv | Format-List"), 20),
    "audio": ("Audio diagnostics", "green", "Check audio endpoints, devices and Windows Audio services.",
        ps("Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | Select FriendlyName,Status | Format-Table; Get-Service Audiosrv,AudioEndpointBuilder | Select Name,Status | Format-Table"), 20),
    "gpu": ("GPU diagnostics", "green", "Display adapters, driver versions and DirectX information.",
        ps("Get-CimInstance Win32_VideoController | Select Name,DriverVersion,VideoProcessor,Status | Format-List; Get-PnpDevice -Class Display | Select FriendlyName,Status | Format-Table"), 20),
    "services": ("Service diagnostics", "green", "Important Windows service state.",
        ps("Get-Service wuauserv,bits,cryptsvc,WinDefend,Audiosrv,Dhcp,Dnscache -ErrorAction SilentlyContinue | Select Name,Status,StartType | Format-Table"), 20),
    "crash_events": ("Recent crash events", "green", "Read recent critical and error events from System log.",
        ps("Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2} -MaxEvents 20 -ErrorAction SilentlyContinue | Select TimeCreated,Id,ProviderName,Message | Format-List"), 35),
    "application_errors": ("Application crashes", "green", "Read recent application error events.",
        ps("Get-WinEvent -FilterHashtable @{LogName='Application';Level=2} -MaxEvents 15 -ErrorAction SilentlyContinue | Select TimeCreated,Id,ProviderName,Message | Format-List"), 35),
    "defender_status": ("Defender status", "green", "Read Microsoft Defender configuration and scan status.",
        ps("Get-MpComputerStatus | Select AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime | Format-List"), 25),
    "windows_component_check": ("Windows component health", "green", "DISM read-only component store health check.",
        [DISM, "/Online", "/Cleanup-Image", "/CheckHealth"], 45),
    "sfc_verify": ("Verify system files", "green", "SFC verifies system files without repairing them.",
        [SFC, "/verifyonly"], 180),
    "disk_scan": ("Disk file-system scan", "green", "Check C: file system online without requesting repair.",
        [CHKDSK, "C:", "/scan"], 120),
    "flush_dns": ("Flush DNS", "yellow", "Clear the Windows DNS resolver cache.",
        [IPCONFIG, "/flushdns"], 30),
    "restart_audio": ("Restart Windows Audio", "yellow", "Restart Windows Audio service (brief audio interruption).",
        ps("Restart-Service -Name Audiosrv -Force -ErrorAction Stop"), 30),
    "restart_bluetooth": ("Restart Bluetooth service", "yellow", "Restart Bluetooth Support Service (devices may disconnect).",
        ps("Restart-Service -Name bthserv -Force -ErrorAction Stop"), 30),
    "run_sfc": ("Repair system files (SFC)", "yellow", "Run sfc /scannow as administrator.",
        [SFC, "/scannow"], 1000),
    "run_dism": ("Repair Windows image (DISM)", "yellow", "Run DISM RestoreHealth (may download Windows components).",
        [DISM, "/Online", "/Cleanup-Image", "/RestoreHealth"], 1400),
    "defender_quick_scan": ("Microsoft Defender quick scan", "yellow", "Start a Defender antivirus quick scan.",
        ps("Start-MpScan -ScanType QuickScan -ErrorAction Stop"), 1000),
    "reset_winsock": ("Reset Winsock", "yellow", "Reset Winsock settings; restart may be required.",
        [NETSH, "winsock", "reset"], 30),
}
# Deliberately no arbitrary PowerShell/CMD endpoint, registry deletion,
# BIOS flashing, disk formatting, BitLocker or firewall-disabling action.

pending: dict[str, tuple[str, float]] = {}
pending_lock = threading.Lock()
history_lock = threading.Lock()

def write_history(action: str, status: str, detail: str = "") -> None:
    record = {
        "id": str(uuid.uuid4()),
        "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "action": action, "status": status, "detail": detail[:500]
    }
    with history_lock:
        with HISTORY_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

def read_history() -> list[dict]:
    if not HISTORY_FILE.exists():
        return []
    with history_lock:
        rows = HISTORY_FILE.read_text(encoding="utf-8").splitlines()[-60:]
    out = []
    for row in reversed(rows):
        try:
            out.append(json.loads(row))
        except ValueError:
            continue
    return out

def invoke(tool: str) -> dict:
    if tool not in TOOLS:
        return {"error": "Unknown tool", "output": ""}
    label, _, _, argv, timeout = TOOLS[tool]
    if os.name != "nt":
        return {"error": "Windows is required", "output": "This tool runs only on Windows."}
    try:
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            errors="replace", timeout=timeout, shell=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)
        )
        output = ((result.stdout or "") + "\n" + (result.stderr or "")).strip()
        output = output[:MAX_OUTPUT] or "(no output)"
        status = "completed" if result.returncode == 0 else "error"
        write_history(label, status, f"exit={result.returncode}; {output[:380]}")
        return {"output": output, "exit_code": result.returncode}
    except subprocess.TimeoutExpired:
        write_history(label, "timeout", "Command exceeded timeout")
        return {"error": "Command timed out", "output": "Command timed out"}
    except Exception as exc:
        write_history(label, "error", str(exc))
        return {"error": "Unable to run diagnostic", "output": str(exc)[:MAX_OUTPUT]}

def tool_info() -> list[dict]:
    return [
        {"id": key, "label": val[0], "risk": val[1], "description": val[2]}
        for key, val in TOOLS.items()
    ]

def request_tool(tool: str) -> dict:
    if tool not in TOOLS:
        return {"error": "Unknown tool", "output": "This tool does not exist."}
    label, risk, _, _, _ = TOOLS[tool]
    if risk == "green":
        return invoke(tool)
    if risk != "yellow":
        return {"error": "Blocked", "output": "High-risk tool unavailable"}
    action_id = secrets.token_urlsafe(18)
    with pending_lock:
        pending[action_id] = (tool, time.monotonic() + 300)
    write_history(label, "awaiting approval")
    return {"pending": {"id": action_id, "tool": tool, "label": label, "risk": risk},
            "output": "Needs explicit approval before running."}

def approve_tool(action_id: str) -> dict:
    with pending_lock:
        item = pending.pop(action_id, None)
    if not item or item[1] < time.monotonic():
        return {"error": "Approval expired", "output": "Request again to create a new approval."}
    return invoke(item[0])

SYSTEM = (
    "You are NEXER Repair, a Windows diagnostic assistant. You see tool results from "
    "the actual PC. Never claim something is repaired or healthy without evidence. "
    "Use read-only tools to diagnose first. To request a Windows repair, call the matching "
    "approved tool. Yellow repairs will be QUEUED for approval, never executed by you. "
    "Explain why approval is needed. Do not output invented diagnostic results. "
    "If you see a screenshot, confirm findings with device diagnostics when possible. "
    "You cannot run arbitrary commands or BIOS changes. Avoid overconfidence."
)

def ollama_tools() -> list[dict]:
    return [{
        "type": "function",
        "function": {
            "name": key, "description": f"{val[2]} Risk: {val[1]}.",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False}
        }
    } for key, val in TOOLS.items()]

def ollama_call(model: str, messages: list[dict]) -> dict:
    body = json.dumps({
        "model": model, "messages": messages, "tools": ollama_tools(), "stream": False,
        "options": {"temperature": 0.2}
    }).encode("utf-8")
    req = urllib.request.Request(
        OLLAMA_URL, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=170) as response:
        return json.load(response)

def chat(text: str, image: str, model: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_.:/-]{1,100}", model):
        return {"reply": "Invalid Ollama model name.", "pending": []}
    if image:
        try:
            binary = base64.b64decode(image, validate=True)
            if len(binary) > 5_000_000:
                return {"reply": "Image too large (5 MB maximum).", "pending": []}
        except (ValueError, base64.binascii.Error):
            return {"reply": "Invalid image data.", "pending": []}
    user: dict = {"role": "user", "content": (text or "Analyze this image.")}
    if image:
        user["images"] = [image]
    messages = [{"role": "system", "content": SYSTEM}, user]
    proposed: list[dict] = []
    try:
        for _ in range(4):
            response = ollama_call(model, messages)
            assistant = response.get("message") or {}
            calls = assistant.get("tool_calls") or []
            if not calls:
                reply = (assistant.get("content") or "I checked the available information.").strip()
                if proposed:
                    reply += "\n\nApproval is required for the proposed repairs."
                return {"reply": reply, "pending": proposed}
            messages.append(assistant)
            for call in calls[:6]:
                fn = call.get("function") or {}
                name = fn.get("name", "")
                result = request_tool(name)
                if result.get("pending"):
                    proposed.append(result["pending"])
                messages.append({
                    "role": "tool", "tool_name": name,
                    "content": json.dumps(result, ensure_ascii=False)[:MAX_OUTPUT]
                })
        return {"reply": "I reached the diagnostic step limit. Review results or ask a more specific question.",
                "pending": proposed}
    except urllib.error.URLError as exc:
        return {"reply": f"Cannot reach Ollama on the PC: {str(exc.reason)[:150]}. Start Ollama and pull the model.",
                "pending": proposed}
    except Exception as exc:
        return {"reply": "Ollama error: " + str(exc)[:300], "pending": proposed}

SCAN_SET = ["system_info", "hardware", "problem_devices", "network", "audio",
            "bluetooth", "gpu", "services", "crash_events", "defender_status"]

def diagnose() -> dict:
    output = []
    for key in SCAN_SET:
        result = invoke(key)
        output.append({
            "id": key, "label": TOOLS[key][0],
            "status": "warning" if result.get("error") or result.get("exit_code", 0) != 0 else "info",
            "output": result.get("output", "")
        })
    return {"results": output}

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "NexerAgent/0.2"
    def log_message(self, fmt, *args):
        pass

    def send_json(self, obj: dict, status: int = 200) -> None:
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self) -> bool:
        given = self.headers.get("X-Nexer-Key", "")
        if not hmac.compare_digest(given.encode(), KEY.encode()):
            self.send_json({"error": "Invalid pairing key"}, 401)
            return False
        return True

    def read_body(self) -> dict | None:
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n < 0 or n > MAX_BODY:
                self.send_json({"error": "Request too large"}, 413)
                return None
            obj = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
            if not isinstance(obj, dict):
                raise ValueError("JSON object required")
            return obj
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.send_json({"error": "Invalid JSON"}, 400)
            return None

    def do_GET(self):
        if not self.authorized():
            return
        if self.path == "/status":
            self.send_json({"name": socket.gethostname(), "windows": platform.platform(),
                            "agent": "NEXER v0.2"})
        elif self.path == "/tools":
            self.send_json({"tools": tool_info()})
        elif self.path == "/history":
            self.send_json({"history": read_history()})
        else:
            self.send_json({"error": "Unknown endpoint"}, 404)

    def do_POST(self):
        if not self.authorized():
            return
        data = self.read_body()
        if data is None:
            return
        if self.path == "/run":
            self.send_json(request_tool(str(data.get("tool", ""))))
        elif self.path == "/approve":
            self.send_json(approve_tool(str(data.get("id", ""))))
        elif self.path == "/diagnose":
            self.send_json(diagnose())
        elif self.path == "/chat":
            self.send_json(chat(
                str(data.get("text", ""))[:4000],
                str(data.get("image", "")),
                str(data.get("model", "qwen3:4b"))
            ))
        else:
            self.send_json({"error": "Unknown endpoint"}, 404)

def start_server(host: str = "127.0.0.1", port: int = 8765):
    server = http.server.ThreadingHTTPServer((host, port), Handler)
    print(f"NEXER Agent ready at http://{host}:{port}")
    print(f"Pairing key: {KEY}")
    print("Keep this key private. Only use a trusted local network.")
    server.serve_forever()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NEXER Repair Windows agent")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--allow-lan", action="store_true",
                        help="Explicitly allow binding to the local network")
    args = parser.parse_args()
    if os.name != "nt":
        sys.exit("The repair agent only runs on Windows 10/11.")
    if args.host not in ("127.0.0.1", "localhost") and not args.allow_lan:
        sys.exit("LAN binding requires --allow-lan. Never port-forward this agent.")
    start_server(args.host, args.port)
