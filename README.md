# WILD NativeMapGate Data

This repository is consumed by WILD_Launcher only. The launcher installs files from `payload/SCUM` into the player's SCUM client and uses `latest.json` plus the manifest to verify hashes and clean launcher-managed legacy files.

Client install target examples:

- `SCUM/Binaries/Win64/UE4SS.dll`
- `SCUM/Binaries/Win64/UE4SS-settings.ini`
- `SCUM/Binaries/Win64/version.dll`
- `SCUM/Binaries/Win64/Mods/mods.txt`
- `SCUM/Binaries/Win64/Mods/NativeMapGate/Scripts/main.lua`
- `SCUM/Binaries/Win64/Mods/shared/UEHelpers/UEHelpers.lua`
- `SCUM/Content/Paks/~mods/SCUM_MagniMap_P.pak`

Do not put server plugins, docs, old handoff zips, or launcher metadata into the game folder. They stay out of `payload/SCUM`.