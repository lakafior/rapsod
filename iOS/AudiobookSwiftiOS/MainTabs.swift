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
                    PodcastsPlaceholder()
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
        }
        .sheet(isPresented: $showsPlayer) {
            PlayerScreen(model: model)
        }
        // Biblioteki, postęp i gniazdo zdarzeń żyją tyle, co to połączenie.
        .task(id: session.id) { await session.library.run() }
    }
}

/// Zakładka „Podcasty” do czasu etapu 10e.
private struct PodcastsPlaceholder: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Podcasty wkrótce", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("Wszystkie biblioteki podcastów w jednej zakładce dojdą w następnej wersji aplikacji."))
                .navigationTitle("Podcasty")
        }
    }
}
