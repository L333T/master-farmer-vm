-- ============================================================================
-- Marty Nav - transport.lua
-- HTTP to the nav server: queue, time-outs, server up / down.
-- ============================================================================
-- core.http_post is asynchronous and cannot be cancelled, so every request
-- gets a sequence number and a deadline; tick() fails requests past their
-- deadline with "timeout", and a late answer for a finished request is
-- ignored. At most C.max_inflight requests are on the wire; the rest queue.
-- C.down_after_failures transport failures in a row mark the server down;
-- while down a health request is tried every C.health_retry s.
--
-- cb(ok, http_code, body): ok = the server answered (any HTTP code).
-- ============================================================================

local C = require("marty/config")
local J = require("marty/journal")

local T = {}

T.server_up = nil          -- nil unknown, then true / false
T.last_latency, T.avg_latency = 0, 0
T.sent, T.failed = 0, 0

local seq = 0
local inflight, inflight_n = {}, 0
local queue = {}
local fail_streak = 0
local listeners = {}
local next_health = 0
local health_pending = false

local function now()
    local ok, t = pcall(core.time)
    return (ok and type(t) == "number") and t or 0
end

function T.on_server_change(fn) listeners[#listeners + 1] = fn end

function T.set_up(up, why)
    if T.server_up == up then return end
    T.server_up = up
    core.log("[Marty Nav] server " .. (up and "connected" or ("unavailable (" .. tostring(why) .. ")"))
        .. " - " .. C.url)
    for i = 1, #listeners do pcall(listeners[i], up) end
end

local function finish(req, ok, code, body)
    if req.done then return end
    req.done = true
    if inflight[req.seq] then
        inflight[req.seq] = nil
        inflight_n = inflight_n - 1
    end
    pcall(req.cb, ok, code, body or "")
end

local function transport_failure(why)
    T.failed = T.failed + 1
    fail_streak = fail_streak + 1
    if fail_streak >= C.down_after_failures then
        T.set_up(false, why)
        next_health = now() + C.health_retry
    end
end

local function send(req)
    seq = seq + 1
    req.seq = seq
    req.sent_at = now()
    req.deadline = req.sent_at + (req.timeout or C.request_timeout)
    inflight[seq] = req
    inflight_n = inflight_n + 1
    T.sent = T.sent + 1
    local function answer(code, _ctype, body)
        J.event("http #%d answer %s (%d bytes)", req.seq, tostring(code), type(body) == "string" and #body or -1)
        local ok = pcall(function()
            if req.done then return end
            local dt = now() - req.sent_at
            T.last_latency = dt
            T.avg_latency = T.avg_latency == 0 and dt or (T.avg_latency * 0.9 + dt * 0.1)
            if type(code) ~= "number" or code == 0 or type(body) ~= "string" then
                transport_failure("no answer")
                finish(req, false, 0, "")
                return
            end
            fail_streak = 0
            T.set_up(true)
            finish(req, true, code, body)
        end)
        if not ok then finish(req, false, 0, "") end
    end
    local headers = { ["Content-Type"] = "application/json" }
    if C.token ~= "" then headers["X-Nav-Token"] = C.token end
    local ok = J.call("core.http_post #" .. seq, false, core.http_post, C.url, headers, req.body, answer)
    if not ok then finish(req, false, 0, "") end
end

local function pump()
    while inflight_n < C.max_inflight and #queue > 0 do
        send(table.remove(queue, 1))
    end
end

---Queue a POST of `body`. opts: { timeout, force (send even while down) }.
function T.post(body, cb, opts)
    opts = opts or {}
    if T.server_up == false and not opts.force then
        pcall(cb, false, "server_down", "")
        return
    end
    if #queue >= C.max_queued then
        pcall(cb, false, "busy", "")
        return
    end
    queue[#queue + 1] = { body = body, cb = cb, timeout = opts.timeout }
    pump()
end

---Is the server answering? A tiny real request (any JSON answer counts).
function T.health(cb)
    if health_pending then return end
    health_pending = true
    local body = '{"map": 0, "start": {"x": 0.00, "y": 0.00, "z": 0.00}, "destination": {"x": 1.00, "y": 1.00, "z": 0.00}}'
    T.post(body, function(ok, code, resp)
        health_pending = false
        local up = ok and type(code) == "number" and code > 0 and code < 500 and resp:find("^%s*{") ~= nil
        if up then
            fail_streak = 0
            T.set_up(true)
        else
            T.set_up(false, ok and ("HTTP " .. tostring(code)) or tostring(code))
        end
        if cb then pcall(cb, up, up and ("ok HTTP " .. tostring(code)) or ("err " .. tostring(code))) end
    end, { force = true })
end

---Every update: time-outs, queue, health retries.
function T.tick()
    local t = now()
    for _, req in pairs(inflight) do
        if not req.done and t > req.deadline then
            transport_failure("timeout")
            finish(req, false, "timeout", "")
        end
    end
    pump()
    if T.server_up == nil and t >= next_health then
        next_health = t + C.health_retry
        T.health()
    elseif T.server_up == false and t >= next_health then
        next_health = t + C.health_retry
        T.health()
    elseif T.server_up == true and t >= next_health then
        next_health = t + C.health_interval
        T.health()
    end
end

function T.inflight() return inflight_n end
function T.queued() return #queue end

return T
