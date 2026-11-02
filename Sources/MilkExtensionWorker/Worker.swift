import Foundation
import MilkExtensionKit

// A distinct executable/signing identity: never signed with Milk's Keychain entitlements.
@main struct Worker {
    static func send(_ object: [String:Any]) throws {
        let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        guard bytes.count <= 8*1024*1024 else { throw Failure.invalid }
        try FileHandle.standardOutput.write(contentsOf:bytes+Data([10]))
    }
    enum Failure: Error { case invalid }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 1, let line=readLine(), line.utf8.count <= 2*1024*1024 else { throw Failure.invalid }
            let request=try JSONDecoder().decode(ExtensionWorkerRequest.self,from:Data(line.utf8))
            guard let bundle=Bundle(url:request.packageURL) else { throw Failure.invalid }
            try bundle.loadAndReturnError()
            guard let principal=bundle.classNamed(request.principalClass) as? MilkExtensionAgentWorker.Type,
                  Bundle(for:principal).bundleURL.resolvingSymlinksInPath() == request.packageURL.resolvingSymlinksInPath() else { throw Failure.invalid }
            let context=ExtensionAgentContext(workspaceURL:request.workspaceURL,storageURL:request.storageURL,packageURL:request.packageURL) { arguments in
                try send(["kind":"git","arguments":arguments])
                guard let line=readLine(), line.utf8.count <= 8*1024*1024,
                      let result=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { throw Failure.invalid }
                if let error=result["error"] as? String { throw NSError(domain:"MilkExtensionWorker",code:1,userInfo:[NSLocalizedDescriptionKey:error]) }
                guard let output=result["result"] as? String else { throw Failure.invalid }; return output
            }
            let result=try await principal.init().run(tool:request.tool,arguments:request.arguments,context:context)
            try send(["kind":"result","text":result])
            _ = readLine() // Remain owned until the host closes/terminates this invocation.
        } catch { try? send(["kind":"failure","error":error.localizedDescription]) }
    }
}
