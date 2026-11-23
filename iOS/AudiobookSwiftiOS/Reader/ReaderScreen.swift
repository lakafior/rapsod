// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 10g).

import SwiftUI
import PDFKit
import OSLog
import AudiobookshelfKit
import AudiobookshelfPlayback

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "Reader")

/// Co otworzyć w czytniku.
struct ReaderTarget: Identifiable, Hashable {
    let itemID: String
    let title: String
    var id: String { itemID }
}

/// Miejsca czytania na telefonie — jeden plik na serwer, wspólny dla wszystkich otwarć czytnika.
@MainActor
enum ReaderPositions {
    private static var stores: [String: EbookPositionStore] = [:]

    static func store(scope: String) -> EbookPositionStore {
        if let store = stores[scope] { return store }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appending(path: "EbookPositions").appending(path: DownloadedItem.folderName(for: scope) + ".json")
        let store = EbookPositionStore(url: url)
        stores[scope] = store
        return store
    }
}

/// Wczytanie e-booka (pobrany z książką → pamięć podręczna → serwer), miejsce startu i zapis pozycji.
@MainActor @Observable
final class ReaderModel {
    enum Content {
        case epub(EpubController)
        case pdf(PDFDocument)
    }
    enum Phase {
        case loading
        case ready(Content)
        case failed(String)
    }

    let target: ReaderTarget
    private(set) var phase: Phase = .loading
    private(set) var title: String
    /// PDF: bieżąca strona (od 1) i liczba stron.
    var pdfPage = 1
    private(set) var pdfCount = 0
    private(set) var saveError: String?

    /// Mapa tekstu książki z nagraniem (etap 11c) — „Słuchaj od tego miejsca” i odwrotnie.
    private(set) var textMap: TextSyncMap?
    /// Uwaga o mapie (nieaktualna po zmianie plików).
    private(set) var textMapNote: String?
    /// Propozycja przy otwarciu: słuchanie jest gdzie indziej niż czytanie (czas w nagraniu).
    var listeningSuggestion: Double?

    @ObservationIgnored private let session: ServerSession
    @ObservationIgnored private let playback: PlaybackCoordinator
    @ObservationIgnored private let isOffline: Bool
    @ObservationIgnored private var checkedSuggestion = false
    /// Pierwsze miejsce zgłoszone po otwarciu (to zapisane) — samo otwarcie niczego nie zapisuje.
    @ObservationIgnored private var openedCFI: String?
    @ObservationIgnored private var hasMoved = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var positions: EbookPositionStore { ReaderPositions.store(scope: session.scope) }

    init(target: ReaderTarget, session: ServerSession, playback: PlaybackCoordinator, isOffline: Bool) {
        self.target = target
        self.session = session
        self.playback = playback
        self.isOffline = isOffline
        title = target.title
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    func load(look: [String: Any], layout: [String: Any], spread: String) async {
        do {
            let (file, format, cacheKey) = try await ebookFile()
            let saved = await savedLocation()
            switch format {
            case .epub:
                let controller = EpubController(book: file, cacheKey: cacheKey, startLocation: EbookLocationValue.epubCFI(saved), look: look, layout: layout, spread: spread)
                controller.onMove = { [weak self] place in
                    guard let self else { return }
                    if openedCFI == nil {
                        openedCFI = place.cfi
                    } else if hasMoved || place.cfi != openedCFI {
                        hasMoved = true
                        record(location: place.cfi, progress: place.progress)
                    }
                    Task { await self.suggestListeningPlace(controller) }
                }
                phase = .ready(.epub(controller))
                Task {
                    await loadTextMap()
                    await suggestListeningPlace(controller)
                }
            case .pdf:
                guard let document = PDFDocument(url: file) else { throw Failure(errorDescription: "Nie udało się otworzyć tego PDF-a.") }
                pdfCount = document.pageCount
                pdfPage = min(max(1, EbookLocationValue.pdfPage(saved) ?? 1), max(1, document.pageCount))
                phase = .ready(.pdf(document))
            case .unsupported:
                throw Failure(errorDescription: format.unsupportedMessage)
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? LibraryStore.message(error))
        }
        // Zaległe zapisy z czytania bez sieci.
        if !isOffline { Task { await flushUnsent() } }
    }

    /// Plik e-booka na telefonie: pobrany z książką, z pamięci podręcznej albo pobrany teraz z serwera.
    private func ebookFile() async throws -> (URL, EbookFormat, String) {
        let downloads = session.downloads.manager
        let item: AudiobookshelfClient.ItemDetail?
        if isOffline {
            item = nil
        } else {
            do {
                item = try await session.auth.perform { try await $0.item(id: target.itemID, token: $1) }
            } catch {
                // Bez połączenia zostaje to, co jest na telefonie.
                guard let local = downloads.ebookURL(itemID: target.itemID) ?? EbookFileCache.standard().latest(itemID: target.itemID) else { throw error }
                return (local, EbookFormat(format: nil, filename: local.lastPathComponent), "\(target.itemID)-local")
            }
        }
        guard let item else {
            if let downloaded = downloads.item(itemID: target.itemID, episodeID: nil) { title = downloaded.title }
            guard let local = downloads.ebookURL(itemID: target.itemID) ?? EbookFileCache.standard().latest(itemID: target.itemID) else {
                throw Failure(errorDescription: "E-booka tej książki nie ma na telefonie. Połącz się z serwerem, żeby go otworzyć.")
            }
            return (local, EbookFormat(format: nil, filename: local.lastPathComponent), "\(target.itemID)-local")
        }
        title = item.title
        guard let ebook = item.media.ebookFile, let ino = ebook.ino else { throw Failure(errorDescription: "Ta książka nie ma e-booka.") }
        let format = EbookFormat(format: ebook.ebookFormat, filename: ebook.metadata?.filename)
        guard let ext = format.fileExtension else { return (URL(filePath: "/"), format, "") }
        let key = EbookFileCache.key(ino: ino, size: ebook.metadata?.size, mtimeMs: libraryFileTime(item, ino: ino))
        let cacheKey = "\(target.itemID)-\(key)"
        // Pobrana książka: e-book obok audio (o ile to ten sam rozmiar co na serwerze).
        if let local = downloads.ebookURL(itemID: target.itemID), local.pathExtension == ext,
           ebook.metadata?.size.map({ Int64($0) == (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }) ?? true {
            return (local, format, cacheKey)
        }
        let cache = EbookFileCache.standard()
        if let cached = cache.file(itemID: target.itemID, key: key, ext: ext) {
            return (cached, format, cacheKey)
        }
        let data = try await session.auth.perform { try await $0.libraryFile(itemID: item.id, ino: ino, token: $1) }
        if downloads.item(itemID: target.itemID, episodeID: nil) != nil {
            // Książka pobrana przed etapem 10g (albo e-book się zmienił) — dopisujemy go do pobranych.
            downloads.storeEbook(data, ext: ext, itemID: target.itemID)
            if let local = downloads.ebookURL(itemID: target.itemID) { return (local, format, cacheKey) }
        }
        guard let stored = cache.store(data, itemID: target.itemID, key: key, ext: ext) else {
            throw Failure(errorDescription: "Brak miejsca na telefonie na plik e-booka.")
        }
        return (stored, format, cacheKey)
    }

    private func libraryFileTime(_ item: AudiobookshelfClient.ItemDetail, ino: String) -> Double? {
        item.libraryFiles?.elements.first { $0.ino == ino }?.metadata.mtimeMs
    }

    /// Miejsce z serwera (świeże, gdy jest sieć) albo z telefonu — według `EbookPositionStore`.
    private func savedLocation() async -> String? {
        var server: String?
        var reachable = false
        do {
            guard !isOffline else { throw URLError(.notConnectedToInternet) }
            let progress = try await session.auth.perform { try await $0.progress(itemID: target.itemID, episodeID: nil, token: $1) }
            server = progress?.ebookLocation?.value
            reachable = true
        } catch {
            server = session.library.progress.value(target.itemID)?.ebookLocation?.value
        }
        return positions.startLocation(itemID: target.itemID, server: server, serverReachable: reachable)
    }

    // MARK: - Tekst i nagranie (etap 11c)

    /// Mapa tekstu tak jak w trybie „Tekst” odtwarzacza: pobrana z książką albo z serwera.
    private func loadTextMap() async {
        let itemID = target.itemID
        let auth = session.auth
        let downloads = session.downloads.manager
        let source = TextSyncSource(
            itemID: itemID,
            fetchItem: { try await auth.perform { try await $0.item(id: itemID, token: $1) } },
            fetchFile: { ino in try await auth.perform { try await $0.libraryFile(itemID: itemID, ino: ino, token: $1) } },
            downloadedCopy: { downloads.textSyncData(itemID: itemID) },
            updateDownloadedCopy: { downloads.storeTextSync($0, itemID: itemID) }
        )
        if case .ready(let document, let isStale, _) = await TextSyncLoader.load(source, cache: .standard()) {
            textMap = document.map
            textMapNote = isStale ? "Pliki książki zmieniły się od synchronizacji — przejścia między tekstem a nagraniem mogą chybiać. Zsynchronizuj e-book na Macu jeszcze raz." : nil
        }
    }

    /// Miejsce słuchania: bieżące odtwarzanie tej książki albo zapisana pozycja.
    func listeningTime() -> Double? {
        if playback.nowPlayingKey == PlaybackTimeline.key(target.itemID, nil) { return playback.player.currentTime }
        // Jak przy wznawianiu odtwarzania: nowszy zapis (telefon albo serwer), nie dalszy.
        let local = session.journal.position(itemID: target.itemID, episodeID: nil)
        let server: ServerProgressLookup = session.library.progress.value(target.itemID).map { .some($0) } ?? .unreachable
        return ProgressMerge.start(local: local, server: server).flatMap { $0.time > 0 ? $0.time : nil }
    }

    static let mismatch = "Tej strony nie ma w mapie tekstu (inne wydanie e-booka albo fragment, którego lektor nie czyta). Zsynchronizuj e-book na Macu jeszcze raz albo spróbuj na innej stronie."

    /// „Słuchaj od tego miejsca”: początek zdania na górze strony → odtwarzanie od tego czasu.
    func listenHere(_ controller: EpubController) async -> String {
        guard let map = textMap, let page = await controller.pageText() else { return Self.mismatch }
        guard let time = EbookAudioSync.time(in: map, href: page.href, passage: page.text) else { return Self.mismatch }
        await playback.play(itemID: target.itemID, from: time)
        listeningSuggestion = nil
        return "Odtwarzanie od \(Self.clock(time))"
    }

    /// „Czytaj od miejsca, gdzie skończyłem słuchać”: zdanie z chwili słuchania → jego strona.
    func readFromListening(_ controller: EpubController, time: Double? = nil) async -> String? {
        guard let map = textMap, let time = time ?? listeningTime() else { return "Nie ma jeszcze miejsca słuchania tej książki." }
        guard let passage = EbookAudioSync.passage(in: map, time: time), await controller.show(passage) else { return Self.mismatch }
        listeningSuggestion = nil
        return nil
    }

    /// Przy otwarciu: jeśli słuchanie poszło dalej (albo zostało w tyle) niż czytanie o ponad
    /// minutę nagrania — propozycja przejścia. Raz na otwarcie.
    private func suggestListeningPlace(_ controller: EpubController) async {
        guard !checkedSuggestion, let map = textMap, let listening = listeningTime(),
              let page = await controller.pageText(), !checkedSuggestion else { return }
        checkedSuggestion = true
        guard let reading = EbookAudioSync.time(in: map, href: page.href, passage: page.text) else { return }
        if abs(reading - listening) > 60 { listeningSuggestion = listening }
    }

    static func clock(_ time: Double) -> String {
        Duration.seconds(max(0, time)).formatted(.time(pattern: time >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    // MARK: - Zapis pozycji

    func pdfPageChanged(_ page: Int) {
        guard page != pdfPage else { return }
        pdfPage = page
        record(location: String(page), progress: EbookLocationValue.pdfProgress(page: page, count: pdfCount))
    }

    /// Zapis na telefonie od razu, na serwer po sekundzie spokoju (przewracanie kartek nie wysyła
    /// żądania przy każdej stronie).
    private func record(location: String, progress: Double?) {
        positions.update(itemID: target.itemID, location: location, progress: progress)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    private func send() async {
        guard let record = positions.record(itemID: target.itemID), !record.sent else { return }
        do {
            try await session.auth.perform { try await $0.updateEbookProgress(itemID: self.target.itemID, location: record.location, progress: record.progress, token: $1) }
            positions.markSent(itemID: target.itemID, location: record.location)
            saveError = nil
        } catch is CancellationError {
        } catch {
            // Zostaje na telefonie i pójdzie przy następnym otwarciu czytnika.
            logger.info("Postęp czytania czeka na sieć: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func flushUnsent() async {
        for (itemID, record) in positions.unsent where itemID != target.itemID {
            guard (try? await session.auth.perform({ try await $0.updateEbookProgress(itemID: itemID, location: record.location, progress: record.progress, token: $1) })) != nil else { return }
            positions.markSent(itemID: itemID, location: record.location)
        }
    }

    func close() {
        saveTask?.cancel()
        Task { await send() }
    }
}

/// Czytnik na pełnym ekranie: EPUB (epub.js) albo PDF (PDFKit), paski chowane dotknięciem środka.
struct ReaderScreen: View {
    let target: ReaderTarget
    let session: ServerSession
    let playback: PlaybackCoordinator
    let isOffline: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model: ReaderModel?
    @State private var look = ReaderLook.load()
    @State private var showsChrome = true
    @State private var showsContents = false
    @State private var showsSettings = false
    @State private var sliderValue: Double?
    @State private var notice: String?

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .task {
                    guard model == nil else { return }
                    let model = ReaderModel(target: target, session: session, playback: playback, isOffline: isOffline)
                    self.model = model
                    await model.load(look: look.javaScript(dynamicType: contentSize), layout: layout, spread: spread(width: geometry.size.width))
                }
                .onChange(of: geometry.size) { _, size in
                    epub?.setSpread(spread(width: size.width))
                    // Zdarzenie `resize` strony potrafi przyjść, zanim WKWebView dostanie nowy rozmiar
                    // (obrót) — wtedy epub.js łamie tekst na starą szerokość. Drugie wywołanie po chwili.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        epub?.call("book.resize()")
                    }
                }
        }
        .background(isPDF ? Color(.systemBackground) : look.theme.page)
        // Motyw tylko w czytniku (`preferredColorScheme` przełączałby całą aplikację pod spodem).
        .environment(\.colorScheme, isPDF ? systemScheme : look.theme.colorScheme)
        .statusBarHidden(!showsChrome)
        .onChange(of: look) { _, look in
            look.save()
            epub?.setLook(look.javaScript(dynamicType: contentSize))
            epub?.setLayout(layout)
        }
        .onChange(of: dynamicTypeSize) { _, _ in epub?.setLook(look.javaScript(dynamicType: contentSize)) }
        .onChange(of: verticalSizeClass) { _, _ in epub?.setLayout(layout) }
        .onDisappear { model?.close() }
        .sheet(isPresented: $showsContents) {
            if let epub { ReaderContents(controller: epub) }
        }
        .sheet(isPresented: $showsSettings) {
            ReaderSettings(look: $look)
                .presentationDetents([.medium, .large])
        }
    }

    private var contentSize: UIContentSizeCategory { UIContentSizeCategory(dynamicTypeSize) }
    /// Miejsce na paski (górny i dolny), żeby pokazane nie zasłaniały tekstu.
    private var layout: [String: Any] {
        // iPhone w poziomie: paski są niższe, a każdy wiersz tekstu się liczy.
        verticalSizeClass == .compact
            ? ["side": look.margins.points, "top": 44, "bottom": 44]
            : ["side": look.margins.points, "top": 60, "bottom": 64]
    }
    private func spread(width: CGFloat) -> String { width > 900 ? "auto" : "none" }

    private var epub: EpubController? {
        if case .ready(.epub(let controller)) = model?.phase { return controller }
        return nil
    }

    private var isPDF: Bool {
        if case .ready(.pdf) = model?.phase { return true }
        return false
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch model?.phase ?? .loading {
        case .loading:
            ProgressView("Otwieranie e-booka…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { closeButton.padding() }
        case .failed(let message):
            ContentUnavailableView {
                Label("Nie można otworzyć e-booka", systemImage: "book.closed")
            } description: {
                Text(message)
            } actions: {
                Button("Zamknij") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case .ready(.epub(let controller)):
            epubView(controller)
        case .ready(.pdf(let document)):
            if let model { pdfView(document, model: model) }
        }
    }

    private var closeButton: some View {
        Button("Zamknij", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
    }

    // MARK: - EPUB

    private func epubView(_ controller: EpubController) -> some View {
        EpubPageView(controller: controller) { toggleChrome() }
            .overlay {
                if let failure = controller.failure {
                    ContentUnavailableView("Nie można otworzyć e-booka", systemImage: "book.closed", description: Text(failure))
                        .background(look.theme.page)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if showsChrome { topBar(controller).transition(.opacity) }
                    if let model, let time = model.listeningSuggestion { suggestion(controller, model: model, time: time) }
                    if let notice {
                        Text(notice)
                            .font(.callout)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 14))
                            .padding(.horizontal)
                            .transition(.opacity)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showsChrome {
                    bottomBar(controller).transition(.opacity)
                } else if let progress = controller.place?.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(look.theme.ink.opacity(0.6))
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Następna strona") { controller.next() }
            .accessibilityAction(named: "Poprzednia strona") { controller.previous() }
            .accessibilityAction(named: showsChrome ? "Ukryj paski" : "Pokaż paski") { toggleChrome() }
            .accessibilityScrollAction { edge in
                switch edge {
                case .trailing, .bottom: controller.next()
                default: controller.previous()
                }
            }
    }

    // MARK: - Tekst i nagranie (etap 11c)

    private func listeningMenu(_ controller: EpubController, model: ReaderModel) -> some View {
        Menu {
            Button("Słuchaj od tego miejsca", systemImage: "play") {
                Task { show(await model.listenHere(controller)) }
            }
            Button("Czytaj od miejsca słuchania", systemImage: "headphones") {
                Task { if let message = await model.readFromListening(controller) { show(message) } }
            }
            .disabled(model.listeningTime() == nil)
            if let note = model.textMapNote { Text(note) }
        } label: {
            Label("Tekst i nagranie", systemImage: "headphones")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }

    private func suggestion(_ controller: EpubController, model: ReaderModel, time: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones").accessibilityHidden(true)
            Text("Słuchanie jest w innym miejscu (\(ReaderModel.clock(time))).").font(.callout)
            Spacer(minLength: 0)
            Button("Przejdź") {
                Task { if let message = await model.readFromListening(controller, time: time) { show(message) } }
            }
            .buttonStyle(.borderedProminent)
            Button("Zostań", systemImage: "xmark") { model.listeningSuggestion = nil }
                .labelStyle(.iconOnly)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func show(_ message: String) {
        withAnimation(reduceMotion ? nil : .default) { notice = message }
        UIAccessibility.post(notification: .announcement, argument: message)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == message { withAnimation(reduceMotion ? nil : .default) { notice = nil } }
        }
    }

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsChrome.toggle() }
    }

    private func topBar(_ controller: EpubController) -> some View {
        HStack(spacing: 12) {
            closeButton
            VStack(spacing: 1) {
                Text(model?.title ?? target.title).font(.headline).lineLimit(1)
                if let chapter = controller.place?.chapter, !chapter.isEmpty {
                    Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            Button("Spis treści", systemImage: "list.bullet") { showsContents = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(controller.toc.isEmpty)
            if let model, model.textMap != nil { listeningMenu(controller, model: model) }
            Button("Wygląd", systemImage: "textformat.size") { showsSettings = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func bottomBar(_ controller: EpubController) -> some View {
        VStack(spacing: 4) {
            if controller.hasLocations, let progress = controller.place?.progress {
                Slider(value: Binding(get: { sliderValue ?? progress }, set: { sliderValue = $0 }), in: 0...1) { editing in
                    if !editing, let value = sliderValue {
                        controller.seek(value)
                        sliderValue = nil
                    }
                }
                .accessibilityLabel("Miejsce w książce")
                .accessibilityValue(Text((sliderValue ?? progress), format: .percent.precision(.fractionLength(0))))
                Text(sliderValue ?? progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Text("Liczenie stron…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    // MARK: - PDF

    private func pdfView(_ document: PDFDocument, model: ReaderModel) -> some View {
        PDFPageView(document: document, page: model.pdfPage) { model.pdfPageChanged($0) }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) {
                HStack {
                    closeButton
                    Text(model.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                    Text("\(model.pdfPage) / \(model.pdfCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Strona \(model.pdfPage) z \(model.pdfCount)")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
    }
}

/// Spis treści EPUB-a.
private struct ReaderContents: View {
    let controller: EpubController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(controller.toc) { item in
                Button {
                    controller.go(item)
                    dismiss()
                } label: {
                    Text(item.label.isEmpty ? "Bez tytułu" : item.label)
                        .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                        .foregroundStyle(.primary)
                }
                .accessibilityAddTraits(isCurrent(item) ? .isSelected : [])
            }
            .navigationTitle("Spis treści")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } }
            }
        }
    }

    private func isCurrent(_ item: ReaderTocItem) -> Bool {
        guard let href = controller.place?.href else { return false }
        let path = item.href.split(separator: "#").first.map(String.init) ?? item.href
        return path.hasSuffix(href) || href.hasSuffix(path)
    }
}

/// Krój, rozmiar, marginesy i motyw.
private struct ReaderSettings: View {
    @Binding var look: ReaderLook
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("Motyw") {
                    Picker("Motyw", selection: $look.theme) {
                        ForEach(ReaderLook.Theme.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Krój", selection: $look.font) {
                        ForEach(ReaderLook.Font.allCases) { Text($0.name).tag($0) }
                    }
                    Stepper(value: $look.sizeStep, in: ReaderLook.sizeSteps) {
                        LabeledContent("Rozmiar", value: "\(look.fontPercent(dynamicType: UIContentSizeCategory(dynamicTypeSize)))%")
                    }
                    Picker("Marginesy", selection: $look.margins) {
                        ForEach(ReaderLook.Margins.allCases) { Text($0.name).tag($0) }
                    }
                } header: {
                    Text("Tekst")
                } footer: {
                    Text("Rozmiar wychodzi od wielkości tekstu ustawionej w systemie (Dynamic Type).")
                }
            }
            .navigationTitle("Wygląd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } }
            }
        }
    }
}

/// PDF w PDFKit: strony jedna pod drugą, zmiana strony zgłaszana do zapisu.
private struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let page: Int
    let onPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        context.coordinator.observe(view)
        // Przejście do zapisanej strony dopiero po pierwszym układzie (wcześniej PDFView je
        // ignoruje); do tego czasu zmiany strony nie są zapisywane — inaczej strona 1
        // nadpisałaby pozycję z serwera.
        let start = document.page(at: page - 1)
        DispatchQueue.main.async {
            view.layoutIfNeeded()
            if let start { view.go(to: start) }
            context.coordinator.isReady = true
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPage = onPage
    }

    @MainActor final class Coordinator: NSObject {
        var onPage: (Int) -> Void
        var isReady = false

        init(onPage: @escaping (Int) -> Void) { self.onPage = onPage }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard isReady, let view = notification.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            onPage(document.index(for: page) + 1)
        }
    }
}
