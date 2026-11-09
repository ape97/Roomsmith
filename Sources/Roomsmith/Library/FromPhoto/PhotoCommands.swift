import SwiftUI

/// File > Furniture from Photos…
struct PhotoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Furniture from Photos…") { model.sheet = .photoToFurniture(improve: nil) }
        }
    }
}
