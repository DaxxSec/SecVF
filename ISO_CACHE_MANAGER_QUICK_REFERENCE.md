# ISO Cache Manager - Quick Reference Guide

## How to Access

**Menu:** Monitoring > Manage ISO Cache
**Keyboard:** Cmd+Shift+5

## Window Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  ISO/IPSW Cache                              [Search: Filter...] │
│  Manage downloaded VM installation images                        │
├─────────────────────────────────────────────────────────────────┤
│  [Refresh]  [Check All Updates]  [Clear All]                    │
├─────────────────────────────────────────────────────────────────┤
│  Name           │ OS    │ Version │ Size   │ Downloaded         │
│  Kali-2025.3    │ Linux │ 2025.3  │ 3.2 GB │ Nov 17, 2025 14:30 │
│  Ubuntu-24.04   │ Linux │ 24.04   │ 4.8 GB │ Nov 16, 2025 09:15 │
│  UniversalMac..  │ macOS │ 15.6.1  │ 13.5GB │ Nov 15, 2025 16:45 │
│                                                                   │
│  Checksum      │ Actions                                         │
│  Verified ✓    │ [Verify] [Check Update] [Delete]               │
│  Not Verified  │ [Verify] [Check Update] [Delete]               │
│  No Checksum   │ [Verify] [Check Update] [Delete]               │
├─────────────────────────────────────────────────────────────────┤
│  Total Cache Size: 21.5 GB (3 images)     Cache: ~/.avf/VMImages│
└─────────────────────────────────────────────────────────────────┘
```

## Button Functions

### Global Actions (Toolbar)

| Button | Function | Confirmation? |
|--------|----------|---------------|
| Refresh | Reload cache from disk | No |
| Check All Updates | Check for newer distro versions (future) | No |
| Clear All | Delete all cached ISOs | Yes |

### Per-Image Actions

| Button | Function | When Disabled? |
|--------|----------|----------------|
| Verify | Run SHA256 checksum verification | When checksum is placeholder |
| Check Update | Check if newer version available (future) | Always (not implemented) |
| Delete | Remove ISO from cache | Never |

## Checksum Status Colors

| Status | Color | Meaning |
|--------|-------|---------|
| Verified | Green | SHA256 matches expected hash |
| Failed | Red | SHA256 does NOT match - corrupted/tampered |
| Not Verified | Yellow | SHA256 available but not yet verified |
| No Checksum | Gray | Distribution has placeholder checksum |

## Search/Filter

- Type in search field to filter results
- Searches: Name, OS Type, Version
- Case-insensitive
- Real-time filtering

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Shift+5 | Open ISO Cache Manager |
| Cmd+F | Focus search field (standard) |
| ↑/↓ | Navigate table rows |
| Enter | Select row (no action) |
| Esc | Dismiss alerts |

## Common Tasks

### Verify an ISO
1. Locate the ISO in the table
2. Check that "Verify" button is enabled (not gray)
3. Click "Verify"
4. Wait for progress dialog (may take 1-5 minutes for large ISOs)
5. View result (Verified or Failed)

### Delete an ISO
1. Click "Delete" button for the ISO
2. Confirm deletion in dialog
3. ISO is removed immediately
4. Table and statistics update automatically

### Clear All Cache
1. Click "Clear All" button in toolbar
2. Review confirmation dialog (shows total size)
3. Confirm to delete all
4. All ISOs removed, table clears

### Search for an ISO
1. Click search field in top-right
2. Type part of name, OS, or version
3. Table filters in real-time
4. Clear search to show all

## File Locations

| OS Type | Cache Directory |
|---------|----------------|
| Linux ISOs | `~/.avf/VMImages/Linux/` |
| macOS IPSWs | `~/.avf/VMImages/macOS/` |

## Expected Behavior

### Empty Cache
- Table shows empty
- Total size: "0.00 GB (0 images)"
- All buttons functional except per-image actions

### Verification Progress
- Modal dialog appears
- Progress bar animates (indeterminate)
- Shows ISO name
- Cannot interact with window until complete
- Cancel button available (future)

### Deletion
- Confirmation dialog shows size to be freed
- Warning about re-download requirement
- Immediate removal on confirm
- Statistics update automatically

## Error Scenarios

### ISO File Missing
- Entry may show in table but verification/deletion fails
- Error dialog explains file not found
- Use "Refresh" to update table

### Verification Fails
- Checksum status turns RED
- Alert recommends deletion and re-download
- ISO is still usable but not trusted

### Insufficient Permissions
- Error dialog shows permission denied
- Check file ownership and permissions
- May need to fix with Terminal

## Integration with VM Creation

- ISOs in cache are automatically detected during VM creation
- Verified ISOs are preferred for security
- Failed verification does not prevent VM creation
- Deleted ISOs will be re-downloaded when needed

## Tips

1. **Verify after Download**: Always verify new ISOs for security
2. **Regular Cleanup**: Delete unused ISOs to free space
3. **Check Size**: Monitor total cache size in footer
4. **Search Efficiently**: Use search for large cache lists
5. **Confirmation Safety**: Read confirmation dialogs carefully

## Troubleshooting

### Window Won't Open
- Check Monitoring menu is available
- Try keyboard shortcut Cmd+Shift+5
- Restart SecVF if needed

### Table is Empty
- Click "Refresh" to reload
- Check if ISOs exist in `~/.avf/VMImages/`
- Create a new VM to trigger ISO download

### Verify Button Disabled
- Normal for distributions without checksums
- Check "Checksum" column shows "No Checksum"
- Only affects Ubuntu, Debian, Fedora, etc. (not Kali)

### Verification Takes Forever
- Normal for large ISOs (3-13 GB)
- Progress dialog should remain responsive
- Wait at least 5 minutes before canceling

### Delete Failed
- Check file permissions
- Ensure no VMs are currently using the ISO
- Try "Refresh" and delete again

## Architecture Overview

```
AppDelegate
    ↓ (creates/shows)
ISOCacheManagerWindow
    ↓ (uses)
ISOCacheManager.shared
    ↓ (manages)
~/.avf/VMImages/
    ├── Linux/
    │   ├── Kali-2025.3/
    │   ├── Ubuntu-24.04/
    │   └── Debian-12.0/
    └── macOS/
        └── UniversalMac_15.6.1/
```

## Data Flow

```
1. User opens window via menu
   ↓
2. ISOCacheManagerWindow.init()
   ↓
3. loadCachedImages() → ISOCacheManager.listCachedImages()
   ↓
4. Parse entries, populate table
   ↓
5. Display with statistics

User clicks "Verify":
   ↓
6. Show progress dialog
   ↓
7. Background thread: ISOCacheManager.verifySHA256()
   ↓
8. Update status, dismiss dialog
   ↓
9. Reload table row with new status
```

## Future Features (Planned)

- [ ] Check for Updates button functionality
- [ ] Last Used date tracking
- [ ] Automatic cleanup policies
- [ ] In-window download progress
- [ ] Batch operations (multi-select)
- [ ] Export cache report
- [ ] Checksum database updates

## Support

For issues or questions:
- Check this guide first
- Review ISO_CACHE_MANAGER_IMPLEMENTATION.md for technical details
- Test with SecVF after rebuild
- Report bugs with screenshots and console logs
