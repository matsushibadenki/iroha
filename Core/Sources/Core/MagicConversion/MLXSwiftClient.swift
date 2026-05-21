import Foundation

public enum MLXSwiftClientError: LocalizedError, @unchecked Sendable {
    case runtimeNotLinked

    public var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "MLX Swift runtime is not linked yet. Use Ollama during early development or add the MLX Swift implementation behind MLXSwiftClient."
        }
    }
}

public enum MLXSwiftClient {
    public static let defaultModelName = "Gemma E2B"

    public static func sendRequest(
        _ request: OpenAIRequest,
        logger: ((String) -> Void)? = nil
    ) async throws -> [String] {
        logger?("MLX Swift backend selected but runtime is not linked")
        throw MLXSwiftClientError.runtimeNotLinked
    }

    public static func sendTextTransformRequest(
        _ prompt: String,
        modelName: String = defaultModelName,
        logger: ((String) -> Void)? = nil
    ) async throws -> String {
        logger?("MLX Swift backend selected but runtime is not linked")
        throw MLXSwiftClientError.runtimeNotLinked
    }
}
