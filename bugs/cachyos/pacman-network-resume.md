# Pacman download does not resume after network change

## Status
Investigating / Feature idea

## Issue

If the active network changes (for example, Ethernet disconnects and Wi-Fi is already connected), ongoing `pacman` downloads stop. The transfer stalls and requires restarting the command manually.

Partial downloads are preserved, so rerunning `pacman` resumes from the cached `.part` files instead of downloading everything again.

## Idea

Instead of stopping permanently after the connection is lost, `pacman` could:

- Detect that the download failed because of a temporary network interruption.
- Wait for a working network connection.
- Retry the download automatically.
- Continue using HTTP Range requests from the existing `.part` file.
- Optionally reselect the fastest available mirror before retrying.

This would make network handovers (Ethernet → Wi-Fi, Wi-Fi → Ethernet, or temporary outages) seamless without requiring the user to restart `pacman`.

## Notes

Need to investigate whether this behavior belongs in `pacman`, `libalpm`, or the download backend, and whether a feature request or existing discussion already covers it.
