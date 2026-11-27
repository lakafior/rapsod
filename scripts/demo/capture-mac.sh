#!/bin/bash
# Zrzuty okien Rapsodu na Macu do README (.github/assets/screenshots/mac-*.png).
#
# Użycie: scripts/demo/capture-mac.sh <Rapsod.app (Debug)> <folder z biblioteką demo> <folder roboczy>
#
# Uruchamia kopię testową (własny folder danych w <folder roboczy>/data, port 13400) z trybem
# `-ABSDemoTour` (Rapsod/Rapsod/App/DemoTour.swift), który ustawia scenę i ogłasza
# `DEMO shot <nazwa> <numer okna>`; skrypt robi wtedy `screencapture -l` bez cienia.
# Surowe PNG (2×) trafiają do <folder roboczy>/raw, adres parowania dla symulatora do
# <folder roboczy>/pair.txt. Aplikacja zostaje uruchomiona (serwer dla scripts/demo/capture-iphone.sh);
# jej PID jest w <folder roboczy>/app.pid. Kopia testowa ma ten sam identyfikator pakietu co
# prawdziwa aplikacja: przed uruchomieniem zapisz `defaults export net.smigi.rapsod`, po
# zakończeniu przywróć zmienione klucze (tryb sam przywraca stan okien).
set -euo pipefail
app="$1"; demo="$2"; work="$3"
mkdir -p "$work/raw" "$work/data"
log="$work/app.log"
: > "$log"
"$app/Contents/MacOS/Rapsod" -ABSDataRoot "$work/data" -ABSPort 13400 \
    -ABSDemoTour "$demo" -ABSDemoTourPairing "$work/pair.txt" >> "$log" 2>&1 &
echo $! > "$work/app.pid"
tail -n +1 -f "$log" | while read -r line; do
    case "$line" in
        "DEMO shot "*)
            set -- $line
            screencapture -x -o -l "$4" "$work/raw/$3.png"
            echo "zrzut $3"
            ;;
        "DEMO OK"*)
            echo "$line"
            pkill -P $$ tail || true
            break
            ;;
        DEMO*) echo "$line" ;;
    esac
done || true  # tail zakończony przez pkill
