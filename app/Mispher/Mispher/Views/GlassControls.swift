import AppKit
import SwiftUI

/// Settings controls styled in the HUD's glass/cyan language so they stop looking
/// like stock AppKit widgets: a compact accent switch, a glass segmented control,
/// and a glass dropdown that matches the header model picker.

/// The pill + animated knob shared by `GlassToggleStyle` and `GlassSwitch`.
private struct GlassTrack: View {
    let isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Palette.accent : Color.white.opacity(0.14))
            .frame(width: 38, height: 22)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .offset(x: isOn ? 16 : 0)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
            }
            .overlay(
                Capsule().strokeBorder(.white.opacity(isOn ? 0 : 0.10), lineWidth: 0.75)
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isOn)
    }
}

/// A compact pill switch with an animated knob. The whole labelled row is tappable.
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                GlassTrack(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A standalone accent switch (no label row), for compact rows that lay out their
/// own label — e.g. the on-device model list.
struct GlassSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            GlassTrack(isOn: isOn).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A text field in the HUD's glass language: a translucent rounded fill with a hairline
/// border that lights up accent when focused — so the Settings forms stop using the stock
/// AppKit `.roundedBorder` box, which reads as a flat black widget against the glass.
/// Supports a single line or a growing multi-line editor (`axis: .vertical`, bounded by
/// `lineLimit`).
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>?
    var fontSize: CGFloat = 11.5

    @FocusState private var focused: Bool

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(.sans(fontSize))
            .foregroundStyle(Palette.fg)
            .tint(Palette.accent)
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? Palette.accent.opacity(0.55) : Palette.border,
                        lineWidth: focused ? 1 : 0.75
                    )
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }

    @ViewBuilder private var field: some View {
        if axis == .vertical {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(lineLimit ?? 1 ... 6)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

/// A compact pill button in the HUD's glass language: a translucent rounded chip with a
/// hairline border that dims on press and when disabled. `prominent` tints it accent (for a
/// primary action like Connect); otherwise it's a neutral glass chip (Edit, Reconnect).
struct GlassPillButtonStyle: ButtonStyle {
    var prominent: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = prominent ? Palette.accent : Palette.fg1
        let fill: Color = prominent ? Palette.accent.opacity(0.14) : .white.opacity(0.06)
        let stroke: Color = prominent ? Palette.accent.opacity(0.32) : Palette.border
        return configuration.label
            .font(.sans(11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.75)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// A small glass segmented control (e.g. int8 / fp32). Selected segment fills accent.
struct GlassSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var isEnabled = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(label: option.label, isSelected: option.value == selection) {
                    selection = option.value
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        // Keep the intrinsic width so a narrow container can't squeeze the segments and wrap
        // a label across two lines (e.g. "Trigger" → "Trigg/er").
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
    }

    private func segment(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let fill: Color = isSelected ? Palette.accent : .clear
        let textColor: Color = isSelected ? Palette.bgDeep : Palette.fg1
        return Button(action: action) {
            Text(label)
                .font(.sans(11, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A vertical list of selectable option rows in the HUD's glass language -- an on-theme
/// replacement for a native dropdown when there are a few descriptive choices. Each row shows an
/// icon, a label, and a one-line description; the selected row is tinted accent with a checkmark.
struct GlassOptionPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        let detail: String
        let systemImage: String
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        VStack(spacing: 6) {
            ForEach(options) { row($0) }
        }
    }

    private func row(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button { selection = option.value } label: {
            HStack(spacing: 11) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.fg2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.sans(12.5, weight: .medium))
                        .foregroundStyle(Palette.fg)
                    Text(option.detail)
                        .font(.sans(11))
                        .foregroundStyle(Palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Palette.accentSoft : .white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? Palette.accent.opacity(0.5) : Palette.border,
                        lineWidth: isSelected ? 1 : 0.75
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}

/// A glass dropdown: a pill + chevron that opens a translucent, arrow-less list flush beneath it.
/// The list is a borderless glass panel (not a stock `NSMenu`, and not a SwiftUI `.popover`, which
/// always draws an arrow), so it matches the app's look. Generic over the selection value.
struct GlassDropdown<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var maxWidth: CGFloat = 200
    var isEnabled = true
    /// An explicit label for the trigger pill, when it should read differently from the
    /// selected option's row label — e.g. a compact short name in the pill while the list
    /// shows full "name · detail" rows.
    var displayLabel: String?
    /// Whether a given option can be picked; others render greyed and inert (with `disabledHint`).
    var isOptionEnabled: (Value) -> Bool = { _ in true }
    /// Trailing hint shown on disabled rows, e.g. "Download in Settings".
    var disabledHint: String?
    /// A leading SF Symbol shown in the trigger pill (e.g. "waveform" for the ASR model).
    var icon: String?
    /// Accent-highlight the trigger pill (fill + border + text) to mark it as active/selected.
    var isActive = false

    @State private var isOpen = false
    /// The rendered pill width, so the panel can match it -- the list then looks anchored to the
    /// trigger instead of floating wider or narrower than it.
    @State private var triggerWidth: CGFloat = 0

    private var currentLabel: String {
        displayLabel ?? options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? Palette.accent : Palette.fg2)
                }
                Text(currentLabel)
                    .font(.sans(11.5, weight: .medium))
                    .foregroundStyle(isActive ? Palette.accent : Palette.fg1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isOpen || isActive ? Palette.accent : Palette.fg2)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Palette.accentSoft : .white.opacity(isOpen ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOpen || isActive ? Palette.accentGlow : .white.opacity(0.08), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { triggerWidth = $0 })
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.15), value: isOpen)
        .glassDropdownPanel(isPresented: $isOpen) {
            GlassMenuCard(minWidth: triggerWidth) {
                VStack(spacing: 1) {
                    ForEach(options, id: \.value) { option in
                        let enabled = isOptionEnabled(option.value)
                        GlassDropdownRow(
                            label: option.label,
                            isSelected: option.value == selection,
                            isEnabled: enabled,
                            hint: enabled ? nil : disabledHint
                        ) {
                            selection = option.value
                            isOpen = false
                        }
                    }
                }
            }
        }
    }
}

/// Shared metrics for the dropdown panel (a generic type can't hold static stored properties).
enum GlassDropdownMetrics {
    /// Transparent room around the card so its drop shadow isn't clipped by the panel bounds.
    static let shadowInset: CGFloat = 16
}

/// The translucent glass card that hosts a dropdown/menu's rows inside the flush panel: a material
/// background, hairline border, rounded corners, and its own soft shadow. Reused by ``GlassDropdown``
/// and the HUD's translate menu.
struct GlassMenuCard<Content: View>: View {
    /// The trigger's width; the card won't render narrower than this (with a small floor) so it
    /// reads as a dropdown from the trigger rather than a detached, mismatched panel.
    var minWidth: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(5)
                .frame(minWidth: max(minWidth, 132), alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: true, vertical: false)
        .background(glassMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Palette.borderStrong, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.45), radius: 13, y: 7)
        .padding(GlassDropdownMetrics.shadowInset)
        .preferredColorScheme(.dark)
    }

    private var glassMaterial: some View {
        ZStack {
            VisualEffectView(material: .menu, blending: .behindWindow)
            Palette.glassFill.opacity(0.45)
        }
    }
}

/// A small uppercase section divider inside a ``GlassMenuCard`` (e.g. "Language", "Model").
struct GlassMenuSectionHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.sans(9.5, weight: .semibold))
            .foregroundStyle(Palette.fg3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 2)
    }
}

/// A row inside a ``GlassMenuCard``: a leading checkmark slot and the label, with an optional
/// trailing hint. The current selection stays accent-tinted; hover adds a soft translucent accent
/// wash (glassy, not a solid block). Disabled rows grey out and don't respond.
struct GlassDropdownRow: View {
    let label: String
    var isSelected = false
    var isEnabled = true
    var hint: String?
    let action: () -> Void
    @State private var hovering = false

    private var foreground: Color {
        if !isEnabled { return Palette.fg3 }
        if isSelected { return Palette.accent }
        return hovering ? Palette.fg : Palette.fg1
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if hovering { return Palette.accent.opacity(isSelected ? 0.22 : 0.16) }
        return isSelected ? Palette.accent.opacity(0.10) : .clear
    }

    var body: some View {
        Button { if isEnabled { action() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 13)
                    .opacity(isSelected ? 1 : 0)
                Text(label)
                    .font(.sans(12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 16)
                if let hint {
                    Text(hint)
                        .font(.sans(10.5))
                        .foregroundStyle(Palette.fg3)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = isEnabled && $0 }
    }
}

extension View {
    /// Present `content` as a flush glass dropdown/menu panel below this view (no popover arrow),
    /// shown while `isPresented` is true. Use a ``GlassMenuCard`` as the content's root.
    func glassDropdownPanel(
        isPresented: Binding<Bool>, @ViewBuilder content: () -> some View
    ) -> some View {
        background(GlassDropdownAnchor(isOpen: isPresented, content: content))
    }
}

/// Bridges to AppKit to present a ``GlassMenuCard`` as a borderless child panel flush below the
/// trigger -- giving a real dropdown (no popover arrow) that can use a translucent glass material.
private struct GlassDropdownAnchor<Content: View>: NSViewRepresentable {
    @Binding var isOpen: Bool
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator { isOpen = false } }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.requestClose = { isOpen = false }
        coordinator.update(content: content, open: isOpen)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var requestClose: () -> Void
        private var panel: NSPanel?
        private var hosting: NSHostingView<AnyView>?
        private var globalMonitor: Any?
        private var localMonitor: Any?

        init(requestClose: @escaping () -> Void) { self.requestClose = requestClose }

        func update(content: some View, open: Bool) {
            let wrapped = AnyView(content)
            hosting?.rootView = wrapped
            if open { present(wrapped) } else { dismiss() }
        }

        private func present(_ content: AnyView) {
            guard panel == nil, let anchor, let parent = anchor.window else { return }
            let host = NSHostingView(rootView: content)
            // Measure the content's natural size FIRST, while the hosting view still has its default
            // (content-driven) sizing constraints. If `sizingOptions = []` is set *before* this, the
            // host holds no content constraints, so `fittingSize` collapses to ~`.zero` and the panel
            // opens invisible with no hit area - the dropdown silently "doesn't work". Measure, then
            // stop the host driving the panel size (the macOS 26 default) so it can't fight our fixed
            // frame in a runaway layout pass.
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            host.sizingOptions = []
            hosting = host

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false // the SwiftUI card draws its own shadow within `shadowInset`
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            host.autoresizingMask = [.width, .height]
            panel.contentView = host

            position(panel, size: size, anchor: anchor, parent: parent)
            parent.addChildWindow(panel, ordered: .above)
            self.panel = panel
            installMonitors()
        }

        /// Place the card flush under the trigger: the card sits `shadowInset` inside the panel, so
        /// offset the panel by that inset to align the visible card's top-left with the pill. The
        /// card is then nudged left if it would overflow the parent window's right edge, so the
        /// dropdown stays within the window rather than spilling past it.
        private func position(_ panel: NSPanel, size: NSSize, anchor: NSView, parent: NSWindow) {
            let inset = GlassDropdownMetrics.shadowInset
            let margin: CGFloat = 8
            let rectInWindow = anchor.convert(anchor.bounds, to: nil)
            let screenRect = parent.convertToScreen(rectInWindow)
            var x = screenRect.minX - inset
            let y = screenRect.minY - 3 + inset - size.height

            // Keep the visible card (panel minus its transparent shadow inset) inside the window.
            let cardWidth = size.width - inset * 2
            let maxCardLeft = parent.frame.maxX - margin - cardWidth
            let minCardLeft = parent.frame.minX + margin
            let cardLeft = min(max(screenRect.minX, minCardLeft), max(minCardLeft, maxCardLeft))
            x = cardLeft - inset
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        }

        private func dismiss() {
            guard let panel else { return }
            removeMonitors()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
            hosting = nil
        }

        func tearDown() {
            removeMonitors()
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel = nil
            hosting = nil
        }

        private func installMonitors() {
            // Click in another app: close.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.requestClose()
            }
            // Click elsewhere in this app: close -- unless it's inside the panel, or on the trigger
            // itself (whose button toggles it closed, so closing here too would just reopen it).
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let panel else { return event }
                if event.window == panel { return event }
                if let anchor, event.window == anchor.window,
                   anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) {
                    return event
                }
                requestClose()
                return event
            }
        }

        private func removeMonitors() {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
        }
    }
}
