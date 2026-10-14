import CoreGraphics

/// Vision's per-word boxes are estimates that tile the whole line, so each one spills
/// into the space before or after the word (very visible in justified text). This
/// snaps every word box to the actual ink in the captured image.
public enum InkSnap {
    public static func snap(_ lines: [OCRLine], in image: CGImage) -> [OCRLine] {
        guard let gray = GrayImage(image) else { return lines }
        return lines.map { snap($0, gray) }
    }

    static func snap(_ line: OCRLine, _ g: GrayImage) -> OCRLine {
        let W = CGFloat(g.width), H = CGFloat(g.height)
        let x0 = max(0, Int(line.rect.minX * W) - 2)
        let x1 = min(g.width, Int((line.rect.maxX * W).rounded(.up)) + 2)
        let y0 = max(0, Int((1 - line.rect.maxY) * H))
        let y1 = min(g.height, Int(((1 - line.rect.minY) * H).rounded(.up)))
        guard x1 - x0 > 4, y1 - y0 > 2 else { return line }

        // Background is the most common gray level in the line; ink is anything far from it,
        // which works for dark-on-light and light-on-dark alike.
        var histogram = [Int](repeating: 0, count: 256)
        for y in y0..<y1 { for x in x0..<x1 { histogram[Int(g[x, y])] += 1 } }
        let background = histogram.indices.max { histogram[$0] < histogram[$1] }!
        let ink = (x0..<x1).map { x in (y0..<y1).contains { y in abs(Int(g[x, y]) - background) > 48 } }

        // Ink columns → word-sized runs; gaps narrower than ~a fifth of the line height are letter gaps.
        let minGap = max(2, Int(Double(y1 - y0) * 0.18))
        var runs: [ClosedRange<Int>] = []
        var x = 0
        while x < ink.count {
            guard ink[x] else { x += 1; continue }
            var end = x
            while end + 1 < ink.count, ink[end + 1] { end += 1 }
            if let last = runs.last, x - last.upperBound - 1 < minGap {
                runs[runs.count - 1] = last.lowerBound...end
            } else {
                runs.append(x...end)
            }
            x = end + 1
        }

        var words = line.words
        for i in words.indices {
            let a = words[i].rect.minX * W - CGFloat(x0), b = words[i].rect.maxX * W - CGFloat(x0)
            let mine = runs.filter { r in
                let center = CGFloat(r.lowerBound + r.upperBound) / 2
                return center >= a && center <= b
            }
            guard let first = mine.first, let last = mine.last else { continue }
            // Clamp so a run that wrongly merged two words can't make a box grow much.
            let slack = CGFloat(minGap)
            let lo = max(CGFloat(first.lowerBound), a - slack)
            let hi = min(CGFloat(last.upperBound + 1), b + slack)
            guard hi > lo else { continue }
            let r = words[i].rect
            words[i].rect = CGRect(x: (lo + CGFloat(x0)) / W, y: r.minY, width: (hi - lo) / W, height: r.height)
        }
        return OCRLine(text: line.text, rect: line.rect, words: words)
    }
}

/// 8-bit grayscale copy of an image; row 0 is the top.
struct GrayImage {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        pixels = buffer
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}
