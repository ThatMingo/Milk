import XCTest
@testable import MilkLayout
final class WorkspaceLayoutTests: XCTestCase {
    func testNestedMinimumAndMove() {
        var l=WorkspaceLayout(); l.apply(.coding)
        let chat=l.root!.leaf(for:.chat)!
        l.place(.preview,at:chat,edge:.top)
        XCTAssertEqual(l.minimumWidth,781); XCTAssertEqual(l.minimumHeight,601)
        l.place(.code,at:chat,edge:.bottom)
        XCTAssertEqual(Set(l.elements),Set([.chat,.code,.preview]))
        XCTAssertEqual(l.elements.count,3)
        XCTAssertEqual(l.minimumHeight,902)
    }
    func testSerializationSavedAndRatios() throws {
        var l=WorkspaceLayout();l.apply(.full)
        l.resize(l.root!.id,ratio:0.42);l.save(name:"My layout")
        let copy=try JSONDecoder().decode(WorkspaceLayout.self,from:JSONEncoder().encode(l))
        XCTAssertEqual(copy,l)
        l.apply(.chat);l.restore(copy.saved[0]);XCTAssertEqual(l.root,copy.root)
    }
    func testPresetsAndMinimumClamping() {
        for preset in LayoutPreset.allCases {
            var l=WorkspaceLayout();l.apply(preset)
            let frames=l.root!.frames(in:CGRect(x:0,y:0,width:1800,height:800))
            for (i,e) in preset.elements.enumerated() {
                let f=frames[l.root!.leaf(for:e)!]!
                XCTAssertEqual(f.width/(1800-Double(preset.elements.count-1)),preset.proportions[i],accuracy:0.001)
            }
            let mins=l.root!.frames(in:CGRect(x:0,y:0,width:l.minimumWidth,height:l.minimumHeight))
            for e in l.elements { XCTAssertEqual(mins[l.root!.leaf(for:e)!]!.width,e.minimumWidth,accuracy:0.001) }
        }
    }
    func testEmptySplitAssignmentRemoval() {
        var l=WorkspaceLayout();let id=l.root!.id;l.split(id,axis:.vertical)
        XCTAssertEqual(l.minimumHeight,601)
        if case let .split(_,_,_,_,empty)=l.root! { l.place(.preview,at:empty.id,edge:.replace) }
        XCTAssertEqual(l.elements,[.chat,.preview])
        l.remove(l.root!.leaf(for:.preview)!);XCTAssertEqual(l.minimumHeight,300)
    }
    func testPreserveDimensions() {
        var l=WorkspaceLayout();let chat=l.root!.id
        l.place(.preview,at:chat,edge:.top)
        let sizes:[WorkspaceElement:CGSize]=[.chat:CGSize(width:700,height:500)]
        XCTAssertEqual(l.root!.preferred(sizes).height,801)
        l.root=l.root!.preserving(sizes)
        let f=l.root!.frames(in:CGRect(x:0,y:0,width:700,height:801))
        XCTAssertEqual(f[chat]!.height,500,accuracy:0.001)
    }
    func testTerminalEveryPlacementPersistenceAndMinimums() throws {
        for edge in Placement.allCases {
            var layout = WorkspaceLayout()
            let chat = layout.root!.id
            layout.place(.terminal, at: chat, edge: edge)
            XCTAssertTrue(layout.elements.contains(.terminal))
            XCTAssertEqual(Set(layout.elements).count, layout.elements.count)
            if edge == .replace {
                XCTAssertEqual(layout.elements, [.terminal])
                XCTAssertEqual(layout.minimumWidth, 420); XCTAssertEqual(layout.minimumHeight, 240)
            } else if edge == .top || edge == .bottom {
                XCTAssertEqual(layout.minimumWidth, 420); XCTAssertEqual(layout.minimumHeight, 541)
            } else {
                XCTAssertEqual(layout.minimumWidth, 781); XCTAssertEqual(layout.minimumHeight, 300)
            }
            layout.resize(layout.root!.id, ratio: 0.63)
            layout.save(name: "With Terminal")
            let copy = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
            XCTAssertEqual(copy, layout)
            layout.apply(.full); layout.restore(copy.saved[0]); XCTAssertEqual(layout.root, copy.root)
            layout.toggle(.terminal); XCTAssertFalse(layout.elements.contains(.terminal))
        }
        var layout = WorkspaceLayout(); layout.apply(.full)
        layout.place(.terminal, at: layout.root!.leaf(for: .code)!, edge: .bottom)
        XCTAssertEqual(Set(layout.elements), Set(WorkspaceElement.allCases))
        XCTAssertEqual(layout.minimumWidth, 1142); XCTAssertEqual(layout.minimumHeight, 541)
    }
}
