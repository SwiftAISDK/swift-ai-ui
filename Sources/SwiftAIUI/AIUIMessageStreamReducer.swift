import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public enum AIUIMessageStreamOutcome: String, Equatable, Hashable, Sendable {
    case completed
    case aborted
    case failed
    case unknown
}

public struct AIUIMessageStreamEndEvent: Equatable, Sendable {
    public var message: AIUIMessage
    public var isAborted: Bool
    public var isCancelled: Bool
    public var outcome: AIUIMessageStreamOutcome
    public var errorDescription: String?

    public init(
        message: AIUIMessage,
        isAborted: Bool,
        isCancelled: Bool,
        outcome: AIUIMessageStreamOutcome,
        errorDescription: String? = nil
    ) {
        self.message = message
        self.isAborted = isAborted
        self.isCancelled = isCancelled
        self.outcome = outcome
        self.errorDescription = errorDescription
    }
}

private actor AIUIMessageStreamLifecycleState {
    private var message: AIUIMessage
    private var didEnd = false

    init(message: AIUIMessage) {
        self.message = message
    }

    func update(_ message: AIUIMessage) {
        self.message = message
    }

    func claimEnd(
        outcome: AIUIMessageStreamOutcome,
        isAborted: Bool = false,
        isCancelled: Bool = false,
        errorDescription: String? = nil
    ) -> AIUIMessageStreamEndEvent? {
        guard !didEnd else { return nil }
        didEnd = true
        return AIUIMessageStreamEndEvent(
            message: message,
            isAborted: isAborted,
            isCancelled: isCancelled,
            outcome: outcome,
            errorDescription: errorDescription
        )
    }
}

public struct AIUIMessageStreamReducer: Sendable {
    public private(set) var message: AIUIMessage

    private var textPartIndexes: [String: Int] = [:]
    private var reasoningPartIndexes: [String: Int] = [:]
    private var toolCallPartIndexes: [String: Int] = [:]
    private var activeToolInputIDs: Set<String> = []
    private var fallbackToolCallIDsByIndex: [Int: String] = [:]
    private var fallbackToolCallCounter = 0
    private var streamNormalizer = LanguageStreamNormalizer(providerID: "ui-message-stream")

    public init(message: AIUIMessage = .assistant()) {
        self.message = message
        for (index, part) in message.parts.enumerated() {
            switch part {
            case let .text(text) where text.state == .streaming:
                textPartIndexes[text.id ?? "$default"] = index
            case let .reasoning(reasoning) where reasoning.state == .streaming:
                reasoningPartIndexes[reasoning.id ?? "$default"] = index
            case let .toolCall(call):
                toolCallPartIndexes[call.id] = index
                if call.rawInputText != nil || (try? decodeJSONBody(Data(call.arguments.utf8))) == nil { activeToolInputIDs.insert(call.id) }
            default: break
            }
        }
    }

    @discardableResult
    public mutating func consume(_ part: LanguageStreamPart) throws -> AIUIMessage {
        for normalizedPart in try streamNormalizer.normalize(part) {
            try consumeCanonical(normalizedPart)
        }
        return message
    }

    private mutating func consumeCanonical(_ part: LanguageStreamPart) throws {
        switch part {
        case let .streamStart(warnings):
            if !warnings.isEmpty {
                message.metadata["warnings"] = .array(warnings.map(warningJSON))
            }
        case let .textStart(id, providerMetadata):
            ensureTextPart(id: id, providerMetadata: providerMetadata)
        case let .textDelta(delta):
            appendText(delta, id: nil)
        case let .textDeltaPart(id, delta, providerMetadata):
            try appendTextDeltaPart(delta, id: id, providerMetadata: providerMetadata)
        case let .textEnd(id, providerMetadata):
            try endTextPart(id: id, providerMetadata: providerMetadata)
        case let .textEndWithCitations(id, citations, providerMetadata):
            try endTextPart(id: id, providerMetadata: providerMetadata, citations: citations)
        case let .reasoningStart(id, providerMetadata):
            ensureReasoningPart(id: id, providerMetadata: providerMetadata)
        case let .reasoningDelta(delta):
            appendReasoning(delta, id: nil)
        case let .reasoningDeltaPart(id, delta, providerMetadata):
            try appendReasoningDeltaPart(delta, id: id, providerMetadata: providerMetadata)
        case let .reasoningEnd(id, providerMetadata):
            try endReasoningPart(id: id, providerMetadata: providerMetadata)
        case let .toolInputStart(id, name, providerExecuted, dynamic, title, providerMetadata),
             let .toolInputStartText(id, name, providerExecuted, dynamic, title, providerMetadata):
            ensureToolCallPart(
                id: id,
                name: name,
                providerExecuted: providerExecuted,
                dynamic: dynamic,
                title: title,
                providerMetadata: providerMetadata
            )
            if part.inputEncoding == .text, let index = toolCallPartIndexes[id], case var .toolCall(call) = message.parts[index] {
                call.inputEncoding = .text
                call.rawInputText = ""
                call.arguments = canonicalJSONText(.string("")) ?? "\"\""
                message.parts[index] = .toolCall(call)
            }
            activeToolInputIDs.insert(id)
        case let .toolInputDelta(id, delta, providerMetadata):
            try appendToolInputDelta(delta, id: id, providerMetadata: providerMetadata)
        case let .toolInputEnd(id, providerMetadata):
            try endToolInput(id: id, providerMetadata: providerMetadata)
        case let .toolCallDelta(id, name, argumentsDelta, index):
            appendToolCallDelta(id: id, name: name, argumentsDelta: argumentsDelta, index: index)
        case let .toolCall(call):
            upsertToolCall(call)
        case let .toolResult(result):
            message.parts.append(.toolResult(result))
        case let .toolApprovalRequest(request):
            message.parts.append(.toolApprovalRequest(request))
        case let .toolApprovalResponse(response):
            message.parts.append(.toolApprovalResponse(response))
        case let .file(file):
            message.parts.append(.file(file))
        case let .reasoningFile(file):
            message.parts.append(.reasoningFile(file))
        case let .custom(value, providerMetadata):
            message.parts.append(.custom(value, providerMetadata: providerMetadata))
        case let .source(source):
            message.parts.append(.source(source))
        case let .metadata(metadata):
            message.metadata.merge(metadata) { _, new in new }
            message.parts.append(.metadata(metadata))
        case let .responseMetadata(metadata):
            message.metadata["response"] = responseMetadataJSON(metadata)
        case let .raw(value):
            message.parts.append(.raw(value))
        case let .error(errorMessage, rawValue):
            message.parts.append(.error(message: errorMessage, rawValue: rawValue))
        case let .finish(reason, usage):
            recordFinish(reason: reason, usage: usage, providerMetadata: [:])
        case let .finishMetadata(reason, usage, providerMetadata):
            recordFinish(reason: reason, usage: usage, providerMetadata: providerMetadata)
        }
    }

    @discardableResult
    public mutating func consume<S: Sequence>(contentsOf parts: S) throws -> AIUIMessage where S.Element == LanguageStreamPart {
        for part in parts {
            try consume(part)
        }
        finishNormalization()
        return message
    }

    /// Source-compatible stream entry point retained from SwiftAISDK 1.9.0.
    public static func snapshots(
        from stream: AsyncThrowingStream<LanguageStreamPart, Error>,
        messageID: String = UUID().uuidString,
        terminateOnError: Bool = false
    ) -> AsyncThrowingStream<AIUIMessage, Error> {
        snapshots(
            from: stream,
            messageID: messageID,
            terminateOnError: terminateOnError,
            originalMessage: nil,
            onEnd: nil
        )
    }

    public static func snapshots(
        from stream: AsyncThrowingStream<LanguageStreamPart, Error>,
        messageID: String = UUID().uuidString,
        terminateOnError: Bool = false,
        originalMessage: AIUIMessage? = nil,
        onEnd: (@Sendable (AIUIMessageStreamEndEvent) async -> Void)? = nil
    ) -> AsyncThrowingStream<AIUIMessage, Error> {
        AsyncThrowingStream { continuation in
            let initialMessage = originalMessage ?? .assistant(id: messageID)
            let lifecycle = AIUIMessageStreamLifecycleState(message: initialMessage)
            let task = Task {
                var reducer = AIUIMessageStreamReducer(message: initialMessage)
                do {
                    for try await part in stream {
                        try Task.checkCancellation()
                        if terminateOnError, case let .error(message, _) = part {
                            throw AIUIMessageStreamError(message: message, chunkType: "error")
                        }
                        let snapshot = try reducer.consume(part)
                        await lifecycle.update(snapshot)
                        continuation.yield(snapshot)
                    }
                    if reducer.finishNormalization() {
                        await lifecycle.update(reducer.message)
                        continuation.yield(reducer.message)
                    }
                    if let event = await lifecycle.claimEnd(outcome: .completed) {
                        await onEnd?(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    if let event = await lifecycle.claimEnd(
                        outcome: .unknown,
                        isCancelled: true
                    ) {
                        await onEnd?(event)
                    }
                    continuation.finish()
                } catch let error as AIAbortError {
                    if let event = await lifecycle.claimEnd(
                        outcome: .aborted,
                        isAborted: true,
                        errorDescription: String(describing: error)
                    ) {
                        await onEnd?(event)
                    }
                    continuation.finish(throwing: error)
                } catch let error as AIUIMessageStreamError {
                    if let event = await lifecycle.claimEnd(
                        outcome: .failed,
                        errorDescription: String(describing: error)
                    ) {
                        await onEnd?(event)
                    }
                    continuation.finish(throwing: error)
                } catch {
                    let streamError = AIUIMessageStreamError(message: String(describing: error))
                    if let event = await lifecycle.claimEnd(
                        outcome: .failed,
                        errorDescription: String(describing: error)
                    ) {
                        await onEnd?(event)
                    }
                    continuation.finish(throwing: streamError)
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    Task {
                        if let event = await lifecycle.claimEnd(
                            outcome: .unknown,
                            isCancelled: true
                        ) {
                            await onEnd?(event)
                        }
                    }
                }
                task.cancel()
            }
        }
    }

    @discardableResult
    private mutating func finishNormalization() -> Bool {
        let finalParts = streamNormalizer.finish()
        for part in finalParts {
            try? consumeCanonical(part)
        }
        return !finalParts.isEmpty
    }

    private mutating func ensureTextPart(
        id: String?,
        providerMetadata: [String: JSONValue] = [:],
        state: AIUIStreamingPartState? = .streaming
    ) {
        let key = id ?? "$default"
        if let index = textPartIndexes[key], case let .text(part) = message.parts[index] {
            message.parts[index] = .text(AIUITextPart(
                id: part.id,
                text: part.text,
                state: part.state ?? state,
                providerMetadata: part.providerMetadata.merging(providerMetadata) { _, new in new },
                citations: part.citations
            ))
            return
        }
        textPartIndexes[key] = message.parts.count
        message.parts.append(.text(AIUITextPart(id: id, text: "", state: state, providerMetadata: providerMetadata)))
    }

    private mutating func appendText(_ delta: String, id: String?, providerMetadata: [String: JSONValue] = [:]) {
        ensureTextPart(id: id, providerMetadata: providerMetadata, state: id == nil ? nil : .streaming)
        let key = id ?? "$default"
        guard let index = textPartIndexes[key], case let .text(part) = message.parts[index] else { return }
        message.parts[index] = .text(AIUITextPart(
            id: part.id,
            text: part.text + delta,
            state: part.state,
            providerMetadata: part.providerMetadata.merging(providerMetadata) { _, new in new },
            citations: part.citations
        ))
    }

    private mutating func appendTextDeltaPart(
        _ delta: String,
        id: String,
        providerMetadata: [String: JSONValue]
    ) throws {
        guard textPartIndexes[id] != nil else {
            throw missingStartError(chunkType: "text-delta", chunkID: id, startChunkType: "text-start")
        }
        appendText(delta, id: id, providerMetadata: providerMetadata)
    }

    private mutating func endTextPart(id: String, providerMetadata: [String: JSONValue], citations: [AICitation]? = nil) throws {
        guard let index = textPartIndexes[id], case let .text(part) = message.parts[index] else {
            throw missingStartError(chunkType: "text-end", chunkID: id, startChunkType: "text-start")
        }
        message.parts[index] = .text(AIUITextPart(
            id: part.id,
            text: part.text,
            state: .done,
            providerMetadata: part.providerMetadata.merging(providerMetadata) { _, new in new },
            citations: citations ?? part.citations
        ))
        textPartIndexes.removeValue(forKey: id)
    }

    private mutating func ensureReasoningPart(
        id: String?,
        providerMetadata: [String: JSONValue] = [:],
        state: AIUIStreamingPartState? = .streaming
    ) {
        let key = id ?? "$default"
        if let index = reasoningPartIndexes[key], case let .reasoning(part) = message.parts[index] {
            message.parts[index] = .reasoning(AIUIReasoningPart(
                id: part.id,
                text: part.text,
                state: part.state ?? state,
                providerMetadata: part.providerMetadata.merging(providerMetadata) { _, new in new }
            ))
            return
        }
        reasoningPartIndexes[key] = message.parts.count
        message.parts.append(.reasoning(AIUIReasoningPart(id: id, text: "", state: state, providerMetadata: providerMetadata)))
    }

    private mutating func appendReasoning(_ delta: String, id: String?, providerMetadata: [String: JSONValue] = [:]) {
        ensureReasoningPart(id: id, providerMetadata: providerMetadata, state: id == nil ? nil : .streaming)
        let key = id ?? "$default"
        guard let index = reasoningPartIndexes[key], case let .reasoning(part) = message.parts[index] else { return }
        message.parts[index] = .reasoning(AIUIReasoningPart(
            id: part.id,
            text: part.text + delta,
            state: part.state,
            providerMetadata: part.providerMetadata.merging(providerMetadata) { _, new in new }
        ))
    }

    private mutating func appendReasoningDeltaPart(
        _ delta: String,
        id: String,
        providerMetadata: [String: JSONValue]
    ) throws {
        guard reasoningPartIndexes[id] != nil else {
            throw missingStartError(chunkType: "reasoning-delta", chunkID: id, startChunkType: "reasoning-start")
        }
        appendReasoning(delta, id: id, providerMetadata: providerMetadata)
    }

    private mutating func endReasoningPart(id: String, providerMetadata: [String: JSONValue]) throws {
        guard let index = reasoningPartIndexes[id], case let .reasoning(part) = message.parts[index] else {
            throw missingStartError(chunkType: "reasoning-end", chunkID: id, startChunkType: "reasoning-start")
        }
        message.parts[index] = .reasoning(AIUIReasoningPart(
            id: part.id,
            text: part.text,
            state: .done,
            providerMetadata: part.providerMetadata.merging(providerMetadata) { _, new in new }
        ))
        reasoningPartIndexes.removeValue(forKey: id)
    }

    private mutating func ensureToolCallPart(
        id: String,
        name: String,
        providerExecuted: Bool = false,
        dynamic: Bool = false,
        title: String? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        if let index = toolCallPartIndexes[id], case let .toolCall(call) = message.parts[index] {
            var updated = call
            updated.name = name.isEmpty ? call.name : name
            updated.providerExecuted = call.providerExecuted || providerExecuted
            updated.dynamic = call.dynamic || dynamic
            updated.title = call.title ?? title
            updated.providerMetadata.merge(providerMetadata) { _, new in new }
            message.parts[index] = .toolCall(updated)
            return
        }
        toolCallPartIndexes[id] = message.parts.count
        message.parts.append(.toolCall(AIToolCall(
            id: id,
            name: name,
            arguments: "",
            providerExecuted: providerExecuted,
            dynamic: dynamic,
            title: title,
            providerMetadata: providerMetadata
        )))
    }

    private mutating func appendToolArguments(_ delta: String, id: String, providerMetadata: [String: JSONValue] = [:]) {
        ensureToolCallPart(id: id, name: "", providerMetadata: providerMetadata)
        guard let index = toolCallPartIndexes[id], case let .toolCall(call) = message.parts[index] else { return }
        var updated = call
        if call.inputEncoding == .text {
            let raw = (call.rawInputText ?? (try? decodeJSONBody(Data(call.arguments.utf8)))?.stringValue ?? "") + delta
            updated.rawInputText = raw
            updated.arguments = canonicalJSONText(.string(raw)) ?? "\"\""
        } else { updated.arguments += delta }
        updated.providerMetadata.merge(providerMetadata) { _, new in new }
        message.parts[index] = .toolCall(updated)
    }

    private mutating func mergeToolMetadata(id: String, providerMetadata: [String: JSONValue]) {
        ensureToolCallPart(id: id, name: "", providerMetadata: providerMetadata)
    }

    private mutating func appendToolInputDelta(
        _ delta: String,
        id: String,
        providerMetadata: [String: JSONValue]
    ) throws {
        guard activeToolInputIDs.contains(id) else {
            throw missingStartError(chunkType: "tool-input-delta", chunkID: id, startChunkType: "tool-input-start")
        }
        appendToolArguments(delta, id: id, providerMetadata: providerMetadata)
    }

    private mutating func endToolInput(id: String, providerMetadata: [String: JSONValue]) throws {
        guard activeToolInputIDs.contains(id) else {
            throw missingStartError(chunkType: "tool-input-end", chunkID: id, startChunkType: "tool-input-start")
        }
        mergeToolMetadata(id: id, providerMetadata: providerMetadata)
        activeToolInputIDs.remove(id)
    }

    private mutating func appendToolCallDelta(id: String?, name: String?, argumentsDelta: String, index: Int?) {
        let toolID = id ?? fallbackToolCallID(index: index)
        ensureToolCallPart(id: toolID, name: name ?? "")
        appendToolArguments(argumentsDelta, id: toolID)
    }

    private mutating func upsertToolCall(_ call: AIToolCall) {
        if let index = toolCallPartIndexes[call.id] {
            var updated = call
            if case let .toolCall(previous) = message.parts[index] { updated.inputEncoding = previous.inputEncoding }
            updated.rawInputText = nil
            activeToolInputIDs.remove(call.id)
            message.parts[index] = .toolCall(updated)
        } else {
            toolCallPartIndexes[call.id] = message.parts.count
            message.parts.append(.toolCall(call))
        }
    }

    private mutating func fallbackToolCallID(index: Int?) -> String {
        if let index {
            if let id = fallbackToolCallIDsByIndex[index] {
                return id
            }
            let id = "tool-call-\(index)"
            fallbackToolCallIDsByIndex[index] = id
            return id
        }
        let id = "tool-call-\(fallbackToolCallCounter)"
        fallbackToolCallCounter += 1
        return id
    }

    private mutating func recordFinish(reason: String?, usage: TokenUsage?, providerMetadata: [String: JSONValue]) {
        message.metadata["finishReason"] = reason.map(JSONValue.string)
        message.metadata["usage"] = usage.map(aiUIMessageTokenUsageJSON)
        if !providerMetadata.isEmpty {
            message.metadata["providerMetadata"] = .object(providerMetadata)
        }
    }

    private func missingStartError(chunkType: String, chunkID: String, startChunkType: String) -> AIUIMessageStreamError {
        AIUIMessageStreamError(
            message: "Received \(chunkType) for missing stream part with ID \"\(chunkID)\". Ensure a \"\(startChunkType)\" chunk is sent before any \"\(chunkType)\" chunks.",
            chunkType: chunkType,
            chunkID: chunkID
        )
    }
}

private func warningJSON(_ warning: AIWarning) -> JSONValue {
    aiWarningJSON(warning)
}

private func responseMetadataJSON(_ metadata: AIResponseMetadata) -> JSONValue {
    .object([
        "id": metadata.id.map(JSONValue.string),
        "timestamp": metadata.timestamp.map { .string(iso8601String($0)) },
        "modelID": metadata.modelID.map(JSONValue.string),
        "headers": metadata.headers.isEmpty ? nil : .object(metadata.headers.mapValues(JSONValue.string)),
        "body": metadata.body
    ])
}

private func aiUIMessageTokenUsageJSON(_ usage: TokenUsage) -> JSONValue {
    .object([
        "inputTokens": usage.inputTokens.map(jsonNumber),
        "outputTokens": usage.outputTokens.map(jsonNumber),
        "totalTokens": usage.totalTokens.map(jsonNumber),
        "inputTokensNoCache": usage.inputTokensNoCache.map(jsonNumber),
        "inputTokensCacheRead": usage.inputTokensCacheRead.map(jsonNumber),
        "inputTokensCacheWrite": usage.inputTokensCacheWrite.map(jsonNumber),
        "outputTextTokens": usage.outputTextTokens.map(jsonNumber),
        "outputReasoningTokens": usage.outputReasoningTokens.map(jsonNumber),
        "rawValue": usage.rawValue
    ])
}

private func jsonNumber(_ value: Int) -> JSONValue {
    .number(Double(value))
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}