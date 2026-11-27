#!/bin/bash
# Przygotowuje osobny symulator iPhone'a do zrzutów w README i paruje go z kopią testową.
#
# Użycie: scripts/demo/capture-iphone.sh <RapsodiOS.app (Debug-iphonesimulator)> <folder roboczy z capture-mac.sh>
#
# Wymaga działającej kopii testowej z scripts/demo/capture-mac.sh (serwer na 13400, adres
# parowania w <folder roboczy>/pair.txt). Tworzy symulator „Rapsod Demo iPhone” (iPhone 18 Pro),
# ustawia pasek stanu 9:41, instaluje i uruchamia aplikację i otwiera adres `rapsod://pair…`.
# Dalej stuknięciami w symulatorze (systemowe „Open”, potem):
#   Audiobooki › seria „Kroniki Mglistego Brzegu” › „Sól i popiół” › „Kontynuuj” (nagrania są ciche)
#   → iphone-book-*; mini odtwarzacz → iphone-player-*; karta Start na górze → iphone-home-*;
#   karta Audiobooki przewinięta do „Ostatnio dodane”/„Ostatnie serie” → iphone-audiobooks-*.
# Wygląd: `xcrun simctl ui <udid> appearance light|dark`; zrzut: `xcrun simctl io <udid> screenshot <plik>`.
# Potem scripts/demo/finish.sh <folder z PNG> i `xcrun simctl delete <udid>`.
set -euo pipefail
app="$1"; work="$2"
udid=$(xcrun simctl create "Rapsod Demo iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-2)
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" net.smigi.rapsod.ios >/dev/null
sleep 3
xcrun simctl openurl "$udid" "$(cat "$work/pair.txt")"
echo "$udid"
