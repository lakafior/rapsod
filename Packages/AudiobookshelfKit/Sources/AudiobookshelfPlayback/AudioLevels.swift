// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kod własny projektu (etap 13b).

import AudiobookshelfKit
import AVFoundation
import Foundation

/// Poziomy głośności pliku w okolicy wybranych chwil (do docinania granic segmentów do ciszy).
/// Czyta tylko kilka sekund wokół każdej chwili, nie cały plik.
public enum AudioLevels {
    /// Długość ramki poziomu (20 ms).
    public static let frame = 0.02

    /// Cisza wokół każdej z chwil (± `radius` s) — przerwy z `SponsorClassification.silences`.
    public static func silences(in url: URL, around times: [Double], radius: Double = 4) throws -> [SponsorClassification.Pause] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return [] }
        let length = Double(file.length) / rate
        var pauses: [SponsorClassification.Pause] = []
        for time in times.sorted() {
            let from = max(0, time - radius), to = min(length, time + radius)
            guard to - from > 0.5 else { continue }
            let levels = try read(file, from: from, to: to)
            pauses += SponsorClassification.silences(levels: levels, frameDuration: frame, startTime: from)
        }
        return pauses
    }

    /// dBFS (RMS kanałów) w ramkach po 20 ms dla zakresu sekund.
    static func read(_ file: AVAudioFile, from: Double, to: Double) throws -> [Float] {
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(from * rate)
        let count = AVAudioFrameCount(max(0, (to - from) * rate))
        file.framePosition = start
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        try file.read(into: buffer, frameCount: count)
        guard let channels = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        let perFrame = max(1, Int(rate * frame))
        let channelCount = Int(buffer.format.channelCount)
        var levels: [Float] = []
        levels.reserveCapacity(frameLength / perFrame + 1)
        var index = 0
        while index + perFrame <= frameLength {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for i in index..<(index + perFrame) { sum += samples[i] * samples[i] }
            }
            let rms = (sum / Float(perFrame * channelCount)).squareRoot()
            levels.append(20 * log10(max(rms, 1e-7)))
            index += perFrame
        }
        return levels
    }
}
