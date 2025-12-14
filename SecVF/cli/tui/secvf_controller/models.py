"""Data models for SecVF controller."""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional, List, Dict, Any


class VMStatus(Enum):
    """Virtual machine status."""
    STOPPED = "stopped"
    RUNNING = "running"
    PAUSED = "paused"
    UNKNOWN = "unknown"


class NetworkMode(Enum):
    """Network mode for VMs."""
    NAT = "nat"
    VIRTUAL = "virtual"
    BRIDGED = "bridged"


@dataclass
class NetworkConfig:
    """Network configuration for a VM."""
    mode: NetworkMode = NetworkMode.NAT
    is_router: bool = False
    router_vm_id: Optional[str] = None
    ip_address: Optional[str] = None
    mac_address: Optional[str] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "NetworkConfig":
        """Create from dictionary."""
        mode_str = data.get("mode", "nat")
        try:
            mode = NetworkMode(mode_str)
        except ValueError:
            mode = NetworkMode.NAT

        return cls(
            mode=mode,
            is_router=bool(data.get("isRouter", 0)),
            router_vm_id=data.get("routerVMId"),
            ip_address=data.get("ipAddress"),
            mac_address=data.get("macAddress"),
        )


@dataclass
class VM:
    """Virtual machine model."""
    id: str
    name: str
    os_type: str
    status: VMStatus
    path: str
    cpu_count: int = 2
    memory_size: int = 4294967296  # 4GB default
    disk_size: int = 68719476736   # 64GB default
    network_config: NetworkConfig = field(default_factory=NetworkConfig)
    created_date: Optional[datetime] = None
    last_used_date: Optional[datetime] = None
    linux_distribution: Optional[str] = None
    linux_version: Optional[str] = None
    macos_installed: bool = False

    @property
    def memory_gb(self) -> float:
        """Memory size in GB."""
        return self.memory_size / (1024 ** 3)

    @property
    def disk_gb(self) -> float:
        """Disk size in GB."""
        return self.disk_size / (1024 ** 3)

    @property
    def is_linux(self) -> bool:
        """Check if this is a Linux VM."""
        return self.os_type.lower() == "linux"

    @property
    def is_macos(self) -> bool:
        """Check if this is a macOS VM."""
        return self.os_type.lower() == "macos"

    @property
    def display_name(self) -> str:
        """Display name with OS icon."""
        icon = "" if self.is_macos else ""
        return f"{icon} {self.name}"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "VM":
        """Create from dictionary (CLI JSON output)."""
        status_str = data.get("status", "unknown")
        try:
            status = VMStatus(status_str)
        except ValueError:
            status = VMStatus.UNKNOWN

        # Parse dates from reference time (seconds since 2001-01-01)
        created = None
        if "createdDate" in data:
            reference = datetime(2001, 1, 1)
            created = datetime.fromtimestamp(reference.timestamp() + data["createdDate"])

        last_used = None
        if "lastUsedDate" in data:
            reference = datetime(2001, 1, 1)
            last_used = datetime.fromtimestamp(reference.timestamp() + data["lastUsedDate"])

        network_data = data.get("networkConfig", {})

        return cls(
            id=data.get("id", ""),
            name=data.get("name", "Unknown"),
            os_type=data.get("osType", "Linux"),
            status=status,
            path=data.get("path", ""),
            cpu_count=data.get("cpuCount", 2),
            memory_size=data.get("memorySize", 4294967296),
            disk_size=data.get("diskSize", 68719476736),
            network_config=NetworkConfig.from_dict(network_data),
            created_date=created,
            last_used_date=last_used,
            linux_distribution=data.get("linuxDistribution"),
            linux_version=data.get("linuxVersion"),
            macos_installed=bool(data.get("macOSInstalled", False)),
        )


@dataclass
class USBDevice:
    """USB device model."""
    name: str
    vendor: str
    device_type: str  # "Physical" or "Virtual"
    status: str
    mounted_to: Optional[str] = None
    path: Optional[str] = None
    size: Optional[int] = None
    vendor_id: Optional[str] = None
    product_id: Optional[str] = None
    serial_number: Optional[str] = None

    @property
    def is_virtual(self) -> bool:
        """Check if this is a virtual device."""
        return self.device_type.lower() == "virtual"

    @property
    def is_mounted(self) -> bool:
        """Check if device is mounted to a VM."""
        return self.mounted_to is not None

    @property
    def size_formatted(self) -> str:
        """Format size for display."""
        if self.size is None:
            return ""

        gb = self.size / (1024 ** 3)
        mb = self.size / (1024 ** 2)

        if gb >= 1:
            return f"{gb:.1f} GB"
        if mb >= 1:
            return f"{mb:.1f} MB"
        return f"{self.size} B"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "USBDevice":
        """Create from dictionary."""
        return cls(
            name=data.get("name", "Unknown"),
            vendor=data.get("vendor", "Unknown"),
            device_type=data.get("type", "Physical"),
            status=data.get("status", "Available"),
            mounted_to=data.get("mountedTo"),
            path=data.get("path"),
            size=data.get("size"),
            vendor_id=data.get("vendorId"),
            product_id=data.get("productId"),
            serial_number=data.get("serialNumber"),
        )


@dataclass
class SwitchStatus:
    """Virtual network switch status."""
    running: bool = False
    connected_ports: int = 0
    max_ports: int = 8
    learned_macs: int = 0
    uptime: float = 0.0

    @property
    def uptime_formatted(self) -> str:
        """Format uptime for display."""
        hours = int(self.uptime) // 3600
        minutes = (int(self.uptime) % 3600) // 60
        seconds = int(self.uptime) % 60
        return f"{hours}h {minutes}m {seconds}s"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SwitchStatus":
        """Create from dictionary."""
        return cls(
            running=data.get("running", False),
            connected_ports=data.get("connectedPorts", 0),
            max_ports=data.get("maxPorts", 8),
            learned_macs=data.get("learnedMACs", 0),
            uptime=data.get("uptime", 0.0),
        )


@dataclass
class SwitchStats:
    """Virtual network switch statistics."""
    packets_forwarded: int = 0
    packets_broadcast: int = 0
    packets_dropped: int = 0
    bytes_transferred: int = 0
    rx_bytes: int = 0
    tx_bytes: int = 0
    security_alerts: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def bytes_formatted(self) -> str:
        """Format total bytes for display."""
        return self._format_bytes(self.bytes_transferred)

    @property
    def rx_formatted(self) -> str:
        """Format RX bytes for display."""
        return self._format_bytes(self.rx_bytes)

    @property
    def tx_formatted(self) -> str:
        """Format TX bytes for display."""
        return self._format_bytes(self.tx_bytes)

    @staticmethod
    def _format_bytes(b: int) -> str:
        """Format bytes for display."""
        gb = b / (1024 ** 3)
        mb = b / (1024 ** 2)
        kb = b / 1024

        if gb >= 1:
            return f"{gb:.2f} GB"
        if mb >= 1:
            return f"{mb:.2f} MB"
        if kb >= 1:
            return f"{kb:.2f} KB"
        return f"{b} B"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SwitchStats":
        """Create from dictionary."""
        return cls(
            packets_forwarded=data.get("packetsForwarded", 0),
            packets_broadcast=data.get("packetsBroadcast", 0),
            packets_dropped=data.get("packetsDropped", 0),
            bytes_transferred=data.get("bytesTransferred", 0),
            rx_bytes=data.get("rxBytes", 0),
            tx_bytes=data.get("txBytes", 0),
            security_alerts=data.get("securityAlerts", []),
        )


@dataclass
class CaptureStatus:
    """Packet capture status."""
    capturing: bool = False
    interface: str = ""
    filter: str = ""
    output_file: str = ""
    packets_captured: int = 0
    bytes_captured: int = 0
    duration: float = 0.0
    start_time: Optional[datetime] = None

    @property
    def duration_formatted(self) -> str:
        """Format duration for display."""
        mins = int(self.duration) // 60
        secs = int(self.duration) % 60
        return f"{mins:02d}:{secs:02d}"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "CaptureStatus":
        """Create from dictionary."""
        start = None
        if "startTime" in data:
            try:
                start = datetime.fromisoformat(data["startTime"].replace("Z", "+00:00"))
            except (ValueError, TypeError):
                pass

        return cls(
            capturing=data.get("capturing", False),
            interface=data.get("interface", ""),
            filter=data.get("filter", ""),
            output_file=data.get("outputFile", ""),
            packets_captured=data.get("packetsCaptured", 0),
            bytes_captured=data.get("bytesCaptured", 0),
            duration=data.get("duration", 0.0),
            start_time=start,
        )


@dataclass
class Packet:
    """Captured network packet."""
    number: int = 0
    time: str = ""
    source: str = ""
    destination: str = ""
    protocol: str = ""
    length: int = 0
    info: str = ""
    details: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Packet":
        """Create from dictionary."""
        return cls(
            number=data.get("number", 0),
            time=data.get("time", ""),
            source=data.get("source", ""),
            destination=data.get("destination", ""),
            protocol=data.get("protocol", ""),
            length=data.get("length", 0),
            info=data.get("info", ""),
            details=data.get("details", {}),
        )


@dataclass
class Snapshot:
    """VM snapshot model."""
    name: str
    vm_name: str
    description: str = ""
    created: Optional[datetime] = None
    size: Optional[str] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Snapshot":
        """Create from dictionary."""
        created = None
        if "created" in data:
            try:
                created = datetime.fromisoformat(data["created"].replace("Z", "+00:00"))
            except (ValueError, TypeError):
                pass

        return cls(
            name=data.get("name", ""),
            vm_name=data.get("vmName", ""),
            description=data.get("description", ""),
            created=created,
            size=data.get("size"),
        )
