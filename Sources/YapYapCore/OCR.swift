import CoreGraphics
import Vision

public enum OCR {
    public static func lines(in image: CGImage, fast: Bool = false) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        if !fast { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image).perform([request])

        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let s = candidate.string
            var words: [OCRWord] = []
            var i = s.startIndex
            // Split on whitespace (not .byWords) so punctuation stays in the spoken text.
            while let start = s[i...].firstIndex(where: { !$0.isWhitespace }) {
                let end = s[start...].firstIndex(where: \.isWhitespace) ?? s.endIndex
                let box = (try? candidate.boundingBox(for: start..<end))?.boundingBox ?? observation.boundingBox
                words.append(OCRWord(text: String(s[start..<end]), rect: box))
                i = end
            }
            return words.isEmpty ? nil : OCRLine(text: s, rect: observation.boundingBox, words: words)
        }
        return InkSnap.snap(lines, in: image)
    }

    public static func doc(from image: CGImage, fast: Bool = false) throws -> Doc {
        let size = CGSize(width: image.width, height: image.height)
        return Doc(blocks: Layout.blocks(try lines(in: image, fast: fast), imageSize: size))
    }
}
