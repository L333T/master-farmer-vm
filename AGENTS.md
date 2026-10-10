# Master Farmer vM - agent notes

| What | Where |
|---|---|
| Project (open this folder) | `C:\Users\ebene\OneDrive\Desktop\_Master_Farmer_vM1.0.0` |
| GitHub repo | `L333T/master-farmer-vm` (default branch `main`, work on `dev`) |
| Local builds | `python make_local.py` -> `..\SNES_\Master_Farmer_vM_v<version>\` |
| Marty Nav source (upstream) | `C:\Users\ebene\OneDrive\Desktop\Marty_Nav` |
| Base | Master Farmer - Grindbot 2.272.1 (`Desktop\SNES_\Master_Farmer_Grindbot`) |

## Release flow
1. Bump `version.lua` and every `-- Version:` banner (not `plugin_loader/`).
2. Add a row to `VERSIONING.md`.
3. `python make_local.py` must report `0 failed`; `luajit tests/test_marty_embed.lua` must pass.
4. Commit on `dev`, push, `gh pr create --base main --head dev`, merge.

## Navigation
- `marty/nav.lua` embeds Marty Nav 2.0.0 (client, query, transport, config,
  journal, json under `marty/`, requires renamed). `nav.update()` runs every
  frame from `main.lua`; `nav.stop()` on unload.
- `movement/sentinel.lua` (`N.client`) takes the client from `marty/nav`
  (`nav.api().client`). The file name is historical: there is no Sentinel.
- To take a newer Marty Nav: copy its modules into `marty/` with the requires
  renamed to `marty/...`; do not copy its `main.lua`.
- No AmeisenNav-only extras: `client:handoff`, the 20-yard windows and the
  strafe-jump-strafe ladder are AmeisenNav 1.6.x features; the bot falls back
  where the client does not have them (`N.handoff` checks for the method).
