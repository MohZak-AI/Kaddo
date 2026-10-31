import AppKit
import SwiftUI
import XCTest
@testable import KaddoCanvas

final class PetInterfaceTests: XCTestCase {
    @MainActor
    func testReducedTransparencyUsesOpaqueAdaptiveSurfaceAndContrastBorder() throws {
        _ = NSApplication.shared
        func render(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: PetSurfaceBackground(kind: .control,
                shape: RoundedRectangle(cornerRadius: 16), reducedTransparency: true,
                increasedContrast: contrast == .increased)
                .frame(width: 120, height: 80).environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(effects(in: host).isEmpty, "Reduced transparency must remove backdrop sampling")
            return try bitmap(host)
        }
        let light = try render(.light)
        let dark = try render(.dark)
        let highContrast = try render(.light, contrast: .increased)
        let lightCenter = try XCTUnwrap(light.colorAt(x: light.pixelsWide / 2, y: light.pixelsHigh / 2))
        let darkCenter = try XCTUnwrap(dark.colorAt(x: dark.pixelsWide / 2, y: dark.pixelsHigh / 2))
        XCTAssertEqual(lightCenter.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(darkCenter.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(try luminance(lightCenter), try luminance(darkCenter) + 0.4)
        XCTAssertEqual(light.colorAt(x: 0, y: 0)?.alphaComponent, 0, "Rounded corners stay click-through")
        XCTAssertNotEqual(light.representation(using: .png, properties: [:]),
                          highContrast.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testReplyUsesActiveBehindWindowMaterial() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: PetSurfaceBackground(kind: .reply,
            shape: RoundedRectangle(cornerRadius: 16)))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
        host.layoutSubtreeIfNeeded()
        let backdrops = effects(in: host)
        XCTAssertEqual(backdrops.count, 1)
        XCTAssertEqual(backdrops.first?.blendingMode, .behindWindow)
        XCTAssertEqual(backdrops.first?.state, .active)
        XCTAssertEqual(backdrops.first?.material, .popover)
    }

    @MainActor
    func testReenteringDuringFadeKeepsPanelAttachedAndPreservesDraft() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(json: "", modelCatalog: #"{"models":[{"name":"local:test"}]}"#)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        let controller = NotesQueryWindowController(state: state,
            assistant: LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session)),
            settings: AssistantSettings())
        let canvas = PetCanvasWindowController(model: state, presentation: controller.presentation,
                                               animationsEnabled: false)
        defer { controller.close(); canvas.close() }
        canvas.showPet()
        controller.attach(to: canvas)
        (canvas.window as? FloatingPetPanel)?.stopAlphaTracking()
        let pet = try XCTUnwrap(canvas.window)
        let composer = try XCTUnwrap(controller.window)
        let sprite = PetChatLayout.spriteFrame(in: pet.frame)
        let inside = NSPoint(x: sprite.midX, y: sprite.midY)
        let outside = NSPoint(x: pet.frame.minX - 100, y: pet.frame.minY)
        let origin = pet.frame.origin
        controller.updateHover(globalPoint: inside, now: 0)
        controller.updateHover(globalPoint: inside, now: 0.13)
        controller.presentation.query = "Preserve this draft"
        for cycle in 0..<3 {
            let time = Double(cycle) * 4 + 1
            controller.updateHover(globalPoint: outside, now: time)
            controller.updateHover(globalPoint: outside, now: time + 0.66)
            XCTAssertTrue(composer.ignoresMouseEvents)
            try await Task.sleep(for: .milliseconds(20))
            controller.updateHover(globalPoint: inside, now: time + 1)
            controller.updateHover(globalPoint: inside, now: time + 1.13)
            try await Task.sleep(for: .milliseconds(220))
            XCTAssertTrue(composer.isVisible, "A stale fade must not retire a reopened panel")
            XCTAssertTrue(composer.parent === pet)
            XCTAssertFalse(composer.ignoresMouseEvents)
            XCTAssertFalse(composer.isKeyWindow, "Reentry must not take keyboard focus")
            XCTAssertEqual(composer.alphaValue, 1)
            XCTAssertEqual(pet.frame.origin, origin)
            XCTAssertEqual(controller.presentation.query, "Preserve this draft")
        }
    }

    @MainActor
    func testComposerAppearanceChangesWhileEditingAndResizing() async throws {
        _ = NSApplication.shared
        let http = Phase4HTTPHarness(failure: .cannotConnectToHost)
        defer { http.cleanUp() }
        let state = PetApplicationState()
        let controller = NotesQueryWindowController(state: state,
            assistant: LocalNotesAssistant(state: state, client: try OllamaClient(session: http.session)),
            settings: AssistantSettings())
        defer { controller.close() }
        controller.present()
        try await Task.sleep(for: .milliseconds(220))
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(window.firstResponder as? QuestionTextView)
        editor.insertText("First line\nSecond line\nThird line", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(60))
        let draft = editor.string
        let selection = editor.selectedRange()
        let expandedHeight = window.frame.height
        XCTAssertGreaterThan(expandedHeight, 44)
        XCTAssertLessThanOrEqual(expandedHeight, 70)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            window.appearance = appearance
            try await Task.sleep(for: .milliseconds(30))
            var textLightness: CGFloat = 0
            var caretLightness: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance {
                textLightness = (try? luminance(editor.textColor ?? .clear)) ?? -1
                caretLightness = (try? luminance(editor.insertionPointColor)) ?? -1
            }
            if appearanceName == .aqua {
                XCTAssertLessThan(textLightness, 0.4)
                XCTAssertLessThan(caretLightness, 0.4)
            } else {
                XCTAssertGreaterThan(textLightness, 0.6)
                XCTAssertGreaterThan(caretLightness, 0.6)
            }
            XCTAssertEqual(editor.string, draft)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(window.frame.height, expandedHeight)
        }
    }

    func testReducedMotionDisablesCustomTransitions() {
        XCTAssertEqual(PetMotion.visibilityDuration(showing: true, reducedMotion: true), 0)
        XCTAssertEqual(PetMotion.visibilityDuration(showing: false, reducedMotion: true), 0)
        XCTAssertNil(PetMotion.visibility(showing: true, enabled: false))
        XCTAssertNil(PetMotion.disclosure(reducedMotion: true))
    }

    @MainActor
    func testStreamingReplyStopsMeasuringOnceFullAndRecalculatesReplacements() {
        var measurements = 0
        let layout = PetReplyTextMeasurement { text in
            measurements += 1
            return text.count > 20 ? 200 : 18
        }
        let fullReply = String(repeating: "A long streamed answer. ", count: 30)
        XCTAssertEqual(layout.height(for: fullReply), 156)
        for count in 1...100 {
            XCTAssertEqual(layout.height(for: fullReply + String(repeating: "more ", count: count)), 156)
        }
        XCTAssertEqual(measurements, 1, "Appending to a full reply must not repeat text layout")
        XCTAssertEqual(layout.height(for: "A new reply"), 18)
        XCTAssertEqual(measurements, 2)
        XCTAssertEqual(layout.height(for: "A new reply"), 18)
        XCTAssertEqual(measurements, 2, "Unrelated hover changes must reuse the measurement")
        XCTAssertEqual(layout.height(for: ""), 0)
        XCTAssertEqual(layout.height(for: fullReply), 156)
        XCTAssertEqual(measurements, 3)
    }

    @MainActor
    private func effects(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap { effects(in: $0) }
    }

    @MainActor
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func luminance(_ color: NSColor) throws -> CGFloat {
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
