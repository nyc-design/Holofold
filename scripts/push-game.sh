#!/usr/bin/env bash
# Copies a game you dumped yourself onto Apple Vision Pro, into Holofold's Documents folder.
# Holofold installs .cia files from there by itself the next time it starts.
#
#   scripts/push-game.sh <file.cia|.3ds|.cci|.cxi|.3dsx> [device UDID] [bundle ID]
#
# Only ever adds a file: it never uses --remove-existing-content (which would wipe the app's
# whole data container, games and saves included).
set -euo pipefail
file="${1:?usage: push-game.sh <game file> [device UDID] [bundle ID]}"
device="${2:-}"
bundle="${3:-$(sed -n 's/^HOLOFOLD_BUNDLE_ID *= *//p' "$(dirname "$0")/../App/Config/Local.xcconfig" 2>/dev/null | tail -1)}"
[ -n "$bundle" ] || { echo "error: give the bundle ID, or set HOLOFOLD_BUNDLE_ID in App/Config/Local.xcconfig" >&2; exit 2; }
if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null | awk '/Vision Pro/ && /connected/ && /physical/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
  [ -n "$device" ] || { echo "error: no connected Vision Pro found; pass its UDID" >&2; exit 2; }
fi
python3 -I "$(dirname "$0")/tools/ciacheck.py" "$file" 2>/dev/null || case "$file" in *.cia|*.CIA) echo "warning: see above — Azahar only installs decrypted dumps" >&2 ;; esac
xcrun devicectl device copy to --device "$device" --domain-type appDataContainer \
  --domain-identifier "$bundle" --source "$file" --destination "Documents/$(basename "$file")"
echo "Copied. Open Holofold on the headset to install and play it."
