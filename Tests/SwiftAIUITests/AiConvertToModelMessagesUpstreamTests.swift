@testable import SwiftAIUI
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func aiConvertToModelMessagesPreservesFailedToolResultMetadataOnCall() throws {
    let namespaceMetadata: [String: JSONValue] = [
        "openai": .object(["namespace": .string("widget_tools")])
    ]
    let message = AIUIMessage.assistant(parts: [
        .toolCall(AIToolCall(
            id: "call-1",
            name: "createWidget",
            arguments: "{}"
        )),
        .toolResult(AIToolResult(
            toolCallID: "call-1",
            toolName: "createWidget",
            result: .string("Invalid input"),
            isError: true,
            providerMetadata: namespaceMetadata
        ))
    ])

    let result = try convertToModelMessages([message])

    guard case let .toolCall(toolCall) = result[0].content[0] else {
        Issue.record("Expected tool call")
        return
    }
    #expect(toolCall.providerMetadata == namespaceMetadata)
}

@Test func aiConvertToModelMessagesOmitsPreliminaryToolOutputWhenIgnoringIncompleteCallsLikeUpstream() throws {
    let toolCall = AIToolCall(
        id: "call-preliminary",
        name: "streamingTool",
        arguments: #"{"task":"finish the work"}"#
    )
    let preliminaryResult = AIToolResult(
        toolCallID: toolCall.id,
        toolName: toolCall.name,
        result: ["complete": false, "progress": "half finished"],
        preliminary: true
    )

    let result = try convertToModelMessages([
        .assistant(parts: [
            .toolCall(toolCall),
            .toolResult(preliminaryResult)
        ]),
        .user("Continue.")
    ], ignoreIncompleteToolCalls: true)

    #expect(result == [.user("Continue.")])
}

@Test func aiConvertToModelMessagesConvertsSimpleTextMessagesLikeUpstream() throws {
    let result = try convertToModelMessages([
        .system("System message", id: "system-1"),
        .user("Hello, AI!", id: "user-1"),
        .assistant(id: "assistant-1", parts: [
            .text(AIUITextPart(text: "Hello, human!", state: .done))
        ])
    ])

    #expect(result == [
        .system("System message"),
        .user("Hello, AI!"),
        .assistant("Hello, human!")
    ])
}

@Test func aiConvertToModelMessagesPreservesSystemTextProviderMetadataLikeUpstream() throws {
    let providerMetadata: [String: JSONValue] = [
        "anthropic": [
            "cacheControl": ["type": "ephemeral"]
        ]
    ]

    let result = try convertToModelMessages([
        AIUIMessage(role: .system, parts: [
            .text(AIUITextPart(text: "You are a helpful assistant.", providerMetadata: providerMetadata))
        ])
    ])

    #expect(result == [
        AIMessage(
            role: .system,
            content: [.text("You are a helpful assistant.")],
            providerMetadata: providerMetadata
        )
    ])
}

@Test func aiConvertToModelMessagesMergesSystemTextProviderMetadataLikeUpstream() throws {
    let result = try convertToModelMessages([
        AIUIMessage(role: .system, parts: [
            .text(AIUITextPart(
                text: "Part 1",
                providerMetadata: ["provider1": ["key1": "value1"]]
            )),
            .text(AIUITextPart(
                text: " Part 2",
                providerMetadata: ["provider2": ["key2": "value2"]]
            ))
        ])
    ])

    #expect(result == [
        AIMessage(
            role: .system,
            content: [.text("Part 1 Part 2")],
            providerMetadata: [
                "provider1": ["key1": "value1"],
                "provider2": ["key2": "value2"]
            ]
        )
    ])
}

@Test func aiConvertToModelMessagesPreservesTextProviderMetadataLikeUpstream() throws {
    let providerMetadata: [String: JSONValue] = [
        "testProvider": [
            "signature": "1234567890"
        ]
    ]

    let result = try convertToModelMessages([
        AIUIMessage(role: .user, parts: [
            .text(AIUITextPart(text: "Hello, AI!", providerMetadata: providerMetadata))
        ]),
        AIUIMessage(role: .assistant, parts: [
            .text(AIUITextPart(text: "Hello, human!", state: .done, providerMetadata: providerMetadata))
        ])
    ])

    #expect(result.count == 2)
    #expect(result[0].content == [.text("Hello, AI!", providerMetadata: providerMetadata)])
    #expect(result[1].content == [.text("Hello, human!", providerMetadata: providerMetadata)])
}

@Test func aiConvertToModelMessagesConvertsAssistantReasoningLikeUpstream() throws {
    let result = try convertToModelMessages([
        AIUIMessage(role: .assistant, parts: [
            .reasoning(AIUIReasoningPart(
                text: "Thinking...",
                providerMetadata: ["testProvider": ["signature": "1234567890"]]
            )),
            .reasoning(AIUIReasoningPart(
                text: "redacted-data",
                providerMetadata: ["testProvider": ["isRedacted": true]]
            )),
            .text(AIUITextPart(text: "Hello, human!", state: .done))
        ])
    ])

    #expect(result == [
        AIMessage(role: .assistant, content: [
            .reasoning(
                "Thinking...",
                providerMetadata: ["testProvider": ["signature": "1234567890"]]
            ),
            .reasoning(
                "redacted-data",
                providerMetadata: ["testProvider": ["isRedacted": true]]
            ),
            .text("Hello, human!")
        ])
    ])
}

@Test func aiConvertToModelMessagesSkipsDataPartsWithoutConverterLikeUpstream() throws {
    let result = try convertToModelMessages([
        AIUIMessage(role: .user, parts: [
            .text(AIUITextPart(text: "Hello")),
            .data(AIUIDataPart(value: ["url": "https://example.com"]))
        ]),
        AIUIMessage(role: .assistant, parts: [
            .text(AIUITextPart(text: "Hi", state: .done)),
            .data(AIUIDataPart(value: ["url": "https://example.com"]))
        ])
    ])

    #expect(result == [
        AIMessage(role: .user, content: [.text("Hello")]),
        AIMessage(role: .assistant, content: [.text("Hi")])
    ])
}

@Test func aiConvertToModelMessagesDoesNotEmitEmptyAssistantForPersistentDataBeforeModelStreamLikeUpstream() throws {
    let result = try convertToModelMessages([
        AIUIMessage(id: "msg-123", role: .assistant, parts: [
            .data(AIUIDataPart(
                id: "weather-1",
                value: [
                    "city": "San Francisco",
                    "status": "loading"
                ]
            )),
            .text(AIUITextPart(id: "text-1", text: "It is sunny.", state: .done))
        ])
    ])

    #expect(result == [
        AIMessage(role: .assistant, content: [
            .text("It is sunny.")
        ])
    ])
}

@Test func aiConvertToModelMessagesConvertsCustomAssistantPartsLikeUpstream() throws {
    let custom: JSONValue = [
        "kind": "test-provider.compaction"
    ]
    let providerMetadata: [String: JSONValue] = [
        "openai": [
            "itemId": "cmp_123"
        ]
    ]

    let result = try convertToModelMessages([
        AIUIMessage(
            role: .assistant,
            parts: [
                .custom(custom, providerMetadata: providerMetadata)
            ]
        )
    ])

    #expect(result == [
        AIMessage(
            role: .assistant,
            content: [
                .custom(custom, providerMetadata: providerMetadata)
            ]
        )
    ])
}

@Test func aiConvertToModelMessagesUsesProviderReferenceForFilePartsLikeUpstream() throws {
    let result = try convertToModelMessages([
        AIUIMessage(role: .user, parts: [
            .file(AIStreamFile(
                mediaType: "application/pdf",
                url: "data:application/pdf;base64,abc",
                filename: "doc.pdf",
                providerReference: ["openai": "file-abc123"]
            )),
            .text(AIUITextPart(text: "Summarize this"))
        ]),
        AIUIMessage(role: .assistant, parts: [
            .file(AIStreamFile(
                mediaType: "application/pdf",
                url: "data:application/pdf;base64,xyz",
                filename: "doc.pdf",
                providerReference: ["anthropic": "file-xyz789"]
            ))
        ])
    ])

    #expect(result == [
        AIMessage(role: .user, content: [
            .providerReference(
                mimeType: "application/pdf",
                reference: ["openai": "file-abc123"],
                filename: "doc.pdf"
            ),
            .text("Summarize this")
        ]),
        AIMessage(role: .assistant, content: [
            .providerReference(
                mimeType: "application/pdf",
                reference: ["anthropic": "file-xyz789"],
                filename: "doc.pdf"
            )
        ])
    ])
}

@Test func aiConvertToModelMessagesConvertsAssistantFilePartsLikeUpstream() throws {
    let fileData = Data("test".utf8)
    let providerMetadata: [String: JSONValue] = [
        "testProvider": [
            "signature": "test-signature"
        ]
    ]

    let result = try convertToModelMessages([
        AIUIMessage(
            role: .assistant,
            parts: [
                .file(AIStreamFile(
                    mediaType: "image/png",
                    data: fileData,
                    filename: "test.png",
                    providerMetadata: providerMetadata
                ))
            ]
        )
    ])

    #expect(result == [
        AIMessage(
            role: .assistant,
            content: [
                .file(
                    mimeType: "image/png",
                    data: fileData,
                    filename: "test.png",
                    providerMetadata: providerMetadata
                )
            ]
        )
    ])
}

@Test func aiConvertToModelMessagesSplitsAssistantToolOutputLikeUpstream() throws {
    let providerMetadata: [String: JSONValue] = [
        "testProvider": [
            "signature": "1234567890"
        ]
    ]
    let toolCall = AIToolCall(
        id: "call1",
        name: "calculator",
        arguments: #"{"operation":"add","numbers":[1,2]}"#,
        providerMetadata: providerMetadata
    )
    let toolResult = AIToolResult(
        toolCallID: "call1",
        toolName: "calculator",
        result: "3",
        providerMetadata: providerMetadata
    )

    let result = try convertToModelMessages([
        AIUIMessage(role: .assistant, parts: [
            .text(AIUITextPart(text: "Let me calculate that for you.", state: .done)),
            .toolCall(toolCall),
            .toolResult(toolResult)
        ])
    ])

    #expect(result == [
        AIMessage(role: .assistant, content: [
            .text("Let me calculate that for you."),
            .toolCall(toolCall)
        ]),
        AIMessage(role: .tool, content: [
            .toolResult(toolResult)
        ])
    ])
}

@Test func aiConvertToModelMessagesKeepsProviderExecutedToolOutputInAssistantLikeUpstream() throws {
    let callMetadata: [String: JSONValue] = [
        "testProvider": [
            "itemId": "call-item"
        ]
    ]
    let resultMetadata: [String: JSONValue] = [
        "testProvider": [
            "itemId": "result-item"
        ]
    ]
    let toolCall = AIToolCall(
        id: "call1",
        name: "calculator",
        arguments: #"{"operation":"multiply","numbers":[3,4]}"#,
        providerExecuted: true,
        providerMetadata: callMetadata
    )
    let toolResult = AIToolResult(
        toolCallID: "call1",
        toolName: "calculator",
        result: "12",
        providerExecuted: true,
        providerMetadata: resultMetadata
    )

    let result = try convertToModelMessages([
        AIUIMessage(role: .assistant, parts: [
            .toolCall(toolCall),
            .toolResult(toolResult)
        ])
    ])

    #expect(result == [
        AIMessage(role: .assistant, content: [
            .toolCall(toolCall),
            .toolResult(toolResult)
        ])
    ])
}

@Test func aiConvertToModelMessagesAddsExecutionDeniedResultForDeniedApprovalLikeUpstream() throws {
    let providerMetadata: [String: JSONValue] = [
        "testProvider": [
            "itemId": "approval-response"
        ]
    ]
    let toolCall = AIToolCall(
        id: "call-1",
        name: "weather",
        arguments: #"{"city":"Tokyo"}"#
    )
    let approvalRequest = AIToolApprovalRequest(
        id: "approval-1",
        toolName: "weather",
        arguments: #"{"city":"Tokyo"}"#,
        toolCallID: "call-1"
    )
    let approvalResponse = AIToolApprovalResponse(
        id: "approval-1",
        approved: false,
        reason: "I don't want to approve this",
        providerMetadata: providerMetadata
    )

    let result = try convertToModelMessages([
        AIUIMessage(role: .assistant, parts: [
            .toolCall(toolCall),
            .toolApprovalRequest(approvalRequest),
            .toolApprovalResponse(approvalResponse)
        ])
    ])

    #expect(result == [
        AIMessage(role: .assistant, content: [
            .toolCall(toolCall),
            .toolApprovalRequest(approvalRequest)
        ]),
        AIMessage(role: .tool, content: [
            .toolApprovalResponse(approvalResponse),
            .toolResult(AIToolResult(
                toolCallID: "call-1",
                toolName: "weather",
                result: ["type": "execution-denied", "reason": "I don't want to approve this"],
                providerMetadata: providerMetadata
            ))
        ])
    ])
}

@Test func aiConvertToModelMessagesPreservesConversationOrderLikeUpstream() throws {
    let result = try convertToModelMessages([
        .user("What's the weather like?", id: "user-1"),
        .assistant(id: "assistant-1", parts: [
            .text(AIUITextPart(text: "I'll check that for you.", state: .done))
        ]),
        .user("Thanks!", id: "user-2")
    ])

    #expect(result == [
        .user("What's the weather like?"),
        .assistant("I'll check that for you."),
        .user("Thanks!")
    ])
}
