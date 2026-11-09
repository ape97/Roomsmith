import AVFoundation
import AVKit
import AppKit
import RoomsmithCore
import SwiftUI

/// Shows the player's video through an `AVPlayerLayer`; a layer is needed for the player clock to run.
struct PresenterPreviewView: NSViewRepresentable {
    let player: AVPlayer?

    final class LayerView: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        v.wantsLayer = true
        v.playerLayer?.videoGravity = .resizeAspect
        v.playerLayer?.backgroundColor = NSColor.black.cgColor
        v.setAccessibilityLabel("Presenter preview")
        return v
    }

    func updateNSView(_ v: LayerView, context: Context) {
        if v.playerLayer?.player !== player { v.playerLayer?.player = player }
    }
}

/// System route button; picking an Apple TV sends the stream there.
struct AirPlayRoutePicker: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setAccessibilityLabel("AirPlay")
        v.player = player
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Controls for presenting the plan, the 3D view or both. Usable on its own: hand it an engine.
struct PresenterPanel: View {
    @Bindable var engine: PresenterEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Primary path: a window on an extra display (Apple TV as separate display) is real time.
            VStack(alignment: .leading, spacing: 6) {
                if engine.isWindowOpen {
                    Button("Close presenter window") { engine.closePresenterWindow() }
                } else {
                    Button(liveTitle) { engine.openLiveWindow() }
                        .disabled(engine.externalDisplayName == nil)
                }
                if engine.externalDisplayName == nil {
                    Text("No extra display yet: on the Mac open Control Center > Screen Mirroring > your Apple TV > Use as Separate Display. The live window then opens by itself. Arrange the TV display at a corner so the pointer stays away.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Text("AirPlay video (2-4 s delay)").font(.caption).foregroundStyle(.secondary)

            Picker("Show", selection: $engine.layout) {
                ForEach(PresenterLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Resolution", selection: $engine.resolution) {
                ForEach(PresenterResolution.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(engine.isPresenting)

            Toggle("Show pointer", isOn: Binding(get: { engine.pointer.isEnabled }, set: { engine.pointer.isEnabled = $0 }))

            HStack {
                if engine.isPresenting {
                    Button("Stop") { engine.stop() }
                } else {
                    Button("Start") { engine.start() }
                        .keyboardShortcut(.defaultAction)
                }
                AirPlayRoutePicker(player: engine.player)
                    .frame(width: 28, height: 28)
                    .opacity(engine.player == nil ? 0.35 : 1)
                    .help("Choose an Apple TV once the preview is running")
                Spacer()
            }

            Text(engine.status.line)
                .font(.callout)
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Presenter status")

            if engine.player != nil {
                PresenterPreviewView(player: engine.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let message = engine.windowMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(minWidth: 280)
        .onAppear { engine.presenterModeActive = true }
        .onDisappear { engine.presenterModeActive = false }
    }

    private var liveTitle: String {
        engine.externalDisplayName.map { "Live (\($0))" } ?? "Live window…"
    }

    private var isFailure: Bool {
        if case .failed = engine.status.state { return true }
        return false
    }
}
