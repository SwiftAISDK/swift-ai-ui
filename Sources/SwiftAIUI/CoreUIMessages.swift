import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public enum AIUIStreamingPartState: String, Equatable, Hashable, Sendable {
    case streaming
    case done
}

public struct AIUITextPart: Equatable, Hashable, Sendable {
    public var id: String?
    public var text: String
    public var state: AIUIStreamingPartState?
    public var providerMetadata: [String: JSONValue]
    public var citations: [AICitation]

    public init(
        id: String? = nil,
        text: String,
        state: AIUIStreamingPartState? = nil,
        providerMetadata: [String: JSONValue] = [:],
        citations: [AICitation] = []
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.providerMetadata = providerMetadata
        self.citations = citations
    }
}

public struct AIUIReasoningPart: Equatable, Hashable, Sendable {
    public var id: String?
    public var text: String
    public var state: AIUIStreamingPartState?
    public var providerMetadata: [String: JSONValue]

    public init(
        id: String? = nil,
        text: String,
        state: AIUIStreamingPartState? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.providerMetadata = providerMetadata
    }
}

public struct AIUIDataPart: Equatable, Hashable, Sendable {
    public var id: String?
    public var value: JSONValue
    public var providerMetadata: [String: JSONValue]

    public init(
        id: String? = nil,
        value: JSONValue,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.value = value
        self.providerMetadata = providerMetadata
    }
}

public enum AIUIMessagePart: Equatable, Hashable, Sendable {
    case text(AIUITextPart)
    case reasoning(AIUIReasoningPart)
    case source(AISource)
    case file(AIStreamFile)
    case reasoningFile(AIStreamFile)
    case toolCall(AIToolCall)
    case toolResult(AIToolResult)
    case toolApprovalRequest(AIToolApprovalRequest)
    case toolApprovalResponse(AIToolApprovalResponse)
    case data(AIUIDataPart)
    case metadata([String: JSONValue])
    case error(message: String, rawValue: JSONValue?)
    case custom(JSONValue, providerMetadata: [String: JSONValue] = [:])
    case raw(JSONValue)
}

/// Static Swift representation of a UI tool result whose execution failed.
/// Swift models the upstream `output-error` state with `AIToolResult.isError`.
public typealias AIUIToolOutputErrorPart = AIToolResult

/// Returns true only for static or dynamic tool results marked as errors.
public func isToolOutputErrorUIPart(_ part: AIUIMessagePart) -> Bool {
    guard case let .toolResult(result) = part else { return false }
    return result.isError
}

/// Typed extraction companion to ``isToolOutputErrorUIPart(_:)``.
public func toolOutputErrorUIPart(_ part: AIUIMessagePart) -> AIUIToolOutputErrorPart? {
    guard case let .toolResult(result) = part, result.isError else { return nil }
    return result
}

public struct AIUIMessage: Equatable, Hashable, Sendable {
    public var id: String
    public var role: MessageRole
    public var parts: [AIUIMessagePart]
    public var metadata: [String: JSONValue]
    /// Static tool calls normalized because their current schema was unavailable
    /// or incompatible. Persist this field alongside the message's parts.
    public var unavailableStaticToolCallIDs: Set<String>

    public init(
        id: String = UUID().uuidString,
        role: MessageRole,
        parts: [AIUIMessagePart] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.init(id: id, role: role, parts: parts, metadata: metadata, unavailableStaticToolCallIDs: [])
    }

    public init(
        id: String = UUID().uuidString,
        role: MessageRole,
        parts: [AIUIMessagePart] = [],
        metadata: [String: JSONValue] = [:],
        unavailableStaticToolCallIDs: Set<String>
    ) {
        self.id = id
        self.role = role
        self.parts = parts
        self.metadata = metadata
        self.unavailableStaticToolCallIDs = unavailableStaticToolCallIDs
    }

    public static func system(
        _ text: String,
        id: String = UUID().uuidString,
        metadata: [String: JSONValue] = [:]
    ) -> AIUIMessage {
        AIUIMessage(
            id: id,
            role: .system,
            parts: [.text(AIUITextPart(text: text))],
            metadata: metadata
        )
    }

    public static func user(
        _ text: String,
        id: String = UUID().uuidString,
        metadata: [String: JSONValue] = [:]
    ) -> AIUIMessage {
        AIUIMessage(
            id: id,
            role: .user,
            parts: [.text(AIUITextPart(text: text))],
            metadata: metadata
        )
    }

    public static func assistant(
        id: String = UUID().uuidString,
        parts: [AIUIMessagePart] = [],
        metadata: [String: JSONValue] = [:]
    ) -> AIUIMessage {
        AIUIMessage(id: id, role: .assistant, parts: parts, metadata: metadata)
    }

    public var text: String {
        parts.compactMap { part in
            if case let .text(textPart) = part {
                return textPart.text
            }
            return nil
        }.joined()
    }

    public var reasoning: String {
        parts.compactMap { part in
            if case let .reasoning(reasoningPart) = part {
                return reasoningPart.text
            }
            return nil
        }.joined()
    }
}

/// Current schemas used to validate persisted static UI tool history.
public struct AIUIMessageToolSchema: Equatable, Sendable {
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?

    public init(inputSchema: JSONValue, outputSchema: JSONValue? = nil) {
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    public init(_ tool: AITool, outputSchema: JSONValue? = nil) {
        self.init(inputSchema: tool.parameters, outputSchema: outputSchema)
    }
}

/// Reconstructs approved tool arguments from the input originally validated by its schema.
public typealias AIUIMessageToolInputRefiner = @Sendable (JSONValue) async throws -> JSONValue