# Security Policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately on GitHub: open the **Security** tab of this repository and
click **Report a vulnerability**. I'll reply as soon as I can.

Only the latest release gets fixes.

## What Aerial Shelf changes on your Mac

- It writes one video ID into the macOS wallpaper settings file and restarts the wallpaper service. The file is
  backed up first, and every change is read back and checked.
- It downloads videos only from Apple's servers: when you click Download, and, with Keep Only the Video on Screen
  on, the next video before each change. Scheduled downloads don't use Low Data Mode or networks macOS marks as
  expensive.
- With Keep Only the Video on Screen on, it permanently deletes the copies it downloaded for that mode once no
  wallpaper, screen saver, display or Space uses them. Videos you downloaded and your own videos go only to the
  Trash, and only when you ask.
- With My Videos on, it sets two preference keys in `com.apple.wallpaper.aerial` that point macOS at a local copy of
  Apple's catalog. Turning My Videos off removes them.
- No accounts, no analytics, no other network access.
