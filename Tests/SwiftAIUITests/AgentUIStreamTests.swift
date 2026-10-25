@testable import SwiftAIUI
import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI
import Testing


@Test func createAgentUIStreamConvertsUIMessagesAndStreamsSnapshots() async throws {
    let model = AgentRecordingLanguageModel(streamParts: [
        .streamStart(warnings: []),
        .textStart(id: "text-1"),
        .textDeltaPart(id: "text-1", delta: "Hel"),
        .textDeltaPart(id: "text-1", delta: "lo"),
        .textEnd(id: "text-1"),
        .finish(reason: "stop", usage: TokenUsage(totalTokens: 5))
    ])
    let agent = AIToolLoopAgent(model: model, instructions: "Answer shortly.")

    var snapshots: [AIUIMessage] = []
    let stream = try createAgentUIStream(
        agent: agent,
        uiMessages: [.user("Hi", id: "user-1")],
        messageID: "assistant-1"
    )
    for try await snapshot in stream {
        snapshots.append(snapshot)
    }

    let request = try #require(model.streamRequests.first)
    #expect(request.messages == [.system("Answer shortly."), .user("Hi")])

    let finalMessage = try #require(snapshots.last)
    #expect(finalMessage.id == "assistant-1")
    #expect(finalMessage.role == .assistant)
    #expect(finalMessage.text == "Hello")
    #expect(finalMessage.metadata["finishReason"]?.stringValue == "stop")
    #expect(finalMessage.metadata["usage"]?["totalTokens"]?.intValue == 5)
}


private final class AgentRecordingLanguageModel: LanguageModel, @unchecked Sendable {
    let providerID = "agent-test"
    let modelID = "language"
    var generateRequests: [LanguageModelRequest] = []
    var streamRequests: [LanguageModelRequest] = []
    private let result: TextGenerationResult
    private let streamParts: [LanguageStreamPart]

    init(
        result: TextGenerationResult = TextGenerationResult(text: "", rawValue: .object([:])),
        streamParts: [LanguageStreamPart] = []
    ) {
        self.result = result
        self.streamParts = streamParts
    }

    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        generateRequests.append(request)
        return result
    }

    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        streamRequests.append(request)
        let parts = streamParts
        return AsyncThrowingStream { continuation in
            for part in parts {
                continuation.yield(part)
            }
            continuation.finish()
        }
    }
}