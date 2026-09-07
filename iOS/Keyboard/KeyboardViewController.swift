import UIKit

final class KeyboardViewController: UIInputViewController {
    private var language = KeyboardLanguage.russian
    private var shift = ShiftState.once
    private var symbols = false
    private var moreSymbols = false
    private var pack: DictionaryPack?
    private var triggerIndex: TriggerIndex?
    private var packError: String?
    private var enabled = true
    private var markings = true
    private var rows = UIStackView()
    private let status = UILabel()
    private let toggle = UIButton(type: .system)
    private var deleteTimer: Timer?
    private var lastShift = Date.distantPast
    private var cursorTranslation: CGFloat = 0
    private var height: NSLayoutConstraint?
    private var pendingAnalysis: DispatchWorkItem?
    private var defaults: UserDefaults { hasFullAccess ? SharedStore.preferences : .standard }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 7
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)
        ])
        let strip = UIStackView()
        strip.spacing = 10
        strip.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        strip.isLayoutMarginsRelativeArrangement = true
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.numberOfLines = 2
        status.accessibilityIdentifier = "keyboard.status"
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.setImage(UIImage(systemName: "power"), for: .normal)
        toggle.accessibilityLabel = "Словарные проверки"
        toggle.addTarget(self, action: #selector(toggleAnalysis), for: .touchUpInside)
        toggle.widthAnchor.constraint(equalToConstant: 38).isActive = true
        strip.addArrangedSubview(status)
        strip.addArrangedSubview(toggle)
        strip.heightAnchor.constraint(equalToConstant: 42).isActive = true
        root.addArrangedSubview(strip)
        rows.axis = .vertical
        rows.spacing = 7
        rows.distribution = .fillEqually
        root.addArrangedSubview(rows)
        height = view.heightAnchor.constraint(equalToConstant: 292)
        height?.priority = .defaultHigh
        height?.isActive = true
        refreshSettings()
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSettings()
        updateShift()
        rebuild()
        analyze()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDeleting()
        pendingAnalysis?.cancel()
        pack = nil
        triggerIndex = nil
        status.text = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if deleteTimer != nil { analyze(); return }
        updateShift()
        rebuild()
        analyze()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if deleteTimer != nil { analyze(); return }
        updateShift()
        rebuild()
        analyze()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = (view.window?.windowScene?.interfaceOrientation.isLandscape ?? false)
        height?.constant = landscape ? 240 : 292
    }

    private func refreshSettings() {
        enabled = defaults.object(forKey: "analysisEnabled") as? Bool ?? true
        markings = defaults.object(forKey: "markingsEnabled") as? Bool ?? true
        language = KeyboardLanguage(rawValue: defaults.string(forKey: "keyboardLanguage") ?? "") ?? .russian
        pack = nil
        triggerIndex = nil
        packError = nil
        if hasFullAccess {
            do {
                pack = try SharedStore.loadPack()
                triggerIndex = pack.map(TriggerIndex.init)
            }
            catch { packError = "Ошибка словарей. Импортируйте пакет заново." }
        }
    }

    @objc private func toggleAnalysis() {
        enabled.toggle()
        defaults.set(enabled, forKey: "analysisEnabled")
        analyze()
    }

    private func rebuild() {
        stopDeleting()
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let layout = symbols
            ? (moreSymbols ? ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'\""] : ["1234567890", "-/:;()₽&@", ".,?!'\""])
            : language.rows
        for (index, rowText) in layout.enumerated() {
            let row = UIStackView()
            row.spacing = 4
            row.distribution = .fillEqually
            if index == 2 {
                let label = symbols ? (moreSymbols ? "123" : "#+=") : (shift == .locked ? "⇪" : "⇧")
                let button = key(label, special: true) { [weak self] in self?.shiftPressed() }
                button.accessibilityLabel = symbols ? "Другие символы" : "Регистр"
                if shift.uppercase && !symbols { button.backgroundColor = .systemBackground }
                row.addArrangedSubview(button)
            }
            for character in rowText {
                let value = String(character)
                let text = shift.uppercase && !symbols ? value.uppercased() : value
                let button = key(text) { [weak self] in self?.insert(text) }
                if let alternate = language.alternates[value], !symbols {
                    button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(insertAlternate(_:))))
                    button.accessibilityHint = "Удерживайте для \(alternate)"
                }
                row.addArrangedSubview(button)
            }
            if index == 2 {
                let button = key("⌫", special: true) { [weak self] in self?.deleteBackward() }
                button.accessibilityLabel = "Удалить"
                button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:))))
                row.addArrangedSubview(button)
            }
            rows.addArrangedSubview(row)
        }
        let bottom = UIStackView()
        bottom.spacing = 4
        let numbers = key(symbols ? "АБВ" : "123", special: true) { [weak self] in
            guard let self else { return }
            symbols.toggle(); moreSymbols = false; rebuild()
        }
        numbers.widthAnchor.constraint(equalToConstant: 46).isActive = true
        bottom.addArrangedSubview(numbers)
        if needsInputModeSwitchKey {
            let globe = key("🌐", special: true) {}
            globe.accessibilityLabel = "Следующая клавиатура"
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            globe.widthAnchor.constraint(equalToConstant: 38).isActive = true
            bottom.addArrangedSubview(globe)
        }
        let lang = key(language == .russian ? "EN" : "RU", special: true) { [weak self] in
            guard let self else { return }
            language = language == .russian ? .english : .russian
            defaults.set(language.rawValue, forKey: "keyboardLanguage")
            symbols = false
            rebuild()
        }
        lang.accessibilityLabel = "Сменить язык"
        lang.widthAnchor.constraint(equalToConstant: 38).isActive = true
        bottom.addArrangedSubview(lang)
        let space = key(language.title) { [weak self] in self?.insert(" ") }
        space.accessibilityLabel = "Пробел"
        space.accessibilityHint = "Проведите в сторону для перемещения курсора"
        space.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:))))
        bottom.addArrangedSubview(space)
        let period = key(".") { [weak self] in self?.insert(".") }
        period.widthAnchor.constraint(equalToConstant: 28).isActive = true
        bottom.addArrangedSubview(period)
        let enter = key(returnTitle, special: true) { [weak self] in self?.insert("\n") }
        enter.widthAnchor.constraint(equalToConstant: 66).isActive = true
        enter.accessibilityLabel = returnTitle
        bottom.addArrangedSubview(enter)
        rows.addArrangedSubview(bottom)
    }

    private var returnTitle: String {
        switch textDocumentProxy.returnKeyType {
        case .send: "Отпр."
        case .search: "Поиск"
        case .go: "Перейти"
        case .done: "Готово"
        case .next: "Далее"
        default: "Ввод"
        }
    }

    private func key(_ title: String, special: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: title.count > 2 ? 14 : 22)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = special ? .systemGray3 : .secondarySystemGroupedBackground
        button.layer.cornerRadius = 6
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.15
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.accessibilityLabel = title
        return button
    }

    private func insert(_ text: String) {
        let proxy = textDocumentProxy
        if enabled && markings && (text == " " || text == "\n" || ",.!?;:)".contains(text)),
           proxy.selectedText?.isEmpty != false, let before = proxy.documentContextBeforeInput,
           let marker = pack?.marker(before: before) {
            proxy.insertText(" (\(marker))")
        }
        proxy.insertText(text)
        shift.consumed()
        updateShift()
        rebuild()
        analyze()
    }

    private func updateShift() {
        guard shift != .locked else { return }
        guard textDocumentProxy.autocapitalizationType != UITextAutocapitalizationType.none,
              let before = textDocumentProxy.documentContextBeforeInput else { shift = .off; return }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let capitalize = before.isEmpty || before.last == "\n" ||
            (before.last?.isWhitespace == true && trimmed.last.map { ".!?".contains($0) } == true)
        shift = capitalize ? .once : .off
    }

    private func shiftPressed() {
        if symbols { moreSymbols.toggle() }
        else {
            let now = Date()
            if now.timeIntervalSince(lastShift) < 0.35 { shift = .locked }
            else { shift = shift == .off ? .once : .off }
            lastShift = now
        }
        rebuild()
    }

    private func deleteBackward() {
        textDocumentProxy.deleteBackward()
        analyze()
    }

    @objc private func holdDelete(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            deleteWord()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                self?.deleteWord()
            }
        } else if gesture.state != .changed { stopDeleting(); updateShift(); rebuild() }
    }

    private func deleteWord() {
        let proxy = textDocumentProxy
        if proxy.selectedText?.isEmpty == false { proxy.deleteBackward(); analyze(); return }
        guard let before = proxy.documentContextBeforeInput else { proxy.deleteBackward(); return }
        let suffix = before.suffix(64)
        let spaces = suffix.reversed().prefix(while: \.isWhitespace).count
        let word = suffix.dropLast(spaces).reversed().prefix { !$0.isWhitespace }.count
        for _ in 0..<(spaces + word) { proxy.deleteBackward() }
        analyze()
    }

    private func stopDeleting() { deleteTimer?.invalidate(); deleteTimer = nil }

    @objc private func insertAlternate(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? UIButton,
              let title = button.currentTitle, let alternate = language.alternates[title.lowercased()] else { return }
        insert(shift.uppercase ? alternate.uppercased() : alternate)
    }

    @objc private func moveCursor(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { cursorTranslation = 0 }
        let translation = gesture.translation(in: view).x
        let steps = Int((translation - cursorTranslation) / 12)
        if steps != 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: steps)
            cursorTranslation += CGFloat(steps) * 12
            analyze()
        }
    }

    private func analyze() {
        pendingAnalysis?.cancel()
        toggle.tintColor = enabled ? .systemIndigo : .secondaryLabel
        toggle.accessibilityValue = enabled ? "Включены" : "Выключены"
        status.textColor = .secondaryLabel
        guard enabled else { status.text = "Соучастник · проверки выключены"; return }
        guard hasFullAccess else {
            status.text = "Печать доступна · для словарей включите полный доступ"
            return
        }
        guard let triggerIndex else {
            status.text = packError ?? "Импортируйте словари в приложении «Соучастник»"
            return
        }
        guard textDocumentProxy.documentContextBeforeInput != nil else {
            status.text = "Поле не предоставляет контекст"
            return
        }
        status.text = "Словарная проверка…"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = String((textDocumentProxy.documentContextBeforeInput ?? "").suffix(400))
            let match = triggerIndex.match(text)
            status.text = match.codes.isEmpty
                ? "Совпадений нет · ИИ-разбор в приложении"
                : "Триггеры: \(match.codes.joined(separator: ", ")) · нужен ИИ-разбор в приложении"
            status.textColor = match.codes.isEmpty ? .secondaryLabel : .systemOrange
        }
        pendingAnalysis = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
