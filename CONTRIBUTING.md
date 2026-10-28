# Contributing to Holofold

Thanks for helping! Holofold is a small project and every fix, test report and idea counts.

## Ground rules

- **No copyrighted game data, ever.** Do not attach, link to, or ask for games, ROMs, BIOS / firmware, encryption keys (`aes_keys.txt`, `seeddb.bin`, `boot9.bin`, …), or tools and sites that obtain them. This applies to code, issues, pull requests, discussions and screenshots. Such content is removed and the thread closed.
- **Be kind.** Assume good intent and keep discussions technical.
- **Licensing.** Holofold is GPL-2.0-or-later. By contributing you agree your work is released under that license.

## Developer Certificate of Origin

Every commit must be signed off (`git commit -s`), which adds:

```
Signed-off-by: Your Name <you@example.com>
```

This certifies the [Developer Certificate of Origin](https://developercertificate.org/): you wrote the change, or have the right to submit it under the project's license.

## Workflow

1. Fork the repository and create a branch from `main`: `feature/<topic>` or `fix/<topic>`.
2. Keep each pull request focused on one change. Describe what you changed, why, and how you tested it.
3. Install the private-file check as a pre-commit hook:
   ```bash
   ln -sf ../../scripts/check-private.sh .git/hooks/pre-commit
   ```
   The same check (`scripts/check-private.sh --all`) runs on every pull request.
4. Don't commit your `App/Config/Local.xcconfig` (it's ignored), your Team ID, device UDIDs, or paths from your Mac.

## Where the code lives

| Path | What |
|---|---|
| `App/Sources/Vision/` | visionOS engine: game and touch windows, stereo presentation, auto-save, diagnostics |
| `App/Sources/VisionMinimal/` | The public entry point: boots straight into a game |
| `App/Sources/Emulation/`, `App/Sources/Core/` | Shared front-end code (input, settings, emulator bridge) |
| `App/Resources/StereoScreen.usda` | RealityKit material that shows each eye its own half of the frame |
| `Core/` | The AzaharCore C API that the app links against |
| `patches/` | Changes to Azahar and its dependencies, applied by `scripts/bootstrap.sh` |

## Changing the Azahar core

`external/` is fetched and patched by `scripts/bootstrap.sh` and is never committed. To change the core:

1. Edit inside `external/azahar` and rebuild with `./scripts/build-core-ios.sh --sdk xros`.
2. Regenerate the patch you changed, for example:
   ```bash
   (cd external/azahar && git diff) > patches/azahar/0003-visionos-offscreen-presentation.patch
   ```
   Or add a new numbered patch if the change is unrelated to the existing ones.
3. Check that a fresh `./scripts/bootstrap.sh` applies all patches cleanly.

## Testing

Test with the bundled open-source homebrew in `App/Bundled/` (StarCruiser7 uses the stereoscopic screen; Craftus is a good 3D workload) and, if you have them, games you dumped yourself. Mention the headset model and visionOS version. The visionOS Simulator is fine for UI changes, but stereo and performance need a real headset.

## Reporting bugs

Use the bug report template. Attach `vision-diag.log` and any `hang-*.txt` files (see the README's Troubleshooting section), with personal paths removed. Name the game by title and title ID, never attach it.
