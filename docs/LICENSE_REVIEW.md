# Licence overview

Not legal advice; this records the project's licensing decisions.

## Roomsmith

- Licence: MIT (see `LICENSE`).
- All source code, built-in furniture designs, the app icon and the README media are original work for this project.
- No third-party models, textures, fonts, icons or images are included.

## Dependencies

| Dependency | Use | Licence |
|---|---|---|
| Apple frameworks (Foundation, CoreGraphics, SwiftUI, AppKit, RealityKit, AVFoundation, PDFKit, Vision and similar) | Runtime | Platform SDK terms |
| Third-party Swift packages | none | n/a |

## Tools (not shipped)

| Tool | Use |
|---|---|
| ffmpeg | Converts screen recordings into README GIFs; not part of the app or the build |
| Swift toolchain, Xcode command line tools | Build and test |

## User content

Models and images a user imports stay in the user's project package and are never uploaded. Users are responsible for the licences of what they import.

## Before a release

1. Check every image and font in the repository against this overview.
2. Confirm the README media shows only sample data.
