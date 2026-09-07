import SwiftUI

@MainActor @Observable
final class AppState {
    var pack: DictionaryPack?
    var message: String?
    var modelInstalled = ModelStore.installed
    var importing = false
    let judge = LocalJudge()
    private let modelStore = ModelStore()

    init() { reload() }
    func reload() {
        do { pack = try SharedStore.loadPack() }
        catch { message = error.localizedDescription }
        modelInstalled = ModelStore.installed
    }

    func importDictionary(_ url: URL) async {
        importing = true
        defer { importing = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try DictionaryPack(directory: url)
            }.value
            try SharedStore.save(imported)
            pack = imported
            message = "Словари импортированы. Переоткройте клавиатуру, чтобы применить изменения."
        } catch { message = error.localizedDescription }
    }

    func importModel(_ url: URL) async {
        importing = true
        defer { importing = false }
        await judge.unload()
        do {
            try await modelStore.importModel(from: url)
            modelInstalled = true
            message = "GGUF импортирован. Совместимость модели будет проверена при первом ИИ-разборе."
        } catch { message = error.localizedDescription }
    }

    func removeModel() async {
        importing = true
        defer { importing = false }
        await judge.unload()
        do { try await modelStore.remove(); modelInstalled = false }
        catch { message = error.localizedDescription }
    }
}
