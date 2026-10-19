import SwiftUI
import ProjectDomain
import ModelProviders

struct RecoveryPolicyEditor: View {
    @Binding var policy: RecoveryPolicy
    let definitions: [ReviewedAlertPolicy]
    var body: some View {
        Picker("Interruption mode", selection: field(\.mode) { $0.replacing(mode: $1) }) {
            Text("Ask / fail").tag(RecoveryMode.askFail)
            Text("Known automatic").tag(RecoveryMode.knownAutomatic)
            Text("Safe inferred").tag(RecoveryMode.safeInferred)
        }
        Text("App alerts require an exact reviewed policy. System alerts choose a unique visible accept action by default; Apple Account sign-in prompts are closed.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
        Toggle("Allow OCR for unresolved tap text", isOn: field(\.allowTextFallback) { $0.replacing(allowTextFallback: $1) })
        Toggle("Automatically accept system prompts", isOn: field(\.allowSystemDismiss) { $0.replacing(allowSystemDismiss: $1) })
        TextField("Maximum recovery actions", value: field(\.maximumActions) { $0.replacing(maximumActions: $1) }, format: .number)
        Toggle("Safe escapes clear obstructions (Close/Back/Not Now)", isOn: field(\.allowSafeEscapes) { $0.replacing(allowSafeEscapes: $1) })
        Toggle("Allow one unambiguous progress control (Next/Continue/Get Started)", isOn: field(\.allowProgressControls) { $0.replacing(allowProgressControls: $1) })
        TextField("Maximum escape actions", value: field(\.maximumEscapes) { $0.replacing(maximumEscapes: $1) }, format: .number)
        TextField("Maximum consecutive unresolved steps before stopping", value: field(\.maximumUnresolvedSteps) { $0.replacing(maximumUnresolvedSteps: $1) }, format: .number)
        Text("Unresolved steps continue forward so later steps can re-establish the expected state; they report needs review, never a silent pass. Screens naming destructive, consent or monetary actions are never advanced automatically. Set consecutive unresolved steps to 0 to stop at the first unresolved step.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
        TextField("Recovery timeout (seconds)", value: field(\.timeoutSeconds) { $0.replacing(timeoutSeconds: $1) }, format: .number)
        TextField("Minimum confidence (0–1)", value: field(\.minimumConfidence) { $0.replacing(minimumConfidence: $1) }, format: .number)
        TextField("Maximum recaptures", value: field(\.maximumRecaptures) { $0.replacing(maximumRecaptures: $1) }, format: .number)
        TextField("Maximum capture age (≤8 seconds)", value: field(\.maximumCaptureAge) { $0.replacing(maximumCaptureAge: $1) }, format: .number)
        Picker("Candidate chooser", selection: field(\.candidateProvider) { $0.replacing(candidateProvider: $1) }) {
            Text("Jev — hosted (default)").tag(CandidateProvider.jev); Text("Local policy").tag(CandidateProvider.local)
        }
        if policy.candidateProvider == .jev {
            Text("Sends bounded safe option IDs/titles and structured state to TypeSafe AI. If the key is missing or rejected or Jev is unavailable, the local reviewed policy is used and the run shows an alert. A provider choice still requires local policy, confidence and freshness checks.").font(WorkbenchStyle.font(.caption))
        }
        ForEach(definitions, id: \.id) { definition in
            Toggle("Enable reviewed policy: \(definition.id)", isOn: Binding(get: { policy.knownInterruptionPolicies.contains(definition.id) }, set: { enabled in
                var ids = policy.knownInterruptionPolicies.filter { $0 != definition.id }; if enabled { ids.append(definition.id) }
                policy = policy.replacing(knownInterruptionPolicies: ids)
            }))
        }
        ForEach(policy.knownInterruptionPolicies.filter { id in !definitions.contains { $0.id == id } }, id: \.self) { id in
            HStack { Text("Missing reviewed definition: \(id)").foregroundStyle(.orange); Button("Remove Reference") { policy = policy.replacing(knownInterruptionPolicies: policy.knownInterruptionPolicies.filter { $0 != id }) } }
        }
    }
    func field<T>(_ key: KeyPath<RecoveryPolicy,T>, _ update: @escaping (RecoveryPolicy,T) -> RecoveryPolicy) -> Binding<T> { Binding(get: { policy[keyPath: key] }, set: { policy = update(policy,$0) }) }
}

struct GoalPolicyEditor: View {
    @Binding var policy: GoalAssessmentPolicy
    var body: some View {
        Picker("Required evidence", selection: Binding(get: { policy.requirement }, set: { policy = .init(requirement: $0, minimumConfidence: policy.minimumConfidence, timeoutSeconds: policy.timeoutSeconds) })) {
            Text("Accessibility text").tag(GoalAssessmentPolicy.EvidenceRequirement.semantic)
            Text("OCR text from final capture").tag(GoalAssessmentPolicy.EvidenceRequirement.ocr)
            Text("Image interpretation (unavailable)").tag(GoalAssessmentPolicy.EvidenceRequirement.image)
        }
        TextField("Goal minimum confidence (0–1)", value: Binding(get: { policy.minimumConfidence }, set: { policy = .init(requirement: policy.requirement, minimumConfidence: $0, timeoutSeconds: policy.timeoutSeconds) }), format: .number)
        TextField("Goal timeout (seconds)", value: Binding(get: { policy.timeoutSeconds }, set: { policy = .init(requirement: policy.requirement, minimumConfidence: policy.minimumConfidence, timeoutSeconds: $0) }), format: .number)
        Text("Text assessment does not see image pixels. Image-required, unavailable or insufficient evidence requires review. Deterministic failure retains precedence. Empty goals use deterministic assertions only.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
    }
}

enum ScreenshotProvider: String {
    case jev, cloudflare
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "screenshotProvider") ?? "") ?? .jev
    }
}

struct ProviderCapabilitiesView: View {
    @AppStorage("screenshotProvider") private var screenshotProvider = ScreenshotProvider.jev.rawValue
    @State private var jevKey = ""
    @State private var jevKeyPresent = JevCredentialStore.hasCredential
    @State private var jevKeyError: String?
    @State private var claudeKey = ""
    @State private var claudeKeyPresent = ClaudeCredentialStore.hasCredential
    @State private var claudeKeyError: String?
    @State private var clefAccountID = ""
    @State private var clefToken = ""
    @State private var clefCredentialsPresent = ClefCredentialStore.hasCredentials
    @State private var clefCredentialsError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Screenshot checks").font(WorkbenchStyle.font(.headline, weight: .bold))
                Picker("First choice", selection: $screenshotProvider) {
                    Text("Jev").tag(ScreenshotProvider.jev.rawValue)
                    Text("Cloudflare").tag(ScreenshotProvider.cloudflare.rawValue)
                }.pickerStyle(.segmented)
                Text("Jev is the default. The other service is tried if the first cannot answer.")
                    .workbenchInfo()
            }.frame(maxWidth: .infinity, alignment: .leading).workbenchCard()

            providerCard("Jev", detail: "Screenshot checks, goal navigation and candidate choice", available: jevKeyPresent) {
                SecureField("API key", text: $jevKey)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Save key") {
                        do { try JevCredentialStore.save(jevKey); jevKey = ""; jevKeyPresent = true; jevKeyError = nil }
                        catch { jevKeyError = error.localizedDescription }
                    }.disabled(jevKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") {
                        do { try JevCredentialStore.remove(); jevKeyPresent = JevCredentialStore.hasCredential; jevKeyError = nil }
                        catch { jevKeyError = error.localizedDescription }
                    }.disabled(!jevKeyPresent)
                }
                if let jevKeyError { Text(jevKeyError).foregroundStyle(.red) }
            }

            providerCard("Cloudflare", detail: "Screenshot checks", available: clefCredentialsPresent) {
                TextField("Account ID", text: $clefAccountID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Workers AI token", text: $clefToken)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Save credentials") {
                        do {
                            try ClefCredentialStore.save(accountID: clefAccountID, apiToken: clefToken)
                            clefAccountID = ""; clefToken = ""; clefCredentialsPresent = true; clefCredentialsError = nil
                        } catch { clefCredentialsError = error.localizedDescription }
                    }.disabled(clefAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || clefToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") {
                        do { try ClefCredentialStore.remove(); clefCredentialsPresent = ClefCredentialStore.hasCredentials; clefCredentialsError = nil }
                        catch { clefCredentialsError = error.localizedDescription }
                    }.disabled(!clefCredentialsPresent)
                }
                if let clefCredentialsError { Text(clefCredentialsError).foregroundStyle(.red) }
            }

            providerCard("Claude", detail: "Text planning and assessment", available: claudeKeyPresent) {
                SecureField("API key", text: $claudeKey)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Save key") {
                        do { try ClaudeCredentialStore.save(claudeKey); claudeKey = ""; claudeKeyPresent = true; claudeKeyError = nil }
                        catch { claudeKeyError = error.localizedDescription }
                    }.disabled(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") {
                        do { try ClaudeCredentialStore.remove(); claudeKeyPresent = ClaudeCredentialStore.hasCredential; claudeKeyError = nil }
                        catch { claudeKeyError = error.localizedDescription }
                    }.disabled(!claudeKeyPresent)
                }
                if let claudeKeyError { Text(claudeKeyError).foregroundStyle(.red) }
            }

            DisclosureGroup("Advanced credential setup") {
                Text("Keys can also be supplied at launch with TYPESAFE_API_KEY, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN and ANTHROPIC_API_KEY. Saved credentials stay on this Mac, outside project files.")
                    .workbenchInfo()
                    .padding(.top, 6)
            }.font(WorkbenchStyle.font(.caption)).padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func providerCard<Content: View>(_ title: String, detail: String, available: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(WorkbenchStyle.font(.headline, weight: .bold))
                Spacer()
                Label(available ? "Ready" : "Add key", systemImage: available ? "checkmark.circle.fill" : "circle")
                    .font(WorkbenchStyle.font(.caption))
                    .foregroundStyle(available ? Color.green : Color.secondary)
            }
            Text(detail).workbenchInfo()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .workbenchCard()
    }
}

struct ProjectRecoverySheet: View {
    private enum Page: String { case recovery = "Recovery", providers = "Providers" }
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .recovery
    @State private var policy: RecoveryPolicy
    @State private var definitions: [ReviewedAlertPolicy]
    @State private var error: String?
    private let original: TestProject?
    init(model: WorkspaceModel) { self.model = model; original = model.project; _policy = State(initialValue: model.project?.defaultRecoveryPolicy ?? .init()); _definitions = State(initialValue: model.project?.reviewedAlertPolicies ?? []) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSheetHeader(title: "Project settings", subtitle: page == .providers ? "Choose screenshot checks and manage credentials." : "Recovery rules for tests in this project.")
                .padding(.top, WorkbenchStyle.sheetPadding).padding(.horizontal, WorkbenchStyle.sheetPadding)
            Picker("Settings", selection: $page) {
                Text("Recovery").tag(Page.recovery)
                Text("Providers").tag(Page.providers)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, WorkbenchStyle.sheetPadding)
            if page == .recovery {
                Form {
                    Section("Project default — used only by inheriting tests") { RecoveryPolicyEditor(policy: $policy, definitions: definitions) }
                    Section("Locally reviewed alerts") {
                        Text("Enter the exact observed app-owned context and every button. Missing identifiers match only missing identifiers. Review each button’s risk; unknown is the default. Definitions alone do not enable recovery.").font(WorkbenchStyle.font(.caption))
                        ForEach(definitions.indices, id: \.self) { index in
                            DisclosureGroup(definitions[index].id.isEmpty ? "New reviewed alert" : definitions[index].id) {
                                ReviewedAlertEditor(value: Binding(get: { definitions[index] }, set: { definitions[index] = $0 }))
                                Button("Remove Definition", role: .destructive) { definitions.remove(at: index) }
                            }
                        }
                        Button("Add Reviewed Alert") { definitions.append(.init(id: "reviewed.\(UUID().uuidString.prefix(8))", bundleIdentifier: model.project?.app.bundleIdentifier ?? "", alertIdentifier: "", exactContext: "", buttons: [])) }
                    }
                }
                .formStyle(.grouped)
            } else {
                ScrollView {
                    ProviderCapabilitiesView()
                        .frame(maxWidth: 600)
                        .frame(maxWidth: .infinity)
                        .padding(WorkbenchStyle.sheetPadding)
                }
                .background(WorkbenchStyle.canvas)
            }
            if let error { WorkbenchNotice(text: error, kind: .danger).padding(.horizontal, WorkbenchStyle.sheetPadding) }
            HStack {
                if page == .providers {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(WorkbenchButtonStyle(prominent: true))
                } else {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Apply Recovery Settings") { apply() }
                        .buttonStyle(WorkbenchButtonStyle(prominent: true))
                }
            }
            .workbenchSheetButtons()
            .padding(WorkbenchStyle.sheetPadding)
        }.frame(width: 700, height: 740)
    }
    func apply() {
        guard let project = model.project, project == original else { error = "The project changed while these settings were open. Cancel and reopen to review current settings."; return }
        let updated = project.replacing(reviewedAlertPolicies: definitions, defaultRecoveryPolicy: policy)
        do {
            let probe = TestCase(name: "Validate default", blocks: [], useProjectRecoveryPolicy: true)
            try updated.replacing(categories: [.init(name: "Validation", suites: [.init(name: "Default", tests: [probe])])]).validate()
            try updated.validate(); model.edit { _ in updated }; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ReviewedAlertEditor: View {
    @Binding var value: ReviewedAlertPolicy
    var body: some View {
        TextField("Policy ID", text: string(0))
        TextField("Exact app bundle identifier", text: string(1))
        TextField("Exact alert identifier", text: string(2))
        TextField("Exact observed context", text: string(3), axis: .vertical).lineLimit(2...6)
        ForEach(value.buttons.indices, id: \.self) { index in
            VStack(alignment: .leading) {
                Text("Button \(index + 1)").font(WorkbenchStyle.font(.caption, weight: .bold))
                TextField("Identifier (empty means missing)", text: Binding(get: { value.buttons[index].identifier ?? "" }, set: { updateButton(index, identifier: $0) }))
                TextField("Exact button label", text: Binding(get: { value.buttons[index].label }, set: { updateButton(index, label: $0) }))
                Picker("Locally reviewed risk", selection: Binding(get: { value.buttons[index].risk }, set: { updateButton(index, risk: $0) })) {
                    Text("Unknown — refuse").tag(ReviewedAlertButton.Risk.unknown)
                    Text("Non-destructive dismissal").tag(ReviewedAlertButton.Risk.nonDestructiveDismissal)
                    Text("Destructive — refuse").tag(ReviewedAlertButton.Risk.destructive)
                }
                Button("Remove Button", role: .destructive) { var buttons = value.buttons; buttons.remove(at: index); replace(buttons: buttons) }
            }
        }
        Button("Add Button") { replace(buttons: value.buttons + [.init(identifier: nil, label: "", risk: .unknown)]) }
        TextField("Known automatic button identifier (empty means missing)", text: string(4))
        TextField("Known automatic button label (empty disables selection)", text: string(5))
    }
    func string(_ index: Int) -> Binding<String> {
        Binding(get: { [value.id,value.bundleIdentifier,value.alertIdentifier,value.exactContext,value.automaticButtonIdentifier ?? "",value.automaticButtonLabel ?? ""][index] }, set: { text in
            var fields = [value.id,value.bundleIdentifier,value.alertIdentifier,value.exactContext,value.automaticButtonIdentifier ?? "",value.automaticButtonLabel ?? ""]; fields[index] = text
            value = .init(id: fields[0], bundleIdentifier: fields[1], alertIdentifier: fields[2], exactContext: fields[3], buttons: value.buttons, automaticButtonIdentifier: fields[4].isEmpty ? nil : fields[4], automaticButtonLabel: fields[5].isEmpty ? nil : fields[5])
        })
    }
    func replace(buttons: [ReviewedAlertButton]) { value = .init(id: value.id, bundleIdentifier: value.bundleIdentifier, alertIdentifier: value.alertIdentifier, exactContext: value.exactContext, buttons: buttons, automaticButtonIdentifier: value.automaticButtonIdentifier, automaticButtonLabel: value.automaticButtonLabel) }
    func updateButton(_ index: Int, identifier: String? = nil, label: String? = nil, risk: ReviewedAlertButton.Risk? = nil) {
        var buttons = value.buttons; let old = buttons[index]
        buttons[index] = .init(identifier: identifier == nil ? old.identifier : (identifier!.isEmpty ? nil : identifier!), label: label ?? old.label, risk: risk ?? old.risk)
        replace(buttons: buttons)
    }
}
