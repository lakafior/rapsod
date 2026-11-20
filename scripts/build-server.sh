#!/bin/bash
# Buduje serwer audiobookshelf z submodule `vendor/audiobookshelf` do katalogu
# `build/abs-server` (ignorowanego przez git). Submodule pozostaje nietknięty:
# źródła są eksportowane przez `git archive`, a node_modules, dist-server
# i client/dist powstają wyłącznie w katalogu wyjściowym.
#
# Pobiera też przypięty Node.js do `build/node` — upstream celuje w Node 24,
# a na Node 25+ serwer nie startuje (usunięty `SlowBuffer`). Ten sam Node
# buduje serwer i jest używany przez aplikację do jego uruchamiania.
#
# Użycie: scripts/build-server.sh [--clean]
# Powtórz po każdym podbiciu taga submodule.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/audiobookshelf"
OUT="$ROOT/build/abs-server"
NODE_DIR="$ROOT/build/node"

# Przypięty Node.js (sumy z https://nodejs.org/dist/v<wersja>/SHASUMS256.txt).
NODE_VERSION="24.22.3"
case "$(uname -m)" in
  arm64)  NODE_ARCH="arm64"; NODE_SHA256="1d64136c8a43d648d1b3bad10797a4c995b1ca032d2bde8799de43b37f058fe5" ;;
  x86_64) NODE_ARCH="x64";   NODE_SHA256="4daeec962855c1a6e66cda398a25037319dc1bbd4a0939188b3547afbbfb6490" ;;
  *) echo "Nieobsługiwana architektura: $(uname -m)" >&2; exit 1 ;;
esac

# Musi zgadzać się z ServerConfiguration.routerBasePath w aplikacji:
# klient web ma tę ścieżkę wkompilowaną podczas `nuxt generate`.
export ROUTER_BASE_PATH="${ROUTER_BASE_PATH-/audiobookshelf}"

# Rozszerzenie SQLite (unaccent / unicode) — to samo wydanie, które upstream
# pobiera w Dockerfile i w BinaryManager.js.
NUSQLITE3_VERSION="1.2"
NUSQLITE3_URL="https://github.com/mikiher/nunicode-sqlite/releases/download/v${NUSQLITE3_VERSION}/libnusqlite3-osx-arm64.zip"
NUSQLITE3_SHA256="46dc4c6dd018027d4d5737314a2ca6b41339e5d2e50dc9bd31036d043a840abe"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

verify_sha256() { # plik, oczekiwana suma
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "$actual" != "$2" ]]; then
    echo "Zła suma SHA-256 dla $1: $actual (oczekiwano $2)" >&2
    exit 1
  fi
}

if [[ ! -f "$SRC/package.json" ]]; then
  echo "Brak submodule. Uruchom: git submodule update --init" >&2
  exit 1
fi

if [[ "${1-}" == "--clean" ]]; then rm -rf "$OUT" "$NODE_DIR"; fi

if [[ "$("$NODE_DIR/bin/node" -v 2>/dev/null || true)" != "v$NODE_VERSION" ]]; then
  echo "==> Node.js $NODE_VERSION ($NODE_ARCH) do $NODE_DIR"
  curl -fsSL -o "$TMP/node.tar.xz" "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.xz"
  verify_sha256 "$TMP/node.tar.xz" "$NODE_SHA256"
  rm -rf "$NODE_DIR" "$OUT"
  mkdir -p "$NODE_DIR"
  tar -xJf "$TMP/node.tar.xz" -C "$NODE_DIR" --strip-components 1
fi
export PATH="$NODE_DIR/bin:$PATH"

REV="$(git -C "$SRC" rev-parse HEAD)"
TAG="$(git -C "$SRC" describe --tags --always)"
STAMP="$REV node-$NODE_VERSION base=$ROUTER_BASE_PATH"
echo "==> audiobookshelf $TAG ($REV), node $(node -v), npm $(npm -v)"

if [[ -f "$OUT/.abs-revision" && "$(cat "$OUT/.abs-revision")" == "$STAMP" ]]; then
  echo "==> $OUT jest aktualny (użyj --clean, aby przebudować)"
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"
echo "==> Eksport źródeł do $OUT"
git -C "$SRC" archive HEAD | tar -x -C "$OUT"

echo "==> Klient web (nuxt generate, ROUTER_BASE_PATH='$ROUTER_BASE_PATH')"
(cd "$OUT/client" && npm ci --no-audit --no-fund && npm run generate)

echo "==> Serwer (npm ci + tsc)"
(cd "$OUT" && npm ci --no-audit --no-fund && npm run build:server && npm prune --omit=dev --no-audit --no-fund)

echo "==> Sprzątanie zależności budowania klienta"
rm -rf "$OUT/client/node_modules" "$OUT/client/.nuxt"

echo "==> libnusqlite3 $NUSQLITE3_VERSION"
curl -fsSL -o "$TMP/nusqlite3.zip" "$NUSQLITE3_URL"
verify_sha256 "$TMP/nusqlite3.zip" "$NUSQLITE3_SHA256"
unzip -q -o "$TMP/nusqlite3.zip" libnusqlite3.dylib -d "$OUT"
echo "$NUSQLITE3_VERSION" > "$OUT/libnusqlite3.dylib.ver"

echo "==> Test ładowania sqlite3 i rozszerzenia"
(cd "$OUT" && node -e "
const s = require('sqlite3')
const d = new s.Database(':memory:')
const fail = (e) => { console.error(e); process.exit(1) }
d.loadExtension('$OUT/libnusqlite3.dylib', (e) => {
  if (e) fail(e)
  d.get(\"select sqlite_version() v, unaccent('Żółć') u\", (e, r) => {
    if (e) fail(e)
    console.log('sqlite', r.v, 'unaccent:', r.u)
    d.close()
  })
})")

echo "$STAMP" > "$OUT/.abs-revision"
echo "==> Gotowe: $OUT"
