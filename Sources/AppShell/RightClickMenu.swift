import AppKit
import SwiftUI

/// One entry in a `rightClickMenu` or `CustomMenu`. Use `.button(_:)` for an
/// action, `.section(_:)` for a group heading and `.divider` for a separator.
struct RightClickItem {
    enum Kind {
        case button
        case divider
        case section
        /// A wrapping, non-interactive line — an explanation shown in place of
        /// choices the user cannot make yet.
        case info
    }

    let kind: Kind
    let title: String?
    let systemImage: String?
    let isDestructive: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let action: (() -> Void)?

    static let divider = RightClickItem(
        kind: .divider,
        title: nil,
        systemImage: nil,
        isDestructive: false,
        isSelected: false,
        isEnabled: false,
        action: nil
    )

    static func section(_ title: String) -> RightClickItem {
        RightClickItem(
            kind: .section,
            title: title,
            systemImage: nil,
            isDestructive: false,
            isSelected: false,
            isEnabled: false,
            action: nil
        )
    }

    static func info(_ title: String) -> RightClickItem {
        RightClickItem(
            kind: .info,
            title: title,
            systemImage: nil,
            isDestructive: false,
            isSelected: false,
            isEnabled: false,
            action: nil
        )
    }

    static func button(
        _ title: String,
        systemImage: String? = nil,
        destructive: Bool = false,
        selected: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> RightClickItem {
        RightClickItem(
            kind: .button,
            title: title,
            systemImage: systemImage,
            isDestructive: destructive,
            isSelected: selected,
            isEnabled: enabled,
            action: action
        )
    }
}

extension View {
    /// A context menu that opens on a plain secondary click (right-mouse button
    /// or two-finger trackpad tap), not just ctrl+click.
    ///
    /// SwiftUI caches context-menu closures by structural position. In a recursive,
    /// type-erased tree that can leave a recycled file row running the action from
    /// the folder that previously occupied the same position. The AppKit host is
    /// updated with this row's actions on every render, so the menu always acts on
    /// the node under the pointer.
    func rightClickMenu(_ items: [RightClickItem]) -> some View {
        contentShape(Rectangle())
            .overlay(RightClickMenuHost(items: items))
    }
}

// MARK: - Click-to-open menus

/// Which edge of the trigger the menu lines up with.
enum CustomMenuAlignment {
    case leading
    case trailing
}

/// A menu opened by a primary click, drawn with the app's own menu card rather
/// than AppKit's. Use this in place of SwiftUI's `Menu` everywhere — pop-up
/// pickers and overflow buttons included — so every menu in the app matches.
struct CustomMenu<Label: View>: View {
    let items: [RightClickItem]
    /// Defaults to the trigger's own width, which is what a field-style picker
    /// wants. Pass a width for small triggers like an ellipsis button.
    var width: CGFloat?
    var alignment: CustomMenuAlignment = .leading
    @ViewBuilder let label: () -> Label

    @State private var anchor = CustomMenuAnchor()

    var body: some View {
        Button(action: present) {
            label()
        }
        .buttonStyle(.plain)
        .background(CustomMenuAnchorReader(anchor: anchor))
    }

    private func present() {
        guard let rect = anchor.screenRect, let view = anchor.view else { return }
        let menuWidth = width ?? rect.width
        RightClickMenuPanel.present(
            items: items,
            width: menuWidth,
            on: view.window?.screen
        ) { size, visibleFrame in
            let x = switch alignment {
            case .leading: rect.minX
            case .trailing: rect.maxX - size.width
            }
            // Footer and bottom-of-window triggers have no room beneath them;
            // open upward there rather than letting the card cover the trigger.
            let below = rect.minY - size.height - 4
            let y = below < visibleFrame.minY + 8 ? rect.maxY + 4 : below
            return NSPoint(x: x, y: y)
        }
    }
}

/// Holds the trigger's AppKit view so the panel can be placed against it.
@MainActor
private final class CustomMenuAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct CustomMenuAnchorReader: NSViewRepresentable {
    let anchor: CustomMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Measures only; the SwiftUI button above it keeps every click.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - AppKit hosting

private struct RightClickMenuHost: NSViewRepresentable {
    let items: [RightClickItem]

    func makeNSView(context: Context) -> RightClickMenuView {
        let view = RightClickMenuView()
        view.items = items
        return view
    }

    func updateNSView(_ nsView: RightClickMenuView, context: Context) {
        nsView.items = items
    }
}

private final class RightClickMenuView: NSView {
    var items: [RightClickItem] = []

    /// Stay transparent to normal row taps while claiming only secondary clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isSecondaryClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isSecondaryClick else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        guard let window = event.window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        RightClickMenuPanel.present(items: items, on: window.screen) { size, _ in
            NSPoint(x: screenPoint.x + 5, y: screenPoint.y - size.height + 5)
        }
    }
}

private final class RightClickMenuPanel: NSPanel {
    /// Long lists scroll rather than running off the screen.
    private static let maxHeight: CGFloat = 380

    // Keep the transient panel alive until it is dismissed. AppKit does not
    // guarantee ownership of a borderless, non-activating panel.
    private static var activePanel: RightClickMenuPanel?
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?

    /// `origin` receives the laid-out panel size and the screen's visible frame
    /// so callers can place the card by whichever corner they anchor to, and
    /// flip it when it would not fit below the trigger.
    static func present(
        items: [RightClickItem],
        width: CGFloat = 190,
        on screen: NSScreen?,
        origin: (NSSize, NSRect) -> NSPoint
    ) {
        activePanel?.close()

        let panel = RightClickMenuPanel(items: items, width: width)
        activePanel = panel
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.position(
            at: origin(panel.frame.size, visibleFrame),
            within: visibleFrame
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        panel.installDismissMonitors()
    }

    private init(items: [RightClickItem], width: CGFloat) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        appearance = NSApp.effectiveAppearance
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
        hidesOnDeactivate = false

        let select: (Int) -> Void = { [weak self] index in
            guard items.indices.contains(index) else { return }
            self?.close()
            items[index].action?()
        }
        // Let SwiftUI measure the rows rather than tabulating heights here, so
        // wrapping info lines and future row kinds size themselves correctly.
        let hostingView = NSHostingView(
            rootView: RightClickMenuCard(
                items: items,
                width: width,
                isScrollable: false,
                onSelect: select
            )
        )
        let contentHeight = hostingView.fittingSize.height
        if contentHeight > Self.maxHeight {
            hostingView.rootView = RightClickMenuCard(
                items: items,
                width: width,
                isScrollable: true,
                onSelect: select
            )
        }
        let size = NSSize(width: width, height: min(contentHeight, Self.maxHeight))
        hostingView.frame = NSRect(origin: .zero, size: size)
        contentView = hostingView
        setContentSize(size)
    }

    override var canBecomeKey: Bool { true }

    private func position(at point: NSPoint, within visibleFrame: NSRect?) {
        var origin = point
        if let visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - frame.width - 8)
            origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - frame.height - 8)
        }
        setFrameOrigin(origin)
    }

    private func installDismissMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                close()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown,
               event.window !== self {
                close()
            }
            return event
        }
    }

    override func close() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if Self.activePanel === self { Self.activePanel = nil }
        super.close()
    }
}

private struct RightClickMenuCard: View {
    let items: [RightClickItem]
    let width: CGFloat
    let isScrollable: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        Group {
            if isScrollable {
                ScrollView(.vertical) { rows }
                    .scrollIndicators(.hidden)
            } else {
                rows
            }
        }
        .padding(WorkbenchStyle.cardPadding)
        .frame(width: width)
        .background(WorkbenchStyle.menuPanel, in: WorkbenchStyle.shape())
        .overlay(WorkbenchStyle.shape().strokeBorder(WorkbenchStyle.border, lineWidth: 1))
        .tint(WorkbenchStyle.accent)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                switch item.kind {
                case .button:
                    WorkbenchRow(
                        title: item.title ?? "",
                        systemImage: item.systemImage,
                        isDestructive: item.isDestructive,
                        isSelected: item.isSelected,
                        isEnabled: item.isEnabled,
                        titleLineLimit: 2,
                        action: { onSelect(index) }
                    )
                case .info:
                    Text(item.title ?? "")
                        .font(WorkbenchStyle.infoFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                case .section:
                    Text(item.title ?? "")
                        .font(WorkbenchStyle.sectionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 26, alignment: .bottom)
                        .padding(.bottom, 2)
                case .divider:
                    Rectangle()
                        .fill(WorkbenchStyle.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, 9)
                        .frame(height: 9)
                }
            }
        }
    }
}
