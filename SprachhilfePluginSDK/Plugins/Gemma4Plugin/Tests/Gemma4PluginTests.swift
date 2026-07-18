import Foundation
import XCTest
import SprachhilfePluginSDK
@_spi(Testing) import SprachhilfePluginSDKTesting
@testable import Gemma4Plugin

final class Gemma4PluginTests: XCTestCase {
    func testPersistedDynamicModelSelectionSurvivesActivationAndExplicitSelection() throws {
        let repoId = "mlx-community/gemma-4-unified-it-4bit"
        let modelId = Gemma4Plugin.userModelId(for: repoId)
        let host = try PluginTestHostServices(defaults: [
            "userModels": try userModelsJSON(repoId: repoId, displayName: "Gemma 4 Unified"),
            "selectedLLMModel": modelId,
        ])
        let plugin = Gemma4Plugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertEqual(plugin.selectedLLMModelId, modelId)
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, modelId)

        plugin.selectLLMModel(modelId)
        XCTAssertEqual(plugin.selectedLLMModelId, modelId)
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, modelId)

        let reloaded = Gemma4Plugin()
        reloaded.activate(host: host)
        defer { reloaded.deactivate() }

        XCTAssertEqual(reloaded.selectedLLMModelId, modelId)
    }

    func testSupportedModelsReportsLoadedDynamicUserModel() throws {
        let repoId = "mlx-community/gemma-4-unified-it-4bit"
        let modelId = Gemma4Plugin.userModelId(for: repoId)
        let host = try PluginTestHostServices()
        let plugin = Gemma4Plugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertTrue(plugin.addUserModel(repoId: repoId, displayName: "Gemma 4 Unified"))
        plugin.loadedModelId = modelId

        XCTAssertEqual(plugin.supportedModels.map(\.id), [modelId])
        XCTAssertEqual(plugin.supportedModels.map(\.displayName), ["Gemma 4 Unified"])
    }

    func testRemovingSelectedDynamicModelFallsBackAndNotifiesCapabilities() throws {
        let repoId = "mlx-community/gemma-4-unified-it-4bit"
        let modelId = Gemma4Plugin.userModelId(for: repoId)
        let fallbackId = try XCTUnwrap(Gemma4Plugin.supportedModelDefinitions.first?.id)
        let host = try PluginTestHostServices()
        let plugin = Gemma4Plugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertTrue(plugin.addUserModel(repoId: repoId, displayName: "Gemma 4 Unified"))
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.selectLLMModel(modelId)
        plugin.removeUserModel(repoId: repoId)

        XCTAssertNil(plugin.resolveModelDef(for: modelId))
        XCTAssertEqual(plugin.selectedLLMModelId, fallbackId)
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, fallbackId)
        XCTAssertEqual(host.capabilitiesChangedCount, 2)
    }

    func testUnknownModelSelectionFallsBackToSupportedDefault() throws {
        let fallbackId = try XCTUnwrap(Gemma4Plugin.supportedModelDefinitions.first?.id)
        let host = try PluginTestHostServices()
        let plugin = Gemma4Plugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.selectLLMModel("user-missing-model")

        XCTAssertEqual(plugin.selectedLLMModelId, fallbackId)
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, fallbackId)
    }

    private func userModelsJSON(repoId: String, displayName: String) throws -> String {
        let data = try JSONEncoder().encode([
            Gemma4Plugin.Gemma4UserModel(repoId: repoId, displayName: displayName),
        ])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
