-- mac-notify.lua — Now Playing desktop notifications for cliamp on macOS
--
-- Sends a notification on every track change, and (optionally) when the queue
-- finishes. Uses terminal-notifier when it is installed, otherwise the
-- built-in osascript. When neither backend is available it falls back to
-- cliamp.notify (notify-send) so the plugin still works on Linux.
--
-- Requires the exec permission and the notifier binary in the allowlist:
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

local p = plugin.register({
    name = "mac-notify",
    type = "hook",
    version = "1.1.0",
    description = "macOS Now Playing notifications on track change and queue end",
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

local function osascript_args(title, subtitle, body)
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

local function terminal_notifier_args(title, subtitle, body)
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
    return args
end

local BACKENDS = {
    ["osascript"] = { bin = "osascript", args = osascript_args },
    ["terminal-notifier"] = { bin = "terminal-notifier", args = terminal_notifier_args },
}

local function try_backend(name, title, subtitle, body)
    local backend = BACKENDS[name]
    local handle, err = cliamp.exec.run(backend.bin, backend.args(title, subtitle, body), {
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

local function notify(title, subtitle, body)
    if active and try_backend(active, title, subtitle, body) then
        return
    end
    local errs = {}
    for _, name in ipairs(candidates()) do
        local ok, err = try_backend(name, title, subtitle, body)
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

p:on("track.change", function(track)
    local title, artist, album = track_text(track)
    if not title then
        return
    end
    notify(title, artist, album)
end)

p:on("queue.end", function(track)
    if not queue_end_on then
        return
    end
    local title, artist, album = track_text(track)
    title = title or ""
    artist = artist or ""
    album = album or ""
    local body = artist ~= "" and artist or album
    notify("Playlist finished", title, body)
end)

p:command("test", function()
    notify("mac-notify", "Test", "Notification from cliamp")
    return "notification requested"
end)
