#!/bin/bash
# Buduje wydanie: samodzielną, podpisaną (Developer ID, hardened runtime)
# i notaryzowaną aplikację w pliku DMG. Wszystko powstaje w `build/release`.
#
# Kroki: serwer, źródła metadanych, Node i ffmpeg (skrypty obok) → zawartość `Contents/Resources/Server`
# → podpis każdej binarki → archiwum i eksport z Xcode → wstawienie serwera
# i licencji do paczki → podpis aplikacji → notaryzacja i bilet dla aplikacji
# → DMG → podpis, notaryzacja i bilet dla DMG → weryfikacja.
#
# Użycie: scripts/release.sh [--skip-notarize]
#   --skip-notarize   wszystko poza notaryzacją (do testów lokalnych; plik
#                     dostaje dopisek „-nienotaryzowany” i nie nadaje się do publikacji)
# Zmienne:
#   ABS_NOTARY_PROFILE  nazwa profilu notarytool w pęku kluczy (domyślnie audiobookswift-notary)
#   ABS_BUILD_NUMBER    numer builda (domyślnie liczba commitów)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REL="$ROOT/build/release"
SERVER_SRC="$ROOT/build/abs-server"
TEAM_ID="5TA8RF548P"
SCHEME="AudiobookSwift"
APP_NAME="AudiobookSwift"
NOTARY_PROFILE="${ABS_NOTARY_PROFILE:-audiobookswift-notary}"
BUILD_NUMBER="${ABS_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"

NOTARIZE=1
if [[ "${1-}" == "--skip-notarize" ]]; then NOTARIZE=0; fi

step() { echo; echo "==> $*"; }
die() { echo "BŁĄD: $*" >&2; exit 1; }

# --- Warunki wstępne -------------------------------------------------------

[[ "$(uname -m)" == "arm64" ]] || die "Wydanie buduje się tylko na Apple Silicon."

IDENTITY="$(security find-identity -v -p codesigning | awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) {print $2; exit}')"
[[ -n "$IDENTITY" ]] || die "Brak tożsamości „Developer ID Application … ($TEAM_ID)” w pęku kluczy."

if (( NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
    || die "Brak profilu notarytool „$NOTARY_PROFILE”. Jednorazowo: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM_ID (zob. README)."
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "UWAGA: w repozytorium są niezacommitowane zmiany — wydanie nie odpowiada żadnemu commitowi."
fi

# --- Serwer i ffmpeg ------------------------------------------------------

step "Serwer audiobookshelf"
"$ROOT/scripts/build-server.sh"
step "Źródła metadanych (aio-abs-providers)"
"$ROOT/scripts/build-providers.sh"
step "Node do paczki (pierwszy raz ok. 30 minut, potem z pamięci podręcznej)"
"$ROOT/scripts/build-node.sh"
step "ffmpeg i ffprobe"
"$ROOT/scripts/build-ffmpeg.sh"

# --- Zawartość Contents/Resources/Server ----------------------------------

step "Składanie serwera do paczki"
rm -rf "$REL"
PAYLOAD="$REL/Server"
ABS="$PAYLOAD/abs-server"
mkdir -p "$ABS/client"

cp "$ROOT/build/node-runtime/node" "$PAYLOAD/node"
# ffmpeg i ffprobe z bibliotekami wspólnymi; binarki szukają ich w `../lib`.
mkdir -p "$PAYLOAD/ffmpeg"
ditto "$ROOT/build/ffmpeg/bin" "$PAYLOAD/ffmpeg/bin"
ditto "$ROOT/build/ffmpeg/lib" "$PAYLOAD/ffmpeg/lib"

# Tylko to, czego serwer używa w czasie działania: skompilowany kod, zbudowany
# klient web, zależności produkcyjne i rozszerzenie SQLite. Źródła, testy,
# dokumentacja i pliki Dockera upstreamu zostają w repozytorium.
cp "$SERVER_SRC/package.json" "$SERVER_SRC/LICENSE" "$SERVER_SRC/libnusqlite3.dylib" "$SERVER_SRC/libnusqlite3.dylib.ver" "$ABS/"
# Ukośnik na końcu źródła: wzorce zaczynające się od „/” liczą się od tego folderu.
rsync -a --exclude '/test' --exclude '.tsbuildinfo' "$SERVER_SRC/dist-server/" "$ABS/dist-server/"
rsync -a "$SERVER_SRC/client/dist" "$ABS/client/"
rsync -a \
  --exclude '/.bin' --exclude '/.package-lock.json' \
  --exclude '/@types' --exclude '/node-gyp' \
  --exclude '/sqlite3/deps' --exclude '/sqlite3/src' --exclude '/sqlite3/binding.gyp' \
  --exclude '*.map' --exclude '*.ts' --exclude '*.tsbuildinfo' \
  --exclude '/moment/src' --exclude '/moment/dist' --exclude '/moment/min' \
  --exclude '/moment-timezone/builds' --exclude '/lodash/fp' --exclude '/validator/es' \
  --exclude '/jose/dist/browser' --exclude '/node-unrar-js/esm' \
  "$SERVER_SRC/node_modules/" "$ABS/node_modules/"
# Wyżej, od `/moment/src`: alternatywne kopie tych samych pakietów (źródła ES,
# zminifikowane paczki dla przeglądarki, wariant lodash/fp). Serwer jest w CommonJS
# i ładuje tylko pliki z pola `main` (`moment.js`, `index.js`, `lodash.js`,
# `dist/node/cjs`, `dist/index.js`); nic nie odwołuje się do pominiętych katalogów.
for leftover in dist-server/test node_modules/.bin node_modules/node-gyp node_modules/@types node_modules/sqlite3/deps node_modules/moment/min; do
  [[ ! -e "$ABS/$leftover" ]] || die "Odchudzanie nie usunęło $leftover."
done
# Licencje bibliotek wkopiowanych do upstreamu (`server/libs`): tsc przenosi do
# dist-server tylko kod, więc pliki licencji dokładamy obok niego.
(cd "$SERVER_SRC" && find server/libs -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0) \
  | while IFS= read -r -d '' file; do
      mkdir -p "$ABS/dist-server/$(dirname "$file")"
      cp "$SERVER_SRC/$file" "$ABS/dist-server/$file"
    done

# Źródła metadanych (aio-abs-providers): kod, zależności produkcyjne i licencja.
# Testy, dokumentacja i pliki Dockera agregatora zostają w repozytorium. Z zależności
# odpadają mapy źródeł, typy TypeScript i opisy pakietów; pliki licencji zostają.
PROVIDERS_SRC="$ROOT/build/aio-abs-providers"
PROVIDERS="$PAYLOAD/aio-abs-providers"
mkdir -p "$PROVIDERS"
cp "$PROVIDERS_SRC/package.json" "$PROVIDERS_SRC/LICENSE" "$PROVIDERS/"
rsync -a "$PROVIDERS_SRC/src/" "$PROVIDERS/src/"
rsync -a \
  --exclude '/.bin' --exclude '/.package-lock.json' --exclude '/@types' \
  --exclude '*.map' --exclude '*.ts' --exclude '*.tsbuildinfo' \
  --exclude 'README*' --exclude 'CHANGELOG*' --exclude 'HISTORY*' \
  "$PROVIDERS_SRC/node_modules/" "$PROVIDERS/node_modules/"
# Agregator tworzy plik ustawień, kopiując domyślny z paczki; kopia dziedziczy
# uprawnienia, więc wzorzec musi być zapisywalny dla właściciela.
chmod -R u+w "$PROVIDERS"
# Agregator to sam JavaScript: binarka w jego zależnościach oznaczałaby moduł
# natywny, którego ten skrypt nie budował i nie sprawdzał.
if find "$PROVIDERS" -type f -exec file -b {} + | grep -q '^Mach-O'; then
  die "W aio-abs-providers pojawił się plik Mach-O (moduł natywny w zależnościach)."
fi

# Rozszerzenie SQLite jest uniwersalne; aplikacja jest tylko dla Apple Silicon.
if lipo -archs "$ABS/libnusqlite3.dylib" | grep -q x86_64; then
  lipo -thin arm64 "$ABS/libnusqlite3.dylib" -output "$ABS/libnusqlite3.dylib"
fi

# --- Podpis binarek serwera ------------------------------------------------

step "Podpis binarek serwera (Developer ID, hardened runtime)"
MACHO_COUNT=0
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q '^Mach-O'; then
    lipo -archs "$file" | grep -qx 'arm64' || die "Binarka nie jest wyłącznie arm64: $file"
    args=(--force --options runtime --timestamp --sign "$IDENTITY" --prefix "net.smigi.abswift.")
    # Tylko Node dostaje uprawnienie runtime (JIT silnika V8) — zob. packaging/node.entitlements.
    if [[ "$file" == "$PAYLOAD/node" ]]; then args+=(--entitlements "$ROOT/packaging/node.entitlements"); fi
    codesign "${args[@]}" "$file" 2> /dev/null || codesign "${args[@]}" "$file"
    codesign --verify --strict "$file"
    echo "  ${file#"$PAYLOAD"/}"
    MACHO_COUNT=$((MACHO_COUNT + 1))
  fi
done < <(find "$PAYLOAD" -type f -print0)
echo "  podpisano: $MACHO_COUNT"

step "Test podpisanego serwera (Node, sqlite3, rozszerzenie, ffmpeg)"
(cd "$ABS" && env -i PATH=/usr/bin:/bin "$PAYLOAD/node" -e "
const s = require('sqlite3')
const d = new s.Database(':memory:')
const fail = (e) => { console.error(e); process.exit(1) }
d.loadExtension('$ABS/libnusqlite3.dylib', (e) => {
  if (e) fail(e)
  d.get(\"select unaccent('Żółć') u\", (e, r) => {
    if (e || r.u !== 'Zolc') fail(e || r)
    console.log('  node', process.version, 'sqlite3 + unaccent: ok')
    d.close()
  })
})")
# Każda zależność produkcyjna musi się załadować z odchudzonego node_modules.
(cd "$ABS" && env -i PATH=/usr/bin:/bin "$PAYLOAD/node" -e "
const deps = Object.keys(require('./package.json').dependencies)
for (const d of deps) require(d)
require('moment-timezone').tz('2026-01-01 12:00', 'Europe/Warsaw').format()
console.log('  zależności produkcyjne (' + deps.length + '): ok')")
env -i "$PAYLOAD/ffmpeg/bin/ffmpeg" -version | head -1 | sed 's/^/  /'
env -i "$PAYLOAD/ffmpeg/bin/ffprobe" -version > /dev/null

step "Test źródeł metadanych na podpisanym Node"
# Start tak, jak robi to aplikacja: wolny port na pętli zwrotnej, ustawienia poza
# paczką, stdin z potoku, którego zamknięcie kończy proces.
PTEST="$REL/providers-test"
mkdir -p "$PTEST"
(cd "$PTEST" && sleep 20 | env -i PATH=/usr/bin:/bin PORT=0 HOST=127.0.0.1 CONFIG_PATH="$PTEST/config.json" \
  API_KEY=test EXIT_ON_STDIN_CLOSE=1 "$PAYLOAD/node" "$PROVIDERS/src/backbone/server.js" > "$PTEST/out.log" 2>&1) &
PROVIDERS_URL=""
for _ in $(seq 1 50); do
  PROVIDERS_URL="$(sed -n 's|^Backbone listening on \(http://127\.0\.0\.1:[0-9]*\).*|\1|p' "$PTEST/out.log" | head -1)"
  [[ -z "$PROVIDERS_URL" ]] || break
  sleep 0.2
done
[[ -n "$PROVIDERS_URL" ]] || { cat "$PTEST/out.log" >&2; die "Agregator nie wystartował na podpisanym Node."; }
curl -fsS --max-time 5 "$PROVIDERS_URL/healthz" | grep -q '"status":"ok"' || die "Agregator nie odpowiada na /healthz."
[[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROVIDERS_URL/search?query=test")" == "401" ]] \
  || die "Agregator odpowiada na /search bez klucza."
[[ -w "$PTEST/config.json" ]] || die "Plik ustawień agregatora nie jest zapisywalny."
pkill -f "$PROVIDERS/src/backbone/server.js" || true
wait || true
rm -rf "$PTEST"
echo "  aio-abs-providers: start, /healthz, klucz, zapis ustawień: ok"

# --- Aplikacja --------------------------------------------------------------

step "Archiwum Xcode (Release, build $BUILD_NUMBER)"
ARCHIVE="$REL/$APP_NAME.xcarchive"
xcodebuild archive \
  -project "$ROOT/AudiobookSwift/AudiobookSwift.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$REL/DerivedData" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" > "$REL/xcodebuild-archive.log" 2>&1 \
  || { tail -40 "$REL/xcodebuild-archive.log" >&2; die "xcodebuild archive nie powiódł się (log: $REL/xcodebuild-archive.log)"; }

step "Eksport z podpisem Developer ID"
# Eksport z podpisem automatycznym tworzy (raz) profil aprowizacji Developer ID
# i osadza go w paczce — bez niego grupa pęku kluczy nie jest dozwolona.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$REL/export" \
  -exportOptionsPlist "$ROOT/packaging/ExportOptions.plist" -allowProvisioningUpdates > "$REL/xcodebuild-export.log" 2>&1 \
  || { tail -40 "$REL/xcodebuild-export.log" >&2; die "Eksport nie powiódł się (log: $REL/xcodebuild-export.log)"; }
APP="$REL/export/$APP_NAME.app"
[[ -d "$APP" ]] || die "Brak $APP po eksporcie."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ -z "$(/usr/libexec/PlistBuddy -c 'Print :ABSDevelopmentRoot' "$APP/Contents/Info.plist")" ]] || die "Wydanie zawiera ścieżkę deweloperską (ABSDevelopmentRoot)."
if [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :ABSSourceURL' "$APP/Contents/Info.plist")" ]]; then
  echo "UWAGA: ABSSourceURL w Info.plist jest pusty — przed publikacją wpisz adres repozytorium ze źródłami (GPL)."
fi

step "Serwer i licencje do paczki"
RESOURCES="$APP/Contents/Resources"
ditto "$PAYLOAD" "$RESOURCES/Server"
LICENSES="$RESOURCES/Licenses"
mkdir -p "$LICENSES"
cp "$ROOT/LICENSE" "$LICENSES/LICENSE.txt"
cp "$ROOT/AudiobookSwift/AudiobookSwift/Resources/THIRD-PARTY-NOTICES.txt" "$LICENSES/"
cp "$SERVER_SRC/LICENSE" "$LICENSES/audiobookshelf-LICENSE.txt"
cp "$ROOT/build/node-runtime/LICENSE" "$LICENSES/Node.js-LICENSE.txt"
cp "$ROOT/build/node-runtime/SOURCE.txt" "$LICENSES/Node.js-SOURCE.txt"
cp "$ROOT/build/ffmpeg/licenses/"* "$LICENSES/"
cp "$ROOT/packaging/licenses/nunicode-LICENSE.txt" "$LICENSES/nunicode-sqlite-LICENSE.txt"
cp "$PROVIDERS_SRC/LICENSE" "$LICENSES/aio-abs-providers-LICENSE.txt"
cat > "$LICENSES/VERSIONS.txt" <<EOF
AudiobookSwift $VERSION ($BUILD_NUMBER), commit $(git -C "$ROOT" rev-parse HEAD)
audiobookshelf $(git -C "$ROOT/vendor/audiobookshelf" describe --tags --always), commit $(git -C "$ROOT/vendor/audiobookshelf" rev-parse HEAD)
aio-abs-providers, commit $(git -C "$ROOT/vendor/aio-abs-providers" rev-parse HEAD) (https://github.com/lakafior/aio-abs-providers)
Node.js $("$PAYLOAD/node" --version) (własny build ze źródeł z https://nodejs.org/dist/, zob. Node.js-SOURCE.txt)
$("$PAYLOAD/ffmpeg/bin/ffmpeg" -version | head -1)
libnusqlite3 $(cat "$SERVER_SRC/libnusqlite3.dylib.ver") (nunicode 1.11, https://github.com/mikiher/nunicode-sqlite)
EOF

step "Podpis aplikacji"
# Zawartość paczki się zmieniła, więc pieczęć trzeba położyć od nowa — z tymi
# samymi uprawnieniami, które nadał eksport (grupa pęku kluczy, identyfikator
# aplikacji). Binarki serwera są już podpisane; bez --deep, żeby ich nie ruszać.
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || die "Eksport nie osadził profilu aprowizacji."
codesign -d --entitlements "$REL/app.entitlements" --xml "$APP" 2> /dev/null
grep -q "$TEAM_ID.net.smigi.abswift" "$REL/app.entitlements" || die "W uprawnieniach aplikacji brakuje grupy pęku kluczy."
if grep -q 'get-task-allow' "$REL/app.entitlements"; then die "Uprawnienia aplikacji zawierają get-task-allow."; fi
codesign --force --options runtime --timestamp --entitlements "$REL/app.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

notarize() { # plik do wysłania
  local out
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || { echo "$out" >&2; die "notarytool nie powiódł się."; }
  echo "$out" | tail -4
  if ! echo "$out" | grep -q 'status: Accepted'; then
    local id
    id="$(echo "$out" | awk '/^ *id:/ {print $2; exit}')"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Notaryzacja odrzucona."
  fi
}

if (( NOTARIZE )); then
  step "Notaryzacja aplikacji"
  ditto -c -k --keepParent "$APP" "$REL/$APP_NAME.zip"
  notarize "$REL/$APP_NAME.zip"
  rm "$REL/$APP_NAME.zip"
  xcrun stapler staple "$APP"
fi

# --- DMG ----------------------------------------------------------------------

SUFFIX=""
if (( ! NOTARIZE )); then SUFFIX="-nienotaryzowany"; fi
DMG="$REL/$APP_NAME-$VERSION$SUFFIX.dmg"
step "Obraz dysku $(basename "$DMG")"
STAGING="$REL/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "$APP_NAME $VERSION" "$STAGING" "$DMG" > /dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( NOTARIZE )); then
  step "Notaryzacja obrazu dysku"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  step "Weryfikacja"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
codesign --verify --deep --strict "$APP"

step "Gotowe"
echo "  plik:    $DMG"
echo "  rozmiar: $(du -h "$DMG" | awk '{print $1}') (aplikacja po rozpakowaniu: $(du -sh "$APP" | awk '{print $1}'))"
echo "  SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
if (( ! NOTARIZE )); then echo "  UWAGA: bez notaryzacji — nie publikować."; fi
