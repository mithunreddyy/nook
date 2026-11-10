import Testing
@testable import NookKit

@Suite struct Search {
    @Test func emptyQueryMatchesEverything() {
        #expect(WindowSearch.score("", in: ["Safari", "Docs"]) != nil)
    }

    @Test func lettersMustAppearInOrder() {
        #expect(WindowSearch.score("sfr", in: ["Safari"]) != nil)
        #expect(WindowSearch.score("rfs", in: ["Safari"]) == nil)
    }

    @Test func ignoresCaseAndSpaces() {
        #expect(WindowSearch.score("VS code", in: ["Visual Studio Code"]) != nil)
    }

    @Test func anyFieldCanMatch() {
        #expect(WindowSearch.score("readme", in: ["Xcode", "README.md — nook"]) != nil)
    }

    @Test func prefixBeatsScatteredLetters() {
        let prefix = WindowSearch.score("ter", in: ["Terminal"])!
        let scattered = WindowSearch.score("ter", in: ["The Archiver"])!
        #expect(prefix > scattered)
    }

    @Test func wordStartsBeatMiddles() {
        let starts = WindowSearch.score("vsc", in: ["Visual Studio Code"])!
        let middle = WindowSearch.score("vsc", in: ["Devscope"])!
        #expect(starts > middle)
    }

    @Test func rankKeepsOrderForTies() {
        let ranked = WindowSearch.rank("", items: ["a", "b", "c"]) { [$0] }
        #expect(ranked == ["a", "b", "c"])
    }

    @Test func rankPutsBestFirstAndDropsMisses() {
        let ranked = WindowSearch.rank("mail", items: ["Notes", "Gmail — Inbox", "Mail"]) { [$0] }
        #expect(ranked == ["Mail", "Gmail — Inbox"])
    }
}
