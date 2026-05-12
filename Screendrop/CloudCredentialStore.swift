//
//  CloudCredentialStore.swift
//  Screendrop
//
//  Keychain-backed storage for R2/S3 credentials and worker configuration.
//  Secrets (access key, secret key, upload token) go in the Keychain.
//  Non-secret config (bucket, region, endpoint, worker URL) go in UserDefaults.
//

import Foundation
import Security

/// Immutable snapshot of credentials used by `S3CloudService` (which is actor-isolated).
struct CloudCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let bucket: String
    let region: String
    let endpoint: String
    let publicURLBase: String
    let workerURL: String
    let uploadToken: String

    var isConfigured: Bool {
        !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !bucket.isEmpty && !endpoint.isEmpty
    }

    var isWorkerConfigured: Bool {
        !workerURL.isEmpty && !uploadToken.isEmpty
    }

    /// Fully configured means both S3 credentials and worker are set.
    var isFullyConfigured: Bool {
        isConfigured && isWorkerConfigured
    }
}

@Observable
final class CloudCredentialStore {
    static let shared = CloudCredentialStore()

    private let defaults = UserDefaults.standard
    private static let keychainService = "com.fayazahmed.Screendrop"

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let accessKeyId = "cloud_s3_access_key_id"
        static let secretAccessKey = "cloud_s3_secret_access_key"
        static let uploadToken = "cloud_upload_token"
        static let bucket = "cloud_s3_bucket"
        static let region = "cloud_s3_region"
        static let endpoint = "cloud_s3_endpoint"
        static let publicURLBase = "cloud_s3_public_url_base"
        static let workerURL = "cloudWorkerURL"       // Matches existing key
    }

    // MARK: - Backing storage (observed)

    private(set) var _accessKeyId: String = ""
    private(set) var _secretAccessKey: String = ""
    private(set) var _uploadToken: String = ""
    private(set) var _bucket: String = ""
    private(set) var _region: String = "auto"
    private(set) var _endpoint: String = ""
    private(set) var _publicURLBase: String = ""
    private(set) var _workerURL: String = ""

    // MARK: - Public computed setters

    var accessKeyId: String {
        get { _accessKeyId }
        set {
            _accessKeyId = newValue
            Self.setKeychainItem(key: Keys.accessKeyId, value: newValue)
        }
    }

    var secretAccessKey: String {
        get { _secretAccessKey }
        set {
            _secretAccessKey = newValue
            Self.setKeychainItem(key: Keys.secretAccessKey, value: newValue)
        }
    }

    var uploadToken: String {
        get { _uploadToken }
        set {
            _uploadToken = newValue
            Self.setKeychainItem(key: Keys.uploadToken, value: newValue)
        }
    }

    var bucket: String {
        get { _bucket }
        set {
            _bucket = newValue
            defaults.set(newValue, forKey: Keys.bucket)
        }
    }

    var region: String {
        get { _region }
        set {
            _region = newValue
            defaults.set(newValue, forKey: Keys.region)
        }
    }

    var endpoint: String {
        get { _endpoint }
        set {
            _endpoint = newValue
            defaults.set(newValue, forKey: Keys.endpoint)
        }
    }

    var publicURLBase: String {
        get { _publicURLBase }
        set {
            _publicURLBase = newValue
            defaults.set(newValue, forKey: Keys.publicURLBase)
        }
    }

    var workerURL: String {
        get { _workerURL }
        set {
            _workerURL = newValue
            defaults.set(newValue, forKey: Keys.workerURL)
        }
    }

    // MARK: - Convenience

    var isConfigured: Bool {
        !_accessKeyId.isEmpty && !_secretAccessKey.isEmpty && !_bucket.isEmpty && !_endpoint.isEmpty
    }

    var isWorkerConfigured: Bool {
        !_workerURL.isEmpty && !_uploadToken.isEmpty
    }

    var isFullyConfigured: Bool {
        isConfigured && isWorkerConfigured
    }

    /// Create an immutable snapshot for passing across actor boundaries.
    func snapshot() -> CloudCredentials {
        CloudCredentials(
            accessKeyId: _accessKeyId,
            secretAccessKey: _secretAccessKey,
            bucket: _bucket,
            region: _region,
            endpoint: _endpoint,
            publicURLBase: _publicURLBase,
            workerURL: _workerURL,
            uploadToken: _uploadToken
        )
    }

    // MARK: - Init

    private init() {
        _accessKeyId = Self.getKeychainItem(key: Keys.accessKeyId) ?? ""
        _secretAccessKey = Self.getKeychainItem(key: Keys.secretAccessKey) ?? ""
        _uploadToken = Self.getKeychainItem(key: Keys.uploadToken) ?? ""
        _bucket = defaults.string(forKey: Keys.bucket) ?? ""
        _region = defaults.string(forKey: Keys.region) ?? "auto"
        _endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        _publicURLBase = defaults.string(forKey: Keys.publicURLBase) ?? ""
        _workerURL = defaults.string(forKey: Keys.workerURL) ?? ""

        // Migrate from old UserDefaults-based cloud token if present
        migrateFromLegacyDefaults()
    }

    private func migrateFromLegacyDefaults() {
        let oldTokenKey = "cloudUploadToken"
        if let oldToken = defaults.string(forKey: oldTokenKey), !oldToken.isEmpty, _uploadToken.isEmpty {
            uploadToken = oldToken
            defaults.removeObject(forKey: oldTokenKey)
        }
    }

    // MARK: - Keychain

    private static func setKeychainItem(key: String, value: String) {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
        ]

        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData as String] = data
        SecItemAdd(newQuery as CFDictionary, nil)
    }

    private static func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
