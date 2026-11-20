# Przypięty Node.js — wspólny dla scripts/build-server.sh (oficjalna binarka,
# która buduje serwer) i scripts/build-node.sh (własny, odchudzony build
# wkładany do paczki). Sumy z https://nodejs.org/dist/v<wersja>/SHASUMS256.txt.
# Upstream celuje w Node 24; na Node 25+ serwer nie startuje (usunięty `SlowBuffer`).
NODE_VERSION="24.22.3"
NODE_SHA256_DARWIN_ARM64="1d64136c8a43d648d1b3bad10797a4c995b1ca032d2bde8799de43b37f058fe5"
NODE_SHA256_DARWIN_X64="4daeec962855c1a6e66cda398a25037319dc1bbd4a0939188b3547afbbfb6490"
NODE_SHA256_SOURCE="48ca3aa8a9b02133356922ef4fc80200e00598c80a4ef446f7c39a459222593d"
