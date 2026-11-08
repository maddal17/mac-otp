import Darwin
import Foundation

public enum AccountLookupResult: Equatable, Sendable {
    case matched(OTPAccountMetadata)
    case ambiguous([OTPAccountMetadata])
    case notFound
}

public enum VaultStoreError: LocalizedError, Equatable, Sendable {
    case accountNotFound(String)
    case ambiguousAccount([String])
    case quickPinNotConfigured
    case quickPinInvalid(remainingAttempts: Int)
    case quickPinLockedOut
    case quickPinTooShort
    case invalidBackupPasswordOrFormat

    public var errorDescription: String? {
        switch self {
        case .accountNotFound(let q):
            return "Аккаунт «\(q)» не найден."
        case .ambiguousAccount(let names):
            return "Найдено несколько подходящих аккаунтов: \(names.joined(separator: ", ")). Уточните запрос или передайте точный ID."
        case .quickPinNotConfigured:
            return "Быстрый PIN не настроен."
        case .quickPinInvalid(let remaining):
            return "Неверный PIN. Осталось попыток: \(remaining)."
        case .quickPinLockedOut:
            return "Превышен лимит попыток PIN. Быстрый PIN сброшен — используйте системную аутентификацию macOS."
        case .quickPinTooShort:
            return "PIN должен содержать от 4 до 12 символов."
        case .invalidBackupPasswordOrFormat:
            return "Неверный мастер-пароль резервной копии или повреждённый файл."
        }
    }
}

private struct PersistedVaultFile: Codable {
    var version: Int = 1
    var settings: SecuritySettings
    var accounts: [OTPAccountMetadata]
    var encryptedSecrets: [String: Data]
}

private struct PersistedPinWrapFile: Codable {
    var version: Int = 1
    var salt: Data
    var iterations: UInt32
    var wrappedMasterKey: Data
    var failedAttempts: Int
}

private struct EncryptedBackupEnvelope: Codable {
    var magic: String = "MACOTP_BACKUP_V1"
    var createdAt: Date
    var salt: Data
    var iterations: UInt32
    var ciphertext: Data
}

public actor VaultStore {
    public static let maxPinAttempts = 5
    private static let masterKeyAccount = "vault-master-key-v1"
    private static let pinPepperAccount = "vault-pin-pepper-v1"

    public let baseDirectory: URL
    private let keychain: KeychainStoreProtocol
    private var vaultData: PersistedVaultFile
    private var auditEntries: [AuditEntry]

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macotp", isDirectory: true)
    }

    public init(
        baseDirectory: URL = VaultStore.defaultDirectory,
        keychain: KeychainStoreProtocol = SystemKeychainStore()
    ) throws {
        self.baseDirectory = baseDirectory
        self.keychain = keychain

        try Self.ensureSecureDirectory(baseDirectory)

        let vaultURL = baseDirectory.appendingPathComponent("vault.json")
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            let raw = try Data(contentsOf: vaultURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.vaultData = try decoder.decode(PersistedVaultFile.self, from: raw)
        } else {
            self.vaultData = PersistedVaultFile(
                settings: SecuritySettings(),
                accounts: [],
                encryptedSecrets: [:]
            )
        }

        let auditURL = baseDirectory.appendingPathComponent("audit.json")
        if FileManager.default.fileExists(atPath: auditURL.path),
           let rawAudit = try? Data(contentsOf: auditURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.auditEntries = (try? decoder.decode([AuditEntry].self, from: rawAudit)) ?? []
        } else {
            self.auditEntries = []
        }

        // Ensure master key exists in Keychain on first startup
        _ = try Self.loadOrCreateMasterKey(keychain: keychain)
    }

    // MARK: - Metadata & Settings (No Secret Decryption)

    public func listAccounts(query: String? = nil) -> [OTPAccountMetadata] {
        let sorted = vaultData.accounts.sorted {
            let lhs = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
            if lhs == .orderedSame {
                return $0.createdAt < $1.createdAt
            }
            return lhs == .orderedAscending
        }

        guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
            return sorted
        }

        return sorted.filter {
            $0.issuer.localizedCaseInsensitiveContains(q) ||
            $0.accountName.localizedCaseInsensitiveContains(q) ||
            $0.id.uuidString.localizedCaseInsensitiveContains(q)
        }
    }

    public func lookupAccount(_ query: String) -> AccountLookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        if let uuid = UUID(uuidString: trimmed),
           let exact = vaultData.accounts.first(where: { $0.id == uuid }) {
            return .matched(exact)
        }

        // Exact case-insensitive match on displayTitle, issuer, or accountName
        let exactTitle = vaultData.accounts.filter {
            $0.displayTitle.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if exactTitle.count == 1 { return .matched(exactTitle[0]) }

        let exactIssuer = vaultData.accounts.filter {
            $0.issuer.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if exactIssuer.count == 1 { return .matched(exactIssuer[0]) }
        if exactIssuer.count > 1 { return .ambiguous(exactIssuer) }

        let exactAccount = vaultData.accounts.filter {
            $0.accountName.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if exactAccount.count == 1 { return .matched(exactAccount[0]) }
        if exactAccount.count > 1 { return .ambiguous(exactAccount) }

        // Substring match
        let substringMatches = vaultData.accounts.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            $0.issuer.localizedCaseInsensitiveContains(trimmed) ||
            $0.accountName.localizedCaseInsensitiveContains(trimmed)
        }

        if substringMatches.isEmpty {
            return .notFound
        } else if substringMatches.count == 1 {
            return .matched(substringMatches[0])
        } else {
            return .ambiguous(substringMatches)
        }
    }

    public func getSettings() -> SecuritySettings {
        vaultData.settings
    }

    public func updateSettings(_ newSettings: SecuritySettings) throws {
        vaultData.settings = newSettings
        try saveVaultToDisk()
    }

    // MARK: - Account CRUD & Code Generation

    @discardableResult
    public func addAccount(_ draft: OTPAccountDraft) throws -> OTPAccountMetadata {
        let secretBytes = try Base32.decode(draft.secretBase32)
        let masterKey = try Self.loadOrCreateMasterKey(keychain: keychain)

        let metadata = OTPAccountMetadata(
            issuer: draft.issuer,
            accountName: draft.accountName,
            digits: draft.digits,
            period: draft.period,
            algorithm: draft.algorithm
        )

        let encrypted = try VaultCrypto.sealSecret(
            secretBytes,
            masterKeyData: masterKey,
            accountId: metadata.id
        )

        vaultData.accounts.append(metadata)
        vaultData.encryptedSecrets[metadata.id.uuidString] = encrypted
        try saveVaultToDisk()
        return metadata
    }

    @discardableResult
    public func importAccounts(_ drafts: [OTPAccountDraft], deduplicate: Bool = true) throws -> [OTPAccountMetadata] {
        var imported: [OTPAccountMetadata] = []
        for draft in drafts {
            if deduplicate {
                let exists = vaultData.accounts.contains {
                    $0.issuer.caseInsensitiveCompare(draft.issuer) == .orderedSame &&
                    $0.accountName.caseInsensitiveCompare(draft.accountName) == .orderedSame
                }
                if exists { continue }
            }
            let added = try addAccount(draft)
            imported.append(added)
        }
        return imported
    }

    public func deleteAccount(id: UUID) throws {
        vaultData.accounts.removeAll { $0.id == id }
        vaultData.encryptedSecrets.removeValue(forKey: id.uuidString)
        try saveVaultToDisk()
    }

    /// Generates a TOTP code for a single account using Keychain master key (caller MUST verify auth first!).
    public func generateCode(accountId: UUID, at date: Date = Date()) throws -> GeneratedOTPCode {
        guard let meta = vaultData.accounts.first(where: { $0.id == accountId }),
              let ciphertext = vaultData.encryptedSecrets[accountId.uuidString] else {
            throw VaultStoreError.accountNotFound(accountId.uuidString)
        }

        let masterKey = try Self.loadOrCreateMasterKey(keychain: keychain)
        let secret = try VaultCrypto.openSecret(ciphertext, masterKeyData: masterKey, accountId: accountId)
        return try TOTPEngine.generate(
            secret: secret,
            accountId: meta.id,
            digits: meta.digits,
            period: meta.period,
            algorithm: meta.algorithm,
            at: date
        )
    }

    /// Generates TOTP codes for all accounts when the UI popover is actively unlocked.
    public func generateAllCodes(at date: Date = Date()) throws -> [UUID: GeneratedOTPCode] {
        guard !vaultData.accounts.isEmpty else { return [:] }
        let masterKey = try Self.loadOrCreateMasterKey(keychain: keychain)
        var result: [UUID: GeneratedOTPCode] = [:]
        for meta in vaultData.accounts {
            guard let ciphertext = vaultData.encryptedSecrets[meta.id.uuidString] else { continue }
            let secret = try VaultCrypto.openSecret(ciphertext, masterKeyData: masterKey, accountId: meta.id)
            let code = try TOTPEngine.generate(
                secret: secret,
                accountId: meta.id,
                digits: meta.digits,
                period: meta.period,
                algorithm: meta.algorithm,
                at: date
            )
            result[meta.id] = code
        }
        return result
    }

    // MARK: - Quick PIN Management (Optional Clamshell Ergonomics)

    public func isQuickPinConfigured() -> Bool {
        FileManager.default.fileExists(atPath: pinWrapURL.path)
    }

    public func configureQuickPin(_ pin: String) throws {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 && trimmed.count <= 12 else {
            throw VaultStoreError.quickPinTooShort
        }

        let masterKey = try Self.loadOrCreateMasterKey(keychain: keychain)
        let pepper = try VaultCrypto.generateRandomBytes(count: 32)
        try keychain.saveData(pepper, account: Self.pinPepperAccount)

        let salt = try VaultCrypto.generateRandomBytes(count: 16)
        let derivedKey = try VaultCrypto.deriveKeyPBKDF2(
            secretString: trimmed,
            salt: salt,
            pepper: pepper,
            iterations: VaultCrypto.pbkdf2Iterations
        )
        let wrapped = try VaultCrypto.sealWithDerivedKey(
            plaintext: masterKey,
            derivedKey: derivedKey,
            aad: Data("MACOTP_PIN_WRAP_V1".utf8)
        )

        let wrapFile = PersistedPinWrapFile(
            salt: salt,
            iterations: VaultCrypto.pbkdf2Iterations,
            wrappedMasterKey: wrapped,
            failedAttempts: 0
        )
        try Self.writeSecureJSON(wrapFile, to: pinWrapURL)
    }

    public func disableQuickPin() throws {
        if FileManager.default.fileExists(atPath: pinWrapURL.path) {
            try FileManager.default.removeItem(at: pinWrapURL)
        }
        try keychain.deleteData(account: Self.pinPepperAccount)
    }

    /// Cryptographically verifies the Quick PIN by unwrapping the Vault Master Key and checking equality.
    public func verifyQuickPin(_ pin: String) throws {
        guard FileManager.default.fileExists(atPath: pinWrapURL.path) else {
            throw VaultStoreError.quickPinNotConfigured
        }

        let raw = try Data(contentsOf: pinWrapURL)
        var wrapFile = try JSONDecoder().decode(PersistedPinWrapFile.self, from: raw)

        if wrapFile.failedAttempts >= Self.maxPinAttempts {
            try? disableQuickPin()
            throw VaultStoreError.quickPinLockedOut
        }

        guard let pepper = try keychain.readData(account: Self.pinPepperAccount) else {
            try? disableQuickPin()
            throw VaultStoreError.quickPinNotConfigured
        }

        let derived = try VaultCrypto.deriveKeyPBKDF2(
            secretString: pin.trimmingCharacters(in: .whitespacesAndNewlines),
            salt: wrapFile.salt,
            pepper: pepper,
            iterations: wrapFile.iterations
        )

        do {
            let unwrapped = try VaultCrypto.openWithDerivedKey(
                combinedCiphertext: wrapFile.wrappedMasterKey,
                derivedKey: derived,
                aad: Data("MACOTP_PIN_WRAP_V1".utf8)
            )
            let expectedMasterKey = try Self.loadOrCreateMasterKey(keychain: keychain)
            guard unwrapped == expectedMasterKey else {
                throw VaultCryptoError.invalidPasswordOrCorruptedData
            }
            if wrapFile.failedAttempts != 0 {
                wrapFile.failedAttempts = 0
                try Self.writeSecureJSON(wrapFile, to: pinWrapURL)
            }
        } catch {
            wrapFile.failedAttempts += 1
            if wrapFile.failedAttempts >= Self.maxPinAttempts {
                try? disableQuickPin()
                throw VaultStoreError.quickPinLockedOut
            } else {
                try? Self.writeSecureJSON(wrapFile, to: pinWrapURL)
                let remaining = Self.maxPinAttempts - wrapFile.failedAttempts
                throw VaultStoreError.quickPinInvalid(remainingAttempts: remaining)
            }
        }
    }

    // MARK: - Encrypted Backup Export / Import

    public func exportEncryptedBackup(masterPassword: String) throws -> Data {
        let trimmed = masterPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else {
            throw VaultStoreError.invalidBackupPasswordOrFormat
        }

        let masterKey = try Self.loadOrCreateMasterKey(keychain: keychain)
        var drafts: [OTPAccountDraft] = []
        for meta in vaultData.accounts {
            guard let ciphertext = vaultData.encryptedSecrets[meta.id.uuidString] else { continue }
            let secretBytes = try VaultCrypto.openSecret(ciphertext, masterKeyData: masterKey, accountId: meta.id)
            drafts.append(
                OTPAccountDraft(
                    issuer: meta.issuer,
                    accountName: meta.accountName,
                    secretBase32: Base32.encode(secretBytes),
                    digits: meta.digits,
                    period: meta.period,
                    algorithm: meta.algorithm
                )
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintextJSON = try encoder.encode(drafts)

        let salt = try VaultCrypto.generateRandomBytes(count: 16)
        let derived = try VaultCrypto.deriveKeyPBKDF2(
            secretString: trimmed,
            salt: salt,
            iterations: VaultCrypto.pbkdf2Iterations
        )
        let sealed = try VaultCrypto.sealWithDerivedKey(
            plaintext: plaintextJSON,
            derivedKey: derived,
            aad: Data("MACOTP_BACKUP_V1".utf8)
        )

        let envelope = EncryptedBackupEnvelope(
            createdAt: Date(),
            salt: salt,
            iterations: VaultCrypto.pbkdf2Iterations,
            ciphertext: sealed
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    @discardableResult
    public func importEncryptedBackup(data: Data, masterPassword: String) throws -> [OTPAccountMetadata] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(EncryptedBackupEnvelope.self, from: data),
              envelope.magic == "MACOTP_BACKUP_V1" else {
            throw VaultStoreError.invalidBackupPasswordOrFormat
        }

        let derived = try VaultCrypto.deriveKeyPBKDF2(
            secretString: masterPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            salt: envelope.salt,
            iterations: envelope.iterations
        )

        let plaintextJSON: Data
        do {
            plaintextJSON = try VaultCrypto.openWithDerivedKey(
                combinedCiphertext: envelope.ciphertext,
                derivedKey: derived,
                aad: Data("MACOTP_BACKUP_V1".utf8)
            )
        } catch {
            throw VaultStoreError.invalidBackupPasswordOrFormat
        }

        guard let drafts = try? decoder.decode([OTPAccountDraft].self, from: plaintextJSON) else {
            throw VaultStoreError.invalidBackupPasswordOrFormat
        }

        return try importAccounts(drafts, deduplicate: true)
    }

    // MARK: - Audit Trail

    public func recordAudit(
        channel: AuditChannel,
        action: String,
        target: String,
        outcome: AuditOutcome,
        detail: String = ""
    ) {
        let entry = AuditEntry(
            channel: channel,
            action: action,
            target: target,
            outcome: outcome,
            detail: detail
        )
        auditEntries.insert(entry, at: 0)
        if auditEntries.count > 100 {
            auditEntries = Array(auditEntries.prefix(100))
        }
        let auditURL = baseDirectory.appendingPathComponent("audit.json")
        try? Self.writeSecureJSON(auditEntries, to: auditURL)
    }

    public func getAuditEntries() -> [AuditEntry] {
        auditEntries
    }

    // MARK: - Private Persistence Helpers

    private var pinWrapURL: URL {
        baseDirectory.appendingPathComponent("pin_wrap.json")
    }

    private func saveVaultToDisk() throws {
        let vaultURL = baseDirectory.appendingPathComponent("vault.json")
        try Self.writeSecureJSON(vaultData, to: vaultURL)
    }

    private static func loadOrCreateMasterKey(keychain: KeychainStoreProtocol) throws -> Data {
        if let existing = try keychain.readData(account: masterKeyAccount), existing.count == 32 {
            return existing
        }
        let generated = try VaultCrypto.generateRandomBytes(count: 32)
        try keychain.saveData(generated, account: masterKeyAccount)
        return generated
    }

    public static func ensureSecureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        chmod(url.path, 0o700)
    }

    private static func writeSecureJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}
