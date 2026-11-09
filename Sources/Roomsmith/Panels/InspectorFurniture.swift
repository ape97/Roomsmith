import SwiftUI
import RoomsmithCore

struct InspectorFurnitureView: View {
    @Environment(AppModel.self) private var model
    @State private var productSheet = false
    @State private var materialsExpanded = false
    let id: UUID

    var body: some View {
        let p = model.project
        if let inst = p.instance(id), let def = p.definition(inst.definitionId) {
            let u = model.unit
            let locked = p.isLocked(id)
            let state = inst.stateId.flatMap { sid in def.states.first { $0.id == sid } }
            let size = inst.size ?? state?.size ?? def.size
            Form {
                Section("Furniture") {
                    Group {
                        LabeledContent("Name") { NameField(title: "Furniture name", value: inst.name) { model.rename(id, to: $0) } }
                        LabeledContent("X") { len("Position x", inst.position.x, u) { v in move(inst) { $0.position.x = v } } }
                        LabeledContent("Y") { len("Position y", inst.position.y, u) { v in move(inst) { $0.position.y = v } } }
                        LabeledContent("Z") { len("Height above floor", inst.position.z, u) { v in move(inst) { $0.position.z = v } } }
                        LabeledContent("Rotation") {
                            AngleField(title: "Rotation", value: inst.rotationDeg) { v in
                                model.perform("Rotate") { try $0.updateInstance(id) { $0.rotationDeg = v } }
                            }
                        }
                    }
                    .disabled(locked)
                    Toggle("Locked", isOn: Binding(get: { inst.locked }, set: { v in model.perform(v ? "Lock" : "Unlock") { try $0.setLocked([id], v) } }))
                    Toggle("Visible", isOn: Binding(get: { inst.visible }, set: { v in model.perform(v ? "Show" : "Hide") { try $0.setVisible([id], v) } }))
                    Toggle("Allow overlap", isOn: Binding(get: { inst.allowsOverlap }, set: { v in
                        model.perform(v ? "Allow Overlap" : "Forbid Overlap") { try $0.updateInstance(id) { $0.allowsOverlap = v } }
                    }))
                    .disabled(locked)
                    .help("Other furniture, walls and openings may overlap this furniture without a collision warning, and it never stops dragged furniture")
                    .accessibilityIdentifier("inspector.allowsOverlap")
                    if CollisionChecker.isFlatOnFloor(inst, definition: def) {
                        Text("Flat floor items never collide")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Size") {
                    Group {
                        LabeledContent("Width") { len("Width", size.width, u, sizeLimit) { v in resize(inst, size) { $0.width = v } } }
                        LabeledContent("Depth") { len("Depth", size.depth, u, sizeLimit) { v in resize(inst, size) { $0.depth = v } } }
                        LabeledContent("Height") { len("Height", size.height, u, sizeLimit) { v in resize(inst, size) { $0.height = v } } }
                        Button("Reset size") { model.perform("Reset Size") { try $0.updateInstance(id) { $0.size = nil } } }
                            .controlSize(.small)
                            .disabled(inst.size == nil)
                            .help("Use the size of the design again")
                    }
                    .disabled(locked)
                }
                Section("Design") {
                    LabeledContent("Design") { Text(def.name) }
                    if !def.builtin {
                        Button("Edit design…") { model.sheet = .furnitureBuilder(def.id) }
                            .controlSize(.small).help("Open the furniture builder")
                    }
                    if !def.states.isEmpty {
                        Picker("State", selection: Binding(get: { inst.stateId }, set: { sid in
                            model.perform("Change State") { try $0.activateState([id], stateId: sid) }
                        })) {
                            Text("Base pose").tag(UUID?.none)
                            ForEach(def.states) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .disabled(locked)
                    }
                }
                if !def.optionGroups.isEmpty {
                    Section("Options") {
                        ForEach(def.optionGroups) { g in
                            Picker(g.name, selection: Binding(get: { g.effectiveChoice(selected: inst.optionSelection[g.id])?.id }, set: { cid in
                                guard let cid else { return }
                                model.perform("Change Option") { try $0.setOptions([id], select: [g.id: cid]) }
                            })) {
                                ForEach(g.choices) { Text($0.name).tag(UUID?.some($0.id)) }
                            }
                            .disabled(locked)
                            .accessibilityIdentifier("inspector.option.\(g.name)")
                        }
                    }
                }
                Section {
                    DisclosureGroup("Materials of parts", isExpanded: $materialsExpanded) {
                        Group {
                            Menu("Apply to all components") {
                                ForEach(p.materials) { m in
                                    Button(m.name) { model.perform("Set Material") { try $0.setMaterial([id], slot: .allComponents, materialId: m.id) } }
                                }
                                Divider()
                                Button("Reset to design") { model.perform("Reset Materials") { try $0.setMaterial([id], slot: .allComponents, materialId: nil) } }
                            }
                            ForEach(def.components) { c in
                                let base = c.materialId.flatMap { p.material($0)?.name }
                                MaterialPicker(title: c.name, materials: p.materials, selection: inst.materialOverrides[c.id],
                                               defaultLabel: base.map { "Design (\($0))" } ?? "Design default", stacked: true) { m in
                                    model.perform("Set Material") { try $0.setMaterial([id], slot: .component(c.id), materialId: m) }
                                }
                            }
                        }
                        .disabled(locked)
                    }
                    .accessibilityIdentifier("inspector.materialsOfParts")
                    if !inst.materialOverrides.isEmpty {
                        Text("Custom materials on parts").font(.caption).foregroundStyle(.secondary)
                    }
                }
                InspectorLightSection(instanceId: id, definition: def, lightOn: inst.lightOn)
                InspectorProductSection(objectId: id, productId: inst.productId, productSheet: $productSheet)
                CollisionSection(ids: [id])
            }
            .formStyle(.grouped)
            .sheet(isPresented: $productSheet) { ProductEditorSheet(objectId: id) }
        }
    }

    private func len(_ title: String, _ v: MM, _ u: LengthUnit, _ range: ClosedRange<MM> = -coordinateLimit ... coordinateLimit,
                     _ commit: @escaping (MM) -> Bool) -> some View {
        LengthField(title: title, value: v, unit: u, range: range, onCommit: commit)
    }

    private func move(_ inst: FurnitureInstance, _ change: @escaping (inout FurnitureInstance) -> Void) -> Bool {
        model.perform("Move") { try $0.updateInstance(id) { change(&$0) } }
    }

    private func resize(_ inst: FurnitureInstance, _ current: Size3, _ change: (inout Size3) -> Void) -> Bool {
        var s = current
        change(&s)
        return model.perform("Resize") { try $0.updateInstance(id) { $0.size = s } }
    }
}

// MARK: Product

/// Product summary with clickable links; shared by furniture and groups.
struct InspectorProductSection: View {
    @Environment(AppModel.self) private var model
    let objectId: UUID
    let productId: UUID?
    @Binding var productSheet: Bool

    var body: some View {
        Section("Product") {
            if let pid = productId, let prod = model.project.product(pid) {
                Text(prod.name).font(.headline)
                if !prod.manufacturer.isEmpty { LabeledContent("Brand") { Text(prod.manufacturer) } }
                if !prod.articleNumber.isEmpty { LabeledContent("SKU") { Text(prod.articleNumber).textSelection(.enabled) } }
                if let minor = prod.priceMinor {
                    LabeledContent("Price") { Text(ProductFormat.price(minor, prod.currency)).monospacedDigit() }
                }
                ForEach(prod.links.filter(\.isValid)) { l in
                    if let url = URL(string: l.url) {
                        Link(destination: url) { Label(l.title.isEmpty ? (url.host ?? l.url) : l.title, systemImage: "link") }
                            .help(l.url)
                    }
                }
                Button("Edit product…") { productSheet = true }
                    .controlSize(.small).help("Edit the product details")
                Button("Unlink product", role: .destructive) {
                    model.perform("Unlink Product") { try $0.linkProduct(nil, to: objectId) }
                }
                .controlSize(.small)
                .help("Remove the link; the product stays in the project")
            } else {
                Text("No product information").foregroundStyle(.secondary)
                Button("Add product info…") { productSheet = true }
                    .controlSize(.small).help("Attach brand, price and links to this furniture")
            }
        }
    }
}

enum ProductFormat {
    static func price(_ minor: Int64, _ currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        let amount = Decimal(minor) / 100
        if code.count == 3 { return amount.formatted(.currency(code: code)) }
        return DecimalText.formatMinor(minor) + (code.isEmpty ? "" : " \(code)")
    }
}

/// Sheet to edit (or create and link) the product of a furniture piece or group.
struct ProductEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let objectId: UUID

    @State private var draft = CatalogProduct(name: "")
    @State private var existing = false
    @State private var priceText = ""
    @State private var hasDimensions = false
    @State private var widthText = ""
    @State private var depthText = ""
    @State private var heightText = ""
    @State private var loaded = false

    private var priceMinor: Int64?? {
        let t = priceText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        return DecimalText.parseMinor(t).map { .some($0) }
    }
    /// Dimensions as currently typed (not necessarily confirmed with Return).
    private var typedDimensions: Size3? {
        let u = model.unit
        guard let w = PendingInput.length(widthText, unit: u, range: sizeLimit, emptyIsZero: false),
              let d = PendingInput.length(depthText, unit: u, range: sizeLimit, emptyIsZero: false),
              let h = PendingInput.length(heightText, unit: u, range: sizeLimit, emptyIsZero: false) else { return nil }
        return Size3(w, d, h)
    }
    private var problems: [String] {
        var out: [String] = []
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Name is required.") }
        if priceMinor == nil { out.append("Price must be a number with at most two decimals.") }
        let cur = draft.currency.trimmingCharacters(in: .whitespaces)
        if priceMinor != .some(nil), cur.count != 3 || !cur.allSatisfy(\.isLetter) { out.append("Currency must be a 3-letter code such as EUR.") }
        if hasDimensions, typedDimensions == nil { out.append("Dimensions must be lengths between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm.") }
        for l in draft.links where !(l.url.isEmpty && l.title.isEmpty) && !l.isValid { out.append("Link “\(l.title.isEmpty ? l.url : l.title)” needs a valid http(s) address.") }
        return out
    }

    var body: some View {
        let u = model.unit
        VStack(spacing: 0) {
            Form {
                Section("Product") {
                    TextField("Name", text: $draft.name)
                    TextField("Brand", text: $draft.manufacturer)
                    TextField("Model", text: $draft.model)
                    TextField("SKU / article number", text: $draft.articleNumber)
                    Picker("Status", selection: $draft.status) {
                        ForEach(PurchaseStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section("Price") {
                    HStack {
                        TextField("Price", text: $priceText).multilineTextAlignment(.trailing)
                        TextField("Currency", text: $draft.currency).frame(width: 60)
                    }
                }
                Section("Dimensions") {
                    Toggle("Has dimensions", isOn: $hasDimensions)
                        .onChange(of: hasDimensions) { _, on in
                            if on, widthText.isEmpty { setDimensionTexts(draft.dimensions ?? Size3(1000, 1000, 1000)) }
                        }
                    if hasDimensions {
                        LabeledContent("Width") { PendingLengthField(title: "Product width", text: $widthText, unit: u, range: sizeLimit, emptyIsZero: false) }
                        LabeledContent("Depth") { PendingLengthField(title: "Product depth", text: $depthText, unit: u, range: sizeLimit, emptyIsZero: false) }
                        LabeledContent("Height") { PendingLengthField(title: "Product height", text: $heightText, unit: u, range: sizeLimit, emptyIsZero: false) }
                    }
                }
                Section("Links") {
                    ForEach($draft.links) { $link in
                        HStack {
                            TextField("Title", text: $link.title).frame(maxWidth: 120)
                            TextField("https://…", text: $link.url)
                            Image(systemName: link.url.isEmpty || link.isValid ? "checkmark.circle" : "exclamationmark.circle.fill")
                                .foregroundStyle(link.url.isEmpty ? Color.secondary : (link.isValid ? Color.green : Color.red))
                                .help(link.url.isEmpty || link.isValid ? "" : "Enter a full address, e.g. https://example.com/chair")
                                .accessibilityLabel(link.url.isEmpty ? "No address" : (link.isValid ? "Valid address" : "Invalid address, enter a full address such as https://example.com"))
                            Button { draft.links.removeAll { $0.id == link.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove link")
                                .accessibilityLabel(link.title.isEmpty ? "Remove link" : "Remove link \(link.title)")
                        }
                    }
                    Button { draft.links.append(ProductLink(title: "", url: "")) } label: { Label("Add link", systemImage: "plus") }
                }
                Section("Notes") {
                    TextEditor(text: $draft.notes).frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 6)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Save" : "Create and Link") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let p = model.project
        let pid = p.instance(objectId)?.productId ?? p.group(objectId)?.productId
        if let pid, let prod = p.product(pid) {
            draft = prod; existing = true
        } else {
            var prod = CatalogProduct(name: p.displayName(of: objectId))
            if let inst = p.instance(objectId), let def = p.definition(inst.definitionId) { prod.category = def.category }
            draft = prod
        }
        priceText = draft.priceMinor.map(DecimalText.formatMinor) ?? ""
        hasDimensions = draft.dimensions != nil
        if let d = draft.dimensions { setDimensionTexts(d) }
    }

    private func setDimensionTexts(_ d: Size3) {
        let u = model.unit
        widthText = u.format(d.width, withUnit: false)
        depthText = u.format(d.depth, withUnit: false)
        heightText = u.format(d.height, withUnit: false)
    }

    private func save() {
        guard case .some(let minor) = priceMinor else { return }
        var prod = draft
        prod.name = prod.name.trimmingCharacters(in: .whitespacesAndNewlines)
        prod.currency = prod.currency.trimmingCharacters(in: .whitespaces).uppercased()
        prod.priceMinor = minor
        prod.dimensions = hasDimensions ? typedDimensions : nil
        if hasDimensions, prod.dimensions == nil { return }
        prod.links = prod.links.filter { !($0.url.isEmpty && $0.title.isEmpty) }
        let isNew = !existing
        let ok = model.perform(isNew ? "Add Product" : "Edit Product") { p in
            if isNew {
                let pid = p.addProduct(prod)
                try p.linkProduct(pid, to: objectId)
            } else {
                try p.updateProduct(prod.id) { $0 = prod }
            }
        }
        if ok { dismiss() }
    }
}
