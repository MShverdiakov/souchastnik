import SwiftUI

@main
struct SouchastnikApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { SetupView() }
                    .tabItem { Label("Клавиатура", systemImage: "keyboard") }
                NavigationStack { AnalyzeView() }
                    .tabItem { Label("Разбор", systemImage: "text.magnifyingglass") }
                NavigationStack { DictionaryView() }
                    .tabItem { Label("Словари", systemImage: "books.vertical") }
            }
            .tint(.indigo)
            .environment(state)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { state.reload() }
                else { Task { await state.judge.unload() } }
            }
            .alert("Соучастник", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
                Button("Понятно", role: .cancel) { state.message = nil }
            } message: { Text(state.message ?? "") }
        }
    }
}
