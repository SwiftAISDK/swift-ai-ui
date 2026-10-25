import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public struct AIUIMessageStreamError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var chunkType: String?
    public var chunkID: String?
    public var rawValue: JSONValue?
    public var validationIssues: [AIUIMessageValidationIssue]

    public init(
        message: String,
        chunkType: String? = nil,
        chunkID: String? = nil,
        rawValue: JSONValue? = nil,
        validationIssues: [AIUIMessageValidationIssue] = []
    ) {
        self.message = message
        self.chunkType = chunkType
        self.chunkID = chunkID
        self.rawValue = rawValue
        self.validationIssues = validationIssues
    }

    public var description: String {
        guard !validationIssues.isEmpty else { return message }
        return "\(message): \(validationIssues.map(\.description).joined(separator: "; "))"
    }
}