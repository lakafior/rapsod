#!/bin/bash
# Kompiluje Node.js ze źródeł w wersji uruchamiającej serwer w paczce i kopiuje
# wynik do `build/node-runtime` (ignorowanego przez git).
#
# Względem oficjalnej binarki (122 MB, po `strip -x` 98 MB) build ma ok. 62 MB:
# dane ICU tylko dla angielskiego i polskiego (small-icu), bez inspektora
# (`--inspect`) i bez dołączonych narzędzi, których serwer nie używa (npm,
# corepack, amaro, `node:sqlite`). Zostaje wszystko, czego używa audiobookshelf:
# Intl (Collator, normalize, strefy czasowe), OpenSSL, WebAssembly, worker_threads,
# zlib, N-API (moduł sqlite3). Test na końcu sprawdza te elementy.
#
# Czysta kompilacja trwa ok. 30 minut, więc wynik trafia do pamięci podręcznej
# wspólnej dla wszystkich kopii repozytorium (worktree):
#   ${ABS_BUILD_CACHE:-~/Library/Caches/Rapsod-build}/node-<wersja>-<skrót opcji>
# Kolejne wywołania i nowe worktree tylko kopiują gotowy plik.
#
# Wymaga narzędzi Xcode i Pythona 3.9–3.14 (wystarczy systemowy /usr/bin/python3).
# Użycie: scripts/build-node.sh [--clean]   (--clean kompiluje od nowa także w pamięci podręcznej)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/node-runtime"
source "$ROOT/scripts/node-version.sh"
NODE_SOURCE_URL="https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION.tar.xz"

# Opcje configure. Języki ICU: polski, bo aplikacja przekazuje serwerowi LANG
# użytkownika, a serwer sortuje (Intl.Collator) według domyślnego języka procesu.
NODE_CONFIGURE=(
  --with-intl=small-icu --with-icu-locales=en,pl
  --without-inspector --without-npm --without-corepack --without-amaro --without-sqlite
)

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Build Node jest przygotowany tylko dla Apple Silicon." >&2
  exit 1
fi

KEY="$(echo "$NODE_VERSION $NODE_SHA256_SOURCE ${NODE_CONFIGURE[*]} $(xcrun clang --version | head -1)" | shasum -a 256 | cut -c1-12)"
CACHE="${ABS_BUILD_CACHE:-$HOME/Library/Caches/Rapsod-build}/node-$NODE_VERSION-$KEY"
STAMP="node-$NODE_VERSION $KEY"

if [[ "${1-}" == "--clean" ]]; then rm -rf "$OUT" "$CACHE"; fi
if [[ -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP" ]]; then
  echo "==> $OUT jest aktualny (użyj --clean, aby przebudować)"
  exit 0
fi

if [[ ! -f "$CACHE/node" ]]; then
  PYTHON=""
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 /usr/bin/python3; do
    if command -v "$candidate" > /dev/null \
      && "$candidate" -c 'import sys; sys.exit(0 if (3, 9) <= sys.version_info[:2] <= (3, 14) else 1)' 2> /dev/null; then
      PYTHON="$(command -v "$candidate")"; break
    fi
  done
  [[ -n "$PYTHON" ]] || { echo "Brak Pythona 3.9–3.14 (configure Node odrzuca inne wersje)." >&2; exit 1; }

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  echo "==> Źródła Node.js $NODE_VERSION"
  curl -fsSL -o "$WORK/node.tar.xz" "$NODE_SOURCE_URL"
  actual="$(shasum -a 256 "$WORK/node.tar.xz" | awk '{print $1}')"
  if [[ "$actual" != "$NODE_SHA256_SOURCE" ]]; then
    echo "Zła suma SHA-256 dla $NODE_SOURCE_URL: $actual (oczekiwano $NODE_SHA256_SOURCE)" >&2
    exit 1
  fi
  mkdir "$WORK/src"
  tar -xJf "$WORK/node.tar.xz" -C "$WORK/src" --strip-components 1
  echo "==> Kompilacja (ok. 30 minut; log: $WORK/make.log, usuwany na końcu)"
  START=$SECONDS
  (cd "$WORK/src" \
    && "$PYTHON" configure.py "${NODE_CONFIGURE[@]}" > "$WORK/configure.log" 2>&1 \
    && make -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1) \
    || { tail -30 "$WORK"/configure.log "$WORK"/make.log >&2 2> /dev/null; exit 1; }
  echo "  czas kompilacji: $(( (SECONDS - START) / 60 )) min"

  mkdir -p "$CACHE.tmp"
  cp "$WORK/src/out/Release/node" "$CACHE.tmp/node"
  # Tylko symbole lokalne: pełny `strip` usuwa też symbole N-API, których szuka
  # moduł natywny sqlite3 (dlopen kończy się błędem „symbol not found”).
  strip -x "$CACHE.tmp/node"
  # strip unieważnia podpis ad hoc z linkera; bez podpisu Apple Silicon nie uruchomi binarki.
  codesign --force --sign - "$CACHE.tmp/node"
  cp "$WORK/src/LICENSE" "$CACHE.tmp/LICENSE"
  cat > "$CACHE.tmp/SOURCE.txt" <<EOF
Node.js w tej paczce zbudowano z niezmienionych źródeł:
  $NODE_SOURCE_URL
  SHA-256: $NODE_SHA256_SOURCE
Opcje configure: ${NODE_CONFIGURE[*]}
Po kompilacji: strip -x. Przepis budowania: scripts/build-node.sh w repozytorium aplikacji.
EOF
  rm -rf "$CACHE"
  mv "$CACHE.tmp" "$CACHE"
else
  echo "==> Node.js z pamięci podręcznej: $CACHE"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$CACHE/node" "$CACHE/LICENSE" "$CACHE/SOURCE.txt" "$OUT/"

echo "==> Test: wersja, Intl (pl), NFD, crypto, WebAssembly, worker_threads"
[[ "$("$OUT/node" -v)" == "v$NODE_VERSION" ]] || { echo "Zła wersja: $("$OUT/node" -v)" >&2; exit 1; }
env -i LANG=pl_PL.UTF-8 "$OUT/node" -e "
const assert = require('assert')
assert.strictEqual(new Intl.Collator().resolvedOptions().locale, 'pl-PL')
assert.strictEqual(['żaba', 'zebra', 'łoś', 'lis'].sort(new Intl.Collator('pl').compare).join(), 'lis,łoś,zebra,żaba')
assert.strictEqual(new Date(Date.UTC(2026, 0, 1, 12)).toLocaleString('pl-PL', { timeZone: 'Europe/Warsaw' }), '1.01.2026, 13:00:00')
assert.strictEqual('Żółć'.normalize('NFD').replace(/[̀-ͯ]/g, ''), 'Zołc')
const c = require('crypto')
c.generateKeyPairSync('ec', { namedCurve: 'P-256' }); c.pbkdf2Sync('a', 'b', 1, 8, 'sha256')
assert.ok(WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])))
const { Worker } = require('worker_threads')
new Worker(\"require('worker_threads').parentPort.postMessage(1)\", { eval: true }).on('message', () => process.exit(0))
"

echo "$STAMP" > "$OUT/.stamp"
echo "==> Gotowe: $OUT/node ($(du -h "$OUT/node" | awk '{print $1}'))"
