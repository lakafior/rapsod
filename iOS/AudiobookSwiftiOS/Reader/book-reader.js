// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Czytnik EPUB klienta iOS (etap 10g) — warstwa na epub.js 0.3.93 (BSD-2-Clause). Ta sama
// wersja epub.js co na Macu i w web UI, więc pozycja CFI i postęp z lokacji znaczą to samo
// na każdym urządzeniu. Swift steruje przez `window.book`, odpowiedzi idą przez
// `webkit.messageHandlers.book`. Treść książki działa bez skryptów (`allowScriptedContent: false`).
(function () {
  'use strict'

  const send = (type, data) => {
    try {
      window.webkit.messageHandlers.book.postMessage(Object.assign({ type }, data || {}))
    } catch (e) {}
  }
  const text = (e) => String((e && (e.stack || e.message)) || e)
  window.addEventListener('error', (e) => send('error', { message: String(e.message || e) }))
  window.addEventListener('unhandledrejection', (e) => send('error', { message: text(e.reason) }))

  let epub = null
  let rendition = null
  // Do pierwszego wyświetlenia zapisanego miejsca nie zgłaszamy ruchu — inaczej początek
  // rozdziału nadpisałby postęp czytania z innego urządzenia.
  let shown = false
  let look = { page: '#ffffff', ink: '#1c1c1e', link: '#0a60c2', font: '', size: 100, leading: 1.5 }

  function css(l) {
    const family = l.font ? `font-family: ${l.font} !important;` : ''
    return `
      html, body { background: ${l.page} !important; color: ${l.ink} !important; }
      body { line-height: ${l.leading} !important; ${family} }
      body * { color: inherit !important; background-color: transparent !important; ${family} }
      body p, body li, body blockquote, body div { line-height: ${l.leading} !important; }
      body a, body a * { color: ${l.link} !important; }
      img, svg, video { max-width: 100% !important; }
    `
  }

  function applyLook() {
    document.documentElement.style.setProperty('--page', look.page)
    if (!rendition) return
    rendition.getContents().forEach((c) => c.addStylesheetCss(css(look), 'abook'))
    rendition.themes.fontSize(`${look.size}%`)
  }

  // Spis treści płasko z głębokością. Adresy względem pliku nawigacji zamieniamy na ścieżki
  // w archiwum; `go` dopasowuje je do rozdziałów po końcówce.
  function contents() {
    const out = []
    const base = 'abook://local/'
    const nav = (epub.packaging && (epub.packaging.navPath || epub.packaging.ncxPath)) || ''
    const visit = (list, depth) => {
      for (const item of list || []) {
        let href = item.href || ''
        try {
          href = new URL(href, base + nav).href.slice(base.length)
        } catch (e) {}
        out.push({ label: (item.label || '').trim(), href, depth })
        visit(item.subitems, depth + 1)
      }
    }
    visit(epub.navigation && epub.navigation.toc, 0)
    return out
  }

  function spineItemFor(path) {
    const items = (epub.spine && epub.spine.spineItems) || []
    return items.find((s) => s.href && (path === s.href || path.endsWith('/' + s.href) || s.href.endsWith('/' + path)))
  }

  function chapterTitle(href) {
    if (!href || !epub.navigation) return null
    const item = epub.navigation.get(href)
    return item ? (item.label || '').trim() : null
  }

  function where(location) {
    return {
      cfi: location.start.cfi,
      href: location.start.href,
      // Jak czytnik Maca: koniec widocznej strony, więc ostatnia strona to 100%.
      progress: epub.locations.length() ? location.end.percentage : null,
      chapter: chapterTitle(location.start.href),
      atStart: !!location.atStart,
      atEnd: !!location.atEnd
    }
  }

  function size() {
    const box = document.getElementById('book')
    return { width: box.clientWidth, height: box.clientHeight }
  }

  const api = {
    open(options) {
      look = Object.assign(look, options.look || {})
      applyLayout(options.layout)
      applyLook()
      epub = ePub('abook://local/book.epub', { openAs: 'epub' })
      const box = size()
      rendition = epub.renderTo('book', {
        width: box.width,
        height: box.height,
        flow: 'paginated',
        spread: options.spread || 'none',
        allowScriptedContent: false
      })
      rendition.on('rendered', (section, view) => {
        applyLook()
        // Linki obsługuje Swift (ramka nie ma skryptów): bez `target` kliknięcie nawiguje ramkę,
        // a aplikacja tę nawigację przechwytuje i przekierowuje do `book.link`.
        const doc = view && view.contents && view.contents.document
        if (doc) doc.querySelectorAll('a[target]').forEach((a) => a.removeAttribute('target'))
      })
      rendition.on('relocated', (location) => {
        if (shown) send('moved', where(location))
      })
      const start = options.location && String(options.location).startsWith('epubcfi(') ? options.location : undefined
      rendition
        .display(start)
        .catch((error) => {
          send('log', { message: 'nie da się otworzyć zapisanego miejsca: ' + text(error) })
          return rendition.display()
        })
        .then(() => {
          // WebKit potrafi zostawić pustą stronę po starcie w środku rozdziału — ponowne
          // wyświetlenie tego samego miejsca po chwili ją rysuje.
          const location = rendition.currentLocation()
          if (start && location && location.start) {
            return new Promise((resolve) => setTimeout(resolve, 60)).then(() => rendition.display(location.start.cfi))
          }
        })
        .then(() => {
          shown = true
          api.report()
        })
        .catch((error) => send('error', { message: 'wyświetlenie: ' + text(error) }))

      epub.ready
        .then(() => {
          const meta = epub.package.metadata || {}
          send('opened', { title: meta.title || '', toc: contents(), rtl: meta.direction === 'rtl' })
          if (options.locations) {
            epub.locations.load(options.locations)
            send('locationsReady', {})
            api.report()
          } else {
            // Domyślny podział (jak na Macu), więc procent jest ten sam na obu urządzeniach.
            epub.locations.generate().then(() => {
              send('locations', { json: epub.locations.save() })
              send('locationsReady', {})
              api.report()
            })
          }
        })
        .catch((error) => send('error', { message: text(error) }))
    },
    report() {
      if (!shown || !rendition || !rendition.manager) return
      const location = rendition.currentLocation()
      if (location && location.start) send('moved', where(location))
    },
    next() {
      if (rendition && rendition.manager) return rendition.next()
    },
    prev() {
      if (rendition && rendition.manager) return rendition.prev()
    },
    // Pozycja ze spisu treści albo CFI.
    go(target) {
      if (!rendition || !rendition.manager) return
      if (String(target).startsWith('epubcfi(')) return rendition.display(target)
      const [path, hash] = String(target).split('#')
      const item = spineItemFor(decodeURIComponent(path))
      return rendition.display(item ? item.href + (hash ? '#' + hash : '') : target)
    },
    // Link wewnętrzny z treści (adres, pod który próbowała przejść ramka).
    link(url) {
      let path = url
      let hash = ''
      try {
        const parsed = new URL(url)
        path = decodeURIComponent(parsed.pathname)
        hash = parsed.hash
      } catch (e) {}
      const item = spineItemFor(path.replace(/^\/+/, ''))
      if (item) rendition.display(item.href + hash)
      else send('log', { message: 'link bez rozdziału: ' + url })
    },
    // Miejsce w książce z suwaka (0…1); wymaga lokacji.
    seek(fraction) {
      if (!rendition || !epub.locations.length()) return
      const cfi = epub.locations.cfiFromPercentage(Math.min(1, Math.max(0, fraction)))
      if (cfi) return rendition.display(cfi)
    },
    // Etap 11c: tekst od początku bieżącej strony (do dopasowania ze zdaniem mapy w Swifcie).
    here() {
      if (!shown || !rendition || !rendition.manager) return null
      const location = rendition.currentLocation()
      if (!location || !location.start) return null
      const range = rendition.getRange(location.start.cfi)
      if (!range) return null
      const doc = range.startContainer.ownerDocument
      const tail = doc.createRange()
      tail.setStart(range.startContainer, range.startOffset)
      tail.setEndAfter(doc.body.lastChild || doc.body)
      return { href: location.start.href, text: tail.toString().slice(0, 1200) }
    },
    // Etap 11c: odszukanie fragmentu (`key` — tekst bez odstępów, małymi literami) w rozdziale
    // i przejście do niego; `occurrence` — które wystąpienie. Zwraca CFI albo null.
    async find(href, key, occurrence) {
      if (!rendition || !rendition.manager) return null
      const item = spineItemFor(href)
      if (!item) return null
      const root = await item.load(epub.load.bind(epub))
      const doc = root.ownerDocument || root
      const body = doc.body || doc.querySelector('body') || root
      const walker = doc.createTreeWalker(body, NodeFilter.SHOW_TEXT)
      const chars = []
      const where = []
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const value = node.nodeValue
        for (let i = 0; i < value.length; i++) {
          const c = value[i]
          if (/\s/.test(c) || c === '\u00AD' || c === '\u200B') continue
          const lower = c.toLowerCase()
          for (const l of lower) {
            chars.push(l)
            where.push([node, i])
          }
        }
      }
      const text = chars.join('')
      let at = -1
      for (let n = 0; n <= occurrence; n++) {
        at = text.indexOf(key, at + 1)
        if (at < 0) break
      }
      if (at < 0) at = text.indexOf(key)
      if (at < 0) return null
      const range = doc.createRange()
      // Zakres z pierwszym znakiem, nie zwinięty: zwinięty zakres na początku akapitu WebKit
      // mierzy na końcu poprzedniej linii, więc epub.js pokazywał stronę wcześniej.
      const [node, offset] = where[at]
      range.setStart(node, offset)
      range.setEnd(node, Math.min(node.nodeValue.length, offset + 1))
      const cfi = item.cfiFromRange(range)
      item.unload()
      await rendition.display(cfi)
      // epub.js potrafi pokazać stronę przed celem (prostokąty zakresów WebKit w tekście
      // łamanym na kolumny bywają przesunięte, a z nich epub.js liczy położenie i koniec strony).
      // Pewny jest tylko początek widocznej strony, więc: cel przed początkiem → kartka wstecz;
      // inaczej kartka dalej, dopóki następna strona nie zaczyna się za celem (wtedy wracamy).
      const order = new ePub.CFI()
      const start = () => {
        const location = rendition.currentLocation()
        return location && location.start ? location.start.cfi : null
      }
      for (let i = 0; i < 3; i++) {
        const here = start()
        if (!here) break
        if (order.compare(cfi, here) < 0) {
          await rendition.prev()
          continue
        }
        await rendition.next()
        const next = start()
        if (!next || next === here) break
        if (order.compare(next, cfi) > 0) {
          await rendition.prev()
          break
        }
      }
      repaint()
      return cfi
    },
    setLook(next) {
      look = Object.assign(look, next || {})
      applyLook()
    },
    setLayout(layout) {
      applyLayout(layout)
      api.resize()
    },
    setSpread(spread) {
      if (rendition) rendition.spread(spread || 'none')
    },
    resize() {
      const box = size()
      if (rendition && rendition.manager && box.width > 0 && box.height > 0) rendition.resize(box.width, box.height)
    }
  }

  // WebKit nie zawsze odmalowuje ramkę rozdziału po przewinięciu kontenera w kodzie (ekran
  // zostaje na poprzedniej stronie, choć DOM jest już na nowej) — zmiana krycia w następnej
  // klatce wymusza odmalowanie.
  function repaint() {
    const box = document.getElementById('book')
    box.style.opacity = '0.99'
    requestAnimationFrame(() => requestAnimationFrame(() => { box.style.opacity = '' }))
  }

  // Marginesy strony (boczne) i miejsce na paski aplikacji (górny i dolny), w punktach.
  function applyLayout(layout) {
    if (!layout) return
    const root = document.documentElement.style
    root.setProperty('--side', `${layout.side || 20}px`)
    root.setProperty('--top', `${layout.top || 0}px`)
    root.setProperty('--bottom', `${layout.bottom || 0}px`)
  }

  let resizeTimer = null
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer)
    resizeTimer = setTimeout(() => api.resize(), 120)
  })

  window.book = api
  send('ready', {})
})()
