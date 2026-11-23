#!/bin/zsh
# Buduje makietę i robi zrzuty każdego ekranu w jasnym i ciemnym wyglądzie.
# Wymaga zgody na nagrywanie ekranu dla terminala (screencapture -l).
set -e
cd "${0:A:h}"
BUILD=${TMPDIR:-/tmp}/makieta-ustawien
mkdir -p "$BUILD" ../makiety-png
swiftc -O -parse-as-library -o "$BUILD/Makieta" Makieta.swift

cat > "$BUILD/winid.swift" <<'EOF'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}
EOF
swiftc -o "$BUILD/winid" "$BUILD/winid.swift"

for screen in users profile root remote libraries; do
  for look in light dark; do
    "$BUILD/Makieta" $screen $look >/dev/null 2>&1 &
    pid=$!
    wid=""
    for i in {1..50}; do
      wid=$("$BUILD/winid" $pid)
      [[ -n $wid ]] && break
      perl -e 'select(undef,undef,undef,0.1)'
    done
    perl -e 'select(undef,undef,undef,1.5)'  # czas na pierwszy rysunek
    screencapture -o -x -l $wid "$BUILD/$screen-$look.png"
    kill $pid
    # Retina → połowa rozdzielczości, żeby pliki w repozytorium były małe.
    sips --resampleWidth 860 "$BUILD/$screen-$look.png" --out "../makiety-png/$screen-$look.png" >/dev/null
  done
done
ls ../makiety-png
