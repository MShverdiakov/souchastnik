import Foundation
import llama

/// Actor isolation keeps all model lifetime and inference calls on one serial executor.
/// The keyboard target deliberately does not link llama.cpp.
actor LocalJudge {
    struct Decision: Sendable {
        let code: String
        let truncated: Bool
    }
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?
    private let contextSize = 1024

    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedPath = nil
    }

    private func load(url: URL) throws {
        if loadedPath == url.path, context != nil { return }
        unload()
        // Do not log the user's text or token stream.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        var params = llama_model_default_params()
        params.load_mode = LLAMA_LOAD_MODE_MMAP
        #if targetEnvironment(simulator)
        params.n_gpu_layers = 0
        #else
        params.n_gpu_layers = 99
        #endif
        guard let loaded = llama_model_load_from_file(url.path, params) else {
            throw PackError.invalid("Модель не загрузилась. Нужна совместимая GGUF Qwen3.5-0.8B.")
        }
        model = loaded
        var architecture = [CChar](repeating: 0, count: 64)
        let count = llama_model_meta_val_str(loaded, "general.architecture", &architecture, architecture.count)
        guard count > 0, String(cString: architecture) == "qwen35" else {
            unload()
            throw PackError.invalid("Ожидалась архитектура qwen35. Для другой модели нужен другой чат-шаблон.")
        }
        var settings = llama_context_default_params()
        settings.n_ctx = UInt32(contextSize)
        settings.n_batch = 128
        settings.n_ubatch = 128
        settings.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        settings.n_threads_batch = settings.n_threads
        guard let created = llama_init_from_model(loaded, settings) else {
            unload()
            throw PackError.invalid("Не удалось создать контекст ИИ. Возможно, недостаточно памяти.")
        }
        context = created
        loadedPath = url.path
    }

    private func tokens(_ text: String, vocab: OpaquePointer, special: Bool) throws -> [llama_token] {
        let size = Int32(text.utf8.count)
        let required = -llama_tokenize(vocab, text, size, nil, 0, false, special)
        guard required >= 0 else { throw PackError.invalid("Ошибка токенизатора") }
        if required == 0 { return [] }
        var result = [llama_token](repeating: 0, count: Int(required))
        let count = llama_tokenize(vocab, text, size, &result, required, false, special)
        guard count >= 0 else { throw PackError.invalid("Ошибка токенизатора") }
        return Array(result.prefix(Int(count)))
    }

    func decide(modelURL: URL, system: String, text: String, alternatives: [String]) throws -> Decision {
        try Task.checkCancellation()
        try load(url: modelURL)
        try Task.checkCancellation()
        guard let model, let context, let vocab = llama_model_get_vocab(model) else {
            throw PackError.invalid("Модель недоступна")
        }
        llama_memory_clear(llama_get_memory(context), true)
        defer { llama_memory_clear(llama_get_memory(context), true) }
        let head = try tokens("<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n", vocab: vocab, special: true)
        let tail = try tokens("<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", vocab: vocab, special: true)
        let body = try tokens(text, vocab: vocab, special: false)
        let options = try alternatives.map { try tokens($0, vocab: vocab, special: false) }
        let reserve = max(16, (options.map(\.count).max() ?? 0) + 1)
        let capacity = contextSize - head.count - tail.count - reserve
        guard capacity > 0 else { throw PackError.invalid("Промпт и примеры слишком длинные для контекста 1024 токена") }
        let prompt = head + body.suffix(capacity) + tail
        for start in stride(from: 0, to: prompt.count, by: 128) {
            try Task.checkCancellation()
            var chunk = Array(prompt[start..<min(start + 128, prompt.count)])
            let result = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard result == 0 else { throw PackError.invalid("Ошибка вычисления ИИ (\(result))") }
        }
        var chooser = try ConstrainedChoice(alternatives: options)
        for _ in 0...reserve {
            try Task.checkCancellation()
            guard let logits = llama_get_logits_ith(context, -1) else { throw PackError.invalid("Нет ответа модели") }
            let next = try chooser.next(eos: llama_vocab_eos(vocab)) { logits[Int($0)] }
            switch next {
            case .finished(let index): return Decision(code: alternatives[index], truncated: body.count > capacity)
            case .token(var token):
                let result = llama_decode(context, llama_batch_get_one(&token, 1))
                guard result == 0 else { throw PackError.invalid("Ошибка декодирования ИИ (\(result))") }
            }
        }
        throw PackError.invalid("Модель не завершила выбор ответа")
    }
}
