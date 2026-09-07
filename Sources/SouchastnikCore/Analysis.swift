import Foundation

public struct TriggerMatch: Equatable, Sendable {
    public let codes: [String]
    public let clean: [String]
}

public struct TriggerIndex: Sendable {
    private struct Group: Sendable {
        let words: [String]
        let codes: [String]
        let clean: String?
    }
    private let groups: [Group]
    public init(pack: DictionaryPack) {
        groups = pack.triggers.groups.map { Group(words: $0.words.map(normalize), codes: $0.codes, clean: $0.clean) }
    }
    public func match(_ input: String) -> TriggerMatch {
        let text = normalize(input)
        var codes: [String] = []
        var clean: [String] = []
        for group in groups where group.words.contains(where: { text.contains($0) }) {
            for code in group.codes where !codes.contains(code) { codes.append(code) }
            if let phrase = group.clean, !phrase.isEmpty { clean.append(phrase) }
        }
        return TriggerMatch(codes: codes, clean: clean)
    }
}

public extension DictionaryPack {
    func match(_ text: String) -> TriggerMatch { TriggerIndex(pack: self).match(text) }

    func systemPrompt(for match: TriggerMatch) -> String {
        let table = match.codes.compactMap { article(code: $0) }
            .map { "\($0.code) \($0.act) — \($0.title)" }.joined(separator: "\n")
        var lines: [String] = []
        for code in match.codes {
            for phrase in examples?.shots?[code] ?? [] { lines.append("«\(phrase)» → \(code)") }
        }
        lines += match.clean.map { "«\($0)» → none" }
        return judgeTemplate.replacingOccurrences(of: "@@TABLE@@", with: table)
            + (lines.isEmpty ? "" : "\nПримеры:\n" + lines.joined(separator: "\n") + "\n")
    }

    func marker(before text: String) -> String? {
        guard let markers, let last = text.last, isWordCharacter(last) else { return nil }
        let word = String(text.reversed().prefix(while: isWordCharacter).reversed())
        let tail = String(text.suffix(128))
        // Prefer a complete multiword name to a shorter suffix.
        for entry in markers.entries {
            let strict = entry.strict ?? false
            let candidate = strict ? tail : tail.lowercased()
            for form in entry.forms ?? [] where form.contains(" ") {
                let form = strict ? form : form.lowercased()
                guard candidate.hasSuffix(form) else { continue }
                let prefix = candidate.dropLast(form.count)
                if prefix.isEmpty || !isWordCharacter(prefix.last!) {
                    return markers.template(for: entry)?.replacingOccurrences(of: "{NAME}", with: entry.name.uppercased())
                }
            }
        }
        for entry in markers.entries {
            let strict = entry.strict ?? false
            let candidate = strict ? word : word.lowercased()
            let exact = (entry.exact ?? []).contains { candidate == (strict ? $0 : $0.lowercased()) }
            let prefix = word.count >= 3 && (entry.forms ?? []).contains {
                !$0.contains(" ") && candidate.hasPrefix(strict ? $0 : $0.lowercased())
            }
            if exact || prefix {
                return markers.template(for: entry)?.replacingOccurrences(of: "{NAME}", with: entry.name.uppercased())
            }
        }
        return nil
    }
}

public func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character == "-" || character == "'" || character == "’"
}

public enum KeyboardLanguage: String, CaseIterable, Sendable {
    case russian, english
    public var rows: [String] {
        switch self {
        case .russian: ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"]
        case .english: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        }
    }
    public var title: String { self == .russian ? "Русский" : "English" }
    public var alternates: [String: String] { self == .russian ? ["е": "ё", "ь": "ъ"] : [:] }
}

public enum ShiftState: Sendable {
    case off, once, locked
    public var uppercase: Bool { self != .off }
    public mutating func consumed() { if self == .once { self = .off } }
}
