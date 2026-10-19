import XCTest
import RunnerCore
@testable import ModelProviders

private actor HTTPStub: JevHTTPClient {
    let body: Data
    let status: Int
    var captured: URLRequest?
    init(_ body: Data, status: Int = 200) { self.body = body; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) { captured = request; return (body, status) }
}
final class JevHTTPTests: XCTestCase {
    func testActualWireContractAndLocalBinding() async throws {
        let candidate = ActionCandidate(captureID: .init(), title: "Not Now", action: .dismiss, isSafeForAutomaticExecution: true)
        let stub = HTTPStub(Data("{\"answers\":{\"recovery\":{\"type\":\"choice\",\"choice\":\"\(candidate.id.uuidString)\",\"probabilities\":{\"\(candidate.id.uuidString)\":0.99,\"abstain\":0.01},\"confidence\":0.95}}}".utf8))
        let result = try await JevCandidateChooser(transport: JevHTTPTransport(apiKey: "test-only-key", client: stub)).choose(from: [candidate], context: "Locally reviewed reminder")
        XCTAssertEqual(result.captureID, candidate.captureID)
        XCTAssertEqual(result.providerEvidence?.probabilities?.count, 2)
        let request = await stub.captured
        XCTAssertEqual(request?.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request?.httpMethod, "POST")
        let body = try XCTUnwrap(request?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["state", "model", "questions"]))
        XCTAssertEqual(json["model"] as? String, "jev-latest")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-only-key"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("test-only-key"))
    }
    func testAbstentionMalformedAndUnknownResponsesRetainRefusal() async throws {
        let candidate = ActionCandidate(captureID: .init(), title: "Not Now", action: .dismiss, isSafeForAutomaticExecution: true)
        for (selected, probabilities, confidence) in [("abstain", [candidate.id.uuidString: 0.1, "abstain": 0.9], 0.9), ("invented", [candidate.id.uuidString: 1.0, "abstain": 0], 1), (candidate.id.uuidString, [candidate.id.uuidString: 0.5, "abstain": 0.5], 1), (candidate.id.uuidString, [candidate.id.uuidString: 0.8], 0.9), (candidate.id.uuidString, [candidate.id.uuidString: 0.1, "abstain": 0.9], 0.9)] {
            let data = try JSONSerialization.data(withJSONObject: ["answers": ["recovery": ["type": "choice", "choice": selected, "probabilities": probabilities, "confidence": confidence]]])
            do { _ = try await JevCandidateChooser(transport: JevHTTPTransport(apiKey: "test-only", client: HTTPStub(data))).choose(from: [candidate], context: ""); XCTFail("Accepted invalid/abstained choice") }
            catch let failure as CandidateProviderRefusal { XCTAssertFalse(failure.evidence.accepted); XCTAssertEqual(failure.evidence.captureID, candidate.captureID); XCTAssertNoThrow(try JSONEncoder().encode(failure.evidence)) }
        }
    }
    func testAbsentCredentialsNeverSendAndHTTPErrorBodyNeverPersists() async throws {
        let candidate = ActionCandidate(captureID: .init(), title: "Close", action: .dismiss, isSafeForAutomaticExecution: true)
        for key in ["", "test-secret"] {
            let stub = HTTPStub(Data("test-secret authorization error".utf8), status: 401)
            do { _ = try await JevCandidateChooser(transport: JevHTTPTransport(apiKey: key, client: stub)).choose(from: [candidate], context: ""); XCTFail() }
            catch let failure as CandidateProviderRefusal { XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure.evidence), as: UTF8.self).contains("test-secret")) }
            if key.isEmpty { let value = await stub.captured; XCTAssertNil(value) }
        }
    }
    func testRequestRoundtripPreservesHostIdentity() throws {
        let value = CandidateDecisionRequest(captureID: .init(), context: "state", options: [])
        XCTAssertEqual(try JSONDecoder().decode(CandidateDecisionRequest.self, from: JSONEncoder().encode(value)), value)
    }
}
