import Foundation
import MacOTPCore
import AppKit
import CoreImage
import CryptoKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String, file: String = #fileID, line: Int = #line) {
        self.description = "\(file):\(line) — \(message)"
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion failed", file: String = #fileID, line: Int = #line) throws {
    if !condition() {
        throw TestFailure(message, file: file, line: line)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if actual != expected {
        let suffix = message.isEmpty ? "" : " (\(message))"
        throw TestFailure("Expected \(expected), got \(actual)\(suffix)", file: file, line: line)
    }
}

@main
struct VerificationSuite {
    static func main() async {
        var passed = 0
        var failed = 0

        func run(_ name: String, _ block: () async throws -> Void) async {
            do {
                try await block()
                print("  [PASS] \(name)")
                passed += 1
            } catch {
                print("  [FAIL] \(name): \(error)")
                failed += 1
            }
        }

        print("=== MacOTP Automated Verification Suite ===")

        await run("1. Base32 normalization & round-trip") {
            let secret = Data("12345678901234567890".utf8)
            let encoded = Base32.encode(secret)
            try expectEqual(encoded, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")

            let messy = "gezd gnbv-gy3t qojq gezd gnbv gy3t qojq===="
            let decoded = try Base32.decode(messy)
            try expectEqual(decoded, secret)
        }

        await run("2. RFC 6238 Official TOTP Vectors (SHA1 / SHA256 / SHA512)") {
            let sha1Secret = Data("12345678901234567890".utf8)
            let sha256Secret = Data("12345678901234567890123456789012".utf8)
            let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

            let t59 = Date(timeIntervalSince1970: 59)
            try expectEqual(try TOTPEngine.generate(secret: sha1Secret, digits: 8, period: 30, algorithm: .sha1, at: t59).code, "94287082")
            try expectEqual(try TOTPEngine.generate(secret: sha256Secret, digits: 8, period: 30, algorithm: .sha256, at: t59).code, "46119246")
            try expectEqual(try TOTPEngine.generate(secret: sha512Secret, digits: 8, period: 30, algorithm: .sha512, at: t59).code, "90693936")

            let t1111111109 = Date(timeIntervalSince1970: 1_111_111_109)
            try expectEqual(try TOTPEngine.generate(secret: sha1Secret, digits: 8, period: 30, algorithm: .sha1, at: t1111111109).code, "07081804")
            try expectEqual(try TOTPEngine.generate(secret: sha256Secret, digits: 8, period: 30, algorithm: .sha256, at: t1111111109).code, "68084774")
            try expectEqual(try TOTPEngine.generate(secret: sha512Secret, digits: 8, period: 30, algorithm: .sha512, at: t1111111109).code, "25091201")
        }

        await run("3. otpauth:// & Google Authenticator migration URI parser") {
            let uri = "otpauth://totp/GitHub:architect%40company.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA256&digits=6&period=30"
            let parsed = try OTPAuthParser.parseURI(uri)
            try expectEqual(parsed.count, 1)
            try expectEqual(parsed[0].issuer, "GitHub")
            try expectEqual(parsed[0].accountName, "architect@company.com")
            try expectEqual(parsed[0].algorithm, .sha256)

            var inner = Data()
            inner.append(contentsOf: [0x0A, 0x05] + Array("HELLO".utf8))
            inner.append(contentsOf: [0x12, 0x0A] + Array("AWS:prod01".utf8))
            inner.append(contentsOf: [0x1A, 0x03] + Array("AWS".utf8))
            inner.append(contentsOf: [0x20, 0x01, 0x28, 0x01, 0x30, 0x02])

            var outer = Data([0x0A, UInt8(inner.count)])
            outer.append(inner)
            let b64 = outer.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let migAccounts = try OTPAuthParser.parseURI("otpauth-migration://offline?data=\(b64)")
            try expectEqual(migAccounts.count, 1)
            try expectEqual(migAccounts[0].issuer, "AWS")
            try expectEqual(migAccounts[0].accountName, "prod01")
            try expectEqual(migAccounts[0].secretBase32, Base32.encode(Data("HELLO".utf8)))
        }

        await run("4. Vault AES-256-GCM AAD tamper resistance, Quick PIN lockout, & Encrypted Backup") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("motp-vault-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let store = try VaultStore(baseDirectory: tempDir, keyProvider: InMemoryMasterKeyProvider())
            let added = try await store.addAccount(
                OTPAccountDraft(issuer: "GitHub", accountName: "alice", secretBase32: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
            )
            let generated = try await store.generateCode(accountId: added.id, at: Date(timeIntervalSince1970: 59))
            try expectEqual(generated.code, "287082")

            // Verify AAD rejects swapping ciphertext to a different account UUID
            let master = try VaultCrypto.generateRandomBytes(count: 32)
            let sealed = try VaultCrypto.sealSecret(Data("secret".utf8), masterKeyData: master, accountId: added.id)
            var didRejectTamper = false
            do {
                _ = try VaultCrypto.openSecret(sealed, masterKeyData: master, accountId: UUID())
            } catch {
                didRejectTamper = true
            }
            try expect(didRejectTamper, "AAD swap must fail decryption")

            // Quick PIN setup & lockout after 5 invalid attempts
            try await store.configureQuickPin("4826")
            try expectEqual(await store.isQuickPinConfigured(), true)
            try await store.verifyQuickPin("4826")

            for _ in 1...4 {
                var rejected = false
                do { try await store.verifyQuickPin("0000") } catch { rejected = true }
                try expect(rejected, "Wrong PIN must be rejected")
            }
            var lockedOut = false
            do {
                try await store.verifyQuickPin("0000")
            } catch VaultStoreError.quickPinLockedOut {
                lockedOut = true
            }
            try expect(lockedOut, "5th failed PIN must trigger lockout")
            try expectEqual(await store.isQuickPinConfigured(), false)

            // Encrypted backup round-trip
            let backup = try await store.exportEncryptedBackup(masterPassword: "SuperSecretBackupPassword")
            let tempDir2 = FileManager.default.temporaryDirectory
                .appendingPathComponent("motp-vault2-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir2) }
            let store2 = try VaultStore(baseDirectory: tempDir2, keyProvider: InMemoryMasterKeyProvider())

            var wrongPwdRejected = false
            do {
                _ = try await store2.importEncryptedBackup(data: backup, masterPassword: "WrongPassword")
            } catch {
                wrongPwdRejected = true
            }
            try expect(wrongPwdRejected, "Wrong backup password must fail")

            let imported = try await store2.importEncryptedBackup(data: backup, masterPassword: "SuperSecretBackupPassword")
            try expectEqual(imported.count, 1)
            try expectEqual(imported[0].issuer, "GitHub")
        }

        await run("5. Zero-Keychain EnclaveMasterKeyProvider ECIES Seal & Cross-Instance Persistence") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("motp-sep-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let provider1 = try EnclaveMasterKeyProvider(baseDirectory: tempDir)
            if SecureEnclave.isAvailable {
                try expectEqual(provider1.backend, .hardwareSecureEnclave)
            }

            // Lazy check: no key file created until first secret operation
            let keyFileURL = tempDir.appendingPathComponent("enclave_keys.json")
            try expect(!FileManager.default.fileExists(atPath: keyFileURL.path), "Lazy init must not create key envelope prematurely")

            let master1 = try provider1.loadOrCreateMasterKey()
            try expectEqual(master1.count, 32)
            try expect(FileManager.default.fileExists(atPath: keyFileURL.path), "Key envelope must exist after sealing")

            // Simulate full process restart with a fresh provider instance
            let provider2 = try EnclaveMasterKeyProvider(baseDirectory: tempDir)
            let master2 = try provider2.loadOrCreateMasterKey()
            try expectEqual(master1, master2, "Unwrapped ECIES master key must match across instances")

            let pepper1 = try provider1.rotatePinPepper()
            let pepper2 = try provider2.loadPinPepper()
            try expectEqual(pepper1, pepper2, "Unwrapped ECIES PIN pepper must match across instances")
            try provider2.clearPinPepper()
            try expectEqual(try provider1.loadPinPepper(), nil)
        }

        await run("6. Live Unix Socket IPC + MCP JSON-RPC + Ambiguity Guard + Rate Limiting + Denial Cooldown") {
            let sockDir = URL(fileURLWithPath: "/tmp/motp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: sockDir) }

            let store = try VaultStore(baseDirectory: sockDir, keyProvider: InMemoryMasterKeyProvider())
            _ = try await store.addAccount(
                OTPAccountDraft(issuer: "GitHub", accountName: "work", secretBase32: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
            )
            _ = try await store.addAccount(
                OTPAccountDraft(issuer: "Google", accountName: "one@gmail.com", secretBase32: "JBSWY3DPEHPK3PXP")
            )
            _ = try await store.addAccount(
                OTPAccountDraft(issuer: "Google", accountName: "two@gmail.com", secretBase32: "JBSWY3DPEHPK3PXP")
            )

            var settings = await store.getSettings()
            settings.mcpMaxRequestsPerMinute = 4
            settings.mcpMinRemainingSeconds = 0
            try await store.updateSettings(settings)

            actor GateMock {
                var approve = true
                var count = 0
                func evaluate() -> Bool {
                    count += 1
                    return approve
                }
                func setApprove(_ v: Bool) { approve = v }
                func getCount() -> Int { count }
            }
            let gate = GateMock()

            let authManager = AuthSessionManager(
                vault: store,
                verifier: { _ in await gate.evaluate() }
            )

            let sockPath = sockDir.appendingPathComponent("ipc.sock").path
            let dispatcher = DaemonIPCDispatcher(vault: store, authManager: authManager)
            let server = UnixDomainSocketServer(socketPath: sockPath) { req in
                await dispatcher.dispatch(req)
            }
            try server.start()
            defer { server.stop() }

            let mcp = MCPProtocolEngine(socketPath: sockPath, autoLaunchDaemon: false)

            let initData = mcp.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#.utf8))
            try expect(initData != nil, "initialize must return response")
            try expect(String(data: initData!, encoding: .utf8)!.contains("mac-otp-mcp"))

            try expect(mcp.handleRawMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)

            let listData = mcp.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_2fa_accounts","arguments":{}}}"#.utf8))!
            let listStr = String(data: listData, encoding: .utf8)!
            try expect(listStr.contains("GitHub (work)"), "Should list GitHub")
            try expectEqual(await gate.getCount(), 0, "Listing accounts when allowed must not prompt Touch ID")

            let ambigData = mcp.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_2fa_code","arguments":{"account":"Google"}}}"#.utf8))!
            let ambigStr = String(data: ambigData, encoding: .utf8)!
            try expect(ambigStr.contains("\"isError\":true"), "Ambiguous account must return isError=true")
            try expectEqual(await gate.getCount(), 0, "Ambiguous query must not prompt Touch ID")

            let ghCall = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_2fa_code","arguments":{"account":"GitHub","wait_for_fresh_window":false}}}"#.utf8)
            let ghStr = String(data: mcp.handleRawMessage(ghCall)!, encoding: .utf8)!
            try expect(ghStr.contains("\"isError\":false"), "Valid code request should succeed")
            try expect(ghStr.contains("Code: "), "Response must include generated OTP code")
            try expectEqual(await gate.getCount(), 1)

            await gate.setApprove(false)
            _ = mcp.handleRawMessage(ghCall)
            _ = mcp.handleRawMessage(ghCall)
            _ = mcp.handleRawMessage(ghCall)

            let countBeforeCooldownCall = await gate.getCount()
            let cooldownStr = String(data: mcp.handleRawMessage(ghCall)!, encoding: .utf8)!
            try expect(cooldownStr.contains("блокировка MCP"), "3 denials must activate anti-fatigue cooldown")
            try expectEqual(await gate.getCount(), countBeforeCooldownCall, "Cooldown must short-circuit before Touch ID prompt")
        }

        print("=== Summary: \(passed) passed, \(failed) failed ===")
        if failed > 0 {
            Foundation.exit(1)
        }
    }
}
