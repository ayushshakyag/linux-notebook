# System freeze while playing The Finals (NTFS SSD)

## Status
Observation

## Issue

The system froze twice while playing **The Finals** installed on an **NTFS SSD**.

Both freezes occurred after **Alt+Tabbing** out of the game. The display became completely unresponsive, keyboard and mouse stopped responding, and a hard reset was required.

## Workaround

After moving the game to my local **Btrfs** drive on CachyOS, I have not experienced the same freeze.

## Observation

A previous bug report mentioned a possible copy/paste hard error related to NTFS, but I have not confirmed whether it was the actual cause of the freezes.

## Next Steps

- Check `journalctl` logs after a freeze.
- Test whether the issue only occurs on NTFS.
- Compare behavior on the local Btrfs filesystem.
- Investigate whether the issue is related to Proton, NTFS (`ntfs3`), KDE Alt+Tab, or the kernel.
