import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - File actions (Control wheel)

    /// Offered for every selection — files, folders and mixed selections alike.
    static func filePage(_ items: [FileItem]) -> WheelPage {
        let plural = items.count > 1
        let singleFolder = items.count == 1 && items[0].kind == .folder
        var actions: [KlickAction] = [
            instant("file.airdrop", "AIRDROP", symbol: "dot.radiowaves.up.forward", confirmation: nil) { FileOps.airDrop($0) },
            instant("file.float", "FLOAT", symbol: "pin", confirmation: nil) { FloatShelf.shared.add($0) },
            instant("file.copy", "COPY", symbol: "doc.on.doc", confirmation: plural ? "Files copied" : "File copied") { FileOps.copyToClipboard($0) },
            instant("file.move", "MOVE", symbol: "folder", confirmation: nil) { FileOps.move($0) },
            instant("file.copypath", "COPY PATH", symbol: "link", confirmation: plural ? "Paths copied" : "Path copied") { FileOps.copyPaths($0) },
            instant("file.terminal", "TERMINAL", symbol: "terminal", confirmation: nil) { FileOps.openTerminal(at: $0[0]) },
            batch("file.zip", "ZIP", symbol: "doc.zipper", verb: "Compressing") { items, p in
                try FileOps.zip(items, progress: p)
            },
        ]
        if singleFolder {
            actions.append(perFile("file.dmg", "DMG", symbol: "externaldrive", verb: "Creating disk image") { item, p in
                [try FileOps.diskImage(item, progress: p)]
            })
        } else {
            actions.append(perFile("file.duplicate", "DUPLICATE", symbol: "plus.square.on.square", verb: "Duplicating") { item, p in
                [try FileOps.duplicate(item, progress: p)]
            })
        }
        return WheelPage(id: PageID.file, title: "File", actions: actions)
    }
}
