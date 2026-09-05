// swift-tools-version: 6.2

import PackageDescription

// The macOS work starts as a standalone package so it can compile and test
// independently while the existing iOS Xcode target remains untouched. The
// domain files below are the same source files compiled by the iOS target.
let package = Package(
    name: "MinisDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MinisDesktopCore", targets: ["MinisDesktopCore"])
    ],
    targets: [
        .target(
            name: "MinisAgentContracts",
            path: "src/ios/AgentKit/Runtime",
            exclude: ["IOSAgentSessionRunner.swift"],
            sources: ["AgentSessionRunner.swift"]
        ),
        .target(
            name: "MinisProviderDomain",
            path: "src/ios/Providers",
            exclude: [
                "AgentProvider.swift",
                "Anthropic",
                "Antigravity",
                "Gemini",
                "Kimi",
                "LLMError.swift",
                "LLMProvider.swift",
                "LLMProviderFactory.swift",
                "LLMTypes.swift",
                "ModelEntry.swift",
                "ModelGroup.swift",
                "ModelGroupRouter.swift",
                "ModelsDevAPI.swift",
                "OAuthRefreshCoordinator.swift",
                "OAuthRefreshSingleFlight.swift",
                "OpenAI",
                "OpenRouter",
                "ProviderConfigDB.swift",
                "ProviderConfigStore.swift",
                "ProviderInstance.swift",
                "ProviderMigration.swift",
                "ProviderTypes.swift",
                "ThinkingLevelCatalog.swift",
                "URLBuilding.swift",
                "Voice",
                "xAI"
            ],
            sources: ["ProviderDomain.swift"]
        ),
        .target(
            name: "MinisAppleDomain",
            path: "src/apple/Domain",
            sources: [
                "Hooks/HookTypes.swift",
                "Hooks/HookEngine.swift",
                "AgentCore/AgentCoreModels.swift",
                "AgentCore/AgentCoreConfig.swift",
                "AgentProfile.swift",
                "AgentRunEngine.swift",
                "ChatPersistence.swift",
                "SyncV2Contracts.swift",
                "GroupProfile.swift",
                "GroupMentionRouter.swift",
                "GroupChatPrompt.swift",
                "GroupChatEngine.swift"
            ]
        ),
        .target(
            name: "MinisPOSIX",
            path: "src/macos/POSIX",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MinisDesktopCore",
            dependencies: ["MinisPOSIX", "MinisAgentContracts", "MinisProviderDomain", "MinisAppleDomain"],
            path: "src/macos/Core",
            sources: [
                "DomainExports.swift",
                "RuntimeModels.swift",
                "RuntimeProtocol.swift",
                "WorkspaceRegistry.swift",
                "DesktopStore.swift",
                "LegacyChatStoreImporter.swift",
                "CredentialStore.swift",
                "KimiOAuth.swift",
                "ProviderRunner.swift",
                "DesktopSyncCoordinator.swift",
                "MacCloudKitSyncTransport.swift",
                "DesktopContextAssembler.swift",
                "RuntimeToolLoop.swift",
                "NativeToolContracts.swift",
                "RuntimeClientAgentSessionRunner.swift",
                "MacCommandExecutionBackend.swift",
                "AgentRuntime.swift",
                "RuntimeClient.swift",
                "MacTerminalBackend.swift",
                "TerminalScreen.swift"
            ],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security"), .linkedFramework("CloudKit")]
        ),
        .testTarget(
            name: "MinisDesktopCoreTests",
            dependencies: ["MinisDesktopCore", "MinisProviderDomain", "MinisAppleDomain"],
            path: "src/macos/Tests",
            exclude: [
                // These exercise App-only OAuth/UI helpers through the Xcode
                // `MinisMac` module; this package exposes only DesktopCore.
                "FileContextFormatterTests.swift",
                "OpenRouterOAuthTests.swift"
            ]
        )
    ]
)
