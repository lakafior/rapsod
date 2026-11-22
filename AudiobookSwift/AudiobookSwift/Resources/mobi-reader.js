// Czytnik MOBI/AZW3 (etap 9h): parser `mobi.js` z klienta web audiobookshelf v2.38.0
// (zapożyczony tam z Koodo Reader, AGPL-3.0), treść w ramce bez skryptów, przewijana jak
// w `MobiReader.vue`. Web UI nie zapisuje postępu MOBI; tutaj miejsce to `mobi:<ułamek 0…1>`
// (przewinięcie) — format, którego czytnik EPUB (CFI), PDF i komiksów (numer strony) nie pomyli.
// To samo API `window.reader` co `reader.js`, więc Swift obsługuje oba czytniki jednym kontrolerem.
import MobiFile from './mobi.js'

const post = (type, payload) => {
  try {
    window.webkit.messageHandlers.reader.postMessage(Object.assign({ type }, payload || {}))
  } catch (e) {}
}

window.addEventListener('error', (e) => post('error', { message: String(e.message || e) }))
window.addEventListener('unhandledrejection', (e) => post('error', { message: String((e.reason && e.reason.message) || e.reason) }))

const themes = {
  light: { fg: '#000', bg: 'rgb(255, 255, 255)' },
  sepia: { fg: '#5b4636', bg: 'rgb(244, 236, 216)' },
  dark: { fg: '#fff', bg: 'rgb(35, 35, 35)' }
}

const viewer = document.getElementById('viewer')
let frame = null
let settings = { theme: 'light', fontScale: 100, lineSpacing: 115, font: 'serif', spread: 'auto' }
let toc = []
let started = false
let lastLocation = null
let reportTimer = null

function fraction() {
  const max = viewer.scrollHeight - viewer.clientHeight
  return max > 0 ? Math.min(1, Math.max(0, viewer.scrollTop / max)) : 0
}

function scrollToFraction(value) {
  const max = viewer.scrollHeight - viewer.clientHeight
  viewer.scrollTop = Math.max(0, max * value)
}

function css() {
  const t = themes[settings.theme] || themes.light
  const family = settings.font === 'sans' ? '-apple-system, Helvetica, sans-serif' : 'Georgia, serif'
  return `
    html, body { background: ${t.bg} !important; color: ${t.fg} !important; }
    body { margin: 0 auto; max-width: 42em; padding: 32px 40px 64px; font-family: ${family};
           font-size: ${settings.fontScale}%; line-height: ${settings.lineSpacing / 100}; overflow: hidden; }
    * { color: inherit !important; background-color: transparent !important; }
    img { max-width: 100%; height: auto; }
    a { color: ${t.fg} !important; }`
}

// Wysokość ramki = wysokość treści; przewija się strona (zdarzenia przewijania w ramce bez
// skryptów nie docierałyby do tej strony).
function fitFrame() {
  const doc = frame && frame.contentDocument
  if (!doc) return
  frame.style.height = '0px'
  frame.style.height = doc.documentElement.scrollHeight + 'px'
}

function applySettings() {
  const t = themes[settings.theme] || themes.light
  document.documentElement.style.setProperty('--bg', t.bg)
  const doc = frame && frame.contentDocument
  if (!doc) return
  const keep = fraction()
  const style = doc.getElementById('reader-style')
  if (style) style.textContent = css()
  fitFrame()
  scrollToFraction(keep)
}

function currentChapter() {
  const doc = frame && frame.contentDocument
  if (!doc || !toc.length) return null
  const top = viewer.scrollTop + 40
  let label = null
  for (const entry of toc) {
    const element = doc.getElementById(entry.href.slice(1))
    if (element && element.offsetTop <= top) label = entry.label
  }
  return label
}

function report(changed) {
  if (!started) return
  const value = fraction()
  const location = 'mobi:' + value.toFixed(4)
  post('relocated', { cfi: location, percentage: value, changed: changed && location !== lastLocation, chapter: currentChapter() })
  lastLocation = location
}

// Treść z pliku jest obca: bez skryptów, ramek, wtyczek, odnośników do arkuszy i atrybutów on*.
function sanitize(root) {
  root.querySelectorAll('script, iframe, frame, object, embed, link, meta, base, form').forEach((node) => node.remove())
  root.querySelectorAll('*').forEach((node) => {
    for (const attribute of Array.from(node.attributes)) {
      const name = attribute.name.toLowerCase()
      const value = attribute.value.trim().toLowerCase()
      if (name.startsWith('on') || ((name === 'href' || name === 'src') && value.startsWith('javascript:'))) node.removeAttribute(attribute.name)
    }
    if (node.tagName === 'A') node.removeAttribute('target')
  })
}

const reader = {
  async open(options) {
    settings = Object.assign(settings, options.settings || {})
    const buffer = await (await fetch('absreader://local/book.mobi')).arrayBuffer()
    let book
    try {
      book = await new MobiFile(buffer).render()
    } catch (error) {
      post('error', { message: 'Nie udało się odczytać pliku: ' + String((error && error.message) || error) })
      return
    }
    const body = book.querySelector('body') || book
    sanitize(body)
    // Spis treści z nagłówków (calibre i większość wydawców oznacza nimi rozdziały).
    toc = []
    body.querySelectorAll('h1, h2, h3').forEach((heading, index) => {
      const label = (heading.textContent || '').trim()
      if (!label) return
      if (!heading.id) heading.id = 'rozdzial-' + index
      toc.push({ label, href: '#' + heading.id, depth: Number(heading.tagName[1]) - 1 })
    })
    const title = ((book.querySelector('title') || {}).textContent || '').trim()

    frame = document.createElement('iframe')
    frame.setAttribute('sandbox', 'allow-same-origin')
    frame.setAttribute('title', 'Treść książki')
    frame.srcdoc = '<!doctype html><html lang="pl"><head><meta charset="utf-8"><style id="reader-style"></style></head><body>' + body.innerHTML + '</body></html>'
    frame.addEventListener('load', () => {
      applySettings()
      const start = options.location && String(options.location).startsWith('mobi:') ? Number(String(options.location).slice(5)) : 0
      // Obrazy mogą zmienić wysokość chwilę po wczytaniu — dopasowanie jeszcze raz.
      setTimeout(() => {
        fitFrame()
        scrollToFraction(isFinite(start) ? start : 0)
        started = true
        post('opened', { title, toc })
        post('locationsReady', {})
        report(false)
      }, 150)
    })
    viewer.replaceChildren(frame)
  },
  report() {
    report(false)
  },
  next() {
    viewer.scrollBy({ top: viewer.clientHeight * 0.9 })
  },
  prev() {
    viewer.scrollBy({ top: -viewer.clientHeight * 0.9 })
  },
  left() {
    reader.prev()
  },
  right() {
    reader.next()
  },
  display(target) {
    const doc = frame && frame.contentDocument
    const element = doc && typeof target === 'string' && target.startsWith('#') ? doc.getElementById(target.slice(1)) : null
    if (element) viewer.scrollTop = element.offsetTop
  },
  // Link wewnętrzny (kotwica) w treści.
  link(href) {
    try {
      const hash = new URL(href).hash
      if (hash) reader.display(hash)
    } catch (e) {}
  },
  seek(value) {
    scrollToFraction(Math.min(1, Math.max(0, value)))
  },
  apply(next) {
    settings = Object.assign(settings, next || {})
    applySettings()
  },
  resize() {
    applySettings()
  }
}

viewer.addEventListener('scroll', () => {
  clearTimeout(reportTimer)
  reportTimer = setTimeout(() => report(true), 200)
})

let resizeTimer = null
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer)
  resizeTimer = setTimeout(() => reader.resize(), 150)
})

window.reader = reader
post('ready', {})
