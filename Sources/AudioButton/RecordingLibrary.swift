import Foundation

struct RecentRecording: Identifiable, Equatable {
    var id: String { audio.path }
    let audio: URL
    let transcript: URL?
    let date: Date
}

enum RecordingLibrary {
    static func meterLevel(_ peak: Float) -> Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        return max(0, min(1, (Double(20 * log10(peak)) + 55) / 55))
    }
    static func recent(in folder: URL, limit: Int = 10) -> [RecentRecording] {
        guard limit > 0,
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.calendar = Calendar(identifier: .gregorian)
        timestampFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return files.compactMap { file -> RecentRecording? in
            guard file.pathExtension.lowercased() == "m4a",
                  let attributes = try? file.resourceValues(forKeys:
                    [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]),
                  attributes.isRegularFile == true else { return nil }
            let text = file.deletingPathExtension().appendingPathExtension("txt")
            let transcript = FileManager.default.fileExists(atPath: text.path) ? text : nil
            // Export creates the final file when recording stops. App filenames
            // retain its start time; renamed/imported files use filesystem dates.
            let started = timestampFormatter.date(from: String(file.deletingPathExtension().lastPathComponent.prefix(19)))
            return RecentRecording(audio: file, transcript: transcript,
                date: started ?? attributes.creationDate ?? attributes.contentModificationDate ?? .distantPast)
        }.sorted {
            if $0.date == $1.date { return $0.audio.lastPathComponent > $1.audio.lastPathComponent }
            return $0.date > $1.date
        }.prefix(limit).map { $0 }
    }
}
