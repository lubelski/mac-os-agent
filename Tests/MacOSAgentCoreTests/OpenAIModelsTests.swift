import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct OpenAIModelsTests {
    @Test func offersTheCurrentModelsInPickerOrder() {
        #expect(OpenAIModel.all.map(\.id) == [
            "gpt-6-luna",
            "gpt-6.1-terra",
            "gpt-6.2-sol",
            "gpt-6.1-sol",
            "gpt-6-sol",
            "gpt-6.2-astra",
            "gpt-6-astra",
            "gpt-5.6-luna",
        ])
    }

    @Test func theDefaultIsOffered() {
        #expect(OpenAIModel.defaultID == "gpt-6-luna")
        #expect(OpenAIModel.all.contains { $0.id == OpenAIModel.defaultID })
    }

    @Test func idsAndNamesAreUnique() {
        #expect(Set(OpenAIModel.all.map(\.id)).count == OpenAIModel.all.count)
        #expect(Set(OpenAIModel.all.map(\.name)).count == OpenAIModel.all.count)
    }
}
