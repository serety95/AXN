---
name: mobile-development
description: Implement shared Android and iOS app behavior for lifecycle, responsive layout, offline data, auth, and constrained device resources. Use for mobile features that need interruption and recovery tests across platforms.
---

# Mobile Development

## Handle the real lifecycle

- Identify who owns each screen, request, and pending operation. Tie asynchronous work to that lifetime. Handle a permission dialog, a focus change, backgrounding, process eviction, and return from settings according to their effect on the feature. Test repeated pause and resume along with a fresh process restoring an interrupted action.
- Preserve recoverable state at durable boundaries during use. Use compatible schema versions and atomic writes, and test reopening data created by a supported older build. Treat process termination as possible at any point in a multi-step operation.
- For offline writes, persist stable operation IDs and the data required to retry, bound the queue and backoff, and reconcile against the authoritative version. Distinguish confirmed, pending, and retryable outcomes in the UI. Exercise a timeout after the service accepted the write.
- Restore the account session through the platform's existing secure storage. When an account changes, bind pending work and cached private data to the correct identity. Keep credentials, personal data, and purchase payloads out of diagnostic traces.

## Prove the feature on a phone

- Check safe areas, system gestures, text scaling, and input or keyboard occlusion on the smallest relevant layout. Exercise denied permissions, audio interruptions, and network handoff where the feature uses them.
- For startup and performance work, measure from process start to a usable screen or accepted input, and inspect relevant memory, frame-time, and thermal behavior in a representative installed build. Keep the compared device, OS, build type, and scenario fixed. Emulator and simulator runs support functional checks.
- Use `android-development` or `ios-development` for platform tooling, device deployment, and store checks. Apply `mobile-games-principle` when a player's first session, control feel, or on-device game loop is the focus.
