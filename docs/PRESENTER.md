# Roomsmith presenter mode: live plan / 3D to an Apple TV via AirPlay video

Status: the presenter engine, toolbar wiring and the real 3D source are implemented and tested locally (section 11); only the check on a real Apple TV is still open. Original research and probe of 2026-11-08 follow; anything involving an Apple TV is "unverified".

Tool versions used for the evidence below: Swift 6.4, macOS 27 SDK (Darwin 27.0). SDK header references name the framework and header file only (`AVFoundation/AVPlayer.h` etc.), they can be found under `xcrun --show-sdk-path`.

## 1. Goal and constraints

* Send the plan view, the 3D view, or both side by side as **live video** to an Apple TV.
* It must behave like AirPlay for videos (route picker, the TV plays a stream), **not** like an extended or mirrored display. Reason: with a second desktop the mouse pointer wanders onto the TV.
* Latency as low as the platform allows; only mature, public API (Roomsmith rule: no third-party packages).

## 2. Recommendation (short)

| | Choice | Why |
|---|---|---|
| Primary | **Local HLS (fMP4/CMAF) produced with `AVAssetWriter`, served by an `NWListener` HTTP server on the LAN, played by an `AVPlayer` whose route is chosen with `AVRoutePickerView(player:)`** | It is the only public, mature macOS path to AirPlay *video* (external playback). Sample-buffer renderers cannot be routed. Everything else in the pipeline (offscreen render, hardware H.264/HEVC, sync samples at segment starts) was proven locally. |
| Latency target | Plain HLS, 0.25 to 0.5 s segments, `EXT-X-START`: about 1.6 to 2.7 s on loopback in the probe; expect more through the Apple TV. Treat **about 2 to 4 s** as the honest range. | Real LL-HLS (1 to 2 s) needs HTTP/2 and a TLS setup that is hard on a LAN; see 3.2. |
| Fallback A | System "AirPlay a window or app" (macOS 15.2 and later, started by the user from Control Center) | No code, no pointer problem for the user, but not programmable and not a route picker inside the app. |
| Fallback B | AirPlay as a second display plus a borderless window on that `NSScreen` | Lowest latency (mirroring path), but the system pointer can reach the TV and no public API stops it. Document the corner-only arrangement tip. |

Because the offscreen render is the same in all cases, the first work package is useful regardless of which transport wins (it also gives a "presenter window" for fallback B).

## 3. Findings

### 3.1 Which API can send self-generated frames to AirPlay video?

| Candidate | Result | Evidence |
|---|---|---|
| `AVPlayer` + `allowsExternalPlayback` + `AVRoutePickerView.player` | **Works for URL-based media**; this is AirPlay *video* ("external playback": the receiver fetches the stream). macOS 10.11+ / 10.15+. | `AVFoundation/AVPlayer.h` (`AVPlayerExternalPlaybackSupport`: "external playback" vs "external screen" definition); `AVKit/AVRoutePickerView.h`: macOS 10.15+, property `player` is macOS only. |
| `AVSampleBufferDisplayLayer` / `AVSampleBufferVideoRenderer` + `AVSampleBufferRenderSynchronizer` | **Not routable.** No external-playback or output-context API. The only related member is `outputObscuredDueToInsufficientExternalProtection` (protected content). Runtime scan of the three classes for `external/airplay/route/outputContext` members found only that one. The `AVRoutePickerView.h` discussion names `AVPlayer` (and on iOS/tvOS `AVSampleBufferAudioRenderer`) as routable, not the video renderers. | SDK headers `AVSampleBufferDisplayLayer.h`, `AVSampleBufferVideoRenderer.h`; probe step (c). |
| `AVRouteDetector` | Present on macOS 10.13+ (`routeDetectionEnabled`, `multipleRoutesDetected`). Useful to show or hide the AirPlay button. `detectsCustomRoutes` is not on macOS. | `AVFoundation/AVRouteDetector.h` |
| `AVCustomRoutingController`, `AVCustomDeviceRoute`, `AVRoutingPlaybackArbiter`, `AVSystemRoute*` | iOS / tvOS only. The classes exist in the runtime but the headers mark them unavailable on macOS. | `AVRouting.framework/Headers/*`, `AVRoutingPlaybackArbiter.h` (iOS 26 / tvOS 26) |
| `usesExternalPlaybackWhileExternalScreenIsActive`, `externalPlaybackVideoGravity` | iOS / tvOS only (the private ObjC members exist, public headers say not macOS). | `AVPlayer.h` |
| `AVPlayerItemSampleBufferOutput`, `AVSampleBufferVideoRenderer.Receiver` (new in the macOS 27 SDK) | Decode-side / render-side APIs. Irrelevant to AirPlay output. | `AVPlayerItemSampleBufferOutput.h` |
| Private `AVOutputContext` / `AVOutputDevice` route | Classes exist at runtime. Not evaluated further: private API, fragile, would break "mature". | probe step (c) |

Conclusion: to hand a *live* stream to AirPlay video, the app must expose it as a URL that an `AVPlayer` can play. That means HLS (or a progressive fMP4 stream, not evaluated) served over HTTP.

### 3.2 Local HLS / LL-HLS

Pipeline: frames (`CVPixelBuffer`) -> `AVAssetWriter` (`outputFileTypeProfile = .mpeg4AppleHLS`, `preferredOutputSegmentInterval`, delegate `assetWriter(_:didOutputSegmentData:segmentType:segmentReport:)`) -> init segment + media segments + hand-written playlist -> HTTP server -> `AVPlayer`.

Facts from Apple (WWDC20 session 10011, https://developer.apple.com/videos/play/wwdc2020/10011/) and the SDK header `AVAssetWriter.h`:

* The writer needs no output file (`AVAssetWriter(contentType:)`), it delivers `.initialization` (ftyp+moov) and `.separable` (moof+mdat) segments through the delegate.
* It does **not** write a playlist; the app builds the `.m3u8` from `AVAssetSegmentReport` (durations). `EXT-X-TARGETDURATION` must be an integer.
* In encoding mode a video sample at or beyond the interval is forced to a sync sample, so segments have the requested length and start with an IDR (verified: first packet of a segment is flagged as key frame by ffprobe).
* True LL-HLS "parts" that start on non-key frames are not possible with `AVAssetWriter` (every fragment starts at a sync sample). Short GOPs (0.25 to 0.5 s) approximate it at a bitrate cost.

LL-HLS (https://developer.apple.com/documentation/http-live-streaming/enabling-low-latency-http-live-streaming-hls, WWDC19 502 https://developer.apple.com/videos/play/wwdc2019/502/): needs parts (`EXT-X-PART`), blocking playlist reload (`_HLS_msn`, `_HLS_part`), preload hints, delta updates, rendition reports, and an HTTP/2 capable server; an Apple engineer confirms all of the first three are required (https://developer.apple.com/forums/thread/745254). The client silently falls back to normal HLS when the server does not comply. In practice HTTP/2 means TLS with a trusted certificate, which is difficult on a home LAN (no public name, AVPlayer and the Apple TV must trust the certificate), and `NWListener` has no ready HTTP/2 server. **LL-HLS is therefore not the baseline.** Low-latency tuning: `EXT-X-START:TIME-OFFSET`, short segments, short GOP. WWDC19 507 (https://developer.apple.com/videos/play/wwdc2019/507) lists AirPlay 2 HLS requirements (IDR at segment starts, time-aligned variants, no codec switching), which the writer output satisfies.

Plain HLS: the client stays about three target durations behind the live edge, so latency is roughly 3 x target duration plus one segment build time (probe below).

Prerequisites on a real Mac:

* The Apple TV cannot reach `127.0.0.1`. During AirPlay the player must use the Mac's **LAN address** (AirPlay does not rewrite localhost; bind `0.0.0.0` and switch the player URL to the LAN IP while AirPlay is active). Do not hard-code `en0` (TN3179 warns about this); enumerate interfaces or use `NWPathMonitor`. Binding to the LAN raises the macOS firewall prompt on first run, so the app must be properly signed (Developer ID or development identity; ad-hoc signatures make the prompts unreliable).
* Local network privacy (TN3179, https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy; macOS 15 and later): accepting incoming TCP connections needs the permission; connecting to a local-network address needs it; Bonjour needs it; AirPlay itself (high level) does not. `Resources/Info.plist` carries `NSLocalNetworkUsageDescription`. There is no API to query the permission; a blocked `NWConnection` ends in `.waiting` with `unsatisfiedReason == .localNetworkDenied`. Whether the Mac's own `AVPlayer` reading the Mac's LAN IP triggers the prompt is **unverified**.
* ATS: the stream is plain `http://` to an IP address. Expect to need `NSAllowsArbitraryLoadsForMedia` and/or `NSAllowsLocalNetworking` in `Info.plist`. Unverified on the AVPlayer-to-Apple-TV path (the Apple TV does the fetch; ATS is a client-side check of the *Mac* process).
* A custom-scheme `AVAssetResourceLoaderDelegate` is no alternative: the receiver fetches the URL itself (unverified claim, widely reported; confirm on hardware).

### 3.3 How existing products do it

* **Keynote "Play on external display"** and system mirroring: Apple's help describes the Apple TV acting as an external display with mirroring off; guidance is inconsistent between guides; common workaround is System Settings > Displays > + > Apple TV as extended display. This is the second-screen model (fallback B), not video.
* **macOS 15.2** added three AirPlay sharing options (entire screen, a window or app, extended display): https://www.mactrast.com/2024/11/macos-sequoia-15-2-beta-adds-new-airplay-options-more-control-over-what-you-show-on-apple-tv/amp/. System-driven; the app cannot choose the window or start it. Latency and pointer behaviour not measured.
* **AirBeamTV, JustStream (Eltima):** internals are not documented. A 2020 Macworld review measured about 5 s lag for such tools; AirBeamTV advertises "low latency" (marketing only). Treat both as evidence that third parties also end up with seconds of delay.
* **Zoom, OBS plugins:** not researched in detail (unverified); neither is a route-picker AirPlay video path for self-generated frames to my knowledge.

### 3.4 Fallback B: AirPlay display as a second screen

* `CGDisplayHideCursor(display)`: the `display` parameter is ignored (header text), so the cursor cannot be hidden per display. `CGAssociateMouseAndMouseCursorPosition(false)` detaches the mouse globally (not wanted). `CGDisplayCapture` is still available; `CGDisplayCaptureWithOptions` is obsolete (`CoreGraphics/CGDirectDisplay.h`, `CGRemoteOperation.h`). Effect on an AirPlay display is unverified.
* No public API confines the pointer to some displays.
* A borderless `NSWindow` at `screen.frame` on the AirPlay `NSScreen` works for content (plan + 3D side by side, `NSScreen.screens` / `didChangeScreenParametersNotification`). `ignoresMouseEvents` only controls events for the window itself, not where the pointer can go. "Displays have separate Spaces" must be on for a fullscreen window on the second display.
* Mitigations (all untested): arrange displays in System Settings so they only touch at a corner (anecdotal forum reports: https://discussions.apple.com/thread/7477152); a `CGEventTap` that warps the cursor back (needs Input Monitoring / Accessibility permission, flicker risk, an intrusive permission for a design app).

## 4. Feasibility probe (local only)

Setup: a standalone Swift file (not part of the repo) that renders synthetic 1280x720 BGRA frames at 30 fps with CoreGraphics (grid, moving box, and a 20-bit frame counter drawn as black/white blocks so the displayed frame can be decoded from pixels), encodes with `AVAssetWriter` (H.264, real time, `.mpeg4AppleHLS`, `AVVideoMaxKeyFrameIntervalDurationKey` = segment interval, no B-frames), writes `init.mp4`, `segN.m4s` and a sliding `live.m3u8`, serves them from an `NWListener` bound **only to 127.0.0.1**, and plays them with a muted `AVPlayer`; an `AVPlayerItemVideoOutput` reads decoded frames and "glass latency" = wall clock at display minus wall clock at frame creation. No AirPlay detector or picker was instantiated; `AVPlayer.isExternalPlaybackActive` stayed `false`.

Core writer configuration that worked:

```swift
let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
writer.outputFileTypeProfile = .mpeg4AppleHLS
writer.preferredOutputSegmentInterval = CMTime(seconds: 0.5, preferredTimescale: 1000)
writer.initialSegmentStartTime = .zero
writer.delegate = segmenter   // writes init.mp4 / segN.m4s, regenerates live.m3u8
// video input: H.264, expectsMediaDataInRealTime = true,
// AVVideoMaxKeyFrameIntervalDurationKey = interval, AVVideoAllowFrameReorderingKey = false
```

Results:

| Check | Result |
|---|---|
| (a) fMP4 segments from synthetic frames | Works. Init segment 672 bytes; segment durations match the interval (1.000, 0.500 s +-3 ms; 0.25 s gives 0.233/0.267 s because of 30 fps frame boundaries); each segment starts with a key frame (ffprobe: first packet flagged `K`), `moof`+`mdat`. |
| Time to first segment | Interval + about 40 ms (1.037 s for 1 s segments). |
| (b) `AVPlayer` loads the playlist from `http://127.0.0.1:<port>/live.m3u8` | Works. Player start to first decoded frame 0.11 to 0.16 s. A `file://` playlist **did not load** (item status stayed "unknown"), so HTTP is needed even for local preview. |
| (c) SDK symbols | `AVRoutePickerView` (AVKit), `AVRouteDetector`, `AVPlayer.allowsExternalPlayback` (default true) present. Sample-buffer renderers expose no external playback or route member (see 3.1). |

Glass latency on loopback (median of 80 to 240 frames, no stalls, 0 dropped frames, about 0.5 to 1.5 Mbit/s for the synthetic content):

| Segment interval | Player policy | Glass latency |
|---|---|---|
| 2.0 s | player created when 3 segments were listed (starts at playlist head) | 6.14 s |
| 1.0 s | same | 3.14 s |
| 1.0 s | player created when the 6-segment window was full (starts at the player's live-edge point) | 5.17 s |
| 1.0 s | same, `EXT-X-START:TIME-OFFSET=-1.0` | 4.07 s |
| 0.5 s | live-edge start | 2.67 s |
| 0.5 s | `configuredTimeOffsetFromLive = 1.0` | 2.66 s (no effect) |
| 0.5 s | `EXT-X-START:TIME-OFFSET=-1.0` | **1.68 s** |
| 0.5 s | `EXT-X-START` -0.5 / 0 | 2.57 s / 3.17 s (not monotonic; the player clamps) |
| 0.25 s | `EXT-X-START:TIME-OFFSET=-0.5` | **1.57 s** (about 1.45 Mbit/s, segment 46 kB) |

Reading: latency is about 3 x target duration (the target duration is an integer, so 0.5 s segments still declare 1 s) plus segment build time; `EXT-X-START` helps by about one second, `configuredTimeOffsetFromLive` did not help; results are not smooth in the knobs, so tune empirically on the Apple TV. Numbers exclude the Apple TV's own buffering and AirPlay transport.

Pitfalls found by the probe (all reproducible):

1. `AVPlayer.automaticallyWaitsToMinimizeStalling = false` made the player drop to `rate = 0` immediately on a live HLS item (while `timeControlStatus` still reported "playing"), and playback never advanced. Leave the default.
2. In a headless command line process the item clock did not advance until an `AVPlayerLayer` was attached to the player (and an `NSApplication` with `.prohibited` policy existed). In the app a layer or `AVPlayerView` exists anyway, but verify that a hidden preview is enough to keep the clock running while the picker has routed to the TV.
3. Starting the player when the playlist has fewer than about 3 target durations makes it run out of data and pause. Hand the URL to the player only after about 3 segments are listed.
4. Playlist `EXT-X-TARGETDURATION` must be recomputed (ceiling of the longest segment); 1.0 s nominal segments can exceed 1 s by a few ms and need target 2.

## 5. Architecture sketch for Roomsmith

```
PlanNSView draw code ---> offscreen CGContext (BGRA, IOSurface-backed CVPixelBuffer) --\
                                                                                         >-- Compositor --> HLSEncoder --> HLSServer --> AVPlayer --> AirPlay route
RealityRenderer (existing scene) -> MTLTexture (IOSurface) -> CVPixelBuffer -------------/                                           ^ AVRoutePickerView
```

Components (all in the `Roomsmith` target; no third-party code; core geometry stays in `RoomsmithCore`):

1. **Plan offscreen render.** Extract the drawing in `Sources/Roomsmith/Plan/PlanDrawing.swift` (`PlanNSView.draw(_:)`: paper, grid, rooms, walls, openings, feet, groups, dimensions) into a function taking a `CGContext`, a `PlanViewport` and the display scene, without the interaction overlay and HUD. Draw into a `CVPixelBuffer` from a `CVPixelBufferPool` (BGRA, IOSurface). Redraw only when the scene or the viewport changed, or the pointer highlight moved (a static plan produces mostly identical frames; the encoder still needs a steady frame clock, so repeat the last buffer at 15 to 30 fps).
2. **3D offscreen render.** `SceneRenderer` already has `interactive: false` for an offscreen scene. Use `RealityRenderer` (RealityFoundation: `@MainActor init() throws`, `entities`, `activeCamera`, `cameraSettings.colorBackground`, `updateAndRender(deltaTime:cameraOutput:whenScheduled:onComplete:)` with `CameraOutput.Descriptor.singleProjection(colorTexture:)`) to render into an IOSurface-backed `MTLTexture`, wrapped as a `CVPixelBuffer`. The comment in `SceneRenderer.swift` mentions a `SceneSnapshot.render`; that type does not exist in the sources yet, so the presenter would be its first user. Camera: follow the interactive camera, or an independent presenter camera.
3. **Compositor.** Layout enum: `plan`, `scene3D`, `sideBySide` (plan left, 3D right, 16:9 canvas at 1920x1080, or 1280x720 for lower load). Compose with Core Image or `CGContext` into the output pixel buffer; letterbox to keep aspect ratio. Everything offscreen means the **system pointer is never part of the video**.
4. **Pointer highlight.** Because the real pointer is not captured, draw a presenter marker (ring or laser dot) at the plan or 3D position under the pointer while presenting. This turns the "no pointer on the TV" requirement into a feature. It also needs to be off by default for clean slides.
5. **HLSEncoder.** `AVAssetWriter` as in section 4, H.264 (broadest Apple TV support; HEVC later), 6 to 10 Mbit/s for 1080p, key frame interval = segment interval, 0.5 s segments to start with. Segmenter delegate writes segments to memory (ring buffer of about 6 to 8 segments + init) and regenerates the playlist (`EXT-X-MAP`, `EXT-X-INDEPENDENT-SEGMENTS`, `EXT-X-START`, integer target duration, sliding window; no `ENDLIST` while live, add `EXT-X-ENDLIST` on stop).
6. **HLSServer.** `NWListener` on a random port, minimal HTTP/1.1 (GET, optional HEAD/Range, keep-alive, `Cache-Control: no-cache`, correct content types `application/vnd.apple.mpegurl`, `video/mp4`). Bind to loopback for the local preview player and to the LAN interface once an AirPlay route is active; never expose it beyond the LAN, use an unguessable path token (the stream shows private floor plans), and shut it down when presenting stops.
7. **Player + route.** An `AVPlayer` for the URL (`allowsExternalPlayback = true`, default stalling behaviour), shown in a small preview (`AVPlayerLayer`) so the clock runs. Observe `isExternalPlaybackActive` / `externalPlaybackType` to switch the URL host from loopback to the LAN address (and back) and to display status. The route picker is `AVRoutePickerView(player:)` wrapped in an `NSViewRepresentable`.
8. **UI** (in `Sources/Roomsmith/App/ContentView.swift`, `toolbar`): a `ToolbarItemGroup(placement: .primaryAction)` entry with the AirPlay button (picker) next to a layout menu (Plan / 3D / Side by side), a Start/Stop toggle, and a status line (idle, starting, live n s behind, route name, error such as "local network access denied"). Use `AVRouteDetector` to hide the button when no route is available. A separate "presenter window" fallback (fallback B) can reuse the compositor output via an `AVSampleBufferDisplayLayer`.
9. **Settings in `Resources/Info.plist`:** `NSLocalNetworkUsageDescription`, ATS media exception (see 3.2). Bonjour keys are not needed unless Bonjour is used.

Threading: render on the main actor (RealityKit/AppKit constraint), hand `CVPixelBuffer`s to a dedicated serial queue that appends to the writer; drop frames when `isReadyForMoreMediaData` is false instead of queuing.

## 6. Latency budget (target 2 to 4 s end to end, honest range)

| Stage | Expected | Notes |
|---|---|---|
| Render (plan CG + 3D RealityRenderer + compose) | 10 to 40 ms | Probe: CG frame 720p is negligible; 3D render time not measured. |
| Encode (hardware H.264) | 5 to 20 ms per frame | Hardware encoder through AVAssetWriter, not measured here beyond "no dropped frames at 30 fps". |
| Segment build | up to 1 x interval (0.25 to 0.5 s) | A frame is only available when its segment closes. |
| Publication + playlist poll | up to 1 x target duration (1 s for sub-second segments) | LL-HLS blocking reload would remove most of it. |
| Player hold-back | 1 to 3 x target duration | Biggest knob; `EXT-X-START` and short segments. Measured sum for these four stages on loopback: 1.6 to 2.7 s. |
| Mac -> Apple TV fetch + TV buffering + decode | unmeasured, assume +0.3 to 1.5 s | The Apple TV re-fetches the stream itself; its live-edge policy is unverified. |

Fallback B (mirroring path) is typically below 0.5 s (unverified).

## 7. Risks

1. **Latency expectations.** Plain HLS cannot do "instant". A pointer highlight moving on the TV will lag by seconds; fine for slides and walkthroughs, poor for interactive drawing. Mitigation: set expectations in the UI; consider fallback B for live editing.
2. **Apple TV tolerance** of 0.25/0.5 s segments and `EXT-X-START` is unverified. Fall back to 1 s segments (about 3 to 5 s latency).
3. **LAN exposure and permissions:** firewall prompt, Local Network permission, signing. An ad-hoc signed development build may behave differently from a release build. No public API to query the permission, so show an actionable error when the connection fails.
4. **LL-HLS** is unattainable without HTTP/2 and TLS; do not promise it.
5. **Route picker semantics on macOS:** whether picking an Apple TV on a macOS `AVPlayer` item that points at a LAN-reachable HTTP URL starts external playback reliably, and whether it falls back to "mirror" in some configurations, is unverified (needs real hardware).
6. **Hidden preview player:** the pipeline needs the `AVPlayer` clock to run; behaviour with a minimized or hidden window is unverified.
7. **Security and privacy:** unauthenticated HTTP on the LAN exposes the plan to the whole network. Use random paths, close the server on stop.
8. **Private API temptation:** `AVOutputContext` and friends exist but must not be used.
9. **Plan/3D thread constraints:** `RealityRenderer` is main-actor bound; keep render cadence adaptive to avoid stealing time from interactive editing.
10. **HEVC / 4K:** not evaluated; keep H.264 1080p as baseline.

## 8. Test plan without a real Apple TV

1. **Unit tests** (`RoomsmithTests`, no UI): playlist writer (sliding window, target duration ceiling, `MEDIA-SEQUENCE`, `EXT-X-START`, `ENDLIST`), segment ring buffer, interface selection for the LAN address, URL host swap.
2. **Encoder smoke test** (as in section 4): synthetic frames, assert init segment present, every segment starts with a sync sample (parse `moof/trun` first-sample flags or use `ffprobe` if available in CI), durations within +-10 % of the interval.
3. **Loopback integration test:** start `HLSServer` on 127.0.0.1, play with `AVPlayer` + `AVPlayerItemVideoOutput`, decode the frame counter, assert time-to-first-frame < 1 s after the third segment and steady glass latency below a threshold (e.g. 3.5 s with 0.5 s segments). Run with a layer attached; CI-friendly (no network beyond loopback).
4. **Validate the HLS output with Apple tools** when the Advanced Tools for Xcode are installed (`mediastreamvalidator`, `hlsreport`). They were not present on the probe machine.
5. **Route code:** unit-test the status state machine with a fake player (external playback active / inactive, LAN host swap); instantiate `AVRoutePickerView` in a view test (no route selection).
6. **Fallback B:** test the presenter window with a second virtual or physical display; confirm it follows `NSScreen` changes.
7. **Manual Apple TV checklist** (needs the user): route appears in the picker; start latency; steady latency per interval (1 s, 0.5 s, 0.25 s) with a timestamp video; behaviour on Wi-Fi vs. wired; sleep/wake; stop and restart; Local Network prompt; firewall prompt; ATS; whether the real pointer appears on the TV (it should not); what the Mac shows while external playback is active; HDMI-CEC / Apple TV sleep.

## 9. Suggested work packages

1. Offscreen plan render + compositor + preview window (useful for fallback B too).
2. `RealityRenderer` offscreen 3D into a pixel buffer (`SceneSnapshot`).
3. `HLSEncoder` + playlist writer + tests (loopback integration test).
4. `HLSServer` + LAN binding + permissions + Info.plist.
5. Toolbar UI: picker, layout, start/stop, status, pointer highlight.
6. Hardware pass with an Apple TV: tune interval / `EXT-X-START`, decide whether the latency is acceptable or whether fallback B must be the default for live editing.

## 10. Sources

* AVFoundation / AVKit / AVRouting / CoreGraphics / RealityFoundation SDK headers and swiftinterface (macOS 27 SDK).
* WWDC20 10011 Author fragmented MPEG-4 content with AVAssetWriter: https://developer.apple.com/videos/play/wwdc2020/10011/
* Enabling Low-Latency HLS: https://developer.apple.com/documentation/http-live-streaming/enabling-low-latency-http-live-streaming-hls
* WWDC19 502 Introducing Low-Latency HLS: https://developer.apple.com/videos/play/wwdc2019/502/
* WWDC19 507 HLS Authoring for AirPlay 2 Video: https://developer.apple.com/videos/play/wwdc2019/507
* Forum on LL-HLS requirements: https://developer.apple.com/forums/thread/745254
* TN3179 Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
* macOS 15.2 AirPlay sharing options: https://www.mactrast.com/2024/11/macos-sequoia-15-2-beta-adds-new-airplay-options-more-control-over-what-you-show-on-apple-tv/amp/
* Pointer stuck on second display (anecdotal): https://discussions.apple.com/thread/7477152

## 11. Implementation status

Built:

* `Sources/RoomsmithCore/Presenter/`: `PresenterComposition` (layouts, 1080p/720p, exact letterbox), `PresenterCompositor` (CGImage/pixel buffer panes into one BGRA IOSurface buffer), `HLSPlaylist` + `HLSSegmentStore` (sliding window, ring buffer), `HLSEncoder` (AVAssetWriter `.mpeg4AppleHLS`, H.264, 30 fps frame clock that repeats the last frame, drops frames when the input is busy), `HTTPRequest` (pure parser, route token, ranges, responses), `HLSServer` (NWListener, loopback or one LAN interface, never 0.0.0.0, no Bonjour), `PresenterLANAddress` (getifaddrs selection, host swap), `PresenterStatus` (state machine with English messages).
* `Sources/Roomsmith/Presenter/`: `PresenterEngine` (render loop, encoder, server, `AVPlayer`, route observation), `PresenterFrameSource` (+ `PresenterModelFrameSource`: plan through an offscreen `PlanNSView`, 3D through `PresenterSceneBridge`), `PresenterPointer` (laser ring), `PresenterViews` (`PresenterPreviewView`, `AirPlayRoutePicker`, `PresenterPanel`), `PresenterWindowController` (fallback B: borderless window on a chosen screen, Esc closes, closes when the display disappears).
* `PlanDrawing.swift`: `drawPlanContent` and `drawOffscreen(in:viewport:scene:drawExtras:)` draw the plan into any `CGContext` without overlay or tool hint; on-screen drawing is unchanged.
* `Info.plist`: `NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking` (the player fetches `http://` from a LAN address).

Hardening (code review): the HLS server enforces a hard header deadline (default 10 s from connection start or from the end of the last response, never extended by incoming bytes, so a slowloris client is cut off), at most 8 connections per source address and 16 in total (`HLSServer.Limits`, injectable for tests). A listener that dies after `.ready` calls `onFailure`; the engine then shows "Stream server stopped – network changed?". `stop()` before `.ready` ends `start()` with `CancellationError`; a server is single-use (also after its listener died) and a second `start()` throws. The engine re-renders when the compositor has no free buffer. The plan crop is fitted again whenever the project revision changes (the plan may have grown). It deliberately does not follow the main window zoom or pan: the viewer always sees the whole plan.

Network rules: nothing listens before the user presses Start. With `ROOMSMITH_TEST_MODE=1` the server always binds 127.0.0.1. Otherwise Start binds the LAN interface address (required: the Apple TV fetches the stream itself, a loopback URL cannot work) and the player uses that URL; without a usable LAN address it falls back to loopback. `isExternalPlaybackActive` is polled for the status line only.

Tests (`Tests/RoomsmithCoreTests/PresenterTests.swift`, `PresenterStreamTests.swift`, Swift Testing): composition and letterbox, playlist and store, HTTP parser (valid, traversal, invalid, oversize, wrong token), range and responses, interface selection and host swap, status machine with fake events, encoder smoke test (init segment, at least 3 segments, first sample of every segment is a sync sample read from `trun`/`tfhd`, durations within 10 %), loopback integration (playlist, init and segment over URLSession, content types, 404 for wrong or missing token, HEAD, clean stop). The App target compiles; the UI, the window and AVPlayer playback are not covered by automated tests (the app was not started).

Only a real Apple TV can verify: the route appears and plays, steady latency per interval, Wi-Fi vs. wired, sleep/wake, the Local Network prompt and its denial message, firewall prompt, that the pointer stays off the TV, what the Mac shows during external playback, HDMI-CEC/Apple TV sleep. Whether the denial error mapping (POSIX EPERM/EACCES, DNS error -65570) matches the real system is unverified.

Manual checklist (section 8.7): route appears in the picker; start latency; steady latency per interval (1 s, 0.5 s, 0.25 s) with a timestamp video; Wi-Fi vs. wired; sleep/wake; stop and restart; Local Network prompt; firewall prompt; ATS; the real pointer must not appear on the TV; what the Mac shows while external playback is active; HDMI-CEC / Apple TV sleep.

Wiring (done): `ContentView` creates `PresenterEngine(source: PresenterModelFrameSource(model: model))` once (`model.presenter`). The toolbar button "Present" (View > Present…, Option-Command-P) opens `PresenterPanel(engine:)` as a sheet of the main window (`model.showPresenter`; the menu item works even when the toolbar item is removed). A small background view in `ContentView` observes `model.cursorPoint` (so mouse moves do not re-evaluate the whole body) and calls `engine.reportPointer`. The 3D pane comes from `PresenterSceneBridge`: while the engine runs, a main-actor task polls at most 15 times per second and draws a picture only when the project id or revision, active level, view settings (ceilings, lamps, only active level, wall opacity), requested size or camera changed. It keeps one `OffscreenSceneSession` (`Sources/Roomsmith/Scene/OffscreenSceneSession.swift`) while it runs: a camera move draws one frame (about 24 ms at 960 x 1080 instead of about 825 ms for a fresh `SceneSnapshot.render`, which made the TV picture lag), a document or view change rebuilds the scene graph in the same renderer, and stopping or a size change closes the session (camera: `SceneSnapshot.liveView?.renderer.camera.rig.state`, else `project.camera`). It keeps the last image; `sceneFrame(size:)` returns it (placeholder "Preparing 3D view…" until the first render) and `contentStamp` rises with every new image. The size is passed through `PresenterFrameSource.setSceneSize(_:)` (nil when the render loop stops, which stops rendering). A render error is shown as `Presenter 3D view: …` in the error line. Check hooks (test mode only): `ROOMSMITH_SHOW_PRESENTER=1|start`; `ROOMSMITH_PRESENTER_3D=<png>` writes every finished 3D pane picture to that file and prints `ROOMSMITH_PRESENTER_3D n=… ms=…` (the preview video stays black in window pictures).

Latency tuning: the stream drifted behind the live view. Changes: `AVPlayer.automaticallyWaitsToMinimizeStalling = false`, item `preferredForwardBufferDuration` 1 s, `configuredTimeOffsetFromLive` 1 s with `automaticallyPreservesTimeOffsetFromLive`; a live-edge catch-up (`PresenterLiveEdge` in Core, pure and unit tested) that seeks to `seekable end - 1 s` with zero tolerance when the measured distance stays above 2.5 s for 2 samples, at most once per 5 s (all values are defaults, not measured). The panel names an extra display (AirPlay as separate screen) as the lowest-delay target, because that path has no HLS buffering. Honest statement: expect about 2 to 4 s through HLS, not less; whether the tuning removes the drift on a real Apple TV is unverified and needs a live check with a timestamp video (the AirPlay receiver keeps its own buffer, which the app cannot shrink).

Priority change (the stream must be truly live): the **primary path is the presenter window on an extra display** (Control Center > Screen Mirroring > Apple TV > Use as Separate Display). It uses the system mirroring path and is real time; the HLS/AirPlay-video path stays as a secondary option labelled "2-4 s delay". Implementation: `PresenterScreenChoice` (Core, pure, tested) picks the external display (AirPlay/Apple TV name first, else the newest, never the main one); `PresenterEngine` listens to `didChangeScreenParametersNotification` and, while the panel is open or a stream runs, opens the window on a newly connected display by itself. While the window is open the render loop ticks every 16 ms (about 60 Hz, renders only when the content changed); without a window it stays at 50 ms. The panel lists the live window first ("Live (<display>)"; the button uses the same screen choice as the auto-open, is disabled without an extra display, and the window never opens on the Mac's own screen) and shows a how-to when no extra display exists; the HLS controls below are labelled "AirPlay video (2-4 s delay)". The window opens by itself once per display: after the user closes it (Esc) it stays closed until that display is reconnected or the button is pressed. Pointer: macOS lets the system pointer reach the TV display, so arrange the TV display in System Settings > Displays so that it only touches the Mac display at a corner. Unverified without hardware: the auto-open on a real Apple TV, the real frame rate on the TV, and the pointer behaviour.
