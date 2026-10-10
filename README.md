# Master Farmer vM 1.0.0 — Master Farmer on Marty Nav (test build)

A separate test project: the Master Farmer bot (questing, grinding, gathering,
rotations - taken from Grindbot 2.272.1) whose navigation is **Marty Nav only**.

- **No AmeisenNav** - no `ameisen/` folder, no `_G.AmeisenNav` lookup, no local
  nav server (127.0.0.1:47110 / 47111).
- **No Sentinel** - no SentinelNavClient. (`movement/sentinel.lua` keeps its old
  file name; it is the bot's navigation layer and now talks to Marty Nav.)
- **Only the Sylvanas API** - Marty Nav asks its path server with
  `core.http_post` and walks the answer with Sylvanas' `simple_movement`.

It does not mix with the main bot or with another navigation plugin:

| | Master Farmer vM | Grindbot |
|---|---|---|
| Plugin name | Master Farmer vM | Master Farmer - Grindbot |
| Folder / identity | `Master_Farmer_vM` | `Master_Farmer_Grindbot` |
| Menu element ids | `mfvm_*` | `mfg_*` |
| Settings / data | `scripts_data/mfvm` | `scripts_data/mfg` |
| Session logs | `scripts_log/MASTER_FARMER_VM_ERRORS` | `scripts_log/MASTER_FARMER_ERRORS` |
| Hot-reload namespace | `_G.MasterFarmer_vM` | `_G.MasterFarmer_Grindbot` |
| Navigation | embedded Marty Nav (`marty/`) | AmeisenNav |

## Navigation: `marty/`

```
marty/nav.lua        the embed: game version, map id, api() = { client, query },
                     update() once per frame (main.lua), stop() (unload)
marty/client.lua     the navigator (AmeisenNav-compatible client API)
marty/query.lua      path requests, cache, derived queries
marty/transport.lua  HTTP queue, time-outs, server up / down
marty/config.lua     tunables (server url, thresholds, stuck recovery)
marty/journal.lua    crash journal: scripts_log/marty_nav/session_*.log
marty/json.lua       JSON decoder
```

These are the Marty Nav 2.0.0 modules (`Desktop\Marty_Nav`) with their requires
renamed to `marty/...`. Marty's own `main.lua` (menu, test tools, path drawing,
publishing in `_G`) is not used: nothing is published in `_G`, so a Marty_Nav or
AmeisenNav plugin loaded beside this one is never touched.

Path server: `marty/config.lua` `url` (`https://nav.deathwing.fyi/nav/testpath`,
the open test endpoint). The status window's **Marty Nav** row shows
`Marty Nav ready` / `path server not answering`.

## Install

**HTTP loader (downloads the bot from GitHub `main`):** copy `plugin_loader\`
into your Sylvanas `scripts` folder as its own plugin (for example
`scripts\Master_Farmer_vM_HTTP`). It shows as **Master Farmer vM (HTTP)** and
downloads `L333T/master-farmer-vm` at the commit `main` points to.

**Local copy:** `python make_local.py` builds `..\Master_Farmer_vM_v<version>\`;
copy that folder into `scripts\Master_Farmer_vM`.

Do not run both copies at once (two update callbacks would drive one
character). The Grindbot and AmeisenNav can stay installed, but do not run the
Grindbot at the same time as this bot.

## Tests

```
luajit tests/test_marty_embed.lua
```

Marty Nav loads without publishing anything in `_G`, has every call the bot
uses, `move_to` posts JSON to the path server and walks the answer, and no Lua
file uses AmeisenNav, Sentinel or the local nav server.

## Releasing

Bump `version.lua` (and the `-- Version:` banners), add a `VERSIONING.md` row,
`python make_local.py` (0 failed), commit on `dev`, push, open a PR to `main`
and merge it - the HTTP loader follows `main`.
