import SwiftUI

// Measurements taken from the Settings HTML: .fr, .lb, .hint, .gh and .sel.
enum SettingsMetrics {
    static let inset:CGFloat=14
    static let rowHeight:CGFloat=50
    static let verticalInset:CGFloat=11
    static let sectionSpacing:CGFloat=26
    static let controlWidth:CGFloat=240
}
struct SettingsRow<Control:View>:View {
    let title:String
    var subtitle:String?=nil
    var subtitleLines:Int?=nil
    @ViewBuilder var control:()->Control
    var body:some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.system(size:13))
                if let subtitle { Text(subtitle).lineLimit(subtitleLines).font(.system(size:11.5)).foregroundStyle(MilkTheme.muted).fixedSize(horizontal:false,vertical:true) }
            }.frame(maxWidth:.infinity,alignment:.leading)
            control().buttonStyle(SettingsButtonStyle()).controlSize(.small).font(.system(size:12.5)).frame(maxWidth:SettingsMetrics.controlWidth,alignment:.trailing)
        }.padding(.horizontal,SettingsMetrics.inset).padding(.vertical,SettingsMetrics.verticalInset).frame(minHeight:SettingsMetrics.rowHeight)
    }
}
struct SettingsNote:View {
    let text:String
    var body:some View { Text(text).font(.system(size:11.5)).foregroundStyle(MilkTheme.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,14).padding(.vertical,8) }
}
struct SettingsActionRow<Content:View>:View {
    @ViewBuilder var content:()->Content
    var body:some View { HStack { Spacer(minLength:0); content() }.buttonStyle(SettingsButtonStyle()).controlSize(.small).padding(.horizontal,14).padding(.vertical,SettingsMetrics.verticalInset).frame(minHeight:SettingsMetrics.rowHeight) }
}

// The reference uses 24-unit stroked SVGs in 20 pt tiles, not filled SF glyphs.
struct SettingsReferenceIcon:Shape {
    let category:String
    func path(in rect:CGRect) -> Path {
        var p=Path()
        func line(_ points:[CGPoint]) { guard let first=points.first else{return};p.move(to:first);for point in points.dropFirst(){p.addLine(to:point)} }
        func circle(_ x:CGFloat,_ y:CGFloat,_ r:CGFloat) { p.addEllipse(in:CGRect(x:x-r,y:y-r,width:r*2,height:r*2)) }
        switch category {
        case "General":
            for (x,y) in [(4,14),(12,8),(20,16)] { line([.init(x:x,y:3),.init(x:x,y:y-4)]);line([.init(x:x,y:y+4),.init(x:x,y:21)]);line([.init(x:x-3,y:y),.init(x:x+3,y:y)]) }
        case "Pi", "Agents":
            p.move(to:.init(x:12,y:2.7));p.addLine(to:.init(x:17.7,y:8.4));p.addCurve(to:.init(x:17.7,y:19.7),control1:.init(x:20.8,y:11.5),control2:.init(x:20.8,y:16.6));p.addCurve(to:.init(x:6.3,y:19.7),control1:.init(x:14.6,y:22.8),control2:.init(x:9.4,y:22.8));p.addCurve(to:.init(x:6.3,y:8.4),control1:.init(x:3.2,y:16.6),control2:.init(x:3.2,y:11.5));p.closeSubpath()
        case "Editor":line([.init(x:16,y:6),.init(x:22,y:12),.init(x:16,y:18)]);line([.init(x:8,y:6),.init(x:2,y:12),.init(x:8,y:18)])
        case "Agent":line([.init(x:4,y:5),.init(x:12,y:2),.init(x:20,y:5),.init(x:20,y:13),.init(x:17,y:18),.init(x:12,y:22),.init(x:7,y:18),.init(x:4,y:13),.init(x:4,y:5)])
        case "Git":line([.init(x:6,y:3),.init(x:6,y:15)]);circle(6,18,3);circle(18,6,3);p.move(to:.init(x:18,y:9));p.addQuadCurve(to:.init(x:9,y:18),control:.init(x:18,y:18))
        case "Extensions":p.addRoundedRect(in:CGRect(x:14,y:3,width:7,height:7),cornerSize:.init(width:1,height:1));line([.init(x:10,y:21),.init(x:10,y:7),.init(x:3,y:7),.init(x:3,y:21),.init(x:17,y:21),.init(x:17,y:14),.init(x:3,y:14)])
        case "Updates":line([.init(x:3,y:15),.init(x:3,y:21),.init(x:21,y:21),.init(x:21,y:15)]);line([.init(x:12,y:3),.init(x:12,y:15)]);line([.init(x:7,y:10),.init(x:12,y:15),.init(x:17,y:10)])
        case "Preview":p.move(to:.init(x:2,y:12));p.addQuadCurve(to:.init(x:22,y:12),control:.init(x:12,y:-3));p.addQuadCurve(to:.init(x:2,y:12),control:.init(x:12,y:27));circle(12,12,3)
        default:for x:CGFloat in [5,12,19] {circle(x,12,1)}
        }
        return p.applying(CGAffineTransform(scaleX:rect.width/24,y:rect.height/24).translatedBy(x:rect.minX,y:rect.minY))
    }
}

struct SettingsRows<Content:View>:View {
    @ViewBuilder var content:()->Content
    var body:some View {
        Group(subviews:content()) {rows in VStack(spacing:0) {ForEach(rows) {row in row;if row.id != rows.last?.id {Hairline()}}} }
    }
}

struct SettingsButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12.5)).foregroundStyle(MilkTheme.ink).padding(.horizontal,10).frame(height:24)
            .background(configuration.isPressed ? MilkTheme.selected:MilkTheme.elevatedSurface,in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).stroke(MilkTheme.line)).opacity(enabled ? 1:0.5)
    }
}
struct SettingsSwitchStyle:ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        Button {configuration.isOn.toggle()} label:{
            ZStack(alignment:.leading) {
                Capsule().fill(configuration.isOn ? MilkTheme.switchOn:MilkTheme.segment)
                Circle().fill(.white).frame(width:15,height:15).offset(x:configuration.isOn ? 15:2)
            }.frame(width:32,height:19).opacity(enabled ? 1:0.5)
        }.buttonStyle(.plain)
            .accessibilityRepresentation {Toggle(isOn:configuration.$isOn) {configuration.label}.toggleStyle(.switch)}
    }
}
