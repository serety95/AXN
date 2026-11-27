---
name: windows-development
description: Build, run, and package Windows desktop apps or games. Use for Windows SDK and architecture checks, Unity standalone previews, DPI and graphics issues, installed smoke tests, and Windows signing.
---

# Windows Development

## Match the Windows target

- Identify the minimum Windows version, target architecture, graphics backend, build profile, and distribution format promised by the project. Use the existing MSBuild, .NET, or Unity build entry point and the required Windows SDK. For Unity, carry the executable with its data folder, player runtime, and native plug-ins.
- Verify launch from the packaged output using a full Windows path, including spaces when realistic. Capture a dedicated player log and the first usable frame. Check available renderers and architecture of native dependencies when initialization fails.

## Verify desktop behavior

- Exercise keyboard and mouse or controller according to the product's supported inputs. Check focus, pause and resume, windowed or full-screen modes, and the intended DPI and aspect ratios. Test system scaling and persistence across restart where the change touches them.
- For a mobile game's Windows preview, use the target portrait aspect for visual review and follow `unity-game-development` for Unity player issues. Windows results establish Windows behavior. Record physical Android and iOS checks as their own evidence.
- Test first run and update with separate test data when the task involves install or migration. Keep persistent user saves intact while switching test builds.

## Verify distribution when requested

- Use the product's chosen channel, such as a portable archive, installer, or MSIX, and verify its full contents and clean install. Use the authorized certificate and signing method for that channel. Verify the signature on the deliverable that users receive. [Microsoft package signing](https://learn.microsoft.com/en-us/windows/win32/appxpkg/how-to-sign-a-package-using-signtool)

Report the Windows version, architecture, graphics backend, artifact, and tested path, with a capture or log where it establishes the result.
