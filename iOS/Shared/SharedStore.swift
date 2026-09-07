import Foundation

// Only the dictionaries/settings are shared. Drafts and the model stay in the app.
struct SharedStore {
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "SharedAppGroup") as? String ?? "group.dev.souchastnik.ios" }
    static var groupURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    static var preferences: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }
    static var packURL: URL? { groupURL?.appendingPathComponent("dictionary-pack.json") }

    static func loadPack() throws -> DictionaryPack? {
        guard let url = packURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 4_000_000 else { throw PackError.invalid("Пакет словарей превышает 4 МБ") }
        let pack = try JSONDecoder().decode(DictionaryPack.self, from: Data(contentsOf: url))
        try pack.validate()
        return pack
    }

    static func save(_ pack: DictionaryPack) throws {
        try pack.validate()
        guard let url = packURL else { throw PackError.invalid("App Group недоступна. Проверьте подпись приложения.") }
        let data = try JSONEncoder().encode(pack)
        guard data.count <= 4_000_000 else { throw PackError.invalid("Пакет словарей превышает 4 МБ") }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
