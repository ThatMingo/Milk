import Foundation
import MilkCore

@MainActor public final class ExtensionHostClient {
    private var connection: NSXPCConnection?
    public private(set) var lastError: String?
    public init() {}
    public func evaluate(manifest: ExtensionManifest, source: String, registry: ExtensionRegistry) async throws -> JSONValue {
        try manifest.validate()
        guard await registry.authorize(extensionID: manifest.id, permission: .ui) else { throw MilkError.message("Extension UI permission was not granted") }
        if connection == nil {
            let connection = NSXPCConnection(serviceName: "dev.thatmingo.Milk.ExtensionHost")
            connection.remoteObjectInterface = NSXPCInterface(with: MilkExtensionHostProtocol.self)
            connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.lastError = "Extension host interrupted"; self?.disconnect() } }
            connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            connection.resume(); self.connection = connection
        }
        let envelope = ExtensionEnvelope(extensionID: manifest.id, method: "evaluate", payload: .object(["source": .string(source)]))
        let data = try JSONEncoder().encode(envelope)
        return try await withCheckedThrowingContinuation { reply in
            let gate = ReplyGate(reply)
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in gate.finish(.failure(MilkError.message("Extension host unavailable or terminated"))) }) as? MilkExtensionHostProtocol else { gate.finish(.failure(MilkError.message("Extension host unavailable"))); return }
            proxy.evaluate(data) { response, error in
                do {
                    if let error { throw MilkError.message(error) }
                    guard let response else { throw MilkError.message("Empty extension response") }
                    gate.finish(.success(try JSONDecoder().decode(JSONValue.self, from: response)))
                } catch { gate.finish(.failure(error)) }
            }
        }
    }
    public func disconnect() { connection?.invalidate(); connection = nil }
    private final class ReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: CheckedContinuation<JSONValue, any Error>?
        init(_ reply: CheckedContinuation<JSONValue, any Error>) { self.reply = reply }
        func finish(_ result: Result<JSONValue, any Error>) { lock.withLock { let reply = self.reply; self.reply = nil; reply?.resume(with: result) } }
    }
}
