import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)

                    Text("Sprachhilfe")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("von Tarik Zengin")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Link(destination: URL(string: "https://www.linkedin.com/in/tarik-zengin-websky-app/")!) {
                        Label("LinkedIn", systemImage: "link")
                            .font(.callout)
                    }

                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    HStack(spacing: 8) {
                        Text("Version \(version) (\(build))")
                            .foregroundStyle(.secondary)

                        Button(localizedAppText("Check for Updates...", de: "Nach Updates suchen …")) {
                            UpdateChecker.shared?.checkForUpdates()
                        }
                        .controlSize(.small)
                        .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
                    }

                    Text(String(localized: "Fast, private speech-to-text for your Mac. Transcribe with local or cloud engines, process text with AI prompts, and insert directly into any app."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        openSetupWizard()
                    } label: {
                        Label(
                            localizedAppText("Open Setup Wizard", de: "Setup-Wizard öffnen"),
                            systemImage: "sparkles"
                        )
                    }
                    Spacer()
                }

                Text(localizedAppText(
                    "Run the first-time setup flow again without changing your saved settings.",
                    de: "Starte den Einrichtungsassistenten erneut, ohne deine gespeicherten Einstellungen zu ändern."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                VStack(spacing: 4) {
                    Text(String(localized: "\u{00A9} 2024-2026 Sprachhilfe Contributors"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Licensed under the GNU General Public License v3.0"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    private func openSetupWizard() {
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        NotificationCenter.default.post(name: .resetSetupWizardWindow, object: nil)
        ManagedAppWindowOpener.shared.open(id: "setup")
    }
}
