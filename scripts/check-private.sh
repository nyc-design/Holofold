#!/usr/bin/env bash
# Refuses to commit (or, with --all, to publish) anything that must stay private: game files,
# keys and console data, very large files, private app-shell sources, and personal identifiers.
#
#   scripts/check-private.sh            check the staged files (git pre-commit hook)
#   scripts/check-private.sh --all      check every tracked file (CI, release audit)
#
# Install as a hook:  ln -sf ../../scripts/check-private.sh .git/hooks/pre-commit
#
# Personal strings to block (your Team ID, device UDIDs, user name …) are read, one per line,
# from ../private/signing/forbidden-strings.txt when that file exists. It is never committed,
# so this script itself contains nothing personal.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "${1:-}" = "--all" ]; then
  files=$(git ls-files)
else
  files=$(git diff --cached --name-only --diff-filter=ACMR)
fi
[ -n "$files" ] || exit 0

fail=0
complain() { echo "check-private: $1" >&2; fail=1; }

# Bundled open-source homebrew and test programs are allowed.
allowed() {
  case "$1" in
    App/Bundled/*|Core/tests/elf/*) return 0 ;;
  esac
  return 1
}

while IFS= read -r f; do
  [ -f "$f" ] || continue
  lower=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
  base=$(basename "$lower")
  case "$lower" in
    *.cia|*.zcia|*.3ds|*.z3ds|*.cci|*.zcci|*.cxi|*.zcxi|*.app.bin|*.sav|*.cst)
      allowed "$f" || complain "$f: game or save data must never be committed" ;;
  esac
  case "$base" in
    aes_keys*|seeddb*|boot9*|boot11*|movable.sed|otp.bin|secret_sectors.bin|*.xcconfig)
      if [ "$base" != "holofold.xcconfig" ] && [ "$base" != "local.xcconfig.example" ]; then
        complain "$f: keys, console data or personal build settings must never be committed"
      fi ;;
  esac
  # Private app shell (launcher UI) — lives in ../private/app-shell only.
  case "$base" in
    visionlauncherview.swift|visionsettingspages.swift|visionfilespage.swift|fullapp.swift|fullshell.swift)
      complain "$f: private app-shell source" ;;
  esac
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt 20000000 ] && ! allowed "$f"; then
    complain "$f: larger than 20 MB"
  fi
  # 3DS binaries by content: NCCH magic at 0x100, SMDH magic at 0.
  if ! allowed "$f" && [ "$size" -gt 512 ]; then
    if [ "$(dd if="$f" bs=1 skip=256 count=4 2>/dev/null)" = "NCCH" ] ||
       [ "$(dd if="$f" bs=1 count=4 2>/dev/null)" = "SMDH" ]; then
      complain "$f: looks like 3DS game data"
    fi
  fi
done <<< "$files"

# Personal identifiers (from the private, uncommitted list).
list="../private/signing/forbidden-strings.txt"
if [ -f "$list" ]; then
  while IFS= read -r needle; do
    [ -n "$needle" ] && [ "${needle#\#}" = "$needle" ] || continue
    hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -f "$f" ] && grep -Iq -F -- "$needle" "$f" && echo "$f"; done || true)
    [ -z "$hits" ] || complain "personal string found in: $(echo $hits)"
  done < "$list"
fi

if [ "$fail" -ne 0 ]; then
  echo "check-private: refusing. Keep games, keys and personal data in ../private/." >&2
  exit 1
fi
