import Foundation
import XCTest
import ProjectDomain

final class LinearIssueDraftTests: XCTestCase {
    func testProposesOneGoalFromExplicitAcceptanceCriteria() {
        let issue = LinearIssueDraft(identifier: "APP-42", title: "Allow account recovery",
            description: "People who forgot their password need a route back in.\n\n## Acceptance Criteria\n- [ ] Reset link is visible on sign in\n- [ ] Confirmation appears after requesting a link\n\n## Technical Notes\nUse the existing endpoint.",
            url: URL(string: "https://linear.app/example/issue/APP-42")!)
        XCTAssertEqual(issue.proposedName, "APP-42: Allow account recovery")
        XCTAssertTrue(issue.proposedGoal.contains("People who forgot their password"))
        XCTAssertFalse(issue.proposedGoal.contains("Reset link is visible"))
        XCTAssertEqual(issue.proposedSuccessCriteria,
            "- [ ] Reset link is visible on sign in\n- [ ] Confirmation appears after requesting a link")
    }

    func testDoesNotInventAcceptanceCriteria() {
        let issue = LinearIssueDraft(identifier: "APP-7", title: "Improve loading",
            description: "Make this faster.", url: URL(string: "https://linear.app/example/issue/APP-7")!)
        XCTAssertEqual(issue.proposedSuccessCriteria, "")
        XCTAssertEqual(issue.proposedGoal, "Improve loading\n\nTicket context:\nMake this faster.")
    }
}
