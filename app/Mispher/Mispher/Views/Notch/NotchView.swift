import DeepAgents
import SwiftUI

// Ported 1:1 from copilot-island's `NotchView` (the dynamic-island container: closed/popping/opened
// lifecycle, activity indicators, springs, and the HITL approval card), re-wired to Mispher's
// ``NotchSessionStore``. The Copilot-CLI-only bits (plugin setup, the "approve in terminal" hint, and
// the Skip button) are removed; the approval card drives `MlxModelManager`'s tool-approval flow.

private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

private let minNotchWidth: CGFloat = 204

private let notchSpringOpen = Animation.spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0)
private let notchSpringClose = Animation.spring(response: 0.42, dampingFraction: 0.85, blendDuration: 0)
private let notchSpringHover = Animation.spring(response: 0.38, dampingFraction: 0.82)
private let contentAppearAnimation = Animation.easeOut(duration: 0.4)
private let approvalBounceSpring = Animation.spring(response: 0.35, dampingFraction: 0.6)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var store: NotchSessionStore

    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var hasReceivedFirstEvent: Bool = false
    @State private var approvalBounceTimer: Timer?
    @State private var approvalAutoTimer: Timer?
    @State private var approvalCountdown: Int = 20

    @Namespace private var activityNamespace

    // MARK: - Derived phase

    private var isProcessing: Bool {
        if case .processing = store.phase { return true }
        if case .runningTool = store.phase { return true }
        return false
    }

    private var isIdle: Bool {
        if case .idle = store.phase { return true }
        return false
    }

    private var hasError: Bool {
        if case .error = store.phase { return true }
        return false
    }

    private var needsApproval: Bool {
        if case .waitingForApproval = store.phase { return true }
        return false
    }

    private var hasNewMessage: Bool {
        !store.sessionsWithNewMessages.isEmpty
    }

    // MARK: - Sizing

    private var baseClosedNotchSize: CGSize {
        CGSize(width: viewModel.deviceNotchRect.width, height: viewModel.deviceNotchRect.height)
    }

    private var expansionWidth: CGFloat {
        if isProcessing || hasError || needsApproval || hasNewMessage {
            return 2 * max(0, baseClosedNotchSize.height - 12) + 60
        }
        return 0
    }

    private var closedNotchSize: CGSize {
        CGSize(width: baseClosedNotchSize.width + expansionWidth, height: baseClosedNotchSize.height)
    }

    private var notchSize: CGSize {
        let size: CGSize
        switch viewModel.status {
        case .closed, .popping: size = closedNotchSize
        case .opened: size = viewModel.openedSize
        }
        return CGSize(width: max(size.width, minNotchWidth), height: size.height)
    }

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) { notchLayout }
        }
        .frame(width: notchSize.width, alignment: .top)
        .padding(.horizontal, viewModel.status == .opened ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.bottom)
        .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
        .background(.black)
        .clipShape(currentNotchShape)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.black)
                .frame(height: 1)
                .padding(.horizontal, topCornerRadius)
        }
        .shadow(color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear, radius: 6)
        .frame(maxHeight: viewModel.status == .opened ? notchSize.height : closedNotchSize.height, alignment: .top)
        .animation(viewModel.status == .opened ? notchSpringOpen : notchSpringClose, value: viewModel.status)
        .animation(.smooth, value: isProcessing)
        .animation(.smooth, value: hasError)
        .animation(.smooth, value: needsApproval)
        .animation(.smooth, value: hasNewMessage)
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            isVisible = true
            if store.sessionActive { showChatIfNeeded() }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: store.phase) { _, _ in handlePhaseChange() }
        .onChange(of: store.sessionActive) { _, active in
            if active {
                isVisible = true
                if viewModel.status == .closed { viewModel.notchOpen(reason: .notification) }
                showChatIfNeeded()
            }
        }
        // A new capture starting: reopen and jump to the chat even when the Ask session was already
        // active. `sessionActive` (askOverlaySessionActive) is sticky, so its onChange above won't
        // re-fire when you browse the session list, close the notch, then speak again - `isCapturing`
        // does transition, so this brings the live transcription pill back into view.
        .onChange(of: store.isCapturing) { _, capturing in
            guard capturing else { return }
            isVisible = true
            if viewModel.status == .closed { viewModel.notchOpen(reason: .notification) }
            if !isInChatMode, let id = store.threadId {
                let session = NotchSession(id: id, title: "New conversation", subtitle: nil, preview: nil, date: nil)
                withAnimation(notchSpringHover) { viewModel.contentType = .chat(session) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(notchSpringHover) { isHovering = hovering }
        }
        // Opening on a click is handled by the window controller's global monitor (the panel ignores
        // mouse events while closed); no SwiftUI tap gesture here, so it can't swallow taps meant for
        // the compose field when open.
    }

    private var showActivity: Bool {
        isProcessing || hasError || needsApproval || hasNewMessage
    }

    private var isInChatMode: Bool {
        if case .chat = viewModel.contentType { return true }
        return false
    }

    // MARK: - Layout

    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .frame(height: closedNotchSize.height)

            if viewModel.status != .closed {
                contentView
                    .frame(width: notchSize.width - 24)
                    .frame(maxWidth: .infinity)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.92, anchor: .top)
                                .combined(with: .opacity)
                                .animation(contentAppearAnimation),
                            removal: .opacity.animation(.easeOut(duration: 0.2))
                        )
                    )
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            // The sparkles activity glyph is the closed pill's "something's happening" cue only; once
            // opened, the left is the green brand (above) and activity shows via the trailing spinner.
            if showActivity, viewModel.status != .opened {
                HStack(spacing: 4) {
                    NotchAppIcon(size: 14, animate: isProcessing)
                        .matchedGeometryEffect(id: "icon", in: activityNamespace, isSource: showActivity)

                    if hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .matchedGeometryEffect(id: "status", in: activityNamespace, isSource: showActivity)
                    }

                    if needsApproval {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .matchedGeometryEffect(id: "status", in: activityNamespace, isSource: showActivity)
                    }
                }
                .frame(width: viewModel.status == .opened ? nil : sideWidth, alignment: .leading)
                .padding(.leading, viewModel.status == .opened ? 8 : 4)
            }

            if viewModel.status == .opened {
                openedHeaderContent
            } else if !showActivity {
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else if isProcessing || hasNewMessage {
                Rectangle()
                    .fill(.clear)
                    .frame(width: baseClosedNotchSize.width - cornerRadiusInsets.closed.top)
            } else {
                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
            }

            if showActivity {
                trailingActivity
            }
        }
        .frame(height: closedNotchSize.height)
    }

    @ViewBuilder private var trailingActivity: some View {
        if isProcessing {
            Group {
                if viewModel.status == .opened { ProcessingSpinner() } else { StarburstView(size: 12) }
            }
            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showActivity)
            .frame(width: viewModel.status == .opened ? 20 : sideWidth, alignment: .trailing)
            .padding(.trailing, viewModel.status == .opened ? 0 : 4)
        } else if needsApproval {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: Color.orange.opacity(0.5), radius: 2)
                .scaleEffect(isBouncing ? 1.3 : 1.0)
                .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showActivity)
                .frame(width: viewModel.status == .opened ? 20 : sideWidth, alignment: .trailing)
                .padding(.trailing, viewModel.status == .opened ? 0 : 4)
        } else if hasError {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
                .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showActivity)
                .frame(width: viewModel.status == .opened ? 20 : sideWidth, alignment: .trailing)
                .padding(.trailing, viewModel.status == .opened ? 0 : 4)
        } else if hasNewMessage {
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 6, height: 6)
                .shadow(color: Color.logoCyan.opacity(0.5), radius: 3)
                .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showActivity)
                .frame(width: viewModel.status == .opened ? 20 : sideWidth, alignment: .trailing)
                .padding(.trailing, viewModel.status == .opened ? 0 : 4)
        }
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 30
    }

    private var openedHeaderContent: some View {
        HStack(spacing: 8) {
            // In a conversation, the back chevron lives here next to the brand (no separate header
            // row below), so it returns to the session list.
            if isInChatMode {
                Button {
                    withAnimation(notchSpringHover) { viewModel.contentType = .sessions }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .help("Conversations")
            }

            // Always the green brand once opened - including while a reply streams (the activity is
            // shown by the trailing spinner, not by swapping the icon back to the old sparkles ear).
            BrandMarkView(size: 15)
                .padding(.leading, isInChatMode ? 0 : 8)
            // The wordmark only on the home page: in a conversation the back chevron takes its room,
            // and on a notched Mac the extra width would push "Mispher" under the hardware notch.
            if !isInChatMode {
                Text("Mispher")
                    .font(.title(14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer()

            headerTrailingButton
                .padding(.trailing, 4)
        }
    }

    /// The trailing ear buttons: a new-chat button (in every mode), plus the menu toggle on the home /
    /// session-list page - there the two sit side by side, mirroring the spot the lone new-chat button
    /// takes in a conversation.
    private var headerTrailingButton: some View {
        HStack(spacing: 2) {
            newChatButton
            if !isInChatMode {
                menuButton
            }
        }
    }

    private var newChatButton: some View {
        Button(action: startNewChat) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Enabled whenever an Ask model is selected (you need one to open a conversation), so it's
        // never greyed at the moment you actually want to begin a new one.
        .disabled(!store.hasAskModel)
        .opacity(store.hasAskModel ? 1 : 0.35)
        .help("New chat")
    }

    /// "New chat": open a brand-new saved conversation (the previous one stays in the list) and drop
    /// into its empty chat. `newSession()` updates `store.threadId` synchronously, so the chat view can
    /// switch to the fresh thread right away.
    private func startNewChat() {
        store.newSession()
        if let id = store.threadId, !isInChatMode {
            let session = NotchSession(id: id, title: "New conversation", subtitle: nil, preview: nil, date: nil)
            withAnimation(notchSpringHover) { viewModel.contentType = .chat(session) }
        }
    }

    private var menuButton: some View {
        Button {
            withAnimation(notchSpringHover) { viewModel.toggleMenu() }
        } label: {
            Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var contentView: some View {
        Group {
            if needsApproval {
                approvalView
            } else if hasError, case .error(let message) = store.phase {
                errorNotificationView(message: message)
            } else {
                switch viewModel.contentType {
                case .sessions:
                    NotchSessionListView(store: store, onSelectSession: { session in
                        store.openConversation(session)
                        withAnimation(notchSpringHover) { viewModel.contentType = .chat(session) }
                    })
                case .menu:
                    NotchMenuView(store: store)
                case .chat(let session):
                    NotchChatView(session: session, store: store)
                }
            }
        }
        .frame(width: notchSize.width - 24)
    }

    // MARK: - HITL approval

    private var approvalView: some View {
        VStack(spacing: 12) {
            if case .waitingForApproval(let toolName) = store.phase {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)

                    Text("Tool Approval Required")
                        .font(.sans(13, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(toolName)
                        .font(.mono(12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))

                    if let args = approvalArguments, !args.isEmpty {
                        Text(args)
                            .font(.mono(11))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button {
                        stopApprovalAutoTimer()
                        store.deny()
                    } label: {
                        Text("Deny")
                            .font(.sans(12, weight: .medium))
                            .foregroundColor(.red.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        stopApprovalAutoTimer()
                        store.approve()
                    } label: {
                        Text("Approve")
                            .font(.sans(12, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Text("Auto-approve in \(approvalCountdown)s")
                    .font(.sans(10))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
    }

    private var approvalArguments: String? {
        guard let request = store.pendingApproval else { return nil }
        let rows = request.argumentRows
        guard !rows.isEmpty else { return nil }
        return rows.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func errorNotificationView(message: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)

                Text("Error")
                    .font(.sans(13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button {
                    withAnimation(notchSpringHover) { viewModel.notchClose() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(message)
                .font(.sans(12))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 12)
    }

    // MARK: - Reactions

    private func showChatIfNeeded() {
        guard case .sessions = viewModel.contentType, let id = store.threadId else { return }
        let session = NotchSession(id: id, title: "New conversation", subtitle: nil, preview: nil, date: nil)
        withAnimation(notchSpringHover) { viewModel.contentType = .chat(session) }
    }

    private func handlePhaseChange() {
        if !hasReceivedFirstEvent { hasReceivedFirstEvent = true }

        if needsApproval {
            isVisible = true
            startApprovalBounce()
            if viewModel.status == .closed { viewModel.notchOpen(reason: .notification) }
        } else if hasError {
            isVisible = true
            stopApprovalBounce()
            if viewModel.status == .closed { viewModel.notchOpen(reason: .notification) }
        } else if isProcessing {
            isVisible = true
            stopApprovalBounce()
            showChatIfNeeded()
        } else {
            stopApprovalBounce()
        }
    }

    private func startApprovalBounce() {
        approvalBounceTimer?.invalidate()
        withAnimation(approvalBounceSpring) { isBouncing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(approvalBounceSpring) { isBouncing = false }
        }
        approvalBounceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                guard needsApproval else { return }
                withAnimation(approvalBounceSpring) { isBouncing = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(approvalBounceSpring) { isBouncing = false }
                }
            }
        }
        startApprovalAutoTimer()
    }

    private func stopApprovalBounce() {
        approvalBounceTimer?.invalidate()
        approvalBounceTimer = nil
        isBouncing = false
        stopApprovalAutoTimer()
    }

    private func startApprovalAutoTimer() {
        stopApprovalAutoTimer()
        approvalCountdown = 20
        approvalAutoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard needsApproval else {
                    stopApprovalAutoTimer()
                    return
                }
                approvalCountdown -= 1
                if approvalCountdown <= 0 {
                    stopApprovalAutoTimer()
                    store.approve()
                }
            }
        }
    }

    private func stopApprovalAutoTimer() {
        approvalAutoTimer?.invalidate()
        approvalAutoTimer = nil
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
        case .closed:
            if hasReceivedFirstEvent, !store.sessionActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if viewModel.status == .closed, isIdle, !isProcessing,
                       !hasError, !needsApproval, !store.sessionActive {
                        withAnimation(.easeOut(duration: 0.3)) { isVisible = false }
                    }
                }
            }
        }
    }
}
