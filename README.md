<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-ui 1.2.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-ui.git", from: "1.2.0")
```

Products: `SwiftAIUI`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# SwiftAIUI

Optional Swift-native UI layer for SwiftAISDK. Maintained in the canonical SwiftAISDK repository and exported as an independent Swift package.

Import `SwiftAIUI` for UI messages, validation and conversion, stream reduction,
`DirectAIChatTransport`, `AIChatSession`, and `createAgentUIStream`.
`AIChatSession` uses Combine and main-actor isolation for native application state.
The core agent and its request options remain in `swift-ai-core`, which does not
import this package. This is not a port of React components or browser rendering.

Delivered steering messages are persisted with their IDs and step numbers.
Use `convertToModelMessages` to replay steering-containing UI history in the
correct assistant/tool/user order while preserving user content metadata.
The singular converter rejects embedded steering, and validation requires the
user role. Exhaustive switches over `AIUIMessagePart` must handle the new
steering-message case.

Run `swift test --package-path Packages/swift-ai-ui` in the canonical checkout.
Upstream mappings and existing UI gaps remain in `Porting/map.json` and the
canonical capability documentation. Distribution manifests are catalog-generated.

## Queued chat messages

Enable `AIChatSession(transport: transport, experimentalQueue: true)` to queue
messages behind the current response. `experimentalQueuedMessages` is observable;
`experimentalRemoveQueuedMessage(_:)` removes an item and
`experimentalSendQueuedMessageNow(_:)` stops owned work before prioritizing it.
Each message retains its headers, body and metadata. Stop, network errors and
interrupted responses pause the queue until the next explicit send. Edits and
regeneration discard queued history. Pending client tools and approvals hold
queued messages; replied approvals reach the model first. The original
initializer keeps immediate replacement behavior. Native automatic-send callbacks
are synchronous, so browser Promise scheduling is represented by generation and
owned-task cancellation rather than a JavaScript decision queue.

Tool errors preserve the model-visible history by default. Set
`DirectAIChatTransport.errorOptions` or pass `errorOptions` to
`createAgentUIStream`/`AIUIMessageStreamReducer.snapshots` for explicit redaction.
A custom `onError` opts into tool redaction unless `redactToolErrors` is false.
Redaction changes restored history and reports a compatibility warning if later
reasoning is streamed. Prefer throwing safe errors inside tools. Native UI uses
`AIToolResult.isError` for failed-tool display, including invalid-input failures;
browser wire chunk names are not a separate native public event protocol.

UI validation stops at the first invalid message, part or citation and rejects
non-finite numbers in provider/tool metadata with a bounded issue. Swift types
already exclude JavaScript functions, bigint and cyclic object values.
