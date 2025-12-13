# SecVF TUI

A Terminal User Interface for SecVF (Computer Security Incident Response Team Virtualization Framework).

## Features

- **VM Management**: List, start, stop, and monitor virtual machines
- **Network Monitoring**: View virtual switch statistics and MAC table
- **Packet Capture**: Start/stop packet capture, view live packets
- **USB Management**: List USB devices, mount/eject to VMs

## Requirements

- macOS 14.0+
- Python 3.10+
- Swift 5.9+ (for building the CLI)

## Installation

### 1. Build the Swift CLI

```bash
cd secvf-cli
swift build
```

### 2. Install Python dependencies

```bash
pip install textual rich
```

### 3. Run the TUI

```bash
./run.sh
```

Or manually:

```bash
python3 -m secvf_tui.app --cli-path ./secvf-cli/.build/debug/secvf-cli
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `r` | Refresh VM list |
| `s` | Start selected VM |
| `x` | Stop selected VM |
| `q` | Quit |
| `Tab` | Switch tabs |
| `Ctrl+C` | Quit |

## Architecture

```
secvf-tui/
├── secvf_controller/     # Python controller layer
│   ├── __init__.py
│   ├── controller.py       # Main controller (interfaces with CLI)
│   └── models.py           # Data models (VM, USBDevice, etc.)
├── secvf_tui/           # Textual TUI application
│   ├── __init__.py
│   ├── app.py             # Main application
│   ├── screens/           # Screen modules
│   └── widgets/           # Widget modules
└── run.sh                 # Launcher script
```

The TUI communicates with SecVF through a Swift CLI helper (`secvf-cli`) that:
- Reads VM metadata from `~/.avf/`
- Sends commands to the main SecVF app via distributed notifications
- Uses tshark for packet capture operations
- Uses system_profiler for USB device enumeration

## Screenshots

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ SecVF - Security VM Manager                                    12:34:56 ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ Virtual Machines │ Network │ Capture │ USB                                ┃
┠───────────────────────────────────────────────────────────────────────────┨
┃ Status │ Name              │ OS      │ CPU │ RAM  │ Network    ┃ Details  ┃
┃ ●      │ Kali Router       │  Linux │ 4   │ 8GB  │ nat (router)┃          ┃
┃ ○      │ Ubuntu VM         │  Linux │ 2   │ 4GB  │ nat        ┃ Kali R.. ┃
┃ ○      │ MacOS Sandbox     │  macOS │ 4   │ 8GB  │ virtual    ┃ ━━━━━━━  ┃
┃                                                                ┃ ● RUNNING┃
┃                                                                ┃          ┃
┃                                                                ┃ System   ┃
┃                                                                ┃ CPU: 4   ┃
┃                                                                ┃ RAM: 8GB ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
┃ r=Refresh │ s=Start │ x=Stop │ q=Quit                                     ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

## CLI Commands

The `secvf-cli` tool can also be used standalone:

```bash
# List VMs
secvf-cli vm list --json

# Start a VM
secvf-cli vm start "Kali Router"

# Stop a VM
secvf-cli vm stop "Kali Router"

# SSH into a VM
secvf-cli vm ssh "Kali Router" --command "uname -a"

# Capture packets
secvf-cli capture start --interface any
secvf-cli capture status
secvf-cli capture stop

# List USB devices
secvf-cli usb list --include-virtual

# Switch statistics
secvf-cli switch status
secvf-cli switch stats --watch
```

## Development

```bash
# Install dev dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Type checking
mypy secvf_controller secvf_tui

# Linting
ruff check .
```
