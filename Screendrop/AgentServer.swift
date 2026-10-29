//
//  AgentServer.swift
//  Screendrop
//
//  The app side of the agent (MCP) server. Listens on a Unix socket only
//  this user can open, speaks JSON-RPC 2.0 framed as one message per line,
//  and hands tool calls to `AgentTools` on the main actor, where the Studio
//  models live. Each request runs in its own task so a long export never
//  blocks a status check, and `notifications/cancelled` cancels it.
//

import Darwin
import Foundation
import OSLog

@MainActor
final class AgentServer {
    static let shared = AgentServer()

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private static let logger = Logger(subsystem: "com.fayazahmed.Screendrop", category: "AgentServer")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: AgentConnection] = [:]

    private init() {}

    var isRunning: Bool { listenFD >= 0 }

    /// Starts or stops listening to match the setting.
    func updateForPreference() {
        if ScreendropPreferences.agentServerEnabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard listenFD < 0 else { return }
        let url = AgentSocket.url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A socket file left by a crash refuses the bind; nobody is behind it.
        unlink(url.path)

        guard var address = AgentSocket.address(for: url.path) else {
            Self.logger.error("Agent socket path is too long")
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        // Created owner-only, so no other account on this Mac can connect.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0, listen(fd, 8) == 0 else {
            Self.logger.error("Agent socket bind failed errno=\(errno)")
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        Self.logger.info("Agent server listening")
    }

    func stop() {
        guard listenFD >= 0 else { return }
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(AgentSocket.url.path)
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // Same-user check on top of the file mode, in case the socket's
            // directory permissions were ever loosened.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(client)
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            let connection = AgentConnection(fd: client)
            let key = ObjectIdentifier(connection)
            let session = AgentSession(connection: connection)
            connection.onMessage = { message in
                Task { @MainActor in session.handle(message) }
            }
            connection.onClose = {
                Task { @MainActor in
                    session.cancelAll()
                    AgentServer.shared.connections.removeValue(forKey: key)
                }
            }
            connections[key] = connection
            connection.start()
        }
    }
}

/// One client's socket: reads lines off the main thread and writes
/// replies in order on its own queue.
nonisolated final class AgentConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.fayazahmed.Screendrop.agent-connection")
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var isClosed = false

    var onMessage: (@Sendable (JSONValue) -> Void)?
    var onClose: (@Sendable () -> Void)?

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        readSource = source
    }

    func send(_ message: JSONValue) {
        guard let data = try? message.encodedLine() else { return }
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            // The socket is non-blocking for reads; flip it for the
            // duration of a write so a large image reply goes out whole.
            let flags = fcntl(self.fd, F_GETFL)
            _ = fcntl(self.fd, F_SETFL, flags & ~O_NONBLOCK)
            let ok = AgentSocket.writeAll(data, to: self.fd)
            _ = fcntl(self.fd, F_SETFL, flags)
            if !ok { self.closeOnQueue() }
        }
    }

    func close() {
        queue.async { [weak self] in self?.closeOnQueue() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            closeOnQueue()
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let message = try? JSONValue.decoder.decode(JSONValue.self, from: Data(line)) {
                onMessage?(message)
            } else {
                send(AgentSession.errorResponse(id: .null, code: -32700, message: "Parse error"))
            }
        }
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onClose?()
    }
}

/// The JSON-RPC conversation with one client.
@MainActor
final class AgentSession {
    private let connection: AgentConnection
    private var tasks: [JSONValue: Task<Void, Never>] = [:]

    init(connection: AgentConnection) {
        self.connection = connection
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func handle(_ message: JSONValue) {
        guard let method = message["method"]?.stringValue else {
            // A response to something we never send; nothing to do.
            return
        }
        let params = message["params"] ?? [:]
        guard let id = message["id"] else {
            handleNotification(method, params: params)
            return
        }

        switch method {
        case "initialize":
            reply(id, result: initializeResult(params))
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": .array(AgentTools.definitions)])
        case "resources/list":
            reply(id, result: ["resources": []])
        case "resources/templates/list":
            reply(id, result: ["resourceTemplates": []])
        case "prompts/list":
            reply(id, result: ["prompts": []])
        case "tools/call":
            callTool(id: id, params: params)
        default:
            connection.send(Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func handleNotification(_ method: String, params: JSONValue) {
        if method == "notifications/cancelled", let requestID = params["requestId"] {
            tasks.removeValue(forKey: requestID)?.cancel()
        }
    }

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = AgentServer.protocolVersions.contains(requested)
            ? requested
            : AgentServer.protocolVersions[0]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "screendrop", "title": "Screendrop", "version": .string(appVersion)],
            "instructions": .string(AgentTools.instructions),
        ]
    }

    private func callTool(id: JSONValue, params: JSONValue) {
        let name = params["name"]?.stringValue ?? ""
        let arguments = params["arguments"] ?? [:]
        let progressToken = params["_meta"]?["progressToken"]
        let connection = connection
        let progress: AgentProgress = { fraction, message in
            guard let progressToken else { return }
            var params: [String: JSONValue] = [
                "progressToken": progressToken,
                "progress": .number(fraction),
                "total": 1,
            ]
            if let message { params["message"] = .string(message) }
            connection.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": .object(params)])
        }

        tasks[id] = Task { [weak self] in
            let result: JSONValue
            do {
                let content = try await AgentTools.call(name, arguments: arguments, progress: progress)
                result = ["content": .array(content)]
            } catch is CancellationError {
                result = Self.toolError("Cancelled.")
            } catch {
                // Tool failures go back as results, not protocol errors, so
                // the model reads the reason and can correct itself.
                result = Self.toolError(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            self?.reply(id, result: result)
            self?.tasks.removeValue(forKey: id)
        }
    }

    private func reply(_ id: JSONValue, result: JSONValue) {
        connection.send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func toolError(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    nonisolated static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}

typealias AgentProgress = @MainActor (_ fraction: Double, _ message: String?) -> Void
