import Foundation
import Observation

/// What you've read and dictated, and running totals, for the home page. Kept in one small JSON
/// file in Application Support, on this Mac only. With "Keep history" off, only the totals are kept.
@Observable
final class History {
    static let shared = History()

    enum Kind: String, Codable { case read, dictation }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date: Date
        var kind: Kind
        var text: String
    }

    struct Totals: Codable, Equatable {
        var wordsRead = 0
        var wordsDictated = 0
        var secondsListened = 0.0
    }

    /// Newest first.
    private(set) var entries: [Entry] = []
    private(set) var totals = Totals()

    private static let limit = 200
    /// Longest excerpt kept per entry: enough to recognize it, not a copy of every page you read.
    private static let excerpt = 600
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private struct Stored: Codable {
        var entries: [Entry]
        var totals: Totals
    }

    /// `file` nil keeps everything in memory (tests).
    init(file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YapYap/history.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            entries = stored.entries
            totals = stored.totals
        }
    }

    func addRead(_ text: String, words: Int, seconds: Double, keep: Bool = Settings.shared.keepHistory) {
        guard words > 0 else { return }
        totals.wordsRead += words
        totals.secondsListened += seconds
        if keep { insert(Entry(date: Date(), kind: .read, text: Self.trim(text))) }
        save()
    }

    func addDictation(_ text: String, keep: Bool = Settings.shared.keepHistory) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return }
        totals.wordsDictated += words
        if keep { insert(Entry(date: Date(), kind: .dictation, text: Self.trim(text))) }
        save()
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Forgets every entry; the totals stay.
    func clear() {
        entries = []
        save()
    }

    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    private static func trim(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > excerpt ? String(flat.prefix(excerpt)) + "…" : flat
    }

    /// Written a moment later, off the main thread, so a burst of changes is one write.
    private func save() {
        guard let file else { return }
        saveWork?.cancel()
        let stored = Stored(entries: entries, totals: totals)
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}
