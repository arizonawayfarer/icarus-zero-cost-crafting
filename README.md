# Zero Craft Costs

This repo builds an Icarus Mod Manager mod that sets ingredient costs to `0` for recipes in the live `Crafting/D_ProcessorRecipes.json` table on your machine.

The generated mod:

- sets every `Inputs[*].Count` to `0`
- sets every `QueryInputs[*].Count` to `0`
- sets every `ResourceInputs[*].RequiredUnits` to `0`

It does not remove powered-bench requirements. Recipes that need electricity still need a powered station.

## Build

Run:

```powershell
pwsh -File .\scripts\build-zero-craft-mod.ps1
```

If your game is not installed in the default Steam location, pass the Icarus root folder:

```powershell
pwsh -File .\scripts\build-zero-craft-mod.ps1 -GameRoot 'D:\SteamLibrary\steamapps\common\Icarus\Icarus'
```

To override the packaged mod version:

```powershell
pwsh -File .\scripts\build-zero-craft-mod.ps1 -Version '1.0.3'
```

## Output

The build script writes a mod zip to:

```text
dist\zero-craft-costs-<version>.zip
```

Install that zip with Icarus Mod Manager.

## Notes

- The script extracts the current recipe tables directly from your local `data.pak`, so rerunning it after a game update will regenerate the patch against the latest installed data.
- The mod format and patch structure are based on the Icarus Mod Manager docs: https://github.com/CrystalFerrai/IcarusModManager/blob/main/docs/creating_mods.md
