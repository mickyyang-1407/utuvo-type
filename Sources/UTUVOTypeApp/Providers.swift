import Foundation
import UTUVOTypeCore

enum ProviderError: Error, CustomStringConvertible, Sendable {
    case missingCredential
    case invalidEndpoint
    case httpStatus(Int)
    case websocket(String)
    case malformedResponse
    case unavailable(String)
    /// Carbon RegisterEventHotKey 回 eExistingHotKeyErr(-9878)：此快捷鍵已被另一個 App 搶先註冊，
    /// 由 catch 路徑判斷後轉給 conflict card，不是真的錯誤，description 給 UI 直接顯示。
    case hotkeyTaken(String)

    var description: String {
        switch self {
        case .missingCredential: return "百鍊 API key 尚未設定"
        case .invalidEndpoint: return "provider endpoint 不合法"
        case .httpStatus(let code): return "provider HTTP status \(code)"
        case .websocket(let message): return "百鍊 ASR WebSocket 失敗：\(message)"
        case .malformedResponse: return "provider 回應格式無法解析"
        case .unavailable(let message): return "本機 provider 不可用：\(message)"
        case .hotkeyTaken(let shortcut):
            return "快捷鍵 \(shortcut) 已被其他 App 佔用（Shortcut \(shortcut) is already taken by another app）"
        }
    }
}

final class BailianFormatterClient: FormatterClient, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession

    init(endpointString: String) throws {
        guard let endpoint = URL(string: endpointString), endpoint.scheme == "https" else {
            throw ProviderError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.session = URLSession(configuration: .ephemeral)
    }

    func format(prompt: String, model: String) async throws -> String {
        guard let apiKey = SecretStore.bailianAPIKey() else {
            throw ProviderError.missingCredential
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
            "temperature": 0.0,
            "max_tokens": 1_024,
            // Qwen3-compatible DashScope endpoints accept this field for
            // hybrid models; reasoning_content is intentionally ignored.
            "enable_thinking": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // Never include the response body: provider error bodies can
            // contain request metadata and must not enter the app status log.
            throw ProviderError.httpStatus(http.statusCode)
        }

        var output = ""
        for try await line in bytes.lines {
            let raw = String(line)
            guard raw.hasPrefix("data:") else { continue }
            let payload = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }
            // Only content is eligible for paste. reasoning_content is not
            // read, concatenated, logged, or shown to the user.
            if let content = delta["content"] as? String {
                output.append(content)
            }
        }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ProviderError.malformedResponse }
        return cleaned
    }
}

final class OllamaFormatterClient: FormatterClient, LocalDeepFormatter, @unchecked Sendable {
    private let endpoint: URL
    private let model: String
    private let session: URLSession

    init(model: String, endpointString: String = "http://127.0.0.1:11434/api/chat") throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = URL(string: endpointString), endpoint.scheme == "http" || endpoint.scheme == "https" else {
            throw ProviderError.invalidEndpoint
        }
        self.model = model
        self.endpoint = endpoint
        self.session = URLSession(configuration: .ephemeral)
    }

    func format(prompt: String, model: String) async throws -> String {
        try await formatText(prompt)
    }

    func format(_ text: String) async throws -> String {
        try await formatText(text)
    }

    private func formatText(_ text: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": text]],
            "stream": false,
            "think": false,
            "options": ["temperature": 0.0]
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.httpStatus(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError.malformedResponse
        }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ProviderError.malformedResponse }
        return result
    }
}

struct LocalASRProcessClient: Sendable {
    let command: String
    let argumentsTemplate: String
    var outputScript: String = "traditional"
    var asrLanguage: String = "Chinese"

    func transcribe(audioURL: URL) async throws -> String {
        let command = command
        let argumentsTemplate = argumentsTemplate
        let outputScript = outputScript
        let asrLanguage = asrLanguage
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            // 引擎家目錄（venv＋模型）跟著 app 走：DMG 版在 Application Support，repo 版在 repo root。
            var environment = RuntimeBootstrap.engineEnvironment(root: RuntimeBootstrap.locateRepoRoot())
            environment["UTUVO_TYPE_OUTPUT_SCRIPT"] = outputScript
            environment["UTUVO_TYPE_ASR_LANGUAGE"] = asrLanguage
            process.environment = environment
            let arguments = argumentsTemplate
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0).replacingOccurrences(of: "{audio}", with: audioURL.path) }
            if command.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = arguments
            } else {
                // Allow a command installed on PATH without shell evaluation.
                // Arguments are still passed as argv; no shell interpolation.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command] + arguments
            }
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                throw ProviderError.unavailable(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProviderError.unavailable("ASR process exit \(process.terminationStatus)")
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let json = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
               let text = object["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !raw.isEmpty else { throw ProviderError.malformedResponse }
            return raw
        }.value
    }
}

struct LocalFormatterProcessClient: FormatterClient, @unchecked Sendable {
    let command: String
    var outputScript: String = "traditional"

    func format(prompt: String, model: String) async throws -> String {
        let command = command
        let outputScript = outputScript
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            var environment = RuntimeBootstrap.engineEnvironment(root: RuntimeBootstrap.locateRepoRoot())
            environment["UTUVO_TYPE_OUTPUT_SCRIPT"] = outputScript
            process.environment = environment
            if command.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = []
            } else {
                // Allow a command installed on PATH without shell evaluation.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command]
            }

            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                throw ProviderError.unavailable(error.localizedDescription)
            }

            guard let data = prompt.data(using: .utf8) else {
                process.terminate()
                throw ProviderError.unavailable("formatter prompt 不是有效 UTF-8")
            }
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.closeFile()

            process.waitUntilExit()
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw ProviderError.unavailable("editor process exit \(process.terminationStatus)")
            }
            let raw = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { throw ProviderError.malformedResponse }
            return raw
        }.value
    }
}

/// Native URLSession WebSocket implementation for the official DashScope
/// duplex event flow: run-task → task-started → binary PCM → finish-task →
/// result-generated/task-finished. It emits sentence partials as they arrive.
final class BailianASRTranscriber: StreamingASRClient, @unchecked Sendable {
    private let endpoint: URL
    private let workspaceID: String

    init(endpointString: String, workspaceID: String = "") throws {
        guard let endpoint = URL(string: endpointString), endpoint.scheme == "wss" else {
            throw ProviderError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.workspaceID = workspaceID
    }

    func transcribe(
        audio: AsyncThrowingStream<Data, Error>,
        context: ASRContext
    ) -> AsyncThrowingStream<ASRPartial, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(audio: audio, context: context, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        audio: AsyncThrowingStream<Data, Error>,
        context: ASRContext,
        continuation: AsyncThrowingStream<ASRPartial, Error>.Continuation
    ) async throws {
        guard let apiKey = SecretStore.bailianAPIKey() else {
            throw ProviderError.missingCredential
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !workspaceID.isEmpty {
            request.setValue(workspaceID, forHTTPHeaderField: "X-DashScope-WorkSpace")
        }

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let taskID = UUID().uuidString
        try await socket.send(.string(try runTaskJSON(taskID: taskID, context: context)))

        while true {
            switch try await decodeServerEvent(from: socket) {
            case .started:
                break
            case .failed(let message):
                throw ProviderError.websocket(message)
            case .partial, .finished:
                continue
            }
            break
        }

        let sender = Task { () throws -> Void in
            for try await chunk in audio {
                try await socket.send(.data(chunk))
            }
            try await socket.send(.string(try finishTaskJSON(taskID: taskID)))
        }
        defer { sender.cancel() }

        while true {
            switch try await decodeServerEvent(from: socket) {
            case .started:
                continue
            case .partial(let value):
                continuation.yield(value)
            case .finished:
                try await sender.value
                return
            case .failed(let message):
                throw ProviderError.websocket(message)
            }
        }
    }

    private enum ServerEvent {
        case started
        case partial(ASRPartial)
        case finished
        case failed(String)
    }

    private func decodeServerEvent(from socket: URLSessionWebSocketTask) async throws -> ServerEvent {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await socket.receive()
        } catch {
            throw ProviderError.websocket(error.localizedDescription)
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw ProviderError.websocket("unknown WebSocket message")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String else {
            throw ProviderError.malformedResponse
        }
        switch event {
        case "task-started":
            return .started
        case "task-finished":
            return .finished
        case "task-failed":
            return .failed(header["error_message"] as? String ?? "unknown provider error")
        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else {
                throw ProviderError.malformedResponse
            }
            if sentence["heartbeat"] as? Bool == true { return .started }
            let text = sentence["text"] as? String ?? ""
            let isFinal = sentence["sentence_end"] as? Bool ?? false
            return .partial(ASRPartial(text: text, isFinal: isFinal))
        default:
            return .started
        }
    }

    private func runTaskJSON(taskID: String, context: ASRContext) throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            "language_hints": ["zh", "en"],
            "semantic_punctuation_enabled": false,
            "max_sentence_silence": 900,
            "heartbeat": true
        ]
        let hotwords = Array(context.hotwords.prefix(50))
        if !hotwords.isEmpty {
            parameters["vocabulary"] = hotwords.reduce(into: [String: Int]()) { result, word in
                result[word] = 5
            }
        }

        var input: [String: Any] = [:]
        let boundedContext = String(context.limitedContext.prefix(400))
        if !boundedContext.isEmpty || !hotwords.isEmpty {
            let text = [boundedContext, hotwords.joined(separator: "、")]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            input["context"] = [[
                "role": "user",
                "content": [["type": "input_text", "text": String(text.prefix(400))]]
            ]]
        }

        let object: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": "qwen-audio-3.0-asr-flash-streaming",
                "parameters": parameters,
                "input": input
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else { throw ProviderError.malformedResponse }
        return string
    }

    private func finishTaskJSON(taskID: String) throws -> String {
        let object: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else { throw ProviderError.malformedResponse }
        return string
    }
}
