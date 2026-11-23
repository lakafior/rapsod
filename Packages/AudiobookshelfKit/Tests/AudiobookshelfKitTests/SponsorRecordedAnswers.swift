// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import AudiobookshelfKit

/// Zapisane odpowiedzi zdalnego modelu z rozpoznania (Mistral Small, cała transkrypcja w jednym
/// zapytaniu, 2026-11-23): numery wierszy uznanych za reklamę i czasy tych wierszy w transkrypcji
/// `DictationTranscriber` (bez tekstu), oraz ręcznie oznaczona prawda (`gt/` w notatkach rozpoznania).
/// 6 publicznych odcinków, 6,4 h, 10 segmentów.
enum SponsorRecordedAnswers {
    struct Episode {
        let name: String
        let answer: [Int]
        let lines: [SponsorClassification.Line]
        let truth: [(Double, Double)]
    }

    static let episodes: [Episode] = [
        .init(name: "pl_kryminatorium", answer: [6, 9, 10, 11, 422, 442, 443], lines: [.init(id: 6, start: 104.88, end: 124.65, text: ""), .init(id: 9, start: 164.34, end: 183.9, text: ""), .init(id: 10, start: 183.9, end: 203.82, text: ""), .init(id: 11, start: 203.82, end: 218.37, text: ""), .init(id: 422, start: 6731.43, end: 6736.05, text: ""), .init(id: 442, start: 7041.12, end: 7050.27, text: ""), .init(id: 443, start: 7050.27, end: 7059.33, text: "")], truth: [(104.9, 219.4), (7041.1, 7060.4)]),
        .init(name: "pl_imponderabilia", answer: [10, 11, 12, 13], lines: [.init(id: 10, start: 73.41, end: 92.73, text: ""), .init(id: 11, start: 92.88, end: 112.5, text: ""), .init(id: 12, start: 112.5, end: 132.48, text: ""), .init(id: 13, start: 132.48, end: 152.25, text: "")], truth: [(74.4, 152.3)]),
        .init(name: "pl_przygody", answer: [1, 2, 3], lines: [.init(id: 1, start: 19.98, end: 39.72, text: ""), .init(id: 2, start: 39.72, end: 59.46, text: ""), .init(id: 3, start: 59.46, end: 79.44, text: "")], truth: [(27.9, 74.2), (106.1, 112.9)]),
        .init(name: "pl_mwf", answer: [83, 103, 104], lines: [.init(id: 83, start: 1302.0, end: 1315.35, text: ""), .init(id: 103, start: 1647.27, end: 1666.89, text: ""), .init(id: 104, start: 1666.89, end: 1683.21, text: "")], truth: [(1655.8, 1683.6)]),
        .init(name: "en_syntax", answer: [15, 16, 17], lines: [.init(id: 15, start: 217.5, end: 225.21, text: ""), .init(id: 16, start: 225.21, end: 233.97, text: ""), .init(id: 17, start: 233.97, end: 243.09, text: "")], truth: [(217.0, 238.9)]),
        .init(name: "en_darknet", answer: [10, 11, 12, 13, 14, 15, 16, 17, 18, 96, 97, 98, 99], lines: [.init(id: 10, start: 124.08, end: 130.11, text: ""), .init(id: 11, start: 130.11, end: 149.73, text: ""), .init(id: 12, start: 149.73, end: 162.57, text: ""), .init(id: 13, start: 162.57, end: 176.55, text: ""), .init(id: 14, start: 181.68, end: 201.3, text: ""), .init(id: 15, start: 201.3, end: 217.47, text: ""), .init(id: 16, start: 217.47, end: 227.1, text: ""), .init(id: 17, start: 227.1, end: 246.3, text: ""), .init(id: 18, start: 246.69, end: 249.54, text: ""), .init(id: 96, start: 1367.22, end: 1375.71, text: ""), .init(id: 97, start: 1381.47, end: 1401.36, text: ""), .init(id: 98, start: 1401.36, end: 1421.04, text: ""), .init(id: 99, start: 1421.04, end: 1438.35, text: "")], truth: [(124.0, 251.0), (1379.5, 1438.5), (2504.6, 2521.0)]),
    ]
}
