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

}
