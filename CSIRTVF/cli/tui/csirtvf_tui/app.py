"""Main TUI application for SecVF."""

import asyncio
from pathlib import Path
from typing import Optional

from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Label,
    Log,
    ProgressBar,
    Rule,
    Static,
    TabbedContent,
    TabPane,
)

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))

from secvf_controller import SecVFController, VM, VMStatus


class VMListWidget(Static):
    """Widget displaying VM list."""

    def __init__(self, controller: SecVFController) -> None:
        super().__init__()
        self.controller = controller
        self.vms: list[VM] = []

    def compose(self) -> ComposeResult:
        yield DataTable(id="vm-table")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("Status", "Name", "OS", "CPU", "RAM", "Network")
        table.cursor_type = "row"
        self.refresh_vms()

    @work(exclusive=True)
    async def refresh_vms(self) -> None:
        """Refresh VM list from controller."""
        try:
            self.vms = await self.controller.list_vms_async()
            table = self.query_one(DataTable)
            table.clear()

            for vm in self.vms:
                status_icon = self._get_status_icon(vm.status)
                os_icon = "" if vm.is_macos else ""
                network = vm.network_config.mode.value
                if vm.network_config.is_router:
                    network += " (router)"

                table.add_row(
                    status_icon,
                    vm.name,
                    f"{os_icon} {vm.os_type}",
                    str(vm.cpu_count),
                    f"{vm.memory_gb:.0f}GB",
                    network,
                    key=vm.id,
                )
        except Exception as e:
            self.app.notify(f"Error loading VMs: {e}", severity="error")

    def _get_status_icon(self, status: VMStatus) -> str:
        """Get status indicator icon."""
        return {
            VMStatus.RUNNING: "[green]●[/]",
            VMStatus.STOPPED: "[dim]○[/]",
            VMStatus.PAUSED: "[yellow]◐[/]",
            VMStatus.UNKNOWN: "[red]?[/]",
        }.get(status, "?")

    def get_selected_vm(self) -> Optional[VM]:
        """Get currently selected VM."""
        table = self.query_one(DataTable)
        if table.cursor_row is not None and table.cursor_row < len(self.vms):
            row_key = table.get_row_at(table.cursor_row)
            for vm in self.vms:
                if vm.id == str(table.get_row_key(row_key)):
                    return vm
        return None


class VMDetailsWidget(Static):
    """Widget displaying VM details."""

    def __init__(self) -> None:
        super().__init__()
        self.vm: Optional[VM] = None

    def compose(self) -> ComposeResult:
        yield Static(id="vm-details-content")

    def update_vm(self, vm: Optional[VM]) -> None:
        """Update displayed VM details."""
        self.vm = vm
        content = self.query_one("#vm-details-content", Static)

        if vm is None:
            content.update("[dim]Select a VM to view details[/]")
            return

        status_color = {
            VMStatus.RUNNING: "green",
            VMStatus.STOPPED: "dim",
            VMStatus.PAUSED: "yellow",
        }.get(vm.status, "red")

        details = f"""[bold]{vm.name}[/]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[{status_color}]● {vm.status.value.upper()}[/]

[bold]System[/]
  OS Type:  {vm.os_type}
  CPU:      {vm.cpu_count} cores
  Memory:   {vm.memory_gb:.1f} GB
  Disk:     {vm.disk_gb:.1f} GB

[bold]Network[/]
  Mode:     {vm.network_config.mode.value}
  Router:   {'Yes' if vm.network_config.is_router else 'No'}
"""

        if vm.linux_distribution:
            details += f"""
[bold]Linux[/]
  Distro:   {vm.linux_distribution}
  Version:  {vm.linux_version or 'Unknown'}
"""

        content.update(details)


class SwitchStatsWidget(Static):
    """Widget displaying virtual switch statistics."""

    def __init__(self, controller: SecVFController) -> None:
        super().__init__()
        self.controller = controller

    def compose(self) -> ComposeResult:
        yield Static(id="switch-stats-content")

    def on_mount(self) -> None:
        self.refresh_stats()

    @work(exclusive=True)
    async def refresh_stats(self) -> None:
        """Refresh switch statistics."""
        try:
            status = self.controller.get_switch_status()
            stats = self.controller.get_switch_stats()

            status_text = "[green]● RUNNING[/]" if status.running else "[dim]○ STOPPED[/]"

            content = f"""[bold]Virtual Network Switch[/]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status: {status_text}
Ports:  {status.connected_ports}/{status.max_ports}
MACs:   {status.learned_macs}

[bold]Traffic[/]
  Forwarded: {stats.packets_forwarded:,}
  Broadcast: {stats.packets_broadcast:,}
  Dropped:   {stats.packets_dropped:,}

  RX: {stats.rx_formatted}
  TX: {stats.tx_formatted}
"""

            content_widget = self.query_one("#switch-stats-content", Static)
            content_widget.update(content)
        except Exception as e:
            self.app.notify(f"Error loading switch stats: {e}", severity="error")


class CaptureWidget(Static):
    """Widget for packet capture controls and status."""

    def __init__(self, controller: SecVFController) -> None:
        super().__init__()
        self.controller = controller

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(id="capture-status")
            with Horizontal(id="capture-controls"):
                yield Button("Start Capture", id="btn-start-capture", variant="success")
                yield Button("Stop Capture", id="btn-stop-capture", variant="error")
            yield Log(id="capture-log", highlight=True, max_lines=100)

    def on_mount(self) -> None:
        self.refresh_status()

    @work(exclusive=True)
    async def refresh_status(self) -> None:
        """Refresh capture status."""
        try:
            status = self.controller.get_capture_status()

            if status.capturing:
                text = f"""[green]● CAPTURING[/]
Interface: {status.interface}
Packets:   {status.packets_captured:,}
Duration:  {status.duration_formatted}
"""
            else:
                text = "[dim]○ NOT CAPTURING[/]"

            status_widget = self.query_one("#capture-status", Static)
            status_widget.update(text)
        except Exception as e:
            self.app.notify(f"Error: {e}", severity="error")

    @on(Button.Pressed, "#btn-start-capture")
    def start_capture(self) -> None:
        """Start packet capture."""
        try:
            self.controller.start_capture(interface="any")
            self.refresh_status()
            self.app.notify("Capture started")
        except Exception as e:
            self.app.notify(f"Error: {e}", severity="error")

    @on(Button.Pressed, "#btn-stop-capture")
    def stop_capture(self) -> None:
        """Stop packet capture."""
        try:
            result = self.controller.stop_capture()
            self.refresh_status()
            packets = result.get("packetsCaptured", 0)
            self.app.notify(f"Capture stopped: {packets} packets")
        except Exception as e:
            self.app.notify(f"Error: {e}", severity="error")


class USBWidget(Static):
    """Widget for USB device management."""

    def __init__(self, controller: SecVFController) -> None:
        super().__init__()
        self.controller = controller

    def compose(self) -> ComposeResult:
        yield DataTable(id="usb-table")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("Type", "Device", "Vendor", "Mounted To", "Status")
        table.cursor_type = "row"
        self.refresh_devices()

    @work(exclusive=True)
    async def refresh_devices(self) -> None:
        """Refresh USB device list."""
        try:
            devices = self.controller.list_usb_devices(include_virtual=True)
            table = self.query_one(DataTable)
            table.clear()

            for device in devices:
                type_icon = "◎" if device.is_virtual else "○"
                mounted = device.mounted_to or "--"

                table.add_row(
                    type_icon,
                    device.name,
                    device.vendor,
                    mounted,
                    device.status,
                )
        except Exception as e:
            self.app.notify(f"Error loading USB devices: {e}", severity="error")


class MainScreen(Screen):
    """Main application screen."""

    BINDINGS = [
        Binding("r", "refresh", "Refresh"),
        Binding("s", "start_vm", "Start VM"),
        Binding("x", "stop_vm", "Stop VM"),
        Binding("q", "app.quit", "Quit"),
    ]

    def __init__(self, controller: SecVFController) -> None:
        super().__init__()
        self.controller = controller

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)

        with TabbedContent():
            with TabPane("Virtual Machines", id="tab-vms"):
                with Horizontal():
                    with Container(id="vm-list-container"):
                        yield VMListWidget(self.controller)
                    with Container(id="vm-details-container"):
                        yield VMDetailsWidget()

            with TabPane("Network", id="tab-network"):
                with Horizontal():
                    yield SwitchStatsWidget(self.controller)

            with TabPane("Capture", id="tab-capture"):
                yield CaptureWidget(self.controller)

            with TabPane("USB", id="tab-usb"):
                yield USBWidget(self.controller)

        yield Footer()

    def on_mount(self) -> None:
        self.title = "SecVF"
        self.sub_title = "Security VM Manager"

    @on(DataTable.RowHighlighted, "#vm-table")
    def vm_selected(self, event: DataTable.RowHighlighted) -> None:
        """Handle VM selection."""
        vm_list = self.query_one(VMListWidget)
        vm_details = self.query_one(VMDetailsWidget)

        if event.row_key:
            for vm in vm_list.vms:
                if vm.id == str(event.row_key.value):
                    vm_details.update_vm(vm)
                    return
        vm_details.update_vm(None)

    def action_refresh(self) -> None:
        """Refresh all data."""
        self.query_one(VMListWidget).refresh_vms()
        self.notify("Refreshing...")

    @work(exclusive=True)
    async def action_start_vm(self) -> None:
        """Start selected VM."""
        vm_list = self.query_one(VMListWidget)
        table = vm_list.query_one(DataTable)

        if table.cursor_row is not None and table.cursor_row < len(vm_list.vms):
            vm = vm_list.vms[table.cursor_row]
            if vm.status == VMStatus.STOPPED:
                try:
                    await self.controller.start_vm_async(vm.name)
                    self.notify(f"Starting {vm.name}...")
                    await asyncio.sleep(1)
                    vm_list.refresh_vms()
                except Exception as e:
                    self.notify(f"Error: {e}", severity="error")
            else:
                self.notify("VM is already running", severity="warning")
        else:
            self.notify("No VM selected", severity="warning")

    @work(exclusive=True)
    async def action_stop_vm(self) -> None:
        """Stop selected VM."""
        vm_list = self.query_one(VMListWidget)
        table = vm_list.query_one(DataTable)

        if table.cursor_row is not None and table.cursor_row < len(vm_list.vms):
            vm = vm_list.vms[table.cursor_row]
            if vm.status == VMStatus.RUNNING:
                try:
                    await self.controller.stop_vm_async(vm.name)
                    self.notify(f"Stopping {vm.name}...")
                    await asyncio.sleep(1)
                    vm_list.refresh_vms()
                except Exception as e:
                    self.notify(f"Error: {e}", severity="error")
            else:
                self.notify("VM is not running", severity="warning")
        else:
            self.notify("No VM selected", severity="warning")


class SecVFApp(App):
    """SecVF Terminal User Interface."""

    CSS = """
    Screen {
        background: $surface;
    }

    #vm-list-container {
        width: 70%;
        height: 100%;
        padding: 1;
    }

    #vm-details-container {
        width: 30%;
        height: 100%;
        padding: 1;
        border-left: solid $primary;
    }

    VMListWidget {
        height: 100%;
    }

    VMDetailsWidget {
        height: 100%;
    }

    #vm-details-content {
        padding: 1;
    }

    SwitchStatsWidget {
        width: 100%;
        height: 100%;
        padding: 1;
    }

    #switch-stats-content {
        padding: 1;
    }

    CaptureWidget {
        width: 100%;
        height: 100%;
        padding: 1;
    }

    #capture-status {
        height: auto;
        padding: 1;
        margin-bottom: 1;
        border: solid $primary;
    }

    #capture-controls {
        height: auto;
        margin-bottom: 1;
    }

    #capture-controls Button {
        margin-right: 1;
    }

    #capture-log {
        height: 1fr;
        border: solid $primary;
    }

    USBWidget {
        width: 100%;
        height: 100%;
        padding: 1;
    }

    DataTable {
        height: 100%;
    }

    TabbedContent {
        height: 1fr;
    }

    TabPane {
        padding: 1;
    }
    """

    BINDINGS = [
        Binding("ctrl+c", "quit", "Quit", show=True),
        Binding("f1", "help", "Help"),
    ]

    def __init__(self, cli_path: Optional[str] = None):
        super().__init__()
        self.controller = SecVFController(cli_path=cli_path)

    def on_mount(self) -> None:
        self.push_screen(MainScreen(self.controller))

    def action_help(self) -> None:
        """Show help."""
        self.notify(
            "r=Refresh | s=Start VM | x=Stop VM | q=Quit",
            title="Keyboard Shortcuts",
        )


def main():
    """Entry point for the TUI application."""
    import argparse

    parser = argparse.ArgumentParser(description="SecVF Terminal UI")
    parser.add_argument(
        "--cli-path",
        help="Path to secvf-cli binary",
        default=None,
    )
    args = parser.parse_args()

    app = SecVFApp(cli_path=args.cli_path)
    app.run()


if __name__ == "__main__":
    main()
