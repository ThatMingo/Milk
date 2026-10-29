import Foundation
import JavaScriptCore
import MilkCore

final class ExtensionHost: NSObject, MilkExtensionHostProtocol {
    private let queue = DispatchQueue(label: "Milk.extension.javascript")
    func evaluate(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        // One serial execution context per call. No filesystem/network/native-object bridge is installed.
        // XPC service entitlements, not the main app's entitlements, constrain this process.
        let box = ReplyBox(reply)
        queue.async {
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + 3)
            watchdog.setEventHandler { _exit(70) } // Terminate only the isolated helper on runaway JS.
            watchdog.resume()
            defer { watchdog.cancel() }
            do {
                guard request.count < 1_000_000 else { throw MilkError.message("Extension request exceeds size limit") }
                let envelope = try JSONDecoder().decode(ExtensionEnvelope.self, from: request)
                guard envelope.protocolVersion == 1, envelope.method == "evaluate", let source = envelope.payload["source"].string else { throw MilkError.message("Unsupported extension protocol") }
                guard let context = JSContext() else { throw MilkError.message("JavaScript runtime unavailable") }
                let value = context.evaluateScript("JSON.stringify((function(){ 'use strict'; \(source) })())")
                guard context.exception == nil, let string = value?.toString(), let bytes = string.data(using: .utf8), bytes.count < 1_000_000 else { throw MilkError.message("Extension evaluation failed") }
                _ = try JSONDecoder().decode(JSONValue.self, from: bytes)
                box.reply(bytes, nil)
            } catch { box.reply(nil, error.localizedDescription) }
        }
    }
    private final class ReplyBox: @unchecked Sendable {
        let reply: (Data?, String?) -> Void
        init(_ reply: @escaping (Data?, String?) -> Void) { self.reply = reply }
    }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let host = ExtensionHost()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MilkExtensionHostProtocol.self)
        connection.exportedObject = host; connection.resume(); return true
    }
}
let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
