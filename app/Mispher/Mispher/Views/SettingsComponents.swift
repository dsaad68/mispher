import DeepAgentsMLX
import SwiftUI

// Shared building blocks for the Settings panels (and the model lists they host), so every
// section — General, Shortcuts, ASR Models, Local models — speaks one glass design
// language: an uppercase `SectionLabel`, a grouped `SettingsCard`, labelled rows, and a
// single accent `Badge`. Promoted out of `SettingsView` so `ModelManagerView` and
// `LocalModelsView` can reuse them instead of hand-rolling their own.

// MARK: - Grouping

/// A grouped settings card: a rounded translucent surface with a hairline border, matching
/// the HUD's glass language. Lays its rows out in a column.
struct SettingsCard<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.75)
        )
    }
}

/// A small uppercase heading above a settings card.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.sans(10, weight: .semibold))
            .foregroundStyle(Palette.fg3)
            .tracking(0.6)
            .padding(.leading, 2)
    }
}

/// A tinted pill badge (e.g. "Vision", "Active", "Resident"). Defaults to the accent tint.
struct Badge: View {
    let text: String
    var tint: Color = Palette.accent

    var body: some View {
        Text(text)
            .font(.sans(9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
    }
}

// MARK: - Rows

/// A settings row with a title, subtitle, and a `GlassToggleStyle` switch.
struct SettingToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sans(12.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(subtitle)
                    .font(.sans(11))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(GlassToggleStyle())
    }
}

/// Shared row layout for the model lists (ASR Models + Local models) so the two read as
/// siblings: a title with optional badges, a subtitle, a trailing control, and optional
/// extra content (per-model options) beneath.
struct ModelRowLayout<Badges: View, Trailing: View, Extra: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var badges: () -> Badges
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var extra: () -> Extra

    init(
        title: String,
        subtitle: String,
        @ViewBuilder badges: @escaping () -> Badges = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badges = badges
        self.trailing = trailing
        self.extra = extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.sans(12.5, weight: .medium))
                            .foregroundStyle(Palette.fg)
                        badges()
                    }
                    Text(subtitle)
                        .font(.sans(11))
                        .foregroundStyle(Palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing()
            }
            extra()
        }
        .padding(.vertical, 5)
    }
}

/// A small amber line noting a model's approximate resident memory, shown beneath a model picker so
/// the cost of a choice is visible before it's downloaded or loaded. Resolves the id against the
/// catalog and renders nothing for an unknown or empty id (e.g. the vision "None" option).
struct ModelMemoryHint: View {
    let modelId: String

    var body: some View {
        if let model = MlxModel.catalog.first(where: { $0.id == modelId }) {
            Text("~\(model.sizeLabel) memory")
                .font(.sans(10.5, weight: .medium))
                .foregroundStyle(Palette.warm)
        }
    }
}

/// A labelled settings row with a trailing control (e.g. a key recorder or model controls).
struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sans(12.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(subtitle)
                    .font(.sans(11))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
