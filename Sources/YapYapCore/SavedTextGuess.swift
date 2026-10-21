import Foundation

/// A first guess at what selected text is, to name it when it's saved: an email address, a phone
/// number, or a key from a service whose keys have a known prefix. Only a suggestion; the name stays
/// editable.
public enum SavedTextGuess {
    public static func guess(_ text: String) -> (name: String, secret: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[A-Za-z]{2,}/#) != nil { return ("Email address", false) }
        if text.wholeMatch(of: #/https?:\/\/\S+/#) != nil { return ("Link", false) }
        if text.wholeMatch(of: #/\+?[\d\s().-]{7,20}/#) != nil, (7...15).contains(text.filter(\.isNumber).count) {
            return ("Phone number", false)
        }
        if !text.contains(where: \.isWhitespace) {
            if let known = prefixes.first(where: { text.hasPrefix($0.prefix) }), text.count >= known.prefix.count + 12 {
                return (known.name, true)
            }
            if looksLikeKey(text) { return ("API key", true) }
        }
        return ("", false)
    }

    /// Long, no spaces, letters and digits mixed: a token rather than a word.
    static func looksLikeKey(_ text: String) -> Bool {
        text.count >= 20 && text.contains(where: \.isLetter) && text.contains(where: \.isNumber)
            && text.allSatisfy { $0.isLetter || $0.isNumber || "-_.=+/:".contains($0) }
    }

    /// Most specific first.
    private static let prefixes: [(prefix: String, name: String)] = [
        ("sk-ant-", "Anthropic key"),
        ("sk-or-", "OpenRouter key"),
        ("sk-proj-", "OpenAI key"),
        ("sk_live_", "Stripe key"),
        ("sk_test_", "Stripe test key"),
        ("rk_live_", "Stripe key"),
        ("sk_", "ElevenLabs key"),
        ("sk-", "OpenAI key"),
        ("github_pat_", "GitHub token"),
        ("ghp_", "GitHub token"),
        ("glpat-", "GitLab token"),
        ("xoxb-", "Slack token"),
        ("xoxp-", "Slack token"),
        ("AKIA", "AWS key"),
        ("AIza", "Google API key"),
        ("hf_", "Hugging Face token"),
        ("gsk_", "Groq key"),
        ("pplx-", "Perplexity key"),
        ("r8_", "Replicate token"),
    ]
}
