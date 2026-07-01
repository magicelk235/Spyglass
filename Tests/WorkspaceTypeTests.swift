import XCTest
@testable import DrivePeakKit

final class WorkspaceTypeTests: XCTestCase {

    func testExtensionRoundTrip() {
        for type in WorkspaceType.allCases {
            XCTAssertEqual(WorkspaceType(fileExtension: type.fileExtension), type)
        }
    }

    func testExtensionIsCaseInsensitive() {
        XCTAssertEqual(WorkspaceType(fileExtension: "GDOC"), .doc)
        XCTAssertEqual(WorkspaceType(fileExtension: "GSheet"), .sheet)
    }

    func testUnknownExtension() {
        XCTAssertNil(WorkspaceType(fileExtension: "pdf"))
        XCTAssertNil(WorkspaceType(fileExtension: ""))
    }

    func testUTIsAreUnique() {
        let utis = WorkspaceType.allCases.map(\.uti)
        XCTAssertEqual(Set(utis).count, utis.count)
    }

    func testOnlyFormsAndSitesAreNotExportable() {
        let nonExportable = WorkspaceType.allCases.filter { !$0.isExportable }
        XCTAssertEqual(Set(nonExportable), [.form, .site])
    }
}
