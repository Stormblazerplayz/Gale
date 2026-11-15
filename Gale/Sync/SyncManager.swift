import Combine
import Foundation
import GaleFormat
import GaleSync
import UIKit

/// Keeps open projects in step with the Gale desktop app, live, over home Wi-Fi.
@MainActor
final class SyncManager: ObservableObject {
    enum Status: Equatable {
        case notPaired
        case connecting
        case connected
        case offline(String)
    }

    struct Hub: Codable, Equatable {
        var host: String
        var port: Int
        var token: String
        var serverID: String
        var serverName: String
    }

    @Published private(set) var status: Status = .notPaired
    @Published private(set) var hub: Hub?
    @Published private(set) var hubProjects: [HubProject] = []
    @Published var lastError: String?

    let deviceID: String
    let deviceName: String
    private var clock: HybridClock
    private var socket: URLSessionWebSocketTask?
    private var session = URLSession(configuration: .default)
    private var attached: [String: Attachment] = [:]
    private weak var library: ProjectLibrary?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var backoff: Double = 1

    /// One open project being synced.
    final class Attachment {
        let document: ProjectDocument
        var replica: SyncReplica
        var state: SavedState
        var subscribed = false

        init(document: ProjectDocument, replica: SyncReplica, state: SavedState) {
            self.document = document
            self.replica = replica
            self.state = state
        }
    }

    /// What we remember per project between launches: the hub's last count and edits not sent yet.
    struct SavedState: Codable {
        var seq: Int = 0
        var pending: [String: [SyncOp]] = [:]
    }

    init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "gale.sync.deviceID") {
            deviceID = id
        } else {
            let kind = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            let id = kind + "-" + String(GaleID.make().prefix(8))
            defaults.set(id, forKey: "gale.sync.deviceID")
            deviceID = id
        }
        deviceName = UIDevice.current.name
        clock = HybridClock(actor: deviceID)
        if let data = defaults.data(forKey: "gale.sync.hub"), let h = try? JSONDecoder().decode(Hub.self, from: data) {
            hub = h
            status = .connecting
        }
    }

    func start(library: ProjectLibrary) {
        self.library = library
        if hub != nil { connect() }
    }

    // MARK: Pairing

    /// A gale://pair link from the QR code (scanned in the Camera app or inside Gale).
    func handle(url: URL) {
        guard let info = PairingInfo(url: url) else { return }
        Task { await pair(info) }
    }

    @discardableResult
    func pair(_ info: PairingInfo) async -> Bool {
        lastError = nil
        guard let url = URL(string: "http://\(hostForURL(info.host)):\(info.port)/api/v1/pair") else {
            lastError = "That computer address doesn't look right."
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": info.code, "deviceId": deviceID, "deviceName": deviceName])
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["token"] as? String else {
                lastError = http.statusCode == 403 || http.statusCode == 401
                    ? "That code didn't work. Make a new one on your computer and try again."
                    : "Your computer said no (\(http.statusCode))."
                return false
            }
            let h = Hub(host: info.host, port: info.port, token: token,
                        serverID: obj["serverId"] as? String ?? info.serverID,
                        serverName: obj["serverName"] as? String ?? info.name)
            hub = h
            if let data = try? JSONEncoder().encode(h) { UserDefaults.standard.set(data, forKey: "gale.sync.hub") }
            connect()
            return true
        } catch {
            lastError = "Couldn't reach your computer. Make sure Gale is open on it and you're on the same Wi-Fi."
            return false
        }
    }

    func unpair() {
        disconnect()
        hub = nil
        hubProjects = []
        status = .notPaired
        UserDefaults.standard.removeObject(forKey: "gale.sync.hub")
    }

    private func hostForURL(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    // MARK: Connection

    func connect() {
        guard let hub else { status = .notPaired; return }
        disconnect()
        status = .connecting
        var c = URLComponents()
        c.scheme = "ws"
        c.host = hub.host
        c.port = hub.port
        c.path = "/api/v1/sync"
        c.queryItems = [URLQueryItem(name: "token", value: hub.token)]
        guard let url = c.url else { status = .offline("Bad address"); return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(hub.token)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws
        ws.resume()
        receive(on: ws)
        send(.hello(deviceId: deviceID, deviceName: deviceName, since: [:]))
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.send(.ping)
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        pingTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for a in attached.values { a.subscribed = false }
    }

    private func scheduleReconnect(_ why: String) {
        guard hub != nil else { return }
        socket = nil
        pingTask?.cancel()
        for a in attached.values { a.subscribed = false }
        status = .offline(why)
        reconnectTask?.cancel()
        let delay = backoff
        backoff = min(30, backoff * 2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func receive(on ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === ws else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect("Can't reach \(self.hub?.serverName ?? "your computer")")
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = nil
                    }
                    if let data, let msg = SyncMessage.decode(data) { self.handle(msg) }
                    self.receive(on: ws)
                }
            }
        }
    }

    private func send(_ message: SyncMessage) {
        guard let ws = socket, let data = try? message.encoded() else { return }
        ws.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.scheduleReconnect("Lost the connection") }
            }
        }
    }

    private func handle(_ message: SyncMessage) {
        switch message {
        case .welcome(_, let name, let projects):
            backoff = 1
            status = .connected
            hubProjects = projects
            if var h = hub, h.serverName != name, !name.isEmpty {
                h.serverName = name
                hub = h
            }
            for id in attached.keys { subscribe(id) }
        case .projects(let projects):
            hubProjects = projects
        case .ops(let p, let ops, let seq):
            guard let a = attached[p] else { return }
            for op in ops { clock.observe(op.t) }
            let won = a.replica.apply(ops)
            a.state.seq = max(a.state.seq, seq)
            if !won.isEmpty, var built = a.replica.project {
                built.modified = Date()
                a.document.applyRemote(built)
                fetchMissingMedia(a)
            }
            save(a)
        case .ack(let ref, let seq):
            for a in attached.values where a.state.pending[ref] != nil {
                a.state.pending[ref] = nil
                a.state.seq = max(a.state.seq, seq)
                save(a)
            }
        case .ping:
            send(.pong)
        default:
            break
        }
    }

    // MARK: Projects

    func attach(_ document: ProjectDocument) {
        let id = document.project.id
        let state = loadState(document.folder)
        // Everything already here counts as very old, so anything newer from the computer wins.
        let base = HybridClock.format(ms: 0, counter: 0, actor: deviceID)
        let a = Attachment(document: document, replica: SyncReplica(project: document.project, stamp: base), state: state)
        attached[id] = a
        document.onLocalChange = { [weak self, weak a] before, after in
            guard let self, let a else { return }
            let ops = SyncObjects.diff(SyncObjects.flatten(before), SyncObjects.flatten(after), clock: &self.clock)
            guard !ops.isEmpty else { return }
            a.replica.apply(ops)
            let ref = GaleID.make()
            a.state.pending[ref] = ops
            self.save(a)
            if a.subscribed { self.send(.push(p: id, ops: ops, ref: ref)) }
            self.uploadMedia(a)
        }
        if status == .connected { subscribe(id) }
    }

    func detach(_ document: ProjectDocument) {
        let id = document.project.id
        guard let a = attached[id], a.document === document else { return }
        save(a)
        document.onLocalChange = nil
        attached[id] = nil
    }

    private func subscribe(_ id: String) {
        guard let a = attached[id] else { return }
        send(.subscribe(p: id, since: a.state.seq))
        a.subscribed = true
        if a.state.seq == 0 {
            // First time: give the computer the whole project. Its own newer values still win.
            let ref = "seed-" + GaleID.make()
            let ops = a.replica.allOps
            a.state.pending[ref] = ops
            send(.push(p: id, ops: ops, ref: ref))
        }
        for (ref, ops) in a.state.pending where !ref.hasPrefix("seed-") || a.state.seq != 0 {
            send(.push(p: id, ops: ops, ref: ref))
        }
        save(a)
        uploadMedia(a)
    }

    /// Downloads a project that only lives on the computer so far.
    func download(_ item: HubProject) async -> URL? {
        guard let hub, let library,
              let url = URL(string: "http://\(hostForURL(hub.host)):\(hub.port)/api/v1/projects/\(item.id)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Bearer \(hub.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            var project = try GaleIO.decode(GaleProject.self, from: data)
            project.normalize()
            let folder = try library.importProject(project)
            for m in project.media where !m.sha256.isEmpty {
                await fetchBlob(m, into: folder)
            }
            return folder
        } catch {
            lastError = "Couldn't get that project from your computer."
            return nil
        }
    }

    // MARK: Media files

    private func blobURL(_ sha: String) -> URL? {
        guard let hub else { return nil }
        return URL(string: "http://\(hostForURL(hub.host)):\(hub.port)/api/v1/blobs/\(sha)")
    }

    private func uploadMedia(_ a: Attachment) {
        let items = a.document.project.media.filter { !$0.sha256.isEmpty }
        guard !items.isEmpty, let token = hub?.token else { return }
        let folder = a.document.folder
        for m in items {
            guard let url = blobURL(m.sha256) else { continue }
            let file = GaleIO.mediaURL(m, in: folder)
            Task {
                var head = URLRequest(url: url)
                head.httpMethod = "HEAD"
                head.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let res = try? await self.session.data(for: head), (res.1 as? HTTPURLResponse)?.statusCode == 200 { return }
                var put = URLRequest(url: url, timeoutInterval: 300)
                put.httpMethod = "PUT"
                put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                _ = try? await self.session.upload(for: put, fromFile: file)
            }
        }
    }

    private func fetchMissingMedia(_ a: Attachment) {
        let folder = a.document.folder
        for m in a.document.project.media where !m.sha256.isEmpty {
            if FileManager.default.fileExists(atPath: GaleIO.mediaURL(m, in: folder).path) { continue }
            Task { await fetchBlob(m, into: folder) }
        }
    }

    private func fetchBlob(_ m: MediaItem, into folder: URL) async {
        guard let url = blobURL(m.sha256), let token = hub?.token else { return }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let res = try? await session.download(for: req), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return }
        let tmp = res.0
        let dest = GaleIO.mediaURL(m, in: folder)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: tmp, to: dest)
    }

    // MARK: Saved state

    private func stateURL(_ folder: URL) -> URL { folder.appendingPathComponent(".sync.json") }

    private func loadState(_ folder: URL) -> SavedState {
        guard let hub, let data = try? Data(contentsOf: stateURL(folder)),
              let saved = try? JSONDecoder().decode([String: SavedState].self, from: data) else { return SavedState() }
        return saved[hub.serverID] ?? SavedState()
    }

    private func save(_ a: Attachment) {
        guard let hub else { return }
        let url = stateURL(a.document.folder)
        var all = (try? JSONDecoder().decode([String: SavedState].self, from: Data(contentsOf: url))) ?? [:]
        all[hub.serverID] = a.state
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }
}
