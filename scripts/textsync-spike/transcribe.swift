import Speech
import AVFoundation
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let t = Task {
  let tr = DictationTranscriber(locale: Locale(identifier: "pl-PL"), preset: .timeIndexedLongDictation)
  if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) { try await req.downloadAndInstall() }
  let file = try AVAudioFile(forReading: url)
  let start = Date()
  let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [tr], finishAfterFile: true)
  _ = analyzer
  var lines: [String] = []
  var last = 0.0
  for try await r in tr.results where r.isFinal {
    for run in r.text.runs {
      guard let tr = run.audioTimeRange else { continue }
      let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespaces)
      if w.isEmpty { continue }
      lines.append(String(format: "%.3f\t%.3f\t%@", tr.start.seconds, tr.end.seconds, w))
      if tr.start.seconds - last > 600 { last = tr.start.seconds; FileHandle.standardError.write("\(Int(last))s after \(Int(Date().timeIntervalSince(start)))s\n".data(using: .utf8)!) }
    }
  }
  try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
  print(String(format: "done: %d words, elapsed %.1fs", lines.count, Date().timeIntervalSince(start)))
  exit(0)
}
RunLoop.main.run()
