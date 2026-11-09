import RoomsmithCore
import AppKit
import SwiftUI

/// All walk settings in one popover. Every control writes `WalkSettingsStore`, which the frame update reads.
struct WalkSettingsPopover: View {
    let autoScreenHeightMm: Double?

    var body: some View {
        WalkSettingsForm(autoScreenHeightMm: autoScreenHeightMm)
            .frame(width: 340, height: min(520, max(240, (NSScreen.main?.visibleFrame.height ?? 700) - 160)))
    }
}

/// The walk controls as a grouped form, shared by the 3D view's popover and the Settings window.
struct WalkSettingsForm: View {
    let autoScreenHeightMm: Double?
    @State private var store = WalkSettingsStore.shared

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: String,
                        format: String = "%.0f", id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue) + " " + unit).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { Text(title) }
                .labelsHidden()
                .help(title)
                .accessibilityIdentifier("walk.\(id)")
        }
    }

    private func b(_ path: WritableKeyPath<WalkSettings, Double>) -> Binding<Double> {
        Binding(get: { store.settings[keyPath: path] }, set: { store.settings[keyPath: path] = $0 })
    }

    private func flag(_ path: WritableKeyPath<WalkSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: path] }, set: { store.settings[keyPath: path] = $0 })
    }

    private var calibrated: Bool {
        if case .calibrated = store.settings.fovMode { return true }
        return false
    }

    private var standardFov: Binding<Double> {
        Binding(get: { if case .standard(let d) = store.settings.fovMode { return d }; return 60 },
                set: { store.settings.fovMode = .standard(fovDeg: $0) })
    }

    var body: some View {
        Form {
            Section("Body") {
                slider("Body height", b(\.bodyHeightMm), WalkSettings.bodyHeightRange, step: 10, unit: "mm", id: "bodyHeight")
                Toggle("Set eye height directly", isOn: Binding(
                    get: { store.settings.eyeHeightOverrideMm != nil },
                    set: { store.settings.eyeHeightOverrideMm = $0 ? store.settings.eyeHeightMm : nil }))
                    .accessibilityIdentifier("walk.eyeOverride")
                if store.settings.eyeHeightOverrideMm != nil {
                    slider("Eye height", Binding(get: { store.settings.eyeHeightOverrideMm ?? store.settings.eyeHeightMm },
                                                 set: { store.settings.eyeHeightOverrideMm = $0 }),
                           WalkSettings.eyeHeightRange, step: 10, unit: "mm", id: "eyeHeight")
                } else {
                    Text("Eye height \(String(Int(store.settings.eyeHeightMm))) mm").font(.caption).foregroundStyle(.secondary)
                }
                slider("Crouch eye height", b(\.crouchEyeFactor), 0.3...0.9, step: 0.05, unit: "x", format: "%.2f", id: "crouch")
                slider("Body radius", b(\.bodyRadiusMm), 100...400, step: 10, unit: "mm", id: "radius")
            }
            Section("Field of view") {
                Picker("Mode", selection: Binding(get: { calibrated }, set: { on in
                    store.settings.fovMode = on ? .calibrated : .standard(fovDeg: 60)
                })) {
                    Text("Standard").tag(false)
                    Text("Calibrated to screen").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("walk.fovMode")
                if calibrated {
                    slider("Viewing distance", b(\.viewingDistanceMm), 200...2000, step: 10, unit: "mm", id: "viewingDistance")
                    Toggle("Read screen height from the display", isOn: Binding(
                        get: { store.settings.screenHeightMm == nil },
                        set: { store.settings.screenHeightMm = $0 ? nil : (autoScreenHeightMm ?? 190) }))
                        .accessibilityIdentifier("walk.screenAuto")
                    if store.settings.screenHeightMm != nil {
                        slider("Screen height", Binding(get: { store.settings.screenHeightMm ?? 190 }, set: { store.settings.screenHeightMm = $0 }),
                               50...1200, step: 5, unit: "mm", id: "screenHeight")
                    } else if let a = autoScreenHeightMm {
                        Text("Display reports \(String(Int(a))) mm").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Display reports no size; 190 mm assumed").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    slider("Vertical field of view", standardFov, WalkSettings.fovRange, step: 1, unit: "°", id: "fov")
                }
            }
            Section("Movement") {
                slider("Slow (Option)", b(\.speedSlowMps), 0.2...3, step: 0.1, unit: "m/s", format: "%.1f", id: "speedSlow")
                slider("Normal", b(\.speedNormalMps), 0.2...5, step: 0.1, unit: "m/s", format: "%.1f", id: "speedNormal")
                slider("Fast (Shift)", b(\.speedFastMps), 0.5...8, step: 0.1, unit: "m/s", format: "%.1f", id: "speedFast")
                slider("Acceleration", b(\.accelerationMps2), 0.5...20, step: 0.5, unit: "m/s²", format: "%.1f", id: "acceleration")
                Toggle("Collision with walls and furniture", isOn: flag(\.collision)).accessibilityIdentifier("walk.collision")
                Toggle("Head bob", isOn: flag(\.headBob)).accessibilityIdentifier("walk.headBob")
                Toggle("1 m scale bar", isOn: flag(\.showScale)).accessibilityIdentifier("walk.showScale")
            }
            Section("Mouse and controller") {
                slider("Mouse sensitivity", b(\.mouseSensitivity), 0.02...0.6, step: 0.01, unit: "°/pt", format: "%.2f", id: "mouseSensitivity")
                Toggle("Invert vertical look", isOn: flag(\.invertY)).accessibilityIdentifier("walk.invertY")
                slider("Stick deadzone", b(\.controllerDeadzone), 0...0.5, step: 0.01, unit: "", format: "%.2f", id: "deadzone")
                slider("Stick look speed", b(\.controllerSensitivity), 30...360, step: 5, unit: "°/s", id: "controllerSensitivity")

            }
            Section {
                Text("WASD or arrows walk, Shift fast, Option slow, C crouch, E or double click turns the door or window in view, Shift+E or Option double click tilts a window. Controller: left stick walks, right stick looks, A door or window, B crouch.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reset to defaults") { store.reset() }
                    .help("Restore every walk setting to its default")
                    .accessibilityIdentifier("walk.reset")
            }
        }
        .formStyle(.grouped)
    }
}
