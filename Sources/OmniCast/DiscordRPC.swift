import Foundation

/// One connection to a running Discord client's local RPC socket
/// ($TMPDIR/discord-ipc-N). Frames are [opcode u32 LE][length u32 LE][JSON].
/// Reads run on their own thread; `onMessage` and `onClose` are called on main.
final class DiscordIPC: @unchecked Sendable {
    enum Opcode: UInt32 { case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4 }

    let path: String
    var onMessage: (([String: Any]) -> Void)?
    var onClose: ((String) -> Void)?

    private var fd: Int32 = -1
    private let writeLock = NSLock()

    init(path: String) { self.path = path }

    /// Paths of every Discord client listening on this Mac (Discord, Canary, PTB…).
    static func socketPaths() -> [String] {
        let tmp = NSTemporaryDirectory()
        return (0..<10).map { tmp + "discord-ipc-\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    func connect() -> Bool {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { close(); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { _ = strcpy($0, path) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(); return false }
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "Discord IPC"
        thread.start()
        return true
    }

    func send(_ op: Opcode, _ payload: [String: Any]) {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var header = Data(count: 8)
        header.withUnsafeMutableBytes {
            $0.storeBytes(of: op.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: UInt32(body.count).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        let frame = header + body
        writeLock.lock()
        defer { writeLock.unlock() }
        frame.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        let fd = self.fd
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            while got < count {
                let n = read(fd, buf.baseAddress! + got, count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? data : nil
    }

    private func readLoop() {
        var reason = "Discord closed the connection"
        while fd >= 0, let header = readExactly(8) {
            let op = header.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: 0, as: UInt32.self)) }
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.load(fromByteOffset: 4, as: UInt32.self))) }
            guard length < 4_000_000, let body = readExactly(length) else { break }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch Opcode(rawValue: op) {
            case .ping: send(.pong, json)
            case .close:
                reason = json["message"] as? String ?? reason
                close()
            default:
                DispatchQueue.main.async { [weak self] in self?.onMessage?(json) }
            }
        }
        close()
        DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
    }
}
