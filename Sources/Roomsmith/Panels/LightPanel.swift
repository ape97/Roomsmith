import AppKit
import RoomsmithCore
import SwiftUI

/// Sun and sky of the scene: time of day, date, north, mood, shadows, exposure. Every change is one undoable command;
/// sliders commit when the drag ends. Lamps are edited on the furniture (inspector).
struct LightPanel: View {
    @Environment(AppModel.self) private var model

    private var light: LightingSettings { model.project.settings.lighting }

    /// Measured size of the controls. The popover is exactly that wide (the mood buttons decide the width, at least
    /// 300 pt) and that tall, or scrolls when the window or screen is shorter, so no control is ever cut off.
    @State private var contentSize = CGSize(width: 300, height: 320)

    var body: some View {
        ScrollView {
            controls.onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: contentSize.width, height: min(contentSize.height, Self.maxHeight))
    }

    private static var maxHeight: CGFloat {
        // The screen and window the popover belongs to (not the main screen: the window may sit on a smaller one).
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        let inWindow = window.map { $0.frame.height - 90 } ?? screen
        return max(200, min(screen - 160, inWindow))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Light").font(.headline)
            Picker("Mood", selection: moodBinding) {
                ForEach(LightMood.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Atmosphere: daylight, evening, night or overcast. Also moves the time of day to a fitting hour.")
            .accessibilityIdentifier("light.mood")

            CommitSlider(title: "Time", value: Double(light.timeMinutes), range: 0...1439, step: 5,
                         text: { String(format: "%02d:%02d", Int($0) / 60, Int($0) % 60) },
                         hint: "Time of day (local solar time); moves the sun and its shadows") { v in
                model.perform("Set time of day") { $0.updateLighting { $0.timeMinutes = Int(v) } }
            } preview: { v in
                model.previewLight(v) { s, v in s.timeMinutes = Int(v) }
            }
            CommitSlider(title: "Day", value: Double(light.dayOfYear), range: 1...366, step: 1,
                         text: { "day \(Int($0))" },
                         hint: "Day of the year (1 = 1 January, 172 = midsummer); sets the sun's height") { v in
                model.perform("Set day of year") { $0.updateLighting { $0.dayOfYear = Int(v) } }
            } preview: { v in
                model.previewLight(v) { s, v in s.dayOfYear = Int(v) }
            }
            CommitSlider(title: "North", value: light.northDeg, range: LightingSettings.northRange, step: 1,
                         text: { String(format: "%.0f°", $0) },
                         hint: "Where north lies in the plan, counter-clockwise from the plan's up direction") { v in
                model.perform("Set north") { $0.updateLighting { $0.northDeg = v } }
            } preview: { v in
                model.previewLight(v) { s, v in s.northDeg = v }
            }
            CommitSlider(title: "Latitude", value: light.latitudeDeg, range: LightingSettings.latitudeRange, step: 1,
                         text: { String(format: "%.0f°", $0) },
                         hint: "Latitude of the site (positive = north); sets how high the sun climbs") { v in
                model.perform("Set latitude") { $0.updateLighting { $0.latitudeDeg = v } }
            } preview: { v in
                model.previewLight(v) { s, v in s.latitudeDeg = v }
            }
            CommitSlider(title: "Exposure", value: light.exposure, range: -3...3, step: 0.25,
                         text: { String(format: "%+.2f EV", $0) },
                         hint: "Overall brightness of the picture in EV stops") { v in
                model.perform("Set exposure") { $0.updateLighting { $0.exposure = v } }
            } preview: { v in
                model.previewLight(v) { s, v in s.exposure = v }
            }
            Toggle("Sun shadows", isOn: shadowsBinding)
                .help("Shadows cast by the sun. Lamps never cast shadows.")
                .accessibilityIdentifier("light.shadows")
        }
        .frame(minWidth: 272, alignment: .leading)
        .padding(14)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var moodBinding: Binding<LightMood> {
        Binding(get: { light.mood }, set: { new in
            guard new != light.mood else { return }
            _ = model.perform("Set light mood") { $0.applyMood(new, setTime: true) }
        })
    }

    private var shadowsBinding: Binding<Bool> {
        Binding(get: { light.shadows }, set: { new in
            _ = model.perform("Toggle sun shadows") { $0.updateLighting { $0.shadows = new } }
        })
    }
}

/// Slider that shows the draft while dragging and commits once on release.
struct CommitSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String
    var logScale = false
    let hint: String
    let onCommit: (Double) -> Bool
    /// Called with every value while dragging and with nil when the drag ends (live preview, not undoable).
    var preview: ((Double?) -> Void)?
    @State private var draft = 0.0
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(text(draft)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            slider
            .help(hint)
            .accessibilityLabel(title)
            .accessibilityIdentifier("light.\(title.lowercased())")
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, new in draft = new }
        .onChange(of: draft) { _, new in if dragging { preview?(new) } }
        .onDisappear { if dragging { dragging = false; preview?(nil) } }
    }

    /// Log scale lets one slider cover ranges like 1...100000 lm; the shown value stays the real one.
    @ViewBuilder private var slider: some View {
        let finish: (Bool) -> Void = { editing in
            dragging = editing
            if editing { return }
            if draft != value, !onCommit(draft) { draft = value }
            preview?(nil)
        }
        if logScale {
            let lo = log(max(range.lowerBound, 1e-6)), hi = log(range.upperBound)
            Slider(value: Binding(get: { log(min(max(draft, range.lowerBound), range.upperBound)) },
                                  set: { draft = min(max(exp($0).rounded(), range.lowerBound), range.upperBound) }),
                   in: lo...hi, onEditingChanged: finish)
        } else {
            Slider(value: $draft, in: range, step: step, onEditingChanged: finish)
        }
    }
}
