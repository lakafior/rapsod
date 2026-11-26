// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import RapsodIntegration

/// Spotlight (etap 14f): identyfikatory z zakresem folderu danych i plan zmian indeksu.
@Suite struct SpotlightPlanTests {
    @Test func identifierRoundTrips() {
        let book = SpotlightKey(scope: "abc123", kind: .book, itemID: "li_1")
        #expect(book.uniqueIdentifier == "rapsod:abc123:book:li_1")
        #expect(SpotlightKey(uniqueIdentifier: book.uniqueIdentifier) == book)
        let episode = SpotlightKey(scope: "abc123", kind: .episode, itemID: "li_2", episodeID: "ep_9")
        #expect(SpotlightKey(uniqueIdentifier: episode.uniqueIdentifier) == episode)
    }

    @Test func rejectsForeignIdentifiers() {
        #expect(SpotlightKey(uniqueIdentifier: "com.other:1") == nil)
        #expect(SpotlightKey(uniqueIdentifier: "rapsod::book:li_1") == nil)
        #expect(SpotlightKey(uniqueIdentifier: "rapsod:s:episode:li_1") == nil)
        #expect(SpotlightKey(uniqueIdentifier: "rapsod:s:book:li_1:extra") == nil)
        #expect(SpotlightKey(uniqueIdentifier: "rapsod:s:film:li_1") == nil)
    }

    @Test func scopeIsStableAndSeparatesDataRoots() {
        let real = SpotlightKey.scope(dataRoot: "/Users/a/Library/Application Support/Rapsod")
        #expect(real == SpotlightKey.scope(dataRoot: "/Users/a/Library/Application Support/Rapsod/"))
        #expect(real != SpotlightKey.scope(dataRoot: "/tmp/abs14c/data"))
        #expect(!real.contains(".") && !real.contains(":") && real.count == 12)
    }

    @Test func libraryDomainIsInsideScopeDomain() {
        let scope = SpotlightKey.domain(scope: "s1")
        let library = SpotlightKey.domain(scope: "s1", libraryID: "lib.a")
        #expect(library.hasPrefix(scope + "."))
        #expect(library == "net.smigi.rapsod.spotlight.s1.lib_a")
    }

    @Test func firstSyncIndexesEverything() {
        let current = [source("a", "L1", 10), source("b", "L1", 20)]
        let changes = SpotlightPlan.changes(manifest: .init(), current: current, listed: ["L1"], libraries: ["L1"])
        #expect(changes.toIndex.map(\.itemID) == ["a", "b"])
        #expect(changes.removedItems.isEmpty && changes.removedLibraries.isEmpty)
    }

    @Test func onlyChangedAndRemovedItemsLater() {
        let manifest = SpotlightManifest(items: [
            "a": .init(libraryID: "L1", kind: .book, updatedAt: 10),
            "b": .init(libraryID: "L1", kind: .book, updatedAt: 20),
            "c": .init(libraryID: "L1", kind: .book, updatedAt: 30),
        ])
        let current = [source("a", "L1", 10), source("b", "L1", 25), source("d", "L1", 5)]
        let changes = SpotlightPlan.changes(manifest: manifest, current: current, listed: ["L1"], libraries: ["L1"])
        #expect(changes.toIndex.map(\.itemID) == ["b", "d"])
        #expect(Set(changes.removedItems.keys) == ["c"])
    }

    @Test func unlistedLibrariesAreLeftAlone() {
        let manifest = SpotlightManifest(items: [
            "a": .init(libraryID: "L1", kind: .book, updatedAt: 10),
            "p": .init(libraryID: "L2", kind: .podcast, updatedAt: 10, episodes: ["e1"]),
        ])
        let changes = SpotlightPlan.changes(manifest: manifest, current: [source("a", "L1", 10)], listed: ["L1"], libraries: ["L1", "L2"])
        #expect(changes.isEmpty)
    }

    @Test func removedLibraryDropsWholeDomain() {
        let manifest = SpotlightManifest(items: [
            "a": .init(libraryID: "L1", kind: .book, updatedAt: 10),
            "p": .init(libraryID: "L2", kind: .podcast, updatedAt: 10),
        ])
        let changes = SpotlightPlan.changes(manifest: manifest, current: [source("a", "L1", 10)], listed: ["L1"], libraries: ["L1"])
        #expect(changes.removedLibraries == ["L2"])
        #expect(changes.removedItems.isEmpty)
    }

    @Test func movedItemIsReindexedUnderNewLibrary() {
        let manifest = SpotlightManifest(items: ["a": .init(libraryID: "L1", kind: .book, updatedAt: 10)])
        let changes = SpotlightPlan.changes(manifest: manifest, current: [source("a", "L2", 10)], listed: ["L2"], libraries: ["L1", "L2"])
        #expect(changes.toIndex.map(\.itemID) == ["a"])
        #expect(changes.removedItems["a"]?.libraryID == "L1")
    }

    @Test func episodesAndBatches() {
        #expect(SpotlightPlan.removedEpisodes(old: ["1", "2", "3"], new: ["2", "4"]) == ["1", "3"])
        #expect(SpotlightPlan.batches(Array(1...5), size: 2) == [[1, 2], [3, 4], [5]])
        #expect(SpotlightPlan.batches([Int](), size: 3).isEmpty)
    }

    @Test func keywordsSplitAndDeduplicate() {
        #expect(SpotlightPlan.keywords(["Bolesław Prus, Jan Nowak"], ["Jan Nowak", nil, ""], ["Saga #1"]) == ["Bolesław Prus", "Jan Nowak", "Saga #1"])
    }

    private func source(_ id: String, _ library: String, _ updated: Double) -> SpotlightSource {
        SpotlightSource(itemID: id, libraryID: library, kind: .book, updatedAt: updated)
    }
}
