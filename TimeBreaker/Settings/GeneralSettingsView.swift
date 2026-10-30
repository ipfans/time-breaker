import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    let model: AppModel
    let localizer: Localizer

    private var launchAtLogin: LaunchAtLoginController { model.launchAtLogin }

    var body: some View {
        Form {
            Section {
                Picker(selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.nativeName).tag(language)
                    }
                } label: {
                    Text(verbatim: localizer.string(.generalLanguage))
                    Text(verbatim: localizer.string(.generalLanguageHelp))
                }
            }

            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    Text(verbatim: localizer.string(.generalLaunchAtLogin))
                    Text(verbatim: loginStatusText)
                }
                if launchAtLogin.status == .requiresApproval {
                    Button {
                        launchAtLogin.openSystemSettings()
                    } label: {
                        Text(verbatim: localizer.string(.loginOpenSettings))
                    }
                }
                if let error = launchAtLogin.errorDescription {
                    Label {
                        Text(verbatim: localizer.format(.loginError, error))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent {
                    Text(verbatim: localizer.format(.generalVersion, Self.version))
                        .textSelection(.enabled)
                } label: {
                    Text(verbatim: localizer.string(.appName))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            model.preferences.language
        } set: { language in
            var candidate = model.preferences
            candidate.language = language
            model.apply(candidate)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLogin.isEnabled
        } set: { enabled in
            launchAtLogin.setEnabled(enabled)
        }
    }

    private var loginStatusText: String {
        switch launchAtLogin.status {
        case .enabled: localizer.string(.loginStatusEnabled)
        case .requiresApproval: localizer.string(.loginStatusRequiresApproval)
        case .notFound: localizer.string(.loginStatusNotFound)
        default: localizer.string(.loginStatusNotRegistered)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
