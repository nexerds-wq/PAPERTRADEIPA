# NEXER Repair v0.2

Converted PAPERTRADEIPA into **NEXER Repair**, retaining its iOS Xcode project and GitHub Actions scheme.

## Two connected applications

- **Windows desktop**: WindowsAgent/nexer_desktop.py (black-screen lock, diagnostics, repair tools, Ollama chat, image upload)
- **Windows agent**: WindowsAgent/nexer_agent.py (paired API, strict command allowlist, repair approval and history)
- **iPhone IPA**: SwiftUI NEXER app in NexerPaperTrader/NexerPaperTraderApp.swift

The iPhone cannot directly run Windows CMD/PowerShell. The phone controls the agent running on your PC.

## Unlock: black screen

**Up, Down, Left, Left, Right**

Windows desktop: hold the **left mouse button** and drag each direction, releasing after each gesture. iPhone: swipe with your finger. Each drag must exceed about 65 pixels. Wrong gestures reset the code. The gesture hides the interface but is not a strong authentication method.

## Run on Windows

1. Install Python 3.10+ with tkinter (standard Python Windows installer).
2. Install Ollama from https://ollama.com and start it.
3. In Command Prompt run: ollama pull qwen3:4b
4. For image understanding also run: ollama pull qwen3-vl:4b
5. Open an administrator terminal if you want repairs that need elevation.
6. From the repository root run: python WindowsAgent/nexer_desktop.py
7. Enter the swipe code with your left mouse button.

The Ollama model can request approved diagnostic tools automatically. Yellow-risk changes need your explicit approval. Destructive commands and arbitrary CMD are blocked.

## Connect iPhone

1. On the Windows desktop Settings tab, choose START PHONE AGENT.
2. Make sure the PC and iPhone are on the same trusted private Wi-Fi/LAN.
3. Copy the pairing key using COPY PAIRING KEY.
4. Build the IPA from the GitHub **Actions** tab: Build NEXER Repair IPA. Download artifact named NEXER-Repair-Unsigned-IPA from the successful run.
5. The IPA is unsigned and **requires signing** with your own device credentials before installation.
6. Launch the iPhone app. Swipe Up, Down, Left, Left, Right on the black screen.
7. In Settings, enter the PC URL such as http://192.168.1.50:8765 and its pairing key; tap Save and connect.

Alternatively launch just the agent for local use with:
python WindowsAgent/nexer_agent.py

Or for the trusted LAN, with explicit permission:
python WindowsAgent/nexer_agent.py --host 0.0.0.0 --allow-lan

The key file is stored at %LOCALAPPDATA%\NexerRepair\pairing.key. History is at %LOCALAPPDATA%\NexerRepair\history.jsonl.

**IMPORTANT SECURITY LIMITATION**: The first release uses HTTP on LAN and does not encrypt pairing secrets in transit. Do not use on untrusted networks, do not port-forward port 8765, and do not expose this server to the public internet. Use an authenticated TLS tunnel or private VPN for remote use.

## Tools and capabilities

Read-only: system info, hardware inventory, problematic devices, driver listing, network, audio, Bluetooth, GPU, services, Windows event logs, Defender status, DISM CheckHealth, SFC verification and disk scan.

Approval-required: clear DNS, restart audio/Bluetooth services, repair Windows image with DISM, SFC system file repair, Windows Defender quick scan and Winsock reset.

Ollama connects to its local API. A vision-capable model allows image analysis from Photos or Files on the phone, and files on the Windows desktop. On iPhone, use Diagnose My PC to gather diagnostic results and inspect them before repairs.

## Limitations and caution

NEXER is not capable of repairing every Windows or hardware problem. This first version does NOT flash BIOS firmware, rewrite partitions, bypass Windows protections, remove arbitrary files, execute AI-generated shell commands or replace defective hardware. Green status means a diagnostic command ran successfully, not that hardware or Windows is definitely healthy.

Sources for future verified rules: Microsoft, Intel, AMD, NVIDIA, ASUS, MSI, ASRock, Gigabyte, Dell, HP, Lenovo, iFixit, CheckMyError and Geekflare. Prefer official vendor recommendations over third-party scripts.

## Build details

- Xcode scheme/target: NexerPaperTrader (old name kept for compatibility)
- Display name: NEXER Repair
- iOS deployment: 17+
- CI workflow: .github/workflows/main.yml
- Test Python syntax: python -m py_compile WindowsAgent/nexer_agent.py WindowsAgent/nexer_desktop.py

Legacy paper-trading Swift sources remain in the repository but are no longer included in the target Sources build phase. They are not part of the new app.
