import CryptoKit
import Darwin
import Foundation

public enum KeyProtectionBackend: String, Codable, Equatable, Sendable {
    case hardwareSecureEnclave = "Apple Secure Enclave (SEP)"
    case softwareIsolatedEnclave = "Software P-256 Isolated Seal"
    case inMemoryTest = "In-Memory Test Provider"
}

public enum MasterKeyProviderError: LocalizedError, Equatable, Sendable {
    case sealCorrupted
    case hardwareUnwrapFailed

    public var errorDescription: String? {
        switch self {
        case .sealCorrupted:
            return "Повреждён локальный криптоконтейнер ключей (enclave_keys.json)."
        case .hardwareUnwrapFailed:
            return "Не удалось расшифровать мастер-ключ через аппаратный чип Secure Enclave этого Mac."
        }
    }
}

public protocol MasterKeyProviderProtocol: Sendable {
    var backend: KeyProtectionBackend { get }
    func loadOrCreateMasterKey() throws -> Data
    func loadPinPepper() throws -> Data?
    func rotatePinPepper() throws -> Data
    func clearPinPepper() throws
}

private struct ECIESSealedBlob: Codable {
    var ephemeralPublicKeyRaw: Data
    var hkdfSalt: Data
    var combinedCiphertext: Data
}

private struct PersistedEnclaveFile: Codable {
    var version: Int = 2
    var usesHardwareSEP: Bool
    var identityKeyBlob: Data
    var masterKeySeal: ECIESSealedBlob?
    var pinPepperSeal: ECIESSealedBlob?
}

/// Zero-Keychain hardware-backed key sealer using Apple Silicon Secure Enclave (`CryptoKit.SecureEnclave`)
/// with ECIES (`P-256 ECDH` + `HKDF-SHA256` + `AES-256-GCM`). Never calls `SecItem*` Keychain APIs.
public final class EnclaveMasterKeyProvider: MasterKeyProviderProtocol, @unchecked Sendable {
    private static let masterContext = "MACOTP_SEP_MASTER_KEY_V2"
    private static let pepperContext = "MACOTP_SEP_PIN_PEPPER_V2"

    private let fileURL: URL
    private let lock = NSLock()
    public let backend: KeyProtectionBackend

    public init(baseDirectory: URL, forceSoftwareFallback: Bool = false) throws {
        try VaultStore.ensureSecureDirectory(baseDirectory)
        self.fileURL = baseDirectory.appendingPathComponent("enclave_keys.json")

        if let existing = try? Self.readEnvelope(from: fileURL) {
            self.backend = existing.usesHardwareSEP ? .hardwareSecureEnclave : .softwareIsolatedEnclave
        } else {
            let useHardware = !forceSoftwareFallback && SecureEnclave.isAvailable
            self.backend = useHardware ? .hardwareSecureEnclave : .softwareIsolatedEnclave
        }
    }

    public func loadOrCreateMasterKey() throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        var envelope = try loadOrInitializeIdentityEnvelope()
        if let sealed = envelope.masterKeySeal {
            return try openECIES(sealed, envelope: envelope, context: Self.masterContext)
        }

        let freshMasterKey = try VaultCrypto.generateRandomBytes(count: 32)
        envelope.masterKeySeal = try sealECIES(freshMasterKey, envelope: envelope, context: Self.masterContext)
        try Self.writeEnvelope(envelope, to: fileURL)
        return freshMasterKey
    }

    public func loadPinPepper() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let envelope = try Self.readEnvelope(from: fileURL)
        guard let sealed = envelope.pinPepperSeal else { return nil }
        return try openECIES(sealed, envelope: envelope, context: Self.pepperContext)
    }

    public func rotatePinPepper() throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        var envelope = try loadOrInitializeIdentityEnvelope()
        let freshPepper = try VaultCrypto.generateRandomBytes(count: 32)
        envelope.pinPepperSeal = try sealECIES(freshPepper, envelope: envelope, context: Self.pepperContext)
        try Self.writeEnvelope(envelope, to: fileURL)
        return freshPepper
    }

    public func clearPinPepper() throws {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var envelope = try Self.readEnvelope(from: fileURL)
        if envelope.pinPepperSeal != nil {
            envelope.pinPepperSeal = nil
            try Self.writeEnvelope(envelope, to: fileURL)
        }
    }

    // MARK: - Private ECIES Engine

    private func loadOrInitializeIdentityEnvelope() throws -> PersistedEnclaveFile {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try Self.readEnvelope(from: fileURL)
        }

        let useHardware = (backend == .hardwareSecureEnclave) && SecureEnclave.isAvailable
        let keyBlob: Data
        if useHardware {
            let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            keyBlob = seKey.dataRepresentation
        } else {
            let swKey = P256.KeyAgreement.PrivateKey()
            keyBlob = swKey.rawRepresentation
        }

        let created = PersistedEnclaveFile(
            usesHardwareSEP: useHardware,
            identityKeyBlob: keyBlob,
            masterKeySeal: nil,
            pinPepperSeal: nil
        )
        try Self.writeEnvelope(created, to: fileURL)
        return created
    }

    private func sealECIES(
        _ plaintext: Data,
        envelope: PersistedEnclaveFile,
        context: String
    ) throws -> ECIESSealedBlob {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try computeSharedSecret(
            envelope: envelope,
            peerPublicKey: ephemeral.publicKey
        )
        let salt = try VaultCrypto.generateRandomBytes(count: 16)
        let aad = Data(context.utf8)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: aad,
            outputByteCount: 32
        )
        let box = try AES.GCM.seal(plaintext, using: wrappingKey, authenticating: aad)
        guard let combined = box.combined else {
            throw VaultCryptoError.encryptionFailed
        }
        return ECIESSealedBlob(
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation,
            hkdfSalt: salt,
            combinedCiphertext: combined
        )
    }

    private func openECIES(
        _ sealed: ECIESSealedBlob,
        envelope: PersistedEnclaveFile,
        context: String
    ) throws -> Data {
        do {
            let peerPub = try P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeralPublicKeyRaw)
            let sharedSecret = try computeSharedSecret(envelope: envelope, peerPublicKey: peerPub)
            let aad = Data(context.utf8)
            let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: sealed.hkdfSalt,
                sharedInfo: aad,
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: sealed.combinedCiphertext)
            return try AES.GCM.open(box, using: wrappingKey, authenticating: aad)
        } catch {
            throw MasterKeyProviderError.hardwareUnwrapFailed
        }
    }

    private func computeSharedSecret(
        envelope: PersistedEnclaveFile,
        peerPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SharedSecret {
        if envelope.usesHardwareSEP {
            let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: envelope.identityKeyBlob
            )
            return try seKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } else {
            let swKey = try P256.KeyAgreement.PrivateKey(
                rawRepresentation: envelope.identityKeyBlob
            )
            return try swKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        }
    }

    private static func readEnvelope(from url: URL) throws -> PersistedEnclaveFile {
        let raw = try Data(contentsOf: url)
        guard let decoded = try? JSONDecoder().decode(PersistedEnclaveFile.self, from: raw) else {
            throw MasterKeyProviderError.sealCorrupted
        }
        return decoded
    }

    private static func writeEnvelope(_ env: PersistedEnclaveFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(env)
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}

public final class InMemoryMasterKeyProvider: MasterKeyProviderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var masterKey: Data?
    private var pepper: Data?
    public let backend: KeyProtectionBackend = .inMemoryTest

    public init() {}

    public func loadOrCreateMasterKey() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let masterKey { return masterKey }
        let fresh = try VaultCrypto.generateRandomBytes(count: 32)
        self.masterKey = fresh
        return fresh
    }

    public func loadPinPepper() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return pepper
    }

    public func rotatePinPepper() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let fresh = try VaultCrypto.generateRandomBytes(count: 32)
        self.pepper = fresh
        return fresh
    }

    public func clearPinPepper() throws {
        lock.lock()
        defer { lock.unlock() }
        self.pepper = nil
    }
}
