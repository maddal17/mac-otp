import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case en = "en"
    case ru = "ru"
    case uz = "uz"
    case fr = "fr"

    public var displayName: String {
        switch self {
        case .system:
            switch Self.detectSystemLanguage() {
            case .ru: return "Системный (Auto)"
            case .uz: return "Tizim tili (Auto)"
            case .fr: return "Système (Auto)"
            default: return "System (Auto)"
            }
        case .en: return "English"
        case .ru: return "Русский"
        case .uz: return "Oʻzbekcha"
        case .fr: return "Français"
        }
    }

    public var resolved: AppLanguage {
        if self == .system {
            return Self.detectSystemLanguage()
        }
        return self
    }

    public static func detectSystemLanguage() -> AppLanguage {
        for pref in Locale.preferredLanguages {
            let lower = pref.lowercased()
            if lower.hasPrefix("ru") { return .ru }
            if lower.hasPrefix("uz") { return .uz }
            if lower.hasPrefix("fr") { return .fr }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

public struct L10n: Sendable {
    public let lang: AppLanguage

    public init(_ setting: AppLanguage = .system) {
        self.lang = setting.resolved
    }

    private func pick(en: String, ru: String, uz: String, fr: String) -> String {
        switch lang {
        case .ru: return ru
        case .uz: return uz
        case .fr: return fr
        case .en, .system: return en
        }
    }

    // MARK: - Header & Menu

    public var locked: String {
        pick(en: "Locked", ru: "Заблокировано", uz: "Qulflangan", fr: "Verrouillé")
    }

    public var settingsAndSecurityMenu: String {
        pick(en: "Settings & Security...", ru: "Настройки и защита...", uz: "Sozlamalar va himoya...", fr: "Réglages et sécurité...")
    }

    public var copyMCPConfigMenu: String {
        pick(en: "Copy MCP Config", ru: "Скопировать конфиг MCP", uz: "MCP konfiguratsiyasini nusxalash", fr: "Copier la config MCP")
    }

    public var activityLogMenu: String {
        pick(en: "Activity Log...", ru: "Журнал событий...", uz: "Faoliyat jurnali...", fr: "Journal d’activité...")
    }

    public var quitAppMenu: String {
        pick(en: "Quit MacOTP", ru: "Выйти из MacOTP", uz: "MacOTP dan chiqish", fr: "Quitter MacOTP")
    }

    public var settingsTooltip: String {
        pick(en: "Settings & More", ru: "Настройки и дополнительно", uz: "Sozlamalar va qoʻshimcha", fr: "Réglages et plus")
    }

    // MARK: - Main Accounts View

    public var searchPlaceholder: String {
        pick(en: "Search...", ru: "Поиск...", uz: "Qidirish...", fr: "Rechercher...")
    }

    public var addFirstAccount: String {
        pick(en: "Add first account", ru: "Добавить первый аккаунт", uz: "Birinchi hisobni qoʻshish", fr: "Ajouter un premier compte")
    }

    public var addAccountTooltip: String {
        pick(en: "Add new account", ru: "Добавить новый аккаунт", uz: "Yangi hisob qoʻshish", fr: "Ajouter un compte")
    }

    public var copyCodeAction: String {
        pick(en: "Copy Code", ru: "Скопировать код", uz: "Kodni nusxalash", fr: "Copier le code")
    }

    public var unlockAndCopyTooltip: String {
        pick(en: "Unlock and copy code", ru: "Разблокировать и скопировать код", uz: "Qulfni ochish va kodni nusxalash", fr: "Déverrouiller et copier le code")
    }

    public var copyMCPIdAction: String {
        pick(en: "Copy ID for MCP", ru: "Скопировать ID для MCP", uz: "MCP uchun ID nusxalash", fr: "Copier l’ID pour MCP")
    }

    public var deleteAccountAction: String {
        pick(en: "Delete Account...", ru: "Удалить аккаунт...", uz: "Hisobni oʻchirish...", fr: "Supprimer le compte...")
    }

    // MARK: - Bottom Stateful Auth Bar

    public var unlockButton: String {
        pick(en: "Unlock", ru: "Разблокировать", uz: "Qulfni ochish", fr: "Déverrouiller")
    }

    public var lockButton: String {
        pick(en: "Lock", ru: "Заблокировать", uz: "Qulflash", fr: "Verrouiller")
    }

    public var enterPinPlaceholder: String {
        pick(en: "Enter PIN + Return", ru: "Введите PIN + Enter", uz: "PIN kiriting + Enter", fr: "PIN + Entrée")
    }

    public var openPinButton: String {
        pick(en: "Open", ru: "Открыть", uz: "Ochish", fr: "Ouvrir")
    }

    public var useSystemAuthTooltip: String {
        pick(en: "Use macOS Password / Touch ID", ru: "Использовать системный пароль / Touch ID", uz: "macOS paroli / Touch ID ishlatish", fr: "Utiliser le mot de passe macOS / Touch ID")
    }

    public var cancelButton: String {
        pick(en: "Cancel", ru: "Отмена", uz: "Bekor qilish", fr: "Annuler")
    }

    // MARK: - Add Account Sheet

    public var newAccountTitle: String {
        pick(en: "New Account", ru: "Новый аккаунт", uz: "Yangi hisob", fr: "Nouveau compte")
    }

    public var qrOrLinkTab: String {
        pick(en: "QR Code / Link", ru: "QR-код / Ссылка", uz: "QR-kod / Havola", fr: "QR Code / Lien")
    }

    public var manualKeyTab: String {
        pick(en: "Manual Key", ru: "Вручную по ключу", uz: "Kalit orqali", fr: "Clé manuelle")
    }

    public var scanScreenButton: String {
        pick(en: "Screen", ru: "С экрана", uz: "Ekrandan", fr: "Écran")
    }

    public var scanClipboardButton: String {
        pick(en: "Clipboard", ru: "Из буфера", uz: "Buferdan", fr: "Presse-papiers")
    }

    public var scanFileButton: String {
        pick(en: "File...", ru: "Файл...", uz: "Fayl...", fr: "Fichier...")
    }

    public var servicePlaceholder: String {
        pick(en: "Service (GitHub, VPN, AWS)", ru: "Сервис (GitHub, VPN, AWS)", uz: "Xizmat (GitHub, VPN, AWS)", fr: "Service (GitHub, VPN, AWS)")
    }

    public var loginPlaceholder: String {
        pick(en: "Account / Email", ru: "Логин / Email", uz: "Login / Email", fr: "Identifiant / E-mail")
    }

    public var secretKeyPlaceholder: String {
        pick(en: "Base32 Secret Key", ru: "Секретный ключ Base32", uz: "Base32 maxfiy kalit", fr: "Clé secrète Base32")
    }

    public var digitsLabel: String {
        pick(en: "Digits", ru: "Цифр", uz: "Raqamlar", fr: "Chiffres")
    }

    public var periodLabel: String {
        pick(en: "Step", ru: "Шаг", uz: "Davr", fr: "Période")
    }

    public var saveButton: String {
        pick(en: "Save", ru: "Сохранить", uz: "Saqlash", fr: "Enregistrer")
    }

    // MARK: - Settings Sheet

    public var settingsTitle: String {
        pick(en: "Settings & Security", ru: "Настройки и защита", uz: "Sozlamalar va himoya", fr: "Réglages et sécurité")
    }

    public var doneButton: String {
        pick(en: "Done", ru: "Готово", uz: "Tayyor", fr: "Terminé")
    }

    public func hardwareKeysBadge(_ backend: String) -> String {
        pick(
            en: "Keys: \(backend) (Zero-Keychain)",
            ru: "Ключи: \(backend) (Zero-Keychain)",
            uz: "Kalitlar: \(backend) (Zero-Keychain)",
            fr: "Clés : \(backend) (Zero-Keychain)"
        )
    }

    public var languageLabel: String {
        pick(en: "Language:", ru: "Язык:", uz: "Til:", fr: "Langue :")
    }

    public var sessionAndMCPGroup: String {
        pick(en: "Session & MCP", ru: "Сессия и MCP", uz: "Sessiya va MCP", fr: "Session et MCP")
    }

    public var uiSessionLabel: String {
        pick(en: "UI Session:", ru: "Сессия UI:", uz: "UI sessiyasi:", fr: "Session UI :")
    }

    public var ttlOneTime: String {
        pick(en: "One-time (0s)", ru: "Одноразово (0с)", uz: "Bir martalik (0s)", fr: "Unique (0s)")
    }

    public var ttl1Min: String {
        pick(en: "1 min", ru: "1 мин", uz: "1 daq", fr: "1 min")
    }

    public var ttl5Min: String {
        pick(en: "5 min", ru: "5 мин", uz: "5 daq", fr: "5 min")
    }

    public var ttl15Min: String {
        pick(en: "15 min", ru: "15 мин", uz: "15 daq", fr: "15 min")
    }

    public var mcpModeLabel: String {
        pick(en: "MCP Mode:", ru: "Режим MCP:", uz: "MCP rejimi:", fr: "Mode MCP :")
    }

    public var mcpAskEveryTime: String {
        pick(en: "Ask every time", ru: "Спрашивать каждый раз", uz: "Har safar soʻrash", fr: "Demander à chaque fois")
    }

    public var mcpShareSession: String {
        pick(en: "Share UI session", ru: "Общая сессия с UI", uz: "UI sessiyasi bilan umumiy", fr: "Partager la session UI")
    }

    public var lockOnSleepToggle: String {
        pick(en: "Lock on Mac sleep", ru: "Блокировать при сне Mac", uz: "Mac uyquga ketganda qulflash", fr: "Verrouiller à la mise en veille")
    }

    public var clearClipboardToggle: String {
        pick(en: "Clear clipboard after 30s", ru: "Очищать буфер через 30 сек", uz: "Buferni 30 soniyada tozalash", fr: "Vider le presse-papiers après 30s")
    }

    public var quickPinGroup: String {
        pick(en: "Quick PIN (Clamshell mode)", ru: "Быстрый PIN (при закрытой крышке)", uz: "Tezkor PIN (qopqoq yopiqligida)", fr: "PIN rapide (capot fermé)")
    }

    public var changePinPlaceholder: String {
        pick(en: "Change PIN", ru: "Сменить PIN", uz: "PIN oʻzgartirish", fr: "Changer le PIN")
    }

    public var newPinPlaceholder: String {
        pick(en: "New PIN (4–12)", ru: "Новый PIN (4–12)", uz: "Yangi PIN (4–12)", fr: "Nouveau PIN (4–12)")
    }

    public var updateButton: String {
        pick(en: "Update", ru: "Обновить", uz: "Yangilash", fr: "Modifier")
    }

    public var setButton: String {
        pick(en: "Set", ru: "Задать", uz: "Oʻrnatish", fr: "Définir")
    }

    public var resetButton: String {
        pick(en: "Reset", ru: "Сброс", uz: "Tiklash", fr: "Effacer")
    }

    public var backupGroup: String {
        pick(en: "Encrypted Backup (AES-256-GCM)", ru: "Резервная копия (AES-256-GCM)", uz: "Shifrlangan nusxa (AES-256-GCM)", fr: "Sauvegarde chiffrée (AES-256-GCM)")
    }

    public var backupPasswordPlaceholder: String {
        pick(en: "Password (min 6 chars)", ru: "Пароль (мин. 6 симв.)", uz: "Parol (kamida 6 belgi)", fr: "Mot de passe (6 car. min)")
    }

    public var exportButton: String {
        pick(en: "Export", ru: "Экспорт", uz: "Eksport", fr: "Exporter")
    }

    public var importButton: String {
        pick(en: "Import", ru: "Импорт", uz: "Import", fr: "Importer")
    }

    // MARK: - Activity Log Sheet

    public var activityLogTitle: String {
        pick(en: "Activity Log", ru: "Журнал событий", uz: "Faoliyat jurnali", fr: "Journal d’activité")
    }

    public var closeButton: String {
        pick(en: "Close", ru: "Закрыть", uz: "Yopish", fr: "Fermer")
    }

    public var noActivityYet: String {
        pick(en: "No events yet", ru: "Событий пока нет", uz: "Hozircha hodisalar yoʻq", fr: "Aucun événement")
    }

    // MARK: - Floating Quick PIN HUD

    public var mcpConfirmHeader: String {
        pick(en: "Approve MCP 2FA Request", ru: "Подтверждение запроса MCP", uz: "MCP soʻrovini tasdiqlash", fr: "Confirmer la requête MCP")
    }

    public var unlockHeader: String {
        pick(en: "Unlock MacOTP", ru: "Разблокировка MacOTP", uz: "MacOTP qulfini ochish", fr: "Déverrouiller MacOTP")
    }

    public var enterQuickPinHUD: String {
        pick(en: "Enter Quick PIN", ru: "Введите быстрый PIN", uz: "Tezkor PIN kiriting", fr: "Saisissez le PIN rapide")
    }

    public var clamshellHintHUD: String {
        pick(
            en: "Touch ID unavailable (clamshell mode). Enter PIN or use macOS password.",
            ru: "Touch ID недоступен (крышка закрыта). Введите PIN или используйте пароль macOS.",
            uz: "Touch ID mavjud emas (qopqoq yopiq). PIN kiriting yoki macOS parolidan foydalaning.",
            fr: "Touch ID indisponible (capot fermé). Entrez le PIN ou le mot de passe macOS."
        )
    }

    public var macOSPasswordButton: String {
        pick(en: "macOS Password", ru: "Пароль macOS", uz: "macOS paroli", fr: "Mot de passe macOS")
    }

    public var denyButton: String {
        pick(en: "Deny", ru: "Отклонить", uz: "Rad etish", fr: "Refuser")
    }

    public var confirmButton: String {
        pick(en: "Confirm", ru: "Подтвердить", uz: "Tasdiqlash", fr: "Confirmer")
    }

    // MARK: - Toasts & Prompts

    public func codeCopiedToast(_ formatted: String) -> String {
        pick(
            en: "Code \(formatted) copied",
            ru: "Код \(formatted) скопирован",
            uz: "Kod \(formatted) nusxalandi",
            fr: "Code \(formatted) copié"
        )
    }

    public func addedToast(_ title: String) -> String {
        pick(en: "Added: \(title)", ru: "Добавлен: \(title)", uz: "Qoʻshildi: \(title)", fr: "Ajouté : \(title)")
    }

    public func importedToast(_ count: Int) -> String {
        pick(
            en: count == 0 ? "Accounts already exist" : "Imported accounts: \(count)",
            ru: count == 0 ? "Аккаунты уже добавлены" : "Импортировано: \(count)",
            uz: count == 0 ? "Hisoblar allaqachon mavjud" : "Import qilindi: \(count)",
            fr: count == 0 ? "Comptes déjà présents" : "Comptes importés : \(count)"
        )
    }

    public func deletedToast(_ title: String) -> String {
        pick(en: "Deleted: \(title)", ru: "Удалён: \(title)", uz: "Oʻchirildi: \(title)", fr: "Supprimé : \(title)")
    }

    public var settingsSavedToast: String {
        pick(en: "Settings saved", ru: "Настройки сохранены", uz: "Sozlamalar saqlandi", fr: "Réglages enregistrés")
    }

    public var pinSetToast: String {
        pick(en: "Quick PIN enabled", ru: "Быстрый PIN установлен", uz: "Tezkor PIN oʻrnatildi", fr: "PIN rapide activé")
    }

    public var pinDisabledToast: String {
        pick(en: "Quick PIN disabled", ru: "Быстрый PIN отключён", uz: "Tezkor PIN oʻchirildi", fr: "PIN rapide désactivé")
    }

    public var backupSavedToast: String {
        pick(en: "Backup saved", ru: "Резервная копия сохранена", uz: "Zaxira nusxa saqlandi", fr: "Sauvegarde enregistrée")
    }

    public var mcpCopiedToast: String {
        pick(en: "MCP config copied", ru: "Конфиг MCP скопирован", uz: "MCP konfiguratsiyasi nusxalandi", fr: "Config MCP copiée")
    }

    public var qrNoOTPDataError: String {
        pick(
            en: "The scanned QR code does not contain a 2FA URI (otpauth://).",
            ru: "Найденный QR-код не содержит данных 2FA (otpauth://).",
            uz: "QR-kodda 2FA maʼlumotlari topilmadi (otpauth://).",
            fr: "Le QR code scanné ne contient pas de données 2FA (otpauth://)."
        )
    }

    public var unlockVaultPrompt: String {
        pick(
            en: "Unlock 2FA vault",
            ru: "Разблокировать хранилище 2FA-кодов",
            uz: "2FA omborini qulfdan chiqarish",
            fr: "Déverrouiller le coffre 2FA"
        )
    }

    public func copyCodePrompt(_ title: String) -> String {
        pick(
            en: "Copy 2FA code for “\(title)”",
            ru: "Скопировать 2FA-код для «\(title)»",
            uz: "«\(title)» uchun 2FA-kodni nusxalash",
            fr: "Copier le code 2FA pour « \(title) »"
        )
    }

    public func mcpCodePrompt(_ title: String) -> String {
        pick(
            en: "Issue 2FA code for “\(title)” (requested via MCP)",
            ru: "Выдать 2FA-код для «\(title)» (запрос через MCP)",
            uz: "«\(title)» uchun 2FA-kod berish (MCP soʻrovi)",
            fr: "Générer le code 2FA pour « \(title) » (requête MCP)"
        )
    }
}
