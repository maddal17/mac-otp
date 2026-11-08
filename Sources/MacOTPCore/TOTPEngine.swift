import CryptoKit
import Foundation

public enum TOTPError: LocalizedError, Equatable, Sendable {
    case invalidDigits(Int)
    case invalidPeriod(Int)
    case emptySecret

    public var errorDescription: String? {
        switch self {
        case .invalidDigits(let d):
            return "Недопустимая длина кода: \(d) (поддерживается 6–8 цифр)."
        case .invalidPeriod(let p):
            return "Недопустимый интервал TOTP: \(p) сек."
        case .emptySecret:
            return "Пустой секретный ключ TOTP."
        }
    }
}

public enum TOTPEngine {
    public static func generate(
        secret: Data,
        accountId: UUID = UUID(),
        digits: Int = 6,
        period: Int = 30,
        algorithm: OTPAlgorithm = .sha1,
        at date: Date = Date()
    ) throws -> GeneratedOTPCode {
        guard !secret.isEmpty else {
            throw TOTPError.emptySecret
        }
        guard (6...8).contains(digits) else {
            throw TOTPError.invalidDigits(digits)
        }
        guard period > 0 && period <= 300 else {
            throw TOTPError.invalidPeriod(period)
        }

        let unixSeconds = max(0, Int64(floor(date.timeIntervalSince1970)))
        let counter = UInt64(unixSeconds) / UInt64(period)
        let remaining = period - Int(unixSeconds % Int64(period))

        let code = computeHOTP(
            secret: secret,
            counter: counter,
            digits: digits,
            algorithm: algorithm
        )

        return GeneratedOTPCode(
            accountId: accountId,
            code: code,
            period: period,
            remainingSeconds: remaining,
            issuedAt: date
        )
    }

    public static func computeHOTP(
        secret: Data,
        counter: UInt64,
        digits: Int,
        algorithm: OTPAlgorithm
    ) -> String {
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)
        let symmetricKey = SymmetricKey(data: secret)

        let digestBytes: [UInt8]
        switch algorithm {
        case .sha1:
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: symmetricKey)
            digestBytes = Array(mac)
        case .sha256:
            let mac = HMAC<SHA256>.authenticationCode(for: counterData, using: symmetricKey)
            digestBytes = Array(mac)
        case .sha512:
            let mac = HMAC<SHA512>.authenticationCode(for: counterData, using: symmetricKey)
            digestBytes = Array(mac)
        }

        let offset = Int(digestBytes[digestBytes.count - 1] & 0x0F)
        let truncated: UInt32 =
            (UInt32(digestBytes[offset] & 0x7F) << 24) |
            (UInt32(digestBytes[offset + 1]) << 16) |
            (UInt32(digestBytes[offset + 2]) << 8) |
            UInt32(digestBytes[offset + 3])

        let modulus: UInt32
        switch digits {
        case 6: modulus = 1_000_000
        case 7: modulus = 10_000_000
        case 8: modulus = 100_000_000
        default: modulus = 1_000_000
        }

        let value = truncated % modulus
        let raw = String(value)
        if raw.count >= digits {
            return raw
        }
        return String(repeating: "0", count: digits - raw.count) + raw
    }
}
