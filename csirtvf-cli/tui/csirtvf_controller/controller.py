"""Main controller for SecVF - interfaces with Swift CLI."""

import asyncio
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from .models import (
    CaptureStatus,
    NetworkMode,
    Packet,
    Snapshot,
    SwitchStats,
    SwitchStatus,
    USBDevice,
    VM,
    VMStatus,
)


class SecVFController:
    """Controller for SecVF operations."""

    def __init__(self, cli_path: Optional[str] = None):
        """Initialize controller.

        Args:
            cli_path: Path to secvf-cli binary. If None, searches common locations.
        """
        self.cli_path = cli_path or self._find_cli()
        self._vm_cache: Dict[str, VM] = {}
        self._callbacks: Dict[str, List[Callable]] = {}

    def _find_cli(self) -> str:
        """Find the secvf-cli binary."""
        # Check common locations
        # Note: TUI is now at secvf-cli/tui/, so parent.parent.parent gets to secvf-cli/
        cli_dir = Path(__file__).parent.parent.parent  # secvf-cli/

        search_paths = [
            # Development build (TUI is inside secvf-cli/tui/)
            cli_dir / ".build" / "debug" / "secvf-cli",
            cli_dir / ".build" / "release" / "secvf-cli",
            # Installed system-wide (preferred name)
            Path("/usr/local/bin/secvf"),
            # Alternative names
            Path("/usr/local/bin/secvf-cli"),
            # User bin
            Path.home() / ".local" / "bin" / "secvf",
            Path.home() / ".local" / "bin" / "secvf-cli",
            # Homebrew
            Path("/opt/homebrew/bin/secvf"),
            Path("/opt/homebrew/bin/secvf-cli"),
        ]

        for path in search_paths:
            if path.exists() and path.is_file():
                return str(path)

        # Try PATH
        cli = shutil.which("secvf-cli")
        if cli:
            return cli

        raise FileNotFoundError(
            "secvf-cli not found. Build it with: cd secvf-cli && swift build"
        )

    def _run_cli(self, *args: str, timeout: float = 30.0) -> Dict[str, Any]:
        """Run CLI command and return JSON result.

        Args:
            *args: CLI arguments
            timeout: Command timeout in seconds

        Returns:
            Parsed JSON response

        Raises:
            RuntimeError: If CLI command fails
        """
        # --json flag goes after subcommand in ArgumentParser
        cmd = [self.cli_path] + list(args) + ["--json"]

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )

            # Parse JSON output
            try:
                data = json.loads(result.stdout)
            except json.JSONDecodeError:
                # Try to parse stderr for errors
                if result.returncode != 0:
                    raise RuntimeError(f"CLI error: {result.stderr or result.stdout}")
                raise RuntimeError(f"Invalid JSON response: {result.stdout}")

            if not data.get("success", True):
                raise RuntimeError(data.get("message", "Unknown error"))

            return data

        except subprocess.TimeoutExpired:
            raise RuntimeError(f"CLI command timed out: {' '.join(args)}")
        except FileNotFoundError:
            raise RuntimeError(f"CLI not found at: {self.cli_path}")

    async def _run_cli_async(self, *args: str, timeout: float = 30.0) -> Dict[str, Any]:
        """Run CLI command asynchronously.

        Args:
            *args: CLI arguments
            timeout: Command timeout in seconds

        Returns:
            Parsed JSON response
        """
        # --json flag goes after subcommand in ArgumentParser
        cmd = [self.cli_path] + list(args) + ["--json"]

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout, stderr = await asyncio.wait_for(
                proc.communicate(),
                timeout=timeout,
            )

            output = stdout.decode() if stdout else ""
            error = stderr.decode() if stderr else ""

            try:
                data = json.loads(output)
            except json.JSONDecodeError:
                if proc.returncode != 0:
                    raise RuntimeError(f"CLI error: {error or output}")
                raise RuntimeError(f"Invalid JSON response: {output}")

            if not data.get("success", True):
                raise RuntimeError(data.get("message", "Unknown error"))

            return data

        except asyncio.TimeoutError:
            raise RuntimeError(f"CLI command timed out: {' '.join(args)}")

    # -------------------------------------------------------------------------
    # VM Operations
    # -------------------------------------------------------------------------

    def list_vms(self) -> List[VM]:
        """List all virtual machines.

        Returns:
            List of VM objects
        """
        data = self._run_cli("vm", "list")
        vms = [VM.from_dict(vm_data) for vm_data in data.get("data", [])]

        # Update cache
        self._vm_cache = {vm.id: vm for vm in vms}

        return vms

    async def list_vms_async(self) -> List[VM]:
        """List all virtual machines asynchronously.

        Returns:
            List of VM objects
        """
        data = await self._run_cli_async("vm", "list")
        vms = [VM.from_dict(vm_data) for vm_data in data.get("data", [])]

        # Update cache
        self._vm_cache = {vm.id: vm for vm in vms}

        return vms

    def get_vm(self, name: str) -> Optional[VM]:
        """Get a specific VM by name.

        Args:
            name: VM name

        Returns:
            VM object or None if not found
        """
        try:
            data = self._run_cli("vm", "status", name)
            return VM.from_dict(data.get("data", {}))
        except RuntimeError:
            return None

    async def get_vm_async(self, name: str) -> Optional[VM]:
        """Get a specific VM by name asynchronously.

        Args:
            name: VM name

        Returns:
            VM object or None if not found
        """
        try:
            data = await self._run_cli_async("vm", "status", name)
            return VM.from_dict(data.get("data", {}))
        except RuntimeError:
            return None

    def start_vm(self, name: str) -> bool:
        """Start a virtual machine.

        Args:
            name: VM name

        Returns:
            True if successful
        """
        self._run_cli("vm", "start", name)
        self._emit("vm_started", name)
        return True

    async def start_vm_async(self, name: str) -> bool:
        """Start a virtual machine asynchronously.

        Args:
            name: VM name

        Returns:
            True if successful
        """
        await self._run_cli_async("vm", "start", name)
        self._emit("vm_started", name)
        return True

    def stop_vm(self, name: str, force: bool = False) -> bool:
        """Stop a virtual machine.

        Args:
            name: VM name
            force: Force stop without graceful shutdown

        Returns:
            True if successful
        """
        args = ["vm", "stop", name]
        if force:
            args.append("--force")

        self._run_cli(*args)
        self._emit("vm_stopped", name)
        return True

    async def stop_vm_async(self, name: str, force: bool = False) -> bool:
        """Stop a virtual machine asynchronously.

        Args:
            name: VM name
            force: Force stop without graceful shutdown

        Returns:
            True if successful
        """
        args = ["vm", "stop", name]
        if force:
            args.append("--force")

        await self._run_cli_async(*args)
        self._emit("vm_stopped", name)
        return True

    def create_vm(
        self,
        name: str,
        os_type: str = "Linux",
        cpu_count: int = 2,
        memory_gb: float = 4.0,
        disk_gb: float = 64.0,
        network_mode: NetworkMode = NetworkMode.NAT,
    ) -> VM:
        """Create a new virtual machine.

        Args:
            name: VM name
            os_type: "Linux" or "macOS"
            cpu_count: Number of CPU cores
            memory_gb: Memory in gigabytes
            disk_gb: Disk size in gigabytes
            network_mode: Network mode

        Returns:
            Created VM object
        """
        args = [
            "vm", "create",
            "--name", name,
            "--os-type", os_type,
            "--cpu-count", str(cpu_count),
            "--memory", str(int(memory_gb * 1024)),  # Convert to MB
            "--disk-size", str(int(disk_gb)),
            "--network-mode", network_mode.value,
        ]

        data = self._run_cli(*args)
        vm = VM.from_dict(data.get("data", {}))
        self._emit("vm_created", vm)
        return vm

    def delete_vm(self, name: str) -> bool:
        """Delete a virtual machine.

        Args:
            name: VM name

        Returns:
            True if successful
        """
        self._run_cli("vm", "delete", name)
        self._emit("vm_deleted", name)
        return True

    # -------------------------------------------------------------------------
    # SSH Operations
    # -------------------------------------------------------------------------

    def ssh_available(self, name: str) -> bool:
        """Check if SSH is available for a VM.

        Args:
            name: VM name

        Returns:
            True if SSH is available
        """
        try:
            data = self._run_cli("vm", "status", name)
            return data.get("data", {}).get("sshAvailable", False)
        except RuntimeError:
            return False

    def ssh_exec(self, name: str, command: str) -> Tuple[str, str, int]:
        """Execute a command via SSH on a VM.

        Args:
            name: VM name
            command: Command to execute

        Returns:
            Tuple of (stdout, stderr, exit_code)
        """
        data = self._run_cli("vm", "ssh", name, "--command", command)
        result = data.get("data", {})
        return (
            result.get("stdout", ""),
            result.get("stderr", ""),
            result.get("exitCode", -1),
        )

    async def ssh_exec_async(self, name: str, command: str) -> Tuple[str, str, int]:
        """Execute a command via SSH on a VM asynchronously.

        Args:
            name: VM name
            command: Command to execute

        Returns:
            Tuple of (stdout, stderr, exit_code)
        """
        data = await self._run_cli_async("vm", "ssh", name, "--command", command)
        result = data.get("data", {})
        return (
            result.get("stdout", ""),
            result.get("stderr", ""),
            result.get("exitCode", -1),
        )

    def copy_to_vm(self, name: str, local_path: str, remote_path: str) -> bool:
        """Copy a file to a VM.

        Args:
            name: VM name
            local_path: Local file path
            remote_path: Remote destination path

        Returns:
            True if successful
        """
        self._run_cli("vm", "copy-to", name, local_path, "--destination", remote_path)
        return True

    def copy_from_vm(self, name: str, remote_path: str, local_path: str) -> bool:
        """Copy a file from a VM.

        Args:
            name: VM name
            remote_path: Remote file path
            local_path: Local destination path

        Returns:
            True if successful
        """
        self._run_cli("vm", "copy-from", name, remote_path, "--destination", local_path)
        return True

    # -------------------------------------------------------------------------
    # Snapshot Operations
    # -------------------------------------------------------------------------

    def list_snapshots(self, vm_name: str) -> List[Snapshot]:
        """List snapshots for a VM.

        Args:
            vm_name: VM name

        Returns:
            List of Snapshot objects
        """
        data = self._run_cli("vm", "snapshot", "list", vm_name)
        return [Snapshot.from_dict(s) for s in data.get("data", [])]

    def create_snapshot(
        self, vm_name: str, snapshot_name: str, description: str = ""
    ) -> Snapshot:
        """Create a snapshot.

        Args:
            vm_name: VM name
            snapshot_name: Snapshot name
            description: Optional description

        Returns:
            Created Snapshot object
        """
        args = ["vm", "snapshot", "create", vm_name, "--name", snapshot_name]
        if description:
            args.extend(["--description", description])

        data = self._run_cli(*args)
        return Snapshot.from_dict(data.get("data", {}))

    def restore_snapshot(self, vm_name: str, snapshot_name: str) -> bool:
        """Restore a snapshot.

        Args:
            vm_name: VM name
            snapshot_name: Snapshot name

        Returns:
            True if successful
        """
        self._run_cli("vm", "snapshot", "restore", vm_name, "--name", snapshot_name)
        return True

    def delete_snapshot(self, vm_name: str, snapshot_name: str) -> bool:
        """Delete a snapshot.

        Args:
            vm_name: VM name
            snapshot_name: Snapshot name

        Returns:
            True if successful
        """
        self._run_cli("vm", "snapshot", "delete", vm_name, "--name", snapshot_name)
        return True

    # -------------------------------------------------------------------------
    # USB Operations
    # -------------------------------------------------------------------------

    def list_usb_devices(self, include_virtual: bool = True) -> List[USBDevice]:
        """List USB devices.

        Args:
            include_virtual: Include virtual USB disks

        Returns:
            List of USBDevice objects
        """
        args = ["usb", "list"]
        if include_virtual:
            args.append("--include-virtual")

        data = self._run_cli(*args)
        return [USBDevice.from_dict(d) for d in data.get("data", [])]

    def mount_usb(self, device: str, vm_name: str) -> bool:
        """Mount USB device to a VM.

        Args:
            device: Device name or ID
            vm_name: Target VM name

        Returns:
            True if successful
        """
        self._run_cli("usb", "mount", device, "--to", vm_name)
        return True

    def eject_usb(self, device: str) -> bool:
        """Eject USB device from VM.

        Args:
            device: Device name or ID

        Returns:
            True if successful
        """
        self._run_cli("usb", "eject", device)
        return True

    def create_virtual_usb(
        self, name: str, size_mb: int = 256, format: str = "dmg", source: Optional[str] = None
    ) -> str:
        """Create a virtual USB disk.

        Args:
            name: Disk name
            size_mb: Size in megabytes
            format: "dmg" or "iso"
            source: Source directory to include

        Returns:
            Path to created disk
        """
        args = ["usb", "create-virtual", "--name", name, "--size", str(size_mb), "--format", format]
        if source:
            args.extend(["--source", source])

        data = self._run_cli(*args)
        return data.get("data", {}).get("path", "")

    # -------------------------------------------------------------------------
    # Switch Operations
    # -------------------------------------------------------------------------

    def get_switch_status(self) -> SwitchStatus:
        """Get virtual switch status.

        Returns:
            SwitchStatus object
        """
        data = self._run_cli("switch", "status")
        return SwitchStatus.from_dict(data.get("data", {}))

    def get_switch_stats(self) -> SwitchStats:
        """Get virtual switch statistics.

        Returns:
            SwitchStats object
        """
        data = self._run_cli("switch", "stats")
        return SwitchStats.from_dict(data.get("data", {}))

    def get_switch_ports(self) -> List[Dict[str, Any]]:
        """Get connected switch ports.

        Returns:
            List of port information dictionaries
        """
        data = self._run_cli("switch", "ports")
        return data.get("data", [])

    def get_mac_table(self) -> List[Dict[str, Any]]:
        """Get MAC address learning table.

        Returns:
            List of MAC table entries
        """
        data = self._run_cli("switch", "macs")
        return data.get("data", [])

    # -------------------------------------------------------------------------
    # Capture Operations
    # -------------------------------------------------------------------------

    def get_capture_status(self) -> CaptureStatus:
        """Get packet capture status.

        Returns:
            CaptureStatus object
        """
        data = self._run_cli("capture", "status")
        return CaptureStatus.from_dict(data.get("data", {}))

    def start_capture(
        self,
        interface: str = "any",
        filter: Optional[str] = None,
        output: Optional[str] = None,
        max_packets: int = 0,
    ) -> bool:
        """Start packet capture.

        Args:
            interface: Interface to capture on
            filter: BPF filter expression
            output: Output file path
            max_packets: Maximum packets to capture (0 = unlimited)

        Returns:
            True if successful
        """
        args = ["capture", "start", "--interface", interface]
        if filter:
            args.extend(["--filter", filter])
        if output:
            args.extend(["--output", output])
        if max_packets > 0:
            args.extend(["--count", str(max_packets)])

        self._run_cli(*args)
        self._emit("capture_started")
        return True

    def stop_capture(self) -> Dict[str, Any]:
        """Stop packet capture.

        Returns:
            Capture statistics
        """
        data = self._run_cli("capture", "stop")
        self._emit("capture_stopped")
        return data.get("data", {})

    def export_capture(
        self,
        output: str,
        format: str = "pcap",
        filter: Optional[str] = None,
        limit: Optional[int] = None,
    ) -> int:
        """Export captured packets.

        Args:
            output: Output file path
            format: Export format (pcap, json, csv)
            filter: Filter expression
            limit: Maximum packets to export

        Returns:
            Number of packets exported
        """
        args = ["capture", "export", output, "--format", format]
        if filter:
            args.extend(["--filter", filter])
        if limit:
            args.extend(["--limit", str(limit)])

        data = self._run_cli(*args)
        return data.get("data", {}).get("packetsExported", 0)

    # -------------------------------------------------------------------------
    # Event System
    # -------------------------------------------------------------------------

    def on(self, event: str, callback: Callable) -> None:
        """Register event callback.

        Args:
            event: Event name
            callback: Callback function
        """
        if event not in self._callbacks:
            self._callbacks[event] = []
        self._callbacks[event].append(callback)

    def off(self, event: str, callback: Callable) -> None:
        """Unregister event callback.

        Args:
            event: Event name
            callback: Callback function
        """
        if event in self._callbacks:
            self._callbacks[event] = [cb for cb in self._callbacks[event] if cb != callback]

    def _emit(self, event: str, *args: Any) -> None:
        """Emit event to registered callbacks.

        Args:
            event: Event name
            *args: Event arguments
        """
        for callback in self._callbacks.get(event, []):
            try:
                callback(*args)
            except Exception:
                pass  # Don't let callback errors break the controller

    # -------------------------------------------------------------------------
    # Utility Methods
    # -------------------------------------------------------------------------

    def get_avf_path(self) -> Path:
        """Get the AVF data directory path.

        Returns:
            Path to ~/.avf
        """
        return Path.home() / ".avf"

    def get_logs_path(self) -> Path:
        """Get the logs directory path.

        Returns:
            Path to ~/.avf/logs
        """
        return self.get_avf_path() / "logs"

    def cli_version(self) -> str:
        """Get CLI version.

        Returns:
            Version string
        """
        try:
            result = subprocess.run(
                [self.cli_path, "--version"],
                capture_output=True,
                text=True,
            )
            return result.stdout.strip()
        except Exception:
            return "unknown"
