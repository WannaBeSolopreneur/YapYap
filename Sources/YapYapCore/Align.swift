/// Re-finds the spoken position in a fresh capture after the page scrolls or resizes.
public enum Align {
    public static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Index offset (new − old) that places `old.words[index...]` in `new`, or nil if
    /// the next few words can't be found confidently.
    public static func shift(from old: Doc, at index: Int, to new: Doc, window: Int = 6) -> Int? {
        guard old.words.indices.contains(index) else { return nil }
        let probe = old.words[index..<min(index + window, old.words.count)].map { norm($0.text) }
        let target = new.words.map { norm($0.text) }
        let needed = probe.count < 3 ? probe.count : max(3, Int((Double(probe.count) * 0.6).rounded(.up)))

        var best: (score: Int, distance: Int, shift: Int)?
        for j in target.indices {
            var score = 0
            for k in probe.indices where j + k < target.count && !probe[k].isEmpty && probe[k] == target[j + k] {
                score += 1
            }
            // The current word itself must match, or the highlight lands on the wrong word.
            guard score >= needed, probe[0] == target[j] else { continue }
            let distance = abs(j - index)
            if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                best = (score, distance, j - index)
            }
        }
        return best?.shift
    }
}
