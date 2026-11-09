import SwiftUI
import RoomsmithCore

/// Parametric furniture builder sheet: templates, live top/front preview, component list and states.
/// The whole edit is kept in a draft; "Save" applies it as ONE undoable command, "Cancel" discards it.
struct FurnitureBuilderView: View {
    let definitionId: UUID?
    /// Set when the builder was opened from a photo proposal: it starts with that template and size (no reset to defaults).
    let draft: PhotoBuilderDraft?
    /// Set when a library entry is edited: after a successful save this gets the recipe (nil once the design no longer
    /// follows it). The builder then works on a scratch project, so "Save and Place" is not offered.
    var onSaved: ((ParametricSpec?) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var def = FurnitureDefinition(name: "New furniture", category: "Custom", size: Size3(800, 500, 900), components: [])
    @State private var loaded = false
    @State private var editsBuiltinCopy = false
    @State private var template: BuilderTemplate = .cabinet
    @State private var params = BuilderParams()
    /// Overall size as typed (mm). Kept in the parent so Generate and Save read the text itself, not a committed value.
    @State private var widthText = ""
    @State private var depthText = ""
    @State private var heightText = ""
    @State private var saving = false
    @State private var tab: Tab = .components
    @State private var selectedComponent: UUID?
    @State private var previewState: UUID?

    private enum Tab: String, CaseIterable, Identifiable { case components = "Components", states = "States", options = "Options"; var id: String { rawValue } }

    init(definitionId: UUID?, draft: PhotoBuilderDraft? = nil, onSaved: ((ParametricSpec?) -> Void)? = nil) {
        self.definitionId = definitionId
        self.draft = draft
        self.onSaved = onSaved
        if let draft {
            // Initial values, not onAppear: changing `template` later would reset the sizes to the template defaults.
            let spec = draft.proposal.spec
            _template = State(initialValue: spec.template)
            _params = State(initialValue: spec.params)
            _widthText = State(initialValue: LengthUnit.mm.format(spec.params.width, withUnit: false))
            _depthText = State(initialValue: LengthUnit.mm.format(spec.params.depth, withUnit: false))
            _heightText = State(initialValue: LengthUnit.mm.format(spec.params.height, withUnit: false))
            _def = State(initialValue: FurnitureDefinition(name: draft.name, category: "Custom", size: spec.params.size, components: []))
        }
    }

    private var materials: [RoomsmithCore.Material] {
        let have = Set(model.project.materials.map(\.id))
        return model.project.materials + BuiltinCatalog.materials.filter { !have.contains($0.id) }
    }
    private var validationError: String? { BuilderSupport.validate(def, project: model.project) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftPane.frame(minWidth: 210, idealWidth: 250, maxWidth: 250)
                Divider()
                centrePane.frame(minWidth: 240, maxWidth: .infinity)
                Divider()
                rightPane.frame(minWidth: 280, idealWidth: 330, maxWidth: 360)
            }
            Divider()
            footer
        }
        // Fits a small MacBook window: the panes shrink to their minimums instead of the sheet being cut off.
        .frame(minWidth: 780, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .onAppear(perform: load)
    }

    // MARK: Left: identity, template, parameters

    private var leftPane: some View {
        Form {
            Section("Furniture") {
                TextField("Name", text: $def.name)
                TextField("Category", text: $def.category)
                LabeledContent("Overall size") {
                    Text("\(def.size.width) × \(def.size.depth) × \(def.size.height) mm").font(.callout.monospacedDigit())
                }
                if editsBuiltinCopy {
                    Text("Built-in designs are not changed: saving creates your own copy.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Template") {
                Picker("Template", selection: $template) {
                    ForEach(BuilderTemplate.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: template) { _, t in params.apply(defaultsOf: t); syncSizeTexts() }
                sizeRow("Width (mm)", $widthText)
                sizeRow("Depth (mm)", $depthText)
                sizeRow("Height (mm)", $heightText)
                if parsedSize == nil {
                    Label("Enter width, depth and height as lengths in mm.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("builderSizeHint")
                } else if sizeChanged {
                    Label("Size changed – press Generate to apply (replaces all components).", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("builderSizePending")
                }
                switch template {
                case .cabinet:
                    stepRow("Shelves", $params.shelves, 0...40)
                    stepRow("Doors", $params.doors, 0...8)
                    intRow("Plinth (mm)", $params.plinth)
                case .table:
                    intRow("Leg inset (mm)", $params.legInset)
                    intRow("Top thickness (mm)", $params.topThickness)
                case .shelf:
                    stepRow("Boards", $params.boards, 1...60)
                case .sofa:
                    intRow("Arm width (mm)", $params.armWidth)
                    intRow("Seat height (mm)", $params.seatHeight)
                case .box:
                    EmptyView()
                }
                Picker("Material", selection: $params.materialId) {
                    Text("None").tag(UUID?.none)
                    ForEach(materials) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Button("Generate") { generate() }
                    .disabled(parsedSize == nil)
                    .help("Replaces all components, states, animations and options with the template result")
                    .accessibilityIdentifier("builderGenerate")
            }
        }
        .formStyle(.grouped)
    }

    /// Length row in millimetres (cm / m suffixes and sums are understood). Parts such as a plinth may be 0.
    private func intRow(_ title: String, _ value: Binding<MM>, range: ClosedRange<MM> = 0 ... sizeLimit.upperBound) -> some View {
        LabeledContent(title) {
            LengthField(title: title, value: value.wrappedValue, unit: .mm, range: range, compact: true) { value.wrappedValue = $0; return true }
                .frame(width: 80)
        }
    }

    private func sizeRow(_ title: String, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            PendingLengthField(title: title, text: text, unit: .mm, range: sizeLimit, emptyIsZero: false).frame(width: 110)
        }
    }

    private var parsedSize: (w: MM, d: MM, h: MM)? {
        guard let w = PendingInput.length(widthText, unit: .mm, range: sizeLimit, emptyIsZero: false),
              let d = PendingInput.length(depthText, unit: .mm, range: sizeLimit, emptyIsZero: false),
              let h = PendingInput.length(heightText, unit: .mm, range: sizeLimit, emptyIsZero: false) else { return nil }
        return (w, d, h)
    }

    /// The typed size differs from the size Generate last used (`params`), so the components do not match it yet.
    private var sizeChanged: Bool {
        guard let s = parsedSize else { return false }
        return s.w != params.width || s.d != params.depth || s.h != params.height
    }

    private func syncSizeTexts() {
        widthText = LengthUnit.mm.format(params.width, withUnit: false)
        depthText = LengthUnit.mm.format(params.depth, withUnit: false)
        heightText = LengthUnit.mm.format(params.height, withUnit: false)
    }

    private func stepRow(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: range)
    }

    // MARK: Centre: preview

    private var centrePane: some View {
        let mats = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parts = BuilderProjection.parts(of: def, stateId: previewState, materials: mats)
        return VStack(spacing: 0) {
            HStack {
                Picker("Preview", selection: $previewState) {
                    Text("Base pose").tag(UUID?.none)
                    ForEach(def.states) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .frame(maxWidth: 260)
                Spacer()
            }
            .padding(8)
            Divider()
            BuilderCanvas(parts: parts, kind: .top, selected: selectedComponent)
            Divider()
            BuilderCanvas(parts: parts, kind: .front, selected: selectedComponent)
        }
    }

    // MARK: Right: components / states / options

    private var rightPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            switch tab {
            case .components:
                BuilderComponentsPane(def: $def, selected: $selectedComponent, materials: materials,
                                      assets: model.project.assets, onGeometryChange: refitSize)
            case .states:
                BuilderStatesPane(def: $def, stateId: $previewState, selectedComponent: $selectedComponent)
            case .options:
                BuilderOptionsPane(def: $def, materials: materials)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let e = validationError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                    .accessibilityIdentifier("builderValidation")
            } else if sizeChanged {
                Label("Size changed – press Generate to apply", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityIdentifier("builderFooterSizePending")
            } else {
                Label("Ready to save", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save(place: false) }
                .disabled(validationError != nil || parsedSize == nil || saving).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("builderSave")
            if onSaved == nil {
                Button("Save and Place") { save(place: true) }
                    .disabled(validationError != nil || parsedSize == nil || saving)
                    .accessibilityIdentifier("builderSavePlace")
            }
            if draft != nil {
                Button("Save to AI Library") { saveToLibrary() }
                    .disabled(validationError != nil || parsedSize == nil || saving)
                    .help("Keep this design in the AI section of the library, with the photos")
                    .accessibilityIdentifier("builderSaveLibrary")
            }
        }
        .padding(10)
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let id = definitionId, var d = model.project.definitions.first(where: { $0.id == id }) {
            if d.builtin {
                d.id = UUID(); d.builtin = false; d.catalogKey = nil; d.name += " (copy)"
                editsBuiltinCopy = true
            }
            def = d
            params.width = d.size.width; params.depth = d.size.depth; params.height = d.size.height
            syncSizeTexts()
            previewState = nil
        } else if draft != nil {
            generate()
        } else {
            params.apply(defaultsOf: template)
            syncSizeTexts()
            def.name = "New cabinet"
            generate()
        }
    }

    /// Saves the edited design into the AI section. The photo recipe is kept only while the design still follows it,
    /// so improving the entry later from a new photo cannot overwrite hand edits.
    private func saveToLibrary() {
        guard let draft, validationError == nil, let size = parsedSize, !saving else { return }
        saving = true
        defer { saving = false }
        var recipe = ParametricSpec(template: template, params: params)
        recipe.params.width = size.w; recipe.params.depth = size.d; recipe.params.height = size.h
        let name = def.name.trimmingCharacters(in: .whitespaces)
        do {
            let follows = FurnitureFromPhoto.follows(def, recipe: recipe)
            _ = try FurnitureFromPhoto.save(definition: def, spec: follows ? recipe : nil, proposal: draft.proposal,
                                            name: name.isEmpty ? template.title : name, hint: draft.hint, images: draft.images,
                                            in: LibraryModel.shared.store)
            model.statusMessage = follows ? "Saved \"\(name)\" to the AI library"
                : "Saved \"\(name)\" to the AI library (edited by hand, so it cannot be improved from photos)"
            dismiss()
        } catch { model.lastError = userMessage(for: error) }
    }

    private func generate() {
        guard let size = parsedSize else { return }
        params.width = size.w; params.depth = size.d; params.height = size.h
        let name = def.name.trimmingCharacters(in: .whitespaces).isEmpty ? template.title : def.name
        let g = params.generate(template, name: name)
        def.components = g.components
        def.states = g.states
        def.defaultStateId = g.defaultStateId
        def.tracks = g.tracks
        def.optionGroups = []
        def.size = g.size
        selectedComponent = nil
        previewState = nil
    }

    private func refitSize() {
        if let s = BuilderSupport.nominalSize(of: def.components), s.isValid { def.size = s }
    }

    private func save(place: Bool) {
        guard validationError == nil, parsedSize != nil, !saving else { return }
        saving = true
        var d = def
        d.name = d.name.trimmingCharacters(in: .whitespaces)
        d.category = d.category.trimmingCharacters(in: .whitespaces)
        let level = model.activeLevelId
        let centre = BuilderSupport.contentCentre(model.project, levelId: level)
        var placed: UUID?
        let ok = model.perform(place ? "Create and Place Furniture" : (model.project.definitions.contains { $0.id == d.id } ? "Edit Furniture" : "Create Furniture")) { p in
            let used = Set(d.components.compactMap(\.materialId))
            for m in BuiltinCatalog.materials where used.contains(m.id) && !p.materials.contains(where: { $0.id == m.id }) {
                _ = p.addMaterial(m)
            }
            if p.definitions.contains(where: { $0.id == d.id }) {
                try p.updateDefinition(d.id) { $0 = d }
            } else {
                _ = p.addDefinition(d)
            }
            if place {
                placed = try p.addInstance(definitionId: d.id, levelId: level, position: P3(centre.x, centre.y, 0))
            }
        }
        guard ok else { saving = false; return }
        if let placed { model.selection = [placed] }
        model.statusMessage = place ? "Created and placed \(d.name)" : "Saved furniture \(d.name)"
        if let onSaved, let size = parsedSize {
            var recipe = ParametricSpec(template: template, params: params)
            recipe.params.width = size.w; recipe.params.depth = size.d; recipe.params.height = size.h
            onSaved(FurnitureFromPhoto.follows(d, recipe: recipe) ? recipe : nil)
        }
        dismiss()
    }
}
