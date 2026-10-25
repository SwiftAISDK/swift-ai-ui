@testable import SwiftAIUI
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@MainActor
@Test func aiChatSessionSendsMessageAndStoresFinalSnapshot() async throws {
    let transport = RecordingChatTransport()
    let session = AIChatSession(
        chatID: "chat-1",
        transport: transport,
        generateMessageID: { "response-1" }
    )

    let task = session.sendMessage(
        "Hello",
        id: "user-1",
        options: AIChatSessionRequestOptions(
            headers: ["x-request": "1"],
            body: ["trace": .string("body")],
            metadata: ["source": "test"]
        )
    )
    await task.value

    let request = try #require(transport.sendRequests.first)
    #expect(request.chatID == "chat-1")
    #expect(request.trigger == .submitMessage)
    #expect(request.messageID == nil)
    #expect(request.responseMessageID == "response-1")
    #expect(request.headers == ["x-request": "1"])
    #expect(request.body["trace"]?.stringValue == "body")
    #expect(request.metadata?["source"]?.stringValue == "test")
    #expect(request.messages.map(\.id) == ["user-1"])
    #expect(session.status == .ready)
    #expect(session.error == nil)
    #expect(session.messages.map(\.id) == ["user-1", "response-1"])
    #expect(session.messages.last?.text == "Echo user-1")
}

@MainActor
@Test func aiChatSessionIncludesUserTextMessageMetadataLikeUpstreamChat() async throws {
    let transport = RecordingChatTransport()
    let session = AIChatSession(
        chatID: "chat-1",
        transport: transport,
        generateMessageID: { "response-1" }
    )

    await session.sendMessage(
        "Hello, world!",
        id: "user-1",
        metadata: ["someData": true]
    ).value

    let request = try #require(transport.sendRequests.first)
    #expect(request.messages.map(\.id) == ["user-1"])
    #expect(request.messages.first?.metadata["someData"]?.boolValue == true)
    #expect(session.messages.first?.id == "user-1")
    #expect(session.messages.first?.metadata["someData"]?.boolValue == true)
    #expect(session.messages.map(\.id) == ["user-1", "response-1"])
}

@MainActor
@Test func aiChatSessionReplacesUserMessageBeforeSending() async throws {
    let transport = RecordingChatTransport()
    let session = AIChatSession(
        chatID: "chat-1",
        transport: transport,
        messages: [
            .user("Old", id: "user-1"),
            .assistant(id: "assistant-1", parts: [.text(AIUITextPart(text: "Old answer"))]),
            .user("Later", id: "user-2")
        ],
        generateMessageID: { "response-1" }
    )

    await session.sendMessage("Edited", replacingMessageID: "user-1").value

    let request = try #require(transport.sendRequests.first)
    #expect(request.messageID == "user-1")
    #expect(request.messages.map(\.id) == ["user-1"])
    #expect(request.messages.first?.text == "Edited")
    #expect(session.messages.map(\.id) == ["user-1", "response-1"])
    #expect(session.messages.first?.text == "Edited")
}

@MainActor
@Test func aiChatSessionUsesExplicitNewIDWhenReplacingUserMessage() async throws {
    let transport = RecordingChatTransport()
    let session = AIChatSession(
        chatID: "chat-1",
        transport: transport,
        messages: [.user("Old", id: "user-1")],
        generateMessageID: { "response-1" }
    )

    await session.sendMessage(
        .user("Edited", id: "replacement-id"),
        replacingMessageID: "user-1"
    ).value

    let request = try #require(transport.sendRequests.first)
    #expect(request.messageID == "user-1")
    #expect(request.messages.map(\.id) == ["replacement-id"])
    #expect(session.messages.map(\.id) == ["replacement-id", "response-1"])
}

@MainActor
@Test func aiChatSessionCanSubmitExistingTranscriptWithoutNewUserMessage() async throws {
    let transport = RecordingChatTransport()
    let session = AIChatSession(
        transport: transport,
        messages: [.user("Hi", id: "user-1")],
        generateMessageID: { "response-1" }
    )

    await session.sendMessage(options: AIChatSessionRequestOptions(headers: ["x-submit": "1"])).value

    let request = try #require(transport.sendRequests.first)
    #expect(request.messageID == "user-1")
    #expect(request.headers == ["x-submit": "1"])
    #expect(request.messages.map(\.id) == ["user-1"])
    #expect(session.messages.map(\.id) == ["user-1", "response-1"])
}

@MainActor
@Test func aiChatSessionContinuesLastAssistantMessageIDLikeUpstreamGetResponseUIMessageID() async throws {
    let transport = RecordingChatTransport()
    let session = AIChatSession(
        transport: transport,
        messages: [
            .user("Continue this", id: "user-1"),
            .assistant(id: "assistant-1", parts: [.text(AIUITextPart(text: "This is"))])
        ],
        generateMessageID: {
            Issue.record("Continuation should reuse the last assistant message ID.")
            return "new-response"
        }
    )

    await session.sendMessage(options: AIChatSessionRequestOptions(headers: ["x-submit": "1"])).value

    let request = try #require(transport.sendRequests.first)
    #expect(request.messageID == "assistant-1")
    #expect(request.responseMessageID == "assistant-1")
    #expect(request.headers == ["x-submit": "1"])
    #expect(request.messages.map(\.id) == ["user-1", "assistant-1"])
    #expect(session.messages.map(\.id) == ["user-1", "assistant-1"])
    #expect(session.messages.last?.text == "Echo assistant-1")
}

@MainActor
@Test func aiChatSessionRegeneratesFromUserOrAssistantMessage() async throws {
    let transport = RecordingChatTransport()
    let ids = RecordingIDGenerator(["response-user", "response-assistant"])
    let session = AIChatSession(
        chatID: "chat-1",
        transport: transport,
        messages: [
            .user("One", id: "user-1"),
            .assistant(id: "assistant-1", parts: [.text(AIUITextPart(text: "Answer one"))]),
            .user("Two", id: "user-2"),
            .assistant(id: "assistant-2", parts: [.text(AIUITextPart(text: "Answer two"))])
        ],
        generateMessageID: { ids.next() }
    )

    await session.regenerate(messageID: "user-2").value
    #expect(transport.sendRequests[0].trigger == .regenerateMessage)
    #expect(transport.sendRequests[0].messageID == "user-2")
    #expect(transport.sendRequests[0].messages.map(\.id) == ["user-1", "assistant-1", "user-2"])
    #expect(session.messages.map(\.id) == ["user-1", "assistant-1", "user-2", "response-user"])

    await session.regenerate(messageID: "response-user").value
    #expect(transport.sendRequests[1].trigger == .regenerateMessage)
    #expect(transport.sendRequests[1].messageID == "response-user")
    #expect(transport.sendRequests[1].messages.map(\.id) == ["user-1", "assistant-1", "user-2"])
    #expect(session.messages.map(\.id) == ["user-1", "assistant-1", "user-2", "response-assistant"])
}

@MainActor
@Test func aiChatSessionResumeKeepsReadyWhenNoStreamExistsAndConsumesReconnectStream() async throws {
    let transport = RecordingChatTransport(reconnects: [nil, "resumed-message"])
    let events = RecordingSessionEvents()
    let session = AIChatSession(
        chatID: "chat-1",
        transport: transport,
        onFinish: { events.finishEvents.append($0) }
    )

    await session.resumeStream(options: AIChatSessionRequestOptions(headers: ["x-resume": "1"])).value
    #expect(session.status == .ready)
    #expect(session.messages.isEmpty)
    #expect(transport.reconnectRequests.first?.headers == ["x-resume": "1"])
    #expect(transport.reconnectRequests.first?.abortSignal != nil)
    #expect(events.finishEvents.isEmpty)

    await session.resumeStream().value
    #expect(session.status == .ready)
    #expect(session.messages.map(\.id) == ["resumed-message"])
    #expect(session.messages.first?.text == "Resumed resumed-message")
    #expect(events.finishEvents.count == 1)
    #expect(events.finishEvents.first?.message?.id == "resumed-message")
}

@MainActor
@Test func aiChatSessionAddsToolOutputAndApprovalResponses() {
    let session = AIChatSession(
        transport: RecordingChatTransport(),
        generateMessageID: { "tool-message" }
    )
    let result = AIToolResult(toolCallID: "call-1", toolName: "lookup", result: ["ok": true])
    let response = AIToolApprovalResponse(id: "approval-1", approved: true)

    session.addToolOutput(result)
    session.addToolApprovalResponse(response, id: "approval-message")

    #expect(session.messages[0].parts == [.toolResult(result)])
    #expect(session.messages[1].id == "approval-message")
    #expect(session.messages[1].parts == [.toolApprovalResponse(response)])
}

@MainActor
@Test func aiChatSessionClearErrorResetsStatusLikeUpstreamChat() async throws {
    let session = AIChatSession(
        transport: ErroringChatTransport(),
        generateMessageID: { "response-error" }
    )

    await session.sendMessage("Hi", id: "user-1").value
    #expect(session.status == .error)
    #expect(session.error != nil)

    session.clearError()

    #expect(session.status == .ready)
    #expect(session.error == nil)
}

@MainActor
@Test func aiChatSessionInvokesFinishAndErrorCallbacksLikeUpstreamChat() async throws {
    let finishEvents = RecordingSessionEvents()
    let success = AIChatSession(
        transport: RecordingChatTransport(),
        generateMessageID: { "response-1" },
        onFinish: { finishEvents.finishEvents.append($0) }
    )

    await success.sendMessage("Hi", id: "user-1").value

    let finish = try #require(finishEvents.finishEvents.first)
    #expect(finish.message?.id == "response-1")
    #expect(finish.messages.map(\.id) == ["user-1", "response-1"])
    #expect(finish.isAbort == false)
    #expect(finish.isDisconnect == false)
    #expect(finish.isError == false)

    let errorEvents = RecordingSessionEvents()
    let failure = AIChatSession(
        transport: ErroringChatTransport(),
        generateMessageID: { "response-error" },
        onError: { errorEvents.errors.append(String(describing: $0)) },
        onFinish: { errorEvents.finishEvents.append($0) }
    )

    await failure.sendMessage("Hi", id: "user-1").value

    #expect(failure.status == .error)
    #expect(errorEvents.errors.count == 1)
    let errorFinish = try #require(errorEvents.finishEvents.first)
    #expect(errorFinish.isError)
    #expect(errorFinish.message?.id == "response-error")
}

@MainActor
@Test func aiChatSessionStopMarksFinishEventAsAbortLikeUpstreamHandleUIMessageStreamFinish() async throws {
    let transport = PendingChatTransport()
    let events = RecordingSessionEvents()
    let session = AIChatSession(
        transport: transport,
        generateMessageID: { "response-1" },
        onFinish: { events.finishEvents.append($0) }
    )

    let task = session.sendMessage("Hi", id: "user-1")
    await waitUntil { session.status == .streaming }

    session.stop(reason: "manual abort")
    await task.value

    #expect(session.status == .ready)
    #expect(events.finishEvents.count == 1)
    let finish = try #require(events.finishEvents.first)
    #expect(finish.isAbort)
    #expect(finish.isError == false)
    #expect(finish.isDisconnect == false)
    #expect(finish.message?.id == "response-1")
    #expect(finish.messages.map(\.id) == ["user-1", "response-1"])
}

@MainActor
@Test func aiChatSessionRemainsSubmittedForMetadataOnlySnapshotUntilContentArrives() async throws {
    let transport = ControlledChatTransport()
    let session = AIChatSession(
        transport: transport,
        generateMessageID: { "response-1" }
    )

    let task = session.sendMessage("Hello", id: "user-1")
    await waitUntil { transport.didSend }

    transport.yield(.assistant(id: "response-1", metadata: ["model": "test-model"]))
    await waitUntil { session.messages.last?.metadata["model"]?.stringValue == "test-model" }
    #expect(session.status == .submitted)

    transport.yield(.assistant(
        id: "response-1",
        parts: [.text(AIUITextPart(id: "text-1", text: "", state: .streaming))],
        metadata: ["model": "test-model"]
    ))
    await waitUntil { session.status == .streaming }
    #expect(session.status == .streaming)

    transport.finish()
    await task.value
    #expect(session.status == .ready)
}

@MainActor
@Test func aiChatSessionRemainsSubmittedForMetadataOnlySnapshotWhenResumingExistingParts() async throws {
    let transport = ControlledChatTransport()
    let existingAssistant = AIUIMessage.assistant(
        id: "response-1",
        parts: [.text(AIUITextPart(id: "text-1", text: "Existing answer", state: .done))]
    )
    let session = AIChatSession(
        transport: transport,
        messages: [.user("Continue", id: "user-1"), existingAssistant],
        generateMessageID: {
            Issue.record("Continuation should reuse the existing assistant message ID.")
            return "unexpected-response"
        }
    )

    let task = session.sendMessage()
    await waitUntil { transport.didSend }

    transport.yield(.assistant(
        id: "response-1",
        parts: existingAssistant.parts,
        metadata: ["model": "test-model"]
    ))
    await waitUntil { session.messages.last?.metadata["model"]?.stringValue == "test-model" }
    #expect(session.status == .submitted)

    transport.yield(.assistant(
        id: "response-1",
        parts: [.text(AIUITextPart(id: "text-1", text: "Existing answer continued", state: .streaming))],
        metadata: ["model": "test-model"]
    ))
    await waitUntil { session.status == .streaming }
    #expect(session.status == .streaming)

    transport.finish()
    await task.value
    #expect(session.status == .ready)
}

@MainActor
@Test func aiChatSessionCanSendAutomaticallyAfterToolOutput() async throws {
    let transport = RecordingChatTransport()
    let ids = RecordingIDGenerator(["tool-message", "auto-response"])
    let session = AIChatSession(
        transport: transport,
        messages: [.assistant(id: "assistant-1")],
        generateMessageID: { ids.next() },
        sendAutomaticallyWhen: { messages in
            messages.last?.role == .tool
        }
    )
    let result = AIToolResult(toolCallID: "call-1", toolName: "lookup", result: ["ok": true])

    session.addToolOutput(result, options: AIChatSessionRequestOptions(headers: ["x-auto": "1"]))

    await waitUntil { transport.sendRequests.count == 1 }
    await waitUntil { session.status == .ready }

    let request = try #require(transport.sendRequests.first)
    #expect(request.messageID == "tool-message")
    #expect(request.headers == ["x-auto": "1"])
    #expect(request.messages.map(\.id) == ["assistant-1", "tool-message"])
    #expect(session.messages.map(\.id) == ["assistant-1", "tool-message", "auto-response"])
}

@MainActor
@Test func aiChatSessionForwardsOptionsWhenAutoSendingAfterToolApprovalResponseLikeUpstream() async throws {
    let transport = RecordingChatTransport()
    let ids = RecordingIDGenerator(["approval-message", "auto-response"])
    let session = AIChatSession(
        transport: transport,
        messages: [.assistant(id: "assistant-1")],
        generateMessageID: { ids.next() },
        sendAutomaticallyWhen: { messages in
            messages.last?.parts.contains(.toolApprovalResponse(AIToolApprovalResponse(id: "approval-1", approved: true))) == true
        }
    )
    let response = AIToolApprovalResponse(id: "approval-1", approved: true)

    session.addToolApprovalResponse(response, options: AIChatSessionRequestOptions(headers: ["x-auto": "approval"]))

    await waitUntil { transport.sendRequests.count == 1 }
    await waitUntil { session.status == .ready }

    let request = try #require(transport.sendRequests.first)
    #expect(request.messageID == "approval-message")
    #expect(request.headers == ["x-auto": "approval"])
    #expect(request.messages.map(\.id) == ["assistant-1", "approval-message"])
    #expect(session.messages.map(\.id) == ["assistant-1", "approval-message", "auto-response"])
}

private final class RecordingChatTransport: AIChatTransport, @unchecked Sendable {
    var sendRequests: [AIChatTransportRequest] = []
    var reconnectRequests: [AIChatReconnectRequest] = []
    private var reconnects: [String?]

    init(reconnects: [String?] = []) {
        self.reconnects = reconnects
    }

    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        sendRequests.append(request)
        let responseID = request.responseMessageID ?? "response"
        let text = "Echo \(request.messages.last?.id ?? "none")"
        return AsyncThrowingStream { continuation in
            continuation.yield(.assistant(id: responseID, parts: [.text(AIUITextPart(text: text))]))
            continuation.finish()
        }
    }

    func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>? {
        reconnectRequests.append(request)
        guard !reconnects.isEmpty else { return nil }
        guard let responseID = reconnects.removeFirst() else { return nil }
        return AsyncThrowingStream { continuation in
            continuation.yield(.assistant(id: responseID, parts: [.text(AIUITextPart(text: "Resumed \(responseID)"))]))
            continuation.finish()
        }
    }
}

private final class ErroringChatTransport: AIChatTransport, @unchecked Sendable {
    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        throw AIError.invalidResponse(provider: "test", message: "boom")
    }
}

private final class PendingChatTransport: AIChatTransport, @unchecked Sendable {
    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        let responseID = request.responseMessageID ?? "response"
        return AsyncThrowingStream { continuation in
            continuation.yield(.assistant(id: responseID, parts: [.text(AIUITextPart(text: "Starting"))]))
        }
    }
}

private final class ControlledChatTransport: AIChatTransport, @unchecked Sendable {
    private let stream: AsyncThrowingStream<AIUIMessage, Error>
    private let continuation: AsyncThrowingStream<AIUIMessage, Error>.Continuation
    private(set) var didSend = false

    init() {
        var capturedContinuation: AsyncThrowingStream<AIUIMessage, Error>.Continuation?
        stream = AsyncThrowingStream { capturedContinuation = $0 }
        continuation = capturedContinuation!
    }

    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        didSend = true
        return stream
    }

    func yield(_ message: AIUIMessage) {
        continuation.yield(message)
    }

    func finish() {
        continuation.finish()
    }
}

private final class RecordingSessionEvents: @unchecked Sendable {
    var finishEvents: [AIChatSessionFinishEvent] = []
    var errors: [String] = []
}

private final class RecordingIDGenerator: @unchecked Sendable {
    private var ids: [String]

    init(_ ids: [String]) {
        self.ids = ids
    }

    func next() -> String {
        ids.isEmpty ? UUID().uuidString : ids.removeFirst()
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @MainActor () -> Bool
) async {
    let start = DispatchTime.now().uptimeNanoseconds
    while !predicate() && DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        await Task.yield()
    }
}
