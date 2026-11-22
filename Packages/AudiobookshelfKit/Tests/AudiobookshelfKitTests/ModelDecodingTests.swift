// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
import AudiobookshelfKit

/// Dekodowanie modeli z przykładowych odpowiedzi serwera (kształty z upstreamu v2.38.0).
struct ModelDecodingTests {
    private let decoder = JSONDecoder()

    @Test func statusAndLibrary() throws {
        let status = try decoder.decode(AudiobookshelfClient.Status.self, from: Data(#"{"serverVersion":"2.38.0","isInit":true,"language":"pl"}"#.utf8))
        #expect(status.serverVersion == "2.38.0")
        #expect(status.isInit)

        let library = try decoder.decode(AudiobookshelfClient.Library.self, from: Data(#"""
        {"id":"lib1","name":"Audiobooki","mediaType":"book","provider":"audible",
         "folders":[{"id":"f1","fullPath":"/Users/x/Audiobooki","libraryId":"lib1"}],"icon":"database"}
        """#.utf8))
        #expect(library.name == "Audiobooki")
        #expect(library.folders.map(\.fullPath) == ["/Users/x/Audiobooki"])
        #expect(library.provider == "audible")
    }

    @Test func itemsPageSkipsBrokenEntries() throws {
        let json = #"""
        {"results":[
          {"id":"li1","libraryId":"lib1","mediaType":"book","addedAt":1700000000000,
           "media":{"metadata":{"title":"Solaris","authorName":"Stanisław Lem","seriesName":"Brak #1"},
                    "coverPath":"/covers/1.jpg","duration":3600.5,"numTracks":3,"ebookFormat":"epub","size":1000}},
          {"id":"zepsuta"},
          {"id":"li2","libraryId":"lib1","mediaType":"podcast",
           "media":{"metadata":{"title":null,"author":"Radio"},"numEpisodes":12}}
        ],"total":3,"limit":2,"page":0}
        """#
        let page = try decoder.decode(AudiobookshelfClient.Page<AudiobookshelfClient.LibraryItem>.self, from: Data(json.utf8))
        let items = page.results.elements
        #expect(page.total == 3)
        #expect(items.map(\.id) == ["li1", "li2"])
        #expect(items[0].title == "Solaris")
        #expect(items[0].author == "Stanisław Lem")
        #expect(items[0].media.ebookFormat == "epub")
        #expect(items[1].title == "Bez tytułu")
        #expect(items[1].author == "Radio")
        #expect(items[1].isPodcast)
    }

    @Test func mediaProgressAndServerTask() throws {
        let progress = try decoder.decode(AudiobookshelfClient.MediaProgress.self, from: Data(#"""
        {"id":"p1","libraryItemId":"li1","episodeId":null,"duration":100,"progress":0.25,"currentTime":25,
         "isFinished":false,"hideFromContinueListening":false,"lastUpdate":1700000000000,"startedAt":1690000000000}
        """#.utf8))
        #expect(progress.libraryItemId == "li1")
        #expect(progress.currentTime == 25)
        #expect(progress.isFinished == false)

        let task = try decoder.decode(AudiobookshelfClient.ServerTask.self, from: Data(#"""
        {"id":"t1","action":"library-scan","data":{"libraryId":"lib1","scanResults":{"added":2,"updated":0,"missing":1,"elapsed":1500}},
         "isFailed":false,"isFinished":true}
        """#.utf8))
        #expect(task.action == "library-scan")
        #expect(task.data?.libraryId == "lib1")
        let results = try #require(task.data?.scanResults)
        #expect(results.added == 2)
        #expect(results.missing == 1)
        #expect(results.elapsed == 1500)
    }

    @Test func librarySettingsAreLenient() throws {
        // Serwer bywa niekonsekwentny co do typów (np. proporcje okładki jako liczba zmiennoprzecinkowa).
        let settings = try decoder.decode(AudiobookshelfClient.LibrarySettings.self, from: Data(#"""
        {"coverAspectRatio":1.0,"disableWatcher":"tak","podcastSearchRegion":"pl","autoScanCronExpression":null}
        """#.utf8))
        #expect(settings.coverAspectRatio == 1)
        #expect(settings.disableWatcher == nil)
        #expect(settings.podcastSearchRegion == "pl")
    }

    @Test func htmlDescriptionsBecomePlainText() {
        #expect(HTMLText.plain("<p>Pierwszy&nbsp;akapit</p><p>Drugi<br>wiersz &#261;</p>") == "Pierwszy akapit\n\nDrugi\nwiersz ą")
        #expect(HTMLText.plain("   ") == nil)
        #expect(HTMLText.plain(nil) == nil)
    }

    @Test func uploadNamesStayUniqueAcrossDiscFolders() {
        let files = [URL(filePath: "/b/Ksiazka/CD1/01.mp3"), URL(filePath: "/b/Ksiazka/CD2/01.mp3")]
        let names = AudiobookshelfClient.uploadNames(for: files)
        #expect(Set(names).count == 2)
        #expect(AudiobookshelfClient.uploadNames(for: [URL(filePath: "/b/a.mp3"), URL(filePath: "/b/b.mp3")]) == ["a.mp3", "b.mp3"])
    }
}
