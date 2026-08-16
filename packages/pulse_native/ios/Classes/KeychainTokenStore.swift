import Foundation
import Security

enum KeychainError: Error {
  case unexpectedStatus(OSStatus)
}

/// Stores the auth token as a generic-password Keychain item.
///
/// Accessibility is `afterFirstUnlockThisDeviceOnly`: the app needs the token
/// to reconnect while running in the background, but the token is a
/// device-local session credential and has no business syncing to iCloud or
/// restoring onto a different device from a backup.
final class KeychainTokenStore {
  private let service: String
  private let account: String

  init(
    service: String = "com.finonex.pulse.auth",
    account: String = "feed-token"
  ) {
    self.service = service
    self.account = account
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func write(_ token: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    // Update first, insert only if there is nothing to update. Doing it the
    // other way round means a duplicate-item error on every refresh, and the
    // token is refreshed roughly once a minute.
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      attributes as CFDictionary
    )
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      let insert = baseQuery.merging(attributes) { current, _ in current }
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainError.unexpectedStatus(addStatus)
      }
    default:
      throw KeychainError.unexpectedStatus(updateStatus)
    }
  }

  func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.unexpectedStatus(status)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    // Deleting something that was never there is a success, not a failure.
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
}
