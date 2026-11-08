# MacOTP

[![CI & Security Verification](https://github.com/maddal17/mac-otp/actions/workflows/ci.yml/badge.svg)](https://github.com/maddal17/mac-otp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-7C3AED.svg)](./LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B%20(Swift%206)-000000.svg)](#quick-start)

Native macOS Menu Bar **2FA / TOTP Authenticator** with a zero-trust **Model Context Protocol (MCP)** bridge—enabling fast human copy-paste and hardware-gated AI agent authentication (**Google Antigravity**, **Claude Desktop / Claude Code**, **Cursor**) via **Touch ID**, **macOS System Password**, or a **Clamshell Quick PIN** without reaching for your phone or ever exposing TOTP seeds.

---

## Why This Exists

Modern workflows require 2FA across cloud consoles, VPNs, SSO portals, and internal staging environments—both interactively by humans and autonomously via browser-capable AI coding agents.

Existing solutions force an uncomfortable trade-off:
- **Mobile authenticators** break flow whenever your phone is in another room or charging.
- **Plaintext CLI scripts / `.env` TOTP secrets** hand raw Base32 seeds directly to subprocesses or LLM contexts with zero user presence verification.
- **Headless MCP servers** running in non-interactive background shells cannot reliably invoke macOS GUI biometric sheets on their own.

**MacOTP** separates secret custody from agent transport: a resident macOS Menu Bar daemon holds the encrypted vault in the user's GUI session, while a lightweight `stdio` MCP binary bridges tool calls over a UID-verified Unix Domain Socket—raising native **Touch ID / PIN** confirmation with the exact target service name before releasing a single ephemeral 6-digit code.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Presentation & Transport Channels                                       │
│                                                                         │
│  [macOS Menu Bar Popover]              [AI Agent / IDE]                 │
│   • Live TOTP countdown & search        │  JSON-RPC 2.0 (stdio)         │
│   • Screen / Clipboard QR import        ▼                               │
│   • Audit log & security policy    [mac-otp-mcp] (Stateless CLI Bridge) │
└──────────────────┬──────────────────────┬───────────────────────────────┘
                   │ In-process           │ ~/.macotp/ipc.sock (0600)
                   │                      │ Kernel UID check: getpeereid()
                   ▼                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ MacOTP Core Daemon (User GUI Session)                                   │
│                                                                         │
│  1. IPC & Rate Limiter                                                  │
│     • Ambiguity check BEFORE biometric prompt                           │
│     • Sliding-window quota & 3-denial anti-fatigue cooldown             │
│                                                                         │
│  2. Auth & Session Gatekeeper                                           │
│     • Single-flight prompt serialization (no stacked OS dialogs)        │
│     • Touch ID / Watch / macOS Password (LocalAuthentication)           │
│     • Optional Quick PIN HUD when lid is closed (Clamshell Mode)        │
│     • Instant revocation on system sleep or screen lock                 │
│                                                                         │
│  3. TOTP Engine (RFC 6238: SHA1 / SHA256 / SHA512, 6–8 digits)          │
│     • Smart freshness guard: waits for next window if <= 4s remain      │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Secret Storage Boundary                                                 │
│  • ~/.macotp/vault.json (0600): AES-256-GCM per-account ciphertexts     │
│    bound via AEAD AAD to each account UUID (prevents record swapping)   │
│  • macOS Login Keychain: 256-bit Vault Master Key + PIN HMAC Pepper     │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Key Restraints & Failure Modes Addressed

| Failure Mode / OS Restraint | Architectural Mitigation |
| :--- | :--- |
| **Headless MCP subprocesses cannot spawn Touch ID** | `mac-otp-mcp` holds zero secrets and delegates over `~/.macotp/ipc.sock` to `MacOTP.app` running in the interactive Aqua session. If `MacOTP.app` is not running, the bridge cold-starts it (`open -g`) and awaits socket readiness. |
| **Closed Clamshell Mode disables MacBook Touch ID** | Detects `LAContext` biometric unavailability at runtime; if an optional Quick PIN is configured, displays a centered floating authorization HUD (`PBKDF2-HMAC-SHA256`, 210k rounds + Keychain pepper, auto-wiped after 5 failed attempts) with one-click fallback to macOS System Password. |
| **No paid Apple Developer certificate (`errSecMissingEntitlement -34018`)** | Works out-of-the-box with ad-hoc code signing (`codesign -s -`) by combining an `AES-256-GCM` AAD-bound local vault with a 256-bit master key in the macOS Keychain gated by `LocalAuthentication`. |
| **Prompt fatigue / runaway agent loops** | Ambiguous or missing account queries fail *before* prompting the user; concurrent calls serialize through a single-flight queue; sliding-window rate limits and a 30s cooldown after 3 consecutive denials block prompt spam. |
| **Expiring TOTP codes failing mid-paste** | If $\le 4$ seconds remain in the current 30-second window when an MCP request is approved, the daemon automatically waits for the next window so the agent always receives a fresh code. |
| **Stale unlocked sessions across sleep** | Subscribes to `NSWorkspace` sleep notifications and `com.apple.screenIsLocked` to purge decrypted state immediately on lid close or screen lock. |

---

## Quick Start

**Requirements:** macOS 14.0+ and Xcode Command Line Tools (`xcode-select --install`). Zero external dependencies.

```bash
git clone https://github.com/maddal17/mac-otp.git
cd mac-otp

# Compile Swift 6 targets, bundle & sign dist/MacOTP.app, and run verification tests
make build

# Install to ~/Applications/MacOTP.app and launch
make install
open ~/Applications/MacOTP.app
```

---

## Adding 2FA Accounts

Click the **shield icon** in the macOS Menu Bar $\to$ **Добавить 2FA**:
1. **Scan QR from Screen** — drag-select any QR code visible in your browser (screenshot is processed via Apple `Vision` and immediately deleted).
2. **Import QR from Clipboard / Image File** — supports both standard `otpauth://totp/...` QR codes and **Google Authenticator batch export QR codes** (`otpauth-migration://offline?data=...`).
3. **Manual Base32 Key / URI** — supports `SHA1`, `SHA256`, `SHA512`, `6` or `8` digits, and `30s` / `60s` periods.
4. **Encrypted Backups** — export/import portable `.macotpbackup` archives (`PBKDF2-HMAC-SHA256` + `AES-256-GCM`) for machine migration.

---

## MCP Configuration

You can copy the exact JSON snippet with one click inside `MacOTP` (**Защита и MCP $\to$ Скопировать JSON для mcp_config.json**), or add it manually:

- **Google Antigravity:** `~/.gemini/config/mcp_config.json`
- **Claude Desktop:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "mac-otp": {
      "command": "/Users/<your-username>/Applications/MacOTP.app/Contents/MacOS/mac-otp-mcp",
      "args": []
    }
  }
}
```

### Exposed MCP Tools

| Tool | Parameters | Description |
| :--- | :--- | :--- |
| `list_2fa_accounts` | `query?` (`string`) | Lists configured 2FA account names, issuers, UUIDs, digits, and periods. **Never returns secrets or OTP codes.** |
| `get_2fa_code` | `account` (`string`), `wait_for_fresh_window?` (`bool`) | Resolves the requested service/UUID, triggers Touch ID / PIN confirmation on macOS showing the exact service name, and returns the ephemeral TOTP code + remaining validity seconds. |
| `authenticator_status` | *(none)* | Reports daemon health, configured account count, unlock state, and active MCP authorization policy. |

---

## License

Released under the [MIT License](./LICENSE).
