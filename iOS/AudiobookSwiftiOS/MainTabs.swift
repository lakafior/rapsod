// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AudiobookshelfKit

/// Układ po sparowaniu: zakładki Start, Audiobooki, Podcasty, Szukaj i Ustawienia, a nad paskiem
/// zakładek mini-odtwarzacz w systemowym miejscu na akcesorium (`tabViewBottomAccessory`).
/// Na iPadzie pasek zakładek może się zamienić w pasek boczny (`sidebarAdaptable`).
struct MainTabs: View {
    let model: AppModel
    let session: ServerSession

    enum AppTab: Hashable {
        case home, books, podcasts, settings, search
    }

    @State private var tab: AppTab = .home
    @State private var showsPlayer = false
    #if DEBUG
    /// Tylko Debug: `-OpenReader <id pozycji>` otwiera czytnik od razu (testy w symulatorze).
    @State private var debugReader: ReaderTarget? = UserDefaults.standard.string(forKey: "OpenReader").flatMap { $0.isEmpty ? nil : $0 }.map { ReaderTarget(itemID: $0, title: "") }
    #endif
    @Namespace private var playerTransition

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "house", value: AppTab.home) {
                HomeView(model: model, session: session)
            }
            Tab("Audiobooki", systemImage: "books.vertical", value: AppTab.books) {
                BooksTab(model: model, session: session)
            }
            // Bez bibliotek podcastów zakładka nie ma sensu — znika.
            if session.library.combined?.podcastLibraries.isEmpty == false {
                Tab("Podcasty", systemImage: "dot.radiowaves.left.and.right", value: AppTab.podcasts) {
                    PodcastsTab(model: model, session: session)
                }
            }
            Tab("Ustawienia", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(model: model, session: session)
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView(model: model, session: session)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Przewijanie w dół zwija pasek zakładek; mini-odtwarzacz przechodzi wtedy do niego (`inline`).
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: model.playback.player.book != nil) {
            // Wysokość akcesorium ustala system — największe rozmiary tekstu by się w nim nie zmieściły.
            MiniPlayerBar(model: model, showsPlayer: $showsPlayer)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .matchedTransitionSource(id: "player", in: playerTransition)
        }
        // Pełny ekran wyrasta z mini-odtwarzacza i wraca do niego (także gestem w dół).
        .fullScreenCover(isPresented: $showsPlayer) {
            PlayerScreen(model: model)
                .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
        }
        // Biblioteki, postęp i gniazdo zdarzeń żyją tyle, co to połączenie.
        #if DEBUG
        .fullScreenCover(item: $debugReader) { target in
            ReaderScreen(target: target, session: session, playback: model.playback, isOffline: model.isOffline)
        }
        #endif
        .task(id: session.id) { await session.library.run() }
    }
}
