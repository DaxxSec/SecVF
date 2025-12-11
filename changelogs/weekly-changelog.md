# Weekly Development Summary

A summary of recent weekly development from 2025-11-13 to 2025-12-10.

## Recent Weekly Activity

- Week 2025-49: Add @MainActor annotations to UI classes for thread safety
- Week 2025-49: Update code-review.md with implementation status
- Week 2025-49: Phase 1: Dynamic SHA256 checksum fetching from official distro sources
- Week 2025-49: Security hardening: path traversal protection and user config validation
- Week 2025-49: Phase 11: Add integration tests for code review items
- Week 2025-49: feat: add Combine publishers for reactive packet updates (Phase 10 - code review)
- Week 2025-49: refactor: extract components from VMLibraryWindowController (Phase 9 - code review)
- Week 2025-49: refactor: externalize Linux distro config to JSON (Phase 8 - code review)
- Week 2025-49: arch: implement Phase 7 architecture improvements (code review)
- Week 2025-49: best-practices: implement Phase 6 code quality improvements (code review)
- Week 2025-49: perf: implement Phase 5 performance optimizations (code review)
- Week 2025-49: security: implement Phase 4 security hardening (code review)
- Week 2025-49: refactor: add Phase 3 infrastructure utilities (code review implementation)
- Week 2025-49: stability: replace all fatalError() with typed error handling (Phase 2)
- Week 2025-49: security: implement Phase 1 critical security fixes
- Week 2025-49: feat: enhance packet analysis UI and add VM control handlers
- Week 2025-48: Fix tshark UI layout: move packet panel horizontal below VM table
- Week 2025-48: Add tshark packet analysis integration with mini panel and full analysis window
- Week 2025-47: Now I have a clear picture of the changes: 1. **New feature**: Scripts USB Manager for mounting scripts as virtual USB to VMs 2. **New feature**: Tools menu with "Mount Scripts USB to VM" and "Rebuild Scripts ISO" options 3. **New feature**: macOS 15+ hot-plug USB support via XHCI controller 4. **New file**: ScriptsUSBManager.swift - manages creation/mounting of scripts ISO 5. **New file**: kali-fakenet-setup.sh - FakeNet script for malware analysis 6. **UI changes**: Library window now resizable, fixed XIB outlets 7. **Added documentation**: code-review.md and scripts/README.md feat: add scripts USB mounting for VMs - Add ScriptsUSBManager to create/mount scripts ISO to VMs - Add Tools menu with Mount Scripts USB and Rebuild ISO options - Support hot-plug USB attachment on macOS 15+ via XHCI controller - Add kali-fakenet-setup.sh for malware analysis environment - Make VM library window resizable and fix XIB layout - Clean up stray VM windows on app launch - Add scripts documentation
- Week 2025-46: Temporarily disable SwitchStatisticsWindowController until added to Xcode
- Week 2025-46: Organize documentation: move implementation notes to archive
- Week 2025-46: Fix bidirectional socket communication in virtual switch
- Week 2025-46: Remove .claude directory from version control
- Week 2025-46: Fix critical virtual network switch packet forwarding
- Week 2025-46: Fix critical VM startup failure after multi-window refactoring
- Week 2025-46: Fix critical multi-VM bugs and add router setup scripts
- Week 2025-46: fix: Critical Linux VM boot crash and add installation support
- Week 2025-45: Fix critical macOS VM installation and boot issues
- Week 2025-45: Fix macOS IPSW download progress UI and add comprehensive documentation
- Week 2025-45: Add security-hardened ISO/IPSW cache manager