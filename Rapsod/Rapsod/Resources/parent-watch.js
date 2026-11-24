// Ładowany przez `node --require` przed kodem audiobookshelf (bez modyfikacji upstreamu).
// Aplikacja trzyma drugi koniec potoku stdin; gdy aplikacja znika (także po SIGKILL),
// jądro zamyka potok, a serwer dostaje EOF i sam się wyłącza. macOS nie ma odpowiednika
// PR_SET_PDEATHSIG, więc to jedyny sposób bez odpytywania.
const HARD_EXIT_MS = 5000

// Procesy potomne serwera (ffmpeg przy scalaniu do M4B, osadzaniu metadanych, pobieraniu
// podcastów, ffprobe przy skanie). Po śmierci node zostałyby sierotami i pracowały dalej
// (sprawdzone: ffmpeg scalający M4B żył po `kill -9` aplikacji), więc zapamiętujemy każdy
// proces z `child_process.spawn` i zabijamy żyjące przy wyjściu. Podmiana musi nastąpić,
// zanim upstream wczyta `fluentFfmpeg` (bierze `spawn` przy załadowaniu modułu).
const childProcess = require('child_process')
const children = new Set()
const originalSpawn = childProcess.spawn
childProcess.spawn = function (...args) {
  const child = originalSpawn.apply(this, args)
  if (child.pid) {
    children.add(child)
    child.once('exit', () => children.delete(child))
  }
  return child
}

function killChildren() {
  for (const child of children) {
    try {
      child.kill('SIGKILL')
    } catch {}
  }
  children.clear()
}

// `exit` obejmuje i zwykłe wyłączenie (SIGINT od aplikacji), i wyjście awaryjne poniżej.
process.on('exit', killChildren)

let shuttingDown = false

function shutdown() {
  // Drugi SIGINT upstream traktuje jak żądanie natychmiastowego wyjścia.
  if (shuttingDown) return
  shuttingDown = true
  // Aplikacji już nie ma — trwające zadania (np. scalanie) nie mają dokąd wrócić.
  killChildren()
  // Upstream obsługuje tylko SIGINT (zamyka bazę i wychodzi).
  process.kill(process.pid, 'SIGINT')
  setTimeout(() => process.exit(0), HARD_EXIT_MS).unref()
}

process.stdin.on('end', shutdown)
process.stdin.on('close', shutdown)
process.stdin.on('error', shutdown)
process.stdin.resume()
