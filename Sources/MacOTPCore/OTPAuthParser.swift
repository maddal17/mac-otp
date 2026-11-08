import Foundation

public enum OTPAuthParseError: LocalizedError, Equatable, Sendable {
    case invalidURI
    case unsupportedType(String)
    case missingSecret
    case invalidMigrationPayload

    public var errorDescription: String? {
        switch self {
        case .invalidURI:
            return "Некорректная ссылка otpauth://."
        case .unsupportedType(let t):
            return "Неподдерживаемый тип OTP: \(t) (поддерживается только TOTP)."
        case .missingSecret:
            return "В ссылке отсутствует параметр secret."
        case .invalidMigrationPayload:
            return "Не удалось декодировать пакет миграции Google Authenticator."
        }
    }
}

public enum OTPAuthParser {
    /// Parses one or more accounts from an `otpauth://` or `otpauth-migration://` URI string.
    public static func parseURI(_ uriString: String) throws -> [OTPAccountDraft] {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw OTPAuthParseError.invalidURI
        }

        switch scheme {
        case "otpauth":
            return [try parseSingleOTPAuth(components: components)]
        case "otpauth-migration":
            return try parseGoogleMigration(components: components)
        default:
            throw OTPAuthParseError.invalidURI
        }
    }

    private static func parseSingleOTPAuth(components: URLComponents) throws -> OTPAccountDraft {
        let host = (components.host ?? "").lowercased()
        guard host == "totp" else {
            throw OTPAuthParseError.unsupportedType(host.isEmpty ? "unknown" : host)
        }

        var rawLabel = components.path
        if rawLabel.hasPrefix("/") {
            rawLabel.removeFirst()
        }
        rawLabel = rawLabel.removingPercentEncoding ?? rawLabel

        var labelIssuer = ""
        var accountName = rawLabel
        if let colonIndex = rawLabel.firstIndex(of: ":") {
            labelIssuer = String(rawLabel[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            accountName = String(rawLabel[rawLabel.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                params[item.name.lowercased()] = value
            }
        }

        guard let rawSecret = params["secret"], !rawSecret.isEmpty else {
            throw OTPAuthParseError.missingSecret
        }
        // Validate Base32 immediately
        _ = try Base32.decode(rawSecret)

        let issuer = (params["issuer"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? labelIssuer

        let algorithm: OTPAlgorithm
        switch (params["algorithm"] ?? "SHA1").uppercased() {
        case "SHA256": algorithm = .sha256
        case "SHA512": algorithm = .sha512
        default: algorithm = .sha1
        }

        let digits = Int(params["digits"] ?? "6") ?? 6
        let period = Int(params["period"] ?? "30") ?? 30

        return OTPAccountDraft(
            issuer: issuer,
            accountName: accountName,
            secretBase32: rawSecret.uppercased().filter { !$0.isWhitespace && $0 != "-" },
            digits: (6...8).contains(digits) ? digits : 6,
            period: (period > 0 && period <= 300) ? period : 30,
            algorithm: algorithm
        )
    }

    // MARK: - Google Authenticator `otpauth-migration://offline?data=...`

    private static func parseGoogleMigration(components: URLComponents) throws -> [OTPAccountDraft] {
        guard let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw OTPAuthParseError.invalidMigrationPayload
        }

        let normalizedBase64 = dataParam
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")
        let paddedBase64: String
        let rem = normalizedBase64.count % 4
        if rem > 0 {
            paddedBase64 = normalizedBase64 + String(repeating: "=", count: 4 - rem)
        } else {
            paddedBase64 = normalizedBase64
        }

        guard let payloadData = Data(base64Encoded: paddedBase64) else {
            throw OTPAuthParseError.invalidMigrationPayload
        }

        var drafts: [OTPAccountDraft] = []
        var reader = ProtobufReader(data: payloadData)

        while !reader.isAtEnd {
            let (fieldNumber, wireType) = try reader.readTag()
            if fieldNumber == 1 && wireType == 2 {
                let entryBytes = try reader.readLengthDelimited()
                if let draft = try parseMigrationEntry(entryBytes) {
                    drafts.append(draft)
                }
            } else {
                try reader.skipField(wireType: wireType)
            }
        }

        guard !drafts.isEmpty else {
            throw OTPAuthParseError.invalidMigrationPayload
        }
        return drafts
    }

    private static func parseMigrationEntry(_ data: Data) throws -> OTPAccountDraft? {
        var reader = ProtobufReader(data: data)
        var secretBytes = Data()
        var name = ""
        var issuer = ""
        var algoRaw: UInt64 = 1
        var digitsRaw: UInt64 = 1
        var otpType: UInt64 = 2 // 2 = TOTP, 1 = HOTP

        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                secretBytes = try reader.readLengthDelimited()
            case (2, 2):
                let strData = try reader.readLengthDelimited()
                name = String(data: strData, encoding: .utf8) ?? ""
            case (3, 2):
                let strData = try reader.readLengthDelimited()
                issuer = String(data: strData, encoding: .utf8) ?? ""
            case (4, 0):
                algoRaw = try reader.readVarint()
            case (5, 0):
                digitsRaw = try reader.readVarint()
            case (6, 0):
                otpType = try reader.readVarint()
            default:
                try reader.skipField(wireType: wire)
            }
        }

        // Skip HOTP entries (otpType == 1)
        if otpType == 1 || secretBytes.isEmpty {
            return nil
        }

        var cleanAccount = name
        if let colonIndex = name.firstIndex(of: ":") {
            let prefix = String(name[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            cleanAccount = String(name[name.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if issuer.isEmpty {
                issuer = prefix
            }
        }

        let algorithm: OTPAlgorithm
        switch algoRaw {
        case 2: algorithm = .sha256
        case 3: algorithm = .sha512
        default: algorithm = .sha1
        }

        let digits: Int
        switch digitsRaw {
        case 2, 8: digits = 8
        case 7: digits = 7
        default: digits = 6
        }

        return OTPAccountDraft(
            issuer: issuer,
            accountName: cleanAccount,
            secretBase32: Base32.encode(secretBytes),
            digits: digits,
            period: 30,
            algorithm: algorithm
        )
    }
}

private struct ProtobufReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readTag() throws -> (Int, Int) {
        let raw = try readVarint()
        let fieldNumber = Int(raw >> 3)
        let wireType = Int(raw & 0x07)
        guard fieldNumber > 0 else {
            throw OTPAuthParseError.invalidMigrationPayload
        }
        return (fieldNumber, wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let b = bytes[offset]
            offset += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw OTPAuthParseError.invalidMigrationPayload
            }
        }
        throw OTPAuthParseError.invalidMigrationPayload
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = Int(try readVarint())
        guard length >= 0, offset + length <= bytes.count else {
            throw OTPAuthParseError.invalidMigrationPayload
        }
        let slice = Data(bytes[offset..<(offset + length)])
        offset += length
        return slice
    }

    mutating func skipField(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard offset + 8 <= bytes.count else { throw OTPAuthParseError.invalidMigrationPayload }
            offset += 8
        case 2:
            _ = try readLengthDelimited()
        case 5:
            guard offset + 4 <= bytes.count else { throw OTPAuthParseError.invalidMigrationPayload }
            offset += 4
        default:
            throw OTPAuthParseError.invalidMigrationPayload
        }
    }
}
