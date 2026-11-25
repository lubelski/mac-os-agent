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

    // MARK: The account's list

    @Test func theListKeepsListedModelsInTheServersOrder() throws {
        let data: JSONValue = ["models": [
            ["slug": "gpt-7-nova", "display_name": "GPT-7 Nova", "visibility": "list"],
            ["slug": "gpt-6-luna", "display_name": "GPT-6 Luna", "visibility": "list"],
            ["slug": "codex-internal", "display_name": "Internal", "visibility": "hide"],
            ["slug": "no-visibility", "display_name": "No Visibility"],
            ["slug": "gpt-6-luna", "display_name": "GPT-6 Luna again", "visibility": "list"],
        ]]
        #expect(try OpenAIModelCatalog.models(from: data.data) == [
            .init(id: "gpt-7-nova", name: "GPT-7 Nova"),
            .init(id: "gpt-6-luna", name: "GPT-6 Luna"),
        ])
    }

    @Test func aListThatIsNotAsDocumentedIsRefused() {
        func attempt(_ json: JSONValue) -> OpenAIModelCatalog.CatalogError? {
            do {
                _ = try OpenAIModelCatalog.models(from: json.data)
                return nil
            } catch {
                return error as? OpenAIModelCatalog.CatalogError
            }
        }
        #expect(attempt(["data": [["id": "gpt-6-luna"]]]) == .invalidResponse("has no models array"))
        #expect(attempt(["models": [["slug": "x", "visibility": "list"]]]) == .invalidResponse("has a model with no slug or name"))
        #expect(attempt(["models": [["slug": "x", "display_name": "X", "visibility": "hide"]]]) == .invalidResponse("lists no models"))
    }

    @Test func withNoListTheFallbackIsOffered() {
        let choices = OpenAIModel.choices(listed: nil, current: "gpt-6-luna")
        #expect(choices.models == OpenAIModel.all)
        #expect(!choices.currentIsUnlisted)
        // A saved model outside the fallback is still offered, as before, without the note.
        let custom = OpenAIModel.choices(listed: nil, current: "my-model")
        #expect(custom.models.last == .init(id: "my-model", name: "my-model"))
        #expect(!custom.currentIsUnlisted)
    }

    @Test func aSavedModelTheAccountDoesNotListStaysSelected() {
        let listed: [OpenAIModel] = [.init(id: "gpt-7-nova", name: "GPT-7 Nova")]
        let choices = OpenAIModel.choices(listed: listed, current: "gpt-6-luna")
        #expect(choices.models == listed + [.init(id: "gpt-6-luna", name: "GPT-6 Luna")])
        #expect(choices.currentIsUnlisted)

        let listedCurrent = OpenAIModel.choices(listed: listed, current: "gpt-7-nova")
        #expect(listedCurrent.models == listed)
        #expect(!listedCurrent.currentIsUnlisted)
    }
}
