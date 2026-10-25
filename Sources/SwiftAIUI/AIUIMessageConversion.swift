import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public typealias AIUIDataPartConverter = @Sendable (AIUIDataPart) throws -> AIContentPart?

public func convertToModelMessages(
    _ messages: [AIUIMessage]
) throws -> [AIMessage] {
    try convertToModelMessages(messages, ignoreIncompleteToolCalls: false)
}

public func convertToModelMessages(
    _ messages: [AIUIMessage],
    ignoreIncompleteToolCalls: Bool
) throws -> [AIMessage] {
    try convertToModelMessages(messages, ignoreIncompleteToolCalls: ignoreIncompleteToolCalls, convertDataPart: nil)
}

public func convertToModelMessages(
    _ messages: [AIUIMessage],
    ignoreIncompleteToolCalls: Bool = false,
    convertDataPart: AIUIDataPartConverter?
) throws -> [AIMessage] {
    _ = try validateUIMessages(messages)
    let unavailableIDs = Set(messages.flatMap { $0.unavailableStaticToolCallIDs })
    let lastUserIndex = messages.lastIndex { $0.role == .user } ?? -1
    return try messages.enumerated().flatMap { index, message in
        var filteredMessage = ignoreIncompleteToolCalls
            ? message.omittingPreliminaryToolCalls()
            : message
        if index < lastUserIndex {
            let completedIDs = Set(message.parts.compactMap { part -> String? in
                if case let .toolResult(result) = part { return result.toolCallID }
                return nil
            })
            let responseIDs = Set(message.parts.compactMap { part -> String? in
                if case let .toolApprovalResponse(response) = part { return response.id }
                return nil
            })
            let pendingIDs = Set(message.parts.compactMap { part -> String? in
                if case let .toolApprovalRequest(request) = part, !completedIDs.contains(request.toolCallID ?? ""), !responseIDs.contains(request.id) { return request.toolCallID }
                return nil
            })
            filteredMessage.parts.removeAll { part in
                if case let .toolCall(call) = part { return pendingIDs.contains(call.id) }
                if case let .toolApprovalRequest(request) = part { return pendingIDs.contains(request.toolCallID ?? "") }
                return false
            }
        }
        let modelMessage = try convertToModelMessage(filteredMessage, path: "messages[\(index)]", convertDataPart: convertDataPart, unavailableStaticToolCallIDs: unavailableIDs)
        return splitAssistantResponseMessages(modelMessage)
    }
}

/// Uses current tool converters when restoring normalized static tool history.
public func convertToModelMessages(
    _ messages: [AIUIMessage],
    tools: [String: AITool],
    ignoreIncompleteToolCalls: Bool = false,
    convertDataPart: AIUIDataPartConverter? = nil
) async throws -> [AIMessage] {
    _ = try validateUIMessages(messages)
    var prepared = messages
    var calls: [String: AIToolCall] = [:]
    for message in messages {
        for part in message.parts {
            if case let .toolCall(call) = part { calls[call.id] = call }
        }
    }
    let restoredIDs = Set(calls.values.filter { tools[$0.name] != nil }.map(\.id))
    for messageIndex in prepared.indices {
        prepared[messageIndex].unavailableStaticToolCallIDs.subtract(restoredIDs)
        for partIndex in prepared[messageIndex].parts.indices {
            guard case var .toolResult(result) = prepared[messageIndex].parts[partIndex],
                  !result.isError,
                  !(ignoreIncompleteToolCalls && result.preliminary),
                  let call = calls[result.toolCallID],
                  let tool = tools[call.name] else { continue }
            if let converter = tool.toModelOutput {
                let input = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? JSONValue.object([:])
                    : try secureJSONParse(call.arguments)
                result.modelOutput = try await converter(.init(toolCallID: call.id, input: input, output: result.result))
            } else {
                result.modelOutput = nil
            }
            prepared[messageIndex].parts[partIndex] = .toolResult(result)
        }
    }
    return try convertToModelMessages(prepared, ignoreIncompleteToolCalls: ignoreIncompleteToolCalls, convertDataPart: convertDataPart)
}

public func convertToModelMessage(_ message: AIUIMessage) throws -> AIMessage {
    try convertToModelMessage(message, path: "message")
}

private func convertToModelMessage(
    _ message: AIUIMessage,
    path: String,
    convertDataPart: AIUIDataPartConverter? = nil,
    unavailableStaticToolCallIDs: Set<String> = []
) throws -> AIMessage {
    var content: [AIContentPart] = []
    var providerMetadata: [String: JSONValue] = [:]
    var systemText = ""
    var failedResultMetadataByToolCallID: [String: [String: JSONValue]] = [:]
    for part in message.parts {
        guard case let .toolResult(result) = part,
              result.isError,
              !result.providerMetadata.isEmpty else {
            continue
        }
        failedResultMetadataByToolCallID[result.toolCallID] = result.providerMetadata
    }

    for (partIndex, part) in message.parts.enumerated() {
        let partPath = "\(path).parts[\(partIndex)]"
        switch part {
        case let .text(text):
            if message.role == .system {
                systemText += text.text
                providerMetadata.merge(text.providerMetadata) { _, new in new }
            } else if !text.text.isEmpty {
                content.append(.text(text.text, providerMetadata: text.providerMetadata))
            }
        case let .reasoning(reasoning):
            if !reasoning.text.isEmpty {
                content.append(.reasoning(reasoning.text, providerMetadata: reasoning.providerMetadata))
            }
        case let .file(file):
            try appendModelFile(file, path: partPath, content: &content)
        case let .toolCall(call):
            var resolvedCall = call
            if resolvedCall.providerMetadata.isEmpty,
               let resultMetadata = failedResultMetadataByToolCallID[call.id] {
                resolvedCall.providerMetadata = resultMetadata
            }
            content.append(.toolCall(resolvedCall))
        case let .toolResult(result):
            if !result.isError,
               unavailableStaticToolCallIDs.contains(result.toolCallID) || message.unavailableStaticToolCallIDs.contains(result.toolCallID) {
                var omitted = result
                let text = "Tool output omitted because the tool is no longer available."
                omitted.result = .string(text)
                omitted.modelOutput = .object(["type": .string("text"), "value": .string(text)])
                content.append(.toolResult(omitted))
            } else {
                content.append(.toolResult(result))
            }
        case let .toolApprovalRequest(request):
            content.append(.toolApprovalRequest(request))
        case let .toolApprovalResponse(response):
            content.append(.toolApprovalResponse(response))
        case let .custom(value, providerMetadata):
            content.append(.custom(value, providerMetadata: providerMetadata))
        case let .data(data):
            if let part = try convertDataPart?(data) { content.append(part) }
        case .source, .reasoningFile, .metadata, .error, .raw:
            break
        }
    }

    if message.role == .system, !systemText.isEmpty {
        content.insert(.text(systemText), at: 0)
    }

    return AIMessage(
        role: message.role,
        content: content,
        providerMetadata: providerMetadata
    )
}

private func splitAssistantResponseMessages(_ message: AIMessage) -> [AIMessage] {
    guard message.role == .assistant else {
        return [message]
    }

    var assistantParts: [AIContentPart] = []
    var toolParts: [AIContentPart] = []
    var toolCallsByID: [String: AIToolCall] = [:]
    var approvalRequestsByID: [String: AIToolApprovalRequest] = [:]
    let explicitToolResultIDs = Set(message.content.compactMap { part -> String? in
        if case let .toolResult(result) = part {
            return result.toolCallID
        }
        return nil
    })

    for part in message.content {
        switch part {
        case let .toolCall(call):
            toolCallsByID[call.id] = call
            assistantParts.append(part)
        case let .toolApprovalRequest(request):
            approvalRequestsByID[request.id] = request
            assistantParts.append(part)
        case let .toolApprovalResponse(response):
            toolParts.append(.toolApprovalResponse(response))
            if !response.approved,
               let request = approvalRequestsByID[response.id],
               let toolCallID = request.toolCallID,
               !explicitToolResultIDs.contains(toolCallID) {
                toolParts.append(.toolResult(AIToolResult(
                    toolCallID: toolCallID,
                    toolName: request.toolName,
                    result: executionDeniedResult(reason: response.reason),
                    providerExecuted: response.providerExecuted,
                    providerMetadata: response.providerMetadata
                )))
            }
        case let .toolResult(result):
            let providerExecuted = result.providerExecuted || (toolCallsByID[result.toolCallID]?.providerExecuted ?? false)
            if providerExecuted {
                assistantParts.append(.toolResult(result))
            } else {
                toolParts.append(.toolResult(result))
            }
        default:
            assistantParts.append(part)
        }
    }

    var messages: [AIMessage] = []
    if !assistantParts.isEmpty {
        messages.append(AIMessage(
            role: .assistant,
            content: assistantParts,
            providerMetadata: message.providerMetadata
        ))
    }
    if !toolParts.isEmpty {
        messages.append(AIMessage(role: .tool, content: toolParts))
    }
    return messages
}

private func appendModelFile(
    _ file: AIStreamFile,
    path: String,
    content: inout [AIContentPart]
) throws {
    if let providerReference = file.providerReference {
        content.append(.providerReference(
            mimeType: file.mediaType,
            reference: providerReference,
            filename: file.filename,
            providerMetadata: file.providerMetadata
        ))
        return
    }

    if let data = file.data {
        content.append(.file(
            mimeType: file.mediaType,
            data: data,
            filename: file.filename,
            providerMetadata: file.providerMetadata
        ))
        return
    }

    if let url = file.url, file.mediaType.lowercased().hasPrefix("image/") {
        content.append(.imageURL(url, providerMetadata: file.providerMetadata))
        return
    }

    if file.url != nil {
        throw unsupportedModelConversionPart(
            path: "\(path).file",
            message: "URL files can only be converted to model messages when mediaType starts with image/."
        )
    }

    throw unsupportedModelConversionPart(
        path: "\(path).file",
        message: "file parts need inline data or an image URL to be converted to model messages."
    )
}

private func unsupportedModelConversionPart(path: String, message: String) -> AIUIMessageStreamError {
    AIUIMessageStreamError(
        message: "Cannot convert UI messages to model messages.",
        validationIssues: [AIUIMessageValidationIssue(path: path, message: message)]
    )
}

private extension AIUIMessage {
    func omittingPreliminaryToolCalls() -> AIUIMessage {
        let preliminaryToolCallIDs = Set(parts.compactMap { part -> String? in
            guard case let .toolResult(result) = part, result.preliminary else { return nil }
            return result.toolCallID
        })
        guard !preliminaryToolCallIDs.isEmpty else { return self }
        let preliminaryApprovalIDs = Set(parts.compactMap { part -> String? in
            guard case let .toolApprovalRequest(request) = part,
                  let toolCallID = request.toolCallID,
                  preliminaryToolCallIDs.contains(toolCallID) else {
                return nil
            }
            return request.id
        })

        var filtered = self
        filtered.parts.removeAll { part in
            switch part {
            case let .toolCall(call):
                return preliminaryToolCallIDs.contains(call.id)
            case let .toolResult(result):
                return result.preliminary && preliminaryToolCallIDs.contains(result.toolCallID)
            case let .toolApprovalRequest(request):
                return request.toolCallID.map(preliminaryToolCallIDs.contains) ?? false
            case let .toolApprovalResponse(response):
                return preliminaryApprovalIDs.contains(response.id)
            default:
                return false
            }
        }
        return filtered
    }
}
