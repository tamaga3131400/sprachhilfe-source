import XCTest
import SprachhilfePluginSDK
@testable import Sprachhilfe

final class PluginRegistryServiceTests: XCTestCase {
    private let sdkCompatibilityVersion = "v1"

    func testFlatRegistryEntryWithoutReleasesDoesNotResolve() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.sprachhilfe.legacy",
                  "name": "Legacy Plugin",
                  "version": "1.0.5",
                  "minHostVersion": "1.2.0",
                  "author": "Sprachhilfe",
                  "description": "Legacy flat entry",
                  "category": "utility",
                  "size": 42,
                  "downloadURL": "https://example.com/legacy.zip"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.3",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertTrue(plugins.isEmpty)
    }

    func testMultiReleaseRegistryChoosesNewestCompatibleReleaseWithMatchingSDKCompatibilityVersion() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.multi",
                  "name": "Multi Plugin",
                  "author": "Sprachhilfe",
                  "description": "Multi-release entry",
                  "category": "transcription",
                  "downloadCount": 100,
                  "detailsURL": "https://example.invalid/addons/multi",
                  "homepageURL": "http://example.com/multi",
                  "iconURL": "https://example.invalid/brand-logos/example/logo.svg",
                  "iconDarkURL": "https://example.invalid/brand-logos/example/logo-dark.svg",
                  "releases": [
                    {
                      "version": "1.1.0",
                      "minHostVersion": "1.3.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 20,
                      "downloadURL": "https://example.com/new.zip"
                    },
                    {
                      "version": "1.0.5",
                      "minHostVersion": "1.2.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/compatible.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.4",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.0.5")
        XCTAssertEqual(plugins.first?.downloadURL, "https://example.com/compatible.zip")
        XCTAssertEqual(plugins.first?.downloadCount, 100)
        XCTAssertEqual(plugins.first?.detailsURL, "https://example.invalid/addons/multi")
        XCTAssertEqual(plugins.first?.homepageURL, "http://example.com/multi")
        XCTAssertEqual(plugins.first?.iconURL, "https://example.invalid/brand-logos/example/logo.svg")
        XCTAssertEqual(plugins.first?.iconDarkURL, "https://example.invalid/brand-logos/example/logo-dark.svg")
    }

    func testRegistryPluginIgnoresInvalidOptionalLinkMetadata() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.sprachhilfe.links",
                  "name": "Links Plugin",
                  "author": "Sprachhilfe",
                  "description": "Invalid link metadata should not block the registry.",
                  "category": "utility",
                  "detailsURL": "not a url",
                  "homepageURL": 42,
                  "iconURL": "http://example.com/icon.svg",
                  "iconDarkURL": ["https://example.com/icon-dark.svg"],
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/links.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.4",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertNil(plugins.first?.detailsURL)
        XCTAssertNil(plugins.first?.homepageURL)
        XCTAssertNil(plugins.first?.iconURL)
        XCTAssertNil(plugins.first?.iconDarkURL)
    }

    func testTopLevelReleaseMetadataDoesNotAffectMultiReleaseMatching() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.future",
                  "name": "Future Plugin",
                  "author": "Sprachhilfe",
                  "description": "New releases are gated by host version.",
                  "category": "transcription",
                  "version": "9.9.9",
                  "minHostVersion": "1.0.0",
                  "sdkCompatibilityVersion": "v1",
                  "size": 1,
                  "downloadURL": "https://example.com/stale-top-level.zip",
                  "releases": [
                    {
                      "version": "1.2.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 20,
                      "downloadURL": "https://example.com/requires-1.4.zip"
                    },
                    {
                      "version": "1.1.6",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/compatible-1.3.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let pre14Plugins = response.resolvedPlugins(
            appVersion: "1.3.3",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )
        let plugins14 = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(pre14Plugins.first?.version, "1.1.6")
        XCTAssertEqual(pre14Plugins.first?.downloadURL, "https://example.com/compatible-1.3.zip")
        XCTAssertEqual(plugins14.first?.version, "1.2.0")
        XCTAssertEqual(plugins14.first?.downloadURL, "https://example.com/requires-1.4.zip")
    }

    func testRegistryEntryDecodesMultipleCategoryIdentifiers() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.multi-capability",
                  "name": "Multi Capability Plugin",
                  "author": "Sprachhilfe",
                  "description": "Transcribes and provides LLM processing.",
                  "category": "transcription",
                  "categories": ["transcription", "llm", "memory"],
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/plugin.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.category, "transcription")
        XCTAssertEqual(plugins.first?.categories, ["transcription", "llm", "memory"])
    }

    func testMultiReleaseRegistryRejectsReleaseWithMismatchedSDKCompatibilityVersionAtSameHostVersion() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.multi",
                  "name": "Multi Plugin",
                  "author": "Sprachhilfe",
                  "description": "Multi-release entry",
                  "category": "transcription",
                  "releases": [
                    {
                      "version": "1.0.6",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v2",
                      "size": 12,
                      "downloadURL": "https://example.com/mismatched.zip"
                    },
                    {
                      "version": "1.0.5",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/matching.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.2",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.0.5")
        XCTAssertEqual(plugins.first?.downloadURL, "https://example.com/matching.zip")
    }

    func testMultiReleaseRegistryFiltersIncompatibleReleasesByArchitectureAndOS() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.arch",
                  "name": "Architecture Plugin",
                  "author": "Sprachhilfe",
                  "description": "Architecture-sensitive entry",
                  "category": "transcription",
                  "releases": [
                    {
                      "version": "1.2.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "minOSVersion": "15.0",
                      "supportedArchitectures": ["arm64"],
                      "size": 20,
                      "downloadURL": "https://example.com/arm64-new.zip"
                    },
                    {
                      "version": "1.1.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "minOSVersion": "14.0",
                      "supportedArchitectures": ["x86_64"],
                      "size": 10,
                      "downloadURL": "https://example.com/intel-compatible.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let osVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.4",
            sdkCompatibilityVersion: sdkCompatibilityVersion,
            currentOSVersion: osVersion,
            architecture: "x86_64"
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.1.0")
        XCTAssertEqual(plugins.first?.downloadURL, "https://example.com/intel-compatible.zip")
    }

    func testRegistryEntryWithCloudHostingOverridesAPIKeyRequirementForClassification() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.openai",
                  "name": "OpenAI / ChatGPT",
                  "author": "Sprachhilfe",
                  "description": "Cloud transcription plus OpenAI/ChatGPT prompts.",
                  "category": "transcription",
                  "hosting": "cloud",
                  "requiresAPIKey": false,
                  "releases": [
                    {
                      "version": "1.1.5",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v1",
                      "size": 20,
                      "downloadURL": "https://example.com/openai.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugin = try XCTUnwrap(response.resolvedPlugins(
            appVersion: "1.3.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        ).first)

        XCTAssertEqual(plugin.hosting, .cloud)
        XCTAssertEqual(plugin.requiresAPIKey, false)
        XCTAssertEqual(plugin.resolvedHosting, .cloud)
    }

    func testRegistryEntryWithoutHostingFallsBackToAPIKeyRequirementForClassification() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.sprachhilfe.remote",
                  "name": "Remote Plugin",
                  "author": "Sprachhilfe",
                  "description": "Remote entry",
                  "category": "transcription",
                  "requiresAPIKey": true,
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/remote.zip"
                    }
                  ]
                },
                {
                  "id": "com.sprachhilfe.local",
                  "name": "Local Plugin",
                  "author": "Sprachhilfe",
                  "description": "Local entry",
                  "category": "transcription",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/local.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.3.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        let remote = try XCTUnwrap(plugins.first { $0.id == "com.sprachhilfe.remote" })
        let local = try XCTUnwrap(plugins.first { $0.id == "com.sprachhilfe.local" })
        XCTAssertNil(remote.hosting)
        XCTAssertEqual(remote.resolvedHosting, .cloud)
        XCTAssertNil(local.hosting)
        XCTAssertEqual(local.resolvedHosting, .local)
    }

    @MainActor
    func testDownloadAndInstallReportsFailureForIncompatiblePlugin() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            fetchData: { _ in
                throw URLError(.badServerResponse)
            }
        )
        let plugin = RegistryPlugin(
            id: "com.sprachhilfe.incompatible",
            source: .official,
            name: "Incompatible Plugin",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion,
            minOSVersion: "99.0",
            supportedArchitectures: nil,
            author: "Sprachhilfe",
            description: "Requires a future macOS version.",
            category: "utility",
            categories: ["utility"],
            size: 10,
            downloadURL: "https://example.com/plugin.zip",
            iconSystemName: nil,
            requiresAPIKey: nil,
            hosting: nil,
            descriptions: nil,
            downloadCount: nil
        )

        let installed = await service.downloadAndInstall(plugin)

        XCTAssertFalse(installed)
        XCTAssertEqual(
            service.installStates[plugin.id],
            .error("Plugin is not compatible with this Mac")
        )
    }

    func testMalformedPluginEntryIsSkippedInsteadOfFailingEntireRegistry() throws {
        // A single bad entry (wrong type on a required field) must not empty
        // the marketplace: the decoder reports the error and keeps the rest.
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": 42,
                  "name": "Malformed plugin id",
                  "author": "Test",
                  "description": "Bad entry",
                  "category": "utility",
                  "releases": []
                },
                {
                  "id": "com.sprachhilfe.ok",
                  "name": "Good Plugin",
                  "author": "Sprachhilfe",
                  "description": "Entry without releases",
                  "category": "utility",
                  "size": 10
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.3",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(response.plugins.count, 1)
        XCTAssertTrue(plugins.isEmpty)
    }

    func testRegistryFeedUsesV1ForPre14Builds() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(appVersion: "1.2.2"),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(appVersion: "1.3.1"),
            .v1
        )
    }

    func testRegistryFeedUsesCommunityFeedFor14PreviewAndStableBuilds() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(appVersion: "1.4.0-rc1"),
            .communityV1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(appVersion: "1.4.0"),
            .communityV1
        )
    }

    func testRegistryPluginSourceDefaultsToOfficialAndDecodesCommunity() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.sprachhilfe.official",
                  "name": "Official Plugin",
                  "author": "Sprachhilfe",
                  "description": "Official entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/official.zip"
                    }
                  ]
                },
                {
                  "id": "com.community.volcengine",
                  "source": "community",
                  "name": "Community Plugin",
                  "author": "Community Author",
                  "description": "Community entry",
                  "category": "llm",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 12,
                      "downloadURL": "https://github.com/tamaga3131400/sprachhilfe-dist/releases/download/plugin-community-v1.0.0/CommunityPlugin.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.map(\.source), [.official, .community])
    }

    func testCommunityPluginWithExternalDownloadURLDoesNotResolve() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.community.external",
                  "source": "community",
                  "name": "External Community Plugin",
                  "author": "Community Author",
                  "description": "Community entry with an external ZIP.",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 12,
                      "downloadURL": "https://github.com/contributor/plugin/releases/download/v1.0.0/Plugin.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertTrue(plugins.isEmpty)
    }

    func testCommunityPluginSourceMetadataWithoutReleasesDoesNotResolve() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.community.source-only",
                  "source": "community",
                  "name": "Source Only Community Plugin",
                  "author": "Community Author",
                  "description": "Reviewed source without a published artifact.",
                  "category": "utility"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertTrue(plugins.isEmpty)
    }

    @MainActor
    func testFetchRegistryUsesVersionSpecificFeedAndWritesLastKnownGoodCache() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryCache")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        let payload = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.sprachhilfe.cached",
                  "name": "Cached Plugin",
                  "author": "Sprachhilfe",
                  "description": "Cacheable entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.3.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/cached.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        var requestedURL: URL?
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.3.0"
            ],
            fetchData: { request in
                requestedURL = request.url
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (payload, response)
            }
        )

        await service.fetchRegistry(force: true)

        XCTAssertEqual(requestedURL?.absoluteString, "https://example.com/plugins-v1.json")
        XCTAssertEqual(service.fetchState, .loaded)
        XCTAssertEqual(service.registry.map(\.id), ["com.sprachhilfe.cached"])

        let cachedData = try Data(contentsOf: cacheDirectory.appendingPathComponent("plugins-v1.json"))
        let cachedResponse = try JSONDecoder().decode(PluginRegistryResponse.self, from: cachedData)
        XCTAssertEqual(cachedResponse.plugins.map(\.id), ["com.sprachhilfe.cached"])
    }

    @MainActor
    func testFetchRegistryFallsBackToLastKnownGoodCacheWhenRemoteFetchFails() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryCache")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        let payload = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.sprachhilfe.cached",
                  "name": "Cached Plugin",
                  "author": "Sprachhilfe",
                  "description": "Cacheable entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.3.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/cached.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        try payload.write(to: cacheDirectory.appendingPathComponent("plugins-v1.json"))

        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.3.0"
            ],
            fetchData: { _ in
                throw URLError(.notConnectedToInternet)
            }
        )

        await service.fetchRegistry(force: true)

        XCTAssertEqual(service.fetchState, .loaded)
        XCTAssertEqual(service.registry.map(\.id), ["com.sprachhilfe.cached"])
    }

    @MainActor
    func testHostFingerprintChangeForcesRegistryRefreshInsideThrottleWindow() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryFingerprint")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        var requestCount = 0
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.4.0"
            ],
            fetchData: { request in
                requestCount += 1
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Self.registryPayload(pluginId: "com.sprachhilfe.fingerprint"), response)
            }
        )
        let now = Date(timeIntervalSince1970: 2_000)

        let initialFetch = await service.refreshRegistryForHostUpdateIfNeeded(currentFingerprint: "1.4.0+803@stable", now: now)
        let throttledFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(60)
        )
        let fingerprintFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.1+804@stable",
            now: now.addingTimeInterval(120)
        )

        XCTAssertTrue(initialFetch)
        XCTAssertFalse(throttledFetch)
        XCTAssertTrue(fingerprintFetch)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testUnchangedHostFingerprintPreservesBackgroundUpdateThrottle() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryFingerprintThrottle")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        var requestCount = 0
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.4.0"
            ],
            fetchData: { request in
                requestCount += 1
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Self.registryPayload(pluginId: "com.sprachhilfe.throttle"), response)
            }
        )
        let now = Date(timeIntervalSince1970: 3_000)

        let initialFetch = await service.refreshRegistryForHostUpdateIfNeeded(currentFingerprint: "1.4.0+803@stable", now: now)
        let throttledFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(23 * 3600)
        )
        let expiredFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(25 * 3600)
        )

        XCTAssertTrue(initialFetch)
        XCTAssertFalse(throttledFetch)
        XCTAssertTrue(expiredFetch)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testHostFingerprintRefreshDoesNotAdvanceThrottleWhenOnlyCacheFallbackLoads() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryFingerprintCacheFallback")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        try Self.registryPayload(pluginId: "com.sprachhilfe.cached-fallback")
            .write(to: cacheDirectory.appendingPathComponent("plugins-community-v1.json"))

        var requestCount = 0
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.4.0"
            ],
            fetchData: { _ in
                requestCount += 1
                throw URLError(.notConnectedToInternet)
            }
        )
        let now = Date(timeIntervalSince1970: 4_000)

        let fallbackFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now
        )
        let retryFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(60)
        )

        XCTAssertFalse(fallbackFetch)
        XCTAssertFalse(retryFetch)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(service.fetchState, .loaded)
        XCTAssertEqual(service.registry.map(\.id), ["com.sprachhilfe.cached-fallback"])
    }

    private static func registryPayload(pluginId: String) -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "\(pluginId)",
                  "name": "Cached Plugin",
                  "author": "Sprachhilfe",
                  "description": "Cacheable entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/cached.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
    }
}
