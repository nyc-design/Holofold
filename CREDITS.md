# Credits

Holofold is GPL-2.0-or-later. It is built from the following projects; each keeps its own license.

## Emulator and front end

| Project | Role | License |
|---|---|---|
| [Azahar](https://github.com/azahar-emu/azahar) (successor to Citra) | The 3DS emulator core | GPL-2.0-or-later |
| [Bifold](https://github.com/Bifold-Emu/Bifold) | iOS front end Holofold forked from: AzaharCore C API, JIT work, interpreter speed-ups, controller layer | GPL-2.0-or-later |
| [CitraVR](https://github.com/amwatson/CitraVR) by Amanda M. Watson | Design inspiration for the stereo panels and curved screen (no code used) | GPL-2.0-or-later |

## Libraries

| Library | License |
|---|---|
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Apache-2.0 |
| dynarmic, oaknut | 0BSD / MIT |
| openal-soft | LGPL-2.0-or-later |
| Other libraries in Azahar's `externals/` (Boost, fmt, SDL, cubeb, glslang, VMA, zstd, …) | See each library's license in `external/azahar/externals/` after bootstrap |

## Bundled homebrew

Licenses are in `App/Bundled/licenses/`.

| Title | Author | License |
|---|---|---|
| 2048 | Carlos "0rientd" Henrique | MIT |
| Anarch | Miloslav Číž, blitzdoughnuts | CC0 |
| Craftus Reloaded | Kemal Afzal "RSDuck" (textures by XSSheep) | MIT (textures CC BY-SA) |
| HexIsoPath | LiquidFenrir | MIT |
| Yahtzee3DS | LiquidFenrir | GPL-3.0 |
| StarCruiser7 | dotMizi | MIT |

## Contributors

See the [contributors page](https://github.com/zlinoliver/Holofold/graphs/contributors), and the upstream Bifold and Azahar contributors whose history this repository keeps.
