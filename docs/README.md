# Roomsmith documentation

Roomsmith is a native macOS app (Swift 6, SwiftPM, macOS 26+) for millimetre-exact floor plans and furnishing: 2D
editor, live RealityKit 3D view with X/Y/Z gizmo, furniture builder, groups with configurations, furniture states with
animation, and a local agent API (MCP). Project files are `Name.roomsmith/` packages with a Markdown `project.md`.
Current state: [STATUS.md](STATUS.md).

## For users

| Topic | File |
|---|---|
| Build, scripts, targets, trackpad reference, panels | [DEVELOPMENT.md](DEVELOPMENT.md) |
| File format | [FILE_FORMAT.md](FILE_FORMAT.md) |
| Using Roomsmith from Claude Code | [AGENT_GUIDE.md](AGENT_GUIDE.md) |
| Ready-to-paste AI prompts and the furniture recipe | [AGENT_PROMPTS.md](AGENT_PROMPTS.md) |
| Furniture skill for your AI client | [skills/roomsmith-furniture/SKILL.md](skills/roomsmith-furniture/SKILL.md) |
| Agent API, every tool | [MCP_API.md](MCP_API.md) |
| Presenter mode and AirPlay | [PRESENTER.md](PRESENTER.md) |
| Performance numbers | [PERFORMANCE.md](PERFORMANCE.md) |

## Pictures

All pictures and GIFs in [images/](images/) show the demo project and are rendered by the app itself (recipe:
[DEVELOPMENT.md](DEVELOPMENT.md#screenshots-and-gifs)).

| Kind | Files |
|---|---|
| GIFs | `ai-build`, `orbit`, `walkthrough`, `camera-modes`, `day-to-night`, `lamps`, `doors-states`, `materials` |
| 3D stills | `hero-aerial`, `interior`, `walls-transparent`, `doors-windows`, `evening`, `night`, `prompt-kit-furniture` |
| Room gallery | `gallery-living`, `gallery-dining`, `gallery-kitchen`, `gallery-bedroom`, `gallery-bath`, `gallery-evening-living`, `gallery-night-bedroom` |
| Plans | `plan-dimensions`, `plan-furnished`, `plan` (PDF export, 1:50 on A3) |
| App windows | `app-light`, `app-dark`, `library`, `workspace`, `settings-walk`, `photo-sheet` |

## For contributors

| Topic | File |
|---|---|
| Product spec | [SPEC.md](SPEC.md) |
| Architecture, coordinates, threading | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Decisions | [DECISIONS.md](DECISIONS.md) |
| Hand and agent parity of every feature | [PARITY.md](PARITY.md) |
| Milestones | [ROADMAP.md](ROADMAP.md) |
| Current state | [STATUS.md](STATUS.md) |
| Acceptance tests | [TEST_MATRIX.md](TEST_MATRIX.md) |
| Licences | [LICENSE_REVIEW.md](LICENSE_REVIEW.md) |

## Key rules

1. Everything in the repo is English and public-safe: no secrets, personal data or absolute local paths.
2. Stored lengths are `Int64` millimetres; X east, Y north, Z up; one central RealityKit mapping.
3. All mutations go through the command engine; UI and agents share it.
4. Never claim "done" or "exact" without a passing test or measurement.
5. No fake buttons; unfinished features stay out of the UI.
6. `scripts/check.sh` must be GREEN before a change counts as done.
7. No third-party packages; no code or assets from other projects.

## Build and test

```
scripts/check.sh                                   # full gate: build of all targets + tests -> RESULT: GREEN
swift build --scratch-path .build-<name>
swift test --scratch-path .build-<name>
```
