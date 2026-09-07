import SwiftUI

struct SetupView: View {
    @Environment(AppState.self) private var state
    @AppStorage("analysisEnabled", store: SharedStore.preferences) private var enabled = true
    @AppStorage("markingsEnabled", store: SharedStore.preferences) private var markings = true
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 42)).foregroundStyle(.indigo)
                    Text("Пишите. Соучастник рядом.")
                        .font(.title2.bold())
                    Text("Русская и английская клавиатура со словарными пометками. Локальный ИИ помогает разобрать фразу в приложении.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section("Подключение") {
                Label("Откройте Настройки → Основные → Клавиатура → Клавиатуры.", systemImage: "1.circle")
                Label("Выберите «Новые клавиатуры» → «Соучастник».", systemImage: "2.circle")
                Label("Удерживайте 🌐 при вводе и выберите «Соучастник».", systemImage: "3.circle")
                Button("Открыть настройки приложения", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section {
                Toggle("Словарные проверки", isOn: $enabled)
                Toggle("Добавлять пометки из словаря", isOn: $markings).disabled(!enabled)
            } header: { Text("Поведение клавиатуры") } footer: {
                Text("Для общих словарей и этих настроек включите «Разрешить полный доступ» в настройках клавиатуры. Приложение не отправляет текст в сеть. Без полного доступа печать работает, а переключатель проверок хранится в самой клавиатуре.")
            }
            Section("Попробуйте") {
                TextField("Нажмите сюда и выберите клавиатуру 🌐", text: $draft, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("keyboard.tryField")
                Text("Удерживайте «е» для «ё», «ь» для «ъ». Двойное нажатие Shift включает Caps Lock. Проведите по пробелу, чтобы переместить курсор.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Данные на устройстве") {
                Label(state.pack == nil ? "Словари не установлены" : "Словари установлены", systemImage: state.pack == nil ? "tray" : "checkmark.circle")
                Label(state.modelInstalled ? "Модель импортирована" : "Модель не установлена", systemImage: "cpu")
                Text("Оригинальные словари, промпт и веса модели не опубликованы в исходном репозитории. Импортируйте их на вкладке «Словари», когда они будут доступны.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("О проекте") {
                Text("Соучастник — сатирический проект автора @neuromikhail. Нативная версия для iOS сохраняет идею, форматы данных и принцип локального ИИ-разбора.")
                Text("Это не юридическая консультация. Модель может ошибаться. Статусы и санкции отражают загруженный справочник и могут устареть.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Исходный код · GPL-3.0", destination: URL(string: "https://github.com/e11isei/souchastnik-ios")!)
            }
        }
        .navigationTitle("Соучастник")
    }
}
