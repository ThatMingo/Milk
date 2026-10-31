import SwiftUI

struct PreviewPanel: View {
    @ObservedObject var service: PreviewService
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ExtensionSlot(point:.previewToolbar)
                Button { service.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MilkButtonStyle()).disabled(service.currentURL == nil || service.busy)
                    .accessibilityLabel("Reload Preview").help("Reload page")
                HStack(spacing: 6) {
                    Circle().fill(service.state == .failed ? MilkTheme.red : service.state == .running ? MilkTheme.green : MilkTheme.muted).frame(width: 6, height: 6)
                    TextField("Project Preview URL", text: $service.address)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .onSubmit { service.navigate() }.disabled(service.workspace == nil).accessibilityLabel("Preview URL").accessibilityIdentifier("milk.preview.url")
                }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 28)
                    .background(MilkTheme.segment, in: RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 2) {
                    viewport("desktopcomputer", .desktop)
                    viewport("ipad", .tablet)
                    viewport("iphone", .phone)
                }.padding(2).background(MilkTheme.segment, in: RoundedRectangle(cornerRadius: 7))
                Button { service.openExternally() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(MilkButtonStyle()).disabled(service.currentURL == nil).help("Open in default browser").accessibilityLabel("Open Preview externally")
                Button {
                    if service.managed || service.busy || [.loading, .running].contains(service.state) { service.stop() }
                    else { service.start() }
                } label: { Image(systemName: service.managed || service.busy || [.loading, .running].contains(service.state) ? "stop" : "play") }
                    .buttonStyle(MilkButtonStyle()).disabled(service.workspace == nil)
                    .accessibilityLabel(service.managed ? "Stop Preview server" : service.busy ? "Cancel Preview startup" : [.loading, .running].contains(service.state) ? "Stop Preview page" : "Start Preview")
                    .help(service.managed ? "Stop the Milk-managed server and its children" : "Start or stop Preview; external servers are never terminated")
                    .accessibilityIdentifier("milk.preview.start-stop")
            }.padding(.horizontal, 8).frame(height: 42).background(MilkTheme.canvas)
            Hairline()
            if let error = service.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(MilkTheme.red)
                    Text(error).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(service.managed ? "Reload" : "Start") { if service.managed { service.reload() } else { service.start() } }.buttonStyle(MilkButtonStyle())
                }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6).background(MilkTheme.surface)
            } else if service.busy || service.state == .loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(service.state == .starting ? "Starting Preview…" : service.state == .waiting ? "Waiting for server…" : "Loading Preview…")
                    Spacer()
                }.font(.system(size: 11)).foregroundStyle(MilkTheme.muted).padding(.horizontal, 12).padding(.vertical, 5)
            }
            if service.currentURL != nil && service.state != .stopped {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 0) {
                            ProjectWebView(renderer: service.renderer)
                                .id(ObjectIdentifier(service.renderer))
                                .frame(width: service.device.width ?? max(1, geometry.size.width - 32), height: max(1, geometry.size.height - 32))
                                .background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MilkTheme.line))
                        }.padding(16).frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "eye").font(.system(size: 22)).foregroundStyle(MilkTheme.muted)
                    Text(service.workspace == nil ? "Open a project to preview it" : service.state == .stopped ? "Preview stopped" : "Project Preview").font(.system(size: 13, weight: .medium))
                    if service.workspace != nil && !service.busy {
                        Button("Start Preview") { service.start() }.buttonStyle(MilkButtonStyle(bordered: true))
                        Text("Or enter a running project URL above.").font(.system(size: 11)).foregroundStyle(MilkTheme.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(MilkTheme.surface).onAppear { service.ensureStarted() }
            .onChange(of: service.workspace) { _, _ in service.ensureStarted() }
    }
    private func viewport(_ symbol: String, _ device: PreviewDevice) -> some View {
        Button { service.selectDevice(device) } label: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22)
                .background(service.device == device ? MilkTheme.selectionSurface : .clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(service.device == device ? MilkTheme.ink : MilkTheme.muted)
        }.buttonStyle(.plain).accessibilityLabel("\(device.rawValue) viewport").help(device.rawValue)
            .accessibilityIdentifier("milk.preview.\(device.rawValue.lowercased())")
    }
}
