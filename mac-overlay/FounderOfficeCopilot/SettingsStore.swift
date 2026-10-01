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
        static let responseModel = "settings.responseModel"
        static let screenContextEnabled = "settings.screenContextEnabled"
        static let appearance = "settings.appearance"
        static let density = "settings.density"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
    }

    /// Live API model used for continuous transcription only ("Heard" bubbles) -
    /// confirmed working against the real API via ListModels plus a live round-trip test
    /// (2026-08-04): responseModalities=AUDIO with outputAudioTranscription enabled
    /// returned a real transcribed reply and turnComplete for this model. Kept overridable
    /// here since these preview ids shift.
    static let defaultGeminiModel = "gemini-3.1-flash-live-preview"

    /// Model used for the one-shot "Respond Now" request - a plain generateContent call
    /// (not the Live API), so this is a standard, non-Live model. Deliberately separate
    /// from defaultGeminiModel: transcription needs a Live-capable model, responses don't,
    /// and a fast general-purpose model is both cheaper and simpler for a single-turn
    /// text-in/text-out request.
    ///
    /// Uses Google's "-latest" alias rather than a pinned version (e.g. "gemini-2.5-flash",
    /// used until this app hit it returning 404 NOT_FOUND: "This model ... is no longer
    /// available to new users") - the alias is Google's own answer to models getting
    /// retired out from under pinned integrations, and always resolves to their current
    /// recommended flash model instead of a specific snapshot that can go stale.
    static let defaultResponseModel = "gemini-flash-latest"

    /// Whether a still of the current screen is sent with each response request.
    ///
    /// DEFAULT OFF, deliberately and on evidence. The capture is genuinely useful ("what's on
    /// screen right now?"), but it uploads WHATEVER is visible. During validation it sent a
    /// screenshot containing an open `.env` file with a live API key, and on a
    /// negative-retrieval benchmark question it caused the assistant to answer about a hotel
    /// codebase that merely happened to be on screen instead of correctly saying it had nothing
    /// stored. Sending the user's screen to a third party is not a reasonable silent default.
    @Published var screenContextEnabled: Bool {
        didSet { UserDefaults.standard.set(screenContextEnabled, forKey: DefaultsKey.screenContextEnabled) }
    }

    /// Window appearance. Applied to the workspace window only, so the always-on overlay keeps
    /// the dark treatment it was designed for.
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: DefaultsKey.appearance) }
    }

    /// Row density for the workspace.
    @Published var density: AppDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: DefaultsKey.density) }
    }

    /// Whether the first-run explanation has been shown. Persisted so it appears exactly once.
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: DefaultsKey.hasCompletedOnboarding) }
    }

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

    @Published var responseModel: String {
        didSet { UserDefaults.standard.set(responseModel, forKey: DefaultsKey.responseModel) }
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

    /// Response-model ids known to now 404 with NOT_FOUND/"no longer available to new
    /// users" - same problem and same fix as knownStaleModelIDs above, kept as a separate
    /// set since it's a different UserDefaults key with a different default.
    private static let knownStaleResponseModelIDs: Set<String> = [
        "gemini-2.5-flash"
    ]

    private init() {
        let defaults = UserDefaults.standard
        agentName = defaults.string(forKey: DefaultsKey.agentName) ?? "Founder Office Copilot"
        aboutMe = defaults.string(forKey: DefaultsKey.aboutMe) ?? ""
        rules = defaults.string(forKey: DefaultsKey.rules) ?? SettingsStore.defaultRules
        // Absent key -> false. `bool(forKey:)` already returns false for a missing key; this is
        // spelled out so the OFF-by-default guarantee is visible rather than incidental.
        screenContextEnabled = defaults.bool(forKey: DefaultsKey.screenContextEnabled)
        appearance = AppAppearance(rawValue: defaults.string(forKey: DefaultsKey.appearance) ?? "") ?? .system
        density = AppDensity(rawValue: defaults.string(forKey: DefaultsKey.density) ?? "") ?? .comfortable
        hasCompletedOnboarding = defaults.bool(forKey: DefaultsKey.hasCompletedOnboarding)

        let storedModel = defaults.string(forKey: DefaultsKey.geminiModel)
        if let storedModel, SettingsStore.knownStaleModelIDs.contains(storedModel) {
            geminiModel = SettingsStore.defaultGeminiModel
            print("[Settings] Migrated stale Gemini model '\(storedModel)' -> '\(SettingsStore.defaultGeminiModel)'")
        } else {
            geminiModel = storedModel ?? SettingsStore.defaultGeminiModel
        }

        let storedResponseModel = defaults.string(forKey: DefaultsKey.responseModel)
        if let storedResponseModel, SettingsStore.knownStaleResponseModelIDs.contains(storedResponseModel) {
            responseModel = SettingsStore.defaultResponseModel
            print("[Settings] Migrated stale response model '\(storedResponseModel)' -> '\(SettingsStore.defaultResponseModel)'")
        } else {
            responseModel = storedResponseModel ?? SettingsStore.defaultResponseModel
        }
    }

    private static let defaultRules = """
    Be concise and concrete, not generic. Favor a clear point of view over a vague summary.
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
