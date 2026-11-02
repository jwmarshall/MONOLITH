// LOVELACE Gmail Keychain boundary. No credential argv, files, logging or UI.
// Build only: mix lovelace.keychain.build. One JSON line in, one JSON line out.
import Foundation
import Security
import Darwin

private let service = "LOVELACE Gmail"
private let maxInput = 128 * 1024
private let maxValue = 16 * 1024

// Security APIs can block; this process-wide deadline also bounds reads on stdin.
// The parent independently enforces a 5-second deadline and stdout byte cap.
DispatchQueue.global().asyncAfter(deadline: .now() + 4) { _exit(124) }
SecKeychainSetUserInteractionAllowed(false)

private func respond(_ result: [String: Any]) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(0)
}

private func fail(_ status: OSStatus) -> Never {
    switch status {
    case errSecItemNotFound: respond(["error": "not_found"])
    case errSecInteractionNotAllowed, errSecAuthFailed: respond(["error": "locked"])
    default: respond(["error": "unavailable"])
    }
}

private func input() -> [String: Any] {
    var bytes = Data()
    while bytes.count <= maxInput {
        // Foundation's read(upToCount:) can wait for the full count or EOF on
        // a pipe. The parent keeps stdin open after writing one short JSON line.
        // POSIX read returns available bytes so framing can see the newline.
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = chunk.withUnsafeMutableBytes { buffer in
            Darwin.read(STDIN_FILENO, buffer.baseAddress, buffer.count)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { respond(["error": "unavailable"]) }
        bytes.append(contentsOf: chunk.prefix(count))
        if let newline = bytes.firstIndex(of: 10) {
            guard newline == bytes.index(before: bytes.endIndex), bytes.count <= maxInput,
                  let object = try? JSONSerialization.jsonObject(with: bytes.dropLast()),
                  let request = object as? [String: Any] else {
                respond(["error": "unavailable"])
            }
            return request
        }
    }
    respond(["error": "unavailable"])
}

let request = input()
guard let operation = request["operation"] as? String,
      ["get", "put", "delete"].contains(operation),
      let account = request["account"] as? String,
      let uuid = UUID(uuidString: account),
      uuid.uuidString.lowercased() == account.lowercased(),
      CommandLine.arguments.count == 1 else {
    respond(["error": "unavailable"])
}

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account.lowercased(),
    kSecAttrSynchronizable as String: false,
    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
]

switch operation {
case "get":
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    guard status == errSecSuccess else { fail(status) }
    guard let data = result as? Data, data.count > 0, data.count <= maxValue,
          let value = String(data: data, encoding: .utf8) else {
        respond(["error": "unavailable"])
    }
    respond(["ok": true, "value": value])
case "put":
    guard let value = request["value"] as? String,
          let data = value.data(using: .utf8), data.count > 0, data.count <= maxValue else {
        respond(["error": "unavailable"])
    }
    let attributes = [kSecValueData as String: data]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { fail(status) }
    respond(["ok": true])
case "delete":
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail(status) }
    respond(["ok": true])
default:
    respond(["error": "unavailable"])
}
