import XCTest
@testable import RunnerCore

final class TargetMatchingTests: XCTestCase {
    func testNormalizeIgnoresCaseAndWhitespace() {
        XCTAssertEqual(TargetTextMatching.normalize("Sign  in with Apple"), "sign in with apple")
        XCTAssertEqual(TargetTextMatching.normalize("  Sign In With Apple Button "), "sign in with apple button")
    }

    func testEqualsIsTolerant() {
        XCTAssertTrue(TargetTextMatching.equals("Sign in with Apple", "sign in with apple"))
        XCTAssertFalse(TargetTextMatching.equals("Sign in with Apple", "Continue with Apple"))
        XCTAssertFalse(TargetTextMatching.equals(nil, "apple"))
    }

    func testContainsNeedsMinimumQueryLength() {
        XCTAssertTrue(TargetTextMatching.contains("Sign in with Apple", "apple"))
        XCTAssertTrue(TargetTextMatching.contains("Sign in with Apple", "sign in with apple"))
        // Single characters must not match the world via substring.
        XCTAssertFalse(TargetTextMatching.contains("Sign in with Apple", "a"))
        XCTAssertFalse(TargetTextMatching.contains(nil, "apple"))
    }

    func testContainsEitherCoversOverSpecifiedQueries() {
        // User guessed an identifier from the label, adding "Button".
        XCTAssertTrue(TargetTextMatching.containsEither("Sign in with Apple", "Sign In With Apple Button"))
        // Vague under-specified query still works.
        XCTAssertTrue(TargetTextMatching.containsEither("Sign in with Apple", "apple"))
        // Unrelated strings never match.
        XCTAssertFalse(TargetTextMatching.containsEither("Terms & Conditions", "Sign In With Apple Button"))
        // Empty element labels never reverse-match.
        XCTAssertFalse(TargetTextMatching.containsEither("", "Sign In With Apple Button"))
        XCTAssertFalse(TargetTextMatching.containsEither(nil, "Sign In With Apple Button"))
    }

    func testWildcardNilTarget() {
        XCTAssertTrue(TargetTextMatching.fieldEquals("anything", nil))
        XCTAssertTrue(TargetTextMatching.fieldContains("anything", nil))
        XCTAssertFalse(TargetTextMatching.fieldEquals(nil, "apple"))
    }

    func testWordsSplitCamelCaseAndSeparators() {
        XCTAssertEqual(TargetTextMatching.words("BackButton"), ["back", "button"])
        XCTAssertEqual(TargetTextMatching.words("chevron.backward"), ["chevron", "backward"])
        XCTAssertEqual(TargetTextMatching.words("Close  button"), ["close", "button"])
    }

    func testDismissalAffordanceTreatsBackAndCloseAsOneFamily() {
        for value in ["close button", "BackButton", "back", "Close", "dismiss", "Dismiss button", "xmark", "chevron.backward", "go back", "navigation back", "Not Now", "Later", "Cancel"] {
            XCTAssertTrue(TargetTextMatching.dismissalAffordance(value), value)
        }
        for value in ["close account", "Sign in", "Continue button", "backspace", "terms and conditions", ""] {
            XCTAssertFalse(TargetTextMatching.dismissalAffordance(value), value)
        }
        XCTAssertFalse(TargetTextMatching.dismissalAffordance(nil))
    }

    func testProgressAffordanceAllowsForwardControlsAndRejectsRisk() {
        for value in ["Next", "Continue button", "Continue with Password", "Get Started", "Done", "Got it", "Sign in", "Skip", "Proceed"] {
            XCTAssertTrue(TargetTextMatching.progressAffordance(value), value)
        }
        for value in ["Start Free Trial", "Continue to Payment", "Pay now", "Delete account", "Cancel", "Subscribe", "Confirm order", "Upgrade plan", "Allow", "Close", "Back", "Terms and Conditions", ""] {
            XCTAssertFalse(TargetTextMatching.progressAffordance(value), value)
        }
        XCTAssertFalse(TargetTextMatching.progressAffordance(nil))
    }

    func testIrreversibleIntentDetectsVocabularyAndMoney() {
        func node(_ label: String) -> UIElement { .init(identifier: nil, role: "staticText", label: label, value: nil, frame: nil) }
        XCTAssertTrue(TargetTextMatching.irreversibleIntent([node("This action deletes your account")]))
        XCTAssertTrue(TargetTextMatching.irreversibleIntent([node("Only $4.99 per month")]))
        XCTAssertTrue(TargetTextMatching.irreversibleIntent([node("Cancel anytime · £9.99/month")]))
        XCTAssertFalse(TargetTextMatching.irreversibleIntent([node("Welcome to the example app")]))
        XCTAssertFalse(TargetTextMatching.irreversibleIntent([]))
    }
}
