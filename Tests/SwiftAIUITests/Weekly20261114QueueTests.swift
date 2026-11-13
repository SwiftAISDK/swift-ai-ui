import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIUI

private final class QueueTransport: AIChatTransport, @unchecked Sendable {
    var requests: [AIChatTransportRequest] = []
    var continuations: [AsyncThrowingStream<AIUIMessage, Error>.Continuation] = []
    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuations.append($0) }
    }
    func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>? { nil }
    func finish(_ index: Int, reason: String = "stop", parts: [AIUIMessagePart]? = nil) {
        continuations[index].yield(.assistant(id: requests[index].responseMessageID ?? "response",
            parts: parts ?? [.text(.init(text: "answer"))], metadata: ["finishReason": .string(reason)]))
        continuations[index].finish()
    }
}
@MainActor private func queueWait(_ condition: () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition(), ContinuousClock.now - start < .seconds(2) { await Task.yield() }
    #expect(condition())
}

@Suite @MainActor struct Weekly20261114QueueTests {
    @Test func idleSendsImmediatelyAndQueuesFIFOWithPerMessageOptions() async throws {
        let transport = QueueTransport()
        let chat = AIChatSession(transport: transport, experimentalQueue: true)
        let first = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("second", id: "u2", metadata: ["source": "queued"], options: .init(headers: ["x-queue": "2"], body: ["q": 2], metadata: "request"))
        _ = chat.sendMessage("third", id: "u3")
        try await queueWait { transport.requests.count == 1 }
        #expect(chat.experimentalQueuedMessages.map(\.id) == ["u2", "u3"])
        #expect(!chat.messages.contains { $0.id == "u2" })
        transport.finish(0); await first.value
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[1].messages.last?.id == "u2")
        #expect(transport.requests[1].headers["x-queue"] == "2")
        #expect(transport.requests[1].body["q"] == 2)
        #expect(transport.requests[1].metadata == "request")
        #expect(transport.requests[1].messages.last?.metadata["source"] == "queued")
        transport.finish(1)
        try await queueWait { transport.requests.count == 3 }
        #expect(transport.requests[2].messages.last?.id == "u3")
        transport.finish(2)
        try await queueWait { !chat.isRunning }
        #expect(chat.experimentalQueuedMessages.isEmpty)
    }

    @Test func removingAnItemPreventsItsSend() async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport(), experimentalQueue: true)
        chat.transport = transport
        let task = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("removed", id: "u2")
        chat.experimentalRemoveQueuedMessage("u2")
        try await queueWait { transport.requests.count == 1 }
        transport.finish(0); await task.value
        #expect(chat.experimentalQueuedMessages.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: ["stop", "error", "interrupted"])
    func stopErrorAndInterruptedPauseUntilNextUserMessage(_ ending: String) async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport(), experimentalQueue: true)
        chat.transport = transport
        let task = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("second", id: "u2")
        try await queueWait { transport.requests.count == 1 }
        switch ending {
        case "stop": await chat.stopAndWait()
        case "error": transport.continuations[0].finish(throwing: URLError(.networkConnectionLost))
        default: transport.finish(0, reason: "interrupted")
        }
        await task.value
        #expect(transport.requests.count == 1)
        #expect(chat.experimentalQueuedMessages.map(\.id) == ["u2"])
        _ = chat.sendMessage("third", id: "u3")
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[1].messages.last?.id == "u2")
        transport.finish(1)
        try await queueWait { transport.requests.count == 3 }
        transport.finish(2)
        try await queueWait { !chat.isRunning }
    }

    @Test func sendingNowPrioritizesOneItemAndPreservesItsOptions() async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport(), experimentalQueue: true)
        chat.transport = transport
        _ = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("second", id: "u2")
        _ = chat.sendMessage("priority", id: "u3", options: .init(headers: ["x-now": "3"]))
        try await queueWait { transport.requests.count == 1 }
        let now = chat.experimentalSendQueuedMessageNow("u3")
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[0].abortSignal?.isAborted == true)
        #expect(transport.requests[1].messages.last?.id == "u3")
        #expect(transport.requests[1].headers["x-now"] == "3")
        transport.finish(1); await now.value
        try await queueWait { transport.requests.count == 3 }
        #expect(transport.requests[2].messages.last?.id == "u2")
        transport.finish(2)
        try await queueWait { !chat.isRunning }
    }

    @Test(arguments: [false, true])
    func historyChangesClearTheQueue(_ regenerate: Bool) async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport(), experimentalQueue: true)
        chat.transport = transport
        _ = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("discarded", id: "u2")
        try await queueWait { transport.requests.count == 1 }
        let replacement = regenerate ? chat.regenerate() : chat.sendMessage("edited", replacingMessageID: "u1")
        #expect(chat.experimentalQueuedMessages.isEmpty)
        try await queueWait { transport.requests.count == 2 }
        #expect(!transport.requests[1].messages.contains { $0.id == "u2" })
        transport.finish(1); await replacement.value
    }

    @Test func clientToolResultUnblocksQueueWithoutAutomaticPredicate() async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport(), experimentalQueue: true)
        chat.transport = transport
        let first = chat.sendMessage("first", id: "u1")
        try await queueWait { transport.requests.count == 1 }
        transport.finish(0, parts: [.toolCall(.init(id: "call", name: "weather", arguments: "{}"))])
        await first.value
        _ = chat.sendMessage("second", id: "u2")
        #expect(chat.experimentalQueuedMessages.count == 1)
        chat.addToolOutput(.init(toolCallID: "call", toolName: "weather", result: "sunny"))
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[1].messages.last?.id == "u2")
        transport.finish(1)
        try await queueWait { !chat.isRunning }
    }

    @Test func stoppedQueueIgnoresLateToolResultsAndTransportReplacementInvalidatesSendNow() async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport(), experimentalQueue: true)
        chat.transport = transport
        let first = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("second", id: "u2")
        try await queueWait { transport.requests.count == 1 }
        await chat.stopAndWait(); await first.value
        chat.addToolOutput(.init(toolCallID: "call", toolName: "weather", result: "sunny"))
        #expect(transport.requests.count == 1)
        let now = chat.experimentalSendQueuedMessageNow("u2")
        let replacement = QueueTransport()
        chat.transport = replacement
        await now.value
        #expect(replacement.requests.isEmpty)
        #expect(chat.experimentalQueuedMessages.map(\.id) == ["u2"])
    }

    @Test(arguments: [true, false])
    func approvalReplyIsSentBeforeQueueWithQueuedRequestOptions(_ approved: Bool) async throws {
        let transport = QueueTransport()
        let chat = AIChatSession(transport: transport, experimentalQueue: true)
        let first = chat.sendMessage("first", id: "u1")
        try await queueWait { transport.requests.count == 1 }
        transport.finish(0, parts: [
            .toolCall(.init(id: "call", name: "tool", arguments: "{}")),
            .toolApprovalRequest(.init(id: "approval", toolName: "tool", arguments: "{}", toolCallID: "call"))
        ])
        await first.value
        _ = chat.sendMessage("second", id: "u2")
        #expect(transport.requests.count == 1)
        chat.addToolApprovalResponse(.init(id: "approval", approved: approved))
        #expect(transport.requests.count == 1)
        _ = chat.sendMessage("third", id: "u3", options: .init(headers: ["x-approval": "reply"]))
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[1].headers["x-approval"] == "reply")
        #expect(!transport.requests[1].messages.contains { $0.id == "u2" })
        transport.finish(1)
        try await queueWait { transport.requests.count == 3 }
        #expect(transport.requests[2].messages.last?.id == "u2")
        transport.finish(2)
        try await queueWait { transport.requests.count == 4 }
        transport.finish(3)
        try await queueWait { !chat.isRunning }
    }

    @Test func removingTheQueuedUserMessageStillSendsItsDeferredApproval() async throws {
        let transport = QueueTransport()
        let chat = AIChatSession(transport: transport, experimentalQueue: true)
        let first = chat.sendMessage("first", id: "u1")
        try await queueWait { transport.requests.count == 1 }
        let parts: [AIUIMessagePart] = [
            .toolCall(.init(id: "call", name: "tool", arguments: "{}")),
            .toolApprovalRequest(.init(id: "approval", toolName: "tool", arguments: "{}", toolCallID: "call"))
        ]
        transport.continuations[0].yield(.assistant(id: transport.requests[0].responseMessageID ?? "a", parts: parts))
        try await queueWait { chat.status == .streaming }
        chat.addToolApprovalResponse(.init(id: "approval", approved: true))
        _ = chat.sendMessage("queued", id: "u2", options: .init(headers: ["x-deferred": "reply"]))
        chat.experimentalRemoveQueuedMessage("u2")
        transport.finish(0, parts: parts)
        await first.value
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[1].headers["x-deferred"] == "reply")
        #expect(!transport.requests[1].messages.contains { $0.id == "u2" })
        transport.finish(1)
        try await queueWait { !chat.isRunning }
    }

    @Test func stopDuringSendNowPreventsItsDelayedRequest() async throws {
        let transport = QueueTransport()
        let chat = AIChatSession(transport: transport, experimentalQueue: true)
        _ = chat.sendMessage("first", id: "u1")
        _ = chat.sendMessage("second", id: "u2")
        try await queueWait { transport.requests.count == 1 }
        let now = chat.experimentalSendQueuedMessageNow("u2")
        chat.stop()
        await now.value
        #expect(transport.requests.count == 1)
        #expect(chat.experimentalQueuedMessages.map(\.id) == ["u2"])
    }

    @Test func disabledQueueKeepsImmediateReplacementBehavior() async throws {
        let transport = QueueTransport(), chat = AIChatSession(transport: QueueTransport())
        chat.transport = transport
        let first = chat.sendMessage("first", id: "u1")
        try await queueWait { transport.requests.count == 1 }
        let second = chat.sendMessage("second", id: "u2")
        try await queueWait { transport.requests.count == 2 }
        #expect(transport.requests[0].abortSignal?.isAborted == true)
        #expect(chat.experimentalQueuedMessages.isEmpty)
        transport.finish(1); await first.value; await second.value
    }
}
