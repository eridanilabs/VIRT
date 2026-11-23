import Foundation
import Testing
@testable import VIRTKit

struct ChatMarkdownTests {
    /// The intent of the run that holds `text`'s first character.
    private func intent(of text: String, in string: AttributedString) throws -> InlinePresentationIntent? {
        let range = try #require(string.range(of: text))
        return string[range].runs.first?.inlinePresentationIntent
    }

    @Test func inlineMarkdownGetsItsStylesAndKeepsLineBreaks() throws {
        let string = ChatMarkdown.attributed("A **bold** and *italic*\n\n  `code`  here")
        #expect(String(string.characters) == "A bold and italic\n\n  code  here")
        #expect(try intent(of: "bold", in: string) == .stronglyEmphasized)
        #expect(try intent(of: "italic", in: string) == .emphasized)
        #expect(try intent(of: "code", in: string) == .code)
        #expect(try intent(of: "here", in: string) == nil)
    }

    @Test func htmlStaysLiteralAndLinksAndImagesAreRemoved() {
        let text = "<script>alert(1)</script> [link](https://example.com) ![cat](https://example.com/cat.png) <https://example.org>"
        let string = ChatMarkdown.attributed(text)
        let shown = String(string.characters)
        #expect(shown.contains("<script>alert(1)</script>"))
        #expect(shown.contains("link"))
        #expect(!shown.contains("https://example.com"))
        #expect(string.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
    }

    @Test func plainTextComesBackVerbatim() {
        let text = "No markup, just 1 < 2 & 3 > 2."
        #expect(String(ChatMarkdown.attributed(text).characters) == text)
    }
}
