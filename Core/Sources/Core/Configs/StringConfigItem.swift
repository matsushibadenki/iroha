//
//  StringConfigItem.swift
//  azooKeyMac
//
//  Created by miwa on 2024/04/27.
//

import Foundation

protocol StringConfigItem: ConfigItem<String> {}

extension StringConfigItem {
    public var value: String {
        get {
            UserDefaults.standard.string(forKey: Self.key) ?? ""
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    public struct ZenzaiProfile: StringConfigItem {
        public init() {}

        public static let key: String = "dev.ensan.inputmethod.iroha.preference.ZenzaiProfile"
    }
}

extension Config {
    /// OpenAIモデル名
    public struct OpenAiModelName: StringConfigItem {
        public init() {}

        public static let `default`: String = "gpt-4o-mini"
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.OpenAiModelName"
    }

    /// OpenAI API エンドポイント
    public struct OpenAiApiEndpoint: StringConfigItem {
        public init() {}

        public static let `default` = "https://api.openai.com/v1/chat/completions"
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.OpenAiApiEndpoint"

        public var value: String {
            get {
                let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// Ollamaモデル名
    public struct OllamaModelName: StringConfigItem {
        public init() {}

        public static let `default`: String = "gemma4:e2b"
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.OllamaModelName"

        public var value: String {
            get {
                let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
                if stored == "Gemma E2B" {
                    return Self.default
                }
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// Ollama Chat APIエンドポイント
    public struct OllamaApiEndpoint: StringConfigItem {
        public init() {}

        public static let `default`: String = "http://localhost:11434/api/chat"
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.OllamaApiEndpoint"

        public var value: String {
            get {
                let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// MLX Swiftモデル名
    public struct MLXSwiftModelName: StringConfigItem {
        public init() {}

        public static let `default`: String = "Gemma E2B"
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.MLXSwiftModelName"

        public var value: String {
            get {
                let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// プロンプト履歴（JSON形式で保存）
    public struct PromptHistory: StringConfigItem {
        public static let key: String = "dev.ensan.inputmethod.iroha.preference.PromptHistory"
    }
}
