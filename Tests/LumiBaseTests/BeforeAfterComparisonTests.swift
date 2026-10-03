import XCTest
import AppKit
@testable import LumiBase

@MainActor
final class BeforeAfterComparisonTests: XCTestCase {
    
    func testXMPBeforeStateResetsAllDevelopEdits() {
        var xmp = XMPMetadata()
        xmp.exposure2012 = 1.50
        xmp.temperature = 6500
        xmp.tint = 15
        xmp.contrast2012 = 25
        xmp.highlights2012 = -50
        xmp.shadows2012 = 30
        xmp.whites2012 = 20
        xmp.blacks2012 = -15
        xmp.dehaze = 10
        xmp.vibrance = 25
        xmp.saturation = 15
        xmp.clarity2012 = 20
        xmp.texture = 15
        xmp.convertToGrayscale = true
        xmp.cameraProfile = "Adobe Standard"
        xmp.advancedRAWHighlightRecovery = true
        xmp.cropGeometry = CropGeometry(top: 0.1, left: 0.1, bottom: 0.9, right: 0.9, angle: 5.0)
        
        XCTAssertTrue(xmp.hasDevelopEdits)
        XCTAssertTrue(xmp.hasCrop)
        
        // Before state with crop preserved (for Split View alignment)
        let beforeSplit = xmp.beforeState(preserveCrop: true)
        XCTAssertNil(beforeSplit.exposure2012)
        XCTAssertNil(beforeSplit.temperature)
        XCTAssertNil(beforeSplit.tint)
        XCTAssertNil(beforeSplit.contrast2012)
        XCTAssertNil(beforeSplit.highlights2012)
        XCTAssertNil(beforeSplit.shadows2012)
        XCTAssertNil(beforeSplit.whites2012)
        XCTAssertNil(beforeSplit.blacks2012)
        XCTAssertNil(beforeSplit.dehaze)
        XCTAssertNil(beforeSplit.vibrance)
        XCTAssertNil(beforeSplit.saturation)
        XCTAssertNil(beforeSplit.clarity2012)
        XCTAssertNil(beforeSplit.texture)
        XCTAssertNil(beforeSplit.convertToGrayscale)
        XCTAssertNil(beforeSplit.cameraProfile)
        XCTAssertNil(beforeSplit.advancedRAWHighlightRecovery)
        XCTAssertTrue(beforeSplit.hasCrop)
        XCTAssertEqual(beforeSplit.cropGeometry.top, 0.1, accuracy: 0.0001)
        XCTAssertEqual(beforeSplit.cropGeometry.angle, 5.0, accuracy: 0.0001)
        
        // Before state with crop reset (for uncropped As-Shot inspection)
        let beforeUncropped = xmp.beforeState(preserveCrop: false)
        XCTAssertFalse(beforeUncropped.hasDevelopEdits)
        XCTAssertFalse(beforeUncropped.hasCrop)
        XCTAssertNil(beforeUncropped.cropTop)
        XCTAssertNil(beforeUncropped.cropAngle)
    }
    
    func testComparisonModeProperties() {
        XCTAssertEqual(ComparisonMode.off.isSplit, false)
        XCTAssertEqual(ComparisonMode.off.isSideBySide, false)
        XCTAssertEqual(ComparisonMode.off.isActive, false)
        
        XCTAssertEqual(ComparisonMode.splitLeftRight.isSplit, true)
        XCTAssertEqual(ComparisonMode.splitLeftRight.isActive, true)
        
        XCTAssertEqual(ComparisonMode.splitTopBottom.isSplit, true)
        XCTAssertEqual(ComparisonMode.splitTopBottom.isActive, true)
        
        XCTAssertEqual(ComparisonMode.sideBySide.isSplit, false)
        XCTAssertEqual(ComparisonMode.sideBySide.isSideBySide, true)
        XCTAssertEqual(ComparisonMode.sideBySide.isActive, true)
    }
    
    func testAppStateBeforeAfterToggleAndCycle() {
        let appState = AppState()
        XCTAssertEqual(appState.comparisonMode, .off)
        XCTAssertFalse(appState.isBeforeToggled)
        XCTAssertEqual(appState.splitPosition, 0.5)
        
        // 1. Toggle Before/After in single image mode
        appState.toggleBeforeAfter()
        XCTAssertTrue(appState.isBeforeToggled)
        XCTAssertEqual(appState.comparisonMode, .off)
        
        appState.toggleBeforeAfter()
        XCTAssertFalse(appState.isBeforeToggled)
        
        // 2. Cycle Comparison Mode forward
        appState.cycleComparisonMode(forward: true)
        XCTAssertEqual(appState.comparisonMode, .splitLeftRight)
        XCTAssertFalse(appState.isBeforeToggled)
        
        appState.cycleComparisonMode(forward: true)
        XCTAssertEqual(appState.comparisonMode, .sideBySide)
        
        appState.cycleComparisonMode(forward: true)
        XCTAssertEqual(appState.comparisonMode, .splitTopBottom)
        
        appState.cycleComparisonMode(forward: true)
        XCTAssertEqual(appState.comparisonMode, .off)
        
        // 3. Cycle Comparison Mode backward
        appState.cycleComparisonMode(forward: false)
        XCTAssertEqual(appState.comparisonMode, .splitTopBottom)
        
        appState.cycleComparisonMode(forward: false)
        XCTAssertEqual(appState.comparisonMode, .sideBySide)
        
        // 4. toggleBeforeAfter when comparisonMode is active exits comparison
        appState.toggleBeforeAfter()
        XCTAssertEqual(appState.comparisonMode, .off)
        XCTAssertFalse(appState.isBeforeToggled)
    }
    
    func testEnteringCropModeExitsComparison() {
        let appState = AppState()
        appState.comparisonMode = .splitLeftRight
        appState.isBeforeToggled = true
        
        appState.toggleCropMode()
        XCTAssertEqual(appState.activeDevelopTool, .crop)
        XCTAssertEqual(appState.comparisonMode, .off)
        XCTAssertFalse(appState.isBeforeToggled)
    }
    
    func testGlobalKeyboardShortcutsForBeforeAfter() {
        let appState = AppState()
        
        // Backslash key (\) toggles Before/After
        let backslashEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\\",
            charactersIgnoringModifiers: "\\",
            isARepeat: false,
            keyCode: 42
        )!
        
        let handledBackslash = appState.handleGlobalKeyEvent(backslashEvent)
        XCTAssertTrue(handledBackslash)
        XCTAssertTrue(appState.isBeforeToggled)
        
        // Pressing backslash again toggles off
        let handledBackslash2 = appState.handleGlobalKeyEvent(backslashEvent)
        XCTAssertTrue(handledBackslash2)
        XCTAssertFalse(appState.isBeforeToggled)
        
        // 'y' key cycles comparison mode
        let yEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16
        )!
        
        let handledY = appState.handleGlobalKeyEvent(yEvent)
        XCTAssertTrue(handledY)
        XCTAssertEqual(appState.comparisonMode, .splitLeftRight)
        
        // Shift+'y' cycles comparison mode backward
        let shiftYEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "Y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16
        )!
        
        let handledShiftY = appState.handleGlobalKeyEvent(shiftYEvent)
        XCTAssertTrue(handledShiftY)
        XCTAssertEqual(appState.comparisonMode, .off)
    }
}
