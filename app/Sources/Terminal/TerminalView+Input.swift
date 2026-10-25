import UIKit

/// Typing: the software keyboard through UIKeyInput, hardware keys through
/// UIPress, and the Smart Keys bar. All of it ends in `send`.
extension TerminalView {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        deletePacer.reset()
        switch text {
        case "\n", "\r": send(TERM_KEY_ENTER)
        case "\t": send(TERM_KEY_TAB)
        default:
            if text.count == 1 || smartKeys.activeMods != 0 {
                send(TERM_KEY_NONE, text: text)
            } else {
                // Several characters at once (dictation, swipe typing): send as typed.
                session.write(Data(text.utf8))
                didSendInput()
            }
        }
    }

    func deleteBackward() {
        deletePacer.call { [weak self] in
            self?.send(TERM_KEY_BACKSPACE)
        }
    }

    /// Sends a key with the Smart Keys modifiers folded in, then releases
    /// any one-shot modifier.
    func send(_ key: TermKey, text: String? = nil, mods: UInt32 = 0) {
        let all = mods | smartKeys.activeMods
        session.key(key, mods: all, text: text)
        smartKeys.consumeModifiers()
        didSendInput()
    }

    func didSendInput() {
        clearSelection()
        stopCoasting()
        restartBlink()
    }

    // ------------------------------------------------------------ hardware keys

    private static let specialKeys: [UIKeyboardHIDUsage: TermKey] = [
        .keyboardReturnOrEnter: TERM_KEY_ENTER, .keypadEnter: TERM_KEY_ENTER,
        .keyboardTab: TERM_KEY_TAB, .keyboardDeleteOrBackspace: TERM_KEY_BACKSPACE,
        .keyboardEscape: TERM_KEY_ESCAPE,
        .keyboardUpArrow: TERM_KEY_UP, .keyboardDownArrow: TERM_KEY_DOWN,
        .keyboardLeftArrow: TERM_KEY_LEFT, .keyboardRightArrow: TERM_KEY_RIGHT,
        .keyboardHome: TERM_KEY_HOME, .keyboardEnd: TERM_KEY_END,
        .keyboardPageUp: TERM_KEY_PAGE_UP, .keyboardPageDown: TERM_KEY_PAGE_DOWN,
        .keyboardInsert: TERM_KEY_INSERT, .keyboardDeleteForward: TERM_KEY_DELETE,
        .keyboardF1: TERM_KEY_F1, .keyboardF2: TERM_KEY_F2, .keyboardF3: TERM_KEY_F3, .keyboardF4: TERM_KEY_F4,
        .keyboardF5: TERM_KEY_F5, .keyboardF6: TERM_KEY_F6, .keyboardF7: TERM_KEY_F7, .keyboardF8: TERM_KEY_F8,
        .keyboardF9: TERM_KEY_F9, .keyboardF10: TERM_KEY_F10, .keyboardF11: TERM_KEY_F11, .keyboardF12: TERM_KEY_F12,
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let action = action(for: key) else {
                rest.insert(press)
                continue
            }
            action()
            if !key.modifierFlags.contains(.command) { startRepeat(key.keyCode, action) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endRepeat(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endRepeat(presses)
        super.pressesCancelled(presses, with: event)
    }

    /// What a hardware key does here, or nil to let UIKit handle it
    /// (plain text goes through insertText so dead keys and layouts work;
    /// Cmd shortcuts reach copy/paste and the shell's key commands).
    private func action(for key: UIKey) -> (@MainActor () -> Void)? {
        let flags = key.modifierFlags
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(TERM_MOD_SHIFT) }
        if flags.contains(.control) { mods |= UInt32(TERM_MOD_CTRL) }
        if flags.contains(.alternate) { mods |= UInt32(TERM_MOD_ALT) }

        if flags.contains(.command) {
            switch key.charactersIgnoringModifiers {
            case "=", "+": return { [weak self] in self.map { $0.userSetFontSize($0.fontSize + 1) } }
            case "-": return { [weak self] in self.map { $0.userSetFontSize($0.fontSize - 1) } }
            case "0": return { [weak self] in self?.userSetFontSize(FontSet.defaultPointSize) }
            default: return nil
            }
        }
        if let k = TerminalView.specialKeys[key.keyCode] {
            return { [weak self] in self?.send(k, mods: mods) }
        }
        if mods & UInt32(TERM_MOD_CTRL | TERM_MOD_ALT) != 0 {
            let text = key.charactersIgnoringModifiers
            guard !text.isEmpty else { return nil }
            return { [weak self] in self?.send(TERM_KEY_NONE, text: text, mods: mods) }
        }
        return nil
    }

    private func startRepeat(_ code: UIKeyboardHIDUsage, _ action: @escaping @MainActor () -> Void) {
        repeatingKey = code
        repeater.start(action)
    }

    private func endRepeat(_ presses: Set<UIPress>) {
        guard let code = repeatingKey, presses.contains(where: { $0.key?.keyCode == code }) else { return }
        repeater.stop()
        repeatingKey = nil
    }

    // ------------------------------------------------------------ clipboard

    override func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        clearSelection()
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        clearSelection()
        session.paste(text)
        didSendInput()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): selection != nil
        case #selector(paste(_:)): !isReadOnly && UIPasteboard.general.hasStrings
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    // ------------------------------------------------------------ smart keys

    func smartKey(_ action: SmartKeysBar.Action) {
        switch action {
        case .key(let key): send(key)
        case .text(let text): send(TERM_KEY_NONE, text: text)
        case .hideKeyboard: _ = resignFirstResponder()
        }
    }
}
