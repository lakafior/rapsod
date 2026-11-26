// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import AudiobookshelfKit

@Suite struct PodcastDirectoriesTests {
    @Test func podcastIndexAuthorizationIsSHA1OfKeySecretAndTime() {
        #expect(PodcastDirectories.podcastIndexAuthorization(key: "ABC", secret: "secret", epoch: 1_700_000_000)
                == "082da403bfa9952c674ed7f16cee88d237d416cb")
    }

    @Test func parsesPodcastIndexFeeds() throws {
        let json = """
        {"status":"true","feeds":[
          {"id":1,"title":"Pierwszy","url":"https://example.com/feed.xml","author":"Autor","artwork":"https://example.com/a.jpg",
           "image":"https://example.com/i.jpg","itunesId":123,"episodeCount":42,"explicit":true,
           "categories":{"77":"Society","9":"Business"}},
          {"id":2,"title":"Bez adresu"},
          {"id":3,"title":"Drugi","url":"https://example.org/rss","ownerName":"Właściciel","itunesId":null,"explicit":false,"categories":null}
        ],"count":3}
        """
        let results = try PodcastDirectories.parsePodcastIndex(Data(json.utf8))
        #expect(results.count == 2)
        #expect(results[0].title == "Pierwszy")
        #expect(results[0].id == 123)
        #expect(results[0].cover == "https://example.com/a.jpg")
        #expect(results[0].trackCount == 42)
        #expect(results[0].explicit == true)
        #expect(results[0].genres == ["Business", "Society"])
        #expect(results[0].source == .podcastIndex)
        #expect(results[1].artistName == "Właściciel")
        #expect(results[1].id == nil)
        #expect(results[1].explicit == false)
    }

    @Test func parsesFyydPodcasts() throws {
        let json = """
        {"status":1,"msg":"ok","data":[
          {"title":"Historia","xmlURL":"https://feeds.example.com/h","imgURL":"https://img/x.jpg","author":" Autor ","episode_count":444},
          {"title":"Bez kanału"}
        ]}
        """
        let results = try PodcastDirectories.parseFyyd(Data(json.utf8))
        #expect(results.count == 1)
        #expect(results[0].feedUrl == "https://feeds.example.com/h")
        #expect(results[0].artistName == "Autor")
        #expect(results[0].trackCount == 444)
        #expect(results[0].source == .fyyd)
        #expect(try PodcastDirectories.parseFyyd(Data(#"{"status":1,"data":[]}"#.utf8)).isEmpty)
    }

    @Test func mergeKeepsFirstOccurrenceOfEachFeed() {
        func result(_ feed: String, _ source: PodcastDirectory?) -> AudiobookshelfClient.PodcastSearchResult {
            .init(title: feed, artistName: nil, description: nil, genres: nil, cover: nil, trackCount: nil, feedUrl: feed, explicit: nil, source: source)
        }
        let merged = PodcastDirectories.merge([
            [result("https://example.com/feed/", nil)],
            [result("http://www.EXAMPLE.com/feed", .podcastIndex), result("https://other.com/rss", .podcastIndex)],
            [result("https://other.com/rss/", .fyyd), result("https://third.com/rss", .fyyd)],
        ])
        #expect(merged.map(\.feedUrl) == ["https://example.com/feed/", "https://other.com/rss", "https://third.com/rss"])
        #expect(merged.map(\.source) == [nil, .podcastIndex, .fyyd])
    }

    @Test func iTunesResultsDecodeWithoutSource() throws {
        let json = #"[{"id":5,"title":"T","feedUrl":"https://x/rss","explicit":false}]"#
        let results = try JSONDecoder().decode([AudiobookshelfClient.PodcastSearchResult].self, from: Data(json.utf8))
        #expect(results.first?.source == nil)
        #expect(results.first?.id == 5)
    }
}
