import AppKit
import SwiftUI
import XCTest
@testable import KaddoCanvas

final class PetCanvasRenderingTests: XCTestCase {
    @MainActor
    func testCompactCanvasRendersOnlyCompanionAndKeepsItsBaselineOnExpansion() throws {
        _ = NSApplication.shared
        let model = PetApplicationState(speechBubbleText: "A long reply should stay tucked away until hover.")
        model.activeTask = PetTask(title: "Study for 25 minutes")
        let presentation = PetChatPresentationState()
        let canvas = PetCanvasWindowController(model: model, presentation: presentation,
                                               animationsEnabled: false)
        defer { canvas.close() }
        let host = try XCTUnwrap(canvas.window?.contentView)
        canvas.window?.orderFrontRegardless()
        settleLayout()
        let compact = try bitmap(host)
        let spriteHeight = Int(canvas.preferences.anchorSize.height / host.bounds.height * CGFloat(compact.pixelsHigh))
        for y in 0..<(compact.pixelsHigh - spriteHeight) {
            for x in 0..<compact.pixelsWide {
                XCTAssertEqual(compact.colorAt(x: x, y: y)?.alphaComponent, 0)
            }
        }
        presentation.expand()
        settleLayout()
        let expanded = try bitmap(host)
        if let directory = ProcessInfo.processInfo.environment["KADDO_HOVER_ARTIFACTS"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try compact.representation(using: .png, properties: [:])?
                .write(to: destination.appendingPathComponent("pet-only-native.png"))
            try expanded.representation(using: .png, properties: [:])?
                .write(to: destination.appendingPathComponent("hover-speech-native.png"))
        }
        XCTAssertNotEqual(compact.representation(using: .png, properties: [:]),
                          expanded.representation(using: .png, properties: [:]))
        for y in (compact.pixelsHigh - spriteHeight)..<compact.pixelsHigh {
            for x in 0..<compact.pixelsWide {
                XCTAssertEqual(compact.colorAt(x: x, y: y), expanded.colorAt(x: x, y: y),
                               "Revealing speech must not move the pet")
            }
        }
    }

    @MainActor
    func testGoalExpiryInterruptsTheFloatingPetAndCanAlertAgain() throws {
        _ = NSApplication.shared
        let model = PetApplicationState()
        let presentation = PetChatPresentationState()
        presentation.expand()
        let canvas = PetCanvasWindowController(model: model, presentation: presentation,
                                               animationsEnabled: false)
        defer { canvas.close() }
        let host = try XCTUnwrap(canvas.window?.contentView)
        canvas.window?.orderFrontRegardless()
        settleLayout()
        XCTAssertEqual(model.currentEmotion, .idle, "Initial zero is not an expired session")
        XCTAssertEqual(model.speechBubbleText, "Ready when you are.")

        for startingEmotion in [PetEmotion.idle, .sleeping] {
            model.currentEmotion = startingEmotion
            model.speechBubbleText = "Working on the goal."
            model.goalTimerSecondsRemaining = 30
            settleLayout()
            XCTAssertEqual(model.currentEmotion, startingEmotion)
            XCTAssertEqual(model.speechBubbleText, "Working on the goal.")
            let before = try snapshot(host)

            // Combine must see even countdown changes within a single UI cycle.
            model.goalTimerSecondsRemaining = 1
            model.goalTimerSecondsRemaining = 0
            _ = try assertRerender(host, previous: before)
            XCTAssertEqual(model.currentEmotion, .celebrating)
            XCTAssertEqual(
                model.speechBubbleText,
                "Time's up! Goal complete? Let's check the files if you're stuck!"
            )
            let celebration = try XCTUnwrap(PetSpriteFrames.images[.celebrating]?.tiffRepresentation)
            XCTAssertNotEqual(celebration, PetSpriteFrames.images[startingEmotion]?.tiffRepresentation)

            model.speechBubbleText = "Goal checked."
            model.currentEmotion = .happy
            model.goalTimerSecondsRemaining = 0
            settleLayout()
            XCTAssertEqual(model.speechBubbleText, "Goal checked.")
            XCTAssertEqual(model.currentEmotion, .happy, "Repeated zero must not retrigger the alert")
        }
    }

    @MainActor
    func testEveryPropertyInvalidatesTheHostedCanvas() throws {
        _ = NSApplication.shared
        let model = PetApplicationState()
        let presentation = PetChatPresentationState()
        presentation.expand()
        let canvas = PetCanvasWindowController(model: model, presentation: presentation,
                                               animationsEnabled: false)
        defer { canvas.close() }
        let panel = try XCTUnwrap(canvas.window as? FloatingPetPanel)
        let host = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertFalse(host.mouseDownCanMoveWindow)
        panel.orderFrontRegardless()
        settleLayout()

        // Do not replace rootView or reconstruct the hosting view after mutations.
        // Each change must invalidate and redraw the same live SwiftUI hierarchy.
        var previous = try snapshot(host)
        settleLayout()
        XCTAssertEqual(try snapshot(host), previous, "An unchanged canvas must render identically")
        model.currentEmotion = .sleeping
        previous = try assertRerender(host, previous: previous)
        model.speechBubbleText = "Canvas state changed."
        previous = try assertRerender(host, previous: previous)
        model.activeTask = PetTask(title: "Review the window engine")
        previous = try assertRerender(host, previous: previous)
        model.activeTask?.title = "Review the alpha targeting"
        previous = try assertRerender(host, previous: previous)
        model.speechBubbleText = ""
        previous = try assertRerender(host, previous: previous)
        model.activeTask = nil
        _ = try assertRerender(host, previous: previous)
    }

    @MainActor
    func testTwoCanvasesObserveTheSameApplicationModel() throws {
        _ = NSApplication.shared
        let model = PetApplicationState()
        let presentation = PetChatPresentationState()
        presentation.expand()
        let first = PetCanvasWindowController(model: model, presentation: presentation, animationsEnabled: false)
        let second = PetCanvasWindowController(model: model, presentation: presentation, animationsEnabled: false)
        defer { first.close(); second.close() }
        let firstHost = try XCTUnwrap(first.window?.contentView)
        let secondHost = try XCTUnwrap(second.window?.contentView)
        first.window?.orderFrontRegardless()
        second.window?.orderFrontRegardless()
        settleLayout()
        let beforeFirst = try snapshot(firstHost)
        let beforeSecond = try snapshot(secondHost)
        model.speechBubbleText = "Shared across both canvases."
        _ = try assertRerender(firstHost, previous: beforeFirst)
        _ = try assertRerender(secondHost, previous: beforeSecond)
    }

    @MainActor
    func testHostingViewHasTransparentCornersAndVisibleBodyPixels() throws {
        _ = NSApplication.shared
        let canvas = PetCanvasWindowController(model: PetApplicationState(), animationsEnabled: false)
        defer { canvas.close() }
        let panel = try XCTUnwrap(canvas.window as? FloatingPetPanel)
        let host = try XCTUnwrap(panel.contentView)
        panel.orderFrontRegardless()
        settleLayout()
        XCTAssertFalse(RenderedAlphaHitTester.containsVisiblePixel(at: NSPoint(x: 1, y: 1), in: host))
        // Inspect the real hosted bitmap, including rounded speech bubble and sprite holes.
        let bitmap = try bitmap(host)
        var visible = 0
        var transparent = 0
        var visiblePoint: NSPoint?
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if alpha > 0 {
                    visible += 1
                    let viewY = (CGFloat(y) + 0.5) / CGFloat(bitmap.pixelsHigh) * host.bounds.height
                    visiblePoint = NSPoint(
                        x: (CGFloat(x) + 0.5) / CGFloat(bitmap.pixelsWide) * host.bounds.width,
                        y: host.isFlipped ? viewY : host.bounds.height - viewY
                    )
                } else {
                    transparent += 1
                }
            }
        }
        XCTAssertGreaterThan(visible, 20)
        XCTAssertGreaterThan(transparent, visible)
        XCTAssertEqual(PetSpriteFrames.images.count, PetEmotion.allCases.count)
        let tracker = PointerPassthroughController(panel: panel)
        let clearPoint = host.convert(NSPoint(x: 1, y: 1), to: nil)
        tracker.updatePointer(globalPoint: panel.convertPoint(toScreen: clearPoint))
        XCTAssertTrue(panel.ignoresMouseEvents)
        let opaquePoint = host.convert(try XCTUnwrap(visiblePoint), to: nil)
        tracker.updatePointer(globalPoint: panel.convertPoint(toScreen: opaquePoint))
        XCTAssertFalse(panel.ignoresMouseEvents, "Actual rendered body pixels must receive events")
    }

    @MainActor
    private func assertRerender(
        _ view: NSView,
        previous: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        // Publication is synchronous; SwiftUI commits rendering on the next UI cycle.
        // A bounded run-loop wait verifies that no second action is needed to update it.
        let deadline = Date().addingTimeInterval(1)
        var current = previous
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            current = try snapshot(view)
        } while current == previous && Date() < deadline
        XCTAssertNotEqual(current, previous, "State mutation must redraw the hosted canvas", file: file, line: line)
        return current
    }

    @MainActor
    private func settleLayout() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func snapshot(_ view: NSView) throws -> Data {
        try XCTUnwrap(bitmap(view).representation(using: .png, properties: [:]))
    }
}
