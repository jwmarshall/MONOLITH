// Synthetic ACL owner for keychain_helper_io_test.exs. Never opens a login/default keychain.
import Foundation
import Security
import Darwin

umask(0o077)
let inputDeadline = DispatchWorkItem { _exit(124) }
DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: inputDeadline)

func finish(_ ok: Bool) -> Never {
    let result: [String: Any] = ok ? ["version": 1, "ok": true] : ["version": 1, "error": "unavailable"]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
}

func privatePath(_ path: String, directory: Bool) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_uid == getuid()
        && (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG)
        && (info.st_mode & 0o077) == 0 && (directory || info.st_nlink == 1)
}

func restrictToOwner(_ item: SecKeychainItem) {
    var owner: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(CommandLine.arguments[0], &owner) == errSecSuccess,
          let owner = owner else { finish(false) }
    var access: SecAccess?
    // A nonempty, explicit owner list; nil would default to the creating application.
    guard SecAccessCreate("LOVELACE synthetic legacy owner" as CFString, [owner] as CFArray, &access) == errSecSuccess,
          let access = access, SecKeychainItemSetAccess(item, access) == errSecSuccess else { finish(false) }
}

guard CommandLine.arguments.count == 1,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { finish(false) }
var frame = Data()
while frame.count <= 64 * 1024 {
    var byte: UInt8 = 0
    guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { finish(false) }
    if byte == 10 { break }
    frame.append(byte)
}
guard frame.count <= 64 * 1024,
      let request = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
      let root = request["directory"] as? String, root.hasPrefix("/"),
      !root.utf8.contains(0), (root as NSString).standardizingPath == root,
      let operation = request["operation"] as? String,
      let text = request["value"] as? String else { finish(false) }
guard !text.isEmpty, text.utf8.count <= 16 * 1024,
      privatePath(root, directory: true) else { finish(false) }
let target = (request["target"] as? String) ?? "legacy"
guard target == "legacy" || target == "destination" else { finish(false) }
let directory = target == "legacy" ? root + "/legacy" : root
let path = directory + "/lovelace.keychain-db"
guard privatePath(directory, directory: true), privatePath(path, directory: false) else { finish(false) }
guard ["add", "verify"].contains(operation) else { finish(false) }
inputDeadline.cancel()
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { _exit(124) }
var opened: SecKeychain?
guard SecKeychainOpen(path, &opened) == errSecSuccess, let keychain = opened else { finish(false) }
let account = "11234567-89ab-cdef-0123-456789abcdef"
let service = "LOVELACE Gmail"
let value = Data(text.utf8)
if operation == "add" {
    var item: SecKeychainItem?
    let added = service.withCString { serviceBytes in
        account.withCString { accountBytes in
            value.withUnsafeBytes { bytes in
                SecKeychainAddGenericPassword(keychain, UInt32(service.utf8.count), serviceBytes,
                    UInt32(account.utf8.count), accountBytes, UInt32(value.count), bytes.baseAddress!, &item)
            }
        }
    }
    guard added == errSecSuccess, let item = item else { finish(false) }
    restrictToOwner(item)
    finish(true)
}
var length: UInt32 = 0
var bytes: UnsafeMutableRawPointer?
var item: SecKeychainItem?
let found = service.withCString { serviceBytes in
    account.withCString { accountBytes in
        SecKeychainFindGenericPassword(keychain, UInt32(service.utf8.count), serviceBytes,
            UInt32(account.utf8.count), accountBytes, &length, &bytes, &item)
    }
}
guard found == errSecSuccess, let bytes = bytes else { finish(false) }
let matches = Data(bytes: bytes, count: Int(length)) == value
SecKeychainItemFreeContent(nil, bytes)
finish(matches)
