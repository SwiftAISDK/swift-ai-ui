import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public enum AIChatTransportTrigger: String, Equatable, Hashable, Sendable {
    case submitMessage = "submit-message"
    case regenerateMessage = "regenerate-message"
}

public struct AIChatTransportRequest: Sendable {
    public var chatID: String
    public var trigger: AIChatTransportTrigger
    public var messageID: String?
    public var responseMessageID: String?
    public var messages: [AIUIMessage]
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]
    public var body: [String: JSONValue]
    public var metadata: JSONValue?

    public init(
        chatID: String,
        trigger: AIChatTransportTrigger = .submitMessage,
        messageID: String? = nil,
        responseMessageID: String? = nil,
        messages: [AIUIMessage],
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        body: [String: JSONValue] = [:],
        metadata: JSONValue? = nil
    ) {
        self.chatID = chatID
        self.trigger = trigger
        self.messageID = messageID
        self.responseMessageID = responseMessageID
        self.messages = messages
        self.abortSignal = abortSignal
        self.headers = headers
        self.body = body
        self.metadata = metadata
    }
}

public struct AIChatReconnectRequest: Sendable {
    public var chatID: String
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]
    public var body: [String: JSONValue]
    public var metadata: JSONValue?

    public init(
        chatID: String,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        body: [String: JSONValue] = [:],
        metadata: JSONValue? = nil
    ) {
        self.chatID = chatID
        self.abortSignal = abortSignal
        self.headers = headers
        self.body = body
        self.metadata = metadata
    }
}

public protocol AIChatTransport: Sendable {
    func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error>
    func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>?
    /// Releases persistent resources when no consumers remain.
    func close() async
}

public extension AIChatTransport {
    func close() async {}

    func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>? {
        nil
    }
}


public struct DirectAIChatTransport: AIChatTransport {
    public var model: any LanguageModel
    public var executableTools: [AITool]
    public var maxSteps: Int
    public var toolCallers: AIToolCallerRouting
    public var stopWhen: [AIStopCondition]
    public var prepareStep: AIPrepareStep?
    public var toolApproval: AIToolApproval?
    public var requestOptions: AIChatRequestOptions
    public var timeoutNanoseconds: UInt64?
    public var retryPolicy: AIRetryPolicy
    public var telemetry: Telemetry.Options?
    public var sendReasoning: Bool
    public var sendSources: Bool
    public var sendFinish: Bool
    public var generateMessageID: @Sendable () -> String

    public init(
        model: any LanguageModel,
        executableTools: [AITool] = [],
        maxSteps: Int = 5,
        toolCallers: AIToolCallerRouting = [:],
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        requestOptions: AIChatRequestOptions = AIChatRequestOptions(),
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        sendReasoning: Bool = true,
        sendSources: Bool = false,
        sendFinish: Bool = true,
        generateMessageID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.model = model
        self.executableTools = executableTools
        self.maxSteps = maxSteps
        self.toolCallers = toolCallers
        self.stopWhen = stopWhen
        self.prepareStep = prepareStep
        self.toolApproval = toolApproval
        self.requestOptions = requestOptions
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryPolicy = retryPolicy
        self.telemetry = telemetry
        self.sendReasoning = sendReasoning
        self.sendSources = sendSources
        self.sendFinish = sendFinish
        self.generateMessageID = generateMessageID
    }
    /// Preserves the initializer released in 1.7.0 before tool-caller routing was added.
    public init(
        model: any LanguageModel,
        executableTools: [AITool] = [],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        requestOptions: AIChatRequestOptions = AIChatRequestOptions(),
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        sendReasoning: Bool = true,
        sendSources: Bool = false,
        sendFinish: Bool = true,
        generateMessageID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.init(
            model: model,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: [:],
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            requestOptions: requestOptions,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            sendReasoning: sendReasoning,
            sendSources: sendSources,
            sendFinish: sendFinish,
            generateMessageID: generateMessageID
        )
    }


    public func sendMessages(_ request: AIChatTransportRequest) throws -> AsyncThrowingStream<AIUIMessage, Error> {
        let tools = executableTools.reduce(into: [String: AITool]()) { $0[$1.name] = $1 }
        var schemas = requestOptions.tools.mapValues {
            AIUIMessageToolSchema(inputSchema: $0["inputSchema"] ?? $0["parameters"] ?? .object([:]))
        }
        schemas.merge(tools.mapValues { AIUIMessageToolSchema($0) }) { _, executable in executable }
        _ = try validateUIMessages(request.messages)
        let toolSchemas = schemas
        let refiners = tools.compactMapValues(\.refineArguments)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try request.abortSignal?.throwIfAborted()
                    var preparedMessages = try await validateUIMessagesForAgent(
                        request.messages,
                        toolSchemas: toolSchemas,
                        refineToolInput: refiners
                    )
                    let registeredProviderCallIDs = Set(preparedMessages.flatMap(\.parts).compactMap { part -> String? in
                        guard case let .toolCall(call) = part, requestOptions.tools[call.name] != nil else { return nil }
                        return call.id
                    })
                    for index in preparedMessages.indices {
                        preparedMessages[index].unavailableStaticToolCallIDs.subtract(registeredProviderCallIDs)
                    }
                    let modelMessages = try await convertToModelMessages(preparedMessages, tools: tools)
                    try Task.checkCancellation()
                    try request.abortSignal?.throwIfAborted()
                    let languageRequest = requestOptions.languageModelRequest(
                        messages: modelMessages,
                        abortSignal: request.abortSignal,
                        headers: request.headers
                    )
                    let languageStream: AsyncThrowingStream<LanguageStreamPart, Error>
                    if executableTools.isEmpty && prepareStep == nil {
                        languageStream = AI.streamText(
                            model: model,
                            request: languageRequest,
                            timeoutNanoseconds: timeoutNanoseconds,
                            retryPolicy: retryPolicy,
                            telemetry: telemetry
                        )
                    } else {
                        languageStream = AI.streamText(
                            model: model,
                            request: languageRequest,
                            executableTools: executableTools,
                            maxSteps: maxSteps,
                            stopWhen: stopWhen,
                            prepareStep: prepareStep,
                            toolCallers: toolCallers,
                            toolApproval: toolApproval,
                            timeoutNanoseconds: timeoutNanoseconds,
                            retryPolicy: retryPolicy,
                            telemetry: telemetry
                        )
                    }
                    let originalMessage = request.responseMessageID.flatMap { responseMessageID in
                        preparedMessages.last { $0.id == responseMessageID }
                    }
                    let snapshots = AIUIMessageStreamReducer.snapshots(
                        from: filteredLanguageStream(languageStream),
                        messageID: request.responseMessageID ?? generateMessageID(),
                        originalMessage: originalMessage
                    )
                    for try await snapshot in snapshots { continuation.yield(snapshot) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reconnectToStream(_ request: AIChatReconnectRequest) async throws -> AsyncThrowingStream<AIUIMessage, Error>? {
        nil
    }

    private func filteredLanguageStream(
        _ stream: AsyncThrowingStream<LanguageStreamPart, Error>
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await part in stream {
                        guard shouldSend(part) else { continue }
                        continuation.yield(part)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func shouldSend(_ part: LanguageStreamPart) -> Bool {
        switch part {
        case .reasoningStart, .reasoningDelta, .reasoningDeltaPart, .reasoningEnd, .reasoningFile:
            return sendReasoning
        case .source:
            return sendSources
        case .finish, .finishMetadata:
            return sendFinish
        default:
            return true
        }
    }
}