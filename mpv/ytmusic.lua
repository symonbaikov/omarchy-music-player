-- Loaded into the plugin's own mpv (bin/ytmusic-mpv start_player).
--
-- Fades: fade_in / fade_out seconds at the start and end of each song,
-- through mpv's volume-gain. That leaves the user's volume alone.
--
-- Peak mix (transition=peak): as each song starts, ask the helper to
-- render the next one so that it opens with this song's climax crossfading
-- into the next song's climax (bin/ytmusic-mpv mixprep). When it's ready,
-- the rendered file replaces the next entry and this song is set to end
-- where the file takes over, so mpv joins them without a gap.
--
-- Backup sources: when a song's stream can't be opened (YouTube changed
-- something, a client broke, a bot check), the on_load_fail hook asks the
-- helper for another source (bin/ytmusic-mpv fallback): the cached audio,
-- or a download through YouTube's other clients. The song then plays with
-- no skip. A stream that breaks mid-song is started again where it broke.
-- Results go to user-data/ytmusic/* for the panel to show.
--
-- Settings come as script-opts at start (ytmusic-<key>=<value>) and later
-- as `script-message ytmusic-set <key> <value>` from the panel.

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local opts = {
    helper = "",
    python = "python3",
    fade_in = 0,
    fade_out = 0,
    transition = "off",
    xfade = 6,
}
require("mp.options").read_options(opts, "ytmusic")

-- The mix must be ready at least this long before the playing song's exit.
local MIX_MARGIN = 12
local SILENT_DB = -96

local function clamp(v, lo, hi, default)
    v = tonumber(v)
    if not v then return default end
    return math.max(lo, math.min(hi, v))
end
opts.fade_in = clamp(opts.fade_in, 0, 30, 0)
opts.fade_out = clamp(opts.fade_out, 0, 30, 0)
opts.xfade = clamp(opts.xfade, 2, 16, 6)
if opts.transition ~= "peak" then opts.transition = "off" end

local function entry_name(i)
    return mp.get_property("playlist/" .. i .. "/filename")
end

local function is_segment(name)
    return name ~= nil and name:match("/seg%-[%w_-]+%-[%w_-]+%.flac$") ~= nil
end

local function current_pos()
    return mp.get_property_number("playlist-pos", -1)
end

-- ---- peak mix ---------------------------------------------------------------

local mix = nil   -- { pos, from, to, orig, title, state = "pending" | "ready" | "done", exit }

-- Undo a ready mix: the playing song plays to its end again, and if the
-- rendered segment is still next, the song's own entry goes back (the
-- segment would repeat this song's ending).
local function cancel_mix()
    local job = mix
    mix = nil
    if not job or job.state ~= "ready" or current_pos() ~= job.pos then return end
    mp.set_property("file-local-options/end", "none")
    if entry_name(job.pos + 1) == job.to then
        local file_opts = job.title ~= "" and ("force-media-title=%" .. #job.title .. "%" .. job.title) or ""
        mp.command_native({"loadfile", job.orig, "insert-at", job.pos + 1, file_opts})
        mp.command_native({"playlist-remove", job.pos + 2})
    end
end

local function on_prepared(job, success, res)
    if mix ~= job then return end
    local out
    if success and res then
        for line in (res.stdout or ""):gmatch("[^\n]+") do
            local d = utils.parse_json(line)
            if type(d) == "table" and (d.type == "mix" or d.type == "error") then out = d end
        end
    end
    if not out or out.type ~= "mix" or not out.ok then
        job.state = "done"
        msg.warn("peak mix skipped: " .. tostring(out and (out.reason or out.message) or "helper failed"))
        return
    end
    -- Only if nothing moved while it rendered.
    local pos = current_pos()
    if pos ~= job.pos or entry_name(pos) ~= job.from or entry_name(pos + 1) ~= job.to then
        job.state = "done"
        return
    end
    local exit = tonumber(out.exit)
    local t = mp.get_property_number("time-pos", 0)
    if not exit or exit < t + 2 or type(out.path) ~= "string" then
        job.state = "done"
        msg.warn("peak mix ready too late")
        return
    end
    local title = mp.get_property("playlist/" .. (pos + 1) .. "/title") or ""
    local file_opts = title ~= "" and ("force-media-title=%" .. #title .. "%" .. title) or ""
    mp.command_native({"loadfile", out.path, "insert-at", pos + 1, file_opts})
    mp.command_native({"playlist-remove", pos + 2})
    mp.set_property("file-local-options/end", string.format("%.3f", exit))
    job.state = "ready"
    job.orig = job.to
    job.title = title
    job.to = out.path
    job.exit = exit
    msg.info(string.format("peak mix ready: leaving at %.1f s", exit))
end

local function prepare()
    if opts.transition ~= "peak" or opts.helper == "" then return end
    if mp.get_property("loop-file") ~= "no" then return end
    local pos = current_pos()
    local count = mp.get_property_number("playlist-count", 0)
    if pos < 0 or pos + 1 >= count then return end
    local cur, nxt = entry_name(pos), entry_name(pos + 1)
    if not cur or not nxt or is_segment(nxt) then return end
    if mix and mix.pos == pos and mix.from == cur and mix.to == nxt then return end
    local raw = mp.get_property_native("ytdl-raw-options") or {}
    local job = { pos = pos, from = cur, to = nxt, state = "pending" }
    mix = job
    local t = mp.get_property_number("time-pos", 0) or 0
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            opts.python, "-I", opts.helper, "mixprep", cur, nxt,
            "--xfade", tostring(opts.xfade),
            "--min-exit", string.format("%.1f", t + MIX_MARGIN),
            "--cookies-spec", raw["cookies-from-browser"] or "",
        },
    }, function(success, res) on_prepared(job, success, res) end)
end

-- The queue changed (radio, autoplay): a mix into an entry that is gone
-- would cut this song short, so undo it and look again.
local function check_queue()
    if mix then
        local pos = current_pos()
        if pos ~= mix.pos or entry_name(pos + 1) ~= mix.to then cancel_mix() end
    end
    prepare()
end

-- ---- fades -----------------------------------------------------------------

local applied_db = 0

local function set_gain(db)
    if math.abs(db - applied_db) < 0.05 then return end
    applied_db = db
    mp.set_property_number("volume-gain", db)
end

-- Quadratic amplitude: sounds even to the ear, unlike a linear ramp.
local function amp_to_db(amp)
    if amp >= 1 then return 0 end
    if amp <= 0.004 then return SILENT_DB end
    return math.max(SILENT_DB, 40 * math.log(amp, 10))
end

local function fade_amp()
    local t = mp.get_property_number("time-pos")
    if not t then return 1 end
    local pos = current_pos()
    local amp = 1
    -- A rendered segment opens with its own crossfade.
    if opts.fade_in > 0 and t < opts.fade_in and not is_segment(entry_name(pos)) then
        amp = math.min(amp, t / opts.fade_in)
    end
    -- Into a rendered segment, the crossfade replaces the fade out.
    if opts.fade_out > 0 and not is_segment(entry_name(pos + 1)) then
        local duration = mp.get_property_number("duration")
        if duration and duration > 0 then
            amp = math.min(amp, (duration - t) / opts.fade_out)
        end
    end
    return math.max(0, amp)
end

local function tick()
    if opts.fade_in <= 0 and opts.fade_out <= 0 then
        set_gain(0)
        return
    end
    set_gain(amp_to_db(fade_amp()))
end

mp.add_periodic_timer(0.05, tick)

-- ---- backup sources ---------------------------------------------------------

-- Reasons about the song itself: no other source gets past them. (A
-- region block or an age check isn't here: with backup mirrors on, a
-- mirror elsewhere may serve the song. The helper decides.)
local CONTENT_ERRORS = {
    "members", "private video", "removed", "copyright", "terminated", "account associated",
}
local last_ytdl_error = ""
local failures = 0        -- songs in a row that no source could play

local function is_content_error(text)
    local lower = (text or ""):lower()
    for _, needle in ipairs(CONTENT_ERRORS) do
        if lower:find(needle, 1, true) then return true end
    end
    return false
end

-- Spotify and cloud songs are queued under these schemes (see "Spotify and
-- cloud songs" below).
local SPOTIFY = "ytmusic-spotify://"
local CLOUD = "ytmusic-cloud://"

local function watch_id(url)
    return url and url:match("^https://music%.youtube%.com/watch%?v=([%w_-]+)$")
end

local function report_health(ok, reason)
    if ok then
        if failures > 0 then
            failures = 0
            mp.set_property_native("user-data/ytmusic/health", { state = "ok", at = os.time() })
        end
        return
    end
    failures = failures + 1
    -- One song failing is that song; several in a row is YouTube or yt-dlp.
    if failures >= 2 then
        mp.set_property_native("user-data/ytmusic/health",
            { state = "failing", reason = tostring(reason or ""):sub(1, 200), at = os.time() })
    end
end

mp.enable_messages("error")
mp.register_event("log-message", function(e)
    if e.prefix == "ytdl_hook" and e.text:match("^ERROR:") then last_ytdl_error = e.text end
end)

mp.add_hook("on_load_fail", 50, function(hook)
    local url = mp.get_property("stream-open-filename")
    local id = watch_id(url)
    if not id or opts.helper == "" or is_content_error(last_ytdl_error) then return end
    local reason = last_ytdl_error
    hook:defer()
    local raw = mp.get_property_native("ytdl-raw-options") or {}
    msg.warn("stream failed, trying backup sources for " .. id)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { opts.python, "-I", opts.helper, "fallback", id, "--cookies-spec", raw["cookies-from-browser"] or "" },
    }, function(success, res)
        local out
        if success and res then
            for line in (res.stdout or ""):gmatch("[^\n]+") do
                local d = utils.parse_json(line)
                if type(d) == "table" and d.type == "fallback" then out = d end
            end
        end
        if out and out.ok and type(out.path) == "string" then
            mp.set_property("stream-open-filename", out.path)
            mp.set_property_native("user-data/ytmusic/fallback", { id = id, via = tostring(out.via), at = os.time() })
            msg.warn("playing " .. id .. " from a backup source: " .. tostring(out.via))
            report_health(true)
        else
            msg.warn("no backup source for " .. id .. ": " .. tostring(out and out.reason or "helper failed"))
            report_health(false, out and out.reason or reason)
            -- The panel offers backup mirrors when they're off and could help.
            mp.set_property_native("user-data/ytmusic/unplayable", {
                id = id,
                reason = tostring(out and out.reason or reason or ""):sub(1, 300),
                mirrors = tostring(out and out.mirrors or "unknown"),
                hopeless = out and out.hopeless == true or false,
                at = os.time(),
            })
        end
        hook:cont()
    end)
end)

-- A stream that ends early (the network dropped before the song was
-- buffered) is opened again where it stopped, once per song.
local played_to = 0
local loaded_entry = nil  -- playlist entry id of the file that opened
local last_duration = 0
local resumed = {}

mp.observe_property("duration", "number", function(_, d)
    if d and d > 0 then last_duration = d end
end)

mp.observe_property("time-pos", "number", function(_, t)
    if t then played_to = t end
end)

mp.register_event("end-file", function(e)
    local t, entry_id = played_to, e.playlist_entry_id
    played_to = 0
    if e.reason ~= "eof" and e.reason ~= "error" then return end
    -- Only a song that opened and played; one that never opened is skipped
    -- (or rescued by the on_load_fail hook above).
    if t < 0.5 or not entry_id or entry_id ~= loaded_entry then return end
    local list = mp.get_property_native("playlist") or {}
    local index, entry
    for i, item in ipairs(list) do
        if item.id == entry_id then index, entry = i - 1, item end
    end
    local name = entry and entry.filename or ""
    if not entry or not (watch_id(name) or name:sub(1, #SPOTIFY) == SPOTIFY or name:sub(1, #CLOUD) == CLOUD
        or name:match("^https://[%w.]*soundcloud%.com/")) then return end
    -- A mix ending this song early, or the song simply finishing.
    if mix and mix.state == "ready" and mix.pos == index then return end
    if e.reason == "eof" and (last_duration <= 0 or t > last_duration - 4) then return end
    local key = entry.filename .. "@" .. math.floor(t / 30)
    if resumed[key] then return end
    resumed[key] = true
    msg.warn(string.format("stream broke at %.1f s, opening it again", t))
    local title = entry.title or ""
    local file_opts = string.format("start=%.1f", t)
    if title ~= "" then file_opts = file_opts .. ",force-media-title=%" .. #title .. "%" .. title end
    mp.command_native({ "loadfile", entry.filename, "insert-at", index + 1, file_opts })
    mp.command_native({ "playlist-remove", index })
    mp.command_native({ "playlist-play-index", index })
end)

-- ---- Spotify and cloud songs ------------------------------------------------
-- A Spotify song is queued as ytmusic-spotify://<id>, a file in the user's
-- cloud storage as ytmusic-cloud://<source>/<hash>. Before yt-dlp looks at
-- one (ytdl_hook's on_load runs at priority 10), ask the helper what to open:
-- the Spotify song's YouTube Music match, or the file on the local rclone
-- server. The entry keeps its name, so the panel still knows which song it is.
local function resolved_ok(kind, url)
    if kind == "sp" then return watch_id(url) ~= nil end
    return url:match("^http://[%w]+:[%w]+@127%.0%.0%.1:%d+/") ~= nil
end

local used_cloud = false

mp.add_hook("on_load", 5, function(hook)
    local url = mp.get_property("stream-open-filename") or ""
    if opts.helper == "" then return end
    local kind, key
    if url:sub(1, #SPOTIFY) == SPOTIFY then
        kind, key = "sp", url:sub(#SPOTIFY + 1)
        if not key:match("^[%w]+$") then return end
    elseif url:sub(1, #CLOUD) == CLOUD then
        kind, key = "cl", url:sub(#CLOUD + 1)
        if not key:match("^[%x]+/[%x]+$") then return end
        used_cloud = true
    else
        return
    end
    hook:defer()
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { opts.python, "-I", opts.helper, "resolve", kind .. ":" .. key },
    }, function(success, res)
        local out
        if success and res then
            for line in (res.stdout or ""):gmatch("[^\n]+") do
                local d = utils.parse_json(line)
                if type(d) == "table" and (d.type == "resolved" or d.type == "error") then out = d end
            end
        end
        if out and out.type == "resolved" and type(out.url) == "string" and resolved_ok(kind, out.url) then
            mp.set_property("stream-open-filename", out.url)
        elseif kind == "sp" then
            msg.warn("no YouTube Music match for Spotify song " .. key .. ": " .. tostring(out and out.message or "helper failed"))
        else
            msg.error("cloud song " .. key .. " can't be opened: " .. tostring(out and out.message or "helper failed"))
        end
        hook:cont()
    end)
end)

-- The local rclone server only serves this player: stop it with the player.
mp.register_event("shutdown", function()
    if opts.helper == "" or not used_cloud then return end
    mp.command_native({
        name = "subprocess",
        detach = true,
        playback_only = false,
        -- Unless a newer player (another pid) took over and may be using it.
        args = { opts.python, "-I", opts.helper, "cloud-stop", "--player", tostring(mp.get_property("pid") or "") },
    })
end)

-- ---- events ----------------------------------------------------------------

mp.register_event("start-file", function()
    last_ytdl_error = ""
    last_duration = 0
end)

mp.register_event("file-loaded", function()
    loaded_entry = mp.get_property_number("playlist/" .. current_pos() .. "/id")
    -- It opened, through its usual stream or a backup one.
    if mp.get_property("stream-open-filename") == mp.get_property("path") then report_health(true) end
    -- Start silent when fading in, before the first tick.
    if opts.fade_in > 0 and not is_segment(entry_name(current_pos())) then
        set_gain(SILENT_DB)
    else
        tick()
    end
    -- A mix belongs to the entry it was made for.
    if mix and mix.pos ~= current_pos() then mix = nil end
    prepare()
end)

mp.observe_property("playlist-count", "number", function() check_queue() end)

mp.observe_property("loop-file", "string", function(_, value)
    if value ~= "no" then cancel_mix() else prepare() end
end)

mp.register_script_message("ytmusic-set", function(key, value)
    if key == "fade_in" then
        opts.fade_in = clamp(value, 0, 30, 0)
    elseif key == "fade_out" then
        opts.fade_out = clamp(value, 0, 30, 0)
    elseif key == "xfade" then
        opts.xfade = clamp(value, 2, 16, 6)
    elseif key == "transition" then
        opts.transition = value == "peak" and "peak" or "off"
        if opts.transition == "peak" then prepare() else cancel_mix() end
    end
    tick()
end)
