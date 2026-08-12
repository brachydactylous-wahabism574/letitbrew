import Foundation
import Testing

private func settingsViewSource() throws -> String {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repository.appendingPathComponent(
            "Sources/LetItBrewApp/LetItBrewSettingsView.swift"
        ),
        encoding: .utf8
    )
}

@Test func settingsNavigationHasFourExplicitOrderedPanes() throws {
    let source = try settingsViewSource()
    let declarations = source
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("case ") && $0.contains(" = \"") }

    #expect(declarations == [
        "case general = \"General\"",
        "case agents = \"Agents\"",
        "case safety = \"Safety\"",
        "case about = \"About\"",
    ])
    #expect(source.contains("@State private var selectedPane: SettingsPane = .general"))
    #expect(source.contains("ForEach(SettingsPane.allCases)"))
    #expect(source.contains("switch selectedPane"))
    #expect(!source.contains("TabView"))
    #expect(!source.contains(".tabItem"))
}

@Test func settingsPaneControlsPreserveKeyboardAndAccessibilityContract() throws {
    let source = try settingsViewSource()

    #expect(source.contains("@FocusState private var focusedPane: SettingsPane?"))
    #expect(source.contains("Button {\n            selectedPane = pane"))
    #expect(source.contains(".focusSection()"))
    #expect(source.contains(".focused($focusedPane, equals: pane)"))
    #expect(source.contains(".stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)"))
    #expect(source.contains(".accessibilityLabel(pane.title)"))
    #expect(source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
    #expect(source.contains(".accessibilityIdentifier(\"settings-pane-\\(pane.id)\")"))
}

@Test func aboutUpdateControlKeepsOneClickAndDialogDismissalContracts() throws {
    let source = try settingsViewSource()

    #expect(source.contains("Button(\"Check for Updates…\")"))
    #expect(source.contains("Button(\"Install Update\") { model.confirmUpdate() }"))
    #expect(source.contains("if !presented && !model.updateInProgress"),
            "SwiftUI's false write after Install must not cancel the confirmed update.")
    #expect(source.contains(".sheet(isPresented: updateCompletionReportBinding)"),
            "The update result must be presented from the Settings root, not only About.")
    #expect(!source.localizedCaseInsensitiveContains("beta channel"))
    #expect(!source.localizedCaseInsensitiveContains("stable channel"))
    #expect(!source.localizedCaseInsensitiveContains("automatically check"))
}
