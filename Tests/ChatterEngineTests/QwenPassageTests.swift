import Foundation
import Testing
@testable import ChatterEngine

struct QwenPassageTests {
    @Test func instructionsNeverBecomeSpokenWords() throws {
        let text="(excited) Hello there. [calm tone] Welcome back."
        let clone=try DeliveryPassages.passages(text,supportsInstructions:false)
        #expect(clone.map(\.text).joined()=="Hello there. Welcome back.")
        #expect(clone.allSatisfy { $0.instruction.isEmpty })
        let custom=try DeliveryPassages.passages(text,instruction:"Speak optimistically.",supportsInstructions:true)
        #expect(custom[0].instruction.contains("excited") && custom[1].instruction.contains("calm tone"))
        #expect(custom.map(\.text)==clone.map(\.text))
    }
    @Test func unicodeSplittingNeverLosesText() throws {
        for text in [String(repeating:"こんにちは、世界。 ",count:100),String(repeating:"Words and spaces!\n",count:100),String(repeating:"😀",count:80)] {
            let result=try DeliveryPassages.split(text,maxBytes:180)
            #expect(result.joined()==text)
            #expect(result.allSatisfy { $0.utf8.count<=181 })
        }
    }
    @Test func malformedNotesRemainLiteral() throws {
        let result=try DeliveryPassages.passages("(2019) was a year.",supportsInstructions:true)
        #expect(result[0].text=="(2019) was a year.")
    }
}
