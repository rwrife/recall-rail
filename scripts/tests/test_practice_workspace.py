"""Linux structural contracts; Apple behavior tests remain in XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class WorkspaceStructureTests(unittest.TestCase):
    def test_pane_intent_snapshot_and_no_session_copy(self):
        source = (ROOT / 'RecallRail/PracticeWorkspaceLayout.swift').read_text()
        self.assertIn('case compact, simulatedCompanion, simulatedSpanned', source)
        self.assertIn('Pane(audience: .privateControls, elements: [.outlineAndDueQueue, .sessionControls])', source)
        self.assertIn('Pane(audience: .presentation, elements: [.activePromptOrSpeaker])', source)
        self.assertIn('Pane(audience: .privateControls, elements: [.activePromptOrSpeaker, .sessionControls])', source)
        for forbidden in ['StudySession', 'PracticeService', 'RecallStore', 'RecallRailKit']:
            self.assertNotIn(forbidden, source)

    def test_compact_accessibility_and_keyboard_structure(self):
        source = (ROOT / 'RecallRail/PracticeView.swift').read_text()
        self.assertIn('model.workspace', source)
        self.assertIn('ScrollView', source)
        self.assertIn('.frame(maxWidth: .infinity, minHeight: 44)', source)
        for shortcut in ['"r"', '"z"', '.return']:
            self.assertIn('.keyboardShortcut(' + shortcut, source)
        self.assertIn('.keyboardShortcut(gradeKey(grade), modifiers: [])', source)
        for grade, key in [('again', '1'), ('hard', '2'), ('recalled', '3')]:
            self.assertIn(f'case .{grade}: "{key}"', source)
        self.assertIn('.accessibilityAction(named: "Reveal answer")', source)
        self.assertIn('.accessibilityAddTraits(.isHeader)', source)
        self.assertNotIn('.animation(', source)
        self.assertNotIn('.foregroundStyle(.red)', source)
        # The shared control style must keep destructive role distinction.
        style = source[source.index('struct PracticeControlStyle'):]
        self.assertIn('configuration.role == .destructive', style)
        self.assertIn('systemRed', style)
        # The Dynamic Type journey needs an in-app effective-size probe.
        self.assertIn('--rr-size-probe', source)
        self.assertIn('preferredContentSizeCategory', source)
        self.assertIn('practice.size-category', source)
        # Identifiers belong to leaf controls/text, never workspace containers.
        self.assertNotIn('.accessibilityIdentifier("practice.workspace")', source)
        self.assertLess(source.index('Text(card.prompt)'), source.index('Text(card.answer)'))
        self.assertLess(source.index('Text(card.answer)'), source.index('ForEach(Grade.allCases'))

    def test_iphone_supports_both_orientations(self):
        project = (ROOT / 'RecallRail.xcodeproj/project.pbxproj').read_text()
        settings = [line for line in project.splitlines()
                    if 'INFOPLIST_KEY_UISupportedInterfaceOrientations =' in line]
        self.assertEqual(len(settings), 2)
        for setting in settings:
            for orientation in ['Portrait', 'LandscapeLeft', 'LandscapeRight']:
                self.assertIn('UIInterfaceOrientation' + orientation, setting)

    def test_ci_runs_structural_contract(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('run: python3 scripts/tests/test_practice_workspace.py', workflow)

    def test_domain_remains_posture_independent(self):
        for path in (ROOT / 'Packages').rglob('*.swift'):
            if '.build' not in path.parts:
                self.assertNotIn('PracticeWorkspaceLayout', path.read_text(), str(path))

if __name__ == '__main__':
    unittest.main()
