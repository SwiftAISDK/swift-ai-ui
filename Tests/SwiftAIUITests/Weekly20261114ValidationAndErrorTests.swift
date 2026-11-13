import Foundation
import Testing
import SwiftAIProvider
@testable import SwiftAIUI

@Suite struct Weekly20261114ValidationAndErrorTests {
    @Test func stopsAtFirstInvalidMessageOrPart() {
        let message = AIUIMessage.user("one", id: "")
        let result = safeValidateUIMessages(Array(repeating: message, count: 1000))
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.path == "messages[0].id")
        let parts = Array(repeating: AIUIMessagePart.file(.init(mediaType: "", data: Data())), count: 1000)
        let partResult = safeValidateUIMessages([.assistant(id: "a", parts: parts)])
        #expect(partResult.issues.count == 1)
        #expect(partResult.issues.first?.path == "messages[0].parts[0].file.mediaType")
    }

    @Test(arguments: [Double.infinity, -.infinity, .nan])
    func rejectsNonFiniteProviderAndToolMetadataWithOneIssue(_ number: Double) {
        var nested = JSONValue.number(number)
        for _ in 0..<128 { nested = ["nested": nested] }
        let part = AIUIMessagePart.text(.init(text: "x", providerMetadata: ["provider": nested]))
        let result = safeValidateUIMessages([.assistant(id: "a", parts: [part])])
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.message.contains("finite") == true)
        var call = AIToolCall(id: "call", name: "tool", arguments: "{}")
        call.toolMetadata = ["score": .number(number)]
        #expect(safeValidateUIMessages([.assistant(id: "a", parts: [.toolCall(call)])]).issues.count == 1)
    }

    @Test func validatesCitationMetadataAndKeepsOpaquePayloads() {
        let source = AISource(id: "source", sourceType: "url", url: "https://example.test", providerMetadata: ["confidence": .number(.infinity)])
        let part = AIUIMessagePart.text(.init(text: "x", citations: [.init(source: source)]))
        #expect(safeValidateUIMessages([.assistant(id: "a", parts: [part])]).issues.count == 1)
        let later = AISource(id: "later", sourceType: "invalid")
        let ordered = safeValidateUIMessages([.assistant(id: "a", parts: [.text(.init(text: "x", citations: [.init(source: source), .init(source: later)]))])])
        #expect(ordered.issues.first?.path.contains("citations[0].source.providerMetadata") == true)
        // Opaque custom/data values are not provider JSON metadata schemas.
        #expect(safeValidateUIMessages([.assistant(id: "a", parts: [.data(.init(value: .number(.infinity)))])]).isValid)
    }

    @Test(arguments: [false, true])
    func toolErrorsPreserveHistoryUnlessRedactionIsExplicit(_ redact: Bool) throws {
        var reducer = AIUIMessageStreamReducer(message: .assistant(id: "a"))
        reducer.errorOptions = .init(redactToolErrors: redact, onError: { _ in "safe" })
        let result = AIToolResult(toolCallID: "call", toolName: "tool", result: ["error": "model error"],
                                  modelOutput: ["type": "error-text", "value": "model error"], isError: true)
        _ = try reducer.consume(.toolResult(result))
        guard case let .toolResult(displayed) = reducer.message.parts.last else { Issue.record("Expected tool error"); return }
        #expect(displayed.isError)
        #expect(displayed.modelOutput?["value"] == .string(redact ? "safe" : "model error"))
        #expect(reducer.message.metadata["warnings"] == nil)
        _ = try reducer.consume(.reasoningStart(id: "reasoning"))
        #expect((reducer.message.metadata["warnings"] != nil) == redact)
        #expect(result.modelOutput?["value"] == "model error")
    }

    @Test func providerExecutedErrorsBypassApplicationRedaction() throws {
        let result = AIToolResult(toolCallID: "call", toolName: "hosted", result: ["code": "provider_code"], isError: true, providerExecuted: true)
        var reducer = AIUIMessageStreamReducer()
        reducer.errorOptions = .init(redactToolErrors: true, onError: { _ in "safe" })
        _ = try reducer.consume(.toolResult(result))
        #expect(reducer.message.parts.last == .toolResult(result))
        _ = try reducer.consume(.reasoningStart(id: "later"))
        #expect(reducer.message.metadata["warnings"] == nil)
    }

    @Test func steeringProviderMetadataUsesTheSameFiniteJSONCheck() {
        let part = AIUIMessagePart.steeringMessage(.init(id: "steer", content: [
            .text("next", providerMetadata: ["confidence": .number(.infinity)])
        ]))
        let result = safeValidateUIMessages([.assistant(id: "a", parts: [part])])
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.path.contains("steeringMessage.content[0].providerMetadata") == true)
    }

    @Test func customFormatterOptsInAndDefaultDoesNotChangeToolHistory() throws {
        let error = AIToolResult(toolCallID: "call", toolName: "tool", result: "private error", isError: true)
        var original = AIUIMessageStreamReducer()
        _ = try original.consume(.toolResult(error))
        #expect(original.message.parts.last == .toolResult(error))
        var redacted = AIUIMessageStreamReducer()
        redacted.errorOptions = .init(onError: { _ in "safe" })
        _ = try redacted.consume(.toolResult(error))
        guard case let .toolResult(result) = redacted.message.parts.last else { Issue.record("Expected tool error"); return }
        #expect(result.result == "safe")
    }
}
