@testable import SwiftAIUI
@testable import SwiftAI
@testable import SwiftAIProvider
import Foundation
import Testing

// Upstream evidence: ai@7.0.173 packages/ai/src/ui/convert-to-model-messages.ts.

// convert-to-model-messages.test.ts: "should convert an assistant message with reasoning"
@Test func aiConvertToModelMessagesKeepsSignedAndRedactedReasoningLikeUpstream() throws {
    let message = AIUIMessage(role: .assistant, parts: [
        .reasoning(AIUIReasoningPart(text: "Thinking...", state: .done, providerMetadata: ["testProvider": ["signature": "1234567890"]])),
        .reasoning(AIUIReasoningPart(text: "redacted-data", state: .done, providerMetadata: ["testProvider": ["isRedacted": true]])),
        .text(AIUITextPart(text: "Hello, human!", state: .done)),
    ])

    let result = try convertToModelMessages([message])

    #expect(result == [AIMessage(role: .assistant, content: [
        .reasoning("Thinking...", providerMetadata: ["testProvider": ["signature": "1234567890"]]),
        .reasoning("redacted-data", providerMetadata: ["testProvider": ["isRedacted": true]]),
        .text("Hello, human!"),
    ])])
}

// convert-to-model-messages.ts pushes every reasoning UI part, so encrypted reasoning
// with an empty summary keeps its replay metadata.
@Test func aiConvertToModelMessagesKeepsEmptyEncryptedReasoningLikeUpstream() throws {
    let metadata: [String: JSONValue] = ["openai": ["itemId": "rs_1", "reasoningEncryptedContent": "enc"]]
    let message = AIUIMessage(role: .assistant, parts: [
        .reasoning(AIUIReasoningPart(text: "", state: .done, providerMetadata: metadata)),
        .text(AIUITextPart(text: "Answer", state: .done)),
    ])

    let result = try convertToModelMessages([message])

    #expect(result == [AIMessage(role: .assistant, content: [
        .reasoning("", providerMetadata: metadata),
        .text("Answer"),
    ])])
}

// convert-to-model-messages.ts converts assistant reasoning-file parts to `reasoning-file` content.
@Test func aiConvertToModelMessagesKeepsAssistantReasoningFilesLikeUpstream() throws {
    let file = AIStreamFile(
        mediaType: "image/png",
        url: "https://example.com/reasoning.png",
        providerMetadata: ["google": ["thoughtSignature": "sig"]]
    )
    let message = AIUIMessage(role: .assistant, parts: [
        .reasoningFile(file),
        .text(AIUITextPart(text: "Done", state: .done)),
    ])

    let result = try convertToModelMessages([message])

    #expect(result == [AIMessage(role: .assistant, content: [
        .reasoningFile(file),
        .text("Done"),
    ])])
}

// convert-to-model-messages.ts keeps non-image data URLs as file parts (inlined by prompt conversion)
// instead of rejecting them.
@Test func aiConvertToModelMessagesInlinesNonImageDataURLFilesLikeUpstream() throws {
    let message = AIUIMessage(role: .user, parts: [
        .file(AIStreamFile(
            mediaType: "application/pdf",
            url: "data:application/pdf;base64,dGVzdA==",
            filename: "doc.pdf",
            providerMetadata: ["test": ["cache": true]]
        )),
        .text(AIUITextPart(text: "Summarize this")),
    ])

    let result = try convertToModelMessages([message])

    #expect(result == [AIMessage(role: .user, content: [
        .file(mimeType: "application/pdf", data: Data("test".utf8), filename: "doc.pdf", providerMetadata: ["test": ["cache": true]]),
        .text("Summarize this"),
    ])])
}

@Test func aiConvertToModelMessagesStillRejectsRemoteNonImageURLFiles() throws {
    let message = AIUIMessage(role: .user, parts: [
        .file(AIStreamFile(mediaType: "application/pdf", url: "https://example.com/doc.pdf")),
    ])

    #expect(throws: AIUIMessageStreamError.self) {
        _ = try convertToModelMessages([message])
    }
}
