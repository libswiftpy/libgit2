//
//  NetworkStream.swift
//  SwiftPyGit
//

import Foundation
import Network
@preconcurrency import libgit2

/// libgit2's plain and TLS streams over `NWConnection`, for an App Clip,
/// which can't open the POSIX sockets libgit2's own streams use. libgit2
/// calls them on its worker thread, which each one blocks until done.
enum NetworkStream {
    static let connectTimeout: TimeInterval = 30
    /// For data either way; libgit2's own streams wait forever by default.
    static let timeout: TimeInterval = 60

    static func register() {
        var plain = git_stream_registration()
        plain.version = GIT_STREAM_VERSION
        plain.`init` = { out, host, port in NetworkStream.make(out, host, port, tls: false) }
        var tls = plain
        tls.`init` = { out, host, port in NetworkStream.make(out, host, port, tls: true) }
        git_stream_register(GIT_STREAM_STANDARD, &plain)
        git_stream_register(GIT_STREAM_TLS, &tls)
    }

    private static func make(_ out: UnsafeMutablePointer<UnsafeMutablePointer<git_stream>?>?, _ host: UnsafePointer<CChar>?, _ port: UnsafePointer<CChar>?, tls: Bool) -> Int32 {
        guard let out, let host, let port, let number = NWEndpoint.Port(String(cString: port)) else {
            git_error_set_str(Int32(GIT_ERROR_NET.rawValue), "invalid host or port")
            return -1
        }
        var parent = git_stream()
        parent.version = GIT_STREAM_VERSION
        parent.encrypted = tls ? 1 : 0
        parent.timeout = Int32(timeout * 1000)
        parent.connect_timeout = Int32(connectTimeout * 1000)
        parent.connect = { stream in NetworkStream.connection(stream).connect() }
        parent.certificate = { out, stream in NetworkStream.connection(stream).certificate(out) }
        parent.read = { stream, data, length in NetworkStream.connection(stream).read(data, length) }
        parent.write = { stream, data, length, _ in NetworkStream.connection(stream).write(data, length) }
        parent.close = { stream in NetworkStream.connection(stream).close() }
        parent.free = { stream in
            guard let stream else { return }
            let box = UnsafeMutableRawPointer(stream).assumingMemoryBound(to: Box.self)
            box.pointee.connection.release()
            box.deinitialize(count: 1)
            box.deallocate()
        }
        let client = Connection(host: String(cString: host), port: number, tls: tls)
        let box = UnsafeMutablePointer<Box>.allocate(capacity: 1)
        box.initialize(to: Box(parent: parent, connection: .passRetained(client)))
        out.pointee = UnsafeMutableRawPointer(box).assumingMemoryBound(to: git_stream.self)
        return 0
    }

    private static func connection(_ stream: UnsafeMutablePointer<git_stream>?) -> Connection {
        UnsafeMutableRawPointer(stream!).assumingMemoryBound(to: Box.self).pointee.connection.takeUnretainedValue()
    }
}

/// libgit2 casts it to its `git_stream`, its first field.
private struct Box {
    var parent: git_stream
    let connection: Unmanaged<Connection>
}

private final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let host: String
    private let queue = DispatchQueue(label: "SwiftPyGit.NetworkStream")
    private var certificate: UnsafeMutablePointer<git_cert_x509>?

    init(host: String, port: NWEndpoint.Port, tls: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(NetworkStream.connectTimeout)
        // The system's trust evaluation for the host, as URLSession does.
        let parameters = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.host = host
    }

    deinit {
        connection.cancel()
        if let certificate {
            free(certificate.pointee.data)
            certificate.deallocate()
        }
    }

    func connect() -> Int32 {
        let outcome = wait(NetworkStream.connectTimeout) { (done: @escaping @Sendable (NWError?) -> Void) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: done(nil)
                // Waiting is for a path that may come later; a clone fails instead.
                case .failed(let error), .waiting(let error): done(error)
                case .cancelled: done(.posix(.ECANCELED))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        switch outcome {
        case .none:
            connection.cancel()
            return fail(GIT_TIMEOUT.rawValue, "connecting to \(host) timed out")
        case .some(.some(let error)):
            connection.cancel()
            var errorClass = GIT_ERROR_NET
            if case .tls = error { errorClass = GIT_ERROR_SSL }
            return fail(-1, "failed to connect to \(host): \(error.localizedDescription)", errorClass: errorClass)
        case .some(.none):
            return 0
        }
    }

    func read(_ data: UnsafeMutableRawPointer?, _ length: Int) -> Int {
        let outcome = wait(NetworkStream.timeout) { (done: @escaping @Sendable (Result<Data, NWError>) -> Void) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: length) { content, _, _, error in
                if let error { done(.failure(error)) } else { done(.success(content ?? Data())) }
            }
        }
        switch outcome {
        case .none:
            return Int(fail(GIT_TIMEOUT.rawValue, "reading from \(host) timed out"))
        case .failure(let error):
            return Int(fail(-1, "failed to read from \(host): \(error.localizedDescription)"))
        case .success(let content):
            // Empty at the end of the stream.
            content.copyBytes(to: data!.assumingMemoryBound(to: UInt8.self), count: content.count)
            return content.count
        }
    }

    func write(_ data: UnsafePointer<CChar>?, _ length: Int) -> Int {
        let content = Data(bytes: data!, count: length)
        let outcome = wait(NetworkStream.timeout) { (done: @escaping @Sendable (NWError?) -> Void) in
            connection.send(content: content, completion: .contentProcessed { done($0) })
        }
        switch outcome {
        case .none:
            return Int(fail(GIT_TIMEOUT.rawValue, "writing to \(host) timed out"))
        case .some(.some(let error)):
            return Int(fail(-1, "failed to write to \(host): \(error.localizedDescription)"))
        case .some(.none):
            return length
        }
    }

    func close() -> Int32 {
        connection.cancel()
        return 0
    }

    /// The server's leaf certificate, for a `certificate_check` callback.
    func certificate(_ out: UnsafeMutablePointer<UnsafeMutablePointer<git_cert>?>?) -> Int32 {
        if certificate == nil, let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            nonisolated(unsafe) var leaf: Data?
            sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
                if leaf == nil { leaf = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data }
            }
            if let leaf {
                let x509 = UnsafeMutablePointer<git_cert_x509>.allocate(capacity: 1)
                let bytes = malloc(leaf.count)!
                leaf.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: leaf.count)
                x509.initialize(to: git_cert_x509(parent: git_cert(cert_type: GIT_CERT_X509), data: bytes, len: leaf.count))
                certificate = x509
            }
        }
        guard let certificate else {
            return fail(-1, "no certificate from \(host)")
        }
        out?.pointee = UnsafeMutableRawPointer(certificate).assumingMemoryBound(to: git_cert.self)
        return 0
    }

    /// Sets libgit2's message on the calling thread, which holds one per thread.
    private func fail(_ status: Int32, _ message: String, errorClass: git_error_t = GIT_ERROR_NET) -> Int32 {
        git_error_set_str(Int32(errorClass.rawValue), message)
        return status
    }

    /// Starts an operation and blocks until its first result, or nil after `seconds`.
    private func wait<T: Sendable>(_ seconds: TimeInterval, _ start: (@escaping @Sendable (T) -> Void) -> Void) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = FirstResult<T>()
        start { value in
            if result.set(value) { semaphore.signal() }
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return result.value
    }
}

private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? { lock.withLock { stored } }

    /// Whether `value` was the first.
    func set(_ value: T) -> Bool {
        lock.withLock {
            guard stored == nil else { return false }
            stored = value
            return true
        }
    }
}
