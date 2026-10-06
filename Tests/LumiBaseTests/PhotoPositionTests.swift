import XCTest
@testable import LumiBase

final class PhotoPositionTests: XCTestCase {
    @MainActor
    func testNoSelectionAndEmptyCollectionHaveNoIndex() {
        let state = AppState()
        XCTAssertEqual(state.photoPositionLabel, "0 photos")
        state.allAssets = [PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/a.arw"))]
        XCTAssertEqual(state.photoPositionLabel, "1 photos")
        state.primarySelectedAssetID = "missing"
        XCTAssertEqual(state.photoPositionLabel, "1 photos")
    }

    @MainActor
    func testFilteringAndReverseSortRecomputePosition() {
        let state = AppState()
        state.allAssets = ["a", "b", "c"].map {
            PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/\($0).arw"))
        }
        state.primarySelectedAssetID = state.allAssets[1].id
        state.filterCriteria.searchText = "b.arw"
        XCTAssertEqual(state.photoPositionLabel, "1 / 1 photos")
        state.filterCriteria.searchText = "a.arw"
        XCTAssertEqual(state.photoPositionLabel, "1 photos")
        state.filterCriteria.reset()
        state.primarySelectedAssetID = state.allAssets[0].id
        state.sortOrder = .filenameDescending
        XCTAssertEqual(state.photoPositionLabel, "3 / 3 photos")
    }

    @MainActor
    func testMultiSelectionUsesActivePhotoNotSelectionCount() {
        let state = AppState()
        state.allAssets = ["a", "b", "c"].map {
            PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/\($0).arw"))
        }
        state.sortOrder = .filenameAscending
        state.selectedAssetIDs = Set(state.allAssets.map(\.id))
        state.primarySelectedAssetID = state.allAssets[1].id
        XCTAssertEqual(state.photoPositionLabel, "2 / 3 photos")
    }

    @MainActor
    func testFirstMiddleLastPositionUsesVisibleOrder() {
        let state = AppState()
        state.allAssets = ["c", "a", "b"].map {
            PhotoAsset(fileURL: URL(fileURLWithPath: "/photos/\($0).arw"))
        }
        state.sortOrder = .filenameAscending
        for (offset, asset) in state.displayedAssets.enumerated() {
            state.primarySelectedAssetID = asset.id
            XCTAssertEqual(state.photoPositionLabel, "\(offset + 1) / 3 photos")
        }
    }
}
