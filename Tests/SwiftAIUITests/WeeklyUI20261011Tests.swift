@testable import SwiftAIUI
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Suite("WeeklyUI20261011Tests")
struct WeeklyUI20261011Tests {
    @MainActor @Test func stopAndWaitDrainsPendingReconnectAndCancelsItsReturnedStream() async throws {
        let transport = WeeklyUIControlledTransport()
        let session = AIChatSession(transport: transport)
        let resume = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 1 }
        let stopped = WeeklyUIFlag()
        let stop = Task { await session.stopAndWait(); stopped.value = true }
        try await weeklyUIWait { transport.reconnectRequests.first?.abortSignal?.isAborted == true }
        #expect(!stopped.value)
        #expect(session.status == .ready)
        transport.resolveReconnect(0, snapshot: .assistant(id: "late", parts: [.text(.init(text: "after stop"))]))
        await stop.value
        await resume.value
        #expect(stopped.value)
        #expect(transport.cancelledReconnects == [0])
        #expect(session.messages.isEmpty)
    }

    @MainActor @Test func stopAndWaitAlsoDrainsSupersededReconnects() async throws {
        let transport = WeeklyUIControlledTransport()
        let session = AIChatSession(transport: transport)
        let first = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 1 }
        let second = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 2 }
        #expect(transport.reconnectRequests[0].abortSignal?.isAborted == true)
        let stopped = WeeklyUIFlag()
        let stop = Task { await session.stopAndWait(); stopped.value = true }
        try await weeklyUIWait { transport.reconnectRequests[1].abortSignal?.isAborted == true }
        transport.resolveReconnect(1)
        await second.value
        #expect(!stopped.value)
        transport.resolveReconnect(0)
        await first.value
        await stop.value
        #expect(stopped.value)
        #expect(session.messages.isEmpty)
    }

    @MainActor @Test func onlyLatestOverlappingReconnectCanPublishSnapshots() async throws {
        let transport = WeeklyUIControlledTransport()
        let session = AIChatSession(transport: transport)
        let first = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 1 }
        let second = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 2 }
        transport.resolveReconnect(0, snapshot: .assistant(id: "stale", parts: [.text(.init(text: "Old"))]))
        await first.value
        transport.resolveReconnect(1, snapshot: .assistant(id: "latest", parts: [.text(.init(text: "Fresh"))]), finished: true)
        await second.value
        #expect(session.messages.map(\.id) == ["latest"])
        #expect(session.messages.first?.text == "Fresh")
        #expect(transport.cancelledReconnects == [0])
    }

    @MainActor @Test func repeatedReconnectFailuresPublishTheLatestError() async throws {
        let transport = WeeklyUIControlledTransport()
        let session = AIChatSession(transport: transport)
        let first = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 1 }
        transport.resolveReconnect(0, error: WeeklyUIResumeError(description: "first failure"))
        await first.value
        let firstError = try #require(session.error)
        #expect(String(describing: firstError) == "first failure")
        let second = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 2 }
        transport.resolveReconnect(1, error: WeeklyUIResumeError(description: "second failure"))
        await second.value
        #expect(session.status == .error)
        let latestError = try #require(session.error)
        #expect(String(describing: latestError) == "second failure")
    }

    @MainActor @Test func queuedToolOutputCannotRestartWhileStopIsWaiting() async throws {
        let transport = WeeklyUIControlledTransport()
        let session = AIChatSession(
            transport: transport,
            messages: [.assistant(id: "assistant", parts: [.toolCall(.init(id: "call", name: "search", arguments: "{}"))])],
            sendAutomaticallyWhen: { _ in true }
        )
        let resume = session.resumeStream()
        try await weeklyUIWait { transport.reconnectRequests.count == 1 }
        let stop = Task { await session.stopAndWait() }
        try await weeklyUIWait { transport.reconnectRequests.first?.abortSignal?.isAborted == true }
        session.addToolOutput(.init(toolCallID: "call", toolName: "search", result: ["ok": true]), id: "tool")
        #expect(transport.sendRequests.isEmpty)
        transport.resolveReconnect(0)
        await resume.value
        await stop.value
        #expect(transport.sendRequests.isEmpty)
        #expect(session.messages.last?.id == "tool")
    }

    @MainActor @Test func disposeWaitsBeforeClosingTheTransportItCaptured() async throws {
        let original = WeeklyUIControlledTransport()
        let replacement = WeeklyUIImmediateTransport()
        let session = AIChatSession(transport: original)
        let resume = session.resumeStream()
        try await weeklyUIWait { original.reconnectRequests.count == 1 }
        let disposal = Task { await session.dispose() }
        try await weeklyUIWait { original.reconnectRequests.first?.abortSignal?.isAborted == true }
        #expect(original.closeCount == 0)
        session.transport = replacement
        original.resolveReconnect(0)
        await resume.value
        await disposal.value
        #expect(original.closeCount == 1)
        #expect(replacement.closeCount == 0)
    }

    @MainActor @Test func synchronousStopAndDefaultTransportCloseRemainCallable() async throws {
        let transport = WeeklyUIDefaultCloseTransport()
        await transport.close()
        let session = AIChatSession(transport: transport)
        let task = session.sendMessage("Hello", id: "user")
        session.stop()
        await task.value
        await session.stopAndWait()
        await session.dispose()
        #expect(session.status == .ready)
    }

    @MainActor @Test func synchronousStopBeforeRequestPreparationPreventsSending() async throws {
        let transport = WeeklyUIImmediateTransport()
        let session = AIChatSession(transport: transport)
        let task = session.sendMessage("Hello", id: "user")
        session.stop()
        await task.value
        #expect(transport.sendRequests.isEmpty)
        #expect(session.status == .ready)
    }

    @MainActor @Test func reentrantStopInsideAutomaticPredicatePreventsRestart() async throws {
        let transport = WeeklyUIImmediateTransport()
        let box = WeeklyUISessionBox()
        let session = AIChatSession(transport: transport, sendAutomaticallyWhen: { _ in
            box.session?.stop()
            return true
        })
        box.session = session
        await session.sendMessage("Hello", id: "user").value
        #expect(transport.sendRequests.count == 1)
        #expect(session.status == .ready)
    }

    @MainActor @Test func stopFromFinishCallbackPreventsAutomaticRestart() async throws {
        let transport = WeeklyUIImmediateTransport()
        let box = WeeklyUISessionBox()
        let session = AIChatSession(
            transport: transport,
            onFinish: { _ in box.session?.stop() },
            sendAutomaticallyWhen: { _ in true }
        )
        box.session = session
        await session.sendMessage("Hello", id: "user").value
        #expect(transport.sendRequests.count == 1)
        #expect(session.status == .ready)
    }

    @MainActor @Test(arguments: [false, true])
    func nativeResumeSnapshotsReplaceReplaysAndKeepSeparateResponses(separate: Bool) async throws {
        let responseID = separate ? "new" : "same"
        let replay = AIUIMessage.assistant(id: responseID, parts: [.text(.init(text: "Fresh"))], metadata: ["fresh": true])
        let transport = WeeklyUIImmediateTransport(reconnects: [[replay]])
        let session = AIChatSession(transport: transport, messages: [.assistant(id: "same", parts: [.text(.init(text: "Stale"))], metadata: ["stale": true])])
        await session.resumeStream().value
        #expect(session.messages.last?.id == responseID)
        #expect(session.messages.last?.text == "Fresh")
        #expect(session.messages.last?.metadata["stale"] == nil)
        #expect(session.messages.count == (separate ? 2 : 1))
        if separate { #expect(session.messages.first?.text == "Stale") }
    }

    @Test(arguments: [false, true])
    func unavailableStaticHistoryRetainsProvenanceAndOmitsSuccessfulRawOutput(split: Bool) throws {
        let history = weeklyUIHistory(split: split)
        #expect(try validateUIMessages(history) == history)
        let normalized = try validateUIMessages(history, toolSchemas: [:])
        #expect(normalized[0].unavailableStaticToolCallIDs == ["call"])
        let normalizedResult = try weeklyUIResult(in: normalized)
        #expect(normalizedResult.dynamic)
        #expect(normalizedResult.result == weeklyUIPrivateOutput)
        let savedIDs = try JSONEncoder().encode(normalized.map(\.unavailableStaticToolCallIDs))
        let reloadedIDs = try JSONDecoder().decode([Set<String>].self, from: savedIDs)
        var reloaded = normalized
        for index in reloaded.indices { reloaded[index].unavailableStaticToolCallIDs = reloadedIDs[index] }
        let revalidated = try validateUIMessages(reloaded, toolSchemas: [:])
        let result = try weeklyUIModelResult(in: convertToModelMessages(revalidated))
        #expect(result.result == "Tool output omitted because the tool is no longer available.")
        #expect(result.modelOutput == ["type": "text", "value": "Tool output omitted because the tool is no longer available."])
        #expect(result.providerMetadata == ["test": ["retained": true]])
    }

    @Test func restoredToolUsesItsCurrentConverterAndPreservesContext() async throws {
        let recorder = WeeklyUIConverterRecorder()
        let tool = weeklyUITool(recorder: recorder)
        let normalized = try validateUIMessages(weeklyUIHistory(), toolSchemas: [:])
        let before = normalized
        let model = try await convertToModelMessages(normalized, tools: ["search": tool])
        let result = try weeklyUIModelResult(in: model)
        #expect(result.modelOutput == ["type": "text", "value": "sunny"])
        let context = try #require(await recorder.contexts().first)
        #expect(context.toolCallID == "call")
        #expect(context.input == ["query": "weather"])
        #expect(context.output == weeklyUIPrivateOutput)
        #expect(normalized == before)
    }

    @Test func unavailablePreliminaryOutputAlsoRetainsItsStaticOrigin() throws {
        var history = weeklyUIHistory()
        guard case var .toolResult(result) = history[0].parts[1] else { return }
        result.preliminary = true
        history[0].parts[1] = .toolResult(result)
        let normalized = try validateUIMessagesForAgent(history)
        #expect(normalized[0].unavailableStaticToolCallIDs == ["call"])
        #expect(try weeklyUIModelResult(in: convertToModelMessages(normalized)).result == "Tool output omitted because the tool is no longer available.")
    }

    @Test func restoredToolWithoutConverterUsesItsOriginalJSONOutput() async throws {
        var history = weeklyUIHistory()
        guard case var .toolResult(result) = history[0].parts[1] else { return }
        result.modelOutput = ["type": "text", "value": "old converter"]
        history[0].parts[1] = .toolResult(result)
        let normalized = try validateUIMessages(history, toolSchemas: [:])
        let tool = AITool(name: "search", parameters: weeklyUIInputSchema, execute: { _ in .null })
        let restored = try weeklyUIModelResult(in: await convertToModelMessages(normalized, tools: ["search": tool]))
        #expect(restored.result == weeklyUIPrivateOutput)
        #expect(restored.modelOutput == nil)
    }

    @Test func ignoredPreliminaryOutputNeverRunsTheCurrentConverter() async throws {
        var history = weeklyUIHistory()
        guard case var .toolResult(result) = history[0].parts[1] else { return }
        result.preliminary = true
        history[0].parts[1] = .toolResult(result)
        let recorder = WeeklyUIConverterRecorder()
        let model = try await convertToModelMessages(
            history,
            tools: ["search": weeklyUITool(recorder: recorder)],
            ignoreIncompleteToolCalls: true
        )
        #expect(model.isEmpty)
        #expect(await recorder.contexts().isEmpty)
    }

    @Test func realDynamicOutputAndErrorResultsArePreserved() async throws {
        var dynamicHistory = weeklyUIHistory(dynamic: true)
        guard case var .toolResult(dynamicResult) = dynamicHistory[0].parts[1] else { return }
        dynamicResult.modelOutput = ["type": "text", "value": "dynamic converter"]
        dynamicHistory[0].parts[1] = .toolResult(dynamicResult)
        let dynamic = try validateUIMessages(dynamicHistory, toolSchemas: [:])
        #expect(dynamic.allSatisfy { $0.unavailableStaticToolCallIDs.isEmpty })
        let dynamicModelResult = try weeklyUIModelResult(in: await convertToModelMessages(dynamic, tools: [:]))
        #expect(dynamicModelResult.result == weeklyUIPrivateOutput)
        #expect(dynamicModelResult.modelOutput == ["type": "text", "value": "dynamic converter"])
        let recorder = WeeklyUIConverterRecorder()
        let failed = try validateUIMessages(weeklyUIHistory(error: true), toolSchemas: [:])
        let model = try await convertToModelMessages(failed, tools: ["search": weeklyUITool(recorder: recorder)])
        let result = try weeklyUIModelResult(in: model)
        #expect(result.isError)
        #expect(result.result == weeklyUIPrivateOutput)
        #expect(await recorder.contexts().isEmpty)
    }

    @Test func schemaAwareValidationDistinguishesFailedEmptyAndInvalidCurrentInputs() throws {
        let schemas = ["search": AIUIMessageToolSchema(inputSchema: weeklyUIInputSchema)]
        let failed = try validateUIMessages(weeklyUIHistory(arguments: #"{"query":1}"#, error: true), toolSchemas: schemas)
        #expect(failed[0].unavailableStaticToolCallIDs == ["call"])
        let empty = try validateUIMessages(weeklyUIHistory(arguments: "{}"), toolSchemas: schemas)
        #expect(empty[0].unavailableStaticToolCallIDs == ["call"])
        #expect(!safeValidateUIMessages(weeklyUIHistory(arguments: #"{"query":1}"#), toolSchemas: schemas).isValid)
        #expect(!safeValidateUIMessages(weeklyUIHistory(arguments: "not JSON", error: true), toolSchemas: schemas).isValid)
        let pending = [AIUIMessage.assistant(id: "pending", parts: [.toolCall(.init(id: "call", name: "search", arguments: "{}"))])]
        #expect(!safeValidateUIMessages(pending, toolSchemas: [:]).isValid)
    }

    @Test func outputSchemaErrorsHaveTheActualSplitResultPath() {
        let schemas = ["search": AIUIMessageToolSchema(inputSchema: weeklyUIInputSchema, outputSchema: ["type": "string"])]
        let result = safeValidateUIMessages(weeklyUIHistory(split: true), toolSchemas: schemas)
        #expect(!result.isValid)
        #expect(result.issues.first?.path == "messages[1].parts[0].toolResult.result")
    }

    @Test func preservedApprovalInputMustReconstructTheCurrentArguments() async throws {
        let history = weeklyUIApprovalHistory()
        let schemas = ["search": AIUIMessageToolSchema(inputSchema: weeklyUIInputSchema)]
        let identity = safeValidateUIMessages(history, toolSchemas: schemas)
        #expect(!identity.isValid)
        #expect(identity.issues.first?.message == "Tool input does not match the output reconstructed from inputSchemaInput.")
        let refiners: [String: AIUIMessageToolInputRefiner] = ["search": { input in
            await Task.yield()
            let query = input["query"]?.stringValue ?? ""
            return ["query": .string(query.trimmingCharacters(in: .whitespacesAndNewlines))]
        }]
        let reconstructed = try await validateUIMessages(history, toolSchemas: schemas, refineToolInput: refiners)
        #expect(reconstructed == history)
        var tampered = history
        guard case var .toolCall(call) = tampered[0].parts[0] else { return }
        call.arguments = #"{"query":"tampered"}"#
        tampered[0].parts[0] = .toolCall(call)
        #expect(!(await safeValidateUIMessages(tampered, toolSchemas: schemas, refineToolInput: refiners)).isValid)
        let failing: [String: AIUIMessageToolInputRefiner] = ["search": { _ in throw WeeklyUIWaitTimeout() }]
        #expect(!(await safeValidateUIMessages(history, toolSchemas: schemas, refineToolInput: failing)).isValid)
    }

    @Test func directTransportReconstructsApprovedInputWithCurrentToolRefiner() async throws {
        let model = WeeklyUIRecordingLanguageModel()
        let tool = AITool(name: "search", parameters: weeklyUIInputSchema, refineArguments: { input in
            ["query": .string((input["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))]
        }, execute: { _ in .null })
        let transport = DirectAIChatTransport(model: model, executableTools: [tool])
        let stream = try transport.sendMessages(.init(chatID: "chat", messages: weeklyUIApprovalHistory()))
        for try await _ in stream {}
        let request = try #require(model.requests.first)
        let call = try #require(request.messages.flatMap(\.content).compactMap { part -> AIToolCall? in
            guard case let .toolCall(call) = part else { return nil }
            return call
        }.first)
        #expect(call.arguments == #"{"query":"weather"}"#)
    }

    @Test func agentHistoryNormalizesMissingTerminalToolsAndKeepsDenialOutput() throws {
        let call = AIToolCall(id: "call", name: "search", arguments: "{}")
        let approval = AIToolApprovalRequest(id: "approval", toolName: "search", arguments: "{}", toolCallID: "call")
        let history = [
            AIUIMessage.assistant(id: "assistant", parts: [
                .toolCall(call), .toolApprovalRequest(approval),
                .toolApprovalResponse(.init(id: "approval", approved: false, reason: "denied"))
            ])
        ]
        let normalized = try validateUIMessagesForAgent(history)
        #expect(normalized[0].unavailableStaticToolCallIDs == ["call"])
        let result = try weeklyUIModelResult(in: convertToModelMessages(normalized))
        #expect(result.result["type"] == "execution-denied")
        #expect(result.result["reason"] == "denied")
    }

    @Test func reducerPreservesNativeProvenanceAcrossSnapshotCopies() throws {
        let normalized = try validateUIMessages(weeklyUIHistory(), toolSchemas: [:])
        var reducer = AIUIMessageStreamReducer(message: normalized[0])
        let snapshot = try reducer.consume(.textDelta("continued"))
        #expect(snapshot.unavailableStaticToolCallIDs == ["call"])
        #expect(try weeklyUIModelResult(in: convertToModelMessages([snapshot])).result == "Tool output omitted because the tool is no longer available.")
    }

    @MainActor @Test func replacingMessagesPreservesNativeProvenance() async throws {
        let transport = WeeklyUIImmediateTransport()
        let session = AIChatSession(transport: transport, messages: [.user("old", id: "user")])
        let replacement = AIUIMessage(id: "user", role: .user, parts: [.text(.init(text: "replacement"))], unavailableStaticToolCallIDs: ["call"])
        await session.sendMessage(replacement, replacingMessageID: "user").value
        #expect(transport.sendRequests.first?.messages.first?.unavailableStaticToolCallIDs == ["call"])
    }

    @Test func directTransportOmitsRemovedStaticOutputBeforeCallingModel() async throws {
        let model = WeeklyUIRecordingLanguageModel()
        let transport = DirectAIChatTransport(model: model)
        let stream = try transport.sendMessages(.init(chatID: "chat", messages: weeklyUIHistory()))
        for try await _ in stream {}
        let request = try #require(model.requests.first)
        let result = try weeklyUIModelResult(in: request.messages)
        #expect(result.result == "Tool output omitted because the tool is no longer available.")
    }

    @Test func preAbortedDirectTransportDoesNotRunHistoryConvertersOrCallModel() async throws {
        let recorder = WeeklyUIConverterRecorder()
        let model = WeeklyUIRecordingLanguageModel()
        let controller = AIAbortController()
        controller.abort()
        let transport = DirectAIChatTransport(model: model, executableTools: [weeklyUITool(recorder: recorder)])
        let stream = try transport.sendMessages(.init(chatID: "chat", messages: weeklyUIHistory(), abortSignal: controller.signal))
        var aborted = false
        do {
            for try await _ in stream {}
        } catch is AIAbortError {
            aborted = true
        }
        #expect(aborted)
        #expect(await recorder.contexts().isEmpty)
        #expect(model.requests.isEmpty)
    }
}

private let weeklyUIPrivateOutput: JSONValue = ["summary": "sunny", "privateMetadata": "must-not-reach-the-model"]
private let weeklyUIInputSchema: JSONValue = ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]

private func weeklyUIHistory(arguments: String = #"{"query":"weather"}"#, dynamic: Bool = false, error: Bool = false, split: Bool = false) -> [AIUIMessage] {
    let call = AIToolCall(id: "call", name: "search", arguments: arguments, dynamic: dynamic)
    let result = AIToolResult(toolCallID: "call", toolName: "search", result: weeklyUIPrivateOutput, isError: error, dynamic: dynamic, providerMetadata: ["test": ["retained": true]])
    if split {
        return [.assistant(id: "assistant", parts: [.toolCall(call)]), .init(id: "result", role: .tool, parts: [.toolResult(result)])]
    }
    return [.assistant(id: "assistant", parts: [.toolCall(call), .toolResult(result)])]
}

private func weeklyUIApprovalHistory() -> [AIUIMessage] {
    let call = AIToolCall(id: "call", name: "search", arguments: #"{"query":"weather"}"#)
    let approval = AIToolApprovalRequest(
        id: "approval", toolName: "search", arguments: call.arguments,
        toolCallID: call.id, inputSchemaInput: ["query": " weather "]
    )
    return [
        .assistant(id: "assistant", parts: [.toolCall(call), .toolApprovalRequest(approval)]),
        .init(id: "approved", role: .tool, parts: [.toolApprovalResponse(.init(id: "approval", approved: true))])
    ]
}

private func weeklyUIResult(in messages: [AIUIMessage]) throws -> AIToolResult {
    try #require(messages.flatMap(\.parts).compactMap { part -> AIToolResult? in
        guard case let .toolResult(result) = part else { return nil }
        return result
    }.first)
}

private func weeklyUIModelResult(in messages: [AIMessage]) throws -> AIToolResult {
    try #require(messages.flatMap(\.content).compactMap { part -> AIToolResult? in
        guard case let .toolResult(result) = part else { return nil }
        return result
    }.first)
}

private func weeklyUITool(recorder: WeeklyUIConverterRecorder) -> AITool {
    AITool(name: "search", parameters: weeklyUIInputSchema, toModelOutput: { context in
        await recorder.record(context)
        return .object(["type": .string("text"), "value": context.output["summary"] ?? .null])
    }, execute: { _ in
        Issue.record("Historical conversion must not execute a tool.")
        return .null
    })
}

private actor WeeklyUIConverterRecorder {
    private var recorded: [AIToolModelOutputContext] = []
    func record(_ context: AIToolModelOutputContext) { recorded.append(context) }
    func contexts() -> [AIToolModelOutputContext] { recorded }
}

@MainActor private final class WeeklyUIFlag { var value = false }
@MainActor private final class WeeklyUISessionBox { weak var session: AIChatSession? }

private final class WeeklyUIControlledTransport: AIChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sends: [AIChatTransportRequest] = []
    private var reconnects: [AIChatReconnectRequest] = []
    private var waiters: [Int: CheckedContinuation<AsyncThrowingStream<AIUIMessage, Error>?, Error>] = [:]
    private var cancellations: Set<Int> = []
    private var closes = 0
    var sendRequests: [AIChatTransportRequest] { lock.withLock { sends } }
    var reconnectRequests: [AIChatReconnectRequest] { lock.withLock { reconnects } }
    var cancelledReconnects: Set<Int> { lock.withLock { cancellations } }
    var closeCount: Int { lock.withLock { closes } }

    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        lock.withLock { sends.append(request) }
        return AsyncThrowingStream { $0.finish() }
    }

    func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                let index = reconnects.count
                reconnects.append(request)
                waiters[index] = continuation
            }
        }
    }

    func resolveReconnect(_ index: Int, snapshot: AIUIMessage? = nil, finished: Bool = false, error: Error? = nil) {
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: index) }) else { return }
        if let error { waiter.resume(throwing: error); return }
        guard let snapshot else { waiter.resume(returning: nil); return }
        let stream = AsyncThrowingStream<AIUIMessage, Error> { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination { self.lock.withLock { _ = self.cancellations.insert(index) } }
            }
            continuation.yield(snapshot)
            if finished { continuation.finish() }
        }
        waiter.resume(returning: stream)
    }

    func close() async { lock.withLock { closes += 1 } }
}

private final class WeeklyUIImmediateTransport: AIChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sends: [AIChatTransportRequest] = []
    private var reconnects: [[AIUIMessage]]
    private var closes = 0
    var sendRequests: [AIChatTransportRequest] { lock.withLock { sends } }
    var closeCount: Int { lock.withLock { closes } }
    init(reconnects: [[AIUIMessage]] = []) { self.reconnects = reconnects }
    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        lock.withLock { sends.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.assistant(id: request.responseMessageID ?? "response", parts: [.text(.init(text: "Done"))]))
            continuation.finish()
        }
    }
    func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>? {
        guard let snapshots = lock.withLock({ reconnects.isEmpty ? nil : reconnects.removeFirst() }) else { return nil }
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }
    func close() async { lock.withLock { closes += 1 } }
}

private struct WeeklyUIDefaultCloseTransport: AIChatTransport {
    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class WeeklyUIRecordingLanguageModel: LanguageModel, @unchecked Sendable {
    let providerID = "test"
    let modelID = "model"
    private let lock = NSLock()
    private var recorded: [LanguageModelRequest] = []
    var requests: [LanguageModelRequest] { lock.withLock { recorded } }
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        lock.withLock { recorded.append(request) }
        return TextGenerationResult(text: "Done", finishReason: "stop", rawValue: .null)
    }
    func stream(_ request: LanguageModelRequest) throws -> AsyncThrowingStream<LanguageStreamPart, Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Done"))
            continuation.yield(.finish(reason: "stop", usage: nil))
            continuation.finish()
        }
    }
}

@MainActor private func weeklyUIWait(_ predicate: @MainActor () -> Bool) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
        guard DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000 else {
            throw WeeklyUIWaitTimeout()
        }
        await Task.yield()
    }
}
private struct WeeklyUIWaitTimeout: Error {}
private struct WeeklyUIResumeError: Error, CustomStringConvertible {
    let description: String
}
