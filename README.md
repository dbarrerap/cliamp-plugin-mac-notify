# cliamp-plugin-mac-notify

Now Playing desktop notifications for [cliamp](https://github.com/bjarneo/cliamp) on macOS.

Sends a notification on every track change with the track title, artist, and
album, plus an optional "Playlist finished" notification when the queue runs
out. cliamp's built-in `cliamp.notify` relies on `notify-send`, which only
exists on Linux — this plugin uses the built-in `osascript` (and optionally
`terminal-notifier`) instead. On Linux it falls back to `cliamp.notify`.

> The Control Center / media-keys "Now Playing" widget is already built into
> cliamp on macOS (`mediactl`). This plugin adds the desktop notifications.

## Install

```sh
cliamp plugins install dbarrerap/cliamp-plugin-mac-notify
cliamp plugins trust mac-notify
```

Manual install: copy `mac-notify.lua` into `~/.config/cliamp/plugins/`, then
approve it:

```sh
cliamp plugins trust mac-notify
```

## Configuration

The notifier binary must be allowlisted. Add to `~/.config/cliamp/config.toml`:

```toml
[plugins]
allowed_binaries = "osascript, terminal-notifier"

[plugins.mac-notify]
# notifier  = "auto"        # auto (default) | osascript | terminal-notifier
# sound     = ""            # macOS sound name, e.g. "Glass"; empty = silent
# group     = "mac-notify"  # terminal-notifier only; "" = stack notifications
# queue_end = false         # true = notify when the queue runs out
```

Restart cliamp after editing the config.

## terminal-notifier (optional)

```sh
brew install terminal-notifier
```

With the default `notifier = "auto"`, the plugin prefers `terminal-notifier`
when it is installed and allowlisted. It gives you:

- a proper app icon instead of the generic **Script Editor** icon,
- `-group`: each new track **replaces** the previous notification instead of
  stacking in Notification Center,
- `-sound` and per-notification control.

Two one-time steps after installing:

1. Allow it in the allowlist (see Configuration above) and restart cliamp.
2. Grant the permission: **System Settings → Notifications →
   terminal-notifier → Allow Notifications** (style: Banners or Alerts).

Check the state at any time:

```sh
terminal-notifier -diagnose
```

Look for `authorization authorized`. If it says `denied` or
`not requested yet`, the app needs to be enabled in System Settings.

## macOS notification permission

`osascript` notifications are attributed to **Script Editor** (generic icon,
no image, notifications stack). Enable them once:

**System Settings → Notifications → Script Editor → Allow Notifications**

If a Focus (Do Not Disturb) mode is active, notifications are delayed until it
ends.

## Backends

1. `terminal-notifier` — if allowed and installed
2. `osascript` — built into macOS
3. `cliamp.notify` (`notify-send`) — Linux fallback

Failures are logged once with the exact fix (usually the `allowed_binaries`
line above).

## Test

From a running cliamp, send a sample notification:

```sh
cliamp plugins call mac-notify test
```

## Debugging

Plugin logs: `~/.config/cliamp/plugins.log`

Backend health: `terminal-notifier -diagnose` and
`cliamp plugins call mac-notify test`.

## License

MIT
