#!/bin/zsh
# Builds and opens the palette lab: Rise's new tab palette held open beside a panel of every value
# it's drawn with (Sources/Rise/PaletteLab.swift). It runs beside the everyday Rise with its own
# profile, which starts from a copy of the everyday history, so the suggestions are real ones.
set -euo pipefail
builtin cd "${0:A:h:h}"
RISE_PALETTE_LAB=1 ./scripts/build.sh
APP="$PWD/build/Rise Palette Lab.app"
osascript -e 'tell application id "dev.bartosz.Rise.PaletteLab" to quit' >/dev/null 2>&1 || true
for _ in {1..50}; do pgrep -xq RiseLab || break; sleep 0.1; done
PROFILE="$HOME/Library/Application Support/Rise Palette Lab"; EVERYDAY="$HOME/Library/Application Support/Rise"
mkdir -p "$PROFILE"
for file in history.json suggestion-icons.json; do
  [[ -f "$EVERYDAY/$file" ]] && cp "$EVERYDAY/$file" "$PROFILE/$file"
done
open "$APP"
echo "Opened $APP"
