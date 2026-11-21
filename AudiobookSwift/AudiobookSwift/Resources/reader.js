// Czytnik EPUB (etap 9g): cienka warstwa na epub.js 0.3.93, tej samej wersji co web UI
// audiobookshelf v2.38.0, z tymi samymi opcjami renderowania (`EpubReader.vue`). Dzięki temu
// pozycja `ebookLocation` (CFI) i `ebookProgress` znaczą to samo w web UI, na telefonie i tutaj.
// Swift steruje przez `window.reader`, odpowiedzi idą przez `webkit.messageHandlers.reader`.
(function () {
  'use strict'

  const post = (type, payload) => {
    try {
      window.webkit.messageHandlers.reader.postMessage(Object.assign({ type }, payload || {}))
    } catch (e) {}
  }

  window.addEventListener('error', (e) => post('error', { message: String(e.message || e) }))
  const consoleError = console.error
  console.error = (...args) => {
    post('error', { message: args.map((a) => (a && a.stack) || String(a)).join(' ') })
    consoleError.apply(console, args)
  }
  window.addEventListener('unhandledrejection', (e) => {
    const reason = e.reason
    post('error', { message: String((reason && reason.message) || reason) })
  })

  const themes = {
    light: { fg: '#000', bg: 'rgb(255, 255, 255)' },
    sepia: { fg: '#5b4636', bg: 'rgb(244, 236, 216)' },
    dark: { fg: '#fff', bg: 'rgb(35, 35, 35)' }
  }

  let book = null
  let rendition = null
  let settings = { theme: 'light', fontScale: 100, lineSpacing: 115, font: 'serif', spread: 'auto' }
  let lastCfi = null
  let started = false

  // Jak `themeRules` w web UI (bez obrysu tekstu).
  function rules(s) {
    const t = themes[s.theme] || themes.light
    const line = (s.lineSpacing / 100) * (s.fontScale / 100)
    return {
      '*': {
        color: `${t.fg}!important`,
        'background-color': `${t.bg}!important`,
        'line-height': `${line}rem!important`
      },
      a: { color: `${t.fg}!important` }
    }
  }

  function applySettings() {
    const t = themes[settings.theme] || themes.light
    document.documentElement.style.setProperty('--bg', t.bg)
    if (!rendition) return
    rendition.getContents().forEach((c) => c.addStylesheetRules(rules(settings)))
    rendition.themes.fontSize(`${settings.fontScale}%`)
    rendition.themes.font(settings.font === 'sans' ? '-apple-system, Helvetica, sans-serif' : 'Georgia, serif')
    rendition.spread(settings.spread || 'auto')
  }

  function isRTL() {
    return book && book.package && book.package.metadata && book.package.metadata.direction === 'rtl'
  }

  // Spis treści jako płaska lista z poziomem; adresy rozwiązane względem pliku nawigacji
  // (jak `getChapters` w web UI, zob. epub.js #1084).
  function tableOfContents() {
    const items = []
    const base = 'https://example.invalid/'
    const navPath = book.packaging.navPath || book.packaging.ncxPath || ''
    const walk = (list, depth) => {
      for (const entry of list || []) {
        let href = entry.href
        try {
          href = new URL(entry.href, base + navPath).href.replace(base, '')
        } catch (e) {}
        items.push({ label: (entry.label || '').trim(), href, depth })
        walk(entry.subitems, depth + 1)
      }
    }
    walk(book.navigation && book.navigation.toc, 0)
    return items
  }

  function describe(location, changed) {
    return {
      cfi: location.start.cfi,
      percentage: book.locations.length() ? location.end.percentage : null,
      changed,
      chapter: chapterLabel(location),
      atStart: !!location.atStart,
      atEnd: !!location.atEnd
    }
  }

  function chapterLabel(location) {
    const href = location && location.start && location.start.href
    if (!href || !book.navigation) return null
    const item = book.navigation.get(href)
    return item ? (item.label || '').trim() : null
  }

  const reader = {
    open(options) {
      settings = Object.assign(settings, options.settings || {})
      applySettings()
      book = ePub('absreader://local/book.epub', { openAs: 'epub' })
      // Opcje jak w `EpubReader.vue` — inny menedżer albo przepływ dałby inne CFI.
      // Wymiary w pikselach jak w web UI — z „100%” WebKit przy starcie w środku rozdziału
      // zostawiał pustą stronę.
      const viewer = document.getElementById('viewer')
      rendition = book.renderTo('viewer', {
        width: viewer.clientWidth,
        height: viewer.clientHeight,
        allowScriptedContent: false,
        spread: settings.spread || 'auto',
        snap: true,
        manager: 'continuous',
        flow: 'paginated'
      })
      const start = options.location && String(options.location).startsWith('epubcfi') ? options.location : undefined
      lastCfi = start || null
      // Dopóki nie stanie się miejsce zapisane na serwerze, nie zgłaszamy pozycji — pierwsze
      // `relocated` (początek rozdziału) nadpisałoby postęp czytania z innego urządzenia.
      rendition.on('relocated', (location) => {
        if (!started) return
        const cfi = location.start.cfi
        post('relocated', describe(location, cfi !== lastCfi))
        lastCfi = cfi
      })
      rendition
        .display(start)
        .catch((error) => {
          post('log', { message: 'start ' + start + ': ' + String((error && error.message) || error) })
          return rendition.display()
        })
        .then(() => {
          started = true
          // WebKit potrafi narysować pustą stronę przy przewinięciu do miejsca w środku
          // rozdziału; ponowne wyświetlenie tego samego miejsca po klatce to naprawia.
          const location = rendition.currentLocation()
          if (start && location && location.start) {
            setTimeout(() => rendition.display(location.start.cfi).then(() => reader.report()), 50)
          } else {
            reader.report()
          }
        })
        .catch((error) => post('error', { message: 'display: ' + String((error && error.message) || error) }))
      rendition.on('rendered', () => applySettings())

      book.ready
        .then(() => {
          const meta = book.package.metadata || {}
          post('opened', { title: meta.title || '', toc: tableOfContents() })
          if (options.locations) {
            book.locations.load(options.locations)
            post('locationsReady', {})
            reader.report()
          } else {
            book.locations.generate().then(() => {
              post('locations', { json: book.locations.save() })
              post('locationsReady', {})
              reader.report()
            })
          }
        })
        .catch((error) => post('error', { message: String((error && error.message) || error) }))
    },
    // Ponowne zgłoszenie bieżącej pozycji (np. gdy właśnie powstały lokacje i jest już procent).
    report() {
      if (!started || !rendition || !rendition.manager) return
      const location = rendition.currentLocation()
      if (!location || !location.start) return
      post('relocated', describe(location, false))
    },
    // Strzałki: klawisze obsługuje Swift (ramka z treścią nie uruchamia skryptów, więc
    // nasłuch epub.js w niej nie działa); przy książce od prawej do lewej kierunek się odwraca.
    left() {
      isRTL() ? reader.next() : reader.prev()
    },
    right() {
      isRTL() ? reader.prev() : reader.next()
    },
    next() {
      if (rendition && rendition.manager) rendition.next()
    },
    prev() {
      if (rendition && rendition.manager) rendition.prev()
    },
    display(target) {
      if (rendition && rendition.manager) rendition.display(target)
    },
    // Procent 0…1 → miejsce w książce (suwak w Swifcie); wymaga lokacji.
    seek(fraction) {
      if (!rendition || !book.locations.length()) return
      const cfi = book.locations.cfiFromPercentage(Math.min(1, Math.max(0, fraction)))
      if (cfi) rendition.display(cfi)
    },
    apply(next) {
      settings = Object.assign(settings, next || {})
      applySettings()
    },
    resize() {
      const viewer = document.getElementById('viewer')
      if (rendition && rendition.manager) rendition.resize(viewer.clientWidth, viewer.clientHeight)
    }
  }

  let resizeTimer = null
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer)
    resizeTimer = setTimeout(() => reader.resize(), 150)
  })

  window.reader = reader
  post('ready', {})
})()
