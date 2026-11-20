#!/bin/bash
# make-corpus.sh <pusty katalog>: pliki testowe w formatach z `SupportedAudioTypes`
# upstreamu (server/utils/globals.js), z tagami, rozdziałami i okładkami.
# Potrzebuje pełnego ffmpeg z Homebrew (kodery mp3, wma, opus, x264) i zbudowanego
# build/ffmpeg (koder WebP). Format .awb pominięty: brak kodera AMR-WB w Homebrew.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$1" && cd "$1"
cp "$HERE/meta.txt" meta.txt
F() { /opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y "$@" || echo "BŁĄD: ${@: -1}"; }
F -f lavfi -i "testsrc=s=400x400:d=1" -frames:v 1 cover.jpg
F -f lavfi -i "testsrc2=s=300x300:d=1" -frames:v 1 cover.png
"$ROOT/build/ffmpeg/bin/ffmpeg" -hide_banner -loglevel error -y -i cover.png cover.webp
F -f lavfi -i "sine=f=440:d=20" -ac 2 src.wav
M=(-i meta.txt -map_metadata 1 -map_chapters 1)
F -i src.wav -i meta.txt -i cover.jpg -map_metadata 1 -map_chapters 1 -map 0:a -map 2 -c:a libmp3lame -b:a 64k -id3v2_version 3 -disposition:v attached_pic t.mp3
F -i src.wav -i meta.txt -i cover.png -map_metadata 1 -map_chapters 1 -map 0:a -map 2 -c:a aac -b:a 64k -c:v copy -disposition:v attached_pic t.m4b
F -i src.wav -i meta.txt -i cover.jpg -map_metadata 1 -map_chapters 1 -map 0:a -map 2 -c:a aac -b:a 64k -c:v copy -disposition:v attached_pic t.m4a
F -i src.wav -i meta.txt -i cover.jpg -map_metadata 1 -map_chapters 1 -map 0:a -map 2 -c:a flac -c:v copy -disposition:v attached_pic t.flac
F -i src.wav "${M[@]}" -c:a libopus -b:a 48k t.opus
F -i src.wav "${M[@]}" -c:a vorbis -strict -2 t.ogg
F -i src.wav "${M[@]}" -c:a vorbis -strict -2 -f ogg t.oga
F -i src.wav "${M[@]}" -c:a wmav2 -b:a 64k t.wma
F -i src.wav "${M[@]}" -c:a pcm_s16be t.aiff
F -i src.wav "${M[@]}" -c:a pcm_s16le t.aif -f aiff
F -i src.wav "${M[@]}" -c:a pcm_s16le t.wav
F -i src.wav "${M[@]}" -c:a libopus t.webm
F -i src.wav "${M[@]}" -c:a libopus -f webm t.webma
F -i src.wav "${M[@]}" -c:a alac t.mka
F -i src.wav -c:a aac -b:a 64k t.aac
F -i src.wav "${M[@]}" -c:a alac t.caf
F -i src.wav -ar 16000 -ac 1 -c:a libvo_amrwbenc -f amr t.awb
F -i src.wav -f lavfi -i "testsrc=s=320x240:d=20" -c:a mp2 -c:v mpeg1video t.mpg
F -i src.wav -f lavfi -i "testsrc=s=320x240:d=20" -c:a ac3 -c:v mpeg2video -f vob t.mpeg
F -i src.wav -f lavfi -i "testsrc=s=320x240:d=20" "${M[@]}" -map 0:a -map 1:v -c:a aac -c:v libx264 -pix_fmt yuv420p t.mp4
F -i src.wav "${M[@]}" -c:a eac3 eac3.mka
F -i src.wav "${M[@]}" -c:a ac3 ac3.m4a
ls -la
