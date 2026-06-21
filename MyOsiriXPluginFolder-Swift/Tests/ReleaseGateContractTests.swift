import Foundation
import XCTest

final class ReleaseGateContractTests: XCTestCase {
    private var repositoryRoot: URL {
        let testFile = URL(fileURLWithPath: #filePath)
        return testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReleaseQualityGateSchemaIsVersioned() throws {
        let schema = try loadJSON("schemas/release_quality_gate.schema.json")

        XCTAssertEqual(schema["schema_version"] as? Int, 1)
        XCTAssertEqual(schema["title"] as? String, "TotalSegmentator Horos/OsiriX Release Quality Gate")
        let required = try XCTUnwrap(schema["required"] as? [String])
        for field in [
            "supported_matrix",
            "automated_evidence",
            "geometry_corpus",
            "host_smoke_evidence",
            "artifact_retention",
            "certification_status",
            "sign_off"
        ] {
            XCTAssertTrue(required.contains(field), "Missing release gate field: \(field)")
        }
    }

    func testGeometryCorpusIsSyntheticAndCoversFailClosedCases() throws {
        let corpus = try loadJSON("tests/fixtures/geometry_corpus/v1/geometry-corpus.json")

        XCTAssertEqual(corpus["schema_version"] as? Int, 1)
        XCTAssertEqual(corpus["corpus_version"] as? String, "2026.06.geometry-v1")
        XCTAssertEqual(corpus["privacy"] as? String, "synthetic-no-phi")

        let fixtures = try XCTUnwrap(corpus["fixtures"] as? [[String: Any]])
        let fixtureIDs = Set(fixtures.compactMap { $0["id"] as? String })
        for requiredID in [
            "axial_identity",
            "oblique_acquisition",
            "same_dimensions_unrelated_series",
            "enhanced_multiframe",
            "mpr_derived_viewer"
        ] {
            XCTAssertTrue(fixtureIDs.contains(requiredID), "Missing geometry fixture: \(requiredID)")
        }
    }

    func testHostSmokeTemplateRequiresViewerRecoveryAndPrivacyEvidence() throws {
        let template = try loadJSON("docs/release/host-smoke-report-template.json")

        XCTAssertEqual(template["schema_version"] as? Int, 1)
        XCTAssertEqual(template["geometry_corpus_version"] as? String, "2026.06.geometry-v1")
        let scenarios = try XCTUnwrap(template["host_smoke_scenarios"] as? [String: Any])
        for scenario in [
            "exact_source_viewer_roi_application",
            "safe_reopen_resync",
            "reject_unrelated_same_size_series",
            "cancel_and_recover",
            "diagnostic_bundle_privacy"
        ] {
            XCTAssertNotNil(scenarios[scenario], "Missing host smoke scenario: \(scenario)")
        }
    }

    private func loadJSON(_ relativePath: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
