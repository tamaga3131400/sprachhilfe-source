import Foundation

enum AppConstants {
    nonisolated(unsafe) static var testAppSupportDirectoryOverride: URL?

    static let appSupportDirectoryName: String = {
        #if DEBUG
        return "Sprachhilfe-Dev"
        #else
        return "Sprachhilfe"
        #endif
    }()

    static let keychainServicePrefix: String = {
        #if DEBUG
        return "com.sprachhilfe.mac.dev.apikey."
        #else
        return "com.sprachhilfe.mac.apikey."
        #endif
    }()

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.sprachhilfe.mac"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        return defaultAppSupportDirectory
    }

    static let defaultAppSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }()

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    static let currentReleaseFingerprint: String = "\(appVersion)+\(buildVersion)"

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["SPRACHHILFE_RUNNING_TESTS"] == "1" ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") } ||
            Bundle.allFrameworks.contains { $0.bundleIdentifier == "com.apple.dt.XCTest" }
    }

    static let isDevelopment: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

}
