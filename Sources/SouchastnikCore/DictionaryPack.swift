import Foundation

public struct Article: Codable, Identifiable, Equatable, Sendable {
    public let code: String
    public let act: String
    public let title: String
    public let penalty: String
    public let severity: Int
    public var id: String { code }
    public var strip: String { "ст. \(code) \(act) · \(title) · \(penalty)" }
}

public struct ArticleFile: Codable, Sendable {
    public let articles: [Article]
}

public struct TriggerGroup: Codable, Sendable {
    public let words: [String]
    public let codes: [String]
    public let clean: String?
}

public struct TriggerFile: Codable, Sendable {
    public let groups: [TriggerGroup]
}

public struct ExampleFile: Codable, Sendable {
    public let shots: [String: [String]]?
    public let clean: [String]?
}

public struct MarkerEntry: Codable, Sendable {
    public let name: String
    public let kind: String?
    public let forms: [String]?
    public let exact: [String]?
    public let strict: Bool?
}

public struct MarkerFile: Codable, Sendable {
    public let template: String?
    public let templates: [String: String]?
    public let agents: [MarkerEntry]?
    public let services: [MarkerEntry]?
    public var entries: [MarkerEntry] { (agents ?? []) + (services ?? []) }
    public func template(for entry: MarkerEntry) -> String? {
        let kind = entry.kind ?? "agent"
        return templates?[kind] ?? (kind == "agent" ? template : nil)
    }
}

public struct DictionaryPack: Codable, Sendable {
    public let articles: ArticleFile
    public let triggers: TriggerFile
    public let markers: MarkerFile?
    public let examples: ExampleFile?
    public let judgeTemplate: String

    public init(directory: URL) throws {
        func read(_ name: String) throws -> Data {
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_000_000 else {
                throw PackError.invalid("\(name): ожидается файл до 2 МБ")
            }
            return try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        articles = try decoder.decode(ArticleFile.self, from: read("articles.json"))
        triggers = try decoder.decode(TriggerFile.self, from: read("triggers.json"))
        judgeTemplate = String(decoding: try read("judge.txt"), as: UTF8.self)
        markers = FileManager.default.fileExists(atPath: directory.appendingPathComponent("agents.json").path)
            ? try decoder.decode(MarkerFile.self, from: read("agents.json")) : nil
        examples = FileManager.default.fileExists(atPath: directory.appendingPathComponent("examples.json").path)
            ? try decoder.decode(ExampleFile.self, from: read("examples.json")) : nil
        try validate()
    }

    public func validate() throws {
        let codes = articles.articles.map(\.code)
        guard !codes.isEmpty, codes.count <= 1000, Set(codes).count == codes.count,
              !codes.contains("none"), codes.allSatisfy({ !$0.isEmpty && $0.count < 40 }) else {
            throw PackError.invalid("Справочник пуст или содержит повторяющиеся/недопустимые коды")
        }
        guard articles.articles.allSatisfy({ !$0.act.isEmpty && !$0.title.isEmpty && !$0.penalty.isEmpty }) else {
            throw PackError.invalid("У статьи отсутствует название, кодекс или санкция")
        }
        guard !triggers.groups.isEmpty, triggers.groups.count <= 5000 else {
            throw PackError.invalid("Отсутствуют группы триггеров или их слишком много")
        }
        for group in triggers.groups {
            guard !group.words.isEmpty, group.words.allSatisfy({ !normalize($0).trimmingCharacters(in: .whitespaces).isEmpty }),
                  !group.codes.isEmpty, group.codes.allSatisfy({ codes.contains($0) }) else {
                throw PackError.invalid("Триггеры содержат пустое слово или неизвестную статью")
            }
        }
        guard judgeTemplate.contains("@@TABLE@@") else {
            throw PackError.invalid("judge.txt должен содержать @@TABLE@@")
        }
        if let markers {
            for entry in markers.entries {
                guard !entry.name.isEmpty, let template = markers.template(for: entry), !template.isEmpty,
                      !((entry.forms ?? []) + (entry.exact ?? [])).isEmpty,
                      ((entry.forms ?? []) + (entry.exact ?? [])).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw PackError.invalid("Некорректная запись маркировки: \(entry.name)")
                }
            }
        }
    }

    public func article(code: String) -> Article? { articles.articles.first { $0.code == code } }
}

public enum PackError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public func normalize(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "ё", with: "е")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}
