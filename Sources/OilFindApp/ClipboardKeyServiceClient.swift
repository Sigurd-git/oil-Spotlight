import Foundation

// A request owns its result so late replies after timeout cannot affect a later load.
final class ClipboardKeyServiceRequest {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var finished = false
    private var value: Result<Data, ClipboardKeyAccessFailure>?

    func resolve(data: Data?, failure: ClipboardKeyAccessFailure?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let failure {
            value = .failure(failure)
        } else if let data, data.count == 32 {
            value = .success(data)
        } else {
            value = .failure(.keyUnavailable)
        }
        completion.signal()
    }

    func wait(timeout: TimeInterval) throws -> Data {
        let status = completion.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        if status == .timedOut {
            finished = true
            value = .failure(.keychainUnavailable)
        }
        return try (value ?? .failure(.keychainUnavailable)).get()
    }
}

enum ClipboardKeyServiceClient {
    static func bytes(createIfMissing: Bool, allowsInteraction: Bool) throws -> Data {
        let requirement = try ClipboardCodeSigning.requirementForCurrentProcess(identifier: ClipboardKeyService.serviceID)
        let connection = NSXPCConnection(serviceName: ClipboardKeyService.serviceID)
        connection.remoteObjectInterface = NSXPCInterface(with: OilFindClipboardKeyServiceProtocol.self)
        // XPC checks the peer's live signature, rather than trusting a PID or a path.
        connection.setCodeSigningRequirement(requirement)
        let request = ClipboardKeyServiceRequest()
        connection.interruptionHandler = { request.resolve(data: nil, failure: .keychainUnavailable) }
        connection.invalidationHandler = { request.resolve(data: nil, failure: .keychainUnavailable) }
        connection.resume()
        defer { connection.invalidate() }
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in
            request.resolve(data: nil, failure: .keychainUnavailable)
        }) as? OilFindClipboardKeyServiceProtocol else {
            throw ClipboardKeyAccessFailure.keychainUnavailable
        }
        remote.readKey(createIfMissing: createIfMissing, allowsInteraction: allowsInteraction) { data, status in
            request.resolve(data: data, failure: status == 0 ? nil
                : (ClipboardKeyAccessFailure(rawValue: status) ?? .keychainUnavailable))
        }
        return try request.wait(timeout: allowsInteraction ? 300 : 10)
    }
}
