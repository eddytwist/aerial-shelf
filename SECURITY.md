# Security Policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately on GitHub: open the **Security** tab of this repository and
click **Report a vulnerability**. I'll reply as soon as I can.

Only the latest release gets fixes.

## What Aerialist changes on your Mac

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
- At first launch, then once a day, and when you click **Check for Updates…**, it downloads `appcast.xml` from the
  latest GitHub release of this repository to see if there's a newer version. You can turn the daily check off in
  Settings → Updates. If you choose to install an update, it downloads the new disk image from the same release,
  checks its EdDSA signature against the public key inside the app, replaces the app and opens it again. The feed
  is signed too. Update checks don't wait for Low Data Mode. Updates use [Sparkle](https://sparkle-project.org),
  which keeps its settings (keys starting with `SU`) in the app's preferences and a download cache in
  `~/Library/Caches/com.eddytwist.Aerialist`.
- No accounts, no analytics, no other network access.
