import XCTest
@testable import KaddoCanvas

final class ApplicationContextMapperTests: XCTestCase {
    func testNormalizesExactBundleIdentifiersAndRejectsLookalikes() {
        let mapper = ApplicationContextMapper()
        for identifier in ["com.microsoft.VSCode", " COM.MICROSOFT.vscode\n",
                           "com.apple.dt.Xcode", "com.jetbrains.intellij"] {
            XCTAssertEqual(mapper.category(for: identifier), .coding, identifier)
        }
        for identifier in ["com.hnc.Discord", " com.tinyspeck.slackmacgap "] {
            XCTAssertEqual(mapper.category(for: identifier), .communication, identifier)
        }
        for identifier in [nil, "", " \n", "com.apple.Safari", "com.microsoft.VSCode.fake",
                           "evil.com.apple.dt.Xcode", "com.apple.dt. Xcode"] {
            XCTAssertEqual(mapper.category(for: identifier), .general, identifier ?? "nil")
        }
    }

    func testConfigurationIsNormalizedAndCodingHasDeterministicPrecedence() {
        let mapper = ApplicationContextMapper(
            codingBundleIdentifiers: [" ORG.EXAMPLE.Editor ", " "],
            communicationBundleIdentifiers: ["org.example.editor", "org.example.chat"]
        )
        XCTAssertEqual(mapper.category(for: "org.example.editor"), .coding)
        XCTAssertEqual(mapper.category(for: "ORG.EXAMPLE.CHAT"), .communication)
        XCTAssertEqual(mapper.category(for: "com.apple.dt.Xcode"), .general)
        XCTAssertEqual(mapper.category(for: ""), .general)
    }
}
