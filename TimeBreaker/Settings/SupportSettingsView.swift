import StoreKit
import SwiftUI

/// Optional tips. Prices come from the App Store; tip names follow the app language.
struct SupportSettingsView: View {
    let tipJar: TipJar
    let localizer: Localizer
    let purchase: TipJar.Purchase

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: localizer.string(.supportTitle))
                            .font(.headline)
                        Text(verbatim: localizer.string(.supportMessage))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                }
            }

            Section {
                switch tipJar.availability {
                case .notLoaded, .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: localizer.string(.supportLoading))
                            .foregroundStyle(.secondary)
                    }
                case .available:
                    ForEach(TipJar.Tier.allCases, id: \.self) { tier in
                        if let product = tipJar.products[tier] {
                            tipRow(tier, product: product)
                        }
                    }
                case .unavailable:
                    LabeledContent {
                        Button {
                            Task { await tipJar.loadProducts() }
                        } label: {
                            Text(verbatim: localizer.string(.supportRetry))
                        }
                    } label: {
                        Text(verbatim: localizer.string(.supportUnavailable))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            switch tipJar.status {
            case .thanked:
                Section {
                    statusLabel(localizer.string(.supportThanks), systemImage: "heart.circle.fill", color: .pink)
                }
            case .pending:
                Section {
                    statusLabel(localizer.string(.supportPending), systemImage: "clock.fill", color: .secondary)
                }
            case .failed:
                Section {
                    statusLabel(localizer.string(.supportFailed), systemImage: "exclamationmark.triangle.fill", color: .red)
                }
            case .idle, .purchasing:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .task { await tipJar.loadProducts() }
    }

    private func tipRow(_ tier: TipJar.Tier, product: Product) -> some View {
        let name = localizer.string(tier.title)
        return LabeledContent {
            Button {
                Task {
                    await tipJar.purchase(tier, using: purchase)
                }
            } label: {
                Group {
                    if tipJar.status == .purchasing(tier) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(verbatim: product.displayPrice)
                            .monospacedDigit()
                    }
                }
                .frame(minWidth: 64)
            }
            .disabled(tipJar.isPurchasing)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(Text(verbatim: product.displayPrice))
        } label: {
            Text(verbatim: name)
        }
    }

    private func statusLabel(_ message: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
    }
}

private extension TipJar.Tier {
    var title: L10n {
        switch self {
        case .small: .supportTipSmall
        case .medium: .supportTipMedium
        case .large: .supportTipLarge
        }
    }
}
