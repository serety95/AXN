---
name: game-development-principles
description: Design or review a game's core loop, rules, progression, or production milestones. Use for engine-independent design decisions, playable slices, fairness, and gameplay acceptance criteria.
---

# Game Development Principles

## Define the playable outcome

- Identify the player action, the decision that makes it interesting, its feedback, and the next useful choice. Play the current build through that sequence before tuning it. For a new loop, specify what the first session should teach and what makes a player want to retry.
- Express a slice as one complete path through the normal entry point, gameplay, outcome, and continuation. Put the riskiest mechanic in that slice. Pick observable success criteria tied to the requested change, such as input reaching the intended action, a reachable route, or progress surviving restart.
- Derive accessibility and content work from the game's actual audience and controls. Use original or licensed assets and keep their provenance with the project. Confirm ownership before adapting existing game material.

## Choose what owns each decision

- Identify the authority for rules, timing, session transitions, saves, and rewards. Keep rendering and feedback separate from decisions that must replay or survive an interruption. Use a fixed tick, seeded generation, and versioned inputs when authoritative replay or deterministic fixtures require them.
- For generated challenges, test the combination of hazards and movement limits at the hardest supported pace. Include transition boundaries where separately valid segments can create an impossible sequence. Preserve the seed, rules version, and input trace for a failure.
- For competitive outcomes and paid entitlements, derive the result from trusted rules or store verification and commit the outcome once across duplicate requests. Keep old saves and in-flight operations readable across version changes.

## Decide with evidence

- Pair tuning or performance comparisons on the same fixture and starting state. Compare player outcomes and resource costs as appropriate to the change. Capture the gameplay sequence when camera, input, effects, or readability are involved.
- Put the most uncertain production risk first. Use the existing toolchain and available assets to measure it before committing to new infrastructure, channels, or content volume. Track what the build supports, what evidence exists, and which decisions need the owner's approval.
- For touch controls and mobile sessions, use `mobile-games-principle`. For Unity implementation and player-build proof, use `unity-game-development`.
