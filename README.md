<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-ui 1.3.1

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-ui.git", from: "1.3.1")
```

Products: `SwiftAIUI`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# SwiftAISDK UI for Swift

`SwiftAIUI` is the optional Swift-native chat and UI-message layer for
[SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK). It provides
`AIUIMessage` values with validation and conversion to model messages, stream
reduction into UI snapshots, `DirectAIChatTransport`, the observable
`AIChatSession`, message queuing and `createAgentUIStream`. It is designed for
SwiftUI and other native state, not a port of React hooks or browser rendering.

- [Chat guide](https://swiftaisdk.github.io/SwiftAISDK/core/chat/)
- [Chat and UI messages API reference](https://swiftaisdk.github.io/SwiftAISDK/components/chat-and-ui-messages/)

## Usage

Add the `SwiftAI` product from `swift-ai-core`, a provider package, and the
`SwiftAIUI` product from this package to your target. The chat guide shows how to
create a session, send messages, render message parts and handle tool approvals.

## Contributing

This package is exported from `Packages/swift-ai-ui` in the canonical
[SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK) repository. Open issues
and pull requests there.
