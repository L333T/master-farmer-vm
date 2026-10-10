-- ============================================================================
-- Marty Nav - client.lua
-- The navigation client: the same public API as AmeisenNav's client, so the
-- Master Farmer products (Questing & Grinding, Route Tool, Intelligent Ally)
-- run on the nav server unchanged.
-- ============================================================================
-- Movement   move_to(target, cb, opts{allow_partial, flags, seamless})
--            move_direct(target, cb)   follow_path(waypoints, cb)
--            replan(reason)  stop()  pause(reason)  resume(reason)
-- Queries    find_path(from, to, cb, opts) -> cb(ok, points, info)
--            validate_destination(target, cb) -> cb(reachable, code, length)
--            get_height / get_player_height -> cb(false) (server has none)
--            raycast(from, to, cb)  random_point(center, r, cb)
--            kite(player, target, cb)  flee(player, threats, cb) -> cb(vec3|nil)
--            plan_route(nodes, cb) -> cb(ok, {waypoints, visit_order, total_distance})
-- Status     get_state() idle|planning|navigating|arrived|failed
--            get_full_state() e.g. "navigating.recovering.jump"
--            is_moving  is_busy  get_destination  get_current_path
--            get_path_index  get_progress  get_last_failure  get_last_path
--            is_server_available  health_check(cb)  get_config  update_config
-- Events     on(event, fn) -> id / off(id): state_change(new, old), path(points),
--            arrived(dest), failed(code, detail), stuck(level), repath(reason),
--            server(up)
-- Callback   cb(success, reason, detail{code, detail}) exactly once; codes:
--            arrived, cancelled, unreachable, start_off_mesh, end_off_mesh,
--            no_path, map_not_loaded, server_timeout, server_down,
--            max_stuck_exceeded, max_repath_exceeded, bad_request.
--
-- Walking: simple_movement:navigate(points) and process() every update
-- (client:update(), called by main.lua - consumers never call it). Steering
-- look_at, except WoW Forever where look_at does not turn: turn keys there.
-- Stuck (less than stuck_min_move in stuck_window s): 1 jump, 2 repath,
-- 3 detour to a random reachable point within 5 yd, 4 back off then repath,
-- 5 jump + repath, then fail max_stuck_exceeded. 3 yd of progress resets it.
-- More than deviation_limit off the path repaths at once.
-- ============================================================================

local C = require("marty/config")
local J = require("marty/journal")
local T = require("marty/transport")
local Q = require("marty/query")
---@type simple_movement
local movement = require("common/utility/simple_movement")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local client = {}
client.__index = client

local nav = nil                 -- the active navigation record
local nav_seq = 0
local state, full = "idle", "idle"
local last_failure = { code = "", detail = "", t = 0 }
local last_path = nil
local listeners, listener_id = {}, 0
local pauses = {}
local moving_paused = false
local forever = false
local look_at_set = nil

local function now()
    local ok, t = pcall(core.time)
    return (ok and type(t) == "number") and t or 0
end

-- ----------------------------------------------------------------- player --
local function player()
    local ok, p = J.call("get_local_player", true, function() return core.object_manager.get_local_player() end)
    if ok and p then return p end
    local ok2, p2 = J.call("get_object_from_guid(player)", true,
        function() return core.object_manager.get_object_from_guid("player") end)
    if ok2 and p2 then return p2 end
    return nil
end

local function player_pos()
    local p = player()
    if not p then return nil end
    local ok, pos = J.call("player:get_position", true, function() return p:get_position() end)
    return ok and Q.xyz(pos) or nil
end

local function casting()
    local p = player()
    if not p then return false end
    local ok1, c = J.call("player:is_casting_spell", true, function() return p:is_casting_spell() end)
    local ok2, ch = J.call("player:is_channelling_spell", true, function() return p:is_channelling_spell() end)
    return (ok1 and c == true) or (ok2 and ch == true)
end

function client.set_forever(on) forever = on == true end

-- ----------------------------------------------------------------- events --
local function emit(ev, ...)
    for _, l in pairs(listeners) do
        if l.ev == ev then pcall(l.fn, ...) end
    end
end

function client:on(ev, fn)
    listener_id = listener_id + 1
    listeners[listener_id] = { ev = ev, fn = fn }
    return listener_id
end

function client:off(id_or_ev, fn)
    if fn == nil then listeners[id_or_ev] = nil return end
    for k, l in pairs(listeners) do
        if l.ev == id_or_ev and l.fn == fn then listeners[k] = nil end
    end
end

T.on_server_change(function(up) emit("server", up) end)

local function set_state(s, sub)
    local new_full = sub and (s .. "." .. sub) or s
    if new_full == full then return end
    local old = full
    state, full = s, new_full
    emit("state_change", new_full, old)
end

-- --------------------------------------------------------------- movement --
local function steer()
    local want
    if C.use_look_at == "look_at" then want = true
    elseif C.use_look_at == "turns" then want = false
    else want = not forever end
    if want ~= look_at_set then
        J.call("simple_movement:set_use_look_at(" .. tostring(want) .. ")", false,
            function() movement:set_use_look_at(want) end)
        look_at_set = want
    end
end

local function halt()
    J.call("simple_movement:stop", false, function() movement:stop() end)
    J.call("simple_movement:clear_navigation", false, function() movement:clear_navigation() end)
end

local function walk(points)
    steer()
    local list = {}
    for i, p in ipairs(points) do list[i] = vec3.new(p.x, p.y, p.z) end
    J.call("simple_movement:resume", false, function() movement:resume() end)
    local ok, started = J.call("simple_movement:navigate(" .. #list .. " points)", false,
        function() return movement:navigate(list, false, true) end)
    moving_paused = false
    return ok and started ~= false
end

-- ------------------------------------------------------------------- end ---
local function finish(rec, success, code, detail)
    if rec.done then return end
    rec.done = true
    J.event("%s #%d %s %s", rec.kind, rec.seq, success and "arrived" or tostring(code), tostring(detail or ""))
    if nav == rec then nav = nil end
    if success then
        set_state("arrived")
        emit("arrived", rec.target)
    else
        if code == "cancelled" then
            set_state("idle")
        else
            last_failure = { code = code, detail = detail or "", t = now() }
            set_state("failed")
            emit("failed", code, detail or "")
        end
    end
    if rec.cb then
        pcall(rec.cb, success == true, success and "arrived" or tostring(detail ~= "" and detail or code),
            { code = success and "arrived" or code, detail = detail or "" })
    end
end

local function cancel_current(keep_walking)
    if nav then
        local rec = nav
        nav = nil
        if not keep_walking then halt() end
        rec.done = true
        if rec.cb then pcall(rec.cb, false, "stopped", { code = "cancelled", detail = "replaced or stopped" }) end
    end
end

-- -------------------------------------------------------------- planning ---
local function start_walk(rec, points)
    J.event("%s #%d walk %d points%s", rec.kind, rec.seq, #points,
        rec.recovering and (" (recovering " .. rec.recovering .. ")") or "")
    rec.path = points
    rec.index = math.min(2, #points)
    rec.walking = true
    rec.sample_t, rec.sample_pos = now(), player_pos()
    rec.progress_from = rec.sample_pos
    last_path = points
    if not walk(points) then
        return finish(rec, false, "bad_request", "simple_movement refused the path")
    end
    set_state("navigating", rec.recovering and ("recovering." .. rec.recovering) or nil)
    emit("path", points)
end

---Ask the server for a path for `rec` from where we stand.
local function plan(rec, reason)
    local pos = player_pos()
    if not pos then return finish(rec, false, "bad_request", "no player position") end
    rec.planning = true
    if not rec.walking then set_state("planning", reason) end
    local goal = rec.target
    local tail = nil
    if rec.kind == "path" then
        -- rejoin the route at the waypoint being approached
        local i = math.max(1, math.min(rec.wp_index or 1, #rec.waypoints))
        goal = rec.waypoints[i]
        tail = {}
        for k = i + 1, #rec.waypoints do tail[#tail + 1] = rec.waypoints[k] end
    end
    local my = rec.seq
    J.event("%s #%d plan (%s) %.1f %.1f %.1f -> %.1f %.1f %.1f", rec.kind, rec.seq, tostring(reason),
        pos.x, pos.y, pos.z, goal.x, goal.y, goal.z)
    Q.find_path(pos, goal, { allow_partial = rec.opts.allow_partial }, function(ok, points, info)
        if nav ~= rec or rec.done or rec.seq ~= my then return end
        rec.planning = false
        if not ok then
            return finish(rec, false, info.code or "no_path", info.detail or "")
        end
        if tail then for _, p in ipairs(tail) do points[#points + 1] = { x = p.x, y = p.y, z = p.z } end end
        start_walk(rec, points)
    end)
end

local function new_nav(kind, target, cb, opts)
    opts = opts or {}
    local seamless = opts.seamless == true and nav ~= nil and nav.walking
    cancel_current(seamless)
    nav_seq = nav_seq + 1
    local rec = { seq = nav_seq, kind = kind, target = target, cb = cb, opts = opts,
                  repaths = 0, stuck = 0, started = now() }
    nav = rec
    if seamless then rec.walking = true end      -- keep walking the old path until the new one arrives
    return rec
end

function client:move_to(target, cb, opts)
    local t = Q.xyz(target)
    if not t then
        if cb then pcall(cb, false, "bad target", { code = "bad_request", detail = "bad target" }) end
        return false
    end
    local rec = new_nav("move", t, cb, opts)
    plan(rec, "move_to")
    return true
end

function client:move_direct(target, cb)
    local t = Q.xyz(target)
    local pos = player_pos()
    if not t or not pos then
        if cb then pcall(cb, false, "bad target", { code = "bad_request", detail = "bad target" }) end
        return false
    end
    local rec = new_nav("direct", t, cb, {})
    start_walk(rec, { pos, t })
    return true
end

function client:follow_path(waypoints, cb)
    local list = {}
    for i, p in ipairs(type(waypoints) == "table" and waypoints or {}) do
        local x = Q.xyz(p)
        if not x then list = nil break end
        list[i] = x
    end
    if not list or #list == 0 then
        if cb then pcall(cb, false, "bad waypoints", { code = "bad_request", detail = "bad waypoints" }) end
        return false
    end
    local rec = new_nav("path", list[#list], cb, {})
    rec.waypoints, rec.wp_index = list, 1
    -- Close to the first waypoint: walk the route as recorded; else path to it first.
    local pos = player_pos()
    if pos and Q.dist3(pos, list[1]) <= 8 then
        local pts = { pos }
        for _, p in ipairs(list) do pts[#pts + 1] = p end
        start_walk(rec, pts)
    else
        plan(rec, "follow_path")
    end
    return true
end

function client:replan(reason)
    if not nav or nav.planning then return end
    nav.repaths = nav.repaths + 1
    if nav.repaths > C.max_repaths then
        return finish(nav, false, "max_repath_exceeded", "more than " .. C.max_repaths .. " repaths")
    end
    emit("repath", reason or "replan")
    if nav.kind == "direct" then
        local pos = player_pos()
        if pos then start_walk(nav, { pos, nav.target }) end
        return
    end
    plan(nav, reason or "replan")
end

function client:stop()
    cancel_current(false)
    halt()
    set_state("idle")
end

function client:pause(reason)
    pauses[reason or "consumer"] = true
end

function client:resume(reason)
    pauses[reason or "consumer"] = nil
end

-- ----------------------------------------------------------------- status --
function client:get_state() return state end
function client:get_full_state() return full end
function client:is_moving() return state == "navigating" end
function client:is_busy() return nav ~= nil end
function client:get_destination() return nav and nav.target or nil end
function client:get_current_path() return nav and nav.path or nil end
function client:get_last_path() return last_path end
function client:get_path_index() return (nav and nav.walking and nav.index) or 0 end
function client:get_last_failure() return last_failure end
function client:is_server_available() return T.server_up == true end
function client:get_config() return C end

function client:get_progress()
    if not nav or not nav.path then
        return { percent = 0, waypoints_remaining = 0, total_waypoints = 0, current_index = 0 }
    end
    local n = #nav.path
    return { percent = n > 0 and (nav.index - 1) / math.max(1, n - 1) or 0,
             waypoints_remaining = math.max(0, n - nav.index + 1), total_waypoints = n, current_index = nav.index }
end

function client:health_check(cb) T.health(cb) end

---Same Lua type only, as AmeisenNav; unknown keys are ignored.
function client:update_config(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        if C[k] ~= nil and type(C[k]) == type(v) then
            C[k] = v
            if k == "url" then Q.clear_cache() end
        end
    end
    look_at_set = nil
end

-- ---------------------------------------------------------------- queries --
function client:find_path(from, to, cb, opts)
    Q.find_path(from, to, opts, cb)
end

function client:validate_destination(target, cb)
    local pos = player_pos()
    if not pos then pcall(cb, false, "bad_request", nil) return end
    Q.find_path(pos, target, {}, function(ok, points, info)
        if ok then pcall(cb, true, nil, info.length or Q.path_length(points))
        else pcall(cb, false, info.code, nil) end
    end)
end

function client:get_height(pos, cb) Q.get_height(pos, cb) end
function client:get_player_height(cb) Q.get_height(player_pos(), cb) end
function client:raycast(from, to, cb) Q.raycast(from, to, cb) end
function client:random_point(center, radius, cb) Q.random_point(center, radius, cb) end

local function away_point(from, away_from, dist)
    local dx, dy = from.x - away_from.x, from.y - away_from.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.1 then dx, dy, len = 1, 0, 1 end
    return { x = from.x + dx / len * dist, y = from.y + dy / len * dist, z = from.z }
end

---A reachable point about escape_distance away from the target.
local function escape(pos, threat, cb)
    local p, t = Q.xyz(pos), Q.xyz(threat)
    if not p or not t then pcall(cb, nil) return end
    local tries = { 0, 0.6, -0.6, 1.2, -1.2 }
    local i = 0
    local function try()
        i = i + 1
        if i > #tries then pcall(cb, nil) return end
        local base = away_point(p, t, C.escape_distance)
        local a = tries[i]
        local dx, dy = base.x - p.x, base.y - p.y
        local cand = { x = p.x + dx * math.cos(a) - dy * math.sin(a), y = p.y + dx * math.sin(a) + dy * math.cos(a),
                       z = p.z }
        Q.find_path(p, cand, { allow_partial = true }, function(ok, points)
            if ok and points and #points > 0 then
                local e = points[#points]
                if Q.dist3(e, p) >= C.escape_distance * 0.5 then
                    pcall(cb, vec3.new(e.x, e.y, e.z))
                    return
                end
            end
            try()
        end)
    end
    try()
end

function client:kite(player_p, target_p, cb) escape(player_p, target_p, cb) end

function client:flee(player_p, threats, cb)
    local sx, sy, sz, n = 0, 0, 0, 0
    for _, t in ipairs(threats or {}) do
        local x = Q.xyz(t)
        if x then sx, sy, sz, n = sx + x.x, sy + x.y, sz + x.z, n + 1 end
    end
    if n == 0 then pcall(cb, nil) return end
    escape(player_p, { x = sx / n, y = sy / n, z = sz / n }, cb)
end

---Nearest neighbour from the player, then 2-opt. Straight-line distances.
function client:plan_route(nodes, cb)
    local pts = {}
    for i, p in ipairs(nodes or {}) do pts[i] = Q.xyz(p) end
    local n = #pts
    if n == 0 then pcall(cb, false, nil) return end
    local start = player_pos() or pts[1]
    local used, order, cur = {}, {}, start
    for _ = 1, n do
        local best, bd = nil, nil
        for i = 1, n do
            if not used[i] then
                local d = Q.dist3(cur, pts[i])
                if not bd or d < bd then best, bd = i, d end
            end
        end
        used[best] = true
        order[#order + 1] = best
        cur = pts[best]
    end
    local function d(a, b) return Q.dist3(a, b) end
    local improved, guard = true, 0
    while improved and guard < 50 do
        improved, guard = false, guard + 1
        for i = 1, n - 2 do
            for k = i + 1, n - 1 do
                local a = i == 1 and start or pts[order[i - 1]]
                local b, c2, e = pts[order[i]], pts[order[k]], pts[order[k + 1]]
                if d(a, c2) + d(b, e) < d(a, b) + d(c2, e) - 0.01 then
                    local lo, hi = i, k
                    while lo < hi do order[lo], order[hi] = order[hi], order[lo]; lo, hi = lo + 1, hi - 1 end
                    improved = true
                end
            end
        end
    end
    local wps, total, prev = {}, 0, start
    for i, idx in ipairs(order) do
        local p = pts[idx]
        wps[i] = vec3.new(p.x, p.y, p.z)
        total = total + Q.dist3(prev, p)
        prev = p
    end
    pcall(cb, true, { waypoints = wps, visit_order = order, total_distance = total })
end

-- ----------------------------------------------------------------- update --
local function seg_dist(p, a, b)
    local abx, aby = b.x - a.x, b.y - a.y
    local l2 = abx * abx + aby * aby
    local t = l2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / l2)) or 0
    local qx, qy = a.x + abx * t, a.y + aby * t
    return math.sqrt((p.x - qx) ^ 2 + (p.y - qy) ^ 2)
end

local function recover(rec, pos)
    rec.stuck = rec.stuck + 1
    J.event("%s #%d stuck level %d", rec.kind, rec.seq, rec.stuck)
    emit("stuck", rec.stuck)
    if rec.stuck > C.max_stuck then
        halt()
        return finish(rec, false, "max_stuck_exceeded", "stuck recovery gave up")
    end
    local level = rec.stuck
    if level == 1 then
        rec.recovering = "jump"
        set_state("navigating", "recovering.jump")
        J.call("core.input.jump", false, core.input.jump)
    elseif level == 2 or level == 5 then
        rec.recovering = level == 2 and "repath" or "jump_repath"
        if level == 5 then J.call("core.input.jump", false, core.input.jump) end
        client.replan(client, "stuck")
    elseif level == 3 then
        rec.recovering = "detour"
        set_state("navigating", "recovering.detour")
        Q.random_point(pos, 5, function(ok, p)
            if nav ~= rec or rec.done then return end
            if ok and p then
                rec.detour = true
                walk({ pos, { x = p.x, y = p.y, z = p.z } })
                rec.detour_until = now() + 2.5
            else
                client.replan(client, "stuck")
            end
        end)
    elseif level == 4 then
        rec.recovering = "backoff"
        set_state("navigating", "recovering.backoff")
        halt()
        J.call("core.input.move_backward_start", false, core.input.move_backward_start)
        rec.backoff_until = now() + C.backoff_time
    end
end

---Every update (main.lua). Consumers never call this.
function client:update()
    T.tick()
    local rec = nav
    if not rec or rec.done or not rec.walking then return end
    if not rec.path then
        -- seamless re-target: keep driving the old walk until the new path arrives
        J.call("simple_movement:process", true, function() movement:process() end)
        return
    end
    local t = now()
    local pos = player_pos()
    if not pos then return end

    -- back off / detour phases
    if rec.backoff_until then
        if t < rec.backoff_until then return end
        rec.backoff_until = nil
        J.call("core.input.move_backward_stop", false, core.input.move_backward_stop)
        client.replan(client, "backoff")
        return
    end
    if rec.detour and t >= (rec.detour_until or 0) then
        rec.detour = nil
        client.replan(client, "detour")
        return
    end

    -- pause (consumer reasons, casting)
    local hold = next(pauses) ~= nil or (C.pause_while_casting and casting())
    if hold then
        if not moving_paused then
            J.call("simple_movement:pause", false, function() movement:pause() end)
            moving_paused = true
        end
        rec.sample_t, rec.sample_pos = t, pos      -- never counts as stuck
        return
    elseif moving_paused then
        J.call("simple_movement:resume", false, function() movement:resume() end)
        moving_paused = false
    end

    local ok, reached = J.call("simple_movement:process", true, function() return movement:process() end)
    local path = rec.path
    local last = path[#path]
    if rec.detour then return end

    -- arrived
    if Q.dist3(pos, last) <= C.final_threshold or (ok and reached == true and Q.dist3(pos, last) <= 4) then
        halt()
        return finish(rec, true, "arrived")
    end

    -- waypoint index (and the route's waypoint for follow_path rejoin)
    while rec.index < #path and Q.dist3(pos, path[rec.index]) <= C.waypoint_threshold do
        rec.index = rec.index + 1
    end
    if rec.kind == "path" and rec.waypoints then
        local wi = rec.wp_index or 1
        while wi < #rec.waypoints and Q.dist3(pos, rec.waypoints[wi]) <= C.waypoint_threshold do wi = wi + 1 end
        rec.wp_index = wi
    end

    -- off the path
    if rec.index >= 2 and not rec.planning and
        seg_dist(pos, path[rec.index - 1], path[rec.index]) > C.deviation_limit then
        client.replan(client, "deviation")
        return
    end

    -- stuck
    if rec.progress_from and Q.dist3(pos, rec.progress_from) >= C.stuck_clear_move then
        rec.progress_from = pos
        if rec.stuck > 0 then
            rec.stuck, rec.recovering = 0, nil
            set_state("navigating")
        end
    end
    if t - rec.sample_t >= C.stuck_window then
        local moved = rec.sample_pos and Q.dist3(pos, rec.sample_pos) or 99
        rec.sample_t, rec.sample_pos = t, pos
        if moved < C.stuck_min_move and not rec.planning then recover(rec, pos) end
    end
end

return setmetatable({}, client)
