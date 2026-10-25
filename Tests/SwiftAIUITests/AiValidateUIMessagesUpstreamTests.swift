@testable import SwiftAIUI
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Testing

@Test func aiValidateUIMessagesAcceptsMessageMetadataWithoutSchemaLikeUpstream() throws {
    let message = AIUIMessage(
        id: "1",
        role: .user,
        parts: [
            .text(AIUITextPart(text: "Hello, world!"))
        ],
        metadata: [
            "foo": "bar",
            "count": 1
        ]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesAcceptsCustomAssistantPartLikeUpstream() throws {
    let custom: JSONValue = [
        "kind": "test-provider.compaction"
    ]
    let providerMetadata: [String: JSONValue] = [
        "openai": [
            "itemId": "cmp_123"
        ]
    ]
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [
            .custom(custom, providerMetadata: providerMetadata)
        ]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    let safeResult = safeValidateUIMessages([message])
    #expect(safeResult.isValid)
    #expect(safeResult.messages == [message])
    #expect(safeResult.issues.isEmpty)
}

@Test func aiValidateUIMessagesAcceptsCustomAssistantPartWithoutProviderMetadataLikeUpstream() throws {
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [
            .custom(["kind": "openai.compaction"])
        ]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesAcceptsReasoningPartLikeUpstream() throws {
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [
            .reasoning(AIUIReasoningPart(text: "Hello, world!"))
        ]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesPreservesToolTitlesAndApprovalDescriptors() throws {
    let descriptor: JSONValue = .object([
        "action": .string("deleteAccount"),
        "risk": .string("high")
    ])
    let toolCall = AIToolCall(
        id: "call-1",
        name: "deleteAccount",
        arguments: #"{"userId":"user-123"}"#,
        dynamic: true,
        title: "Delete account"
    )
    let approval = AIToolApprovalRequest(
        id: "approval-1",
        toolName: toolCall.name,
        arguments: toolCall.arguments,
        toolCallID: toolCall.id,
        descriptor: descriptor
    )
    let message = AIUIMessage.assistant(parts: [
        .toolCall(toolCall),
        .toolApprovalRequest(approval)
    ])

    let result = try validateUIMessages([message])

    #expect(result == [message])
    guard case let .toolCall(validatedCall) = result[0].parts[0],
          case let .toolApprovalRequest(validatedApproval) = result[0].parts[1] else {
        Issue.record("Expected validated tool call and approval request")
        return
    }
    #expect(validatedCall.title == "Delete account")
    #expect(validatedApproval.descriptor == descriptor)
    #expect(contentPartTelemetryJSON(.toolApprovalRequest(validatedApproval))["descriptor"] == descriptor)
    #expect(toolApprovalRequestTelemetryJSON(validatedApproval)["descriptor"] == descriptor)
}

@Test func aiValidateUIMessagesAcceptsSourceURLPartLikeUpstream() throws {
    let source = AISource(
        id: "1",
        sourceType: "url",
        url: "https://example.com",
        title: "Example"
    )
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [.source(source)]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesAcceptsSourceDocumentPartLikeUpstream() throws {
    let source = AISource(
        id: "1",
        sourceType: "document",
        title: "Example",
        mediaType: "text/plain",
        filename: "example.txt"
    )
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [.source(source)]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesAcceptsFilePartLikeUpstream() throws {
    let file = AIStreamFile(
        mediaType: "text/plain",
        url: "https://example.com"
    )
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [.file(file)]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesPreservesProviderReferenceOnFilePartLikeUpstream() throws {
    let file = AIStreamFile(
        mediaType: "application/pdf",
        url: "data:application/pdf;base64,abc",
        filename: "document.pdf",
        providerReference: ["openai": "file-abc123"]
    )
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [.file(file)]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).messages.first?.parts == [.file(file)])
}

@Test func aiValidateUIMessagesAcceptsDataPartsLikeUpstream() throws {
    let message = AIUIMessage(
        id: "1",
        role: .assistant,
        parts: [
            .data(AIUIDataPart(id: "foo", value: ["foo": "bar"])),
            .data(AIUIDataPart(id: "bar", value: ["bar": 123]))
        ]
    )

    let result = try validateUIMessages([message])

    #expect(result == [message])
    #expect(safeValidateUIMessages([message]).isValid)
}

@Test func aiValidateUIMessagesAcceptsEmptyAssistantMessagesLikeUpstream() throws {
    let assistant = AIUIMessage(id: "assistant-empty", role: .assistant, parts: [])
    let result = try validateUIMessages([assistant])

    #expect(result == [assistant])
    #expect(safeValidateUIMessages([assistant]).isValid)

    let user = AIUIMessage(id: "user-empty", role: .user, parts: [])
    let safeUser = safeValidateUIMessages([user])
    #expect(!safeUser.isValid)
    #expect(safeUser.issues.contains { issue in
        issue.path == "messages[0].parts" && issue.message.contains("at least one part")
    })
}
