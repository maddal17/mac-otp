import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum VaultCryptoError: LocalizedError, Equatable, Sendable {
    case encryptionFailed
    case decryptionFailed
    case keyDerivationFailed
    case invalidPasswordOrCorruptedData

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Ошибка шифрования данных хранилища."
        case .decryptionFailed:
            return "Не удалось расшифровать секрет (ключ повреждён или данные изменены)."
        case .keyDerivationFailed:
            return "Ошибка формирования криптографического ключа."
        case .invalidPasswordOrCorruptedData:
            return "Неверный пароль/PIN или данные повреждены."
        }
    }
}

public enum VaultCrypto {
    public static let pbkdf2Iterations: UInt32 = 210_000

    public static func generateRandomBytes(count: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw VaultCryptoError.keyDerivationFailed
        }
        return Data(bytes)
    }

    public static func sealSecret(
        _ secret: Data,
        masterKeyData: Data,
        accountId: UUID
    ) throws -> Data {
        let key = SymmetricKey(data: masterKeyData)
        let aad = Data(accountId.uuidString.utf8)
        let sealed = try AES.GCM.seal(secret, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw VaultCryptoError.encryptionFailed
        }
        return combined
    }

    public static func openSecret(
        _ combinedCiphertext: Data,
        masterKeyData: Data,
        accountId: UUID
    ) throws -> Data {
        let key = SymmetricKey(data: masterKeyData)
        let aad = Data(accountId.uuidString.utf8)
        do {
            let box = try AES.GCM.SealedBox(combined: combinedCiphertext)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultCryptoError.decryptionFailed
        }
    }

    public static func deriveKeyPBKDF2(
        secretString: String,
        salt: Data,
        pepper: Data? = nil,
        iterations: UInt32 = pbkdf2Iterations
    ) throws -> Data {
        let inputMaterial: Data
        if let pepper, !pepper.isEmpty {
            let mac = HMAC<SHA256>.authenticationCode(
                for: Data(secretString.utf8),
                using: SymmetricKey(data: pepper)
            )
            inputMaterial = Data(mac).base64EncodedData()
        } else {
            inputMaterial = Data(secretString.utf8)
        }

        var derived = [UInt8](repeating: 0, count: 32)
        let result = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                inputMaterial.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        inputMaterial.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw VaultCryptoError.keyDerivationFailed
        }
        return Data(derived)
    }

    public static func sealWithDerivedKey(
        plaintext: Data,
        derivedKey: Data,
        aad: Data = Data()
    ) throws -> Data {
        let key = SymmetricKey(data: derivedKey)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else {
            throw VaultCryptoError.encryptionFailed
        }
        return combined
    }

    public static func openWithDerivedKey(
        combinedCiphertext: Data,
        derivedKey: Data,
        aad: Data = Data()
    ) throws -> Data {
        let key = SymmetricKey(data: derivedKey)
        do {
            let box = try AES.GCM.SealedBox(combined: combinedCiphertext)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultCryptoError.invalidPasswordOrCorruptedData
        }
    }
}
