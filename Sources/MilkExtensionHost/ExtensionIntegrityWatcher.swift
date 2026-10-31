import Foundation
import CoreServices

/// Observe only Milk's installed-code tree. Data writes never cause integrity rescans.
final class ExtensionIntegrityWatcher {
    private var stream: FSEventStreamRef?
    private var changed: (() -> Void)?
    init(url: URL, changed: @escaping () -> Void) {
        self.changed=changed
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let callback: FSEventStreamCallback={ _,info,_,_,_,_ in
            guard let info else { return }
            Unmanaged<ExtensionIntegrityWatcher>.fromOpaque(info).takeUnretainedValue().changed?()
        }
        stream=FSEventStreamCreate(nil,callback,&context,[url.path] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.3,FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream,.main); FSEventStreamStart(stream) }
    }
    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream=nil; changed=nil
    }
    deinit { stop() }
}
