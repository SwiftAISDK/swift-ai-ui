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

    // ai@7.0.179 validates deep provider, citation and tool metadata in place.
    @Test func preservesDeepJSONValuesInTextToolAndCitationMetadata() throws {
        let node = (0..<100).reduce(JSONValue.array([JSONValue]())) { value, _ in .array([value]) }
        let nested = JSONValue.array(Array(repeating: node, count: 20))
        let metadata: [String: JSONValue] = ["provider": ["key": nested]]
        let citation = AICitation(source: .init(id: "source-1", sourceType: "url", url: "https://example.com",
            providerMetadata: metadata))
        var call = AIToolCall(id: "1", name: "foo", arguments: "{}", providerMetadata: metadata)
        call.toolMetadata = ["key": nested]
        let messages: [AIUIMessage] = [.assistant(id: "1", parts: [
            .text(.init(text: "Hello", providerMetadata: metadata, citations: [citation])),
            .toolCall(call),
            .toolResult(.init(toolCallID: "1", toolName: "foo", result: "result", providerMetadata: metadata))
        ])]
        #expect(try validateUIMessages(messages) == messages)
    }

    @Test func rejectsNonFiniteValuesInCitationMetadataAtTheFirstPath() {
        let citation = AICitation(source: .init(id: "source-1", sourceType: "url", url: "https://example.com",
            providerMetadata: ["provider": ["key": [JSONValue.number(.infinity), .number(.infinity)]]]))
        let messages: [AIUIMessage] = [.assistant(id: "1", parts: [.text(.init(text: "Hello", citations: [citation]))])]
        let result = safeValidateUIMessages(messages)
        #expect(!result.isValid)
        #expect(result.issues == [.init(
            path: "messages[0].parts[0].text.citations[0].source.providerMetadata.provider.key[0]",
            message: "Invalid JSON value. Expected a finite number."
        )])
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

    @Test func nestedDeniedToolMetadataReachesTheAgentModel() async throws {
        let node = (0..<100).reduce(JSONValue.array([])) { value, _ in .array([value]) }
        let nested = JSONValue.array(Array(repeating: node, count: 20))
        let call = AIToolCall(id: "call-1", name: "x", arguments: "{}", providerMetadata: ["p": ["value": nested]])
        let approval = AIToolApprovalRequest(id: "approval-1", toolName: "x", arguments: "{}", toolCallID: call.id)
        let denied = AIToolResult(toolCallID: call.id, toolName: call.name, result: "Tool call execution denied.",
            isError: true, providerMetadata: call.providerMetadata)
        let model = WeeklyValidationModel()
        let stream = try createAgentUIStream(agent: AIToolLoopAgent(model: model), uiMessages: [
            .assistant(id: "m1", parts: [.toolCall(call), .toolApprovalRequest(approval)]),
            .init(id: "m2", role: .tool, parts: [.toolApprovalResponse(.init(id: approval.id, approved: false)), .toolResult(denied)])
        ])
        for try await _ in stream {}

        let requests = model.streamRequests
        try #require(requests.count == 1)
        let calls = requests[0].messages.filter { $0.role == .assistant }.flatMap(\.content).compactMap { part -> AIToolCall? in
            guard case let .toolCall(call) = part else { return nil }
            return call
        }
        let modelCall = try #require(calls.first)
        #expect(modelCall.id == "call-1")
        #expect(modelCall.providerMetadata["p"]?["value"] == nested)
    }
}

private final class WeeklyValidationModel: LanguageModel, @unchecked Sendable {
    let providerID = "test-provider", modelID = "test-model"
    private let lock = NSLock()
    private var requests: [LanguageModelRequest] = []
    var streamRequests: [LanguageModelRequest] { lock.withLock { requests } }
    var streamCalls: Int { streamRequests.count }
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        Issue.record("Invalid UI history must not invoke model generation")
        return .init(text: "", rawValue: [:])
    }
    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        lock.withLock { requests.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.streamStart(warnings: []))
            continuation.yield(.finishMetadata(reason: "stop", usage: .init(inputTokens: 1, outputTokens: 1)))
            continuation.finish()
        }
    }
}
