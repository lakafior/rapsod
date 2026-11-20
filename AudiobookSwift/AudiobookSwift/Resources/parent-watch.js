// Ładowany przez `node --require` przed kodem audiobookshelf (bez modyfikacji upstreamu).
// Aplikacja trzyma drugi koniec potoku stdin; gdy aplikacja znika (także po SIGKILL),
// jądro zamyka potok, a serwer dostaje EOF i sam się wyłącza. macOS nie ma odpowiednika
// PR_SET_PDEATHSIG, więc to jedyny sposób bez odpytywania.
const HARD_EXIT_MS = 5000

function shutdown() {
  // Upstream obsługuje tylko SIGINT (zamyka bazę i wychodzi).
  process.kill(process.pid, 'SIGINT')
  setTimeout(() => process.exit(0), HARD_EXIT_MS).unref()
}

process.stdin.on('end', shutdown)
process.stdin.on('close', shutdown)
process.stdin.on('error', shutdown)
process.stdin.resume()
