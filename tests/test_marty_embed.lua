-- Master Farmer vM 1.0.0: navigation is the embedded Marty Nav only.
--   * marty/nav loads, publishes nothing in _G (no AmeisenNav / MartyNav);
--   * its client has every call movement/sentinel.lua needs (K.SN_NEED);
--   * move_to POSTs JSON to the Marty path server and walks the answer with
--     simple_movement;
--   * no Lua file looks up AmeisenNav / Sentinel or the local nav server.
-- Run (from this folder):  luajit tests/test_marty_embed.lua
local ROOT = arg[1] or "."
package.path = ROOT .. "/?.lua;" .. package.path

local fails = 0
local function check(name, cond, extra)
    print((cond and "PASS " or "FAIL ") .. name .. ((not cond and extra ~= nil) and ("   [" .. tostring(extra) .. "]") or ""))
    if not cond then fails = fails + 1 end
end
local function auto(t)
    return setmetatable(t or {}, { __index = function() return function() return nil end end })
end

-- ---------------------------------------------------------------- core mock
local T = 100
local posts = {}
local PLAYER = { pos = { x = 0, y = 0, z = 0 } }
function PLAYER:get_position() return self.pos end
function PLAYER:is_valid() return true end
function PLAYER:is_dead() return false end
function PLAYER:is_casting_spell() return false end
function PLAYER:is_channelling_spell() return false end
core = auto({
    time = function() return T end,
    get_game_version = function() return "Tbc" end,
    get_instance_id = function() return 0 end,
    get_local_time = function() return "2026-10-10 12:00:00" end,
    http_post = function(url, headers, body, cb) posts[#posts + 1] = { url = url, headers = headers, body = body, cb = cb } end,
    object_manager = auto({ get_local_player = function() return PLAYER end }),
    input = auto({}),
})
package.preload["common/geometry/vector_3"] = function()
    local v = {}
    v.__index = v
    function v.new(x, y, z) return setmetatable({ x = x, y = y, z = z }, v) end
    return v
end
local walked = nil
package.preload["common/utility/simple_movement"] = function()
    return auto({
        navigate = function(_, pts) walked = pts; return true end,
        is_moving = function() return walked ~= nil end,
        process = function() return false end,
        get_current_index = function() return 1 end,
    })
end

-- ---------------------------------------------------------------- 1. load
local ok, nav = pcall(require, "marty/nav")
check("marty/nav loads", ok and type(nav) == "table", nav)
if not ok then os.exit(1) end
check("nothing published in _G.AmeisenNav", rawget(_G, "AmeisenNav") == nil)
check("nothing published in _G.MartyNav", rawget(_G, "MartyNav") == nil)

local api = nav.api()
local c = api and api.client
local need = { "move_to", "follow_path", "stop", "is_moving", "get_state", "validate_destination",
    "is_server_available", "health_check" }
local missing = {}
for _, n in ipairs(need) do if type(c and c[n]) ~= "function" then missing[#missing + 1] = n end end
check("client has every call the bot uses", #missing == 0, table.concat(missing, ","))

-- ---------------------------------------------------------------- 2. walk
local done
c:move_to({ x = 30, y = 40, z = 0 }, function(okm, why) done = { okm, why } end)
for _ = 1, 3 do T = T + 0.1; nav.update() end
local req = nil
for _, p in ipairs(posts) do
    if p.body:find('"x": 30.00', 1, true) then req = p end
end
check("move_to POSTs to the Marty path server", req and tostring(req.url):find("nav.deathwing.fyi/nav/path", 1, true) ~= nil,
    req and req.url)
check("the request is JSON with map, start and destination",
    req and req.body:find('"map"', 1, true) and req.body:find('"start"', 1, true)
    and req.body:find('"destination"', 1, true), req and req.body)
for _, p in ipairs(posts) do
    if p ~= req then p.cb(200, "application/json", '{"ok": true, "found": true, "points": [{"x": 0, "y": 0, "z": 0}, {"x": 1, "y": 1, "z": 0}]}') end
end
if req then
    req.cb(200, "application/json",
        '{"ok": true, "found": true, "points": [{"x": 0, "y": 0, "z": 0}, {"x": 15, "y": 20, "z": 0}, {"x": 30, "y": 40, "z": 0}]}')
end
for _ = 1, 3 do T = T + 0.1; nav.update() end
check("the answer is walked with simple_movement", type(walked) == "table" and #walked >= 2, walked and #walked)
check("navigating", c:get_state() == "navigating" or c:is_moving() == true, c:get_state())
c:stop()

-- ---------------------------------------------------------------- 3. no other navigation in the project
local function files(dir, out)
    out = out or {}
    local p = io.popen('dir /s /b "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul')
    if p then
        for line in p:lines() do out[#out + 1] = line end
        p:close()
    end
    return out
end
local bad = {}
for _, f in ipairs(files(ROOT == "." and (io.popen("cd"):read("*l")) or ROOT)) do
    if not f:find("\\tests\\", 1, true) then
        local h = io.open(f, "r")
        local s = h and h:read("*a") or ""
        if h then h:close() end
        for line in s:gmatch("[^\n]+") do
            local code = line:gsub("%-%-.*$", "")
            if code:find('rawget(_G, "AmeisenNav")', 1, true) or code:find("_G.AmeisenNav", 1, true)
                or code:find('require("ameisen', 1, true) or code:find("SentinelNavClient", 1, true)
                or code:find("47110", 1, true) or code:find("47111", 1, true) then
                bad[#bad + 1] = f:match("[^\\]+$") .. ": " .. code:sub(1, 60)
            end
        end
    end
end
check("no Lua file uses AmeisenNav, Sentinel or the local nav server", #bad == 0, table.concat(bad, " | "))
local h = io.open(ROOT .. "/movement/sentinel.lua", "r")
local sn = h and h:read("*a") or ""
if h then h:close() end
check("the bot's nav layer asks marty/nav", sn:find('require, "marty/nav"', 1, true) ~= nil)

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
