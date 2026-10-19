import SwiftUI
import ProjectDomain

struct LinearTicketImportView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var issueURL = ""
    @State private var draft: LinearIssueDraft?
    @State private var testName = ""
    @State private var goal = ""
    @State private var criteria = ""
    @State private var isConnected = LinearMCPClient.shared.isConnected
    @State private var busy = false
    @State private var error: String?
    @State private var sourceProjectID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a test from a ticket").font(WorkbenchStyle.titleFont)
            Text("Connect Linear, then paste a ticket link. Review the goal and visible result before adding one test to this project.")
                .workbenchInfo()

            HStack {
                Label(isConnected ? "Linear connected" : "Linear not connected",
                      systemImage: isConnected ? "checkmark.circle.fill" : "circle.dotted")
                Spacer()
                if isConnected {
                    Button("Disconnect") {
                        do { try LinearMCPClient.shared.disconnect(); isConnected = false; draft = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(busy)
                } else {
                    Button("Connect Linear") {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await LinearMCPClient.shared.connect(); isConnected = true; error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
            }

            HStack {
                TextField("Linear ticket URL or ID", text: $issueURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: issueURL) { draft = nil }
                Button("Fetch ticket") { fetch() }
                    .disabled(busy || !isConnected || issueURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let draft {
                Divider()
                HStack {
                    Text(draft.identifier).font(WorkbenchStyle.font(.headline, weight: .semibold))
                    Text(draft.title).lineLimit(1)
                    Spacer()
                    Link("Open ticket", destination: draft.url)
                }
                Text("One test is proposed. Check that the success description is observable in the app.")
                    .workbenchInfo()
                TextField("Test name", text: $testName)
                Text("Goal").font(WorkbenchStyle.font(.caption, weight: .semibold))
                TextEditor(text: $goal).frame(height: 100).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Visible success description").font(WorkbenchStyle.font(.caption, weight: .semibold))
                TextEditor(text: $criteria).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if draft.proposedSuccessCriteria.isEmpty {
                    Text("No acceptance criteria section was found. Describe what a successful screen should show before adding the test.")
                        .foregroundStyle(.orange)
                }
            }

            if let error { Text(error).foregroundStyle(.red).font(WorkbenchStyle.font(.caption)) }
            if busy { ProgressView() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button("Add test") {
                    do {
                        guard model.project?.id == sourceProjectID else {
                            self.error = "The project changed. Open the ticket import again."
                            return
                        }
                        try model.addLinearTest(name: testName, goal: goal, successCriteria: criteria)
                        dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || draft == nil || testName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { sourceProjectID = model.project?.id }
    }

    private func fetch() {
        Task {
            busy = true; defer { busy = false }
            do {
                let issue = try await LinearMCPClient.shared.fetchIssue(issueURL)
                guard model.project?.id == sourceProjectID else {
                    self.error = "The project changed. Open the ticket import again."
                    return
                }
                draft = issue
                testName = issue.proposedName
                goal = issue.proposedGoal
                criteria = issue.proposedSuccessCriteria
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
