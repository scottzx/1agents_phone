//
//  SharedFolderWebDAVServer.swift
//  Minis
//
//  A deliberately small, local-only WebDAV server for /var/minis/shared.
//  It never serves the app's Documents, Library, or rootfs directories.
//

import Darwin
import Foundation
import Security
import SwiftUI
import UIKit

/// Provides Finder-mountable access to the one user-approved shared folder.
///
/// The listener is intentionally active only while Minis is foregrounded. iOS
/// cannot guarantee network listeners survive suspension, and advertising a
/// writable service while the app is not visible would be surprising.
final class SharedFolderWebDAVServer: ObservableObject, @unchecked Sendable {
    static let shared = SharedFolderWebDAVServer()

    static let username = "minis"
    static let port: UInt16 = 8465

    @Published private(set) var isEnabled = false
    @Published private(set) var isRunning = false
    @Published private(set) var endpointURL: String?
    @Published private(set) var lastError: String?
    @Published private(set) var password: String

    private let listenerQueue = DispatchQueue(label: "com.1agents.phone.webdav.listener")
    private let acceptQueue = DispatchQueue(label: "com.1agents.phone.webdav.accept", qos: .utility)
    private let connectionQueue = DispatchQueue(label: "com.1agents.phone.webdav.connection", qos: .utility, attributes: .concurrent)
    private var listenSocket: Int32 = -1
    private var shouldListen = false

    private init() {
        self.password = Self.loadOrCreatePassword()
    }

    /// Start serving. Safe to call repeatedly from the SwiftUI toggle.
    func enable() {
        isEnabled = true
        startListener()
    }

    /// Stop serving and keep no writable network endpoint open.
    func disable() {
        isEnabled = false
        stopListener()
    }

    /// iOS may tear down a socket while an app is backgrounded, so rebuild it
    /// on every foreground transition rather than trusting a stale listener.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if isEnabled { startListener(restart: true) }
        case .background:
            stopListener()
        default:
            break
        }
    }

    func regeneratePassword() {
        let newPassword = Self.makePassword()
        guard Self.savePassword(newPassword) else {
            lastError = "Could not save the new password to Keychain."
            return
        }
        password = newPassword
        if isEnabled { startListener(restart: true) }
    }

    func copyEndpoint() {
        guard let endpointURL else { return }
        UIPasteboard.general.string = endpointURL
    }

    func copyPassword() {
        UIPasteboard.general.string = password
    }

    // MARK: - Listener

    private func startListener(restart: Bool = false) {
        let password = self.password
        let root = AIChatViewModel.minisSharedPersistentDir
        listenerQueue.async { [weak self] in
            guard let self else { return }
            if restart { self.closeListenerLocked() }
            guard self.listenSocket < 0 else { return }

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                self.publish(error: "Could not create the WebDAV listener.")
                return
            }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Self.port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else {
                let code = errno
                close(fd)
                self.publish(error: "Could not start WebDAV on port \(Self.port) (errno \(code)).")
                return
            }

            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.listenSocket = fd
            self.shouldListen = true
            let endpoint = Self.localIPv4Address().map { "http://\($0):\(Self.port)/" }
            self.publish(running: true, endpoint: endpoint, error: nil)
            self.acceptQueue.async { [weak self] in
                self?.acceptLoop(socket: fd, root: root, password: password)
            }
        }
    }

    private func stopListener() {
        listenerQueue.async { [weak self] in
            self?.shouldListen = false
            self?.closeListenerLocked()
            self?.publish(running: false, endpoint: nil, error: nil)
        }
    }

    private func closeListenerLocked() {
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }

    private func acceptLoop(socket: Int32, root: URL, password: String) {
        while shouldListen, listenSocket == socket {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(socket, $0, &length)
                }
            }
            if client < 0 {
                if !shouldListen || listenSocket != socket || errno == EBADF || errno == EINVAL { break }
                if errno != EINTR { usleep(50_000) }
                continue
            }
            let peerAddress = peer.sin_addr.s_addr.bigEndian
            connectionQueue.async {
                Self.handleConnection(client, peerAddress: peerAddress, root: root, password: password)
            }
        }
    }

    private func publish(running: Bool? = nil, endpoint: String? = nil, error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let running { self.isRunning = running }
            if running == false || endpoint != nil { self.endpointURL = endpoint }
            self.lastError = error
        }
    }

    // MARK: - HTTP / WebDAV

    private struct Request {
        let method: String
        let target: String
        let headers: [String: String]
        let bodyPrefix: Data
    }

    private static func handleConnection(_ fd: Int32, peerAddress: UInt32, root: URL, password: String) {
        defer { close(fd) }
        guard isPrivateIPv4(peerAddress) else {
            send(fd, status: "403 Forbidden", body: Data("Local-network clients only.\n".utf8))
            return
        }
        guard let request = readRequest(fd) else {
            send(fd, status: "400 Bad Request", body: Data())
            return
        }
        guard isAuthorized(request.headers["authorization"], password: password) else {
            send(fd, status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Minis Shared\""], body: Data())
            return
        }
        guard let components = pathComponents(from: request.target) else {
            send(fd, status: "400 Bad Request", body: Data("Invalid path.\n".utf8))
            return
        }
        let url = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        switch request.method {
        case "OPTIONS":
            send(fd, status: "200 OK", headers: davHeaders, body: Data())
        case "PROPFIND":
            propfind(fd, root: root, url: url, components: components, depth: request.headers["depth"] ?? "infinity")
        case "GET", "HEAD":
            get(fd, url: url, headOnly: request.method == "HEAD")
        case "PUT":
            put(fd, request: request, destination: url)
        case "MKCOL":
            mkcol(fd, destination: url)
        case "DELETE":
            delete(fd, url: url, isRoot: components.isEmpty)
        case "MOVE", "COPY":
            moveOrCopy(fd, request: request, root: root, source: url, sourceIsRoot: components.isEmpty, copy: request.method == "COPY")
        case "LOCK":
            lock(fd, url: url)
        case "UNLOCK":
            send(fd, status: "204 No Content", headers: davHeaders, body: Data())
        default:
            send(fd, status: "405 Method Not Allowed", headers: davHeaders, body: Data())
        }
    }

    private static let davHeaders = [
        "DAV": "1, 2",
        "MS-Author-Via": "DAV",
        "Allow": "OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK"
    ]

    private static func propfind(_ fd: Int32, root: URL, url: URL, components: [String], depth: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            send(fd, status: "404 Not Found", body: Data())
            return
        }
        var urls = [url]
        if isDirectory.boolValue, depth.lowercased() != "0" {
            urls += (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<D:multistatus xmlns:D=\"DAV:\">\r\n"
            + urls.map { propertyResponse(for: $0, root: root) }.joined()
            + "</D:multistatus>\r\n"
        send(fd, status: "207 Multi-Status", headers: davHeaders.merging(["Content-Type": "application/xml; charset=utf-8"], uniquingKeysWith: { _, new in new }), body: Data(body.utf8))
    }

    private static func propertyResponse(for url: URL, root: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let isDirectory = values?.isDirectory ?? false
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate ?? .distantPast
        let created = values?.creationDate ?? modified
        let relative = url.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = relative.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let href = "/" + encoded + (isDirectory && !encoded.isEmpty ? "/" : "")
        let resourceType = isDirectory ? "<D:collection/>" : ""
        let etag = "\"\(size)-\(Int(modified.timeIntervalSince1970))\""
        return """
        <D:response><D:href>\(xml(href))</D:href><D:propstat><D:prop><D:resourcetype>\(resourceType)</D:resourcetype><D:getcontentlength>\(size)</D:getcontentlength><D:getlastmodified>\(httpDate(modified))</D:getlastmodified><D:creationdate>\(isoDate(created))</D:creationdate><D:getetag>\(etag)</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\r\n
        """
    }

    private static func get(_ fd: Int32, url: URL, headOnly: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            send(fd, status: "404 Not Found", body: Data())
            return
        }
        guard !isDirectory.boolValue, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? NSNumber else {
            send(fd, status: "405 Method Not Allowed", body: Data())
            return
        }
        let headers = ["Content-Type": "application/octet-stream", "Content-Length": size.stringValue, "Accept-Ranges": "bytes", "Connection": "close"]
        sendHeader(fd, status: "200 OK", headers: headers)
        guard !headOnly, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard sendAll(fd, chunk) else { return }
        }
    }

    private static func put(_ fd: Int32, request: Request, destination: URL) {
        guard let rawLength = request.headers["content-length"], let length = Int(rawLength), length >= 0 else {
            send(fd, status: "411 Length Required", body: Data())
            return
        }
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            send(fd, status: "409 Conflict", body: Data())
            return
        }
        let existed = FileManager.default.fileExists(atPath: destination.path)
        let temporary = parent.appendingPathComponent(".webdav-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil), let handle = try? FileHandle(forWritingTo: temporary) else {
            send(fd, status: "507 Insufficient Storage", body: Data())
            return
        }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        var remaining = length
        let prefix = request.bodyPrefix.prefix(length)
        do {
            try handle.write(contentsOf: prefix)
            remaining -= prefix.count
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(remaining, 1)))
            while remaining > 0 {
                let count = read(fd, &buffer, min(buffer.count, remaining))
                guard count > 0 else { send(fd, status: "400 Bad Request", body: Data()); return }
                try handle.write(contentsOf: Data(buffer.prefix(Int(count))))
                remaining -= Int(count)
            }
            try handle.close()
            if existed {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            send(fd, status: existed ? "204 No Content" : "201 Created", headers: davHeaders, body: Data())
        } catch {
            send(fd, status: "507 Insufficient Storage", body: Data())
        }
    }

    private static func mkcol(_ fd: Int32, destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            send(fd, status: "405 Method Not Allowed", body: Data())
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            send(fd, status: "201 Created", headers: davHeaders, body: Data())
        } catch {
            send(fd, status: "409 Conflict", body: Data())
        }
    }

    private static func delete(_ fd: Int32, url: URL, isRoot: Bool) {
        guard !isRoot else { send(fd, status: "403 Forbidden", body: Data()); return }
        guard FileManager.default.fileExists(atPath: url.path) else { send(fd, status: "404 Not Found", body: Data()); return }
        do {
            try FileManager.default.removeItem(at: url)
            send(fd, status: "204 No Content", headers: davHeaders, body: Data())
        } catch {
            send(fd, status: "403 Forbidden", body: Data())
        }
    }

    private static func moveOrCopy(_ fd: Int32, request: Request, root: URL, source: URL, sourceIsRoot: Bool, copy: Bool) {
        guard !sourceIsRoot, FileManager.default.fileExists(atPath: source.path), let destinationHeader = request.headers["destination"], let components = pathComponents(fromDestination: destinationHeader) else {
            send(fd, status: "400 Bad Request", body: Data())
            return
        }
        let destination = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        guard destination != source else { send(fd, status: "403 Forbidden", body: Data()); return }
        let overwrite = request.headers["overwrite"]?.uppercased() != "F"
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        guard overwrite || !destinationExists else { send(fd, status: "412 Precondition Failed", body: Data()); return }
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            send(fd, status: "409 Conflict", body: Data())
            return
        }
        do {
            if destinationExists { try FileManager.default.removeItem(at: destination) }
            if copy { try FileManager.default.copyItem(at: source, to: destination) }
            else { try FileManager.default.moveItem(at: source, to: destination) }
            send(fd, status: destinationExists ? "204 No Content" : "201 Created", headers: davHeaders, body: Data())
        } catch {
            send(fd, status: "403 Forbidden", body: Data())
        }
    }

    private static func lock(_ fd: Int32, url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { send(fd, status: "404 Not Found", body: Data()); return }
        let token = "opaquelocktoken:\(UUID().uuidString)"
        let body = "<?xml version=\"1.0\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>Infinity</D:depth><D:timeout>Second-3600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>"
        send(fd, status: "200 OK", headers: davHeaders.merging(["Lock-Token": "<\(token)>", "Content-Type": "application/xml; charset=utf-8"], uniquingKeysWith: { _, new in new }), body: Data(body.utf8))
    }

    // MARK: - HTTP helpers

    private static func readRequest(_ fd: Int32) -> Request? {
        // Match the byte-at-a-time framing used by the app's proven debug
        // listener. In particular this avoids a rare iOS USB-forwarding case
        // where recv() can block after the complete header is already queued.
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            let count = read(fd, &byte, 1)
            guard count == 1 else { return nil }
            data.append(byte)
            if data.count >= 4, data.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) { break }
        }
        guard data.count >= 4,
              let header = String(data: data.dropLast(4), encoding: .utf8) else { return nil }
        var lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " ", maxSplits: 2).map(String.init), first.count >= 2 else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return Request(method: first[0].uppercased(), target: first[1], headers: headers, bodyPrefix: Data())
    }

    private static func isAuthorized(_ header: String?, password: String) -> Bool {
        guard let header, header.lowercased().hasPrefix("basic "), let data = Data(base64Encoded: String(header.dropFirst(6))), let received = String(data: data, encoding: .utf8) else { return false }
        return received == "\(username):\(password)"
    }

    private static func pathComponents(from target: String) -> [String]? {
        let raw = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return safePathComponents(raw)
    }

    private static func pathComponents(fromDestination value: String) -> [String]? {
        if let components = URLComponents(string: value), components.scheme != nil {
            return safePathComponents(components.percentEncodedPath)
        }
        return safePathComponents(value)
    }

    private static func safePathComponents(_ rawPath: String) -> [String]? {
        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        var result: [String] = []
        for raw in rawComponents {
            guard let decoded = String(raw).removingPercentEncoding,
                  !decoded.isEmpty, decoded != ".", decoded != "..", !decoded.contains("/") else { return nil }
            result.append(decoded)
        }
        return result
    }

    private static func send(_ fd: Int32, status: String, headers: [String: String] = [:], body: Data) {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        sendHeader(fd, status: status, headers: allHeaders)
        if !body.isEmpty { _ = sendAll(fd, body) }
    }

    private static func sendHeader(_ fd: Int32, status: String, headers: [String: String]) {
        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { response += "\(key): \(value)\r\n" }
        response += "\r\n"
        _ = sendAll(fd, Data(response.utf8))
    }

    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            while sent < data.count {
                let count = write(fd, base.advanced(by: sent), data.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let first = (address >> 24) & 0xff
        let second = (address >> 16) & 0xff
        return first == 10 || first == 127 || first == 192 && second == 168 || first == 172 && (16...31).contains(second) || first == 169 && second == 254
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("pdp_ip") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Keychain password

    private static let keychainService = "com.1agents.phone.shared-webdav"
    private static let keychainAccount = "password"

    private static func loadOrCreatePassword() -> String {
        if let existing = loadPassword() { return existing }
        let password = makePassword()
        _ = savePassword(password)
        return password
    }

    private static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func savePassword(_ value: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let update = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func makePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Settings UI

struct SharedFolderWebDAVSettingsView: View {
    @ObservedObject private var server = SharedFolderWebDAVServer.shared

    var body: some View {
        List {
            Section {
                Toggle("Share with Mac on local network", isOn: Binding(
                    get: { server.isEnabled },
                    set: { $0 ? server.enable() : server.disable() }
                ))
                Text("Only /var/minis/shared is exposed. Minis must stay open in the foreground while your Mac is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if server.isEnabled {
                Section("Finder connection") {
                    LabeledContent("Server") {
                        Text(server.endpointURL ?? "Starting…")
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Username") { Text(SharedFolderWebDAVServer.username).textSelection(.enabled) }
                    LabeledContent("Password") { Text(server.password).font(.caption.monospaced()).textSelection(.enabled) }
                    Button("Copy server address") { server.copyEndpoint() }
                        .disabled(server.endpointURL == nil)
                    Button("Copy password") { server.copyPassword() }
                    Button("Generate new password", role: .destructive) { server.regeneratePassword() }
                    Text("In Finder choose Go → Connect to Server, enter the server address, then sign in with the username and password above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = server.lastError {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Mac Shared Folder")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
/// A deliberately read-only diagnostic for inspecting the shared folder from
/// Xcode's device console. It is invoked only by an explicit launch argument
/// and never exposes a network endpoint or mutates user files.
enum SharedFolderReadOnlyInspector {
    private static let maximumTextBytes = 512 * 1024
    private static let maximumPreviewBytes = 8 * 1024
    private static let maximumReportedFiles = 100

    static func run(terms: [String]) {
        let root = AIChatViewModel.minisSharedPersistentDir.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("[SharedInspector] shared folder is not present: \(root.path)")
            return
        }

        print("[SharedInspector] scanning shared folder for: \(terms.joined(separator: ", "))")
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var matches = 0
        while let url = urls?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: maximumTextBytes)) ?? Data()
            try? handle.close()
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let matchingTerms = terms.filter { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            guard !matchingTerms.isEmpty else { continue }

            matches += 1
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let size = values.fileSize ?? 0
            let snippet = snippet(from: text, for: matchingTerms[0])
            print("[SharedInspector] match path=\(relativePath) size=\(size) terms=\(matchingTerms.joined(separator: ",")) snippet=\(snippet)")
            if matches >= maximumReportedFiles {
                print("[SharedInspector] stopped after \(maximumReportedFiles) matching files.")
                break
            }
        }
        print("[SharedInspector] completed: \(matches) matching files.")
    }

    /// Finds one matching text file using the same read-only enumeration as
    /// `run(terms:)`, then prints a bounded preview for console inspection.
    static func previewFirstMatch(terms: [String]) {
        let root = AIChatViewModel.minisSharedPersistentDir.standardizedFileURL
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = urls?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: maximumPreviewBytes)) ?? Data()
            try? handle.close()
            guard let text = String(data: data, encoding: .utf8),
                  terms.contains(where: { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let suffix = data.count == maximumPreviewBytes ? "\n[SharedInspector] preview truncated at \(maximumPreviewBytes) bytes." : ""
            print("[SharedInspector] preview path=\(relativePath)\n\(text)\(suffix)")
            return
        }
        print("[SharedInspector] no matching text file found for preview.")
    }

    /// Prints a bounded, textual preview of one user-specified file. The path
    /// must be relative to `shared`; traversal components are rejected.
    static func preview(relativePath: String) {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            print("[SharedInspector] rejected invalid preview path.")
            return
        }
        let root = AIChatViewModel.minisSharedPersistentDir.standardizedFileURL
        let url = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        let pathSuffix = "/" + components.joined(separator: "/")
        var target = url
        var isDirectory: ObjCBool = false
        // The app group root is initialized shortly after a cold app launch.
        // Wait briefly rather than reporting a false negative to the console.
        var found = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        for _ in 0..<20 where !found {
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]),
               let resolved = enumerator.compactMap({ $0 as? URL }).first(where: { $0.path.hasSuffix(pathSuffix) }) {
                target = resolved
                found = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
                if found { break }
            }
            Thread.sleep(forTimeInterval: 0.25)
            found = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        }
        guard found, !isDirectory.boolValue else {
            print("[SharedInspector] preview file not found: \(relativePath)")
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: target) else {
            print("[SharedInspector] preview file could not be opened: \(relativePath)")
            return
        }
        let data = (try? handle.read(upToCount: maximumPreviewBytes)) ?? Data()
        try? handle.close()
        guard let text = String(data: data, encoding: .utf8) else {
            print("[SharedInspector] preview is not UTF-8 text: \(relativePath)")
            return
        }
        let suffix = data.count == maximumPreviewBytes ? "\n[SharedInspector] preview truncated at \(maximumPreviewBytes) bytes." : ""
        print("[SharedInspector] preview path=\(relativePath)\n\(text)\(suffix)")
    }

    private static func snippet(from text: String, for term: String) -> String {
        guard let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return "" }
        let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
#endif
