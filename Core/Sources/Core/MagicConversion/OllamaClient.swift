import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OllamaError: LocalizedError, @unchecked Sendable {
    case invalidURL
    case noServerResponse
    case invalidResponseStatus(code: Int, body: String)
    case parseError(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ollama endpoint is invalid. Please check preferences."
        case .noServerResponse:
            return "Ollama is not responding. Start Ollama and make sure the selected model is installed."
        case .invalidResponseStatus(let code, let body):
            return "Ollama request failed with HTTP \(code): \(body)"
        case .parseError(let message):
            return "Could not parse Ollama response: \(message)"
        case .emptyResponse:
            return "Ollama returned an empty response."
        }
    }
}

public enum OllamaClient {
    public static let defaultEndpoint = "http://localhost:11434/api/chat"
    public static let defaultModelName = "gemma4:e2b"

    public static func sendRequest(
        _ request: OpenAIRequest,
        endpoint: String,
        logger: ((String) -> Void)? = nil
    ) async throws -> [String] {
        let prompt = """
        \(Prompt.getPromptText(for: request.target))

        Input: `\(request.prompt)<\(request.target)>`

        Return only JSON in this exact shape:
        {"predictions":["候補1","候補2","候補3"]}
        """

        let content = try await sendChat(
            prompt: prompt,
            modelName: request.modelName.isEmpty ? defaultModelName : request.modelName,
            endpoint: endpoint,
            logger: logger
        )
        return try parsePredictions(from: content)
    }

    public static func sendTextTransformRequest(
        prompt: String,
        modelName: String,
        endpoint: String,
        logger: ((String) -> Void)? = nil
    ) async throws -> String {
        let content = try await sendChat(
            prompt: """
            \(prompt)

            Return only JSON in this exact shape:
            {"result":"変換後の文章"}
            """,
            modelName: modelName.isEmpty ? defaultModelName : modelName,
            endpoint: endpoint,
            logger: logger
        )
        return try parseTextTransformResult(from: content)
    }

    private static func sendChat(
        prompt: String,
        modelName: String,
        endpoint: String,
        logger: ((String) -> Void)? = nil
    ) async throws -> String {
        let endpoint = endpoint.isEmpty ? defaultEndpoint : endpoint
        guard let url = URL(string: endpoint) else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "stream": false,
            "format": "json",
            "messages": [
                [
                    "role": "system",
                    "content": "You are a Japanese input method assistant. Prefer concise, natural Japanese candidates. Return strict JSON only."
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ] as [String: Any])

        logger?("Ollama request started: model=\(modelName), endpoint=\(endpoint)")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.noServerResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(bytes: data, encoding: .utf8) ?? "Body is not encoded in UTF-8"
            throw OllamaError.invalidResponseStatus(code: httpResponse.statusCode, body: body)
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw OllamaError.parseError("Top-level response was not a JSON object")
        }

        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String {
            logger?("Ollama response received")
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let response = json["response"] as? String {
            logger?("Ollama legacy response received")
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw OllamaError.parseError("Missing message.content")
    }

    private static func parsePredictions(from content: String) throws -> [String] {
        if let data = extractJSONObjectString(from: content).data(using: .utf8),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let predictions = object["predictions"] as? [String] {
            return normalizedOptions(predictions)
        }

        if let data = extractJSONArrayString(from: content).data(using: .utf8),
           let predictions = try JSONSerialization.jsonObject(with: data) as? [String] {
            return normalizedOptions(predictions)
        }

        let fallback = content
            .split(whereSeparator: \.isNewline)
            .map { line in
                line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789.、 "))
            }
        let options = normalizedOptions(fallback)
        guard !options.isEmpty else {
            throw OllamaError.emptyResponse
        }
        return options
    }

    private static func parseTextTransformResult(from content: String) throws -> String {
        if let data = extractJSONObjectString(from: content).data(using: .utf8),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = object["result"] as? String {
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaError.emptyResponse
        }
        return trimmed
    }

    private static func normalizedOptions(_ options: [String]) -> [String] {
        var seen = Set<String>()
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                return nil
            }
            seen.insert(trimmed)
            return trimmed
        }
    }

    private static func extractJSONObjectString(from content: String) -> String {
        extractDelimitedString(from: content, start: "{", end: "}") ?? content
    }

    private static func extractJSONArrayString(from content: String) -> String {
        extractDelimitedString(from: content, start: "[", end: "]") ?? content
    }

    private static func extractDelimitedString(from content: String, start: Character, end: Character) -> String? {
        guard let startIndex = content.firstIndex(of: start),
              let endIndex = content.lastIndex(of: end),
              startIndex <= endIndex else {
            return nil
        }
        return String(content[startIndex...endIndex])
    }
}
