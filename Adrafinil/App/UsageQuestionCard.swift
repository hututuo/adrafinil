import Digoxin
import Propofol
import SwiftUI

/// Digoxin's question: whether this Mac is counted among Adrafinil's users. Asked once, the
/// first time the popover opens without a stored choice (so a copy updated from an earlier
/// version is asked too); Settings › General holds the choice from then on.
struct UsageQuestionCard: View {
    @State private var isAsking = UsageCounting.tier == nil
    @State private var activeCount: Int?

    var body: some View {
        if isAsking {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    Image(systemName: "person.2")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.awake)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Count yourself in")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        Text("One anonymous check-in a day counts how many people use Adrafinil. It never includes what you work on or which agents you run. Settings › General lists what is sent.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let activeCount {
                            Text("Yesterday, \(activeCount) Macs counted themselves in.")
                                .font(.caption).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Theme.Space.sm) {
                    Button { answer(.off) } label: {
                        Text("Not Now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    Button { answer(.counting) } label: {
                        Text("Count Me In").frame(maxWidth: .infinity).foregroundStyle(Theme.onAwake)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Theme.awake)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: Theme.awake.opacity(0.16))
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            .task { activeCount = await ActiveCount.shared.value() }
        }
    }

    private func answer(_ tier: ConsentTier) {
        UsageCounting.choose(tier)
        withAnimation(.smooth(duration: 0.3)) { isAsking = false }
    }
}
