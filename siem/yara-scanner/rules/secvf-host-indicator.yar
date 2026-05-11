/*
   SecVF-specific YARA rules — flag files that reference the host environment.

   These rules don't match malware. They match files that show signs of
   having been written *by* malware running in a SecVF lab — i.e. they
   reference SecVF-specific paths, bundle IDs, or the analyst Mac's user
   directories. A match here is a strong indicator that something inside
   a VM is aware of the lab's structure.

   License: MIT (same as SecVF).
*/

rule SecVF_Host_Path_Reference {
    meta:
        description = "File contains a literal SecVF host filesystem path"
        author      = "DaxxSec"
        severity    = "high"
        category    = "secvf-host-aware"
        reference   = "https://secvf.daxxsec.tech/wiki/Containment-Breakout"
    strings:
        $a = "/Users/" ascii
        $b = ".avf/" ascii
        $c = "SecVF.app" ascii
        $d = "com.DaxxSec.SecVF" ascii
        $e = "com.ItzDaxxy.SecVF" ascii
    condition:
        any of ($b, $c, $d, $e) or
        ($a and any of ($b, $c, $d, $e))
}

rule SecVF_Router_IP_Reference {
    meta:
        description = "File references the SecVF router VM IP (10.0.100.1) or lab subnet"
        author      = "DaxxSec"
        severity    = "medium"
        category    = "secvf-network-aware"
    strings:
        $router = "10.0.100.1"
        $subnet = "10.0.100.0/24"
        $range  = /10\.0\.100\.[0-9]{1,3}/
    condition:
        $router or $subnet or #range > 3
}

rule SecVF_AISandbox_Reference {
    meta:
        description = "File references SecVF AI sandbox internals"
        author      = "DaxxSec"
        severity    = "high"
        category    = "secvf-host-aware"
    strings:
        $a = "AISandbox" ascii
        $b = "ai-sandbox-base-v1" ascii
        $c = "vsock" ascii
        $d = ":2222" ascii
        $e = "VZVirtioSocketDevice" ascii
    condition:
        ($a and $b) or ($c and $d) or $e
}

rule SecVF_VirtualizationFramework_Probe {
    meta:
        description = "File probes Apple Virtualization framework presence"
        author      = "DaxxSec"
        severity    = "medium"
        category    = "secvf-vm-detect"
    strings:
        $a = "Virtualization.framework" ascii
        $b = "VZVirtualMachine" ascii
        $c = "com.apple.Virtualization" ascii
        $d = "ioreg -l | grep -i Virtualization" ascii
        $e = "sysctl kern.hv_vmm_present" ascii
    condition:
        2 of them
}
