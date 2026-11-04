// LOVELACE dedicated file-keychain boundary. Secrets use stdin/stdout only.
// File keychains require deprecated macOS Security APIs. No login/default/search-list
// changes, Data Protection Keychain fallback or broad ACLs. Explicit setup/migration UI only.
import Foundation
import Security
import Darwin

#if LOVELACE_TEST_MIGRATION && !LOVELACE_TEST
#error("Synthetic migration requires LOVELACE_TEST; no production legacy-source fallback")
#endif

private let version = 1
private let maxInput = 128 * 1024
private let maxValue = 16 * 1024
private let databaseAccount = "5bbed47a-8e42-4b3e-a2e8-f81beb0738d5"
private let geminiAccount = "b26d050a-0729-4d79-a6bc-407cf660a7ea"
private let oauthAccount = "710dd510-61ed-4e6a-975c-78ce13f5d6e2"
private let operations = ["create", "unlock", "lock", "status", "get", "put", "delete", "copy_legacy", "delete_legacy"]
umask(0o077)

private let inputDeadline = DispatchWorkItem { _exit(124) }
DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: inputDeadline)

private func respond(_ result: [String: Any]) -> Never {
    var envelope = result
    envelope["version"] = version
    if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(0)
}

private func fail(_ status: OSStatus) -> Never {
    switch status {
    case errSecItemNotFound: respond(["error": "not_found"])
    case errSecInteractionNotAllowed, errSecAuthFailed: respond(["error": "locked"])
    case errSecDuplicateItem, errSecDuplicateKeychain: respond(["error": "exists"])
    default: respond(["error": "unavailable"])
    }
}

private func failLegacy(_ status: OSStatus) -> Never {
    switch status {
    case errSecInteractionNotAllowed: respond(["error": "legacy_authorization_required"])
    case errSecAuthFailed, errSecUserCanceled: respond(["error": "legacy_access_denied"])
    default: respond(["error": "legacy_unavailable"])
    }
}

private func input() -> [String: Any] {
    var bytes = Data()
    while bytes.count <= maxInput {
        // POSIX read observes short newline frames without waiting for EOF.
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { respond(["error": "unavailable"]) }
        bytes.append(contentsOf: chunk.prefix(count))
        if let newline = bytes.firstIndex(of: 10) {
            guard newline == bytes.index(before: bytes.endIndex), bytes.count <= maxInput,
                  let object = try? JSONSerialization.jsonObject(with: bytes.dropLast()),
                  let request = object as? [String: Any] else { respond(["error": "unavailable"]) }
            return request
        }
    }
    respond(["error": "unavailable"])
}

private func uuid(_ value: String) -> Bool {
    guard let parsed = UUID(uuidString: value) else { return false }
    return parsed.uuidString.lowercased() == value.lowercased()
}

private func validIdentity(_ account: String, _ service: String) -> Bool {
    guard uuid(account) else { return false }
    switch service {
    case "LOVELACE Gmail": return true
    case "LOVELACE Gemini": return account == geminiAccount
    case "LOVELACE Google OAuth": return account == oauthAccount
    case "LOVELACE Database": return account == databaseAccount
    default: return false
    }
}

private func fileInfo(_ path: String) -> stat? {
    var info = stat()
    if lstat(path, &info) == 0 { return info }
    if errno == ENOENT { return nil }
    respond(["error": "unavailable"])
}

private func privateDirectory(_ root: String, create: Bool) {
    if create && fileInfo(root) == nil {
        guard mkdir(root, 0o700) == 0 || errno == EEXIST else { respond(["error": "unavailable"]) }
    }
    guard let info = fileInfo(root) else { return }
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
          (info.st_mode & 0o077) == 0 else { respond(["error": "invalid_directory"]) }
}

private let creationContents = Data("LOVELACE keychain creation v1\n".utf8)

private func creationPending(_ marker: String) -> Bool {
    guard let info = fileInfo(marker) else { return false }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
          info.st_nlink == 1, (info.st_mode & 0o077) == 0,
          info.st_size == creationContents.count,
          (try? Data(contentsOf: URL(fileURLWithPath: marker))) == creationContents else {
        respond(["error": "invalid_directory"])
    }
    return true
}

private func beginCreation(_ marker: String, interrupt: Bool = false) {
    let temporary = marker + "." + UUID().uuidString
    let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { respond(["error": "unavailable"]) }
    defer { Darwin.close(descriptor) }
    #if LOVELACE_TEST
    if interrupt { respond(["error": "unavailable"]) }
    #endif
    let written = creationContents.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    guard written == creationContents.count, fsync(descriptor) == 0,
          renamex_np(temporary, marker, UInt32(RENAME_EXCL)) == 0 else {
        respond(["error": "unavailable"])
    }
}

private func finishCreation(_ marker: String) {
    guard creationPending(marker), unlink(marker) == 0 else { respond(["error": "unavailable"]) }
}

private func openKeychain(_ path: String) -> SecKeychain {
    guard let info = fileInfo(path) else { respond(["error": "missing"]) }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
          info.st_nlink == 1, (info.st_mode & 0o077) == 0 else { respond(["error": "invalid_directory"]) }
    var keychain: SecKeychain?
    let status = SecKeychainOpen(path, &keychain)
    guard status == errSecSuccess, let opened = keychain else { fail(status) }
    return opened
}

private func isUnlocked(_ keychain: SecKeychain) -> Bool {
    var status: SecKeychainStatus = 0
    let result = SecKeychainGetStatus(keychain, &status)
    guard result == errSecSuccess else { fail(result) }
    return (status & SecKeychainStatus(kSecUnlockStateStatus)) != 0
}

private func requireUnlocked(_ keychain: SecKeychain) {
    guard isUnlocked(keychain) else { respond(["error": "locked"]) }
}

// The explicit SecKeychain argument is mandatory: nil would search user defaults.
private func find(_ keychain: SecKeychain, _ account: String, _ service: String,
                  legacy: Bool = false) -> (Data, SecKeychainItem)? {
    var length: UInt32 = 0
    var bytes: UnsafeMutableRawPointer?
    var item: SecKeychainItem?
    let status = service.withCString { serviceBytes in
        account.withCString { accountBytes in
            SecKeychainFindGenericPassword(keychain, UInt32(service.utf8.count), serviceBytes,
                                          UInt32(account.utf8.count), accountBytes, &length, &bytes, &item)
        }
    }
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
        if legacy { failLegacy(status) }
        fail(status)
    }
    defer { SecKeychainItemFreeContent(nil, bytes) }
    guard length > 0, length <= maxValue, let bytes = bytes, let item = item else {
        respond(["error": legacy ? "legacy_unavailable" : "unavailable"])
    }
    return (Data(bytes: bytes, count: Int(length)), item)
}

private func add(_ keychain: SecKeychain, _ account: String, _ service: String, _ data: Data) {
    let status = service.withCString { serviceBytes in
        account.withCString { accountBytes in
            data.withUnsafeBytes { bytes in
                SecKeychainAddGenericPassword(keychain, UInt32(service.utf8.count), serviceBytes,
                                             UInt32(account.utf8.count), accountBytes,
                                             UInt32(data.count), bytes.baseAddress!, nil)
            }
        }
    }
    guard status == errSecSuccess else { fail(status) }
}

private func password(_ request: [String: Any]) -> Data {
    guard let value = request["password"] as? String,
          let data = value.precomposedStringWithCanonicalMapping.data(using: .utf8),
          data.count > 0, data.count <= 4096 else {
        respond(["error": "invalid_password"])
    }
    return data
}

private func migrateLegacy(_ keychain: SecKeychain, _ accounts: [String], delete: Bool,
                           root: String, request: [String: Any]) {
#if LOVELACE_TEST && !LOVELACE_TEST_MIGRATION
    // Default test binaries cannot even open a legacy source.
    respond(["error": "unavailable"])
#else
    #if LOVELACE_TEST
    // This branch never compiles the real login-keychain path into a test binary.
    let legacyRoot = root + "/legacy"
    privateDirectory(legacyRoot, create: false)
    let sourcePath = legacyRoot + "/lovelace.keychain-db"
    #else
    let sourcePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Keychains/login.keychain-db").path
    #endif
    var info = stat()
    if lstat(sourcePath, &info) != 0 {
        if errno == ENOENT { respond(["ok": true]) }
        respond(["error": "legacy_unavailable"])
    }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
          info.st_nlink == 1 else { respond(["error": "legacy_unavailable"]) }
    var opened: SecKeychain?
    let status = SecKeychainOpen(sourcePath, &opened)
    guard status == errSecSuccess, let source = opened else { failLegacy(status) }
    var sourceStatus: SecKeychainStatus = 0
    let checked = SecKeychainGetStatus(source, &sourceStatus)
    guard checked == errSecSuccess else { failLegacy(checked) }
    guard (sourceStatus & SecKeychainStatus(kSecUnlockStateStatus)) != 0 else {
        respond(["error": "legacy_locked"])
    }
    let identities = accounts.map { ($0, "LOVELACE Gmail") } + [
        (geminiAccount, "LOVELACE Gemini"), (oauthAccount, "LOVELACE Google OAuth")
    ]
    // Authorize and snapshot every source before any mutation. In particular, a
    // later denied ACL must not leave an earlier credential partially copied.
    var originals: [(String, String, Data, SecKeychainItem)] = []
    for (account, service) in identities {
        #if LOVELACE_TEST && LOVELACE_TEST_MIGRATION
        // Synthetic Security failure boundary; never present in production or the
        // default test helper. Actual locked-source/ACL tests also use real APIs.
        if request["legacy_failure_account"] as? String == account,
           let failure = request["legacy_failure"] as? String {
            switch failure {
            case "authorization": failLegacy(errSecInteractionNotAllowed)
            case "denied": failLegacy(errSecAuthFailed)
            case "cancelled": failLegacy(errSecUserCanceled)
            case "unavailable": failLegacy(errSecNotAvailable)
            default: respond(["error": "legacy_unavailable"])
            }
        }
        #endif
        if let (value, item) = find(source, account, service, legacy: true) {
            originals.append((account, service, value, item))
        }
    }
    // Preflight every conflict before changing either keychain. Resume is idempotent.
    for (account, service, value, _) in originals {
        let destination = find(keychain, account, service)
        if let (existing, _) = destination, existing != value { respond(["error": "conflict"]) }
        if delete && destination == nil { respond(["error": "conflict"]) }
    }
    // Any attended destination ACL approval must persist for ordinary runtime
    // reads. Check every existing item again without UI before the first write.
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
    for (account, service, value, _) in originals {
        let destination = find(keychain, account, service)
        if let (existing, _) = destination, existing != value { respond(["error": "conflict"]) }
        if delete && destination == nil { respond(["error": "conflict"]) }
    }
    for (account, service, value, item) in originals {
        if delete {
            guard let (existing, _) = find(keychain, account, service), existing == value else {
                respond(["error": "conflict"])
            }
            let allowDeletion = request["migration_interaction"] as? Bool == true
            guard SecKeychainSetUserInteractionAllowed(allowDeletion) == errSecSuccess else { exit(1) }
            guard let (current, _) = find(source, account, service, legacy: true),
                  current == value else { respond(["error": "conflict"]) }
            let result = SecKeychainItemDelete(item)
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
            guard result == errSecSuccess || result == errSecItemNotFound else { failLegacy(result) }
        } else {
            if let (existing, _) = find(keychain, account, service) {
                guard existing == value else { respond(["error": "conflict"]) }
            } else {
                add(keychain, account, service, value)
            }
            guard let (copied, _) = find(keychain, account, service), copied == value else {
                respond(["error": "unavailable"])
            }
        }
    }
    respond(["ok": true])
#endif
}

let request = input()
guard request["version"] as? Int == version,
      let wireOperation = request["operation"] as? String, wireOperation.hasPrefix("vault_"),
      let root = request["directory"] as? String, root.hasPrefix("/"), root.utf8.count <= 4096,
      !root.utf8.contains(0), (root as NSString).standardizingPath == root,
      CommandLine.arguments.count == 1 else { respond(["error": "unavailable"]) }
let operation = String(wireOperation.dropFirst(6))
guard operations.contains(operation) else { respond(["error": "unavailable"]) }
let setupInteraction = operation == "create" && request["setup_interaction"] as? Bool == true
let migrationOperation = operation == "copy_legacy" || operation == "delete_legacy"
// Rebuilt helpers may need attended authorization for the existing Database item
// ACL. Only the migration caller opts in; no other get identity can enable UI.
let migrationDatabaseRead = operation == "get"
    && (request["account"] as? String)?.lowercased() == databaseAccount
    && request["service"] as? String == "LOVELACE Database"
let migrationInteraction = (migrationOperation || migrationDatabaseRead)
    && request["migration_interaction"] as? Bool == true

// Validate request identities before touching any keychain.
var account = ""
var service = ""
if ["get", "put", "delete"].contains(operation) {
    guard let suppliedAccount = request["account"] as? String,
          let suppliedService = request["service"] as? String else { respond(["error": "unavailable"]) }
    account = suppliedAccount.lowercased()
    service = suppliedService
    guard validIdentity(account, service) else { respond(["error": "invalid_account"]) }
    // The generated database key has no public overwrite/delete path.
    guard service != "LOVELACE Database" || operation == "get" else { respond(["error": "unavailable"]) }
}
var value: Data?
if operation == "put" {
    guard let text = request["value"] as? String, let data = text.data(using: .utf8),
          data.count > 0, data.count <= maxValue else { respond(["error": "invalid_value"]) }
    value = data
}
var accounts: [String] = []
if operation == "copy_legacy" || operation == "delete_legacy" {
    guard let supplied = request["accounts"] as? [String], supplied.count <= 512,
          supplied.allSatisfy({ uuid($0) }) else { respond(["error": "invalid_account"]) }
    accounts = Array(Set(supplied.map { $0.lowercased() })).sorted()
}
guard SecKeychainSetUserInteractionAllowed(setupInteraction || migrationInteraction) == errSecSuccess else { exit(1) }
inputDeadline.cancel()
DispatchQueue.global().asyncAfter(deadline: .now() + (setupInteraction || migrationInteraction ? 120 : 4)) { _exit(124) }

privateDirectory(root, create: operation == "create")
let path = root + "/lovelace.keychain-db"
if operation == "create" {
    let marker = root + "/.keychain-pending"
    let resuming = creationPending(marker)
    guard fileInfo(path) == nil || resuming else { respond(["error": "exists"]) }
    if !resuming {
        #if LOVELACE_TEST
        beginCreation(marker, interrupt: request["interrupt_before_marker"] as? Bool == true)
        #else
        beginCreation(marker)
        #endif
    }
    let data = password(request)
    if fileInfo(path) != nil {
        let existingKeychain = openKeychain(path)
        // SecKeychainUnlock does not check a password when already unlocked.
        let locked = SecKeychainLock(existingKeychain)
        guard locked == errSecSuccess else { fail(locked) }
        let unlocked = data.withUnsafeBytes {
            SecKeychainUnlock(existingKeychain, UInt32(data.count), $0.baseAddress, true)
        }
        guard unlocked == errSecSuccess else { fail(unlocked) }
        guard let (existing, _) = find(existingKeychain, databaseAccount, "LOVELACE Database"),
              let hex = String(data: existing, encoding: .utf8),
              hex.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            respond(["error": "unavailable"])
        }
        finishCreation(marker)
        respond(["ok": true])
    }
    // Never publish a partially initialized keychain. Interrupted attempts remain
    // encrypted and unused; retry creates a fresh staging file, not a replacement.
    let staging = root + "/.keychain-creating-" + UUID().uuidString + ".keychain-db"
    var created: SecKeychain?
    let status = data.withUnsafeBytes {
        SecKeychainCreate(staging, UInt32(data.count), $0.baseAddress, false, nil, &created)
    }
    guard status == errSecSuccess, let keychain = created else { fail(status) }
    guard chmod(staging, 0o600) == 0 else { respond(["error": "unavailable"]) }
    #if LOVELACE_TEST
    if request["interrupt_after_create"] as? Bool == true {
        _ = SecKeychainLock(keychain)
        respond(["error": "unavailable"])
    }
    #endif
    let unlocked = data.withUnsafeBytes {
        SecKeychainUnlock(keychain, UInt32(data.count), $0.baseAddress, true)
    }
    guard unlocked == errSecSuccess else { fail(unlocked) }
    // No time-based auto-lock: application lifecycle owns explicit vault locking.
    var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                       lockOnSleep: false, useLockInterval: false, lockInterval: UInt32.max)
    let configured = SecKeychainSetSettings(keychain, &settings)
    guard configured == errSecSuccess else { fail(configured) }
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
    var random = [UInt8](repeating: 0, count: 32)
    let generated = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard generated == errSecSuccess else { fail(generated) }
    let hex = random.map { String(format: "%02x", $0) }.joined()
    add(keychain, databaseAccount, "LOVELACE Database", Data(hex.utf8))
    guard let (stored, _) = find(keychain, databaseAccount, "LOVELACE Database"), stored == Data(hex.utf8) else {
        respond(["error": "unavailable"])
    }
    guard SecKeychainLock(keychain) == errSecSuccess,
          renamex_np(staging, path, UInt32(RENAME_EXCL)) == 0 else {
        respond(["error": "unavailable"])
    }
    let published = openKeychain(path)
    let publishedUnlock = data.withUnsafeBytes {
        SecKeychainUnlock(published, UInt32(data.count), $0.baseAddress, true)
    }
    guard publishedUnlock == errSecSuccess else { fail(publishedUnlock) }
    guard let (publishedKey, _) = find(published, databaseAccount, "LOVELACE Database"),
          publishedKey == Data(hex.utf8) else { respond(["error": "unavailable"]) }
    finishCreation(marker)
    respond(["ok": true])
}
if fileInfo(path) == nil {
    if operation == "status" { respond(["ok": true, "status": "missing"]) }
    if operation == "lock" { respond(["ok": true]) }
    respond(["error": "missing"])
}
let keychain = openKeychain(path)
switch operation {
case "status":
    respond(["ok": true, "status": isUnlocked(keychain) ? "unlocked" : "locked"])
case "unlock":
    let data = password(request)
    let status = data.withUnsafeBytes { SecKeychainUnlock(keychain, UInt32(data.count), $0.baseAddress, true) }
    guard status == errSecSuccess else { fail(status) }
    requireUnlocked(keychain)
    respond(["ok": true])
case "lock":
    let status = SecKeychainLock(keychain)
    guard status == errSecSuccess else { fail(status) }
    guard !isUnlocked(keychain) else { respond(["error": "unavailable"]) }
    respond(["ok": true])
case "get":
    requireUnlocked(keychain)
    guard let (data, _) = find(keychain, account, service) else { respond(["error": "not_found"]) }
    guard let text = String(data: data, encoding: .utf8) else { respond(["error": "unavailable"]) }
    respond(["ok": true, "value": text])
case "put":
    requireUnlocked(keychain)
    guard let data = value else { respond(["error": "invalid_value"]) }
    if let (_, item) = find(keychain, account, service) {
        let status = data.withUnsafeBytes { SecKeychainItemModifyAttributesAndData(item, nil, UInt32(data.count), $0.baseAddress) }
        guard status == errSecSuccess else { fail(status) }
    } else {
        add(keychain, account, service, data)
    }
    guard let (stored, _) = find(keychain, account, service), stored == data else { respond(["error": "unavailable"]) }
    respond(["ok": true])
case "delete":
    requireUnlocked(keychain)
    if let (_, item) = find(keychain, account, service) {
        let status = SecKeychainItemDelete(item)
        guard status == errSecSuccess || status == errSecItemNotFound else { fail(status) }
    }
    respond(["ok": true])
case "copy_legacy", "delete_legacy":
    requireUnlocked(keychain)
    migrateLegacy(keychain, accounts, delete: operation == "delete_legacy", root: root, request: request)
default:
    respond(["error": "unavailable"])
}
