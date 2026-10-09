/// App-only presentation intent. Simulated plans describe a future adapter;
/// they neither detect hardware nor claim dual-screen compatibility.
/// No session, card, reveal, pending grade, or timer state is copied here.
struct PracticeWorkspaceLayout: Equatable {
    enum Presentation: CaseIterable {
        case compact, simulatedCompanion, simulatedSpanned
    }
    enum Audience { case privateControls, presentation }
    enum Element { case outlineAndDueQueue, sessionControls, activePromptOrSpeaker }
    struct Pane: Equatable {
        let audience: Audience
        let elements: [Element]
    }

    var presentation: Presentation = .compact
    var showHint = false

    /// Ordered pane-intent snapshot. Upcoming cues, schedule/evidence, hints,
    /// permission, navigation, and grading belong only on private controls.
    /// Presentation may show only the active prompt/explicitly revealed answer
    /// or active speaker view. It must never render the private control view.
    var panes: [Pane] {
        switch presentation {
        case .compact:
            [Pane(audience: .privateControls, elements: [.activePromptOrSpeaker, .sessionControls])]
        case .simulatedCompanion, .simulatedSpanned:
            [Pane(audience: .privateControls, elements: [.outlineAndDueQueue, .sessionControls]),
             Pane(audience: .presentation, elements: [.activePromptOrSpeaker])]
        }
    }
}
