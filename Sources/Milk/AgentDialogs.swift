import SwiftUI

// Menu and takeover share the same settings service and controls.
struct RuntimeConfigurationDialog: View {
    @ObservedObject var state:ShellState
    let dismiss:()->Void
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            Text("Agents").font(.system(size:22,weight:.semibold))
            AgentsSettingsView(state:state)
            Button("Done",action:dismiss).keyboardShortcut(.cancelAction)
        }.padding(24) }.frame(width:650,height:760).background(MilkTheme.canvas)
    }
}
