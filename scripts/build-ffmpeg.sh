#!/bin/bash
# Kompiluje ffmpeg i ffprobe ze źródeł do `build/ffmpeg` (ignorowanego przez git).
#
# Build statyczny, bez bibliotek z Homebrew: jedyną biblioteką zewnętrzną jest
# libwebp (upstream domyślnie żąda miniatur okładek w WebP, a ffmpeg nie ma
# własnego kodera WebP). Bez `--enable-gpl` i `--enable-nonfree`, więc wynik jest
# na licencji LGPL 2.1+. Wymaga tylko narzędzi wiersza poleceń Xcode.
#
# Użycie: scripts/build-ffmpeg.sh [--clean]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ffmpeg"

# Źródła przypięte do wersji i sumy SHA-256.
FFMPEG_VERSION="9.0.2"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
LIBWEBP_VERSION="1.6.0"
LIBWEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$LIBWEBP_VERSION.tar.gz"
LIBWEBP_SHA256="e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"

# Najstarszy system, na którym binarki mają działać (Node 24 wymaga 13.5).
export MACOSX_DEPLOYMENT_TARGET="13.5"

# Opcje `configure` ffmpeg. `--disable-autodetect` gwarantuje, że nic z systemu
# budującego (Homebrew) nie zostanie wlinkowane; potrzebne rzeczy włączamy jawnie:
# AudioToolbox (koder aac_at), SecureTransport (https), zlib (PNG), libwebp.
FFMPEG_CONFIGURE=(
  --cc=clang --arch=arm64
  --disable-autodetect --disable-doc --disable-debug --disable-ffplay
  --disable-shared --enable-static
  --enable-audiotoolbox --enable-securetransport --enable-zlib --enable-pthreads
  --enable-libwebp
)

STAMP="ffmpeg-$FFMPEG_VERSION libwebp-$LIBWEBP_VERSION min-$MACOSX_DEPLOYMENT_TARGET ${FFMPEG_CONFIGURE[*]}"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Build ffmpeg jest przygotowany tylko dla Apple Silicon." >&2
  exit 1
fi

if [[ "${1-}" == "--clean" ]]; then rm -rf "$OUT"; fi
if [[ -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP" ]]; then
  echo "==> $OUT jest aktualny (użyj --clean, aby przebudować)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
JOBS="$(sysctl -n hw.ncpu)"

fetch() { # url, suma, plik
  curl -fsSL -o "$3" "$1"
  local actual
  actual="$(shasum -a 256 "$3" | awk '{print $1}')"
  if [[ "$actual" != "$2" ]]; then
    echo "Zła suma SHA-256 dla $1: $actual (oczekiwano $2)" >&2
    exit 1
  fi
}

echo "==> libwebp $LIBWEBP_VERSION"
fetch "$LIBWEBP_URL" "$LIBWEBP_SHA256" "$WORK/libwebp.tar.gz"
mkdir "$WORK/libwebp" "$WORK/deps"
tar -xzf "$WORK/libwebp.tar.gz" -C "$WORK/libwebp" --strip-components 1
(cd "$WORK/libwebp" \
  && ./configure --prefix="$WORK/deps" --disable-shared --enable-static \
       --disable-libwebpmux --disable-libwebpdemux --disable-libwebpdecoder \
       --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-gl --disable-sdl > "$WORK/libwebp-configure.log" \
  && make -j"$JOBS" > "$WORK/libwebp-make.log" 2>&1 \
  && make install >> "$WORK/libwebp-make.log" 2>&1) \
  || { tail -30 "$WORK"/libwebp-*.log >&2; exit 1; }

# `configure` ffmpeg szuka libwebp przez pkg-config, którego czysty macOS nie ma.
# Ten zamiennik zna wyłącznie naszą statyczną kopię libwebp.
cat > "$WORK/pkg-config" <<EOF
#!/bin/sh
mode=""; found=1
for a in "\$@"; do
  case "\$a" in
    --exists|--cflags|--libs|--version) mode="\$a" ;;
    libwebp|"libwebp "*) found=0 ;;
  esac
done
[ "\$mode" = "--version" ] && { echo 0.29; exit 0; }
[ "\$found" = 0 ] || exit 1
case "\$mode" in
  --cflags) echo "-I$WORK/deps/include" ;;
  --libs) echo "-L$WORK/deps/lib -lwebp -lsharpyuv" ;;
esac
exit 0
EOF
chmod +x "$WORK/pkg-config"

echo "==> ffmpeg $FFMPEG_VERSION (kilka minut)"
fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "$WORK/ffmpeg.tar.xz"
mkdir "$WORK/ffmpeg"
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK/ffmpeg" --strip-components 1
(cd "$WORK/ffmpeg" \
  && ./configure --prefix="$WORK/out" --pkg-config="$WORK/pkg-config" "${FFMPEG_CONFIGURE[@]}" > "$WORK/ffmpeg-configure.log" \
  && make -j"$JOBS" > "$WORK/ffmpeg-make.log" 2>&1 \
  && make install >> "$WORK/ffmpeg-make.log" 2>&1) \
  || { tail -30 "$WORK"/ffmpeg-*.log >&2; exit 1; }

if ! grep -q '^License: LGPL version 2.1 or later' "$WORK/ffmpeg-configure.log"; then
  echo "Nieoczekiwana licencja buildu ffmpeg:" >&2
  grep '^License' "$WORK/ffmpeg-configure.log" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/licenses"
cp "$WORK/out/bin/ffmpeg" "$WORK/out/bin/ffprobe" "$OUT/bin/"
strip -x "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"
cp "$WORK/ffmpeg/COPYING.LGPLv2.1" "$OUT/licenses/FFmpeg-COPYING.LGPLv2.1.txt"
cp "$WORK/ffmpeg/LICENSE.md" "$OUT/licenses/FFmpeg-LICENSE.md"
cp "$WORK/libwebp/COPYING" "$OUT/licenses/libwebp-COPYING.txt"
# Informacja o źródłach wymagana przez LGPL: skąd wziąć dokładnie ten kod i jak go zbudować.
cat > "$OUT/licenses/FFmpeg-SOURCE.txt" <<EOF
ffmpeg i ffprobe w tej paczce zbudowano z niezmienionych źródeł:
  $FFMPEG_URL
  SHA-256: $FFMPEG_SHA256
  $LIBWEBP_URL
  SHA-256: $LIBWEBP_SHA256
Opcje configure ffmpeg: ${FFMPEG_CONFIGURE[*]}
Przepis budowania: scripts/build-ffmpeg.sh w repozytorium aplikacji.
EOF

echo "==> Test: brak bibliotek spoza systemu, koder WebP i AAC"
if otool -L "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe" | grep -v ':$' | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
  echo "ffmpeg linkuje biblioteki spoza systemu (powyżej)." >&2
  exit 1
fi
"$OUT/bin/ffmpeg" -hide_banner -loglevel error -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 -y "$WORK/test.webp"
"$OUT/bin/ffmpeg" -hide_banner -loglevel error -f lavfi -i "sine=duration=1" -c:a aac -y "$WORK/test.m4a"
"$OUT/bin/ffprobe" -v error -show_entries format=format_name -of csv=p=0 "$WORK/test.m4a" > /dev/null

echo "$STAMP" > "$OUT/.stamp"
echo "==> Gotowe: $OUT ($("$OUT/bin/ffmpeg" -version | head -1))"
