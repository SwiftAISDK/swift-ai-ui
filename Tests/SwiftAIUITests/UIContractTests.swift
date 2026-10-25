@testable import SwiftAIUI
import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI
import Testing


@Test func uiMessageReducerBuildsAssistantMessageFromLanguageStreamParts() throws {
    let source = AISource(id: "src-1", sourceType: "url", url: "https://example.com")
    let file = AIStreamFile(id: "file-1", mediaType: "text/plain", filename: "note.txt")
    let approvalRequest = AIToolApprovalRequest(
        id: "approval-call-1",
        toolName: "lookup",
        arguments: #"{"city":"Tokyo"}"#,
        toolCallID: "call-1"
    )
    let approvalResponse = AIToolApprovalResponse(id: "approval-call-1", approved: true)
    let toolResult = AIToolResult(
        toolCallID: "call-1",
        toolName: "lookup",
        result: ["forecast": "sunny"]
    )
    let response = AIResponseMetadata(id: "resp-1", modelID: "model-1")

    let parts: [LanguageStreamPart] = [
        .streamStart(warnings: [AIWarning(type: "unsupported", feature: "seed")]),
        .textStart(id: "text-1"),
        .textDeltaPart(id: "text-1", delta: "Hel"),
        .textDeltaPart(id: "text-1", delta: "lo"),
        .textEnd(id: "text-1"),
        .reasoningStart(id: "reasoning-1"),
        .reasoningDeltaPart(id: "reasoning-1", delta: "thinking"),
        .reasoningEnd(id: "reasoning-1"),
        .toolInputStart(id: "call-1", name: "lookup", title: "Lookup"),
        .toolInputDelta(id: "call-1", delta: #"{"city""#),
        .toolInputDelta(id: "call-1", delta: #":"Tokyo"}"#),
        .toolInputEnd(id: "call-1"),
        .toolApprovalRequest(approvalRequest),
        .toolApprovalResponse(approvalResponse),
        .toolResult(toolResult),
        .source(source),
        .file(file),
        .metadata(["trace": .string("ui")]),
        .responseMetadata(response),
        .finish(reason: "stop", usage: TokenUsage(totalTokens: 9))
    ]

    var reducer = AIUIMessageStreamReducer(message: .assistant(id: "message-1"))
    let message = try reducer.consume(contentsOf: parts)

    #expect(message.id == "message-1")
    #expect(message.role == .assistant)
    #expect(message.text == "Hello")
    #expect(message.reasoning == "thinking")
    #expect(message.metadata["warnings"]?[0]?["feature"]?.stringValue == "seed")
    #expect(message.metadata["trace"]?.stringValue == "ui")
    #expect(message.metadata["response"]?["id"]?.stringValue == "resp-1")
    #expect(message.metadata["usage"]?["totalTokens"]?.intValue == 9)
    #expect(message.metadata["finishReason"]?.stringValue == "stop")
    #expect(message.parts.contains(.toolApprovalRequest(approvalRequest)))
    #expect(message.parts.contains(.toolApprovalResponse(approvalResponse)))
    #expect(message.parts.contains(.toolResult(toolResult)))
    #expect(message.parts.contains(.source(source)))
    #expect(message.parts.contains(.file(file)))

    let toolCall = try #require(message.parts.compactMap { part -> AIToolCall? in
        if case let .toolCall(call) = part { return call }
        return nil
    }.first)
    #expect(toolCall.id == "call-1")
    #expect(toolCall.name == "lookup")
    #expect(toolCall.arguments == #"{"city":"Tokyo"}"#)
    #expect(toolCall.title == "Lookup")
    #expect(safeValidateUIMessages([message]).isValid)
}


@Test func uiMessageStreamReducerTracksStreamingStateAndRejectsMissingStarts() throws {
    var reducer = AIUIMessageStreamReducer(message: .assistant(id: "message-1"))

    _ = try reducer.consume(.textStart(id: "text-1"))
    var text = try #require(reducer.message.parts.firstTextPart)
    #expect(text.state == .streaming)

    _ = try reducer.consume(.textDeltaPart(id: "text-1", delta: "Hello"))
    _ = try reducer.consume(.textEnd(id: "text-1"))
    text = try #require(reducer.message.parts.firstTextPart)
    #expect(text.text == "Hello")
    #expect(text.state == .done)

    do {
        var brokenReducer = AIUIMessageStreamReducer(message: .assistant(id: "broken"))
        _ = try brokenReducer.consume(.textDeltaPart(id: "missing", delta: "!"))
        Issue.record("Expected missing text-start failure.")
    } catch let error as AIUIMessageStreamError {
        #expect(error.chunkType == "text-delta")
        #expect(error.chunkID == "missing")
    }

    do {
        var brokenReducer = AIUIMessageStreamReducer(message: .assistant(id: "broken"))
        _ = try brokenReducer.consume(.toolInputDelta(id: "missing-tool", delta: "{}"))
        Issue.record("Expected missing tool-input-start failure.")
    } catch let error as AIUIMessageStreamError {
        #expect(error.chunkType == "tool-input-delta")
        #expect(error.chunkID == "missing-tool")
    }
}


@Test func uiMessageValidationReportsBrokenMessageParts() throws {
    let broken = AIUIMessage(
        id: "",
        role: .assistant,
        parts: [
            .toolCall(AIToolCall(id: "", name: "", arguments: "{")),
            .toolResult(AIToolResult(toolCallID: "missing-call", toolName: "lookup", result: ["ok": true])),
            .toolApprovalResponse(AIToolApprovalResponse(id: "missing-approval", approved: false))
        ]
    )

    let result = safeValidateUIMessages([broken])
    #expect(result.isValid == false)
    #expect(result.issues.contains { $0.path == "messages[0].id" })
    #expect(result.issues.contains { $0.path.contains("toolCall.arguments") })
    #expect(result.issues.contains { $0.message.contains("tool result must reference") })
    #expect(result.issues.contains { $0.message.contains("approval response must reference") })

    do {
        try validateUIMessages([broken])
        Issue.record("Expected UI message validation failure.")
    } catch let error as AIUIMessageStreamError {
        #expect(error.validationIssues == result.issues)
    }
}


@Test func uiMessageValidationThrowsTypedApprovalErrors() throws {
    do {
        try validateUIMessages([
            AIUIMessage(
                id: "assistant-1",
                role: .assistant,
                parts: [.toolApprovalResponse(AIToolApprovalResponse(id: "missing-approval", approved: true))]
            )
        ])
        Issue.record("Expected invalid tool approval error.")
    } catch let error as AIInvalidToolApprovalError {
        #expect(error.approvalID == "missing-approval")
        #expect(error.description.contains("unknown approvalId"))
    }

    do {
        try validateUIMessages([
            AIUIMessage(
                id: "assistant-1",
                role: .assistant,
                parts: [
                    .toolApprovalRequest(AIToolApprovalRequest(
                        id: "approval-1",
                        toolName: "lookup",
                        arguments: "{}",
                        toolCallID: "missing-call"
                    ))
                ]
            )
        ])
        Issue.record("Expected approval tool-call lookup failure.")
    } catch let error as AIToolCallNotFoundForApprovalError {
        #expect(error.approvalID == "approval-1")
        #expect(error.toolCallID == "missing-call")
    }
}


@Test func uiMessageValidationRejectsEmptyMessagesAndNonAssistantPartsLikeUpstream() {
    let emptyMessages = safeValidateUIMessages([])
    #expect(emptyMessages.isValid == false)
    #expect(emptyMessages.issues.contains { $0.path == "messages" })

    let emptyAssistantParts = safeValidateUIMessages([AIUIMessage(id: "empty-assistant", role: .assistant)])
    #expect(emptyAssistantParts.isValid)

    let emptyUserParts = safeValidateUIMessages([AIUIMessage(id: "empty-user", role: .user)])
    #expect(emptyUserParts.isValid == false)
    #expect(emptyUserParts.issues.contains { $0.path == "messages[0].parts" })
}


@Test func uiMessageSnapshotStreamEmitsIncrementalMessages() async throws {
    let stream = AsyncThrowingStream<LanguageStreamPart, Error> { continuation in
        continuation.yield(.textDelta("A"))
        continuation.yield(.textDelta("B"))
        continuation.yield(.finish(reason: "stop", usage: TokenUsage(totalTokens: 2)))
        continuation.finish()
    }

    var snapshots: [AIUIMessage] = []
    for try await snapshot in AIUIMessageStreamReducer.snapshots(from: stream, messageID: "message-1") {
        snapshots.append(snapshot)
    }

    #expect(snapshots.map(\.text) == ["A", "AB", "AB"])
    #expect(snapshots.last?.metadata["finishReason"]?.stringValue == "stop")
    #expect(snapshots.last?.metadata["usage"]?["totalTokens"]?.intValue == 2)
}


@Test func convertToModelMessagesMapsSupportedUIMessageParts() throws {
    let imageData = try #require("image".data(using: .utf8))
    let call = AIToolCall(id: "call-1", name: "lookup", arguments: #"{"city":"Tokyo"}"#)
    let result = AIToolResult(toolCallID: "call-1", toolName: "lookup", result: ["forecast": "sunny"])

    let messages = try convertToModelMessages([
        .system("Rules."),
        AIUIMessage(
            id: "user-1",
            role: .user,
            parts: [
                .text(AIUITextPart(text: "What is this?")),
                .file(AIStreamFile(mediaType: "image/png", data: imageData, filename: "image.png")),
                .file(AIStreamFile(mediaType: "image/jpeg", url: "https://example.com/image.jpg"))
            ]
        ),
        AIUIMessage(
            id: "assistant-1",
            role: .assistant,
            parts: [
                .reasoning(AIUIReasoningPart(text: "Need a lookup.")),
                .toolCall(call),
                .metadata(["ignored": .bool(true)])
            ]
        ),
        AIUIMessage(id: "tool-1", role: .tool, parts: [.toolResult(result)])
    ])

    #expect(messages.count == 4)
    #expect(messages[0] == .system("Rules."))
    #expect(messages[1].role == .user)
    #expect(messages[1].combinedText == "What is this?")
    #expect(messages[1].content.count == 3)
    #expect(messages[2].reasoning == nil)
    #expect(messages[2].content == [.reasoning("Need a lookup."), .toolCall(call)])
    #expect(messages[3].content == [.toolResult(result)])
}


@Test func convertToModelMessagesPreservesReasoningProviderMetadata() throws {
    let messages = try convertToModelMessages([
        AIUIMessage(
            id: "assistant-1",
            role: .assistant,
            parts: [
                .reasoning(AIUIReasoningPart(
                    text: "Need a lookup.",
                    providerMetadata: ["anthropic": ["signature": "sig_123"]]
                )),
                .text(AIUITextPart(text: "Done."))
            ]
        )
    ])

    let message = try #require(messages.first)
    #expect(message.reasoning == nil)
    #expect(message.content[0].providerMetadata["anthropic"]?["signature"]?.stringValue == "sig_123")
}


@Test func convertToModelMessagesPreservesContentPartProviderMetadata() throws {
    let fileData = Data("%PDF-1.7\n".utf8)
    let messages = try convertToModelMessages([
        AIUIMessage(
            id: "user-1",
            role: .user,
            parts: [
                .text(AIUITextPart(
                    text: "Read this.",
                    providerMetadata: ["anthropic": ["cacheControl": ["type": "ephemeral"]]]
                )),
                .file(AIStreamFile(
                    mediaType: "application/pdf",
                    data: fileData,
                    filename: "doc.pdf",
                    providerMetadata: ["anthropic": ["citations": ["enabled": true]]]
                ))
            ]
        )
    ])

    let message = try #require(messages.first)
    #expect(message.content.count == 2)
    #expect(message.content[0].providerMetadata["anthropic"]?["cacheControl"]?["type"]?.stringValue == "ephemeral")
    #expect(message.content[1].providerMetadata["anthropic"]?["citations"]?["enabled"]?.boolValue == true)
}


@Test func convertToModelMessagesRejectsUnsupportedURLFiles() throws {
    let message = AIUIMessage(
        id: "user-1",
        role: .user,
        parts: [
            .file(AIStreamFile(mediaType: "application/pdf", url: "https://example.com/report.pdf"))
        ]
    )

    do {
        _ = try convertToModelMessages([message])
        Issue.record("Expected model-message conversion failure.")
    } catch let error as AIUIMessageStreamError {
        #expect(error.validationIssues.first?.path == "messages[0].parts[0].file")
        #expect(error.description.contains("URL files"))
    }
}


@Test func directAIChatTransportConvertsHistoryAndStreamsUIMessageSnapshots() async throws {
    let source = AISource(id: "source-1", sourceType: "url", url: "https://example.com")
    let model = ChatTransportRecordingLanguageModel(streamParts: [
        .textDelta("Hel"),
        .textDelta("lo"),
        .reasoningDelta("thinking"),
        .source(source),
        .finish(reason: "stop", usage: TokenUsage(totalTokens: 5))
    ])
    let call = AIToolCall(id: "call-1", name: "lookup", arguments: #"{"city":"Tokyo"}"#)
    let result = AIToolResult(toolCallID: "call-1", toolName: "lookup", result: ["forecast": "sunny"])
    let transport = DirectAIChatTransport(
        model: model,
        executableTools: [AITool(name: "lookup", parameters: ["type": "object"], execute: { _ in ["forecast": "sunny"] })],
        requestOptions: AIChatRequestOptions(
            temperature: 0.2,
            providerOptions: ["mock": ["trace": "enabled"]],
            headers: ["x-default": "1"]
        ),
        sendSources: true,
        generateMessageID: { "generated-response" }
    )

    let stream = try transport.sendMessages(AIChatTransportRequest(
        chatID: "chat-1",
        responseMessageID: "response-1",
        messages: [
            .system("Rules."),
            .user("Weather?"),
            AIUIMessage(id: "assistant-1", role: .assistant, parts: [.toolCall(call)]),
            AIUIMessage(id: "tool-1", role: .tool, parts: [.toolResult(result)])
        ],
        headers: ["x-request": "2"]
    ))

    var snapshots: [AIUIMessage] = []
    for try await snapshot in stream {
        snapshots.append(snapshot)
    }

    let request = try #require(model.streamRequests.first)
    #expect(request.temperature == 0.2)
    #expect(request.providerOptions["mock"]?["trace"]?.stringValue == "enabled")
    #expect(request.headers == ["x-default": "1", "x-request": "2"])
    #expect(request.messages.map(\.role) == [.system, .user, .assistant, .tool])
    #expect(request.messages[2].content == [.toolCall(call)])
    #expect(request.messages[3].content == [.toolResult(result)])
    let finalSnapshot = try #require(snapshots.last)
    #expect(finalSnapshot.id == "response-1")
    #expect(finalSnapshot.text == "Hello")
    #expect(finalSnapshot.reasoning == "thinking")
    #expect(finalSnapshot.parts.contains(.source(source)))
    #expect(finalSnapshot.metadata["finishReason"]?.stringValue == "stop")
}


@Test func directAIChatTransportCanHideReasoningSourcesAndFinishMetadata() async throws {
    let model = ChatTransportRecordingLanguageModel(streamParts: [
        .reasoningDelta("hidden"),
        .source(AISource(id: "source-1", sourceType: "url", url: "https://example.com")),
        .textDelta("Visible"),
        .finish(reason: "stop", usage: TokenUsage(totalTokens: 1))
    ])
    let transport = DirectAIChatTransport(
        model: model,
        sendReasoning: false,
        sendSources: false,
        sendFinish: false,
        generateMessageID: { "generated-response" }
    )

    var snapshots: [AIUIMessage] = []
    for try await snapshot in try transport.sendMessages(AIChatTransportRequest(
        chatID: "chat-1",
        messages: [.user("Hi")]
    )) {
        snapshots.append(snapshot)
    }

    let finalSnapshot = try #require(snapshots.last)
    #expect(finalSnapshot.id == "generated-response")
    #expect(finalSnapshot.text == "Visible")
    #expect(finalSnapshot.reasoning.isEmpty)
    #expect(finalSnapshot.metadata["finishReason"] == nil)
    #expect(finalSnapshot.parts.contains { part in
        if case .source = part { return true }
        return false
    } == false)
}


private final class ChatTransportRecordingLanguageModel: LanguageModel, @unchecked Sendable {
    let providerID = "chat-transport"
    let modelID = "language"
    var generateRequests: [LanguageModelRequest] = []
    var streamRequests: [LanguageModelRequest] = []
    private let result: TextGenerationResult
    private let streamParts: [LanguageStreamPart]

    init(
        result: TextGenerationResult = TextGenerationResult(text: "ok", rawValue: .object([:])),
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


private extension Array where Element == AIUIMessagePart {
    var firstTextPart: AIUITextPart? {
        for part in self {
            if case let .text(text) = part {
                return text
            }
        }
        return nil
    }
}