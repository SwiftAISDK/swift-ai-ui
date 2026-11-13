import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public func createAgentUIStream(
    agent: any AIAgent,
    uiMessages: [AIUIMessage],
    options: AIAgentCallOptions = AIAgentCallOptions(),
    messageID: String = UUID().uuidString
) throws -> AsyncThrowingStream<AIUIMessage, Error> {
    let validatedMessages = try validateUIMessages(uiMessages)
    let modelMessages = try convertToModelMessages(validatedMessages)
    return AIUIMessageStreamReducer.snapshots(
        from: agent.stream(messages: modelMessages, options: options),
        messageID: messageID
    )
}

public func createAgentUIStream(
    agent: any AIAgent,
    uiMessages: [AIUIMessage],
    options: AIAgentCallOptions = AIAgentCallOptions(),
    messageID: String = UUID().uuidString,
    convertDataPart: AIUIDataPartConverter?
) throws -> AsyncThrowingStream<AIUIMessage, Error> {
    let validatedMessages = try validateUIMessages(uiMessages)
    let modelMessages = try convertToModelMessages(validatedMessages, convertDataPart: convertDataPart)
    return AIUIMessageStreamReducer.snapshots(from: agent.stream(messages: modelMessages, options: options), messageID: messageID)
}
/// Adds explicit tool-error presentation control while preserving existing overloads.
public func createAgentUIStream(
    agent: any AIAgent,
    uiMessages: [AIUIMessage],
    options: AIAgentCallOptions = AIAgentCallOptions(),
    messageID: String = UUID().uuidString,
    convertDataPart: AIUIDataPartConverter? = nil,
    errorOptions: AIUIMessageErrorOptions
) throws -> AsyncThrowingStream<AIUIMessage, Error> {
    let modelMessages = try convertToModelMessages(try validateUIMessages(uiMessages), convertDataPart: convertDataPart)
    return AIUIMessageStreamReducer.snapshots(from: agent.stream(messages: modelMessages, options: options),
        messageID: messageID, errorOptions: errorOptions)
}
