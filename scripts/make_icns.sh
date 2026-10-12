#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from a 1024px icon PNG (default: assets/icon.png).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="${1:-assets/icon.png}"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET" Resources

for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "✅ Resources/AppIcon.icns"
