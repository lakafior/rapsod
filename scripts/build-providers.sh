#!/bin/bash
# Buduje agregator źródeł metadanych z submodule `vendor/aio-abs-providers` do katalogu
# `build/aio-abs-providers` (ignorowanego przez git). Submodule pozostaje nietknięty:
# źródła są eksportowane przez `git archive`, a node_modules powstaje wyłącznie
# w katalogu wyjściowym.
#
# Agregator to czysty JavaScript (bez modułów natywnych i skryptów instalacyjnych),
# więc „budowanie” to eksport i `npm ci --omit=dev`. Używa Node z `build/node`,
# który pobiera `scripts/build-server.sh` — ten sam Node uruchamia potem agregator.
#
# Użycie: scripts/build-providers.sh [--clean]
# Powtórz po każdym przesunięciu przypięcia submodule.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/aio-abs-providers"
OUT="$ROOT/build/aio-abs-providers"
NODE_DIR="$ROOT/build/node"

if [[ ! -f "$SRC/package.json" ]]; then
  echo "Brak submodule. Uruchom: git submodule update --init" >&2
  exit 1
fi
if [[ ! -x "$NODE_DIR/bin/node" ]]; then
  echo "Brak Node w $NODE_DIR. Uruchom najpierw: scripts/build-server.sh" >&2
  exit 1
fi
export PATH="$NODE_DIR/bin:$PATH"

if [[ "${1-}" == "--clean" ]]; then rm -rf "$OUT"; fi

REV="$(git -C "$SRC" rev-parse HEAD)"
STAMP="$REV node-$(node -v)"
echo "==> aio-abs-providers $(git -C "$SRC" describe --tags --always) ($REV), node $(node -v), npm $(npm -v)"

if [[ -f "$OUT/.providers-revision" && "$(cat "$OUT/.providers-revision")" == "$STAMP" ]]; then
  echo "==> $OUT jest aktualny (użyj --clean, aby przebudować)"
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"
echo "==> Eksport źródeł do $OUT"
git -C "$SRC" archive HEAD | tar -x -C "$OUT"

echo "==> Zależności produkcyjne (npm ci --omit=dev)"
(cd "$OUT" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)

echo "==> Test uruchomienia"
# Start na wolnym porcie z konfiguracją w katalogu tymczasowym; stdin z potoku,
# którego zamknięcie kończy proces (tak samo uruchamia go aplikacja).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && sleep 3 | PORT=0 HOST=127.0.0.1 CONFIG_PATH="$TMP/config.json" EXIT_ON_STDIN_CLOSE=1 \
  node "$OUT/src/backbone/server.js" > "$TMP/out.log" 2>&1) || true
if ! grep -q '^Backbone listening on http://127\.0\.0\.1:[0-9]' "$TMP/out.log"; then
  echo "Agregator nie wystartował:" >&2
  cat "$TMP/out.log" >&2
  exit 1
fi
grep '^Backbone listening on' "$TMP/out.log" | sed 's/ (config:.*//'

echo "$STAMP" > "$OUT/.providers-revision"
echo "==> Gotowe: $OUT"
