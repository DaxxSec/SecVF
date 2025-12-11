# Monthly Development Overview

A summary of recent monthly development from 2025-11-13 to 2025-12-10.

## Recent Monthly Activity

- 2025-12: Add @MainActor annotations to UI classes for thread safety
- 2025-12: Update code-review.md with implementation status
- 2025-12: Phase 1: Dynamic SHA256 checksum fetching from official distro sources
- 2025-12: Security hardening: path traversal protection and user config validation
- 2025-12: Phase 11: Add integration tests for code review items
- 2025-12: feat: add Combine publishers for reactive packet updates (Phase 10 - code review)
- 2025-12: refactor: extract components from VMLibraryWindowController (Phase 9 - code review)
- 2025-12: refactor: externalize Linux distro config to JSON (Phase 8 - code review)
- 2025-12: arch: implement Phase 7 architecture improvements (code review)
- 2025-12: best-practices: implement Phase 6 code quality improvements (code review)
- 2025-12: perf: implement Phase 5 performance optimizations (code review)
- 2025-12: security: implement Phase 4 security hardening (code review)
- 2025-12: refactor: add Phase 3 infrastructure utilities (code review implementation)
- 2025-12: stability: replace all fatalError() with typed error handling (Phase 2)
- 2025-12: security: implement Phase 1 critical security fixes
- 2025-12: feat: enhance packet analysis UI and add VM control handlers
- 2025-12: Fix tshark UI layout: move packet panel horizontal below VM table
- 2025-12: Add tshark packet analysis integration with mini panel and full analysis window
- 2025-11: Now I have a clear picture of the changes: 1. **New feature**: Scripts USB Manager for mounting scripts as virtual USB to VMs 2. **New feature**: Tools menu with "Mount Scripts USB to VM" and "Rebuild Scripts ISO" options 3. **New feature**: macOS 15+ hot-plug USB support via XHCI controller 4. **New file**: ScriptsUSBManager.swift - manages creation/mounting of scripts ISO 5. **New file**: kali-fakenet-setup.sh - FakeNet script for malware analysis 6. **UI changes**: Library window now resizable, fixed XIB outlets 7. **Added documentation**: code-review.md and scripts/README.md feat: add scripts USB mounting for VMs - Add ScriptsUSBManager to create/mount scripts ISO to VMs - Add Tools menu with Mount Scripts USB and Rebuild ISO options - Support hot-plug USB attachment on macOS 15+ via XHCI controller - Add kali-fakenet-setup.sh for malware analysis environment - Make VM library window resizable and fix XIB layout - Clean up stray VM windows on app launch - Add scripts documentation
- 2025-11: Temporarily disable SwitchStatisticsWindowController until added to Xcode
- 2025-11: Organize documentation: move implementation notes to archive
- 2025-11: Fix bidirectional socket communication in virtual switch
- 2025-11: Remove .claude directory from version control
- 2025-11: Fix critical virtual network switch packet forwarding
- 2025-11: Fix critical VM startup failure after multi-window refactoring
- 2025-11: Fix critical multi-VM bugs and add router setup scripts
- 2025-11: fix: Critical Linux VM boot crash and add installation support
- 2025-11: Fix critical macOS VM installation and boot issues
- 2025-11: Fix macOS IPSW download progress UI and add comprehensive documentation
- 2025-11: Add security-hardened ISO/IPSW cache manager
- 2025-11: Fix SSL certificate validation and add build artifacts to gitignore
- 2025-11: Fix main thread deadlock in IPSW download initialization
- 2025-11: Fix IPSW download progress reporting and add stall detection
- 2025-11: Remove recursive SecVF.app copy from build resources
- 2025-11: Fix hardcoded paths and resolve macOS IPSW download issue
- 2025-11: Major UI redesign with cybersecurity theme and enhanced VM management
- 2025-11: Add comprehensive test infrastructure and fix critical bugs
- 2025-11: Fix compilation errors - move network config types
- 2025-11: Add dark-themed UI with CSIRT branding and splash screen
- 2025-11: Add real-time log monitoring with Monitoring menu