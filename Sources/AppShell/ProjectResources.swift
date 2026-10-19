import Foundation
import Security
import SwiftUI
import CryptoKit
import RunnerCore

struct ProjectSkill: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var instructions: String
}

struct ProjectCredential: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case account = "Account", secret = "Secret", input = "Input" }
    var id: UUID = UUID()
    var name: String
    var kind: Kind
    var note: String
}

private struct ProjectResourcesFile: Codable {
    var skills: [ProjectSkill] = []
    var credentials: [ProjectCredential] = []
}

@MainActor @Observable final class ProjectResourcesStore {
    private(set) var skills: [ProjectSkill] = []
    private(set) var credentials: [ProjectCredential] = []
    private var projectID: UUID?
    private var base: URL?

    func load(projectID: UUID?, base: URL?) throws {
        let file: ProjectResourcesFile
        if let base, FileManager.default.fileExists(atPath: base.appendingPathComponent("resources.json").path) {
            file = try JSONDecoder().decode(ProjectResourcesFile.self, from: Data(contentsOf: base.appendingPathComponent("resources.json")))
        } else { file = ProjectResourcesFile() }
        self.projectID = projectID
        self.base = base
        skills = file.skills
        credentials = file.credentials
    }

    func attach(projectID: UUID, base: URL) throws {
        self.projectID = projectID
        self.base = base
        try persist()
    }

    func saveSkill(id: UUID?, name: String, instructions: String) throws {
        let item = ProjectSkill(id: id ?? UUID(), name: name, instructions: instructions)
        if let index = skills.firstIndex(where: { $0.id == item.id }) { skills[index] = item }
        else { skills.append(item) }
        try persist()
    }

    func deleteSkill(_ id: UUID) throws {
        skills.removeAll { $0.id == id }
        try persist()
    }

    func saveCredential(id: UUID?, name: String, kind: ProjectCredential.Kind, note: String, username: String, value: String) throws {
        guard let projectID, base != nil else { throw resourceError("Save the project before adding an account or secret.") }
        let item = ProjectCredential(id: id ?? UUID(), name: name, kind: kind, note: note)
        if kind == .account && !username.isEmpty { try KeychainResource.set(username, key: key(projectID, item.id, "username")) }
        else { KeychainResource.delete(key: key(projectID, item.id, "username")) }
        if !value.isEmpty { try KeychainResource.set(value, key: key(projectID, item.id, "value")) }
        if let index = credentials.firstIndex(where: { $0.id == item.id }) { credentials[index] = item }
        else { credentials.append(item) }
        try persist()
    }

    func deleteCredential(_ id: UUID) throws {
        guard let projectID, base != nil else { return }
        KeychainResource.delete(key: key(projectID, id, "username"))
        KeychainResource.delete(key: key(projectID, id, "value"))
        credentials.removeAll { $0.id == id }
        try persist()
    }

    func username(for id: UUID) -> String {
        guard let projectID, base != nil else { return "" }
        return KeychainResource.get(key: key(projectID, id, "username")) ?? ""
    }

    func value(for id: UUID) -> String {
        guard let projectID, base != nil else { return "" }
        return KeychainResource.get(key: key(projectID, id, "value")) ?? ""
    }

    func goalInputs() -> [GoalSavedInput] {
        credentials.compactMap { credential in
            // Existing projects may have stored a name as an Account named
            // “Name”, with “Name” as the username and the answer as its value.
            let legacyName = credential.kind == .account &&
                credential.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Name") == .orderedSame &&
                username(for: credential.id).trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Name") == .orderedSame
            guard credential.kind == .input || legacyName else { return nil }
            let answer = value(for: credential.id).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }
            return GoalSavedInput(name: credential.name, value: answer)
        }
    }

    private func key(_ projectID: UUID, _ id: UUID, _ field: String) -> String {
        let location = base?.standardizedFileURL.path ?? ""
        let scope = SHA256.hash(data: Data(location.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(projectID.uuidString).\(scope).\(id.uuidString).\(field)"
    }

    private func persist() throws {
        guard let base else { return }
        let data = try JSONEncoder().encode(ProjectResourcesFile(skills: skills, credentials: credentials))
        try data.write(to: base.appendingPathComponent("resources.json"), options: .atomic)
    }
}

private enum KeychainResource {
    static let service = "dev.agentic.TestWorkbench.resources"
    static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    static func set(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var attributes = query(key)
            attributes[kSecValueData as String] = data
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw resourceError("The credential could not be saved to Keychain (\(result)).") }
        } else if update != errSecSuccess {
            throw resourceError("The credential could not be updated in Keychain (\(update)).")
        }
    }
    static func get(key: String) -> String? {
        var attributes = query(key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(key: String) { SecItemDelete(query(key) as CFDictionary) }
}

private func resourceError(_ message: String) -> NSError {
    NSError(domain: "ProjectResources", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct ProjectResourcesView: View {
    @Bindable var model: WorkspaceModel
    @State private var editingSkill: ProjectSkill?
    @State private var editingCredential: ProjectCredential?
    @State private var deletingCredential: ProjectCredential?
    @State private var showingNewSkill = false
    @State private var showingNewCredential = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Resources").font(WorkbenchStyle.font(.largeTitle, weight: .bold))
                    Text("Reusable instructions, inputs and accounts for this project").foregroundStyle(.secondary)
                }
                resourceSection("Skills", icon: "wrench.and.screwdriver", addTitle: "Add skill", add: { showingNewSkill = true }) {
                    if model.resources.skills.isEmpty { emptyRow("No skills saved yet") }
                    ForEach(model.resources.skills) { skill in
                        resourceRow(skill.name, detail: skill.instructions, icon: "text.book.closed", edit: { editingSkill = skill }, delete: {
                            do { try model.resources.deleteSkill(skill.id) } catch { model.report(error) }
                        })
                    }
                }
                resourceSection("Accounts, inputs & secrets", icon: "lock.shield", addTitle: "Add resource", add: {
                    if model.bundleURL != nil || model.save() { showingNewCredential = true }
                }) {
                    if model.resources.credentials.isEmpty { emptyRow("No saved inputs, accounts or secrets yet") }
                    ForEach(model.resources.credentials) { credential in
                        resourceRow(credential.name, detail: "\(credential.kind.rawValue) · \(credential.note.isEmpty ? "Stored in Keychain" : credential.note)", icon: credential.kind == .account ? "person.crop.circle" : credential.kind == .input ? "text.cursor" : "key", edit: { editingCredential = credential }, delete: { deletingCredential = credential })
                    }
                }
                Label("Credential values stay in macOS Keychain. A copied project needs its credentials entered again.", systemImage: "info.circle")
                    .font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 1050, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).workbenchCanvas()
        .sheet(isPresented: $showingNewSkill) { SkillEditor(model: model, skill: nil) }
        .sheet(item: $editingSkill) { SkillEditor(model: model, skill: $0) }
        .sheet(isPresented: $showingNewCredential) { CredentialEditor(model: model, credential: nil) }
        .sheet(item: $editingCredential) { CredentialEditor(model: model, credential: $0) }
        .confirmationDialog("Delete stored credential?", isPresented: Binding(get: { deletingCredential != nil }, set: { if !$0 { deletingCredential = nil } })) {
            Button("Delete from Keychain", role: .destructive) {
                if let id = deletingCredential?.id { do { try model.resources.deleteCredential(id) } catch { model.report(error) } }
                deletingCredential = nil
            }
            Button("Cancel", role: .cancel) { deletingCredential = nil }
        } message: { Text("The saved value cannot be recovered after deletion.") }
    }
    func resourceSection<Content: View>(_ title: String, icon: String, addTitle: String, add: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: icon).font(WorkbenchStyle.font(.title3, weight: .bold))
                Spacer()
                Button(addTitle, systemImage: "plus", action: add).buttonStyle(.borderedProminent)
            }.padding(18)
            Divider()
            content()
        }.background(WorkbenchStyle.panel, in: WorkbenchStyle.shape()).overlay(WorkbenchStyle.shape().strokeBorder(WorkbenchStyle.border))
    }
    func resourceRow(_ title: String, detail: String, icon: String, edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(WorkbenchStyle.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(WorkbenchStyle.font(.body, weight: .semibold)); Text(detail).font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Edit", action: edit).buttonStyle(.borderless)
                Menu { Button("Delete", role: .destructive, action: delete) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Divider().padding(.leading, 54)
        }
    }
    func emptyRow(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
}

private struct SkillEditor: View {
    @Bindable var model: WorkspaceModel
    let skill: ProjectSkill?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(skill == nil ? "Add skill" : "Edit skill").font(WorkbenchStyle.font(.title2, weight: .bold))
            TextField("Name", text: $name)
            TextEditor(text: $instructions).font(WorkbenchStyle.font(.body)).frame(height: 180).overlay(WorkbenchStyle.shape(8).strokeBorder(WorkbenchStyle.border))
            Text("Instructions are saved with this project. They are not automatically used by a run.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { do { try model.resources.saveSkill(id: skill?.id, name: name, instructions: instructions); dismiss() } catch { model.report(error) } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 500).onAppear { name = skill?.name ?? ""; instructions = skill?.instructions ?? "" }
    }
}

private struct CredentialEditor: View {
    @Bindable var model: WorkspaceModel
    let credential: ProjectCredential?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ProjectCredential.Kind = .account
    @State private var note = ""
    @State private var username = ""
    @State private var value = ""
    @State private var showingValue = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(credential == nil ? "Add resource" : "Edit resource").font(WorkbenchStyle.font(.title2, weight: .bold))
            TextField("Name", text: $name)
            Picker("Type", selection: $kind) { ForEach(ProjectCredential.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if kind == .account { TextField("Email or username", text: $username) }
            HStack {
                if showingValue || kind == .input {
                    TextField(kind == .account ? "Password" : kind == .input ? "Value" : "Secret value", text: $value)
                } else {
                    SecureField(kind == .account ? "Password" : "Secret value", text: $value)
                }
                if kind != .input {
                    Button {
                        showingValue.toggle()
                    } label: {
                        Image(systemName: showingValue ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showingValue ? "Hide value" : "Show value")
                    .help(showingValue ? "Hide value" : "Show value")
                }
            }
            TextField("Note (optional)", text: $note)
            Text(kind == .input ? "An Input can fill one matching visible text field during a test. Its value stays in Keychain, but may appear in the app's screenshots." : "Values are stored in macOS Keychain.")
                .font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { do { try model.resources.saveCredential(id: credential?.id, name: name, kind: kind, note: note, username: username, value: value); dismiss() } catch { model.report(error) } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (credential == nil && value.isEmpty)) }
        }.padding(24).frame(width: 480).onAppear { name = credential?.name ?? ""; kind = credential?.kind ?? .account; note = credential?.note ?? ""; if let credential { username = model.resources.username(for: credential.id); value = model.resources.value(for: credential.id) } }
    }
}
