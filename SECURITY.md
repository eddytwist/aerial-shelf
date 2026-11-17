# Security Policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately on GitHub: open the **Security** tab of this repository and
click **Report a vulnerability**. I'll reply as soon as I can.

Only the latest release gets fixes.

## What Aerialist changes on your Mac

- It writes one video ID into the macOS wallpaper settings file and restarts the wallpaper service. The file is
  backed up first, and every change is read back and checked.
- It downloads videos only from Apple's servers: the next video before each change when it isn't on disk, and when
  you set one as the wallpaper or keep it on this Mac. Scheduled downloads don't use Low Data Mode or networks macOS
  marks as expensive.
- With **Delete Shown Aerials** on (Settings → Storage), it permanently deletes copies it downloaded for the
  rotation once they fall out of the last 1–10 shown and no wallpaper, screen saver, display or Space uses them.
  Videos you keep on this Mac and your own videos are never deleted automatically; other files go only to the
  Trash, and only after you confirm.
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
