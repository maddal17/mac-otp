import Foundation

public struct MCPJSONValue: Codable, Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([MCPJSONValue])
        case object([String: MCPJSONValue])
    }

    public var storage: Storage

    public init(_ storage: Storage) {
        self.storage = storage
    }

    public static func string(_ s: String) -> MCPJSONValue { .init(.string(s)) }
    public static func int(_ i: Int) -> MCPJSONValue { .init(.int(i)) }
    public static func bool(_ b: Bool) -> MCPJSONValue { .init(.bool(b)) }
    public static func object(_ o: [String: MCPJSONValue]) -> MCPJSONValue { .init(.object(o)) }
    public static func array(_ a: [MCPJSONValue]) -> MCPJSONValue { .init(.array(a)) }

    public var stringValue: String? {
        if case .string(let s) = storage { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = storage { return b }
        return nil
    }

    public var objectValue: [String: MCPJSONValue]? {
        if case .object(let o) = storage { return o }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.storage = .null
        } else if let b = try? container.decode(Bool.self) {
            self.storage = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self.storage = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self.storage = .double(d)
        } else if let s = try? container.decode(String.self) {
            self.storage = .string(s)
        } else if let a = try? container.decode([MCPJSONValue].self) {
            self.storage = .array(a)
        } else if let o = try? container.decode([String: MCPJSONValue].self) {
            self.storage = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable {
    public var jsonrpc: String?
    public var id: MCPJSONValue?
    public var method: String
    public var params: [String: MCPJSONValue]?
}

public struct JSONRPCErrorObject: Codable, Sendable {
    public var code: Int
    public var message: String
}

public struct JSONRPCResponse: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: MCPJSONValue
    public var result: MCPJSONValue?
    public var error: JSONRPCErrorObject?
}

public final class MCPProtocolEngine: Sendable {
    public let socketPath: String
    public let autoLaunchDaemon: Bool

    public init(
        socketPath: String = UnixDomainSocketServer.defaultSocketPath,
        autoLaunchDaemon: Bool = true
    ) {
        self.socketPath = socketPath
        self.autoLaunchDaemon = autoLaunchDaemon
    }

    /// Processes a single JSON-RPC message line; returns `nil` for notifications (no `id`).
    public func handleRawMessage(_ data: Data) -> Data? {
        let decoder = JSONDecoder()
        guard let req = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            let errResp = JSONRPCResponse(
                id: .init(.null),
                result: nil,
                error: JSONRPCErrorObject(code: -32700, message: "Parse error")
            )
            return encodeSingleLine(errResp)
        }

        // Notifications do not carry an `id` and MUST NOT produce a response
        guard let requestId = req.id else {
            return nil
        }

        let response = dispatchRequest(req, id: requestId)
        return encodeSingleLine(response)
    }

    private func dispatchRequest(_ req: JSONRPCRequest, id: MCPJSONValue) -> JSONRPCResponse {
        switch req.method {
        case "initialize":
            let requestedVersion = req.params?["protocolVersion"]?.stringValue ?? "2024-11-05"
            let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let negotiated = supportedVersions.contains(requestedVersion) ? requestedVersion : "2024-11-05"

            let result: MCPJSONValue = .object([
                "protocolVersion": .string(negotiated),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("mac-otp-mcp"),
                    "version": .string("1.0.0")
                ])
            ])
            return JSONRPCResponse(id: id, result: result, error: nil)

        case "ping":
            return JSONRPCResponse(id: id, result: .object([:]), error: nil)

        case "tools/list":
            let tools: [MCPJSONValue] = [
                .object([
                    "name": .string("list_2fa_accounts"),
                    "description": .string(
                        "Lists available 2FA / TOTP accounts configured in MacOTP (returns service issuer, account login, ID, digits, and period; never exposes secret seeds or OTP codes)."
                    ),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string"),
                                "description": .string("Optional case-insensitive filter by service issuer or account login.")
                            ])
                        ])
                    ])
                ]),
                .object([
                    "name": .string("get_2fa_code"),
                    "description": .string(
                        "Generates the current 2FA / TOTP code for a given service or account ID. Triggers macOS Touch ID / PIN verification on the user's Mac according to security policy."
                    ),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "account": .object([
                                "type": .string("string"),
                                "description": .string("Service name (e.g. 'GitHub', 'AWS'), account email/login, or exact account UUID.")
                            ]),
                            "wait_for_fresh_window": .object([
                                "type": .string("boolean"),
                                "description": .string("When true (default), waits briefly if the current code has <= 4s left so a fresh code is returned.")
                            ])
                        ]),
                        "required": .array([.string("account")])
                    ])
                ]),
                .object([
                    "name": .string("authenticator_status"),
                    "description": .string(
                        "Returns operational status of the MacOTP Menu Bar daemon, configured account count, unlock session status, and active MCP security policy."
                    ),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ])
            ]
            return JSONRPCResponse(id: id, result: .object(["tools": .array(tools)]), error: nil)

        case "tools/call":
            guard let toolName = req.params?["name"]?.stringValue else {
                return JSONRPCResponse(
                    id: id,
                    result: nil,
                    error: JSONRPCErrorObject(code: -32602, message: "Missing tool name")
                )
            }
            let args = req.params?["arguments"]?.objectValue ?? [:]
            return handleToolCall(id: id, name: toolName, arguments: args)

        default:
            return JSONRPCResponse(
                id: id,
                result: nil,
                error: JSONRPCErrorObject(code: -32601, message: "Method not found: \(req.method)")
            )
        }
    }

    private func handleToolCall(
        id: MCPJSONValue,
        name: String,
        arguments: [String: MCPJSONValue]
    ) -> JSONRPCResponse {
        do {
            try ensureDaemonReady()

            switch name {
            case "authenticator_status":
                let resp = try UnixDomainSocketClient.send(
                    IPCRequest(command: .status),
                    socketPath: socketPath,
                    timeoutSeconds: 10
                )
                guard resp.ok, let st = resp.status else {
                    return toolResult(id: id, text: resp.errorMessage ?? "Ошибка получения статуса.", isError: true)
                }
                let summary = """
                MacOTP Daemon: RUNNING
                Accounts configured: \(st.accountCount)
                UI Session Unlocked: \(st.unlocked ? "YES (\(st.remainingUnlockSeconds)s remaining)" : "NO (Locked)")
                MCP Policy: \(st.mcpAuthPolicy.rawValue)
                List When Locked: \(st.allowMCPListWhenLocked)
                """
                return toolResult(id: id, text: summary, isError: false)

            case "list_2fa_accounts":
                let query = arguments["query"]?.stringValue
                let resp = try UnixDomainSocketClient.send(
                    IPCRequest(command: .listAccounts, query: query),
                    socketPath: socketPath,
                    timeoutSeconds: 90
                )
                guard resp.ok, let accounts = resp.accounts else {
                    return toolResult(
                        id: id,
                        text: resp.errorMessage ?? "Не удалось получить список аккаунтов.",
                        isError: true
                    )
                }
                if accounts.isEmpty {
                    return toolResult(id: id, text: "В хранилище MacOTP пока нет подходящих аккаунтов.", isError: false)
                }
                let lines = accounts.map { acc in
                    "- \(acc.displayTitle) | id: \(acc.id.uuidString) | digits: \(acc.digits) | period: \(acc.period)s"
                }
                return toolResult(
                    id: id,
                    text: "Найдено аккаунтов (\(accounts.count)):\n" + lines.joined(separator: "\n"),
                    isError: false
                )

            case "get_2fa_code":
                guard let accountQuery = arguments["account"]?.stringValue,
                      !accountQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return toolResult(id: id, text: "Параметр 'account' обязателен.", isError: true)
                }
                let waitFresh = arguments["wait_for_fresh_window"]?.boolValue ?? true
                let resp = try UnixDomainSocketClient.send(
                    IPCRequest(command: .getCode, query: accountQuery, waitForFreshWindow: waitFresh),
                    socketPath: socketPath,
                    timeoutSeconds: 90
                )
                guard resp.ok, let result = resp.codeResult else {
                    return toolResult(
                        id: id,
                        text: resp.errorMessage ?? "Не удалось получить 2FA-код.",
                        isError: true
                    )
                }
                let payloadText = """
                Account: \(result.account.displayTitle)
                Code: \(result.generated.code)
                Valid for: \(result.generated.remainingSeconds)s (period \(result.generated.period)s)
                """
                return toolResult(id: id, text: payloadText, isError: false)

            default:
                return toolResult(id: id, text: "Неизвестный инструмент: \(name)", isError: true)
            }
        } catch {
            return toolResult(id: id, text: error.localizedDescription, isError: true)
        }
    }

    private func toolResult(id: MCPJSONValue, text: String, isError: Bool) -> JSONRPCResponse {
        let body: MCPJSONValue = .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ]),
            "isError": .bool(isError)
        ])
        return JSONRPCResponse(id: id, result: body, error: nil)
    }

    private func ensureDaemonReady() throws {
        if UnixDomainSocketClient.isDaemonAlive(socketPath: socketPath) {
            return
        }
        guard autoLaunchDaemon else {
            throw IPCSocketError.daemonUnavailable("фоновый агент не запущен")
        }

        guard let appBundleURL = Self.locateAppBundle() else {
            throw IPCSocketError.daemonUnavailable("приложение MacOTP.app не найдено и не запущено")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-g", appBundleURL.path]
        try? proc.run()
        proc.waitUntilExit()

        for _ in 0..<35 {
            Thread.sleep(forTimeInterval: 0.15)
            if UnixDomainSocketClient.isDaemonAlive(socketPath: socketPath) {
                return
            }
        }

        throw IPCSocketError.daemonUnavailable("не удалось дождаться запуска MacOTP.app")
    }

    private static func locateAppBundle() -> URL? {
        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["MACOTP_APP_PATH"],
           fm.fileExists(atPath: envPath) {
            return URL(fileURLWithPath: envPath)
        }

        // Check if current executable lives inside .../MacOTP.app/Contents/MacOS/mac-otp-mcp
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let maybeApp = execURL
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // MacOTP.app
        if maybeApp.pathExtension == "app", fm.fileExists(atPath: maybeApp.path) {
            return maybeApp
        }

        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/MacOTP.app"),
            home.appendingPathComponent("Applications/MacOTP.app")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func encodeSingleLine(_ resp: JSONRPCResponse) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try? encoder.encode(resp)
    }
}
