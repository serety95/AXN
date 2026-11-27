---
name: ios-development
description: Build, run, profile, and prepare iOS or iPadOS apps and games for App Store distribution. Use for Unity Xcode exports, Xcode and simulator checks, device signing, privacy manifests, or TestFlight readiness.
---

# iOS Development

## Verify the build stage

- Identify the bundle ID, deployment target, capabilities, package dependencies, and shared scheme. For Unity, match the pinned Editor and iOS Build Support, then use the project's export path and build profile. Preserve reproducible native edits in the project or export step.
- Use macOS with compatible Xcode for the native build. Check `xcodebuild -version`, select the project's workspace or project, and inspect its schemes and supported destinations. Use an existing simulator runtime for functional checks where the target and native libraries support it. Record a Unity-generated Xcode project as an export and an Xcode archive as a separate stage. [Unity iOS build process](https://docs.unity.com/en-us/engine/6000.3/manual/platform-specific/iphone/ios-building-and-delivering/build-process) · [Xcode support](https://developer.apple.com/support/xcode/)
- For physical devices, verify the bundle ID, team, provisioning, entitlements, and signature for the chosen build without exposing credentials. Exercise actual touch and safe areas, background and audio interruptions, and working restore flows. Use Instruments and a representative build for sustained FPS, memory, energy, or thermal measurements.

## Check App Store readiness when requested

- Verify current SDK and submission requirements before archiving for App Store Connect. Inspect the packaged entitlements, privacy manifests, required-reason API usage, and third-party SDK behavior. Verify the applicable privacy labels, deletion flow, tracking consent, and purchase restore with the actual build. Use a test environment for commerce. [Upcoming Apple requirements](https://developer.apple.com/news/upcoming-requirements/) · [Apple privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- Use the user's approved team and distribution route for signing and TestFlight. Report the stage reached, build number, device or simulator and OS, evidence, and pending checks. Apply `mobile-development` to shared lifecycle and data recovery.
