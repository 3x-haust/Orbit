import AppKit
import Darwin

/// One owner per login account, even for app copies and `open -n`.
/// Hold the OS lock until exit (crashes release it too); never unlink the file.
@MainActor
enum OrbitInstance {
    private static var descriptor: Int32 = -1
    private static var observer: NSObjectProtocol?
    private static let reopen = Notification.Name("com.lyu.orbit.reopen")
    private static let reopened = Notification.Name("com.lyu.orbit.reopened")
    private static var handled: [String] = []
    static var ready = false

    private static func acquire() throws -> Int32? {
        let fm = FileManager.default
        let directory = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Orbit", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        let fd = openat(dir, "instance.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    static func claim() throws -> Bool {
        if descriptor >= 0 { return true }
        let center = DistributedNotificationCenter.default()
        if observer == nil {
            observer = center.addObserver(forName: reopen, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard descriptor >= 0, ready, let request = note.object as? String else { return }
                    if !handled.contains(request) {
                        let urls = (note.userInfo?["urls"] as? [String] ?? []).compactMap { URL(string: $0) }.filter(\.isFileURL)
                        if urls.isEmpty { MainWindow.show() } else { Archives.shared.open(urls) }
                        handled.append(request)
                        if handled.count > 256 { handled.removeFirst() }
                    }
                    center.postNotificationName(reopened, object: request, userInfo: nil, deliverImmediately: true)
                }
            }
        }
        guard let fd = try acquire() else { return false }
        descriptor = fd
        return true
    }

    #if DEBUG
    static func rejectsSecondLock() throws -> Bool {
        guard let probe = try acquire() else { return true }
        close(probe)
        return false
    }
    #endif

    /// Acknowledge delivery, take over after owner exit, or fail explicitly after five seconds.
    static func handoff(urls: [URL], completion: @escaping (Result<Bool, Error>) -> Void) {
        let center = DistributedNotificationCenter.default()
        let request = UUID().uuidString
        var finished = false
        var token: NSObjectProtocol?
        func finish(_ result: Result<Bool, Error>) {
            guard !finished else { return }
            finished = true
            if let token { center.removeObserver(token) }
            completion(result)
        }
        token = center.addObserver(forName: reopened, object: request, queue: .main) { _ in
            MainActor.assumeIsolated { finish(.success(false)) }
        }
        func attempt(_ remaining: Int) {
            guard !finished else { return }
            do { if try claim() { finish(.success(true)); return } }
            catch { finish(.failure(error)); return }
            center.postNotificationName(reopen, object: request, userInfo: ["urls": urls.filter(\.isFileURL).map(\.absoluteString)], deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !finished else { return }
                if remaining > 0 { attempt(remaining - 1) }
                else { finish(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)))) }
            }
        }
        attempt(9)
    }
}
