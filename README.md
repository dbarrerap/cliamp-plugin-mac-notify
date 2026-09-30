# cliamp-plugin-mac-notify

Now Playing desktop notifications for [cliamp](https://github.com/bjarneo/cliamp) on macOS.

Sends a notification on every track change with the track title, artist, and
album. cliamp's built-in `cliamp.notify` relies on `notify-send`, which only
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
allowed_binaries = "osascript"   # add terminal-notifier too if you use it

[plugins.mac-notify]
# notifier = "auto"       # auto (default) | osascript | terminal-notifier
# sound    = ""           # macOS sound name, e.g. "Glass"; empty = silent
# group    = "mac-notify" # terminal-notifier only; "" = stack notifications
```

Restart cliamp after editing the config.

## macOS notification permission

`osascript` notifications are attributed to **Script Editor**. Enable them once:

**System Settings → Notifications → Script Editor → Allow Notifications**

If a Focus (Do Not Disturb) mode is active, notifications are delayed until it
ends.

## terminal-notifier (optional)

```sh
brew install terminal-notifier
```

With the default `notifier = "auto"`, the plugin prefers `terminal-notifier`
when it is installed and allowlisted: cliamp-branded notifications and, through
`group`, each new track replaces the previous notification instead of stacking.

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

## License

MIT
