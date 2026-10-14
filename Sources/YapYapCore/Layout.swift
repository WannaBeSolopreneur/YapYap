import CoreGraphics

/// Reading order for macOS 13–15, where RecognizeDocumentsRequest isn't available.
/// A recursive XY-cut: split on vertical whitespace (columns, sidebars) first, then on
/// horizontal gaps (rows), and group consecutive close lines into paragraphs.
public enum Layout {
    public static func blocks(_ lines: [OCRLine], imageSize: CGSize) -> [[OCRLine]] {
        guard !lines.isEmpty else { return [] }
        let w = imageSize.width, h = imageSize.height
        // Top-left pixel boxes so gaps compare in real proportions.
        let boxes = lines.map {
            CGRect(x: $0.rect.minX * w, y: (1 - $0.rect.maxY) * h, width: $0.rect.width * w, height: $0.rect.height * h)
        }
        let heights = boxes.map(\.height).sorted()
        let lineHeight = max(heights[heights.count / 2], 1)
        let cutter = Cutter(boxes: boxes, lineHeight: lineHeight)
        return cutter.cut(Array(lines.indices)).map { $0.map { lines[$0] } }
    }
}

private struct Cutter {
    let boxes: [CGRect]
    let lineHeight: CGFloat

    func cut(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }

        let cols = columns(items)
        if cols.count > 1 {
            return cols.flatMap { cut($0) }
        }

        let rows = split(items, start: { boxes[$0].minY }, end: { boxes[$0].maxY }, minGap: 0)
        if rows.count > 1 {
            // A full-width title blocks the column cut for the whole region, so regroup
            // consecutive rows that share a gutter; otherwise two columns read row by row.
            var runs: [[Int]] = []
            var i = 0
            while i < rows.count {
                var run = rows[i]
                i += 1
                if columns(run).count > 1 {
                    while i < rows.count, columns(run + rows[i]).count > 1 {
                        run += rows[i]
                        i += 1
                    }
                }
                runs.append(run)
            }

            var out: [[Int]] = []
            for run in runs {
                let groups = cut(run)
                if let prev = out.last?.last, let next = groups.first?.first, continues(prev, next) {
                    out[out.count - 1] += groups[0]
                    out += groups.dropFirst()
                } else {
                    out += groups
                }
            }
            return out
        }

        // Lines that overlap on both axes: read top to bottom, left to right.
        return [items.sorted {
            let a = boxes[$0], b = boxes[$1]
            if abs(a.minY - b.minY) > lineHeight * 0.5 { return a.minY < b.minY }
            return a.minX < b.minX
        }]
    }

    private func columns(_ items: [Int]) -> [[Int]] {
        split(items, start: { boxes[$0].minX }, end: { boxes[$0].maxX }, minGap: lineHeight * 1.2)
    }

    /// Same paragraph if the next line starts right below and roughly at the same indent.
    private func continues(_ a: Int, _ b: Int) -> Bool {
        let p = boxes[a], n = boxes[b]
        let gap = n.minY - p.maxY
        let sameSize = abs(n.height - p.height) < lineHeight * 0.35
        return gap < lineHeight * 0.8 && abs(n.minX - p.minX) < lineHeight * 2 && sameSize
    }

    /// Splits items into runs separated by empty bands of at least `minGap` along one axis.
    private func split(_ items: [Int], start: (Int) -> CGFloat, end: (Int) -> CGFloat, minGap: CGFloat) -> [[Int]] {
        let sorted = items.sorted { start($0) < start($1) }
        var groups: [[Int]] = [[sorted[0]]]
        var reach = end(sorted[0])
        for i in sorted.dropFirst() {
            if start(i) - reach > minGap {
                groups.append([i])
            } else {
                groups[groups.count - 1].append(i)
            }
            reach = max(reach, end(i))
        }
        return groups
    }
}
