import SwiftUI

/// Optional native settings facet. Core hosts opaque sections; each adapter owns
/// its schema, draft, validation, persistence and authentication behavior.
@MainActor protocol AgentSettingsProviding {
    var settingsSections: [AgentSettingsSection] { get }
    func settingsView(section: String, agent: AgentService) -> AnyView
}
struct AgentSettingsSection: Identifiable, Equatable {
    var id: String
    var title: String
}
