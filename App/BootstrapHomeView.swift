import SetFlowKit
import SwiftUI

struct BootstrapHomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Set Flow")
                        .font(.largeTitle.bold())
                    Text("Local-first workout circuits with deterministic set queues and large rest-timer controls.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Native iPhone foundation is ready", systemImage: "checkmark.circle")
                        Text("Routine editor, session runner, rest timer, and private history land in the next milestones.")
                            .foregroundStyle(.secondary)
                        Text("Domain core milestone: \(SetFlowKit.milestone).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .navigationTitle("Home")
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}
