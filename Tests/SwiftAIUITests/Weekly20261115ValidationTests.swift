// ai@7.0.173 validate-ui-messages and create-agent-ui-stream-response deltas.
// Typed Swift parts cannot express {} / unknown tags / missing required fields or
// JavaScript property getters. Invalid native envelopes/JSON below preserve the
// bounded first-error and pre-agent validation behaviors on the Swift surface.
import Foundation
import Testing
import SwiftAIProvider
import SwiftAI
@testable import SwiftAIUI

@Suite("Weekly20261115Validation", .serialized)
struct Weekly20261115ValidationTests {
    @Test(arguments: ["parts", "messages", "steering parts"])
    func repeatedInvalidCollectionsReportOneBoundedFirstIssue(_ collection: String) {
        let invalid = AIUIMessagePart.file(.init(mediaType: "", data: Data()))
        let messages: [AIUIMessage], expectedPath: String
        switch collection {
        case "parts":
            messages = [.init(id: "1", role: .user, parts: Array(repeating: invalid, count: 100))]
            expectedPath = "messages[0].parts[0].file.mediaType"
        case "messages":
            messages = Array(repeating: .init(id: "1", role: .user, parts: [invalid]), count: 100)
            expectedPath = "messages[0].parts[0].file.mediaType"
        default:
            let content = Array(repeating: AIContentPart.text("invalid", providerMetadata: ["invalid": .number(.infinity)]), count: 100)
            messages = [.assistant(id: "1", parts: [.steeringMessage(.init(id: "2", content: content))])]
            expectedPath = "messages[0].parts[0].steeringMessage.content[0].providerMetadata.invalid"
        }
        let result = safeValidateUIMessages(messages)
        #expect(!result.isValid)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.path == expectedPath)
        #expect(result.issues.map(\.description).joined().count < 40_000)
    }

    @Test func preservesFirstInvalidPartIndex() {
        let result = safeValidateUIMessages([.init(id: "1", role: .user, parts: [
            .text(.init(text: "hello")), .file(.init(mediaType: "", data: Data()))
        ])])
        #expect(!result.isValid)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.path == "messages[0].parts[1].file.mediaType")
    }

    @Test func laterInvalidMetadataDoesNotAddIssuesAfterFirstInvalidPart() {
        let result = safeValidateUIMessages([.init(id: "1", role: .user, parts: [
            .file(.init(mediaType: "", data: Data())),
            .text(.init(text: "hello", providerMetadata: ["later": .number(.infinity)]))
        ])])
        #expect(!result.isValid)
        #expect(result.issues == [.init(path: "messages[0].parts[0].file.mediaType", message: "file media type must not be empty.")])
    }

    @Test func acceptsUnchangedLargeValidPartArrays() throws {
        let messages = [AIUIMessage(id: "1", role: .user, parts: Array(repeating: .text(.init(text: "hello")), count: 2500))]
        #expect(try validateUIMessages(messages) == messages)
    }

    @Test(arguments: ["text", "static tool", "dynamic tool"])
    func malformedNativeJSONMetadataHasBoundedSingleFailure(_ kind: String) {
        // Native provider metadata intentionally accepts arbitrary JSON values;
        // unlike the JS nested record schema, scalar finite values are valid.
        // Non-finite numbers are the corresponding representable invalid JSON.
        let metadata = Dictionary(uniqueKeysWithValues: (0..<100).map { ("key\($0)", JSONValue.number(.infinity)) })
        let part: AIUIMessagePart
        if kind == "text" { part = .text(.init(text: "hello", providerMetadata: metadata)) }
        else { part = .toolCall(.init(id: "1", name: "foo", arguments: "{}", dynamic: kind == "dynamic tool", providerMetadata: metadata)) }
        let result = safeValidateUIMessages([.init(id: "1", role: .user, parts: [part])])
        #expect(!result.isValid)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.path.hasSuffix("providerMetadata.key0") == true)
        #expect(result.issues.map(\.description).joined().count < 40_000)
    }

    @Test func repeatedMalformedPartsFailBeforeAgentRuns() {
        let model = WeeklyValidationModel(), agent = AIToolLoopAgent(model: model)
        let messages = [AIUIMessage(id: "m1", role: .user, parts: Array(repeating: .file(.init(mediaType: "", data: Data())), count: 2500))]
        do {
            _ = try createAgentUIStream(agent: agent, uiMessages: messages)
            Issue.record("Expected validation error before creating agent stream")
        } catch let error as AIUIMessageStreamError {
            #expect(error.validationIssues.count == 1)
            #expect(error.validationIssues.first?.path == "messages[0].parts[0].file.mediaType")
            #expect(error.description.count < 40_000)
        } catch { Issue.record("Expected native UI validation error, got \(error)") }
        #expect(model.streamCalls == 0)
    }
}

private final class WeeklyValidationModel: LanguageModel, @unchecked Sendable {
    let providerID = "test-provider", modelID = "test-model"
    private let lock = NSLock()
    private var calls = 0
    var streamCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        Issue.record("Invalid UI history must not invoke model generation")
        return .init(text: "", rawValue: [:])
    }
    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        lock.lock(); calls += 1; lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }
}
