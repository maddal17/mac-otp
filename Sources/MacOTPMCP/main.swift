import Darwin
import Foundation
import MacOTPCore

let socketPath = ProcessInfo.processInfo.environment["MACOTP_SOCKET_PATH"]
    ?? UnixDomainSocketServer.defaultSocketPath

let engine = MCPProtocolEngine(socketPath: socketPath, autoLaunchDaemon: true)

setbuf(stdout, nil)

func writeStdoutLine(_ data: Data) {
    var payload = data
    payload.append(0x0A)
    payload.withUnsafeBytes { rawBuf in
        guard let base = rawBuf.baseAddress else { return }
        var written = 0
        while written < payload.count {
            let n = Darwin.write(STDOUT_FILENO, base.advanced(by: written), payload.count - written)
            if n <= 0 { break }
            written += n
        }
    }
    fflush(stdout)
}

func readStdinMessages() {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)

    while true {
        let n = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 {
            break
        }
        buffer.append(contentsOf: chunk[0..<n])

        while !buffer.isEmpty {
            // Skip leading CR/LF
            while let first = buffer.first, first == 0x0A || first == 0x0D {
                buffer.removeFirst()
            }
            if buffer.isEmpty { break }

            // Support optional LSP-style Content-Length framing as fallback
            if let prefixStr = String(data: buffer.prefix(min(buffer.count, 32)), encoding: .utf8),
               prefixStr.lowercased().hasPrefix("content-length:") {
                let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
                guard let headerRange = buffer.range(of: separator) else {
                    break // wait for more bytes
                }
                let headerStr = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) ?? ""
                let lenLine = headerStr
                    .split(whereSeparator: \.isNewline)
                    .first { $0.lowercased().hasPrefix("content-length:") }
                let lengthValue = lenLine?
                    .split(separator: ":")
                    .dropFirst()
                    .first?
                    .trimmingCharacters(in: .whitespaces)
                guard let contentLength = lengthValue.flatMap({ Int($0) }), contentLength >= 0 else {
                    buffer.removeAll()
                    break
                }
                let bodyStart = headerRange.upperBound
                guard buffer.count >= bodyStart + contentLength else {
                    break // wait for full body
                }
                let messageData = Data(buffer[bodyStart..<(bodyStart + contentLength)])
                buffer.removeSubrange(0..<(bodyStart + contentLength))

                if let reply = engine.handleRawMessage(messageData) {
                    writeStdoutLine(reply)
                }
                continue
            }

            // Standard MCP newline-delimited JSON-RPC
            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                break // wait for complete line
            }
            var lineData = Data(buffer[..<newlineIndex])
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            buffer.removeSubrange(0...newlineIndex)

            if !lineData.isEmpty, let reply = engine.handleRawMessage(lineData) {
                writeStdoutLine(reply)
            }
        }
    }
}

readStdinMessages()
