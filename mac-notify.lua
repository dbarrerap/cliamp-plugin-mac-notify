-- mac-notify.lua — Now Playing desktop notifications for cliamp on macOS
--
-- Sends a notification on every track change, when playback (re)starts after
-- a pause or stop, and (optionally) when the queue finishes. A debounce
-- coalesces fast skipping into one notification for the track you settle on
-- (art is fetched only for that track). Local files
-- contribute their embedded artwork: ffmpeg extracts the
-- cover once per file (cached) and terminal-notifier shows it in the banner
-- with -contentImage. YouTube tracks get their video thumbnail
-- (i.ytimg.com/vi/<id>/hqdefault.jpg) the same way. Uses terminal-notifier
-- when it is installed, otherwise the built-in osascript. When neither backend
-- is available it falls back to cliamp.notify (notify-send) so the plugin
-- still works on Linux. Tracks without an album still notify:
-- terminal-notifier needs a non-empty message, so an empty body falls back to
-- the subtitle.
--
-- Requires the exec permission and the notifier binaries in the allowlist
-- (ffmpeg ships in cliamp's default allowlist):
--
--   [plugins]
--   allowed_binaries = "osascript, terminal-notifier"
--
-- Optional configuration in config.toml:
--
--   [plugins.mac-notify]
--   notifier  = "auto"         -- auto | osascript | terminal-notifier
--   sound     = ""             -- e.g. "Glass"; empty = silent
--   group     = "mac-notify"   -- terminal-notifier only; "" = stack instead of replace
--   queue_end = false          -- true = notify when the queue runs out
--   play_start = true          -- notify when playback (re)starts (pause/stop -> play)
--   debounce  = 2              -- seconds to wait after a track change; 0 = off
--   art       = "auto"         -- auto | on | off; local cover + YouTube thumbnail

local p = plugin.register({
    name = "mac-notify",
    type = "hook",
    version = "1.5.0",
    description = "macOS Now Playing notifications with album art (local + YouTube)",
    permissions = { "exec" },
})

local cfg_notifier = p:config("notifier") or "auto"
local cfg_sound = p:config("sound") or ""
local cfg_group = p:config("group")
if cfg_group == nil then
    cfg_group = "mac-notify"
end
local cfg_queue_end = p:config("queue_end")
local queue_end_on = cfg_queue_end == true or cfg_queue_end == "true"
local cfg_play_start = p:config("play_start")
local play_start_on = cfg_play_start == nil or cfg_play_start == true or cfg_play_start == "true"
local cfg_debounce = p:config("debounce")
local debounce_secs = 2
if type(cfg_debounce) == "number" then
    debounce_secs = cfg_debounce
elseif cfg_debounce == false then
    debounce_secs = 0
elseif type(cfg_debounce) == "string" then
    debounce_secs = tonumber(cfg_debounce) or tonumber(cfg_debounce:match("%d+")) or 2
end
if debounce_secs < 0 then
    debounce_secs = 0
end
local cfg_art = p:config("art") or "auto"
if cfg_art ~= "auto" and cfg_art ~= "on" and cfg_art ~= "off" then
    cliamp.log.warn('mac-notify: unknown art mode "' .. tostring(cfg_art) .. '", using "auto"')
    cfg_art = "auto"
end
local art_on = cfg_art ~= "off"

local ART_DIR = "/tmp/cliamp-mac-notify"
local seq = 0

local active = nil
local warned = {}

local function log_once(level, msg)
    if warned[msg] then
        return
    end
    warned[msg] = true
    if level == "error" then
        cliamp.log.error(msg)
    elseif level == "debug" then
        cliamp.log.debug(msg)
    else
        cliamp.log.warn(msg)
    end
end

local function candidates()
    if cfg_notifier == "osascript" or cfg_notifier == "terminal-notifier" then
        return { cfg_notifier }
    end
    if cfg_notifier ~= "auto" then
        log_once("warn", 'mac-notify: unknown notifier "' .. tostring(cfg_notifier) .. '", using "auto"')
    end
    return { "terminal-notifier", "osascript" }
end

local function track_text(track)
    local title = track.title or ""
    local artist = track.artist or ""
    local album = track.album or ""
    if title == "" then
        if artist == "" then
            return nil
        end
        title = artist
        artist = ""
    end
    return title, artist, album
end

local function as_escape(s)
    s = tostring(s or "")
    s = s:gsub("%c", " ")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    return s
end

local function osascript_args(title, subtitle, body, image)
    local script = 'display notification "' .. as_escape(body)
        .. '" with title "' .. as_escape(title) .. '"'
    if subtitle ~= "" then
        script = script .. ' subtitle "' .. as_escape(subtitle) .. '"'
    end
    if cfg_sound ~= "" then
        script = script .. ' sound name "' .. as_escape(cfg_sound) .. '"'
    end
    return { "-e", script }
end

-- terminal-notifier rejects an empty or dash-leading -message.
local function usable_msg(s)
    return type(s) == "string" and s:match("%S") ~= nil and not s:match("^%-")
end

local function terminal_notifier_args(title, subtitle, body, image)
    if not usable_msg(body) then
        if usable_msg(subtitle) then
            body = subtitle
            subtitle = ""
        else
            body = "·"
        end
    end
    local args = { "-title", title }
    if subtitle ~= "" then
        table.insert(args, "-subtitle")
        table.insert(args, subtitle)
    end
    table.insert(args, "-message")
    table.insert(args, body)
    if cfg_sound ~= "" then
        table.insert(args, "-sound")
        table.insert(args, cfg_sound)
    end
    if cfg_group ~= "" then
        table.insert(args, "-group")
        table.insert(args, cfg_group)
    end
    if image then
        table.insert(args, "-contentImage")
        table.insert(args, image)
    end
    return args
end

local BACKENDS = {
    ["osascript"] = { bin = "osascript", args = osascript_args },
    ["terminal-notifier"] = { bin = "terminal-notifier", args = terminal_notifier_args },
}

local function try_backend(name, title, subtitle, body, image)
    local backend = BACKENDS[name]
    local handle, err = cliamp.exec.run(backend.bin, backend.args(title, subtitle, body, image), {
        on_exit = function(code)
            if code ~= 0 then
                log_once("warn", "mac-notify " .. name .. " exited with code " .. tostring(code))
                if active == name then
                    active = nil
                end
            end
        end,
    })
    if not handle then
        if active == name then
            active = nil
        end
        return false, err
    end
    if active ~= name then
        active = name
        cliamp.log.info("mac-notify using backend: " .. name)
    end
    return true
end

local function do_notify(title, subtitle, body, image)
    if active and try_backend(active, title, subtitle, body, image) then
        return
    end
    local errs = {}
    for _, name in ipairs(candidates()) do
        local ok, err = try_backend(name, title, subtitle, body, image)
        if ok then
            return
        end
        log_once("debug", "mac-notify " .. name .. ": " .. tostring(err))
        table.insert(errs, name .. ": " .. tostring(err))
    end
    local all = table.concat(errs, "; ")
    if all:find("concurrency", 1, true) then
        -- Transient: too many short-lived notifier processes at once.
        log_once("debug", "mac-notify: exec busy, dropping notification")
        return
    end
    local msg = "mac-notify: no notifier backend — " .. all
    if msg:find("allowlist", 1, true) then
        msg = msg .. '. Add the binaries to [plugins] allowed_binaries in config.toml'
    end
    log_once("warn", msg)
    -- Last resort: cliamp.notify works on Linux through notify-send.
    cliamp.notify(title, subtitle ~= "" and subtitle or body)
end

local SCALE = "scale='min(512,iw)':-2"

local function is_local(path)
    return type(path) == "string" and path ~= "" and not path:match("^%a[%w%.%+%-]*:")
end

local function fetch_art(args, mine, out, send, none, timeout)
    cliamp.fs.mkdir(ART_DIR)
    local handle, err = cliamp.exec.run("ffmpeg", args, {
        timeout = timeout,
        on_exit = function(code)
            if mine ~= seq then
                return -- superseded by a newer notification
            end
            if code == 0 and cliamp.fs.exists(out) then
                send(out)
            else
                if none then
                    cliamp.fs.write(none, "")
                end
                send(nil)
            end
        end,
    })
    if not handle then
        -- No .none marker on spawn failure: the next attempt may succeed.
        log_once("warn", "mac-notify ffmpeg failed: " .. tostring(err) .. ", notification continues without art")
        send(nil)
    end
end

local function youtube_id(path)
    if type(path) ~= "string" then
        return nil
    end
    if not path:match("^https?://[^/]*youtube%.com/") and not path:match("^https?://youtu%.be/") then
        return nil
    end
    return path:match("[?&]v=([%w_-]+)")
        or path:match("youtu%.be/([%w_-]+)")
        or path:match("/shorts/([%w_-]+)")
        or path:match("/live/([%w_-]+)")
end

local function notify(title, subtitle, body, path)
    -- Latest notification wins: a newer send invalidates a pending art chain.
    seq = seq + 1
    local mine = seq
    local function send(image)
        do_notify(title, subtitle, body, image)
    end

    if not art_on then
        send(nil)
        return
    end

    if is_local(path) then
        local key = cliamp.crypto.sha256(path)
        local img = ART_DIR .. "/" .. key .. ".jpg"
        local none = ART_DIR .. "/" .. key .. ".none"
        if cliamp.fs.exists(img) then
            send(img)
            return
        end
        if cliamp.fs.exists(none) then
            send(nil)
            return
        end
        fetch_art({
            "-y", "-i", path, "-map", "0:v:0", "-frames:v", "1",
            "-vf", SCALE, "-q:v", "3", img,
        }, mine, img, send, none, 10)
        return
    end

    local yid = youtube_id(path)
    if not yid then
        send(nil)
        return
    end
    local img = ART_DIR .. "/yt-" .. yid .. ".jpg"
    if cliamp.fs.exists(img) then
        send(img)
        return
    end
    -- Network failures are transient: no .none marker, retry on next play.
    fetch_art({
        "-y", "-i", "https://i.ytimg.com/vi/" .. yid .. "/hqdefault.jpg",
        "-frames:v", "1", "-vf", SCALE, "-q:v", "3", img,
    }, mine, img, send, nil, 4)
end

-- Dedup shared by track.change and play-start: the same path announced twice
-- within DEDUP_SECS is the same transition seen from two events (a track
-- change and the matching state flip). queue.end and the test command do not
-- take part.
local DEDUP_SECS = 2
local last_announce = { path = nil, at = 0 }

local function recently_announced(path)
    return type(path) == "string" and path ~= ""
        and last_announce.path == path
        and (os.time() - last_announce.at) < DEDUP_SECS
end

local function mark_announced(path)
    if type(path) == "string" and path ~= "" then
        last_announce.path = path
        last_announce.at = os.time()
    end
end

-- Debounce: a burst of track.change events (fast skipping) coalesces into a
-- single notification for the track the user settles on. Art is fetched only
-- when the timer fires, so skipped tracks cost nothing.
local pending_id = nil
local pending_path = nil

local function cancel_pending()
    if pending_id then
        cliamp.timer.cancel(pending_id)
        pending_id = nil
        pending_path = nil
    end
end

local function announce_now(title, artist, album, path)
    if recently_announced(path) then
        return
    end
    mark_announced(path)
    notify(title, artist, album, path)
end

local prev_status = nil

p:on("track.change", function(track)
    local title, artist, album = track_text(track)
    if not title then
        return
    end
    if recently_announced(track.path) then
        return
    end
    if debounce_secs <= 0 then
        announce_now(title, artist, album, track.path)
        return
    end
    cancel_pending()
    pending_path = track.path
    pending_id = cliamp.timer.after(debounce_secs, function()
        pending_id = nil
        pending_path = nil
        announce_now(title, artist, album, track.path)
    end)
end)

p:on("playback.state", function(ev)
    local prev = prev_status
    prev_status = ev.status
    if not play_start_on then
        return
    end
    -- Only a transition INTO playing (not seeks/volume while already
    -- playing, and not the first event after plugin load).
    if ev.status ~= "playing" or prev == nil or prev == "playing" then
        return
    end
    if pending_id then
        if pending_path == ev.path then
            return -- the pending debounce timer delivers this track
        end
        cancel_pending() -- stale pending from an older track
    end
    local title, artist, album = track_text(ev)
    if not title then
        return
    end
    announce_now(title, artist, album, ev.path)
end)

p:on("playback.stop", function()
    cancel_pending()
end)

p:on("queue.end", function(track)
    cancel_pending()
    if not queue_end_on then
        return
    end
    local title, artist, album = track_text(track)
    title = title or ""
    artist = artist or ""
    album = album or ""
    local body = artist ~= "" and artist or album
    notify("Playlist finished", title, body, track.path)
end)

p:on("app.quit", function()
    cancel_pending()
end)

p:command("test", function()
    notify("mac-notify", "Test", "Notification from cliamp", cliamp.track.path())
    return "notification requested"
end)
