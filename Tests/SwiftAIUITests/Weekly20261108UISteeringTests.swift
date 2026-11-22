import Foundation
import Testing
import SwiftAI
import SwiftAIProvider
import SwiftAIUI

@Suite("Weekly20261108 native UI steering history")
struct Weekly20261108UISteeringTests {
    @Test func replayKeepsUserSteeringBetweenAssistantSteps() throws {
        var reducer = AIUIMessageStreamReducer(message: .assistant(id: "assistant"))
        try reducer.consume(.textStart(id: "first"))
        try reducer.consume(.textDeltaPart(id: "first", delta: "first"))
        try reducer.consume(.textEnd(id: "first"))
        let content: [AIContentPart] = [.text("correction", providerMetadata: ["anthropic": ["cacheControl": ["type": "ephemeral"]]]), .providerReference(mimeType: "application/pdf", reference: ["openai": "file-1"], filename: "report.pdf")]
        try reducer.consume(.steeringMessage(id: "steer-1", message: .init(role: .user, content: content), stepNumber: 1))
        try reducer.consume(.textStart(id: "second"))
        try reducer.consume(.textDeltaPart(id: "second", delta: "second"))
        try reducer.consume(.ping)
        let messages = try convertToModelMessages([.user("initial", id: "user"), reducer.message])
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(messages[2].content == content)
        #expect(messages[1].content == [.text("first")])
        #expect(throws: AIUIMessageStreamError.self) { try convertToModelMessage(reducer.message) }
    }

    @Test func steeringRejectsNonUserContent() {
        let message = AIUIMessage.assistant(parts: [.steeringMessage(.init(id: "steer", content: [.toolCall(.init(id: "call", name: "bad", arguments: "{}"))]))])
        #expect(!safeValidateUIMessages([message]).isValid)
    }
    @Test func emptyTextMetadataSurvivesUIReplay() throws {
        let message = AIUIMessage.assistant(parts: [.text(.init(text: "", providerMetadata: ["anthropic": ["signature": "kept"]]))])
        let converted = try convertToModelMessages([message])
        #expect(converted.first?.content == [.text("", providerMetadata: ["anthropic": ["signature": "kept"]])])
    }

    @Test func interruptedTextAndReasoningStayAsEmptyCompletedParts() async throws {
        let correction = "Use Paris, Texas instead."
        let answer = "It is sunny in Paris, Texas."
        let parts: [LanguageStreamPart] = [
            .streamStart(warnings: []),
            .reasoningStart(id: "0"), .textStart(id: "1"),
            .textEnd(id: "1"), .reasoningEnd(id: "0"),
            .steeringMessage(id: "steer-1", message: .user(correction), stepNumber: 0),
            .textStart(id: "2"), .textDeltaPart(id: "2", delta: answer), .textEnd(id: "2"),
            .finishMetadata(reason: "stop", usage: .init(outputTokens: 10))
        ]
        let stream = AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            continuation.finish()
        }
        var final: AIUIMessage?
        for try await snapshot in AIUIMessageStreamReducer.snapshots(from: stream, messageID: "assistant") {
            final = snapshot
        }
        #expect(final?.parts == [
            .reasoning(.init(id: "0", text: "", state: .done)),
            .text(.init(id: "1", text: "", state: .done)),
            .steeringMessage(.init(id: "steer-1", content: [.text(correction)])),
            .text(.init(id: "2", text: answer, state: .done))
        ])
    }
}
