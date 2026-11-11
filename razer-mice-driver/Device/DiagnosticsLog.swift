import Foundation
import Observation

/// In-app log of everything said to and heard from the mouse. Mirrored to
/// ~/Library/Logs/Adder/adder.log so a failed session can be read after the fact.
@Observable
final class DiagnosticsLog {
    private(set) var lines: [String] = []

    @ObservationIgnored private let file: FileHandle?
    @ObservationIgnored private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/Adder/adder.log")

    init() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Truncate per launch: the log is a session transcript, not a history.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    func add(_ message: String) {
        let line = "\(stamp.string(from: .now))  \(message)"
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        try? file?.write(contentsOf: Data((line + "\n").utf8))
    }

    var text: String { lines.joined(separator: "\n") }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
