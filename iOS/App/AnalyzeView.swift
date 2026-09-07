import SwiftUI

struct AnalyzeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var result: String?
    @State private var busy = false
    @State private var job: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        Form {
            Section {
                Text("Разберите фразу локально")
                    .font(.title2.bold())
                Text("Вставьте или наберите текст. Словарь выберет кандидатов, а модель проверит контекст. Текст не сохраняется и не отправляется на сервер.")
                    .foregroundStyle(.secondary)
            }
            Section("Ваш текст") {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .accessibilityLabel("Текст для локального ИИ-разбора")
                    .accessibilityIdentifier("analysis.text")
                HStack {
                    Text("\(text.count) / 4000").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Очистить", role: .destructive) { text = "" }.disabled(text.isEmpty)
                }
            }
            Section {
                if busy {
                    HStack {
                        ProgressView()
                        Text("Локальный ИИ разбирает фразу…")
                        Spacer()
                        Button("Отмена") { cancel() }
                    }
                } else {
                    Button("Разобрать фразу", systemImage: "sparkle.magnifyingglass") { analyze() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.pack == nil || state.importing)
                        .accessibilityIdentifier("analysis.run")
                }
                if let result { Text(result).textSelection(.enabled).accessibilityIdentifier("analysis.result") }
                if state.pack == nil {
                    Label("Сначала импортируйте словари и judge.txt на вкладке «Словари».", systemImage: "tray.and.arrow.down")
                        .foregroundStyle(.secondary)
                } else if !state.modelInstalled {
                    Text("Без модели доступен только поиск триггеров. Совпадение со словарём не означает наличие нарушения.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("ИИ работает в открытом приложении. В клавиатуре iOS доступна словарная проверка: тяжёлая модель не запускается внутри расширения.")
                Text("Ответ — оценка модели, а не юридический вывод. Отсутствие совпадений не гарантирует отсутствие рисков.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Разбор фразы")
        .onChange(of: text) { _, newValue in
            cancel()
            result = nil
            if newValue.count > 4000 { text = String(newValue.prefix(4000)) }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onDisappear { cancel(); Task { await state.judge.unload() } }
    }

    private func cancel() {
        requestID = UUID()
        job?.cancel()
        job = nil
        busy = false
    }

    private func analyze() {
        cancel()
        guard let pack = state.pack else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = pack.match(text)
        guard !match.codes.isEmpty else {
            result = "В загруженном словаре триггеров совпадений нет. ИИ не запускался."
            return
        }
        guard state.modelInstalled else {
            result = "Кандидаты по словарю: \(match.codes.joined(separator: ", ")). Для проверки контекста импортируйте GGUF-модель."
            return
        }
        let id = UUID()
        requestID = id
        busy = true
        result = nil
        job = Task {
            do {
                let decision = try await state.judge.decide(modelURL: ModelStore.modelURL, system: pack.systemPrompt(for: match), text: text, alternatives: ["none"] + match.codes)
                try Task.checkCancellation()
                guard requestID == id else { return }
                if decision.code == "none" {
                    result = "Модель не выбрала ни одну из статей-кандидатов."
                } else if let article = pack.article(code: decision.code) {
                    result = "Оценка модели: \(article.strip)"
                } else { result = "Ответ модели отсутствует в справочнике." }
                if decision.truncated { result = (result ?? "") + "\n\nТекст не поместился в контекст: проанализирована только его последняя часть." }
            } catch is CancellationError {
                // A stale request must never replace the result of edited text.
            } catch {
                if requestID == id { result = error.localizedDescription }
            }
            if requestID == id { busy = false; job = nil }
        }
    }
}
