---
name: mobile-games-principle
description: Design, prototype, tune, or review mobile games, including iOS and Android ports. Use for touch controls, first-session gameplay, on-device performance, or mobile game release readiness.
---

# Mobile Game Principles

Apply the sections that bear on the requested change. Use the project's chosen engine, game rules, and audience. For a new game or port, identify the core action, expected session length, orientation, grip, and lowest supported device tier. State assumptions that affect the design or its acceptance criteria.

## First session and touch controls

- For a new game or major loop change, prove the short path from launch to the first meaningful action, its outcome, and a retry or continuation. Teach each action where it first matters. Schedule optional downloads, sign-in prompts, and monetization around natural breaks.
- Map frequent controls to the intended grip. Try them on a small physical phone with the system gesture area and cutouts present. Check that fingers leave critical cues visible. Test canceled gestures, overlapping touches, and touches that begin on UI and end over gameplay.
- Make critical feedback readable with sound and haptics disabled. When the game's actions allow it, give players a tap or button alternative to precision gestures. Check HUD readability with longer localized strings when localization is in scope.

## Challenge and game feel

- Give players enough time to perceive a hazard, decide, and execute the response at the fastest supported pace. For generated challenges, test reachability using actual movement and timing limits. In a lane-based driver, for example, overlapping obstacles must leave a route the car can reach in time at top speed. Save failing seeds and input traces when available.
- Make feedback follow accepted input promptly, and check that timing-sensitive actions behave consistently across supported frame rates. Adjust rendering quality independently of gameplay timing and input rules.
- Review a rendered gameplay sequence at the game's intended orientation and aspect. Keep the player, upcoming decisions, and controls legible together. Check gameplay and menus independently when they share cameras, canvases, or loading transitions. For a Unity game, use `unity-game-development` to verify the standalone player.

## Device budgets and interruptions

- For performance work, pair before and after runs on the same physical device, build type, settings, and scenario. Choose budgets for the lowest supported tier and measure what the change affects, such as cold-launch time to accepted input, slow frames, or peak memory. Use a representative build and sustain play long enough to observe thermal throttling and repeated-session memory growth when relevant.
- Define what happens to an active session on backgrounding, interruption, process death, and loss of connectivity. Save progress at recoverable boundaries such as checkpoints or completed runs. For offline-capable modes, test a cold launch with no network. For online modes, exercise reconnection and the outcome of retries after a timeout. Use `mobile-development` for shared recovery mechanics.
- Report measured results with the device, build, and scenario. Mark physical-device targets as pending when only editor, desktop, or emulator evidence is available.

## Release and live features

- When release is in scope, verify current platform requirements for the target audience and markets against official sources and the SDKs in the build. Use `android-development` or `ios-development` for the target. Test the applicable consent, deletion, purchase, and restore flows in platform test environments.
- For paid entitlements or competitive rewards, define which system owns the result and test that retries, duplicate notifications, and interrupted sessions produce one durable outcome per operation. When telemetry is in scope, tie events to decisions such as first-session completion, retry friction, or reliability.
