import Foundation

protocol BoolConfigItem: ConfigItem<Bool> {
    static var `default`: Bool { get }
}

extension BoolConfigItem {
    public var value: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: Self.key) {
                value as? Bool ?? Self.default
            } else {
                Self.default
            }
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    /// デバッグウィンドウにd/Dで遷移する設定
    public struct DebugWindow: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.debug.enableDebugWindow"
    }
    /// 予測入力のデバッグ機能を有効化する設定
    public struct DebugPredictiveTyping: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.debug.predictiveTyping"
    }
    /// 入力訂正のデバッグ機能を有効化する設定
    public struct DebugTypoCorrection: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.debug.typoCorrection"
    }
    /// ライブ変換を有効化する設定
    public struct LiveConversion: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.enableLiveConversion"
    }
    /// 円マークの代わりにバックスラッシュを入力する設定
    public struct TypeBackSlash: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.typeBackSlash"
    }
    /// 「　」の代わりに「 」を入力する設定
    public struct TypeHalfSpace: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.typeHalfSpace"
    }
    /// Optionキー押下時に直接全角英数を入力する設定
    public struct OptionDirectFullWidthInput: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.optionDirectFullWidthInput"
    }
    /// AI変換時にコンテキストを含めるかどうか
    public struct IncludeContextInAITransform: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.includeContextInAITransform"
    }
    /// Chromium/Electronなど未対応アプリではApple日本語入力へ自動切替する設定
    public struct AutoSwitchUnsupportedAppsToAppleJapanese: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.autoSwitchUnsupportedAppsToAppleJapanese"
    }
}
