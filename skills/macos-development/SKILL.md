---
name: macos-development
description: Build, run, profile, and distribute macOS desktop apps or games. Use for Unity macOS player builds, Xcode targets, Apple silicon and Intel support, macOS input and graphics, or signing and notarization.
---

# macOS Development

## Build and run on the intended Mac

- Identify the minimum macOS version, deployment channel, and supported architecture. Use the project's Xcode scheme or pinned Unity editor and macOS build module. Check the generated app executable and native plug-ins with `file` or `lipo -archs` when architecture matters. A universal deliverable needs compatible slices for its required native binaries.
- Treat producing an app bundle and running it on macOS as separate checks. Open the packaged app through its normal entry point and inspect its first usable screen, launch logs, and affected behavior. If the current host can only export the app, identify the macOS check that needs a compatible machine.
- Check Metal rendering when relevant, Retina or scaled layouts, focus and window changes, keyboard and trackpad or controller input, and persisted state on restart. Use Instruments for a relevant performance change on the intended hardware. Use `unity-game-development` for Unity player or build failures.

## Verify the chosen distribution path

- For direct distribution that requires Gatekeeper trust, verify the approved Developer ID signing, applicable hardened runtime and entitlements, notarization, and ticket on the final artifact. Check the delivered app on a clean macOS test environment. [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- For Mac App Store distribution, validate the archive, entitlements and sandbox behavior, and current store requirements against the delivered variant. Use the authorized Apple team and distribution route. [Upcoming Apple requirements](https://developer.apple.com/news/upcoming-requirements/) · [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)

Record the output bundle or archive, macOS version, architecture, and evidence for build, run, signing, and distribution checks completed.
