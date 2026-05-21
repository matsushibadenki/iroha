import Carbon
import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

private final class AISuggestionCoordinator {
    struct Request {
        var prompt: String
        var target: String
        var modelName: String
        var backend: AIBackend
        var apiKey: String
        var apiEndpoint: String
    }

    private struct RequestKey: Hashable {
        var backend: AIBackend
        var prompt: String
        var target: String
        var modelName: String
        var apiEndpoint: String
    }

    private var currentTask: Task<Void, Never>?
    private var cachedPredictions: [RequestKey: [String]] = [:]
    private var cacheOrder: [RequestKey] = []
    private let maxCacheCount = 64
    private let debounceNanoseconds: UInt64 = 250_000_000

    func cancel() {
        self.currentTask?.cancel()
        self.currentTask = nil
    }

    func request(
        _ requestConfig: Request,
        logger: @escaping (String) -> Void,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let key = RequestKey(
            backend: requestConfig.backend,
            prompt: requestConfig.prompt,
            target: requestConfig.target,
            modelName: requestConfig.modelName,
            apiEndpoint: requestConfig.apiEndpoint
        )

        if let predictions = self.cachedPredictions[key] {
            logger("AI suggestion cache hit: \(predictions)")
            completion(.success(predictions))
            return
        }

        self.cancel()

        let request = OpenAIRequest(
            prompt: requestConfig.prompt,
            target: requestConfig.target,
            modelName: requestConfig.modelName
        )
        let safeLogger: (String) -> Void = { message in
            Task { @MainActor in
                logger(message)
            }
        }

        self.currentTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.debounceNanoseconds ?? 250_000_000)
                try Task.checkCancellation()

                safeLogger("AI suggestion request started")
                let predictions = try await AIClient.sendRequest(
                    request,
                    backend: requestConfig.backend,
                    apiKey: requestConfig.apiKey,
                    apiEndpoint: requestConfig.apiEndpoint,
                    logger: safeLogger
                )
                try Task.checkCancellation()

                let coordinator = self
                await MainActor.run {
                    guard let coordinator else {
                        return
                    }
                    coordinator.store(predictions: predictions, for: key)
                    logger("AI suggestion request completed: \(predictions)")
                    completion(.success(predictions))
                    coordinator.currentTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    logger("AI suggestion request cancelled")
                }
            } catch {
                let coordinator = self
                await MainActor.run {
                    logger("AI suggestion request failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    coordinator?.currentTask = nil
                }
            }
        }
    }

    private func store(predictions: [String], for key: RequestKey) {
        self.cachedPredictions[key] = predictions
        self.cacheOrder.removeAll { $0 == key }
        self.cacheOrder.append(key)

        while self.cacheOrder.count > self.maxCacheCount {
            let oldest = self.cacheOrder.removeFirst()
            self.cachedPredictions.removeValue(forKey: oldest)
        }
    }
}

@objc(IrohaInputController)
class IrohaInputController: IMKInputController, NSMenuItemValidation {
    var segmentsManager: SegmentsManager
    private(set) var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem
    var transformSelectedTextMenuItem: NSMenuItem

    private var candidatesWindow: NSWindow
    private var candidatesViewController: CandidatesViewController

    private var predictionWindow: NSWindow
    private var predictionViewController: PredictionCandidatesViewController
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?
    private var lastKnownCursorLocation: CGPoint?

    private var replaceSuggestionWindow: NSWindow
    private var replaceSuggestionsViewController: ReplaceSuggestionsViewController
    private let aiSuggestionCoordinator = AISuggestionCoordinator()

    var promptInputWindow: PromptInputWindow
    var isPromptWindowVisible: Bool = false

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    // ピン留めプロンプトのキャッシュ（パフォーマンス向上のため）
    private var pinnedPromptsCache: [PromptHistoryItem] = []

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        // Chromium 系アプリの deadlock 回避のため、初期化時に client への
        // 問い合わせを行わない（Chromium issue 503787240）。
        // ウィンドウは直後に orderOut されるため origin はユーザーから不可視であり、
        // 最初の候補表示時に refreshCandidateWindow() で正しい位置に再配置される。
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    /// ピン留めプロンプトのキャッシュを更新
    func reloadPinnedPromptsCache() {
        guard let data = UserDefaults.standard.data(forKey: Config.PromptHistory.key),
              let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) else {
            self.pinnedPromptsCache = []
            return
        }
        self.pinnedPromptsCache = history.filter { $0.isPinned }
    }

    // MARK: - カスタムプロンプトショートカット検出
    private func checkCustomPromptShortcut(event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }

        let key = characters.lowercased()
        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        // 修飾キーがない場合は早期リターン（通常の入力）
        if eventModifiers.isEmpty {
            return nil
        }

        // キャッシュからショートカット付きのピン留めプロンプトを検索
        if let matched = self.pinnedPromptsCache.first(where: { item in
            guard let itemShortcut = item.shortcut else {
                return false
            }
            return itemShortcut.key == key && itemShortcut.modifiers == eventModifiers
        }) {
            return matched.prompt
        }

        return nil
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        DevLog.write("InputController init client=\(String(describing: inputClient))")
        let applicationDirectoryURL = if #available(macOS 13, *) {
            URL.applicationSupportDirectory
            .appending(path: "iroha", directoryHint: .isDirectory)
            .appending(path: "memory", directoryHint: .isDirectory)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("iroha", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        }

        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.irohaIdentifier)
        self.segmentsManager = SegmentsManager(
            kanaKanjiConverter: (NSApplication.shared.delegate as? AppDelegate)!.kanaKanjiConverter,
            applicationDirectoryURL: applicationDirectoryURL,
            containerURL: containerURL
        )

        let localizedAppName = Bundle.main.localizedInfoDictionary?["CFBundleName"] as? String ?? "iroha"
        self.appMenu = NSMenu(title: localizedAppName)
        self.liveConversionToggleMenuItem = NSMenuItem()
        self.transformSelectedTextMenuItem = NSMenuItem()

        let candidatesViewController = CandidatesViewController()
        let predictionViewController = PredictionCandidatesViewController()
        let replaceSuggestionsViewController = ReplaceSuggestionsViewController()

        self.candidatesViewController = candidatesViewController
        self.predictionViewController = predictionViewController
        self.replaceSuggestionsViewController = replaceSuggestionsViewController

        self.candidatesWindow = Self.makeCandidateWindow(contentViewController: candidatesViewController)
        self.predictionWindow = Self.makeCandidateWindow(contentViewController: predictionViewController)
        self.replaceSuggestionWindow = Self.makeCandidateWindow(contentViewController: replaceSuggestionsViewController)

        // PromptInputWindowの初期化
        self.promptInputWindow = PromptInputWindow()

        super.init(server: server, delegate: delegate, client: inputClient)

        // デリゲートの設定を super.init の後に移動
        self.candidatesViewController.delegate = self
        self.replaceSuggestionsViewController.delegate = self
        self.segmentsManager.delegate = self
        self.setupMenu()
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        DevLog.write("activateServer sender=\(String(describing: sender))")
        // アプリケーションサポートのディレクトリを準備しておく
        self.prepareApplicationSupportDirectory()
        // Register custom input table (if available) for `.tableName` usage
        CustomInputTableStore.registerIfExists()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateTransformSelectedTextMenuItemEnabledState()
        // ピン留めプロンプトのキャッシュを更新
        self.reloadPinnedPromptsCache()
        self.segmentsManager.activate()

        if let client = sender as? IMKTextInput {
            self.overrideKeyboardLayoutIfNeeded(client, reason: "activateServer")
        }
        // Chromium 系アプリで JS コンパイル中に activate された場合、
        // client.attributes(forCharacterIndex:) の同期呼び出しが deadlock を
        // 引き起こすため呼び出さない（Chromium issue 503787240）。
        // refreshCandidateWindow / refreshPredictionWindow は composing/selecting 状態で
        // client.attributes(...) を呼ぶ経路があるため、activate 中は使わずウィンドウを
        // 明示的に閉じる。
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
        self.hidePredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        DevLog.write("deactivateServer sender=\(String(describing: sender))")
        self.aiSuggestionCoordinator.cancel()
        self.segmentsManager.deactivate()
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.replaceSuggestionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        // Unicode入力モードの場合は状態だけリセットして終了
        // マウスクリック等でOSがMarkedTextを確定した場合、IME側からは消せないため
        if case .unicodeInput = self.inputState {
            self.inputState = .none
            return
        }
        if self.segmentsManager.isEmpty {
            return
        }
        let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
        if let client = sender as? IMKTextInput {
            self.insertCommittedText(text, client: client, reason: "commitComposition")
        }
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        DevLog.write("setValue tag=\(tag) value=\(String(describing: value)) sender=\(String(describing: sender))")

        if let value = value as? NSString {
            if let currentClient = self.currentInputClient(reason: "setValue") {
                self.overrideKeyboardLayoutIfNeeded(currentClient, reason: "setValue")
            }
            let modeIdentifier = value as String
            let englishMode = modeIdentifier == "com.apple.inputmethod.Roman"

            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバーやshortcut経由の切り替えに対応する。
                // composing中でも英数キーMarkedTextを保ったまま英語入力へ移る。
                if self.inputLanguage == .japanese {
                    self.inputLanguage = .english
                    self.segmentsManager.stopJapaneseInput()
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                    let (clientAction, clientActionCallback) = self.inputState.event(
                        eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0x00),
                        userAction: .かな,
                        inputLanguage: self.inputLanguage,
                        liveConversionEnabled: false,
                        enableDebugWindow: false,
                        enableSuggestion: false
                    )
                    if let currentClient = self.currentInputClient(reason: "setValue.handleClientAction") {
                        _ = self.handleClientAction(
                            clientAction,
                            clientActionCallback: clientActionCallback,
                            client: currentClient
                        )
                    }
                }
            }
            DevLog.write("setValue handled locally tag=\(tag) mode=\(modeIdentifier)")
            return
        }

        super.setValue(value, forTag: tag, client: sender)
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        DevLog.write("recognizedEvents sender=\(String(describing: sender))")
        return Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        self.handleKeyEvent(event, client: sender, entryPoint: "handle")
    }

    @MainActor override func inputText(_ string: String!, client sender: Any!) -> Bool {
        DevLog.write("inputText string=\(String(describing: string)) sender=\(String(describing: sender)) state=\(self.inputState)")
        guard let string, let client = sender as? IMKTextInput else {
            return false
        }
        var handled = false
        for character in string {
            let eventCore = self.keyEventCoreForInputText(character)
            let userAction = UserAction.getUserAction(eventCore: eventCore, inputLanguage: self.inputLanguage)
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            let (clientAction, clientActionCallback) = inputState.event(
                eventCore: eventCore,
                userAction: userAction,
                inputLanguage: self.inputLanguage,
                liveConversionEnabled: Config.LiveConversion().value,
                enableDebugWindow: Config.DebugWindow().value,
                enableSuggestion: aiBackendEnabled
            )
            DevLog.write("inputText action=\(clientAction) callback=\(clientActionCallback)")
            handled = self.handleClientAction(clientAction, clientActionCallback: clientActionCallback, client: client) || handled
        }
        return handled
    }

    @MainActor override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        DevLog.write("inputText:key string=\(String(describing: string)) key=\(keyCode) flags=\(flags) sender=\(String(describing: sender)) state=\(self.inputState)")
        guard let string, let client = sender as? IMKTextInput else {
            return false
        }
        let eventCore = KeyEventCore(
            modifierFlags: .init(from: NSEvent.ModifierFlags(rawValue: UInt(flags))),
            characters: string,
            charactersIgnoringModifiers: string,
            keyCode: UInt16(clamping: keyCode)
        )
        return self.handleKeyEventCore(eventCore, client: client, entryPoint: "inputText:key")
    }

    private func keyEventCoreForInputText(_ character: Character) -> KeyEventCore {
        let string = String(character)
        let keyCode: UInt16 = switch character {
        case "\r", "\n": 36
        case " ": 49
        case "\u{8}", "\u{7F}": 51
        case "\t": 48
        default: 0
        }
        return KeyEventCore(
            modifierFlags: [],
            characters: string,
            charactersIgnoringModifiers: string,
            keyCode: keyCode
        )
    }

    @MainActor private func handleKeyEventCore(_ eventCore: KeyEventCore, client: IMKTextInput, entryPoint: String) -> Bool {
        let userAction = UserAction.getUserAction(eventCore: eventCore, inputLanguage: inputLanguage)
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        let (clientAction, clientActionCallback) = inputState.event(
            eventCore: eventCore,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: aiBackendEnabled
        )
        DevLog.write("\(entryPoint) action=\(clientAction) callback=\(clientActionCallback)")
        return handleClientAction(clientAction, clientActionCallback: clientActionCallback, client: client)
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor private func handleKeyEvent(_ event: NSEvent!, client sender: Any!, entryPoint: String) -> Bool {
        guard let event, let client = sender as? IMKTextInput else {
            DevLog.write("\(entryPoint) ignored event=\(String(describing: event)) sender=\(String(describing: sender))")
            return false
        }
        guard event.type == .keyDown else {
            DevLog.write("\(entryPoint) ignored non-keyDown type=\(event.type.rawValue)")
            return false
        }
        DevLog.write("\(entryPoint) keyDown keyCode=\(event.keyCode) chars=\(event.characters ?? "nil") state=\(self.inputState)")

        // カスタムプロンプトショートカットのチェック
        if let matchedPrompt = checkCustomPromptShortcut(event: event) {
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            if aiBackendEnabled && !self.isPromptWindowVisible {
                if self.triggerAiTranslation(initialPrompt: matchedPrompt) {
                    return true
                }
            }
            // ショートカットがマッチした場合はイベントを消費して他のハンドラに渡さない
            return true
        }

        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)
        let charactersForOptionDirectInput = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option))
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(
            characters: charactersForOptionDirectInput,
            modifierFlags: eventModifiers,
            inputLanguage: inputLanguage,
            inputState: inputState,
           typeBackSlash: Config.TypeBackSlash().value
           ) {
            self.insertCommittedText(text, client: client, reason: "optionDirectFullWidthInput")
            return true
        }

        let userAction = UserAction.getUserAction(eventCore: event.keyEventCore, inputLanguage: inputLanguage)

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                if self.triggerAiTranslation(initialPrompt: "english") {
                    return true
                }
                if !self.segmentsManager.isEmpty {
                    _ = self.handleClientAction(.submitHalfWidthRomanCandidate, clientActionCallback: .transition(.none), client: client)
                    self.switchInputLanguage(.english, client: client)
                    return true
                }
            }
        }

        // かなキー（keyCode 104）の処理（ダブルタップで日本語への翻訳）
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                if self.triggerAiTranslation(initialPrompt: "japanese") {
                    return true
                }
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // If AI backend is off, ignore the suggest action
            if !aiBackendEnabled {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: AI backend is off")
                return false
            }

            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            guard let selectedRange = self.safeSelectedRange(client: client, reason: "handleKeyEvent.suggest") else {
                self.segmentsManager.appendDebugMessage("Suggest action skipped selected text check for unsafe client")
                return false
            }
            self.segmentsManager.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                self.segmentsManager.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                return self.handleClientAction(.showPromptInputWindow, clientActionCallback: .fallthrough, client: client)
            } else {
                self.segmentsManager.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        let (clientAction, clientActionCallback) = inputState.event(
            eventCore: event.keyEventCore,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: aiBackendEnabled
        )
        DevLog.write("\(entryPoint) action=\(clientAction) callback=\(clientActionCallback)")
        return handleClientAction(clientAction, clientActionCallback: clientActionCallback, client: client)
    }

    private var inputStyle: InputStyle {
        switch Config.InputStyle().value {
        case .default:
            .mapped(id: .defaultRomanToKana)
        case .defaultAZIK:
            .mapped(id: .defaultAZIK)
        case .defaultKanaUS:
            .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS:
            .mapped(id: .defaultKanaJIS)
        case .custom:
            if CustomInputTableStore.exists() {
                .mapped(id: .tableName(CustomInputTableStore.tableName))
            } else {
                .mapped(id: .defaultRomanToKana)
            }
        }
    }

    // この種のコードは複雑にしかならないので、lintを無効にする
    // swiftlint:disable:next cyclomatic_complexity
    @MainActor func handleClientAction(_ clientAction: ClientAction, clientActionCallback: ClientActionCallback, client: IMKTextInput) -> Bool {
        // return only false
        switch clientAction {
        case .showCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterFirstCandidatePreviewMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: false)
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: true)
            self.segmentsManager.update(requestRichCandidates: true)
        case .appendToMarkedText(let string):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let string):
            self.insertCommittedText(string, client: client, reason: "insertWithoutMarkedText")
        case .editSegment(let count):
            self.segmentsManager.editSegment(count: count)
        case .commitMarkedText:
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.insertCommittedText(text, client: client, reason: "commitMarkedText")
        case .commitMarkedTextAndAppendToMarkedText(let string):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.insertCommittedText(text, client: client, reason: "commitMarkedTextAndAppendToMarkedText")
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.insertCommittedText(text, client: client, reason: "commitMarkedTextAndAppendPieceToMarkedText")
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .submitSelectedCandidate:
            self.submitSelectedCandidate()
        case .removeLastMarkedText:
            self.segmentsManager.deleteBackwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .selectPrevCandidate:
            self.segmentsManager.requestSelectingPrevCandidate()
        case .selectNextCandidate:
            self.segmentsManager.requestSelectingNextCandidate()
        case .selectNumberCandidate(let num):
            self.segmentsManager.requestSelectingRow(self.candidatesViewController.getNumberCandidate(num: num))
            self.submitSelectedCandidate()
            self.segmentsManager.requestResettingSelection()
        case .submitHiraganaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toHiragana()
            })
        case .submitKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana()
            })
        case .submitHankakuKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .submitFullWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            })
        case .submitHalfWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .enableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: true)
        case .disableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: false)
        case .stopComposition:
            self.segmentsManager.stopComposition()
        case .forgetMemory:
            self.segmentsManager.forgetMemory()
        case .selectInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .commitMarkedTextAndSelectInputLanguage(let language):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.insertCommittedText(text, client: client, reason: "commitMarkedTextAndSelectInputLanguage")
            self.switchInputLanguage(language, client: client)
        // PredictiveSuggestion
        case .requestPredictiveSuggestion:
            self.requestPredictiveSuggestion()
        case .acceptPredictionCandidate:
            self.acceptPredictionCandidate()
        // ReplaceSuggestion
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectNextCandidate()
        case .selectPrevReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectPrevCandidate()
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate()
        case .hideReplaceSuggestionWindow:
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
        // Selected Text Transform
        case .showPromptInputWindow:
            self.segmentsManager.appendDebugMessage("Executing showPromptInputWindow")
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.segmentsManager.appendDebugMessage("Executing transformSelectedText with text: '\(selectedText)' and prompt: '\(prompt)'")
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        // Unicode Input (Shift+Ctrl+U)
        case .enterUnicodeInputMode:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .appendToUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .removeLastUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .submitUnicodeInput(let codePoint):
            if let scalar = UInt32(codePoint, radix: 16), let unicodeScalar = Unicode.Scalar(scalar) {
                let character = String(Character(unicodeScalar))
                self.insertCommittedText(character, client: client, reason: "submitUnicodeInput")
            }
        case .cancelUnicodeInput:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            // 選択中の候補を確定
            self.submitSelectedCandidate()
            // 残りのテキストがあればひらがなのまま確定
            if !self.segmentsManager.isEmpty {
                let text = self.segmentsManager.convertTarget
                self.insertCommittedText(text, client: client, reason: "submitSelectedCandidateAndEnterUnicodeInputMode")
                self.segmentsManager.stopComposition()
            }
        // MARK: 特殊ケース
        case .consume:
            // 何もせず先に進む
            break
        case .fallthrough:
            return false
        }

        switch clientActionCallback {
        case .fallthrough:
            break
        case .transition(let inputState):
            // 遷移した時にreplaceSuggestionWindowをhideする
            if inputState != .replaceSuggestion {
                self.replaceSuggestionWindow.orderOut(nil)
            }
            if inputState == .none {
                self.switchInputLanguage(self.inputLanguage, client: client)
            }
            self.inputState = inputState
        case .basedOnBackspace(let ifIsEmpty, let ifIsNotEmpty), .basedOnSubmitCandidate(let ifIsEmpty, let ifIsNotEmpty):
            self.inputState = self.segmentsManager.isEmpty ? ifIsEmpty : ifIsNotEmpty
        }

        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        return true
    }

    @MainActor private func insertCommittedText(_ text: String, client: IMKTextInput, reason: String) {
        guard !text.isEmpty else {
            DevLog.write("insertCommittedText skipped empty reason=\(reason)")
            return
        }
        let markedRange = self.safeMarkedRange(client: client, reason: "insertCommittedText")
        let replacementRange: NSRange
        if let markedRange, markedRange.location != NSNotFound {
            replacementRange = markedRange
        } else {
            replacementRange = NSRange(location: NSNotFound, length: 0)
        }
        DevLog.write("insertCommittedText reason=\(reason) text='\(text)' replacementRange=\(replacementRange)")
        client.insertText(text, replacementRange: replacementRange)
    }

    func currentInputClient(reason: String) -> IMKTextInput? {
        let rawClient: Any? = self.client()
        guard let client = rawClient as? IMKTextInput else {
            DevLog.write("input client unavailable or invalid reason=\(reason) client=\(String(describing: rawClient))")
            return nil
        }
        return client
    }

    func shouldAvoidSynchronousClientQueries(client providedClient: IMKTextInput? = nil, reason: String) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier?.lowercased() ?? ""
        let appName = app?.localizedName?.lowercased() ?? ""
        let appPath = app?.bundleURL?.path.lowercased() ?? ""
        let frameworksURL = app?.bundleURL?.appendingPathComponent("Contents/Frameworks")
        let frameworkNames = [
            "Electron Framework.framework",
            "Chromium Embedded Framework.framework",
            "Brave Browser Framework.framework",
            "Google Chrome Framework.framework",
            "Microsoft Edge Framework.framework"
        ]
        let hasRiskyFramework = frameworkNames.contains { frameworkName in
            guard let frameworksURL else {
                return false
            }
            return FileManager.default.fileExists(atPath: frameworksURL.appendingPathComponent(frameworkName).path)
        }
        let riskyBundleIDFragments = [
            "electron",
            "chromium",
            "chrome",
            "brave",
            "edgemac",
            "vscode",
            "slack",
            "discord",
            "notion",
            "obsidian",
            "codex",
            "atlas",
            "microsoft.word",
            "microsoft.excel",
            "microsoft.powerpoint",
            "microsoft.teams"
        ]
        let riskyNameMatches = [
            "electron",
            "chrome",
            "google chrome",
            "brave browser",
            "microsoft edge",
            "visual studio code",
            "code",
            "slack",
            "discord",
            "notion",
            "obsidian",
            "codex",
            "microsoft word",
            "microsoft excel",
            "microsoft powerpoint",
            "microsoft teams"
        ]
        let result =
            hasRiskyFramework ||
            riskyBundleIDFragments.contains { bundleID.contains($0) } ||
            riskyNameMatches.contains(appName) ||
            appPath.contains("/electron") ||
            appPath.contains("/google chrome.app") ||
            appPath.contains("/brave browser.app") ||
            appPath.contains("/microsoft edge.app") ||
            appPath.contains("/visual studio code.app") ||
            appPath.contains("/slack.app") ||
            appPath.contains("/discord.app") ||
            appPath.contains("/codex.app") ||
            appPath.contains("/microsoft word.app") ||
            appPath.contains("/microsoft excel.app") ||
            appPath.contains("/microsoft powerpoint.app") ||
            appPath.contains("/microsoft teams.app")
        DevLog.write("avoid synchronous client queries result=\(result) reason=\(reason) name=\(app?.localizedName ?? "nil") appBundle=\(app?.bundleIdentifier ?? "nil") framework=\(hasRiskyFramework)")
        return result
    }

    func shouldAvoidSynchronousClientAttributes() -> Bool {
        self.shouldAvoidSynchronousClientQueries(reason: "legacyAttributesCheck")
    }

    func safeSelectedRange(client: IMKTextInput, reason: String) -> NSRange? {
        guard !self.shouldAvoidSynchronousClientQueries(client: client, reason: reason) else {
            DevLog.write("selectedRange skipped for unsafe client reason=\(reason)")
            return nil
        }
        return client.selectedRange()
    }

    func safeMarkedRange(client: IMKTextInput, reason: String) -> NSRange? {
        guard !self.shouldAvoidSynchronousClientQueries(client: client, reason: reason) else {
            DevLog.write("markedRange skipped for unsafe client reason=\(reason)")
            return nil
        }
        return client.markedRange()
    }

    func safeString(client: IMKTextInput, from range: NSRange, actualRange: inout NSRange, reason: String) -> String? {
        guard !self.shouldAvoidSynchronousClientQueries(client: client, reason: reason) else {
            DevLog.write("string(from:) skipped for unsafe client reason=\(reason)")
            return nil
        }
        return client.string(from: range, actualRange: &actualRange)
    }

    func safeDocumentLength(client: IMKTextInput, reason: String) -> Int? {
        guard !self.shouldAvoidSynchronousClientQueries(client: client, reason: reason) else {
            DevLog.write("length skipped for unsafe client reason=\(reason)")
            return nil
        }
        return client.length()
    }

    private func currentInputSourceID() -> String? {
        guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(selected, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
    }

    private func selectInputSource(id: String) {
        let filter = [
            kTISPropertyInputSourceID as String: id as CFString
        ] as CFDictionary
        guard let sourceList = TISCreateInputSourceList(filter, true) else {
            DevLog.write("selectInputSource failed: sourceList nil id=\(id)")
            return
        }
        guard let sources = sourceList.takeRetainedValue() as? [TISInputSource] else {
            return
        }
        guard let source = sources.first else {
            DevLog.write("selectInputSource failed: source not found id=\(id)")
            return
        }
        let enableStatus = TISEnableInputSource(source)
        let selectStatus = TISSelectInputSource(source)
        DevLog.write("selectInputSource id=\(id) enableStatus=\(enableStatus) selectStatus=\(selectStatus)")
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        self.inputLanguage = language
        self.overrideKeyboardLayoutIfNeeded(client, reason: "switchInputLanguage")
        switch language {
        case .english:
            self.selectInputModeIfNeeded("com.apple.inputmethod.Roman", client: client, reason: "switchInputLanguage")
            self.segmentsManager.stopJapaneseInput()
        case .japanese:
            self.selectInputModeIfNeeded("dev.ensan.inputmethod.iroha.Japanese", client: client, reason: "switchInputLanguage")
        }
    }

    @MainActor private func overrideKeyboardLayoutIfNeeded(_ client: IMKTextInput, reason: String) {
        // During local IMK debugging, forcing the hardware keyboard layout can make macOS
        // immediately leave this input source on some systems. Keep the selected IM stable.
        DevLog.write("overrideKeyboard skipped reason=\(reason) layout=\(Config.KeyboardLayout().value.layoutIdentifier)")
    }

    @MainActor private func selectInputModeIfNeeded(_ mode: String, client: IMKTextInput, reason: String) {
        // Avoid asking macOS to re-select an IMK mode while debugging activation churn.
        // The controller's internal InputLanguage is enough for composing behavior here.
        DevLog.write("selectMode skipped reason=\(reason) mode=\(mode)")
    }

    @MainActor func refreshCandidateWindow() {
        switch self.segmentsManager.getCurrentCandidateWindow(inputState: self.inputState) {
        case .selecting(let candidates, let selectionIndex):
            guard let cursorLocation = self.cursorAnchorLocation(reason: "refreshCandidateWindow.selecting") else {
                self.hideCandidateWindow()
                return
            }
            self.candidatesViewController.showCandidateIndex = true
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: cursorLocation
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            guard let cursorLocation = self.cursorAnchorLocation(reason: "refreshCandidateWindow.composing") else {
                self.hideCandidateWindow()
                return
            }
            self.candidatesViewController.showCandidateIndex = false
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: cursorLocation
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.hideCandidateWindow()
        }
    }

    @MainActor func refreshPredictionWindow() {
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        let predictions = self.requestPreferredPredictionCandidates()
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        let candidates = predictions.map { prediction in
            Candidate(
                text: prediction.displayText,
                value: 0,
                composingCount: .surfaceCount(prediction.displayText.count),
                lastMid: 0,
                data: []
            )
        }

        self.lastPredictionCandidates = candidates.map(\.text)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        guard let cursorLocation = self.cursorAnchorLocation(reason: "refreshPredictionWindow") else {
            self.hidePredictionWindow()
            return
        }
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: cursorLocation
        )

        if Config.LiveConversion().value {
            self.predictionWindow.orderFront(nil)
            return
        }

        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // アンカーである候補ウィンドウの中心が乗っているスクリーンを基準にする。
        // predictionWindow.screen / candidatesWindow.screen はマルチディスプレイ遷移直後に
        // 古いディスプレイを返すことがあるため、frame の中心点で能動的に判定する。
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    @MainActor private func showCachedPredictionWindow() {
        let candidates = self.lastPredictionCandidates.map { text in
            Candidate(
                text: text,
                value: 0,
                composingCount: .surfaceCount(text.count),
                lastMid: 0,
                data: []
            )
        }
        guard !candidates.isEmpty else {
            return
        }
        guard let cursorLocation = self.cursorAnchorLocation(reason: "showCachedPredictionWindow") else {
            self.hidePredictionWindow()
            return
        }
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: cursorLocation
        )
        self.predictionWindow.orderFront(nil)
    }

    @MainActor
    func cursorAnchorLocation(client providedClient: IMKTextInput? = nil, reason: String) -> CGPoint? {
        guard let client = providedClient ?? self.currentInputClient(reason: reason) else {
            DevLog.write("cursorAnchorLocation skipped: client nil reason=\(reason)")
            return nil
        }

        if self.shouldAvoidSynchronousClientQueries(client: client, reason: reason) {
            let fallback = self.lastKnownCursorLocation ?? NSEvent.mouseLocation
            DevLog.write("cursorAnchorLocation fallback reason=\(reason) location=\(fallback)")
            return fallback
        }

        var rect: NSRect = .zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        let location = rect.origin
        if location != .zero {
            self.lastKnownCursorLocation = location
        }
        DevLog.write("cursorAnchorLocation attributes reason=\(reason) location=\(location)")
        return location
    }

    @MainActor
    private func hideCandidateWindow() {
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    @MainActor
    private func acceptPredictionCandidate() {
        let predictions = self.requestPreferredPredictionCandidates()
        guard let prediction = predictions.first else {
            return
        }
        let deleteCount = prediction.deleteCount
        if deleteCount > 0 {
            self.segmentsManager.deleteBackwardFromCursorPosition(count: deleteCount)
        }
        let appendText = prediction.appendText

        guard !appendText.isEmpty else {
            return
        }

        self.segmentsManager.insertAtCursorPosition(appendText, inputStyle: .direct)
    }

    private func requestPreferredPredictionCandidates() -> [SegmentsManager.PredictionCandidate] {
        SegmentsManager.preferredPredictionCandidates(
            typoCorrectionCandidates: self.segmentsManager.requestTypoCorrectionPredictionCandidates(),
            predictionCandidates: self.segmentsManager.requestPredictionCandidates()
        )
    }

    var retryCount = 0
    let maxRetries = 3

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.segmentsManager.appendDebugMessage(errorMessage)
    }

    @MainActor func getCursorLocation() -> CGPoint {
        let location = self.cursorAnchorLocation(reason: "getCursorLocation") ?? .zero
        self.segmentsManager.appendDebugMessage("カーソル位置取得: \(location)")
        return location
    }

    @MainActor func refreshMarkedText() {
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        let currentMarkedText = self.segmentsManager.getCurrentMarkedText(inputState: self.inputState)
        for part in currentMarkedText where !part.content.isEmpty {
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: self.markedTextAttributes(
                        focus: part.focus,
                        highlight: highlight,
                        underline: underline
                    )
                )
            )
        }
        DevLog.write("refreshMarkedText text='\(text.string)' selection=\(currentMarkedText.selectionRange) state=\(self.inputState)")
        guard let client = self.currentInputClient(reason: "refreshMarkedText") else {
            DevLog.write("refreshMarkedText skipped: client nil")
            return
        }
        let plainText = text.string
        DevLog.write("setMarkedText plain='\(plainText)' selection=\(currentMarkedText.selectionRange)")
        client.setMarkedText(
            plainText,
            selectionRange: currentMarkedText.selectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func markedTextAttributes(
        focus: SegmentsManager.MarkedText.FocusState,
        highlight: [NSAttributedString.Key: Any]?,
        underline: [NSAttributedString.Key: Any]?
    ) -> [NSAttributedString.Key: Any]? {
        switch focus {
        case .focused:
            highlight
        case .unfocused:
            underline
        case .none:
            [:]
        }
    }

    @MainActor
    func submitCandidate(_ candidate: Candidate) {
        if let client = self.currentInputClient(reason: "submitCandidate") {
            // インサートを行う前にコンテキストを取得する
            let cleanLeftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30)
            self.insertCommittedText(candidate.text, client: client, reason: "submitCandidate")
            // アプリケーションサポートのディレクトリを準備しておく
            self.segmentsManager.prefixCandidateCommited(candidate, leftSideContext: cleanLeftSideContext ?? "")
        }
    }

    @MainActor
    func submitSelectedCandidate() {
        if let candidate = self.segmentsManager.selectedCandidate {
            self.submitCandidate(candidate)
            self.segmentsManager.requestResettingSelection()
        }
    }
}

extension IrohaInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            self.submitSelectedCandidate()
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Task { @MainActor in
            self.segmentsManager.requestSelectingRow(row)
        }
    }
}

extension IrohaInputController: SegmentManagerDelegate {
    func getLeftSideContext(maxCount: Int) -> String? {
        guard let client = self.currentInputClient(reason: "getLeftSideContext") else {
            self.segmentsManager.appendDebugMessage("\(#function): client nil")
            return nil
        }
        guard let markedRange = self.safeMarkedRange(client: client, reason: "getLeftSideContext.markedRange") else {
            self.segmentsManager.appendDebugMessage("\(#function): skipped for unsafe client")
            return nil
        }
        let endIndex = markedRange.location
        guard endIndex != NSNotFound else {
            self.segmentsManager.appendDebugMessage("\(#function): marked range not found")
            return nil
        }
        let leftRange = NSRange(location: max(endIndex - maxCount, 0), length: min(endIndex, maxCount))
        var actual = NSRange()
        // 同じ行の文字のみコンテキストに含める
        let leftSideContext = self.safeString(client: client, from: leftRange, actualRange: &actual, reason: "getLeftSideContext.string")
        self.segmentsManager.appendDebugMessage("\(#function): leftSideContext=\(leftSideContext ?? "nil")")
        return leftSideContext
    }
}

extension IrohaInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        self.segmentsManager.requestSelectingSuggestionRow(row)
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            if let candidate = self.replaceSuggestionsViewController.getSelectedCandidate() {
                if let client = self.currentInputClient(reason: "replaceSuggestionSubmitted") {
                    // 選択された候補をテキストとして挿入
                    self.insertCommittedText(candidate.text, client: client, reason: "replaceSuggestionSubmitted")
                    // サジェスト候補ウィンドウを非表示にする
                    self.replaceSuggestionWindow.setIsVisible(false)
                    self.replaceSuggestionWindow.orderOut(nil)
                    // 変換状態をリセット
                    self.segmentsManager.stopComposition()
                }
            }
        }
    }
}

// Suggest Candidate
extension IrohaInputController {
    // MARK: - Replace Suggestion Request Handling
    @MainActor func requestReplaceSuggestion(
        targetOverride: String? = nil,
        composingCountOverride: Int? = nil,
        promptOverride: String? = nil
    ) {
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 開始")

        // リクエスト開始時に前回の候補をクリアし、ウィンドウを非表示にする
        self.segmentsManager.setReplaceSuggestions([])
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)

        // Get selected backend preference
        let preference = Config.AIBackendPreference().value

        // If backend is off, do nothing
        if preference == .off {
            self.segmentsManager.appendDebugMessage("AI backend is off, skipping suggestion")
            return
        }

        let composingText = targetOverride ?? self.segmentsManager.convertTarget
        let composingCount = composingCountOverride ?? composingText.count

        // プロンプトを取得
        let prompt = promptOverride ?? self.getLeftSideContext(maxCount: 100) ?? ""

        self.segmentsManager.appendDebugMessage("プロンプト取得成功: \(prompt) << \(composingText)")

        guard let requestConfig = self.aiSuggestionRequestConfig(
            preference: preference,
            prompt: prompt,
            target: composingText
        ) else {
            self.segmentsManager.appendDebugMessage("Unexpected .off state in backend selection")
            return
        }
        self.segmentsManager.appendDebugMessage("APIリクエスト準備完了: prompt=\(prompt), target=\(composingText), modelName=\(requestConfig.modelName)")
        self.segmentsManager.appendDebugMessage("Using backend: \(requestConfig.backend.rawValue)")

        self.segmentsManager.appendDebugMessage("AI候補リクエストをキューへ追加")
        self.aiSuggestionCoordinator.request(
            requestConfig,
            logger: { [weak self] message in
                self?.segmentsManager.appendDebugMessage(message)
            },
            completion: { [weak self] result in
                guard let self else {
                    return
                }

                switch result {
                case .success(let predictions):
                    self.segmentsManager.appendDebugMessage("APIレスポンス受信成功: \(predictions)")
                    let candidates = self.makeReplaceSuggestionCandidates(
                        predictions: predictions,
                        composingCount: composingCount
                    )
                    self.showReplaceSuggestions(candidates)
                case .failure(let error):
                    let errorMessage = "APIリクエストエラー: \(error.localizedDescription)"
                    self.segmentsManager.appendDebugMessage(errorMessage)

                    let alert = NSAlert()
                    alert.messageText = "変換に失敗しました"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        )
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 終了")
    }

    private func aiSuggestionRequestConfig(
        preference: Config.AIBackendPreference.Value,
        prompt: String,
        target: String
    ) -> AISuggestionCoordinator.Request? {
        let apiKey = Config.OpenAiApiKey().value
        switch preference {
        case .foundationModels:
            return AISuggestionCoordinator.Request(
                prompt: prompt,
                target: target,
                modelName: Config.OpenAiModelName().value,
                backend: .foundationModels,
                apiKey: apiKey,
                apiEndpoint: Config.OpenAiApiEndpoint().value
            )
        case .ollama:
            return AISuggestionCoordinator.Request(
                prompt: prompt,
                target: target,
                modelName: Config.OllamaModelName().value,
                backend: .ollama,
                apiKey: apiKey,
                apiEndpoint: Config.OllamaApiEndpoint().value
            )
        case .mlxSwift:
            return AISuggestionCoordinator.Request(
                prompt: prompt,
                target: target,
                modelName: Config.MLXSwiftModelName().value,
                backend: .mlxSwift,
                apiKey: apiKey,
                apiEndpoint: ""
            )
        case .openAI:
            return AISuggestionCoordinator.Request(
                prompt: prompt,
                target: target,
                modelName: Config.OpenAiModelName().value,
                backend: .openAI,
                apiKey: apiKey,
                apiEndpoint: Config.OpenAiApiEndpoint().value
            )
        case .off:
            return nil
        }
    }

    @MainActor func requestPredictiveSuggestion() {
        let prompt = self.getLeftSideContext(maxCount: 200) ?? ""
        self.requestReplaceSuggestion(
            targetOverride: "つづき",
            composingCountOverride: 0,
            promptOverride: prompt
        )
    }

    @MainActor private func makeReplaceSuggestionCandidates(predictions: [String], composingCount: Int) -> [Candidate] {
        let candidates = predictions.map { text in
            Candidate(
                text: text,
                value: PValue(0),
                composingCount: .surfaceCount(composingCount),
                lastMid: 0,
                data: [],
                actions: [],
                inputable: true
            )
        }
        self.segmentsManager.appendDebugMessage("候補変換成功: \(candidates.map { $0.text })")
        return candidates
    }

    @MainActor private func showReplaceSuggestions(_ candidates: [Candidate]) {
        self.segmentsManager.appendDebugMessage("候補ウィンドウ更新中...")
        guard !candidates.isEmpty else {
            self.segmentsManager.setReplaceSuggestions([])
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
            self.segmentsManager.appendDebugMessage("AI候補が空のため候補ウィンドウを閉じました")
            return
        }

        self.segmentsManager.setReplaceSuggestions(candidates)
        self.replaceSuggestionsViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: self.getCursorLocation()
        )
        self.replaceSuggestionWindow.setIsVisible(true)
        self.replaceSuggestionWindow.makeKeyAndOrderFront(nil)
        self.segmentsManager.appendDebugMessage("候補ウィンドウ更新完了")
    }

    // MARK: - Window Management
    @MainActor func hideReplaceSuggestionCandidateView() {
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)
    }

    @MainActor func submitSelectedSuggestionCandidate() {
        if let candidate = self.replaceSuggestionsViewController.getSelectedCandidate() {
            if let client = self.currentInputClient(reason: "submitSelectedSuggestionCandidate") {
                self.insertCommittedText(candidate.text, client: client, reason: "submitSelectedSuggestionCandidate")
                self.replaceSuggestionWindow.setIsVisible(false)
                self.replaceSuggestionWindow.orderOut(nil)
                self.segmentsManager.stopComposition()
            }
        }
    }

    // MARK: - Helper Methods
    private func retrySuggestionRequestIfNeeded(cursorPosition: CGPoint) {
        if retryCount < maxRetries {
            retryCount += 1
            self.segmentsManager.appendDebugMessage("再試行中... (\(retryCount)回目)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestReplaceSuggestion()
            }
        } else {
            self.segmentsManager.appendDebugMessage("再試行上限に達しました。")
            retryCount = 0
        }
    }

}
