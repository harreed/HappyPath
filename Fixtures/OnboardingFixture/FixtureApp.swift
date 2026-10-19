import SwiftUI
import UIKit
import UserNotifications

@main struct FixtureApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--library-probe") { LibraryProbeView() }
            else if ProcessInfo.processInfo.arguments.contains("--targeting-probe") { TargetingProbeView() }
            else if ProcessInfo.processInfo.arguments.contains("--semantic-probe") { SemanticProbeView() }
            else if ProcessInfo.processInfo.arguments.contains("--scroll-probe") ||
                        ProcessInfo.processInfo.arguments.contains("--dense-scroll-probe") ||
                        ProcessInfo.processInfo.arguments.contains("--dense-scroll-late") { ScrollProbeView() }
            else if ProcessInfo.processInfo.arguments.contains("--icon-probe") { IconProbeView() }
            else { OnboardingView() }
        }
    }
}

/// Live cases for OCR labels, distractors and controls that do not advance.
struct TargetingProbeView: View {
    private let mode = ProcessInfo.processInfo.arguments.last ?? ""
    @State private var created = false
    @State private var profileOpened = false
    @State private var ignoredTaps = 0
    @State private var targetMoved = false

    var body: some View {
        VStack(spacing: 22) {
            Text("Targeting probe").font(.largeTitle)
            if created || mode == "complete" {
                Text("Scenario created").accessibilityIdentifier("targeting.complete")
            } else {
                if mode == "heading" {
                    Text("Create scenario").font(.title2)
                } else {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.blue))
                        let label = context.resolve(Text("Create scenario")
                            .font(.system(size: 25)).foregroundColor(.white))
                        context.draw(label, at: CGPoint(x: size.width * 0.3, y: size.height / 2))
                    }
                    .frame(height: 92).cornerRadius(12).contentShape(Rectangle())
                    .offset(y: mode == "moving" && targetMoved ? 140 : 0)
                    .onTapGesture {
                        if mode == "no-progress" { ignoredTaps += 1 }
                        else { created = true }
                    }
                    .accessibilityHidden(true)
                }
                if mode == "moving" {
                    Button("Move target") { targetMoved = true }
                        .accessibilityIdentifier("targeting.move")
                }
                if ["off-center", "heading", "no-progress"].contains(mode) {
                    Button("Profile") { profileOpened = true }
                        .accessibilityIdentifier("targeting.profile")
                }
                if profileOpened { Text("Profile opened") }
            }
        }.padding(30)
    }
}

/// Deliberately no accessibility identifiers; a successful action has a visible effect.
struct SemanticProbeView: View {
    @State private var name = ""
    @State private var applied = "Nothing applied"
    var body: some View {
        VStack(spacing: 24) {
            TextField("Semantic name", text: $name).accessibilityLabel("Semantic name")
            Button("Apply name") { applied = "Applied \(name)" }
            Text(applied)
        }.padding(30)
    }
}

struct OnboardingView: View {
    @State private var name = ""
    @State private var stage = 0
    @State private var alert = false
    @State private var replacedAlert = false
    init() {
        let probe = ProcessInfo.processInfo.arguments.contains("--recovery-probe")
        _name = State(initialValue: probe ? "Ada Recovery" : "")
        _stage = State(initialValue: probe ? 1 : 0)
    }
    var body: some View {
        VStack(spacing: 32) {
            if ProcessInfo.processInfo.arguments.contains("--bridge-probes") {
                HStack {
                    Button("Probe A") {}.accessibilityIdentifier("fixture.ambiguous")
                    Button("Probe B") {}.accessibilityIdentifier("fixture.ambiguous")
                }
            }
            if stage == 0 {
                Text("Welcome").font(.largeTitle)
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("onboarding.name")
                Button("Continue") { stage = 1; alert = true }
                    .accessibilityIdentifier("onboarding.continue").disabled(name.isEmpty)
            } else if stage == 1 {
                Text("Hello, \(name)").accessibilityIdentifier("onboarding.greeting")
                // Deliberately omit this custom-drawn control from accessibility to exercise OCR.
                Canvas { context, size in
                    context.draw(Text("Finish setup").font(.system(size: 28)).foregroundColor(.white),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                }.frame(height: 90).background(Color.blue).cornerRadius(12)
                    .contentShape(Rectangle()).onTapGesture { stage = 2 }.accessibilityHidden(true)
            } else {
                Text("Setup complete").font(.largeTitle).accessibilityIdentifier("onboarding.complete")
                Text("Welcome, \(name)").accessibilityIdentifier("onboarding.finalName")
            }
        }.padding(30)
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--recovery-probe") && !ProcessInfo.processInfo.arguments.contains("--no-alert") { alert = true } }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--replace-alert") {
                try? await Task.sleep(for: .seconds(6)); alert = false; replacedAlert = true
                try? await Task.sleep(for: .milliseconds(750)); alert = true
            }
        }
        .alert("Try reminders?", isPresented: $alert) {
            Button("Not Now", role: .cancel) {}.accessibilityIdentifier("fixture.alert.notNow")
            Button("Enable") {}.accessibilityIdentifier("fixture.alert.enable")
            if ProcessInfo.processInfo.arguments.contains("--ambiguous-alert") {
                Button("Not Now") {}.accessibilityIdentifier("fixture.alert.otherNotNow")
            }
            if ProcessInfo.processInfo.arguments.contains("--destructive-alert") {
                Button("Delete account", role: .destructive) {}.accessibilityIdentifier("fixture.alert.delete")
            }
        } message: { Text(replacedAlert ? "This optional interruption is injected by the fixture. Changed context: delete account." : "This optional interruption is injected by the fixture.") }
    }
}

/// Separate launch mode: real scrolling with stable semantic row identifiers.
struct ScrollProbeView: View {
    private let startLate = ProcessInfo.processInfo.arguments.contains("--dense-scroll-late")
    private let rowCount = ProcessInfo.processInfo.arguments.contains("--dense-scroll-probe") ||
        ProcessInfo.processInfo.arguments.contains("--dense-scroll-late") ? 300 : 25
    var body: some View {
        if startLate {
            ScrollViewReader { proxy in
                scrollRows
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            proxy.scrollTo(200, anchor: .top)
                        }
                    }
            }
        } else {
            scrollRows
        }
    }
    private var scrollRows: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { index in
                    Text("Scroll row \(index)")
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .id(index)
                        .accessibilityIdentifier(index == 0 ? "fixture.scroll.first" :
                            index == 20 ? "fixture.scroll.target" : "fixture.scroll.row.\(index)")
                }
            }
        }.accessibilityIdentifier("fixture.scroll")
    }
}

/// Isolated observed-signal fixtures. No simulated model/driver decisions.
struct LibraryProbeView: View {
    let mode = ProcessInfo.processInfo.arguments.last ?? ""
    @State private var loading = true
    @State private var presented = false
    @State private var text = ""
    @State private var acknowledged = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            if mode == "offline" || mode == "offline-expected" { Text("No internet connection"); Button("Acknowledge") { acknowledged = true }.accessibilityIdentifier("library.continue"); if acknowledged { Text("Offline action acknowledged") } }
            else if mode == "auth" { Text("Session expired. Sign in again") }
            else if (mode == "loading" || mode == "transient-forever") && loading { ProgressView("Loading") }
            else if mode == "keyboard" { TextField("Input", text: $text).focused($focused).accessibilityIdentifier("library.input") }
            else { Text("Ready"); Button("Continue") {}.accessibilityIdentifier("library.continue") }
        }
        .alert("App would like to access your location", isPresented: Binding(get: { mode == "permission" && presented }, set: { presented = $0 })) { Button("Allow") {}; Button("Don't Allow", role: .cancel) {} }
        .confirmationDialog("First run options", isPresented: Binding(get: { mode == "sheet" && presented }, set: { presented = $0 }), titleVisibility: .visible) { Button("Start") {}; Button("Cancel", role: .cancel) {} }
        .task {
            presented = true; focused = true
            if mode == "system-permission" {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            }
            if mode == "loading" { try? await Task.sleep(for: .seconds(3.5)); loading = false }
            if mode == "crash" { try? await Task.sleep(for: .seconds(2)); exit(0) }
        }
    }
}

/// Icon-semantics probe: which icon target information survives into the accessibility tree.
/// First two rows are plain SwiftUI symbol buttons with no labels; then labeled and
/// identifier-only controls; last row is UIKit image-only buttons for comparison.
struct IconProbeView: View {
    @State private var last = "none"
    private let primary = ["gear", "magnifyingglass", "trash", "plus"]
    private let secondary = ["xmark", "chevron.backward", "heart", "bell"]
    var body: some View {
        VStack(spacing: 18) {
            Text("Icon probe").font(.largeTitle)
            Text("Last: \(last)").accessibilityIdentifier("fixture.icons.last")
            HStack(spacing: 18) {
                ForEach(primary, id: \.self) { name in
                    Button { last = "swiftui.unlabeled.\(name)" } label: { Image(systemName: name) }
                }
            }
            HStack(spacing: 18) {
                ForEach(secondary, id: \.self) { name in
                    Button { last = "swiftui.unlabeled.\(name)" } label: { Image(systemName: name) }
                }
            }
            HStack(spacing: 18) {
                Button { last = "swiftui.labeled.gear" } label: { Image(systemName: "gear") }
                    .accessibilityLabel("Open settings")
                Button { last = "swiftui.labeled.trash" } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete item")
                Button { last = "swiftui.identified" } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityIdentifier("fixture.icons.profile")
                Image(systemName: "star")
            }
            Canvas { context, size in
                var star = Path()
                for point in 0..<10 {
                    let angle = Double(point) * .pi / 5 - .pi / 2
                    let radius = point.isMultiple(of: 2) ? 31.0 : 14.0
                    let vertex = CGPoint(x: size.width / 2 + cos(angle) * radius,
                                         y: size.height / 2 + sin(angle) * radius)
                    if point == 0 { star.move(to: vertex) } else { star.addLine(to: vertex) }
                }
                star.closeSubpath()
                context.fill(star, with: .color(.yellow))
            }
            .frame(width: 82, height: 82).background(Color.purple).cornerRadius(12)
            .contentShape(Rectangle()).onTapGesture { last = "canvas.hidden.star" }
            .accessibilityHidden(true)
            HStack(spacing: 18) {
                UIKitIconButton(systemName: "square.and.arrow.up") { last = "uikit.unlabeled" }
                UIKitIconButton(systemName: "person.crop.circle", label: "Profile") { last = "uikit.labeled" }
            }
        }.padding(30)
    }
}

/// UIKit counterpart so a UIKit image-only UIButton can be compared with the SwiftUI rows.
struct UIKitIconButton: UIViewRepresentable {
    let systemName: String
    var label: String? = nil
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in onTap() })
        button.accessibilityLabel = label
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
