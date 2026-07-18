import SwiftUI

struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text(String(localized: "Welcome to Sprachhilfe!"))
                .font(.title2.bold())

            Text(localizedAppText(
                "Fast, private speech-to-text for your Mac. Transcribe with local or cloud engines and process text with AI workflows.",
                de: "Schnelle, private Spracherkennung für deinen Mac. Transkribiere mit lokalen oder Cloud-Modellen und verarbeite Text mit KI-Workflows."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 400)

            Text(localizedAppText(
                "Sprachhilfe is free and open source (GPLv3).",
                de: "Sprachhilfe ist kostenlos und quelloffen (GPLv3)."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button {
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
                dismiss()
            } label: {
                Text(localizedAppText("Get Started", de: "Los geht's"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 440)
    }
}
