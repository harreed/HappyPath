import AppKit
import SwiftUI

enum WorkbenchStyle {
    // An eight-point rhythm shared by the menu, workspace, cards and sheets.
    static let spacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 24
    static let cardRadius: CGFloat = 13
    static let rowRadius: CGFloat = 8
    static let rowHeight: CGFloat = 38
    static let controlHeight: CGFloat = 34
    static let iconWidth: CGFloat = 16
    static let cardPadding: CGFloat = 6
    static let panelPadding: CGFloat = 16
    static let sheetPadding: CGFloat = 24

    // Dynamic AppKit colors let every window, sheet, and hosted menu follow macOS appearance.
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static let accent = adaptive(rgb(0.10, 0.39, 0.35), rgb(0.43, 0.79, 0.68))
    static let accentText = adaptive(.white, rgb(0.043, 0.051, 0.067))
    static let copper = adaptive(rgb(0.78, 0.35, 0.23), rgb(0.95, 0.55, 0.40))
    static let ink = adaptive(rgb(0.12, 0.18, 0.17), rgb(0.92, 0.93, 0.94))
    // A charcoal base with a restrained cool tint; each surface is slightly lighter.
    static let canvas = adaptive(rgb(0.976, 0.973, 0.958), rgb(0.043, 0.051, 0.067))
    static let sidebar = adaptive(rgb(0.955, 0.953, 0.931), rgb(0.063, 0.075, 0.098))
    static let panel = adaptive(.white, rgb(0.090, 0.106, 0.133))
    static let menuPanel = panel
    static let border = adaptive(.black.withAlphaComponent(0.10), .white.withAlphaComponent(0.14))
    static let hairline = adaptive(.black.withAlphaComponent(0.07), .white.withAlphaComponent(0.09))
    static let hover = adaptive(.black.withAlphaComponent(0.05), .white.withAlphaComponent(0.08))
    static let pressed = adaptive(.black.withAlphaComponent(0.09), .white.withAlphaComponent(0.13))
    static let inset = adaptive(.black.withAlphaComponent(0.035), .white.withAlphaComponent(0.045))
    static let illustrationField = adaptive(rgb(0.935, 0.949, 0.921), rgb(0.067, 0.086, 0.106))
    static let simulatorField = adaptive(rgb(0.92, 0.93, 0.97), rgb(0.067, 0.086, 0.114))
    static let badgeBackground = adaptive(rgb(0.09, 0.13, 0.19), rgb(0.09, 0.106, 0.133))
    static let selected = accent.opacity(0.16)
    static var destructiveText: Color { Color.red.opacity(0.9) }
    static var destructiveHover: Color { Color.red.opacity(0.10) }
    static var destructiveBorder: Color { Color.red.opacity(0.4) }

    static let rowFont = font(.caption, weight: .semibold)
    static let sectionFont = font(.caption2, weight: .bold)
    static let infoFont = font(.caption)
    static let titleFont = font(.title3, weight: .bold)
    static let monoFont = font(size: 10)
    static let motion: Animation = .easeOut(duration: 0.1)

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 13
        case .subheadline: size = 12
        case .caption: size = 11
        case .caption2: size = 10
        case .footnote: size = 11
        case .callout: size = 12
        default: size = 13
        }
        return font(size: size, weight: weight, relativeTo: style)
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .bold: name = "DMSans-Bold"
        case .semibold: name = "DMSans-SemiBold"
        case .medium: name = "DMSans-Medium"
        default: name = "DMSans-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    static func shape(_ radius: CGFloat = cardRadius) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

struct WorkbenchMenuTrigger: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .help(title)
    }
}

extension View {
    func workbenchCard(padding: CGFloat = WorkbenchStyle.panelPadding, radius: CGFloat = WorkbenchStyle.cardRadius) -> some View {
        self
            .padding(padding)
            .background(WorkbenchStyle.panel, in: WorkbenchStyle.shape(radius))
            .overlay(WorkbenchStyle.shape(radius).strokeBorder(WorkbenchStyle.border, lineWidth: 1))
    }

    func workbenchInset(padding: CGFloat = 10, radius: CGFloat = WorkbenchStyle.rowRadius) -> some View {
        self
            .padding(padding)
            .background(WorkbenchStyle.inset, in: WorkbenchStyle.shape(radius))
            .overlay(WorkbenchStyle.shape(radius).strokeBorder(WorkbenchStyle.hairline, lineWidth: 1))
    }

    func workbenchInfo() -> some View {
        font(WorkbenchStyle.infoFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func workbenchCanvas() -> some View {
        background(WorkbenchStyle.canvas)
    }

    func workbenchSheetButtons() -> some View {
        buttonStyle(WorkbenchButtonStyle())
    }
}

struct WorkbenchRow<Trailing: View>: View {
    var title: String
    var systemImage: String?
    var leading: String?
    var subtitle: String?
    var isDestructive = false
    var isSelected = false
    var isHighlighted = false
    var isEnabled = true
    var titleLineLimit = 1
    @ViewBuilder var trailing: () -> Trailing
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let leading {
                    Text(leading)
                        .font(WorkbenchStyle.font(.caption).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, alignment: .trailing)
                }
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(WorkbenchStyle.font(size: 12, weight: .semibold))
                        .frame(width: WorkbenchStyle.iconWidth)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(WorkbenchStyle.rowFont)
                        .lineLimit(titleLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(WorkbenchStyle.font(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(WorkbenchStyle.font(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(isDestructive ? WorkbenchStyle.destructiveText : Color.primary.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(minHeight: WorkbenchStyle.rowHeight)
            .background(fill, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = isEnabled && $0 }
        .animation(WorkbenchStyle.motion, value: isHovered)
    }

    private var fill: Color {
        if isHovered { return isDestructive ? WorkbenchStyle.destructiveHover : WorkbenchStyle.hover }
        if isHighlighted { return WorkbenchStyle.selected }
        return .clear
    }
}

extension WorkbenchRow where Trailing == EmptyView {
    init(
        title: String,
        systemImage: String? = nil,
        leading: String? = nil,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        isSelected: Bool = false,
        isHighlighted: Bool = false,
        isEnabled: Bool = true,
        titleLineLimit: Int = 1,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            leading: leading,
            subtitle: subtitle,
            isDestructive: isDestructive,
            isSelected: isSelected,
            isHighlighted: isHighlighted,
            isEnabled: isEnabled,
            titleLineLimit: titleLineLimit,
            trailing: { EmptyView() },
            action: action
        )
    }
}

struct WorkbenchSectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(WorkbenchStyle.sectionFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkbenchNotice: View {
    enum Kind {
        case info
        case warning
        case danger

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .danger: "xmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .info: .secondary
            case .warning: .orange
            case .danger: .red
            }
        }
    }

    let text: String
    var kind: Kind = .info

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol)
                .font(WorkbenchStyle.font(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(text)
                .font(WorkbenchStyle.infoFont)
                .foregroundStyle(kind == .info ? Color.secondary : kind.tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(kind.tint.opacity(0.08), in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
        .overlay(WorkbenchStyle.shape(WorkbenchStyle.rowRadius).strokeBorder(kind.tint.opacity(0.25), lineWidth: 1))
    }
}

struct WorkbenchSheetHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WorkbenchStyle.titleFont)
            if let subtitle {
                Text(subtitle).workbenchInfo()
            }
        }
    }
}

struct WorkbenchButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

private struct WorkbenchButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let destructive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(WorkbenchStyle.rowFont)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: WorkbenchStyle.controlHeight)
            .background(fill, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
            .overlay(WorkbenchStyle.shape(WorkbenchStyle.rowRadius).strokeBorder(stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovered = $0 }
            .animation(WorkbenchStyle.motion, value: isHovered)
            .animation(WorkbenchStyle.motion, value: configuration.isPressed)
    }

    private var foreground: Color {
        if destructive { return WorkbenchStyle.destructiveText }
        if prominent { return WorkbenchStyle.accentText }
        return Color.primary.opacity(0.86)
    }

    private var fill: Color {
        if prominent { return Color.accentColor.opacity(configuration.isPressed ? 0.75 : isHovered ? 0.9 : 1) }
        if destructive { return isHovered ? WorkbenchStyle.destructiveHover : .clear }
        return isHovered ? WorkbenchStyle.hover : .clear
    }

    private var stroke: Color {
        if prominent { return .clear }
        if destructive { return WorkbenchStyle.destructiveBorder }
        return WorkbenchStyle.border
    }
}
