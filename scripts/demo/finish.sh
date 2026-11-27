#!/bin/bash
# Skaluje i odchudza surowe zrzuty do .github/assets/screenshots/.
#
# Użycie: scripts/demo/finish.sh <folder z surowymi PNG>
# mac-home|grid|book-* → 1600 px szerokości, mac-settings-* → 1400 px, mac-menubar-* → bez zmian (2×),
# iphone-* → 600 px. Potem paleta 256 kolorów (ffmpeg palettegen/paletteuse), gdy wychodzi mniejsza.
set -euo pipefail
raw="$1"
out="$(cd "$(dirname "$0")/../.." && pwd)/.github/assets/screenshots"
mkdir -p "$out"
for file in "$raw"/*.png; do
    name=$(basename "$file")
    case "$name" in
        mac-home-*|mac-grid-*|mac-book-*) width=1600 ;;
        mac-settings-*) width=1400 ;;
        iphone-*) width=600 ;;
        *) width=0 ;;
    esac
    tmp="$out/.tmp-$name"
    if [ "$width" -gt 0 ]; then
        ffmpeg -loglevel error -y -i "$file" -vf "scale=$width:-1:flags=lanczos" "$tmp"
    else
        cp "$file" "$tmp"
    fi
    ffmpeg -loglevel error -y -i "$tmp" -filter_complex "[0]split[a][b];[a]palettegen=max_colors=256:reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128" "$tmp.pal.png"
    if [ "$(stat -f %z "$tmp.pal.png")" -lt "$(stat -f %z "$tmp")" ]; then mv "$tmp.pal.png" "$out/$name"; rm "$tmp"; else mv "$tmp" "$out/$name"; rm "$tmp.pal.png"; fi
    echo "$name $(sips -g pixelWidth "$out/$name" | awk '/pixelWidth/ {print $2}') px, $(( $(stat -f %z "$out/$name") / 1024 )) KB"
done
