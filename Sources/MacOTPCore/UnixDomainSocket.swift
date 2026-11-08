import Darwin
import Foundation

public enum IPCSocketError: LocalizedError, Sendable {
    case socketPathTooLong(String)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case daemonUnavailable(String)
    case unauthorizedPeer(uid_t)
    case ioFailed(String)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let p):
            return "Путь сокета превышает лимит macOS UNIX_PATH_MAX: \(p)"
        case .socketCreationFailed(let code):
            return "Не удалось создать сокет IPC (errno \(code))."
        case .bindFailed(let code):
            return "Не удалось привязать сокет IPC (errno \(code))."
        case .listenFailed(let code):
            return "Не удалось запустить прослушивание IPC (errno \(code))."
        case .daemonUnavailable(let detail):
            return "Основное приложение MacOTP недоступно (\(detail)). Запустите MacOTP.app."
        case .unauthorizedPeer(let uid):
            return "Отклонён IPC-запрос от стороннего UID \(uid)."
        case .ioFailed(let detail):
            return "Ошибка обмена данными по IPC: \(detail)"
        case .invalidPayload:
            return "Некорректный формат ответа IPC."
        }
    }
}

public typealias IPCRequestHandler = @Sendable (IPCRequest) async -> IPCResponse

public final class UnixDomainSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: IPCRequestHandler
    private var serverFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private let stateLock = NSLock()
    private var running = false

    public init(socketPath: String, handler: @escaping IPCRequestHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public static var defaultSocketPath: String {
        VaultStore.defaultDirectory.appendingPathComponent("ipc.sock").path
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }

        let parentURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try VaultStore.ensureSecureDirectory(parentURL)

        // Remove stale socket file if present
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCSocketError.socketCreationFailed(errno)
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = try UnixSocketHelpers.makeSockAddrUn(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw IPCSocketError.bindFailed(err)
        }

        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw IPCSocketError.listenFailed(err)
        }

        self.serverFD = fd
        self.running = true

        let queue = DispatchQueue(label: "com.macotp.ipc.accept", qos: .userInitiated)
        self.acceptQueue = queue
        let requestHandler = self.handler

        queue.async { [weak self] in
            while true {
                guard let self else { break }
                self.stateLock.lock()
                let stillRunning = self.running
                let listenFD = self.serverFD
                self.stateLock.unlock()

                if !stillRunning || listenFD < 0 { break }

                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(listenFD, sockPtr, &clientLen)
                    }
                }

                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }

                Task.detached(priority: .userInitiated) {
                    await Self.handleClientConnection(clientFD: clientFD, handler: requestHandler)
                }
            }
        }
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = running
        let fd = serverFD
        running = false
        serverFD = -1
        stateLock.unlock()

        if wasRunning && fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(socketPath)
        }
    }

    deinit {
        stop()
    }

    private static func handleClientConnection(
        clientFD: Int32,
        handler: @escaping IPCRequestHandler
    ) async {
        defer { close(clientFD) }

        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        UnixSocketHelpers.setSocketTimeout(fd: clientFD, seconds: 15)

        // Enforce kernel-level UID isolation
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        if getpeereid(clientFD, &peerUID, &peerGID) != 0 || peerUID != getuid() {
            return
        }

        do {
            let lineData = try UnixSocketHelpers.readLine(fd: clientFD, maxBytes: 65_536)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(IPCRequest.self, from: lineData)

            let response = await handler(request)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var out = try encoder.encode(response)
            out.append(0x0A)
            try UnixSocketHelpers.writeAll(fd: clientFD, data: out)
        } catch {
            // Connection dropped or malformed frame; close quietly
        }
    }
}

public enum UnixDomainSocketClient {
    public static func send(
        _ request: IPCRequest,
        socketPath: String = UnixDomainSocketServer.defaultSocketPath,
        timeoutSeconds: Int = 90
    ) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCSocketError.socketCreationFailed(errno)
        }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        UnixSocketHelpers.setSocketTimeout(fd: fd, seconds: timeoutSeconds)

        var addr = try UnixSocketHelpers.makeSockAddrUn(path: socketPath)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCSocketError.daemonUnavailable("errno \(errno)")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try UnixSocketHelpers.writeAll(fd: fd, data: payload)

        let responseLine = try UnixSocketHelpers.readLine(fd: fd, maxBytes: 262_144)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(IPCResponse.self, from: responseLine) else {
            throw IPCSocketError.invalidPayload
        }
        return response
    }

    public static func isDaemonAlive(socketPath: String = UnixDomainSocketServer.defaultSocketPath) -> Bool {
        guard let resp = try? send(IPCRequest(command: .ping), socketPath: socketPath, timeoutSeconds: 2) else {
            return false
        }
        return resp.ok
    }
}

enum UnixSocketHelpers {
    static func makeSockAddrUn(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8CString)
        let maxCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxCapacity else {
            throw IPCSocketError.socketPathTooLong(path)
        }

        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (idx, byte) in pathBytes.enumerated() {
                rawBuf[idx] = UInt8(bitPattern: byte)
            }
        }
        return addr
    }

    static func setSocketTimeout(fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw IPCSocketError.ioFailed("write errno \(errno)")
                }
                if written == 0 {
                    throw IPCSocketError.ioFailed("write EOF")
                }
                offset += written
            }
        }
    }

    static func readLine(fd: Int32, maxBytes: Int) throws -> Data {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)

        while accumulated.count < maxBytes {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw IPCSocketError.ioFailed("read errno \(errno)")
            }
            if n == 0 {
                break
            }
            if let newlineIdx = chunk[0..<n].firstIndex(of: 0x0A) {
                accumulated.append(contentsOf: chunk[0..<newlineIdx])
                return accumulated
            }
            accumulated.append(contentsOf: chunk[0..<n])
        }

        guard !accumulated.isEmpty else {
            throw IPCSocketError.ioFailed("empty frame")
        }
        return accumulated
    }
}
