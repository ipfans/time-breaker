import SwiftUI

/// Both break plans. Edits apply immediately when valid; invalid edits leave the last valid
/// configuration in effect and explain why.
struct BreaksSettingsView: View {
    let model: AppModel
    let localizer: Localizer

    @State private var shortBreak: BreakConfiguration
    @State private var longBreak: BreakConfiguration
    @State private var issues: [PreferencesIssue] = []
    /// Field input rejected before it reached the configuration.
    @State private var rejectedInput: PreferencesIssue?

    init(model: AppModel, localizer: Localizer) {
        self.model = model
        self.localizer = localizer
        _shortBreak = State(initialValue: model.preferences.shortBreak)
        _longBreak = State(initialValue: model.preferences.longBreak)
    }

    var body: some View {
        Form {
            BreakPlanSection(configuration: $shortBreak, rejectedInput: $rejectedInput, localizer: localizer)
            BreakPlanSection(configuration: $longBreak, rejectedInput: $rejectedInput, localizer: localizer)

            if !displayedIssues.isEmpty {
                Section {
                    ForEach(displayedIssues, id: \.self) { issue in
                        Label {
                            Text(verbatim: localizer.message(for: issue))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                    }
                    Text(verbatim: localizer.string(.validationKeptPrevious))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(verbatim: localizer.string(.breaksFootnote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: shortBreak) { commit() }
        .onChange(of: longBreak) { commit() }
    }

    private var displayedIssues: [PreferencesIssue] {
        guard let rejectedInput, !issues.contains(rejectedInput) else { return issues }
        return [rejectedInput] + issues
    }

    private func commit() {
        var candidate = model.preferences
        candidate.shortBreak = shortBreak
        candidate.longBreak = longBreak
        issues = model.apply(candidate)
    }
}

private struct BreakPlanSection: View {
    @Binding var configuration: BreakConfiguration
    @Binding var rejectedInput: PreferencesIssue?
    let localizer: Localizer

    private var isShort: Bool { configuration.kind == .short }

    var body: some View {
        Section {
            Toggle(isOn: $configuration.isEnabled) {
                Text(verbatim: localizer.string(.breaksEnabled))
            }

            Group {
                LabeledContent {
                    NumberField(
                        value: workMinutes,
                        range: BreakConfiguration.workIntervalMinutesRange,
                        unit: localizer.string(.unitMinutes),
                        accessibilityLabel: localizer.string(isShort ? .a11yShortWorkMinutes : .a11yLongWorkMinutes)
                    )
                } label: {
                    Text(verbatim: localizer.string(.breaksWorkInterval))
                }

                LabeledContent {
                    HStack(spacing: 12) {
                        NumberField(
                            value: durationMinutes,
                            range: 0...60,
                            unit: localizer.string(.unitMinutes),
                            accessibilityLabel: localizer.string(isShort ? .a11yShortDurationMinutes : .a11yLongDurationMinutes)
                        )
                        NumberField(
                            value: durationSeconds,
                            range: 0...59,
                            unit: localizer.string(.unitSeconds),
                            accessibilityLabel: localizer.string(isShort ? .a11yShortDurationSeconds : .a11yLongDurationSeconds)
                        )
                    }
                } label: {
                    Text(verbatim: localizer.string(.breaksDuration))
                }

                Toggle(isOn: $configuration.allowsSkip) {
                    Text(verbatim: localizer.string(.breaksAllowSkip))
                    Text(verbatim: localizer.string(.breaksAllowSkipHelp))
                }
            }
            .disabled(!configuration.isEnabled)

            Text(verbatim: summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(verbatim: localizer.string(isShort ? .breaksShortHeader : .breaksLongHeader))
        }
    }

    private var summary: String {
        guard configuration.isEnabled else { return localizer.string(.breaksDisabledSummary) }
        return localizer.format(
            .breaksSummary,
            localizer.duration(seconds: configuration.workIntervalSeconds),
            localizer.duration(seconds: configuration.breakDurationSeconds)
        )
    }

    /// Field values outside their own range are rejected rather than clamped, keeping the
    /// previous value and reporting the problem.
    private var workMinutes: Binding<Int> {
        Binding {
            configuration.workIntervalSeconds / 60
        } set: { minutes in
            guard let seconds = BreakConfiguration.workIntervalSeconds(minutes: minutes) else {
                rejectedInput = .workIntervalOutOfRange(configuration.kind)
                return
            }
            rejectedInput = nil
            configuration.workIntervalSeconds = seconds
        }
    }

    private var durationMinutes: Binding<Int> {
        Binding {
            configuration.breakDurationSeconds / 60
        } set: { minutes in
            setDuration(minutes: minutes, seconds: configuration.breakDurationSeconds % 60)
        }
    }

    private var durationSeconds: Binding<Int> {
        Binding {
            configuration.breakDurationSeconds % 60
        } set: { seconds in
            setDuration(minutes: configuration.breakDurationSeconds / 60, seconds: seconds)
        }
    }

    private func setDuration(minutes: Int, seconds: Int) {
        guard let total = BreakConfiguration.breakDurationSeconds(minutes: minutes, seconds: seconds) else {
            rejectedInput = .breakDurationOutOfRange(configuration.kind)
            return
        }
        rejectedInput = nil
        configuration.breakDurationSeconds = total
    }
}

/// An integer text field with a stepper and a unit label.
struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 4) {
            TextField(value: $value, format: .number.grouping(.never)) {
                Text(verbatim: accessibilityLabel)
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))

            Stepper(value: $value, in: range) {
                Text(verbatim: accessibilityLabel)
            }
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: accessibilityLabel))

            Text(verbatim: unit)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
