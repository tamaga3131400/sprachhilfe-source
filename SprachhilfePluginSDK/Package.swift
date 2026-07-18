// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SprachhilfePluginSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SprachhilfePluginSDK", type: .dynamic, targets: ["SprachhilfePluginSDK"]),
        .library(name: "SprachhilfePluginSDKTesting", targets: ["SprachhilfePluginSDKTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "2685c640d4079641a01ef3489cacb684c34109fd"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "68947ccdca79bcf7a26dc220f73caa060369513c"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.24.2"),
    ],
    targets: [
        .target(name: "SprachhilfePluginSDK"),
        .target(
            name: "SprachhilfePluginSDKTesting",
            dependencies: ["SprachhilfePluginSDK"]
        ),
        .target(
            name: "OpenAICompatiblePlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/OpenAICompatiblePlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "OpenAIPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/OpenAIPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "OpenRouterPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/OpenRouterPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "Qwen3Plugin",
            dependencies: [
                "SprachhilfePluginSDK",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ],
            path: "Plugins/Qwen3Plugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "ParakeetPlugin",
            dependencies: [
                "SprachhilfePluginSDK",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Plugins/ParakeetPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "FillerWordsPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/FillerWordsPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "FileJobScriptPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/FileJobScriptPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "LinearPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/LinearPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "ObsidianPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/ObsidianPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "SystemTTSPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/SystemTTSPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "SupertonicPlugin",
            dependencies: [
                "SprachhilfePluginSDK",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Plugins/SupertonicPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "FileMemoryPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/FileMemoryPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "LiveTranscriptPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/LiveTranscriptPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "AssemblyAIPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/AssemblyAIPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "Reson8Plugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/Reson8Plugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "SmallestAIPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/SmallestAIPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
                .process("smallest.svg"),
            ]
        ),
        .target(
            name: "WebhookPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/WebhookPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "Neo4jGraphPlugin",
            dependencies: ["SprachhilfePluginSDK"],
            path: "Plugins/Neo4jGraphPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "Gemma4Plugin",
            dependencies: [
                "SprachhilfePluginSDK",
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Plugins/Gemma4Plugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .testTarget(
            name: "SprachhilfePluginSDKTests",
            dependencies: ["SprachhilfePluginSDK"]
        ),
        .testTarget(
            name: "OpenAICompatiblePluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "OpenAICompatiblePlugin",
            ],
            path: "Plugins/OpenAICompatiblePlugin/Tests"
        ),
        .testTarget(
            name: "OpenAIPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "OpenAIPlugin",
            ],
            path: "Plugins/OpenAIPlugin/Tests"
        ),
        .testTarget(
            name: "OpenRouterPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "OpenRouterPlugin",
            ],
            path: "Plugins/OpenRouterPlugin/Tests"
        ),
        .testTarget(
            name: "Qwen3PluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "Qwen3Plugin",
            ],
            path: "Plugins/Qwen3Plugin/Tests"
        ),
        .testTarget(
            name: "ParakeetPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "ParakeetPlugin",
            ],
            path: "Plugins/ParakeetPlugin/Tests"
        ),
        .testTarget(
            name: "SpeechAnalyzerPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
            ],
            path: "Plugins/SpeechAnalyzerPlugin/Tests"
        ),
        .testTarget(
            name: "FillerWordsPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "FillerWordsPlugin",
            ],
            path: "Plugins/FillerWordsPlugin/Tests"
        ),
        .testTarget(
            name: "FileJobScriptPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "FileJobScriptPlugin",
            ],
            path: "Plugins/FileJobScriptPlugin/Tests"
        ),
        .testTarget(
            name: "LinearPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "LinearPlugin",
            ],
            path: "Plugins/LinearPlugin/Tests"
        ),
        .testTarget(
            name: "ObsidianPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "ObsidianPlugin",
            ],
            path: "Plugins/ObsidianPlugin/Tests"
        ),
        .testTarget(
            name: "SystemTTSPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "SystemTTSPlugin",
            ],
            path: "Plugins/SystemTTSPlugin/Tests"
        ),
        .testTarget(
            name: "SupertonicPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "SupertonicPlugin",
            ],
            path: "Plugins/SupertonicPlugin/Tests"
        ),
        .testTarget(
            name: "FileMemoryPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "FileMemoryPlugin",
            ],
            path: "Plugins/FileMemoryPlugin/Tests"
        ),
        .testTarget(
            name: "LiveTranscriptPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "LiveTranscriptPlugin",
            ],
            path: "Plugins/LiveTranscriptPlugin/Tests"
        ),
        .testTarget(
            name: "AssemblyAIPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "AssemblyAIPlugin",
            ],
            path: "Plugins/AssemblyAIPlugin/Tests"
        ),
        .testTarget(
            name: "Reson8PluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "Reson8Plugin",
            ],
            path: "Plugins/Reson8Plugin/Tests"
        ),
        .testTarget(
            name: "SmallestAIPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "SmallestAIPlugin",
            ],
            path: "Plugins/SmallestAIPlugin/Tests"
        ),
        .testTarget(
            name: "WebhookPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "WebhookPlugin",
            ],
            path: "Plugins/WebhookPlugin/Tests"
        ),
        .testTarget(
            name: "Neo4jGraphPluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "Neo4jGraphPlugin",
            ],
            path: "Plugins/Neo4jGraphPlugin/Tests"
        ),
        .testTarget(
            name: "Gemma4PluginTests",
            dependencies: [
                "SprachhilfePluginSDK",
                "SprachhilfePluginSDKTesting",
                "Gemma4Plugin",
            ],
            path: "Plugins/Gemma4Plugin/Tests"
        ),
    ]
)
