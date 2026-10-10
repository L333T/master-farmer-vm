-- ============================================================================
-- Master Farmer vM - marty/nav.lua
-- Marty Nav, embedded: the bot's only navigation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk  (Marty Nav 2.0.0: 1stblizz)
-- Version: 1.0.1
-- Folder: Master_Farmer_vM
-- ============================================================================
-- This build of Master Farmer walks with Marty Nav and nothing else: no
-- AmeisenNav, no SentinelNavClient, no local nav server. Marty Nav asks the
-- path server (marty/config.lua url, nav.deathwing.fyi test endpoint) with
-- core.http_post and walks the answer with Sylvanas' simple_movement - only
-- the Sylvanas API.
--
-- The modules from the Marty_Nav plugin (client, config, journal, json,
-- query, transport) live under marty/ with their requires renamed, and are
-- driven from here instead of from Marty's own main.lua: no menu, no test
-- tools, no path drawing, and NOTHING is published in _G - the client is
-- this plugin's own (movement/sentinel.lua asks nav.api(), never _G), so it
-- cannot mix with an AmeisenNav or Marty_Nav plugin loaded beside it.
--
-- nav.update() steps the client once per frame (main.lua on_update).
-- ============================================================================

local C = require("marty/config")
local J = require("marty/journal")
local T = require("marty/transport")
local Q = require("marty/query")
local client = require("marty/client")

local nav = {}

nav.VERSION = "2.0.0"   -- Marty Nav

local function game_version()
    local ok, v = pcall(core.get_game_version)
    return (ok and type(v) == "string") and v or ""
end
nav.GAME_VERSION = game_version()
pcall(client.set_forever, nav.GAME_VERSION:lower():find("forever") ~= nil)

local function map_id()
    local ok, id = pcall(core.get_instance_id)
    if ok and type(id) == "number" and id >= 0 then return id end
    local ok2, id2 = pcall(core.get_map_id)
    if ok2 and type(id2) == "number" then return id2 end
    return nil
end
pcall(Q.set_map_fn, map_id)

local API = { VERSION = nav.VERSION, GAME_VERSION = nav.GAME_VERSION, client = client, query = Q, marty = true }

--- { client, query } - the shape movement/sentinel.lua reads (client methods
--- follow the AmeisenNav client API, see Marty_Nav README).
function nav.api()
    return API
end

nav.client = client
nav.query = Q
nav.config = C

local last_t = nil

--- Step the client: once per frame, whoever calls first.
function nav.update()
    local ok, t = pcall(core.time)
    if ok and t == last_t then return end
    last_t = ok and t or nil
    local okc, err = pcall(client.update, client)
    if not okc then
        pcall(J.info, "update error: %s", tostring(err))
    end
end

--- Is the path server answering?
function nav.server_up()
    local ok, up = pcall(client.is_server_available, client)
    return ok and up == true
end

--- Stop any walk (unload / bot stop).
function nav.stop()
    pcall(client.stop, client)
end

pcall(J.info, "Marty Nav %s embedded in Master Farmer vM - game %s - server %s",
    nav.VERSION, nav.GAME_VERSION, tostring(C.url))

return nav
