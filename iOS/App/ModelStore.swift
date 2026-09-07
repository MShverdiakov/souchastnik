import Foundation

actor ModelStore {
    static var modelURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Models/model.gguf")
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    func importModel(from source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw PackError.invalid("Это не GGUF-файл. Переименование другого файла не превращает его в модель.")
        }
        let manager = FileManager.default
        let folder = Self.modelURL.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: Self.modelURL.path) {
            _ = try manager.replaceItemAt(Self.modelURL, withItemAt: temporary)
        } else { try manager.moveItem(at: temporary, to: Self.modelURL) }
        var url = Self.modelURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func remove() throws {
        if Self.installed { try FileManager.default.removeItem(at: Self.modelURL) }
    }
}
