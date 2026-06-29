import Combine
import SwiftUI

/// The notch's UI state machine: closed / popping / opened, plus which content the opened notch
/// shows. Ported 1:1 from copilot-island's `NotchViewModel`, with `ContentType.chat` carrying a
/// Mispher ``NotchSession`` instead of a Copilot-CLI `HistoricalSession`.
enum NotchStatus: Equatable {
    case closed
    case popping
    case opened
}

enum NotchOpenReason {
    case click
    case hover
    case notification
}

enum ContentType: Equatable {
    case sessions
    case menu
    case chat(NotchSession)
}

struct NotchGeometry {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat
    let hasPhysicalNotch: Bool
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var status: NotchStatus = .closed
    @Published var contentType: ContentType = .sessions
    @Published var openReason: NotchOpenReason = .click

    let geometry: NotchGeometry

    private static let bootStepDuration: Double = 0.3
    private static let notchSpring = Animation.spring(response: 0.4, dampingFraction: 0.85)

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }
    var hasPhysicalNotch: Bool { geometry.hasPhysicalNotch }

    /// The opened notch's fixed width and its *maximum* height. The content sizes the notch within
    /// this cap (see ``NotchChatView``), so it grows stage by stage rather than always filling 400.
    var openedSize: CGSize { CGSize(width: 380, height: 440) }

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight,
            hasPhysicalNotch: hasPhysicalNotch
        )
    }

    func performBootAnimation() {
        withAnimation(.easeOut(duration: Self.bootStepDuration)) {
            status = .popping
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bootStepDuration) { [weak self] in
            withAnimation(.easeIn(duration: Self.bootStepDuration)) {
                self?.status = .closed
            }
        }
    }

    func notchOpen(reason: NotchOpenReason) {
        guard status == .closed else { return }
        openReason = reason

        withAnimation(Self.notchSpring) {
            status = .popping
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            withAnimation(Self.notchSpring) {
                self?.status = .opened
            }
        }
    }

    func notchClose() {
        withAnimation(Self.notchSpring) {
            status = .closed
        }
    }

    func toggleMenu() {
        if status == .opened, contentType == .menu {
            withAnimation(Self.notchSpring) { contentType = .sessions }
        } else if status == .opened {
            withAnimation(Self.notchSpring) { contentType = .menu }
        }
    }
}
