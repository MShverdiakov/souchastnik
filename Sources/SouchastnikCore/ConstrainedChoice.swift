import Foundation

/// Greedy traversal of tokenized alternatives. A completed prefix competes with EOS.
public struct ConstrainedChoice: Sendable {
    public enum Step: Equatable, Sendable { case token(Int32), finished(Int) }
    private let alternatives: [[Int32]]
    private var alive: [Int]
    private var position = 0

    public init(alternatives: [[Int32]]) throws {
        guard !alternatives.isEmpty, alternatives.allSatisfy({ !$0.isEmpty }) else {
            throw PackError.invalid("Не удалось токенизировать варианты ответа")
        }
        self.alternatives = alternatives
        alive = Array(alternatives.indices)
    }

    public mutating func next(eos: Int32, noneBias: Float = 1, logit: (Int32) -> Float) throws -> Step {
        let completed = alive.first { alternatives[$0].count == position }
        var allowed: [Int32] = []
        for i in alive where position < alternatives[i].count {
            let token = alternatives[i][position]
            if !allowed.contains(token) { allowed.append(token) }
        }
        guard let first = allowed.first else {
            guard let completed else { throw PackError.invalid("Пустой набор ответов модели") }
            return .finished(completed)
        }
        let biased: Int32? = position == 0 ? alternatives[0][0] : nil
        func score(_ token: Int32) -> Float { logit(token) + (token == biased ? noneBias : 0) }
        var best = first
        for token in allowed.dropFirst() where score(token) > score(best) { best = token }
        guard score(best).isFinite else { throw PackError.invalid("Модель вернула некорректные логиты") }
        if let completed, logit(eos) > score(best) { return .finished(completed) }
        alive = alive.filter { position < alternatives[$0].count && alternatives[$0][position] == best }
        position += 1
        if alive.count == 1, alternatives[alive[0]].count == position { return .finished(alive[0]) }
        return .token(best)
    }
}
