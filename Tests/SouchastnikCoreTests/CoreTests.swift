import XCTest
@testable import SouchastnikCore

final class CoreTests: XCTestCase {
    private func fixture(_ changes: (URL) throws -> Void = { _ in }) throws -> DictionaryPack {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        // Synthetic codes and names, never a shipped legal dictionary.
        let files = [
            "articles.json": #"{"articles":[{"code":"TEST-A","act":"Тест","title":"Пример А","penalty":"Тестовая санкция","severity":1},{"code":"TEST-B","act":"Тест","title":"Пример Б","penalty":"Не реальная статья","severity":2}]}"#,
            "triggers.json": #"{"groups":[{"words":["ёжик"],"codes":["TEST-A"],"clean":"Добрый ёжик"},{"words":["ежик","два слова"],"codes":["TEST-A","TEST-B"]}]}"#,
            "judge.txt": "Выбери код или none.\n@@TABLE@@",
            "examples.json": #"{"shots":{"TEST-A":["Пример срабатывания"]},"clean":["НЕ ВКЛЮЧАТЬ ОБЩИЙ ПРИМЕР"]}"#,
            "agents.json": #"{"templates":{"agent":"ТЕСТ {NAME}","service":"СЕРВИС {NAME}"},"agents":[{"name":"Тестовое Имя","forms":["Тестов"],"strict":true},{"name":"Два Слова","forms":["Два Слова"]}],"services":[{"name":"ТестСервис","kind":"service","exact":["тс","X"],"strict":true}]}"#
        ]
        for (name, content) in files { try Data(content.utf8).write(to: url.appendingPathComponent(name)) }
        try changes(url)
        return try DictionaryPack(directory: url)
    }

    func testTriggerNormalizationOrderAndDeduplication() throws {
        let match = try fixture().match("ЁЖИК и два\n\tслова")
        XCTAssertEqual(match.codes, ["TEST-A", "TEST-B"])
        XCTAssertEqual(match.clean, ["Добрый ёжик"])
    }

    func testNoTriggerDoesNotProduceCandidates() throws {
        XCTAssertEqual(try fixture().match("Молоко в холодильнике").codes, [])
    }

    func testPromptIncludesOnlyCandidatesAndGroupCounterexamples() throws {
        let pack = try fixture()
        let match = TriggerMatch(codes: ["TEST-A"], clean: ["Добрый ёжик"])
        let prompt = pack.systemPrompt(for: match)
        XCTAssertTrue(prompt.contains("TEST-A Тест — Пример А"))
        XCTAssertTrue(prompt.contains("«Пример срабатывания» → TEST-A"))
        XCTAssertTrue(prompt.contains("«Добрый ёжик» → none"))
        XCTAssertFalse(prompt.contains("TEST-B"))
        XCTAssertFalse(prompt.contains("НЕ ВКЛЮЧАТЬ"))
        XCTAssertFalse(prompt.contains("Тестовая санкция"))
    }

    func testMarkersRespectCaseExactFormsBoundariesAndDuplicates() throws {
        let pack = try fixture()
        XCTAssertEqual(pack.marker(before: "Привет Тестовым"), "ТЕСТ ТЕСТОВОЕ ИМЯ")
        XCTAssertNil(pack.marker(before: "привет тестовым"))
        XCTAssertEqual(pack.marker(before: "X"), "СЕРВИС ТЕСТСЕРВИС")
        XCTAssertNil(pack.marker(before: "x"))
        XCTAssertNil(pack.marker(before: "тсервис"))
        XCTAssertEqual(pack.marker(before: "это два слова"), "ТЕСТ ДВА СЛОВА")
        XCTAssertNil(pack.marker(before: "недва слова"))
        XCTAssertNil(pack.marker(before: "Тестовый (ТЕСТ ТЕСТОВОЕ ИМЯ)"))
        XCTAssertNil(pack.marker(before: ""))
    }

    func testUnknownCodeRejected() throws {
        XCTAssertThrowsError(try fixture { url in
            try Data(#"{"groups":[{"words":["x"],"codes":["UNKNOWN"]}]}"#.utf8)
                .write(to: url.appendingPathComponent("triggers.json"))
        })
    }

    func testEmptyTriggerRejected() throws {
        XCTAssertThrowsError(try fixture { url in
            try Data(#"{"groups":[{"words":["  "],"codes":["TEST-A"]}]}"#.utf8)
                .write(to: url.appendingPathComponent("triggers.json"))
        })
    }

    func testMissingOptionalFilesSupported() throws {
        let pack = try fixture { url in
            try FileManager.default.removeItem(at: url.appendingPathComponent("agents.json"))
            try FileManager.default.removeItem(at: url.appendingPathComponent("examples.json"))
        }
        XCTAssertNil(pack.markers)
        XCTAssertNil(pack.examples)
    }

    func testMissingRequiredFileRejected() throws {
        XCTAssertThrowsError(try fixture { url in
            try FileManager.default.removeItem(at: url.appendingPathComponent("judge.txt"))
        })
    }

    func testPackRoundTripKeepsPenaltyAndSeverity() throws {
        let original = try fixture()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DictionaryPack.self, from: data)
        try decoded.validate()
        XCTAssertEqual(decoded.articles.articles, original.articles.articles)
    }

    func testConstrainedChoiceNoneBias() throws {
        var chooser = try ConstrainedChoice(alternatives: [[1], [2]])
        XCTAssertEqual(try chooser.next(eos: 0) { $0 == 1 ? 1.0 : 1.5 }, .finished(0))
    }

    func testConstrainedChoiceCanChooseShorterPrefix() throws {
        var chooser = try ConstrainedChoice(alternatives: [[9], [1, 2], [1, 2, 3]])
        XCTAssertEqual(try chooser.next(eos: 0) { $0 == 1 ? 10 : 0 }, .token(1))
        XCTAssertEqual(try chooser.next(eos: 0) { $0 == 2 ? 10 : 0 }, .token(2))
        XCTAssertEqual(try chooser.next(eos: 0) { $0 == 0 ? 10 : 0 }, .finished(1))
    }

    func testConstrainedChoiceCanChooseLongerPrefix() throws {
        var chooser = try ConstrainedChoice(alternatives: [[9], [1], [1, 3]])
        XCTAssertEqual(try chooser.next(eos: 0) { $0 == 1 ? 10 : 0 }, .token(1))
        XCTAssertEqual(try chooser.next(eos: 0) { $0 == 3 ? 10 : 0 }, .finished(2))
    }

    func testInvalidChoicesRejected() throws {
        XCTAssertThrowsError(try ConstrainedChoice(alternatives: []))
        XCTAssertThrowsError(try ConstrainedChoice(alternatives: [[]]))
    }

    func testRussianKeyboardContainsTheWholeAlphabet() {
        let layout = KeyboardLanguage.russian
        let actual = Set((layout.rows.joined() + layout.alternates.values.joined()).lowercased())
        XCTAssertEqual(actual, Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"))
    }

    func testShiftOnceAndCapsLock() {
        var shift = ShiftState.once
        shift.consumed()
        XCTAssertFalse(shift.uppercase)
        shift = .locked
        shift.consumed()
        XCTAssertTrue(shift.uppercase)
    }
}
