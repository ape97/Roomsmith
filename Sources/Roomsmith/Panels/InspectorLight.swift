import AppKit
import RoomsmithCore
import SwiftUI

/// Lamps of a furniture piece: the on/off switch of this instance and the lamps of its design (shared by all copies).
struct InspectorLightSection: View {
    @Environment(AppModel.self) private var model
    let instanceId: UUID
    let definition: FurnitureDefinition
    let lightOn: Bool

    var body: some View {
        Section("Light") {
            if definition.lights.isEmpty {
                Text("This design has no lamps.").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Lamps on", isOn: Binding(get: { lightOn }, set: { v in
                    _ = model.perform(v ? "Switch lamps on" : "Switch lamps off") { try $0.setLightOn(v, instance: instanceId) }
                }))
                .help("Switch this furniture's lamps on or off (works on locked furniture too)")
                .accessibilityIdentifier("inspector.lightOn")
            }
            ForEach(definition.lights) { e in
                EmitterEditor(definitionId: definition.id, emitter: e, unit: model.unit)
            }
            Button("Add lamp", systemImage: "plus") {
                let top = definition.size.height
                var e = LightEmitter(name: "Lamp \(definition.lights.count + 1)", position: P3(0, 0, top))
                e.kind = .point
                _ = model.perform("Add lamp") { try $0.setEmitter(e, in: definition.id) }
            }
            .controlSize(.small)
            .disabled(definition.lights.count >= LightEmitter.maxPerDefinition)
            .help("Add a lamp to this design (up to \(LightEmitter.maxPerDefinition)); every copy of the design gets it")
            .accessibilityIdentifier("inspector.addLamp")
        }
    }
}

private struct EmitterEditor: View {
    @Environment(AppModel.self) private var model
    let definitionId: UUID
    let emitter: LightEmitter
    let unit: LengthUnit
    @State private var open = false
    /// Colour being picked; committed once after the picker rests (the picker streams values while dragging).
    @State private var colorDraft: Color?

    private func set(_ name: String, _ change: @escaping (inout LightEmitter) -> Void) -> Bool {
        var e = emitter
        change(&e)
        return model.perform(name) { try $0.setEmitter(e, in: definitionId) }
    }

    var body: some View {
        DisclosureGroup(emitter.name, isExpanded: $open) {
            LabeledContent("Name") { NameField(title: "Lamp name", value: emitter.name) { v in set("Rename lamp") { $0.name = v } } }
            Picker("Type", selection: Binding(get: { emitter.kind }, set: { v in _ = set("Change lamp type") { $0.kind = v } })) {
                Text("Point").tag(LightKind.point)
                Text("Spot").tag(LightKind.spot)
            }
            .pickerStyle(.segmented)
            .help("Point lights shine in all directions, spots in a cone")
            LabeledContent("X") { LengthField(title: "Lamp x", value: emitter.position.x, unit: unit) { v in set("Move lamp") { $0.position.x = v } } }
            LabeledContent("Y") { LengthField(title: "Lamp y", value: emitter.position.y, unit: unit) { v in set("Move lamp") { $0.position.y = v } } }
            LabeledContent("Z") { LengthField(title: "Lamp height", value: emitter.position.z, unit: unit) { v in set("Move lamp") { $0.position.z = v } } }
            CommitSlider(title: "Brightness", value: Double(emitter.lumens), range: Double(LightEmitter.lumensRange.lowerBound)...Double(LightEmitter.lumensRange.upperBound), step: 1,
                         text: { "\(Int($0)) lm" }, logScale: true, hint: "Luminous flux; a 60 W bulb is about 800 lm") { v in
                set("Set lamp brightness") { $0.lumens = Int(v) }
            }
            CommitSlider(title: "Warmth", value: Double(emitter.kelvin), range: 1500...12000, step: 100,
                         text: { "\(Int($0)) K" }, hint: "Colour temperature: low = warm, high = cool. Ignored while a colour is set") { v in
                set("Set lamp warmth") { $0.kelvin = Int(v) }
            }
            .disabled(emitter.color != nil)
            LabeledContent("Colour") {
                HStack {
                    ColorPicker("Lamp colour", selection: Binding(get: { colorDraft ?? Color(nsColor: Self.nsColor(emitter.rgb)) },
                                                                  set: { colorDraft = $0 }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Explicit lamp colour; while set it overrides the warmth")
                    .task(id: colorDraft.map(Self.rgbColor)) {
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { commitColor() }
                    }
                    .onDisappear { commitColor() }
                    Button("Use warmth") { _ = set("Use lamp warmth") { $0.color = nil } }
                        .disabled(emitter.color == nil)
                        .help("Drop the explicit colour and use the warmth slider again")
                }
            }
            CommitSlider(title: "Range", value: Double(emitter.rangeMm), range: Double(LightEmitter.rangeMmLimit.lowerBound)...Double(LightEmitter.rangeMmLimit.upperBound), step: 100,
                         text: { String(format: "%.1f m", $0 / 1000) }, logScale: true, hint: "Distance at which the light has faded out") { v in
                set("Set lamp range") { $0.rangeMm = MM(v) }
            }
            if emitter.kind == .spot {
                CommitSlider(title: "Cone", value: emitter.coneDeg, range: 10...150, step: 1,
                             text: { String(format: "%.0f°", $0) }, hint: "Opening angle of the spot") { v in
                    set("Set lamp cone") { $0.coneDeg = v }
                }
                CommitSlider(title: "Tilt", value: emitter.pitchDeg, range: -90...90, step: 1,
                             text: { String(format: "%.0f°", $0) }, hint: "-90 points straight down, 0 horizontally, 90 up") { v in
                    set("Tilt lamp") { $0.pitchDeg = v }
                }
                CommitSlider(title: "Turn", value: emitter.yawDeg, range: -180...180, step: 1,
                             text: { String(format: "%.0f°", $0) }, hint: "Direction of a tilted spot around the vertical axis") { v in
                    set("Turn lamp") { $0.yawDeg = v }
                }
            }
            Button("Delete lamp", systemImage: "trash", role: .destructive) {
                _ = model.perform("Delete lamp") { try $0.removeEmitter(emitter.id, from: definitionId) }
            }
            .controlSize(.small)
            .help("Delete this lamp from the design")
        }
    }

    /// One undo step per picked colour, and none when the picker only re-reports the stored colour.
    private func commitColor() {
        guard let draft = colorDraft else { return }
        colorDraft = nil
        let c = Self.rgbColor(draft)
        if c != emitter.color { _ = set("Set lamp colour") { $0.color = c } }
    }

    private static func nsColor(_ c: SIMD3<Double>) -> NSColor { NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1) }

    private static func rgbColor(_ c: Color) -> RoomsmithCore.RGBColor {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        func u(_ v: CGFloat) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        return RoomsmithCore.RGBColor(u(n.redComponent), u(n.greenComponent), u(n.blueComponent))
    }
}
