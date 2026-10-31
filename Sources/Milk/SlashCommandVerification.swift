import AppKit
import SwiftUI

/// Explicit disposable UI harness: real pinned Pi and isolated loopback/resource/terminal fixtures.
@MainActor enum SlashCommandVerification {
    static let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Slash-UI-"+UUID().uuidString)
    static let suite="Milk.SlashUI."+UUID().uuidString
    static func makeState() -> ShellState {
        ShellState(persist:false,preferences:UserDefaults(suiteName:suite)!,agentAdapter:PiAdapter(runtime:PiRuntimeService(environmentOverrides:["PI_CODING_AGENT_DIR":root.appendingPathComponent("agent").path,"MILK_OMLX_TOKEN":"fixture"]),configuration:{ .load(UserDefaults(suiteName:suite)!) }),terminalService:TerminalService(shell:root.appendingPathComponent("test-shell").path))
    }
    static func run(state: ShellState, window: NSWindow) async {
        let fm=FileManager.default, project=URL(fileURLWithPath:fm.currentDirectoryPath), output=project.appendingPathComponent("output/verification-slash-commands")
        let server=Process(), pipe=Pipe()
        var results:[String]=[]
        func check(_ condition: Bool, _ message: String) { results.append("\(condition ? "PASS":"FAIL") \(message)") }
        func settle() async { try? await Task.sleep(nanoseconds:300_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            let deadline=Date().addingTimeInterval(15)
            while !condition() { guard Date() < deadline else { throw AgentError.message("Timeout: "+message+" · "+(state.agent.current.error ?? "")) }; try await Task.sleep(nanoseconds:20_000_000) }
        }
        func find(_ id: String, _ view: NSView) -> NSView? { if view.identifier?.rawValue == id { return view }; return view.subviews.lazy.compactMap { find(id,$0) }.first }
        func panel(_ id: String = "milk.composer.slash-menu") -> NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == id && $0.isVisible } }
        func composerRect() -> NSRect {
            guard let anchor=find("milk.geometry.slash-composer",window.contentView!) else { return .zero }
            return window.convertToScreen(anchor.convert(anchor.bounds,to:nil))
        }
        func anchored(_ label: String) {
            guard let popup=panel() else { check(false,label+" exists"); return }
            let rect=composerRect()
            check(abs(popup.frame.minX-rect.minX)<1 && abs(popup.frame.width-rect.width)<1 && abs(popup.frame.minY-rect.maxY-14)<1,label)
        }
        func capture(_ name: String, popupID: String = "milk.composer.slash-menu") {
            guard let view=window.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let image=NSImage(size:view.bounds.size); image.lockFocus()
            if let cg=bitmap.cgImage { NSImage(cgImage:cg,size:view.bounds.size).draw(in:view.bounds) }
            if let popup=panel(popupID), let content=popup.contentView, let capture=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:capture)
                let rect=view.convert(window.convertFromScreen(popup.frame),from:nil)
                if let cg=capture.cgImage { NSImage(cgImage:cg,size:content.bounds.size).draw(in:rect) }
            }
            image.unlockFocus()
            if let tiff=image.tiffRepresentation, let rendered=NSBitmapImageRep(data:tiff) { try? rendered.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(name+".png")) }
        }
        do {
            try fm.createDirectory(at:output,withIntermediateDirectories:true)
            let workspace=root.appendingPathComponent("Workspace"), agent=root.appendingPathComponent("agent")
            for url in [workspace,agent.appendingPathComponent("extensions"),agent.appendingPathComponent("prompts"),agent.appendingPathComponent("skills/ui-review")] { try fm.createDirectory(at:url,withIntermediateDirectories:true) }
            try Data("export default function(pi) { pi.registerCommand('ui-check', {description:'Run UI fixture',handler:async(args,ctx)=>ctx.ui.notify(args,'info')}); }".utf8).write(to:agent.appendingPathComponent("extensions/ui.ts"))
            try Data("---\ndescription: UI prompt fixture\n---\nReview $ARGUMENTS\n".utf8).write(to:agent.appendingPathComponent("prompts/ui-template.md"))
            try Data("---\nname: ui-review\ndescription: UI review skill\n---\nReview the supplied request.\n".utf8).write(to:agent.appendingPathComponent("skills/ui-review/SKILL.md"))
            try Data("#!/bin/sh\nexport HISTFILE=/dev/null PS1='' PS2=''\nexec /bin/bash --noprofile --norc -i\n".utf8).write(to:root.appendingPathComponent("test-shell"))
            try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.appendingPathComponent("test-shell").path)
            server.executableURL=URL(fileURLWithPath:"/usr/bin/python3"); server.arguments=["-u",project.appendingPathComponent("Tests/Fixtures/omlx_fixture.py").path]; server.standardOutput=pipe; server.standardError=FileHandle.nullDevice
            try server.run()
            guard let port=Int(String(decoding:pipe.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw AgentError.message("Fixture did not start") }
            try state.workspace.openWorkspace(workspace)
            var config=AgentConfiguration(); config.omlx.enabled=true; config.omlx.endpoint=URL(string:"http://127.0.0.1:\(port)")!
            config.omlx.modelIDs=["milk-fixture","reasoning-fixture"]; config.omlx.reasoningModels=["reasoning-fixture"]; config.omlx.defaultModel="reasoning-fixture"
            try state.agent.updateConfiguration(config,token:nil)
            try await wait("Pi ready") { state.agent.runtimeStatuses[state.selectedSession]?.phase == .ready }
            await settle()
            guard let scroll=find("milk.composer.input",window.contentView!) as? NSScrollView, let input=scroll.documentView as? ComposerInput.InputView else { throw AgentError.message("Composer not mounted") }
            window.makeFirstResponder(input)
            func key(_ code: UInt16) {
                let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
                input.keyDown(with:event)
            }
            state.updateComposerDraft("hello"); await settle(); let before=composerRect()
            state.updateComposerDraft("/"); await settle()
            check(panel() != nil,"Slash at the beginning opens a child popup")
            check(composerRect() == before,"Completion does not move or resize the composer/conversation layout")
            anchored("Popup aligns above the composer with the existing 14 pt gap")
            check(window.attachedSheet == nil && panel()?.canBecomeKey == false,"Popup is nonmodal and keeps text editing in the composer")
            check(state.slashCommands.commands.contains { $0.name == "ui-check" } && state.slashCommands.commands.contains { $0.name == "ui-template" } && state.slashCommands.commands.contains { $0.name == "skill:ui-review" },"Real Pi extension, prompt and skill commands reach the menu")
            for appearance in [MilkAppearance.light,.dark,.system] {
                state.settings.appearance=appearance; await settle(); capture(appearance.rawValue.lowercased()+"-commands")
                check(panel()?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]),appearance.rawValue+" popup follows the host appearance")
            }
            key(125); check(state.slashCommands.selectedID == "resume","Native Down selects next command")
            key(126); check(state.slashCommands.selectedID == "new","Native Up selects previous command")
            key(126); await settle(); check(state.slashCommands.selectedID == "skill:ui-review","Up wraps to the last resource and scrolls it into view"); capture("scrolled-selection")
            state.updateComposerDraft("/ne"); await settle(); capture("filtered-new")
            key(48); await settle()
            check(state.agent.current.draft == "/new " && panel() == nil && window.firstResponder === input,"Tab completes and returns the caret to the composer")
            state.updateComposerDraft("/does-not-exist"); await settle(); capture("empty-results")
            check(panel() != nil && state.slashCommands.results.isEmpty,"No commands found remains a compact visible popup")
            key(53); await settle(); check(panel() == nil,"Escape closes completion")
            state.updateComposerDraft("Fix src/views/foo/bar.swift"); await settle(); check(panel() == nil,"An ordinary slash in a prompt never triggers completion")
            state.updateComposerDraft("/model"); await settle(); key(36); await settle(); capture("existing-model-picker",popupID:"milk.composer.model-picker")
            check(panel() == nil && panel("milk.composer.model-picker") != nil && state.slashCommands.popup == .model,"Model command opens the existing model picker without stacking completion")
            state.updateComposerDraft("/thinking"); await settle(); key(36); await settle(); capture("existing-effort-picker",popupID:"milk.composer.model-picker")
            check(state.slashCommands.popup == .thinking && panel("milk.composer.model-picker") != nil,"Thinking command opens the existing effort picker")
            state.updateComposerDraft("/"); await settle()
            let approval=Task { try? await state.agent.authorizeExtensionAction(owner:"dev.milk.slash-ui",action:"Verify approval priority",workspace:state.workspace.workspace?.url,session:state.selectedSession) }
            try await wait("approval priority") { state.agent.presentedApproval != nil }; await settle(); capture("approval-priority",popupID:"milk.approval.popup")
            check(panel() == nil && panel("milk.approval.popup") != nil && state.slashCommands.popup == nil,"Approval dismisses completion and remains highest priority")
            if let decision=state.agent.presentedApproval { state.agent.respond(decision.request,session:decision.session,cancelled:true) }; await approval.value
            state.updateComposerDraft("/terminal"); state.submitComposerPrompt()
            try await wait("terminal focus") { state.terminal.session?.view.window != nil && window.firstResponder === state.terminal.session?.view }
            let terminal=state.terminal.session?.id
            state.updateComposerDraft("/terminal"); state.submitComposerPrompt(); await settle()
            check(state.terminal.session?.id == terminal && window.firstResponder === state.terminal.session?.view,"Terminal command focuses and reuses the existing shell")
            let pid=state.terminal.session?.process?.pid ?? -1
            try JSONSerialization.data(withJSONObject:["terminalPID":pid,"temporaryRoot":root.path],options:.prettyPrinted).write(to:output.appendingPathComponent("quit-process.json"))
            check(pid > 1,"A real owned Terminal is running before /quit")
        } catch { check(false,error.localizedDescription) }
        if server.isRunning { server.terminate() }
        try? results.joined(separator:"\n").write(to:output.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8)
        print(results.joined(separator:"\n"))
        let cleanupRoot=root, cleanupSuite=suite
        _ = NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { _ in
            try? FileManager.default.removeItem(at:cleanupRoot); UserDefaults(suiteName:cleanupSuite)?.removePersistentDomain(forName:cleanupSuite)
        }
        // Exercise the production slash dispatcher and NSApplication termination/cleanup handshake.
        state.updateComposerDraft("/quit"); state.submitComposerPrompt()
    }
}
