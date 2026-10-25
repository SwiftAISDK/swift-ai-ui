import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public struct AIUIMessageValidationIssue: Equatable, CustomStringConvertible, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(path): \(message)"
    }
}

public struct AIUIMessageValidationResult: Equatable, Sendable {
    public var messages: [AIUIMessage]
    public var issues: [AIUIMessageValidationIssue]

    public init(messages: [AIUIMessage], issues: [AIUIMessageValidationIssue]) {
        self.messages = messages
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }
}

@discardableResult
public func validateUIMessages(_ messages: [AIUIMessage]) throws -> [AIUIMessage] {
    let result = safeValidateUIMessages(messages)
    guard result.isValid else {
        if result.issues.count == 1, let approvalError = firstToolApprovalValidationError(in: messages) {
            throw approvalError
        }
        throw AIUIMessageStreamError(
            message: "Invalid UI messages.",
            validationIssues: result.issues
        )
    }
    return messages
}

public func safeValidateUIMessages(_ messages: [AIUIMessage]) -> AIUIMessageValidationResult {
    var issues: [AIUIMessageValidationIssue] = []
    var messageIDs: Set<String> = []
    var toolCallIDs: Set<String> = []
    var approvalRequestIDs: Set<String> = []

    if messages.isEmpty {
        issues.append(AIUIMessageValidationIssue(path: "messages", message: "messages array must not be empty."))
    }

    for (messageIndex, message) in messages.enumerated() {
        let messagePath = "messages[\(messageIndex)]"
        validateNonEmpty(message.id, path: "\(messagePath).id", label: "message id", issues: &issues)
        if !message.id.isEmpty && !messageIDs.insert(message.id).inserted {
            issues.append(AIUIMessageValidationIssue(path: "\(messagePath).id", message: "message id must be unique."))
        }
        if message.role != .assistant && message.parts.isEmpty {
            issues.append(AIUIMessageValidationIssue(path: "\(messagePath).parts", message: "message must contain at least one part."))
        }

        for (partIndex, part) in message.parts.enumerated() {
            let partPath = "\(messagePath).parts[\(partIndex)]"
            collectPartReferences(part, path: partPath, toolCallIDs: &toolCallIDs, approvalRequestIDs: &approvalRequestIDs, issues: &issues)
        }
    }

    for (messageIndex, message) in messages.enumerated() {
        for (partIndex, part) in message.parts.enumerated() {
            let partPath = "messages[\(messageIndex)].parts[\(partIndex)]"
            validatePartLinks(part, path: partPath, toolCallIDs: toolCallIDs, approvalRequestIDs: approvalRequestIDs, issues: &issues)
        }
    }

    return AIUIMessageValidationResult(messages: messages, issues: issues)
}

/// Validates current static tool schemas and normalizes unavailable terminal history.
@discardableResult
public func validateUIMessages(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema]
) throws -> [AIUIMessage] {
    let result = safeValidateUIMessages(messages, toolSchemas: toolSchemas)
    guard result.isValid else {
        throw AIUIMessageStreamError(message: "Invalid UI messages.", validationIssues: result.issues)
    }
    return result.messages
}

/// Missing terminal static tools retain explicit provenance for safe conversion.
public func safeValidateUIMessages(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema]
) -> AIUIMessageValidationResult {
    safeValidateUIMessages(messages, toolSchemas: toolSchemas, reconstructedInputs: [:])
}

/// Reconstructs preserved approval inputs with the current native tool refiners.
public func safeValidateUIMessages(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema],
    refineToolInput: [String: AIUIMessageToolInputRefiner]
) async -> AIUIMessageValidationResult {
    let originalInputs = preservedApprovalInputs(in: messages)
    var reconstructed: [String: AIUIMessageReconstructedInput] = [:]
    for message in messages {
        for part in message.parts {
            guard case let .toolCall(call) = part, !call.dynamic,
                  let original = originalInputs[call.id],
                  let schema = toolSchemas[call.name],
                  let refine = refineToolInput[call.name] else { continue }
            do {
                try AIJSONSchemaValidator.validate(original, schema: schema.inputSchema)
            } catch {
                continue
            }
            do {
                reconstructed[call.id] = .value(try await refine(original))
            } catch {
                reconstructed[call.id] = .failure(String(describing: error))
            }
        }
    }
    return safeValidateUIMessages(messages, toolSchemas: toolSchemas, reconstructedInputs: reconstructed)
}

@discardableResult
public func validateUIMessages(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema],
    refineToolInput: [String: AIUIMessageToolInputRefiner]
) async throws -> [AIUIMessage] {
    let result = await safeValidateUIMessages(messages, toolSchemas: toolSchemas, refineToolInput: refineToolInput)
    guard result.isValid else {
        throw AIUIMessageStreamError(message: "Invalid UI messages.", validationIssues: result.issues)
    }
    return result.messages
}

private enum AIUIMessageReconstructedInput {
    case value(JSONValue)
    case failure(String)
}

private struct AIUIMessageInputReconstructionError: Error, CustomStringConvertible {
    let description: String
}

private func preservedApprovalInputs(in messages: [AIUIMessage]) -> [String: JSONValue] {
    var inputs: [String: JSONValue] = [:]
    for message in messages {
        for part in message.parts {
            guard case let .toolApprovalRequest(request) = part,
                  let callID = request.toolCallID,
                  let input = request.inputSchemaInput else { continue }
            inputs[callID] = input
        }
    }
    return inputs
}

private func safeValidateUIMessages(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema],
    reconstructedInputs: [String: AIUIMessageReconstructedInput]
) -> AIUIMessageValidationResult {
    var normalized = messages
    var issues: [AIUIMessageValidationIssue] = []
    let originalInputs = preservedApprovalInputs(in: messages)
    var results: [String: (value: AIToolResult, path: String)] = [:]
    var approvalCalls: [String: String] = [:]
    var deniedApprovalIDs: Set<String> = []

    for (messageIndex, message) in messages.enumerated() {
        for (partIndex, part) in message.parts.enumerated() {
            switch part {
            case let .toolResult(result):
                results[result.toolCallID] = (result, "messages[\(messageIndex)].parts[\(partIndex)].toolResult.result")
            case let .toolApprovalRequest(request):
                if let callID = request.toolCallID { approvalCalls[request.id] = callID }
            case let .toolApprovalResponse(response) where !response.approved:
                deniedApprovalIDs.insert(response.id)
            default: break
            }
        }
    }
    let deniedCallIDs = Set(deniedApprovalIDs.compactMap { approvalCalls[$0] })
    var newlyUnavailable: Set<String> = []

    for (messageIndex, message) in messages.enumerated() {
        for (partIndex, part) in message.parts.enumerated() {
            guard case let .toolCall(call) = part, !call.dynamic else { continue }
            let path = "messages[\(messageIndex)].parts[\(partIndex)].toolCall.arguments"
            let resultInfo = results[call.id]
            let result = resultInfo?.value
            let terminal = result != nil || deniedCallIDs.contains(call.id)
            guard let schema = toolSchemas[call.name] else {
                if terminal {
                    newlyUnavailable.insert(call.id)
                } else {
                    issues.append(.init(path: path, message: "No tool schema found for tool '\(call.name)'."))
                }
                continue
            }

            let input: JSONValue
            do {
                input = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .object([:])
                    : try secureJSONParse(call.arguments)
            } catch {
                // Native argument strings must remain valid JSON, including failed calls.
                continue
            }
            do {
                let original = originalInputs[call.id]
                try AIJSONSchemaValidator.validate(original ?? input, schema: schema.inputSchema)
                if let original {
                    switch reconstructedInputs[call.id] ?? .value(original) {
                    case let .failure(message):
                        throw AIUIMessageInputReconstructionError(description: message)
                    case let .value(reconstructed) where reconstructed != input:
                        throw AIUIMessageInputReconstructionError(
                            description: "Tool input does not match the output reconstructed from inputSchemaInput."
                        )
                    case .value: break
                    }
                }
            } catch {
                if result?.isError == true || (result != nil && input.objectValue?.isEmpty == true) {
                    newlyUnavailable.insert(call.id)
                } else {
                    issues.append(.init(path: path, message: String(describing: error)))
                }
            }
            if let result, !result.isError, let outputSchema = schema.outputSchema {
                do {
                    try AIJSONSchemaValidator.validate(result.result, schema: outputSchema)
                } catch {
                    issues.append(.init(path: resultInfo?.path ?? path, message: String(describing: error)))
                }
            }
        }
    }

    for messageIndex in normalized.indices {
        for partIndex in normalized[messageIndex].parts.indices {
            switch normalized[messageIndex].parts[partIndex] {
            case var .toolCall(call) where newlyUnavailable.contains(call.id):
                call.dynamic = true
                normalized[messageIndex].parts[partIndex] = .toolCall(call)
                normalized[messageIndex].unavailableStaticToolCallIDs.insert(call.id)
            case var .toolResult(result) where newlyUnavailable.contains(result.toolCallID):
                result.dynamic = true
                normalized[messageIndex].parts[partIndex] = .toolResult(result)
                normalized[messageIndex].unavailableStaticToolCallIDs.insert(result.toolCallID)
            default: break
            }
        }
    }
    let structural = safeValidateUIMessages(normalized)
    issues.append(contentsOf: structural.issues)
    return AIUIMessageValidationResult(messages: normalized, issues: issues)
}

/// Validates ephemeral agent tool history, including terminal calls to removed tools.
@discardableResult
public func validateUIMessagesForAgent(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema] = [:]
) throws -> [AIUIMessage] {
    try validateUIMessages(messages, toolSchemas: toolSchemas)
}

@discardableResult
public func validateUIMessagesForAgent(
    _ messages: [AIUIMessage],
    toolSchemas: [String: AIUIMessageToolSchema] = [:],
    refineToolInput: [String: AIUIMessageToolInputRefiner]
) async throws -> [AIUIMessage] {
    try await validateUIMessages(messages, toolSchemas: toolSchemas, refineToolInput: refineToolInput)
}

private func firstToolApprovalValidationError(in messages: [AIUIMessage]) -> (any Error)? {
    var toolCallIDs: Set<String> = []
    var approvalRequestIDs: Set<String> = []
    var approvalRequestToolCallIDs: [(approvalID: String, toolCallID: String)] = []
    var approvalResponseIDs: [String] = []

    for message in messages {
        for part in message.parts {
            switch part {
            case let .toolCall(call) where !call.id.isEmpty:
                toolCallIDs.insert(call.id)
            case let .toolApprovalRequest(request):
                if !request.id.isEmpty {
                    approvalRequestIDs.insert(request.id)
                }
                if let toolCallID = request.toolCallID, !toolCallID.isEmpty {
                    approvalRequestToolCallIDs.append((request.id, toolCallID))
                }
            case let .toolApprovalResponse(response) where !response.id.isEmpty:
                approvalResponseIDs.append(response.id)
            default:
                break
            }
        }
    }

    for item in approvalRequestToolCallIDs where !toolCallIDs.contains(item.toolCallID) {
        return AIToolCallNotFoundForApprovalError(
            toolCallID: item.toolCallID,
            approvalID: item.approvalID
        )
    }

    for approvalID in approvalResponseIDs where !approvalRequestIDs.contains(approvalID) {
        return AIInvalidToolApprovalError(approvalID: approvalID)
    }

    return nil
}

private func collectPartReferences(
    _ part: AIUIMessagePart,
    path: String,
    toolCallIDs: inout Set<String>,
    approvalRequestIDs: inout Set<String>,
    issues: inout [AIUIMessageValidationIssue]
) {
    switch part {
    case let .text(text):
        validateOptionalID(text.id, path: "\(path).text.id", issues: &issues)
        validateCitations(text.citations, path: "\(path).text.citations", issues: &issues)
    case let .reasoning(reasoning):
        validateOptionalID(reasoning.id, path: "\(path).reasoning.id", issues: &issues)
    case let .source(source):
        validateNonEmpty(source.id, path: "\(path).source.id", label: "source id", issues: &issues)
    case let .file(file), let .reasoningFile(file):
        validateNonEmpty(file.mediaType, path: "\(path).file.mediaType", label: "file media type", issues: &issues)
        if let id = file.id {
            validateNonEmpty(id, path: "\(path).file.id", label: "file id", issues: &issues)
        }
    case let .toolCall(call):
        validateNonEmpty(call.id, path: "\(path).toolCall.id", label: "tool call id", issues: &issues)
        validateNonEmpty(call.name, path: "\(path).toolCall.name", label: "tool name", issues: &issues)
        validateJSONString(call.arguments, path: "\(path).toolCall.arguments", issues: &issues)
        if !call.id.isEmpty && !toolCallIDs.insert(call.id).inserted {
            issues.append(AIUIMessageValidationIssue(path: "\(path).toolCall.id", message: "tool call id must be unique."))
        }
    case let .toolResult(result):
        validateNonEmpty(result.toolCallID, path: "\(path).toolResult.toolCallID", label: "tool call id", issues: &issues)
        validateNonEmpty(result.toolName, path: "\(path).toolResult.toolName", label: "tool name", issues: &issues)
    case let .toolApprovalRequest(request):
        validateNonEmpty(request.id, path: "\(path).toolApprovalRequest.id", label: "approval request id", issues: &issues)
        validateNonEmpty(request.toolName, path: "\(path).toolApprovalRequest.toolName", label: "tool name", issues: &issues)
        validateJSONString(request.arguments, path: "\(path).toolApprovalRequest.arguments", issues: &issues)
        if let toolCallID = request.toolCallID {
            validateNonEmpty(toolCallID, path: "\(path).toolApprovalRequest.toolCallID", label: "tool call id", issues: &issues)
        }
        if !request.id.isEmpty && !approvalRequestIDs.insert(request.id).inserted {
            issues.append(AIUIMessageValidationIssue(path: "\(path).toolApprovalRequest.id", message: "approval request id must be unique."))
        }
    case let .toolApprovalResponse(response):
        validateNonEmpty(response.id, path: "\(path).toolApprovalResponse.id", label: "approval response id", issues: &issues)
    case let .data(data):
        validateOptionalID(data.id, path: "\(path).data.id", issues: &issues)
    case .metadata:
        break
    case let .error(message, _):
        validateNonEmpty(message, path: "\(path).error.message", label: "error message", issues: &issues)
    case .custom, .raw:
        break
    }
}

private func validatePartLinks(
    _ part: AIUIMessagePart,
    path: String,
    toolCallIDs: Set<String>,
    approvalRequestIDs: Set<String>,
    issues: inout [AIUIMessageValidationIssue]
) {
    switch part {
    case let .toolResult(result):
        if !result.toolCallID.isEmpty && !toolCallIDs.contains(result.toolCallID) {
            issues.append(AIUIMessageValidationIssue(path: "\(path).toolResult.toolCallID", message: "tool result must reference an existing tool call."))
        }
    case let .toolApprovalRequest(request):
        if let toolCallID = request.toolCallID, !toolCallID.isEmpty, !toolCallIDs.contains(toolCallID) {
            issues.append(AIUIMessageValidationIssue(path: "\(path).toolApprovalRequest.toolCallID", message: "approval request must reference an existing tool call."))
        }
    case let .toolApprovalResponse(response):
        if !response.id.isEmpty && !approvalRequestIDs.contains(response.id) {
            issues.append(AIUIMessageValidationIssue(path: "\(path).toolApprovalResponse.id", message: "approval response must reference an existing approval request."))
        }
    default:
        break
    }
}

private func validateNonEmpty(
    _ value: String,
    path: String,
    label: String,
    issues: inout [AIUIMessageValidationIssue]
) {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(AIUIMessageValidationIssue(path: path, message: "\(label) must not be empty."))
    }
}

private func validateOptionalID(_ value: String?, path: String, issues: inout [AIUIMessageValidationIssue]) {
    guard let value else { return }
    validateNonEmpty(value, path: path, label: "id", issues: &issues)
}

private func validateJSONString(_ value: String, path: String, issues: inout [AIUIMessageValidationIssue]) {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do {
        _ = try secureJSONParse(value)
    } catch {
        issues.append(AIUIMessageValidationIssue(path: path, message: "must be valid JSON."))
    }
}

private func validateCitations(_ citations: [AICitation], path: String, issues: inout [AIUIMessageValidationIssue]) {
    for (index, citation) in citations.enumerated() {
        let base = "\(path)[\(index)]"
        let source = citation.source
        let validSource = source.sourceType == "url" ? source.url != nil
            : source.sourceType == "document" && source.mediaType != nil && source.title != nil
        if !validSource { issues.append(.init(path: "\(base).source", message: "Citation requires a URL source or a document with mediaType and title.")) }
        if let value = citation.startIndex, value < 0 { issues.append(.init(path: "\(base).startIndex", message: "Citation offsets must be nonnegative.")) }
        if let value = citation.endIndex, value < 0 { issues.append(.init(path: "\(base).endIndex", message: "Citation offsets must be nonnegative.")) }
    }
}