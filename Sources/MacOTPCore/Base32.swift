import Foundation

public enum Base32Error: LocalizedError, Equatable, Sendable {
    case emptyInput
    case invalidCharacter(Character)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Секретный ключ пуст."
        case .invalidCharacter(let ch):
            return "Недопустимый символ Base32: '\(ch)'."
        }
    }
}

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ raw: String) throws -> Data {
        let cleaned = raw
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }

        guard !cleaned.isEmpty else {
            throw Base32Error.emptyInput
        }

        var buffer: UInt32 = 0
        var bitsLeft = 0
        var output = Data()
        output.reserveCapacity((cleaned.count * 5) / 8)

        for ch in cleaned {
            let value: UInt32
            if let ascii = ch.asciiValue {
                if ascii >= 65 && ascii <= 90 { // A-Z
                    value = UInt32(ascii - 65)
                } else if ascii >= 50 && ascii <= 55 { // 2-7
                    value = UInt32(ascii - 50 + 26)
                } else {
                    throw Base32Error.invalidCharacter(ch)
                }
            } else {
                throw Base32Error.invalidCharacter(ch)
            }

            buffer = (buffer << 5) | value
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                let byte = UInt8((buffer >> bitsLeft) & 0xFF)
                output.append(byte)
            }
        }

        guard !output.isEmpty else {
            throw Base32Error.emptyInput
        }

        return output
    }

    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(alphabet[index])
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(alphabet[index])
        }

        return result
    }
}
