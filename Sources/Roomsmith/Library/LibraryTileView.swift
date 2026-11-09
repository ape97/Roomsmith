import SwiftUI
import RoomsmithCore

/// What a tile can do; the grid fills it in for each entry.
struct LibraryTileActions {
    var edit: (() -> Void)?
    var preview: (() -> Void)?
    var place: () -> Void
}

/// Small capsule that marks something an AI agent added, until the user looks at it.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityLabel("New")
    }
}

/// One library tile: large picture, name, size. Draggable into plan and 3D; double-click or Return opens the preview;
/// a pencil appears on hover or keyboard focus to edit the entry. VoiceOver gets Edit, Preview and Place as actions.
struct LibraryTileView: View {
    let title: String
    let subtitle: String
    let image: NSImage?
    var dragPayload: String?
    let actions: LibraryTileActions
    var placeLabel: String = "Place"
    /// An AI agent added this entry and the user has not looked at it yet.
    var isNew = false
    /// Called when the user clicks, previews, edits, drags or places the tile.
    var onSeen: (() -> Void)?
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                LibraryPicture(image: image, side: nil)
                    .overlay(alignment: .bottomTrailing) { if isNew { NewBadge().padding(3) } }
                if hover || focused, let edit = actions.edit {
                    Button(action: edit) { Image(systemName: "pencil.circle.fill").font(.title3) }
                        .buttonStyle(.borderless)
                        .padding(3)
                        .help("Edit")
                        .accessibilityLabel("Edit")
                }
            }
            Text(title).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(Color(nsColor: .labelColor))
            Text(subtitle).font(.caption2).lineLimit(1).foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .onKeyPress(.return) {
            guard let preview = actions.preview else { return .ignored }
            onSeen?()
            preview()
            return .handled
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onSeen?(); actions.preview?() }
        .simultaneousGesture(TapGesture().onEnded { onSeen?() })
        .onDrag { onSeen?(); return dragPayload.map { NSItemProvider(object: $0 as NSString) } ?? NSItemProvider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isNew ? "\(title), \(subtitle), New" : "\(title), \(subtitle)")
        .accessibilityAction(named: placeLabel) { onSeen?(); actions.place() }
        .accessibilityAction(named: "Preview") { onSeen?(); actions.preview?() }
        .accessibilityAction(named: "Edit") { onSeen?(); actions.edit?() }
    }
}

/// A flowing grid of tiles.
struct LibraryGridView<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8, alignment: .top)], alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 8)
    }
}

/// A section header with a disclosure triangle whose open state is remembered under `key`.
struct CollapsibleSection<Content: View, Menu: View>: View {
    let title: String
    let count: Int?
    let forceOpen: Bool
    @AppStorage private var stored: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let menu: Menu

    init(_ title: String, count: Int? = nil, key: String, defaultOpen: Bool = true, forceOpen: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder menu: () -> Menu = { EmptyView() }) {
        self.title = title; self.count = count; self.forceOpen = forceOpen
        self._stored = AppStorage(wrappedValue: defaultOpen, key, store: AppDefaults.store)
        self.content = content(); self.menu = menu()
    }

    var body: some View {
        let open = forceOpen || stored
        VStack(alignment: .leading, spacing: 6) {
            Button { stored.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).frame(width: 12)
                    Text(title).font(.subheadline.weight(.semibold))
                    if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 8)
            .contextMenu { menu }
            .accessibilityLabel("\(title), \(open ? "expanded" : "collapsed")")
            .accessibilityAddTraits(.isHeader)
            if open { content }
        }
    }
}
