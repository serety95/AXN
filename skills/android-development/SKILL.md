---
name: android-development
description: Build, install, profile, and prepare Android apps or games for Google Play. Use for Android SDK and Gradle setup, Unity Android support, adb, APK and AAB verification, or Android release requirements.
---

# Android Development

## Build the intended artifact

- Inspect the project's application ID, min and target SDK, variant, Gradle wrapper, and existing SDK tools. For Unity, match the pinned Editor's Android Build Support and compatible SDK, NDK, and JDK. Read the first failing Gradle or Unity task before changing dependencies.
- Use a development package and a test application ID when available. Build the APK for local installation. For an AAB, use the existing Play test track or generate compatible APKs with Bundletool when the task calls for install verification. Keep signing keys, passwords, and device identifiers out of committed files and reports. [Android App Bundles](https://developer.android.com/guide/app-bundle) · [Bundletool](https://developer.android.com/tools/bundletool)

## Run the affected path

- List available targets with `adb devices -l` and select the intended target when more than one is attached. Install the intended artifact, exercise the affected path from the normal launcher, and collect relevant, filtered logcat evidence. Use a disposable profile to test clean install or data reset. Check an upgrade with existing data when compatibility matters. [Android Debug Bridge](https://developer.android.com/tools/adb)
- Where relevant, test lifecycle restoration, permission denial, system gesture insets, and the project's supported graphics APIs and device tiers. For game profiling, capture repeatable frame timing, peak memory, and sustained thermal behavior on a physical target. Use `mobile-development` for shared lifecycle and offline recovery.

## Check Play readiness when requested

- Recheck the current Play target API and packaging rules for the intended submission. Check application ID, version code, release signing, native ABIs, and page-size compatibility of native libraries. Verify Data safety answers, the applicable account deletion path, and billing behavior against the built release variant. Use the approved test track when external testing is authorized. [Play target API policy](https://support.google.com/googleplay/android-developer/answer/11926878) · [Android page sizes](https://developer.android.com/guide/practices/page-sizes) · [Play Data safety](https://support.google.com/googleplay/android-developer/answer/10787469)

Record the variant, artifact type, device or emulator, OS, and tested path. Mark physical-device results and Play distribution as pending when their prerequisites are unavailable.
