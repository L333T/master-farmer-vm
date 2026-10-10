-- ============================================================================
-- Marty Nav - journal.lua
-- Session log + crash breadcrumbs: scripts_log/marty_nav/session_<time>.log
-- ============================================================================
-- A game crash happens INSIDE a native call, with no Lua error to catch. So
-- every risky call is written to disk BEFORE it is made ("> label") and after
-- it returns ("< label"): the last "> label" without its "<" in a crashed
-- session names the call the game died in.
--
--   Event calls (rare: http_post, an HTTP answer, navigate, stop, steering,
--   jump, back-off) are always journaled.
--   Per-frame calls (process, the player reads, the path drawing) only with
--   the menu's "Crash breadcrumbs: every frame" - that writes ~10 lines a
--   frame, so only for a crash hunt.
-- J.info / J.event lines record what the navigator did (paths, results).
-- core.write_log_file appends a line at a time (as the Grindbot's log).
-- ============================================================================

local J = {}

local FOLDER = "marty_nav"
local MAX_LINES = 40000
local path = nil
local lines = 0
J.per_frame = false

local function stamp()
    local ok, t = pcall(core.time)
    return string.format("t=%.2f", (ok and type(t) == "number") and t or 0)
end

local function open()
    if path or type(core.write_log_file) ~= "function" then return path end
    local ok, lt = pcall(function() return core.get_local_time() end)
    local name = "session"
    if ok and type(lt) == "table" and lt.year then
        name = string.format("session_%04d-%02d-%02d_%02d-%02d-%02d", lt.year, lt.month or 0, lt.day or 0,
            lt.hour or 0, lt.min or lt.minute or 0, lt.sec or lt.second or 0)
    else
        local ok2, t = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
        if ok2 and type(t) == "string" then name = "session_" .. t end
    end
    pcall(function() core.create_log_folder(FOLDER) end)
    path = FOLDER .. "/" .. name .. ".log"
    pcall(function() core.create_log_file(path) end)
    return path
end

local function write(kind, text)
    if lines >= MAX_LINES then return end
    local p = open()
    if not p then return end
    lines = lines + 1
    pcall(core.write_log_file, p, string.format("%s  %-5s %s\n", stamp(), kind, text))
end

local function pack(...) return { n = select("#", ...), ... } end

function J.info(fmt, ...) write("INFO", string.format(fmt, ...)) end
function J.event(fmt, ...) write("EVENT", string.format(fmt, ...)) end

---Journal a native call: "> label" before, "< label" after.
---per_frame calls are journaled only when J.per_frame is on.
function J.call(label, per_frame, fn, ...)
    local on = not per_frame or J.per_frame
    if on then write(">", label) end
    local r = pack(pcall(fn, ...))
    if on then write("<", label) end
    return (table.unpack or unpack)(r, 1, r.n)
end

function J.path() return path end

return J
