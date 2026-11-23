import Foundation

/// A host's reply text as inline Markdown. The host is untrusted: raw HTML stays literal text,
/// and links and images are removed, so nothing can be tapped or loaded.
public enum ChatMarkdown {
    /// Bold, italic, code and strikethrough runs, with whitespace and line breaks kept. Text the
    /// parser rejects comes back verbatim.
    public static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        result.link = nil
        result.imageURL = nil
        return result
    }
}
