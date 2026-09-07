import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @Environment(AppState.self) private var state
    @State private var importFolder = false
    @State private var importModel = false
    @State private var confirmRemoval = false
    @State private var query = ""

    private var articles: [Article] {
        let all = state.pack?.articles.articles ?? []
        guard !query.isEmpty else { return all }
        return all.filter { "\($0.code) \($0.act) \($0.title)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section("Пакет словарей") {
                if let pack = state.pack {
                    LabeledContent("Статей", value: "\(pack.articles.articles.count)")
                    LabeledContent("Групп триггеров", value: "\(pack.triggers.groups.count)")
                    LabeledContent("Записей маркировки", value: "\(pack.markers?.entries.count ?? 0)")
                } else {
                    ContentUnavailableView("Словари не установлены", systemImage: "books.vertical", description: Text("Оригинальные данные отсутствуют в публичном репозитории. Приложение не подставляет выдуманный справочник."))
                }
                Button("Импортировать папку словарей", systemImage: "folder.badge.plus") { importFolder = true }
                Text("Обязательно: articles.json, triggers.json, judge.txt. Необязательно: agents.json и examples.json. Форматы совместимы с исходным проектом.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Локальная модель") {
                Label(state.modelInstalled ? "GGUF-файл установлен" : "Модель не установлена", systemImage: "cpu")
                Button("Импортировать GGUF-файл", systemImage: "square.and.arrow.down") { importModel = true }
                if state.modelInstalled {
                    Button("Удалить модель", role: .destructive) { confirmRemoval = true }
                }
                Text("Qwen3.5-0.8B в формате GGUF, исходная квантизация Q4_0. Можно импортировать и оригинальный файл libmodel-qwen35-08b-q40.so: внутри него GGUF. Веса не входят в приложение.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if state.importing {
                Section { ProgressView("Импорт данных…") }
            }
            if state.pack != nil {
                Section("Статьи из загруженного справочника") {
                    ForEach(articles) { article in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ст. \(article.code) \(article.act)").font(.headline)
                            Text(article.title)
                            Text(article.penalty).font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .disabled(state.importing)
        .navigationTitle("Словари и ИИ")
        .searchable(text: $query, prompt: "Код или название статьи")
        .fileImporter(isPresented: $importFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await state.importDictionary(url) }
            case .failure(let error): state.message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importModel, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url): Task { await state.importModel(url) }
            case .failure(let error): state.message = error.localizedDescription
            }
        }
        .confirmationDialog("Удалить локальную модель? Для следующего разбора потребуется повторный импорт.", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Удалить модель", role: .destructive) { Task { await state.removeModel() } }
        }
    }
}
