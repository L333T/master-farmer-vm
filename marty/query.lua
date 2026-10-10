-- ============================================================================
-- Marty Nav - query.lua
-- Navmesh questions answered with the server's one call (a path).
-- ============================================================================
-- Server: POST {"map", "start": {x,y,z}, "destination": {x,y,z}} ->
--   {"ok", "found", "partial", "reason", "status", "ms", "length", "remaining",
--    "startSnap", "points": [{x,y,z,room}, ...]}
--
-- find_path(from, to, opts, cb)  cb(ok, points|nil, info)
--   points are fresh {x,y,z} tables (vec3 with opts.vec3), start included.
--   info = { code = "ok" | fail code, detail, partial, ms, cached, length }
--   Codes as AmeisenNav: start_off_mesh, end_off_mesh, no_path, unreachable,
--   map_not_loaded, server_timeout, server_down, bad_request.
--   A partial path counts when it ends within C.partial_accept of the goal or
--   opts.allow_partial is set; otherwise "unreachable".
--   Answers are cached C.path_cache_ttl s on a C.path_cache_grid yd grid and
--   identical requests in flight are merged.
--
-- The test server has no height / raycast / random-point call, so:
--   random_point  a random spot in the radius that a path reaches (its end)
--   raycast       "clear" when the path is nearly the straight line
--   get_height    not available (cb(false, nil, {code="unsupported"}))
--   move_along_surface  the end of a partial-allowed path toward `to`
-- ============================================================================

local C = require("marty/config")
local T = require("marty/transport")
local json = require("marty/json")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local Q = {}

local cache = {}       -- key -> { t, ok, points, info }
local cache_n = 0
local waiting = {}     -- key -> { cb, ... } merged in-flight requests
Q.stats = { requests = 0, cached = 0, last_ms = nil, last_rtt = 0, last_code = "" }

local function now()
    local ok, t = pcall(core.time)
    return (ok and type(t) == "number") and t or 0
end

function Q.xyz(p)
    if p == nil then return nil end
    local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return { x = x, y = y, z = z }
    end
    return nil
end

function Q.dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Q.path_length(points)
    local d = 0
    for i = 2, #points do d = d + Q.dist3(points[i - 1], points[i]) end
    return d
end

local MAP_ID_FN = function() return 0 end
function Q.set_map_fn(fn) MAP_ID_FN = fn end

local function f2(n) return string.format("%.2f", n) end

function Q.body(map_id, a, b)
    return string.format(
        '{"map": %d, "start": {"x": %s, "y": %s, "z": %s}, "destination": {"x": %s, "y": %s, "z": %s}}',
        map_id, f2(a.x), f2(a.y), f2(a.z), f2(b.x), f2(b.y), f2(b.z))
end

local function key(map_id, a, b)
    local g = C.path_cache_grid
    local function s(v) return math.floor(v / g + 0.5) end
    return table.concat({ map_id, s(a.x), s(a.y), s(a.z), s(b.x), s(b.y), s(b.z) }, ":")
end

local function copy_points(points, as_vec3)
    local out = {}
    for i, p in ipairs(points) do
        out[i] = as_vec3 and vec3.new(p.x, p.y, p.z) or { x = p.x, y = p.y, z = p.z }
    end
    return out
end

---Map a server answer to (ok, points, info).
function Q.read_answer(ok_http, code, body)
    if not ok_http then
        if code == "server_down" then return false, nil, { code = "server_down", detail = "server not reachable" } end
        if code == "busy" then return false, nil, { code = "server_timeout", detail = "request queue full" } end
        if code == "timeout" then return false, nil, { code = "server_timeout", detail = "no answer in time" } end
        return false, nil, { code = "server_timeout", detail = "transport error" }
    end
    local data = json.decode(body)
    if type(data) ~= "table" then
        return false, nil, { code = "server_timeout", detail = "unreadable answer (HTTP " .. tostring(code) .. ")" }
    end
    if data.ok ~= true then
        return false, nil, { code = "bad_request", detail = tostring(data.status or ("HTTP " .. tostring(code))) }
    end
    local info = { detail = tostring(data.status or ""), ms = tonumber(data.ms), partial = data.partial == true,
                   length = tonumber(data.length), remaining = tonumber(data.remaining) }
    if data.found ~= true then
        local r = tostring(data.reason or "")
        if r == "" then r = "no_path" end
        if r ~= "start_off_mesh" and r ~= "end_off_mesh" and r ~= "no_path" and r ~= "map_not_loaded" then
            info.server_reason = r
            r = r:find("map") and "map_not_loaded" or "no_path"
        end
        info.code = r
        return false, nil, info
    end
    local points = {}
    if type(data.points) == "table" then
        for _, p in ipairs(data.points) do
            local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
            if x and y and z then points[#points + 1] = { x = x, y = y, z = z } end
        end
    end
    if #points == 0 then
        info.code = "no_path"
        return false, nil, info
    end
    info.code = "ok"
    return true, points, info
end

---@param opts table|nil { map, allow_partial, no_cache, vec3 }
function Q.find_path(from, to, opts, cb)
    opts = opts or {}
    local a, b = Q.xyz(from), Q.xyz(to)
    if not a or not b then
        pcall(cb, false, nil, { code = "bad_request", detail = "bad start or end" })
        return
    end
    local map_id = opts.map or MAP_ID_FN()
    if type(map_id) ~= "number" then
        pcall(cb, false, nil, { code = "map_not_loaded", detail = "no map id" })
        return
    end
    local k = key(map_id, a, b)
    local function deliver(ok, points, info, cached)
        local i2 = {}
        for kk, v in pairs(info) do i2[kk] = v end
        i2.cached = cached
        if ok and info.partial then
            local last = points[#points]
            local short = info.remaining or Q.dist3(last, b)
            if short > C.partial_accept and not opts.allow_partial then
                i2.code = "unreachable"
                i2.detail = string.format("partial path stops %.1f yd short", short)
                pcall(cb, false, nil, i2)
                return
            end
        end
        pcall(cb, ok, ok and copy_points(points, opts.vec3) or nil, i2)
    end
    local hit = not opts.no_cache and cache[k]
    if hit and now() - hit.t <= C.path_cache_ttl then
        Q.stats.cached = Q.stats.cached + 1
        deliver(hit.ok, hit.points, hit.info, true)
        return
    end
    if waiting[k] then
        local list = waiting[k]
        list[#list + 1] = deliver
        return
    end
    waiting[k] = { deliver }
    Q.stats.requests = Q.stats.requests + 1
    local t0 = now()
    T.post(Q.body(map_id, a, b), function(ok_http, code, body)
        local ok, points, info = Q.read_answer(ok_http, code, body)
        Q.stats.last_rtt, Q.stats.last_ms, Q.stats.last_code = now() - t0, info.ms, info.code
        local transient = info.code == "server_timeout" or info.code == "server_down"
        if not transient then
            if not cache[k] then cache_n = cache_n + 1 end
            cache[k] = { t = now(), ok = ok, points = points, info = info }
            if cache_n > C.path_cache_size then
                cache, cache_n = {}, 0
            end
        end
        local list = waiting[k] or {}
        waiting[k] = nil
        for i = 1, #list do list[i](ok, points, info, false) end
    end)
end

function Q.clear_cache() cache, cache_n = {}, 0 end

---Several paths: cb(ok, results) with results[i] = { ok, points, info }.
function Q.find_paths(pairs_list, opts, cb)
    local n, done, results = #pairs_list, 0, {}
    if n == 0 then pcall(cb, true, {}, { code = "ok" }) return end
    for i, pr in ipairs(pairs_list) do
        Q.find_path(pr[1], pr[2], opts, function(ok, points, info)
            results[i] = { ok = ok, points = points, info = info }
            done = done + 1
            if done == n then pcall(cb, true, results, { code = "ok" }) end
        end)
    end
end

function Q.get_height(_pos, cb)
    pcall(cb, false, nil, { code = "unsupported", detail = "the nav server has no height query" })
end

---"clear" when the path is within 10% (and 1 yd) of the straight line.
function Q.raycast(from, to, cb, opts)
    local a, b = Q.xyz(from), Q.xyz(to)
    if not a or not b then pcall(cb, false, nil, nil, { code = "bad_request" }) return end
    Q.find_path(a, b, opts, function(ok, points, info)
        if not ok then pcall(cb, true, false, nil, info) return end
        local straight = Q.dist3(a, b)
        local len = Q.path_length(points)
        local clear = len <= straight * 1.1 + 1.0 and #points <= 3
        pcall(cb, true, clear, (not clear) and points[2] or nil, info)
    end)
end

---The end of a path toward `to` (partial allowed): how far the mesh goes.
function Q.move_along_surface(from, to, cb, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    o.allow_partial = true
    Q.find_path(from, to, o, function(ok, points, info)
        if not ok then pcall(cb, false, nil, info) return end
        pcall(cb, true, points[#points], info)
    end)
end

---A reachable random point within `radius` of `center`: up to 4 tries.
function Q.random_point(center, radius, cb, opts)
    local c = Q.xyz(center)
    if not c then pcall(cb, false, nil, { code = "bad_request" }) return end
    local tries = 0
    local function try()
        tries = tries + 1
        local ang = math.random() * math.pi * 2
        local r = (0.4 + math.random() * 0.6) * (radius or 8)
        local cand = { x = c.x + math.cos(ang) * r, y = c.y + math.sin(ang) * r, z = c.z }
        local o = { allow_partial = true, no_cache = true }
        for k, v in pairs(opts or {}) do o[k] = v end
        Q.find_path(c, cand, o, function(ok, points, info)
            if ok and points and #points >= 1 then
                local p = points[#points]
                pcall(cb, true, vec3.new(p.x, p.y, p.z), info)
            elseif tries < 4 and info.code ~= "server_down" and info.code ~= "start_off_mesh" then
                try()
            else
                pcall(cb, false, nil, info)
            end
        end)
    end
    try()
end

return Q
