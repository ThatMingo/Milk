import Foundation
import CoreData

public struct SessionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var file: String?
    public var mode: AgentMode
    public init(id: UUID = UUID(), name: String = "New session", file: String? = nil, mode: AgentMode = .approval) {
        self.id = id; self.name = name; self.file = file; self.mode = mode
    }
}
public struct EditorRestoration: Codable, Sendable, Equatable {
    public var paths: [String] = []
    public var selectedPath: String?
    public var split = false
    public init() {}
}
public struct WorkspaceRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var bookmark: Data
    public var sessions: [SessionRecord] = []
    public var selectedSession: UUID?
    public var editor = EditorRestoration()
    public var inspectorVisible = true
    public var terminalVisible = false
    public var lastOpened: Date
    public init(folder: URL) throws {
        id = UUID(); path = folder.resolvingSymlinksInPath().path
        bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        lastOpened = Date()
    }
    public func resolve() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MilkError.message("Workspace folder is unavailable") }
        return url
    }
}

/// Core Data stores Milk metadata only. The versioned payload permits explicit, tested migrations.
public actor WorkspaceStore {
    private let container: NSPersistentContainer
    public static let schemaVersion = 1
    public init(directory: URL? = nil, inMemory: Bool = false) throws {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription(); entity.name = "State"; entity.managedObjectClassName = "NSManagedObject"
        let key = NSAttributeDescription(); key.name = "key"; key.attributeType = .stringAttributeType
        let payload = NSAttributeDescription(); payload.name = "payload"; payload.attributeType = .binaryDataAttributeType
        entity.properties = [key, payload]; entity.uniquenessConstraints = [["key"]]; model.entities = [entity]
        model.versionIdentifiers = ["MilkMetadata1"]
        container = NSPersistentContainer(name: "MilkMetadata", managedObjectModel: model)
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Milk", isDirectory: true)
        if !inMemory { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let store = NSPersistentStoreDescription(url: root.appendingPathComponent("Metadata.sqlite"))
        store.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        store.shouldAddStoreAsynchronously = false
        store.shouldMigrateStoreAutomatically = true; store.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [store]
        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
    }
    public struct Envelope: Codable, Sendable {
        public var version: Int
        public var workspaces: [WorkspaceRecord]
        public init(version: Int = WorkspaceStore.schemaVersion, workspaces: [WorkspaceRecord]) { self.version = version; self.workspaces = workspaces }
        public static func decode(_ data: Data) throws -> Envelope {
            let envelope = try JSONDecoder().decode(Self.self, from: data)
            guard envelope.version <= WorkspaceStore.schemaVersion else { throw MilkError.message("Milk metadata is from a newer application. It was not overwritten.") }
            return envelope
        }
    }
    public func load() async throws -> [WorkspaceRecord] {
        let context = container.newBackgroundContext()
        let data: Data? = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "State"); request.predicate = NSPredicate(format: "key == %@", "workspaces")
            return try context.fetch(request).first?.value(forKey: "payload") as? Data
        }
        return try data.map { try Envelope.decode($0).workspaces } ?? []
    }
    public func save(_ workspaces: [WorkspaceRecord]) async throws {
        let data = try JSONEncoder().encode(Envelope(workspaces: workspaces))
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "State"); request.predicate = NSPredicate(format: "key == %@", "workspaces")
            let row = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "State", into: context)
            row.setValue("workspaces", forKey: "key"); row.setValue(data, forKey: "payload"); try context.save()
        }
    }
}
