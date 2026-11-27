---
name: unity-game-development
description: Implement or debug Unity games in C#, including scene lifecycles, packages, render pipelines, platform builds, and player-only failures. Use for Unity code and content changes that need repeatable Editor or standalone verification.
---

# Unity Game Development

## Match the project

- Read `ProjectSettings/ProjectVersion.txt`, `Packages/manifest.json`, `Packages/packages-lock.json`, and the existing build entry point. Use the pinned editor, the selected build profile, and its platform modules. Check license and module availability before changing project configuration or downloading tooling. [Unity Build Profiles](https://docs.unity3d.com/6000.3/Documentation/Manual/build-profiles.html)
- Locate the real Bootstrap scene, composition scopes, active render pipeline, and assembly boundaries. Keep authored asset identities by preserving `.meta` files. Use the existing project DI, async, and asset-loading tools where they fit the change.
- Keep simulation rules independent of Unity presentation when tests or replay depend on them. Cancel scene-owned work when its scope ends, balance Addressables loads and releases, and preallocate bounded pools for frequently spawned objects. Measure frame allocations after warmup on the affected path.

## Verify the actual player

1. Run the repository's relevant EditMode, PlayMode, or batch build targets. Give each run its own log and output path, and keep a single Editor process on a checkout. Use `unity-cli` when installed for a build or test it supports. [Unity Editor command line](https://docs.unity3d.com/6000.3/Documentation/Manual/EditorCommandLineArguments.html)
2. For visible, input, or lifecycle changes, run a player with graphics and inspect the affected screen or transition at the intended layout. Check the first playable frame, UI readability, and the active scene's camera and canvas. A headless run establishes compile or logic evidence.
3. For a magenta player frame, identify the first bad camera, world material, or full-screen UI draw. Compare the player log, render pipeline, graphics API, runtime material references, and stripping rules. Include an explicit reference or targeted shader variant when runtime-created content depends on it. Keep broad shader retention scoped to demonstrated needs. [Unity Shader.Find](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/Shader.Find.html)
4. For visual polish, use `craft-game-floors` for composition and `urp-postprocessing` when the project and effect warrant it. Capture the scene from the built player and check usable controls, object clarity, and resource impact.

Use the requested platform skill for target-specific install, signing, and release checks. In the handoff, name the editor version, target, profile, test results, and evidence paths. Record export, build, installation, and playthrough at the stages actually completed.
