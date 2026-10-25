@testable import SwiftAIUI
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Testing

@Test func aiReadUIMessageStreamReturnsSnapshotsForBasicInputLikeUpstream() async throws {
    let stream = AIUIMessageStreamReducer.snapshots(
        from: uiLanguageStream([
            .streamStart(warnings: []),
            .textStart(id: "text-1"),
            .textDeltaPart(id: "text-1", delta: "Hello, "),
            .textDeltaPart(id: "text-1", delta: "world!"),
            .textEnd(id: "text-1"),
            .finish(reason: "stop", usage: nil)
        ]),
        messageID: "msg-123"
    )

    let messages = try await collectUIMessages(stream)

    #expect(messages.map(\.id) == Array(repeating: "msg-123", count: 6))
    #expect(messages.map(\.role) == Array(repeating: .assistant, count: 6))
    #expect(messages[0].parts.isEmpty)
    #expect(messages[1].parts == [
        .text(AIUITextPart(id: "text-1", text: "", state: .streaming))
    ])
    #expect(messages[2].parts == [
        .text(AIUITextPart(id: "text-1", text: "Hello, ", state: .streaming))
    ])
    #expect(messages[3].parts == [
        .text(AIUITextPart(id: "text-1", text: "Hello, world!", state: .streaming))
    ])
    #expect(messages[4].parts == [
        .text(AIUITextPart(id: "text-1", text: "Hello, world!", state: .done))
    ])
    #expect(messages[5].parts == messages[4].parts)
    #expect(messages[5].metadata["finishReason"]?.stringValue == "stop")
}

@Test func aiReadUIMessageStreamTerminatesOnErrorPartLikeUpstream() async throws {
    let stream = AIUIMessageStreamReducer.snapshots(
        from: uiLanguageStream([
            .streamStart(warnings: []),
            .textStart(id: "text-1"),
            .textDeltaPart(id: "text-1", delta: "Hello"),
            .error(message: "Test error message")
        ]),
        messageID: "msg-123",
        terminateOnError: true
    )

    do {
        _ = try await collectUIMessages(stream)
        Issue.record("Expected terminateOnError to throw.")
    } catch let error as AIUIMessageStreamError {
        #expect(error.message == "Test error message")
        #expect(error.chunkType == "error")
    } catch {
        Issue.record("Expected AIUIMessageStreamError, got \(error).")
    }
}

private func uiLanguageStream(_ parts: [LanguageStreamPart]) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        for part in parts {
            continuation.yield(part)
        }
        continuation.finish()
    }
}

private func collectUIMessages(_ stream: AsyncThrowingStream<AIUIMessage, Error>) async throws -> [AIUIMessage] {
    var messages: [AIUIMessage] = []
    for try await message in stream {
        messages.append(message)
    }
    return messages
}
