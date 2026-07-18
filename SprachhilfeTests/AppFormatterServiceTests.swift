import XCTest
@testable import Sprachhilfe

final class AppFormatterServiceTests: XCTestCase {
    @MainActor
    func testMarkdownFormattingNormalizesBullets() {
        let service = AppFormatterService()

        let output = service.format(
            text: "bullet first item\n* second item",
            bundleId: "md.obsidian",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "- first item\n- second item")
    }

    @MainActor
    func testHTMLFormattingEscapesMarkup() {
        let service = AppFormatterService()

        let output = service.format(
            text: "hello <team>\n- launch",
            bundleId: "com.apple.mail",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "<p>hello &lt;team&gt;</p>\n<ul>\n<li>launch</li>\n</ul>")
    }

    @MainActor
    func testRTFFormattingLeavesMarkdownTextForClipboardConversion() {
        let service = AppFormatterService()

        let output = service.format(
            text: "**Launch**\n- Budget",
            bundleId: "com.apple.mail",
            outputFormat: "rtf"
        )

        XCTAssertEqual(output, "**Launch**\n- Budget")
    }

    @MainActor
    func testRegisterDefaultUserDefaultsIncludesAppFormattingFlag() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        AppDelegate.registerDefaultUserDefaults(defaults)

        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.appFormattingEnabled) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) as? Bool, true)
    }
}
