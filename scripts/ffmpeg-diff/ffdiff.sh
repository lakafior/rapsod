#!/bin/bash
# ffdiff.sh <katalog z ffmpeg i ffprobe> <korpus z make-corpus.sh> <katalog wyników>
# Uruchamia wywołania ffmpeg/ffprobe takie jak w upstreamie (Stream.js, ffmpegHelpers.js,
# libs/nodeFfprobe) na każdym pliku korpusu i zapisuje w <wyniki>/results.txt kod wyjścia
# każdego testu i sumę MD5 wyjścia ffprobe. Dwa buildy porównuje się przez `diff`
# plików results.txt (zob. README, „ffmpeg”). Niezerowe kody są w porządku, jeśli pełny
# build zwraca te same (np. okładka w WAV przy `-c copy`, koder opus bez `-strict -2`).
set -u
B=$1; C=$2; O=$3; rm -rf "$O"; mkdir -p "$O/w"
FF="$B/ffmpeg"; FP="$B/ffprobe"
r() { local name=$1; shift; env -i PATH=/usr/bin:/bin "$@" > "$O/w/$name.log" 2>&1; echo "$name $?" >> "$O/results.txt"; }
probe() { env -i "$FP" -hide_banner -loglevel fatal -show_error -show_format -show_streams -show_programs -show_chapters -show_private_data -print_format json "$1" | sed "s#$O/w/##g; s#$C/##g"; }
"$FF" -hide_banner -formats > /dev/null 2>&1; echo "formats $?" >> "$O/results.txt"
for f in concat hls mp4 ipod mp3 ffmetadata image2 mpegts webp flac ogg matroska; do
  "$FF" -hide_banner -formats 2>/dev/null | grep -qE "^ [D ][E ]d?[E ]? +$f( |,|$)|[ ,]$f[ ,]" && echo "fmt-$f ok" >> "$O/results.txt" || echo "fmt-$f BRAK" >> "$O/results.txt"
done
for e in aac opus mjpeg png libwebp; do "$FF" -hide_banner -encoders 2>/dev/null | grep -qE " $e " && echo "enc-$e ok" >> "$O/results.txt" || echo "enc-$e BRAK" >> "$O/results.txt"; done
for img in cover.jpg cover.png cover.webp; do for fmt in webp jpeg png; do
  ext=$fmt; [[ $fmt == jpeg ]] && ext=jpg
  r "resize-$img-$fmt" "$FF" -y -i "$C/$img" -vf scale=100:-1 "$O/w/r-$img.$ext"
done; done
for path in "$C"/t.* "$C"/ac3.m4a "$C"/eac3.mka; do
  f=$(basename "$path"); ext=${f##*.}
  probe "$path" > "$O/probe-$f.json"; echo "probe-$f $? $(md5 -q "$O/probe-$f.json")" >> "$O/results.txt"
  printf "file '%s'\nduration 20\n" "$path" > "$O/w/list-$f.txt"
  for mode in copy aac; do
    mkdir -p "$O/w/hls-$f-$mode"
    r "hls-$mode-$f" "$FF" -f concat -safe 0 -seek_timestamp 1 -ss 3 -noaccurate_seek -i "$O/w/list-$f.txt" -y -copyts -avoid_negative_ts make_non_negative -max_delay 5000000 -max_muxing_queue_size 2048 -map 0:a -c:a $( [[ $mode == aac ]] && echo "aac -ac 2 -b:a 96k" || echo copy ) -f hls -hls_time 6 -hls_segment_type mpegts -start_number 0 -hls_playlist_type vod -hls_list_size 0 -hls_allow_cache 0 -hls_segment_filename "$O/w/hls-$f-$mode/output-%d.ts" "$O/w/hls-$f-$mode/output.m3u8"
  done
  codec=$(env -i "$FP" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$path" | head -1)
  if [[ -n "$codec" ]]; then cext=jpg; [[ $codec == png ]] && cext=png; r "cover-$f" "$FF" -y -i "$path" -map 0:v:0 -frames:v 1 "$O/w/c-$f.$cext"; fi
  fmt=(); case $ext in m4b|m4a|mp4) fmt=(-f mp4);; mp3) fmt=(-id3v2_version 3);; esac
  r "embed-$f" "$FF" -y -i "$path" -i "$C/meta.txt" -i "$C/cover.jpg" -map 0:a -map_metadata 1 -map_metadata 0 -map_chapters 1 -c copy -metadata track=1 ${fmt[@]+"${fmt[@]}"} -map 2:v -disposition:v:0 attached_pic -metadata:s:v title=Cover -metadata:s:v comment=Cover "$O/w/e-$f.tmp.$ext"
  r "embedwebp-$f" "$FF" -y -i "$path" -i "$C/meta.txt" -i "$C/cover.webp" -map 0:a -map_metadata 1 -map_metadata 0 -map_chapters 1 -c copy ${fmt[@]+"${fmt[@]}"} -map 2:v -disposition:v:0 attached_pic -c:v mjpeg "$O/w/ew-$f.tmp.$ext"
  r "embednocover-$f" "$FF" -y -i "$path" -i "$C/meta.txt" -map 0:a -map_metadata 1 -map_metadata 0 -map_chapters 1 -c copy ${fmt[@]+"${fmt[@]}"} -map '0:v?' "$O/w/en-$f.tmp.$ext"
  [[ -f "$O/w/e-$f.tmp.$ext" ]] && { probe "$O/w/e-$f.tmp.$ext" > "$O/probe-embed-$f.json"; echo "probe-embed-$f $(md5 -q "$O/probe-embed-$f.json")" >> "$O/results.txt"; }
  printf "file '%s'\nfile '%s'\n" "$path" "$path" > "$O/w/merge-$f.txt"
  for codec in aac opus copy; do
    r "merge-$codec-$f" "$FF" -y -safe 0 -f concat -i "$O/w/merge-$f.txt" -f mp4 -map 0:a -acodec $codec -ac 2 -b:a 64k "$O/w/m-$codec-$f.m4b"
  done
  r "podcast-$f" bash -c "cat '$path' | '$FF' -y -loglevel debug -i pipe:0 -c:a copy -map 0:a -metadata podcast=1 -metadata album='Ćma' '$O/w/p-$f.$ext'"
done
sort -o "$O/results.txt" "$O/results.txt"
