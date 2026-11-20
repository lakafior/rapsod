#!/bin/bash
# Kompiluje ffmpeg i ffprobe ze źródeł do `build/ffmpeg` (ignorowanego przez git).
#
# Tylko składniki, których używa serwer (lista niżej), w bibliotekach wspólnych
# dla ffmpeg i ffprobe: `bin/` i `lib/` (binarki szukają bibliotek w
# `@executable_path/../lib`). Bez bibliotek z Homebrew: jedyną zewnętrzną jest
# libwebp, wlinkowana statycznie w libavcodec (upstream domyślnie żąda miniatur
# okładek w WebP, a ffmpeg nie ma własnego kodera WebP). Bez `--enable-gpl` i `--enable-nonfree`, więc wynik jest
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
# zlib (PNG, Matroska) i libwebp.
#
# `--disable-everything` i lista komponentów wynikająca z wywołań w upstreamie
# (Stream.js, utils/ffmpegHelpers.js, libs/nodeFfprobe) dla rozszerzeń
# z `SupportedAudioTypes` (utils/globals.js):
# - wejście: pliki i potok (podcasty przychodzą przez stdin, nie przez http ffmpeg),
#   demuxer concat (HLS, scalanie), ffmetadata (rozdziały), obrazy okładek;
# - wyjście: HLS w segmentach MPEG-TS, MP4/M4B, obrazy (okładki i miniatury)
#   oraz muxer dla każdego formatu, do którego upstream osadza metadane
#   z `-c copy` (rozszerzenie pliku wybiera muxer);
# - kodery: aac (transkodowanie, scalanie), opus (opcja scalania w kliencie),
#   mjpeg, png, libwebp (okładki i miniatury);
# - dekodery: dźwięk z obsługiwanych formatów, obrazy okładek i najczęstsze
#   strumienie wideo w plikach .mp4/.webm/.mpg (upstream bierze z nich okładkę);
# - lavfi z generatorami sine/color tylko do testów na końcu skryptu.
# Zmiana listy: sprawdź wyniki testu różnicowego opisanego w README.
FFMPEG_COMPONENTS=(
  --disable-everything --disable-network
  --enable-protocol=file,pipe
  --enable-demuxer=aac,ac3,eac3,aiff,amr,amrnb,amrwb,asf,caf,concat,ffmetadata,flac,loas,matroska,mov,mp3,mpegps,mpegts,ogg,w64,wav,mpegvideo,m4v,h264,hevc
  --enable-demuxer=image2,image_jpeg_pipe,image_png_pipe,image_webp_pipe
  --enable-muxer=adts,aiff,amr,asf,caf,flac,hls,image2,ipod,matroska,matroska_audio,mov,mp3,mp4,mpeg1system,mpegts,oga,ogg,opus,vob,w64,wav,webm,webp
  --enable-encoder=aac,opus,mjpeg,png,libwebp
  --enable-decoder=aac,aac_latm,ac3,eac3,alac,amrnb,amrwb,flac,mp1,mp1float,mp2,mp2float,mp3,mp3float,opus,vorbis
  --enable-decoder=wmav1,wmav2,wmapro,wmalossless,wmavoice,adpcm_ima_qt,adpcm_ima_wav,adpcm_ms,gsm,gsm_ms,pcm_alaw,pcm_mulaw
  --enable-decoder='pcm_s*,pcm_u*,pcm_f*'
  --enable-decoder=mjpeg,png,webp,bmp,gif,h264,hevc,mpeg1video,mpeg2video,mpeg4,vp8,vp9
  --enable-parser=aac,aac_latm,ac3,flac,mpegaudio,opus,vorbis,amr,mjpeg,png,webp,h264,hevc,mpegvideo,mpeg4video,vp8,vp9
  --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,mp3_header_decompress,vp9_superframe,null
  --enable-filter=abuffer,abuffersink,buffer,buffersink,aformat,format,anull,null,aresample,scale,trim,atrim,setpts,asetpts,transpose,hflip,vflip,copy,acopy
  --enable-indev=lavfi --enable-filter=sine,color --enable-decoder=wrapped_avframe
)
FFMPEG_CONFIGURE=(
  --cc=clang --arch=arm64
  --disable-autodetect --disable-doc --disable-debug --disable-ffplay
  --disable-static --enable-shared --install-name-dir=@rpath
  --extra-ldexeflags=-Wl,-rpath,@executable_path/../lib
  --enable-zlib --enable-pthreads --enable-libwebp
  "${FFMPEG_COMPONENTS[@]}"
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
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/licenses"
cp "$WORK/out/bin/ffmpeg" "$WORK/out/bin/ffprobe" "$OUT/bin/"
# Biblioteki wspólne dla ffmpeg i ffprobe; tylko pliki z numerem głównej wersji,
# do których odwołują się binarki (`@rpath/libavcodec.62.dylib` itd.).
for lib in "$WORK"/out/lib/lib*.dylib; do
  name="$(basename "$lib")"
  if [[ "$name" =~ ^lib[a-z]+\.[0-9]+\.dylib$ ]]; then cp "$lib" "$OUT/lib/$name"; fi
done
strip -x "$OUT"/bin/* "$OUT"/lib/*
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

echo "==> Test: tylko biblioteki systemowe i własne, koder WebP i AAC"
if otool -L "$OUT"/bin/* "$OUT"/lib/* | grep -v ':$' | grep -vE '^\s+(/usr/lib/|/System/Library/|@rpath/lib[a-z]+\.[0-9]+\.dylib )'; then
  echo "ffmpeg linkuje biblioteki spoza systemu (powyżej)." >&2
  exit 1
fi
# Kopia w innym miejscu, z pustym środowiskiem: biblioteki muszą się znaleźć
# względem binarki, nie względem katalogu budowania.
cp -R "$OUT" "$WORK/moved"
T="$WORK/moved/bin"
env -i "$T/ffmpeg" -hide_banner -loglevel error -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 -y "$WORK/test.webp"
env -i "$T/ffmpeg" -hide_banner -loglevel error -f lavfi -i "sine=duration=1" -c:a aac -y "$WORK/test.m4a"
env -i "$T/ffprobe" -v error -show_entries format=format_name -of csv=p=0 "$WORK/test.m4a" > /dev/null
# fluent-ffmpeg w upstreamie odrzuca wywołanie, jeśli `ffmpeg -formats` nie zna formatu z `-f`.
for format in concat ffmetadata hls mp4 mpegts; do
  env -i "$T/ffmpeg" -hide_banner -formats 2> /dev/null | grep -qE "^ [D ][E ][d ] +$format " || { echo "Brak formatu $format w ffmpeg -formats." >&2; exit 1; }
done

echo "$STAMP" > "$OUT/.stamp"
echo "==> Gotowe: $OUT ($("$OUT/bin/ffmpeg" -version | head -1))"
