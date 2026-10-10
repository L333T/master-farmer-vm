# Master Farmer vM - project notes

This is the **Master Farmer vM** test project (Master Farmer on Marty Nav).
Work from `C:\Users\ebene\OneDrive\Desktop\_Master_Farmer_vM1.0.0`.
Repo: `L333T/master-farmer-vm` (dev -> PR -> main; the HTTP loader follows main).

Rules for this project:
- Navigation is the embedded Marty Nav (`marty/`) only. Never add AmeisenNav,
  Sentinel, `_G.AmeisenNav`, or the local nav server (127.0.0.1:47110/47111).
- Only the Sylvanas API. Nothing from this project is published in `_G` except
  the bot's own `_G.MasterFarmer_vM` namespace.
- Keep the vM identity (`mfvm_` menu ids, `scripts_data/mfvm`,
  `MASTER_FARMER_VM_ERRORS`) so it never shares state with the Grindbot.
- The Grindbot (`Desktop\SNES_\Master_Farmer_Grindbot`) is a separate project;
  do not change it from here.
See README.md and AGENTS.md.
