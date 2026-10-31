import Foundation
import CoreGraphics

/// Stable identifiers keep unknown extension leaves decodable when their package is absent.
public struct WorkspaceElement: RawRepresentable, CaseIterable, Codable, Identifiable, Hashable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard ["code","chat","preview","terminal"].contains(rawValue) || rawValue.range(of: #"^extension:[A-Za-z][A-Za-z0-9.-]*/panel:[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        self.rawValue=rawValue
    }
    public static let code=Self(rawValue:"code")!, chat=Self(rawValue:"chat")!, preview=Self(rawValue:"preview")!, terminal=Self(rawValue:"terminal")!
    public static let allCases: [Self] = [.code,.chat,.preview,.terminal]
    /// Host populates descriptors from active registry entries. They are never serialized.
    public static var extensionDescriptors: [String:PanelDescriptor] = [:]
    public struct PanelDescriptor {
        public var title: String
        public var minimum: CGSize
        public init(title: String, minimum: CGSize) { self.title=title; self.minimum=minimum }
    }
    public var isExtension: Bool { rawValue.hasPrefix("extension:") }
    public var id: String { rawValue }
    public var title: String { Self.extensionDescriptors[rawValue]?.title ?? (isExtension ? "Unavailable extension":rawValue.capitalized) }
    public var minimumWidth: Double { Double(Self.extensionDescriptors[rawValue]?.minimum.width ?? (self == .code || self == .terminal ? 420 : 360)) }
    public var minimumHeight: Double { Double(Self.extensionDescriptors[rawValue]?.minimum.height ?? (self == .terminal ? 240 : 300)) }
    public init(from decoder: Decoder) throws {
        let c=try decoder.singleValueContainer(), value=try c.decode(String.self)
        guard let parsed=Self(rawValue:value) else { throw DecodingError.dataCorruptedError(in:c,debugDescription:"Invalid panel identifier") }; self=parsed
    }
    public func encode(to encoder: Encoder) throws { var c=encoder.singleValueContainer(); try c.encode(rawValue) }
}

public enum LayoutPreset: String, CaseIterable, Identifiable {
    case chat, coding, preview, full, terminal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chat: return "Default"
        case .coding: return "Coding"
        case .preview: return "Preview"
        case .full: return "Full"
        case .terminal: return "Terminal"
        }
    }
    public var elements: [WorkspaceElement] {
        switch self {
        case .chat: return [.chat]
        case .coding: return [.code, .chat]
        case .preview: return [.chat, .preview]
        case .full: return [.code, .chat, .preview]
        case .terminal: return [.chat, .terminal]
        }
    }
    public var proportions: [Double] {
        switch self {
        case .chat: return [1]
        case .coding: return [0.45, 0.55]
        case .preview, .terminal: return [0.55, 0.45]
        case .full: return [0.35, 0.35, 0.30]
        }
    }
}

public enum SplitAxis: String, Codable { case horizontal, vertical }
public enum Placement: String, CaseIterable { case left, right, top, bottom, replace }

public indirect enum LayoutNode: Codable, Equatable, Identifiable {
    case leaf(UUID, WorkspaceElement?)
    case split(UUID, SplitAxis, Double, LayoutNode, LayoutNode)
    public var id: UUID { switch self { case let .leaf(id, _), let .split(id, _, _, _, _): return id } }
    public var elements: [WorkspaceElement] {
        switch self { case let .leaf(_, e): return e.map { [$0] } ?? []
        case let .split(_, _, _, a, b): return a.elements + b.elements }
    }
    public var minimum: CGSize {
        switch self {
        case let .leaf(_, e): return CGSize(width: e?.minimumWidth ?? 180, height: e?.minimumHeight ?? 300)
        case let .split(_, axis, _, a, b):
            let x = a.minimum, y = b.minimum
            return axis == .horizontal ? CGSize(width: x.width+y.width+1, height: max(x.height,y.height)) : CGSize(width: max(x.width,y.width), height: x.height+y.height+1)
        }
    }
    /// Omit unavailable leaves for rendering without changing the persisted tree.
    public func available(where include: (WorkspaceElement) -> Bool) -> LayoutNode? {
        switch self {
        case let .leaf(_, element): return element.map { include($0) } == false ? nil:self
        case let .split(id,axis,ratio,a,b):
            let x=a.available(where:include), y=b.available(where:include)
            if let x, let y { return .split(id,axis,ratio,x,y) }; return x ?? y
        }
    }
    public func mapped(_ id: UUID, _ transform: (LayoutNode) -> LayoutNode) -> LayoutNode {
        if self.id == id { return transform(self) }
        if case let .split(i, axis, ratio, a, b) = self { return .split(i, axis, ratio, a.mapped(id, transform), b.mapped(id, transform)) }
        return self
    }
    public func removing(_ id: UUID) -> LayoutNode? {
        if self.id == id { return nil }
        guard case let .split(i, axis, ratio, a, b) = self else { return self }
        let x = a.removing(id), y = b.removing(id)
        if let x, let y { return .split(i, axis, ratio, x, y) }
        return x ?? y
    }
    public func leaf(for element: WorkspaceElement) -> UUID? {
        switch self { case let .leaf(id, e): return e == element ? id : nil
        case let .split(_, _, _, a, b): return a.leaf(for: element) ?? b.leaf(for: element) }
    }
    public func firstLength(_ size: CGSize) -> Double {
        guard case let .split(_, axis, ratio, a, b) = self else { return 0 }
        let horizontal = axis == .horizontal
        let available = (horizontal ? size.width : size.height)-1
        let amin = horizontal ? a.minimum.width : a.minimum.height
        let bmin = horizontal ? b.minimum.width : b.minimum.height
        return max(amin, min(available-bmin, available*ratio))
    }
    public func frames(in rect: CGRect) -> [UUID: CGRect] {
        var result = [id: rect]
        if case let .split(_, axis, _, a, b) = self {
            let length = firstLength(rect.size)
            let ar = CGRect(origin: rect.origin, size: axis == .horizontal ? CGSize(width:length,height:rect.height) : CGSize(width:rect.width,height:length))
            let br = axis == .horizontal ? CGRect(x:rect.minX+length+1,y:rect.minY,width:rect.width-length-1,height:rect.height) : CGRect(x:rect.minX,y:rect.minY+length+1,width:rect.width,height:rect.height-length-1)
            result.merge(a.frames(in: ar)) { _,n in n }; result.merge(b.frames(in: br)) { _,n in n }
        }
        return result
    }
    public func preferred(_ sizes: [WorkspaceElement: CGSize]) -> CGSize {
        switch self {
        case let .leaf(_, e): return e.flatMap { sizes[$0] } ?? minimum
        case let .split(_, axis, _, a, b):
            let x=a.preferred(sizes), y=b.preferred(sizes)
            return axis == .horizontal ? CGSize(width:x.width+y.width+1,height:max(x.height,y.height)) : CGSize(width:max(x.width,y.width),height:x.height+y.height+1)
        }
    }
    public func preserving(_ sizes: [WorkspaceElement: CGSize]) -> LayoutNode {
        guard case let .split(id, axis, _, a,b) = self else { return self }
        let x=a.preferred(sizes), y=b.preferred(sizes)
        let ratio = axis == .horizontal ? x.width/(x.width+y.width) : x.height/(x.height+y.height)
        return .split(id,axis,ratio,a.preserving(sizes),b.preserving(sizes))
    }
}

public struct SavedLayout: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public let root: LayoutNode
}
public struct WorkspaceLayout: Codable, Equatable {
    public static let dividerWidth = 1.0
    public var root: LayoutNode? = .leaf(UUID(), .chat)
    public var selectedName = "Default"
    public var saved: [SavedLayout] = []
    public init() {}
    public var elements: [WorkspaceElement] { root?.elements ?? [] }
    public var minimumWidth: Double { Double(root?.minimum.width ?? 180) }
    public var minimumHeight: Double { Double(root?.minimum.height ?? 300) }
    public var preset: LayoutPreset? { LayoutPreset.allCases.first { $0.title == selectedName } }
    public mutating func apply(_ preset: LayoutPreset) {
        selectedName = preset.title
        let leaves = preset.elements.map { LayoutNode.leaf(UUID(), $0) }
        if leaves.count == 1 { root=leaves[0] }
        else if leaves.count == 2 { root = .split(UUID(),.horizontal,preset.proportions[0],leaves[0],leaves[1]) }
        else { root = .split(UUID(),.horizontal,0.35,leaves[0],.split(UUID(),.horizontal,0.35/0.65,leaves[1],leaves[2])) }
    }
    public mutating func remove(_ id: UUID) { root=root?.removing(id); selectedName="Custom" }
    public mutating func toggle(_ e: WorkspaceElement) {
        if let id=root?.leaf(for:e) { remove(id) }
        else if let target=root?.id { place(e, at:target, edge: e == .code ? .left : .right) }
        else { root = .leaf(UUID(),e) }
    }
    public mutating func place(_ e: WorkspaceElement, at target: UUID, edge: Placement) {
        if root?.leaf(for:e) == target { return }
        if let existing=root?.leaf(for:e) { root=root?.removing(existing) }
        let leaf=LayoutNode.leaf(UUID(),e)
        if root == nil { root=leaf; return }
        root=root?.mapped(target) { node in
            if edge == .replace { return .leaf(node.id,e) }
            let before = edge == .left || edge == .top
            return .split(UUID(), edge == .top || edge == .bottom ? .vertical : .horizontal, 0.5, before ? leaf : node, before ? node : leaf)
        }
        selectedName="Custom"
    }
    public mutating func split(_ id: UUID, axis: SplitAxis) {
        root=root?.mapped(id) { .split(UUID(),axis,0.5,$0,.leaf(UUID(),nil)) }; selectedName="Custom"
    }
    public mutating func resize(_ id: UUID, ratio: Double) {
        root=root?.mapped(id) { node in
            if case let .split(i,axis,_,a,b)=node { return .split(i,axis,max(0.001,min(0.999,ratio)),a,b) }; return node
        }; selectedName="Custom"
    }
    public mutating func save(name: String) {
        guard let root else { return }; let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        saved.append(SavedLayout(id:UUID(),name:name.isEmpty ? "Custom \(saved.count+1)" : name,root:root)); selectedName=saved.last!.name
    }
    public mutating func restore(_ saved: SavedLayout) { root=saved.root; selectedName=saved.name }
}
