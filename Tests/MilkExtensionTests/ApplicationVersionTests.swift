import XCTest
import Foundation
@testable import MilkExtensionHost

final class ApplicationVersionTests: XCTestCase {
    func testSwiftPMUsesMilkCheckoutRatherThanTestRunnerVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(MilkApplicationVersion.current.version, try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(MilkApplicationVersion.current.buildNumber, try String(contentsOf: root.appendingPathComponent("BUILD_NUMBER"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func testReadsActualBundleMetadataAndDoesNotInventMissingValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.milk.version." + UUID().uuidString, "CFBundleShortVersionString": "0.2.3", "CFBundleVersion": "42"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        let value = MilkApplicationVersion(bundle: bundle)
        XCTAssertEqual(value.version, "0.2.3")
        XCTAssertEqual(value.buildNumber, "42")
        let absent = MilkApplicationVersion(bundle: Bundle(for: Self.self))
        XCTAssertEqual(absent.version, Bundle(for: Self.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(absent.buildNumber, Bundle(for: Self.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}
