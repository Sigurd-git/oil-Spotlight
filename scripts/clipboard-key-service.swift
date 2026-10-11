import Foundation
import Security

private final class ClipboardKeyServiceObject: NSObject, OilFindClipboardKeyServiceProtocol {
    private let queue: DispatchQueue
    private let lifetime: ClipboardKeyServiceLifetime

    init(queue: DispatchQueue, lifetime: ClipboardKeyServiceLifetime) {
        self.queue = queue
        self.lifetime = lifetime
        super.init()
    }

    func readKey(createIfMissing: Bool, allowsInteraction: Bool, reply: @escaping (Data?, Int) -> Void) {
        queue.async {
            do {
                let bytes = try self.lifetime.performIfActive {
                    try ClipboardKeyAccess.bytes(
                        service: ClipboardKeyService.service, account: ClipboardKeyService.account,
                        allowsInteraction: allowsInteraction, createIfMissing: createIfMissing
                    )
                }
                reply(bytes, 0)
            } catch let failure as ClipboardKeyAccessFailure {
                reply(nil, failure.rawValue)
            } catch {
                reply(nil, ClipboardKeyAccessFailure.keychainUnavailable.rawValue)
            }
        }
    }
}

private final class ClipboardKeyServiceListener: NSObject, NSXPCListenerDelegate {
    private let hostRequirement: String
    private let queue = DispatchQueue(label: "OilFind.clipboard-key-service")

    init(hostRequirement: String) {
        self.hostRequirement = hostRequirement
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(hostRequirement)
        let lifetime = ClipboardKeyServiceLifetime()
        connection.invalidationHandler = { lifetime.end() }
        connection.interruptionHandler = { lifetime.end() }
        connection.exportedInterface = NSXPCInterface(with: OilFindClipboardKeyServiceProtocol.self)
        connection.exportedObject = ClipboardKeyServiceObject(queue: queue, lifetime: lifetime)
        connection.resume()
        return true
    }
}

@main
private struct ClipboardKeyServiceMain {
    static func main() {
        do {
            let identity = try ClipboardCodeSigning.currentIdentity()
            guard identity.identifier == ClipboardKeyService.serviceID else { exit(1) }
            let requirement = try ClipboardCodeSigning.requirement(
                identifier: ClipboardKeyService.hostID, certificateSHA1: identity.certificateSHA1
            )
            let delegate = ClipboardKeyServiceListener(hostRequirement: requirement)
            let listener = NSXPCListener.service()
            listener.delegate = delegate
            withExtendedLifetime(delegate) { listener.resume() }
        } catch {
            exit(1)
        }
    }
}
