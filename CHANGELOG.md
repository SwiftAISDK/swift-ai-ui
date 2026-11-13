# Changelog

## 1.2.0

- Add opt-in observable chat message queues with per-message options, cancellation, prioritization, approval ordering and history resets. UI validation stops at the first invalid element and rejects nonfinite provider/tool metadata with bounded errors. Tool errors preserve model history by default, with explicit presentation redaction and later-reasoning warnings; provider-executed errors retain their codes. Reviewed npm delta: ai 7.0.165 to 7.0.172, @ai-sdk/react 4.0.169 to 4.0.176. Validation: `node Scripts/test-packages.mjs` passed all 52 owning suites and 1731 facade tests; tooling 27/27, generation/isolation checks, standalone exports and 106 minimum/latest consumers, documentation check and 101-page build passed. Publication requires green exact-source Swift 6.3.3 CI. Paid/live verification and full-package parity are not claimed.
  Compatibility: Additive native APIs or capabilities under the project minor-release convention. npm baselines and Swift SemVer are independent; this reviewed delta does not establish full-package or live-service parity.
