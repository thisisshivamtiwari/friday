import Foundation
import Security
import Combine

/// Central store for user-configurable settings: agent persona, custom rules, and the
/// Gemini API key. Persona/rules are plain preferences (UserDefaults); the API key is a
/// secret and lives in the Keychain, never in a plist or UserDefaults.
/// https://developer.apple.com/documentation/security/keychain_services
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum DefaultsKey {
        static let agentName = "settings.agentName"
        static let aboutMe = "settings.aboutMe"
        static let rules = "settings.rules"
        static let geminiModel = "settings.geminiModel"
        static let transcriptionLocale = "settings.transcriptionLocale"
    }

    /// Locales offered for the local on-device "You" transcript (SFSpeechRecognizer is
    /// locked to a single locale per session - it can't auto-detect or switch languages
    /// mid-conversation the way Gemini's own transcription does). Kept as a short curated
    /// list rather than every SFSpeechRecognizer.supportedLocales() result, since most of
    /// those aren't realistic choices for this user base.
    static let transcriptionLocaleOptions: [(id: String, label: String)] = [
        ("en-US", "English (US)"),
        ("en-IN", "English (India)"),
        ("hi-IN", "Hindi")
    ]

    /// Default Live API model - confirmed working against the real API via ListModels
    /// plus a live round-trip test (2026-08-04): responseModalities=AUDIO with
    /// outputAudioTranscription enabled returned a real transcribed reply and turnComplete
    /// for this model. The "native-audio" family (also available to this key) was only
    /// tested against responseModalities=TEXT, which it rejected - untested here with the
    /// AUDIO+outputAudioTranscription combo GeminiLiveClient actually uses, so this
    /// non-native-audio model is the one with a confirmed-working setup, not a guess.
    /// Kept overridable here since these preview ids shift.
    static let defaultGeminiModel = "gemini-3.1-flash-live-preview"

    @Published var agentName: String {
        didSet { UserDefaults.standard.set(agentName, forKey: DefaultsKey.agentName) }
    }

    /// Persistent context about the user - name, role, goals - included in every session
    /// so the assistant can personalize suggestions instead of treating each meeting as
    /// a blank slate. Separate from `rules`, which is about how the assistant should
    /// behave rather than who it's helping.
    @Published var aboutMe: String {
        didSet { UserDefaults.standard.set(aboutMe, forKey: DefaultsKey.aboutMe) }
    }

    @Published var rules: String {
        didSet { UserDefaults.standard.set(rules, forKey: DefaultsKey.rules) }
    }

    @Published var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: DefaultsKey.geminiModel) }
    }

    /// Locale identifier (e.g. "en-US", "hi-IN") used for the local on-device "You"
    /// transcript. Whatever language the user actually speaks needs to match this, or
    /// SFSpeechRecognizer silently produces no transcript at all - not an error, just
    /// empty/near-empty results that never populate a "You" bubble.
    @Published var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: DefaultsKey.transcriptionLocale) }
    }

    /// Backed by the Keychain rather than @Published+UserDefaults; reads/writes are
    /// synchronous and infrequent (settings screen only), so no extra caching layer.
    var geminiAPIKey: String? {
        get { KeychainStore.readString(account: Self.apiKeyAccount) }
        set {
            objectWillChange.send()
            if let newValue, !newValue.isEmpty {
                KeychainStore.saveString(newValue, account: Self.apiKeyAccount)
            } else {
                KeychainStore.delete(account: Self.apiKeyAccount)
            }
        }
    }

    private static let apiKeyAccount = "gemini-api-key"

    /// Model ids that were saved as the default at some point during development but are
    /// now known not to work with this app's setup (responseModalities=AUDIO +
    /// outputAudioTranscription) - a value stored in UserDefaults before a code-level
    /// default changes does NOT pick up the new default automatically, so anyone who had
    /// the app open while these were current would otherwise be silently stuck on them.
    private static let knownStaleModelIDs: Set<String> = [
        "gemini-2.5-flash-native-audio-preview-09-2025"
    ]

    private init() {
        let defaults = UserDefaults.standard
        agentName = defaults.string(forKey: DefaultsKey.agentName) ?? "Founder Office Copilot"
        aboutMe = defaults.string(forKey: DefaultsKey.aboutMe) ?? ""
        rules = defaults.string(forKey: DefaultsKey.rules) ?? SettingsStore.defaultRules

        let storedModel = defaults.string(forKey: DefaultsKey.geminiModel)
        if let storedModel, SettingsStore.knownStaleModelIDs.contains(storedModel) {
            geminiModel = SettingsStore.defaultGeminiModel
            print("[Settings] Migrated stale Gemini model '\(storedModel)' -> '\(SettingsStore.defaultGeminiModel)'")
        } else {
            geminiModel = storedModel ?? SettingsStore.defaultGeminiModel
        }

        transcriptionLocale = defaults.string(forKey: DefaultsKey.transcriptionLocale) ?? "en-US"
    }

    private static let defaultRules = """
    You are a real-time meeting copilot. Listen to the conversation and, when useful, \
    suggest one short, natural intervention line the user could say next. Be concise \
    and concrete, not generic.
    """
}

/// Minimal Keychain wrapper for a single generic-password secret (the Gemini API key)
/// https://developer.apple.com/documentation/security/keychain_services/keychain_items/adding_a_password_to_the_keychain
enum KeychainStore {
    private static let service = "com.founderoffice.copilot.secrets"

    /// Every query is explicitly pinned to the legacy/file-based keychain (NOT the modern
    /// Data Protection Keychain) rather than leaving it to the OS default. Confirmed by
    /// actually running this code with status checking on: requesting the Data Protection
    /// Keychain here fails outright with errSecMissingEntitlement (-34018), because this
    /// app is intentionally not sandboxed and has no keychain-access-groups entitlement -
    /// adding App Sandbox would be a much bigger change (it restricts the screen/audio
    /// capture this app depends on) just to satisfy a keychain API choice. Since the OS's
    /// default resolution between the two stores isn't guaranteed consistent across launch
    /// contexts (Xcode run vs. double-clicking the built .app, different derived-data
    /// state), being explicit is what actually makes save and read reliably agree - this is
    /// almost certainly why the API key wasn't surviving a restart before.
    /// https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: false
        ]
    }

    static func saveString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            print("[Keychain] Delete-before-save for '\(account)' returned status \(deleteStatus) (non-fatal, continuing to add)")
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            print("[Keychain] Saved '\(account)' (\(data.count) bytes)")
        } else {
            let message = (SecCopyErrorMessageString(addStatus, nil) as String?) ?? "unknown error"
            print("[Keychain] FAILED to save '\(account)': OSStatus \(addStatus) - \(message). The key will appear to save in the UI but will NOT survive a restart.")
        }
    }

    static func readString(account: String) -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
                print("[Keychain] Read '\(account)' failed: OSStatus \(status) - \(message)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        SecItemDelete(query as CFDictionary)
    }
}
