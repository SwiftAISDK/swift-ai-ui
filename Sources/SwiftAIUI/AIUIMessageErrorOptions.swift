import Foundation

/// Tool errors preserve the model's history by default. Providing an error
/// formatter opts into redaction unless `redactToolErrors` is explicitly false.
public struct AIUIMessageErrorOptions: Sendable {
    public var redactToolErrors: Bool?
    public var onError: (@Sendable (String) -> String)?
    public init(redactToolErrors: Bool? = nil, onError: (@Sendable (String) -> String)? = nil) {
        self.redactToolErrors = redactToolErrors
        self.onError = onError
    }
    var shouldRedactToolErrors: Bool { redactToolErrors ?? (onError != nil) }
}
