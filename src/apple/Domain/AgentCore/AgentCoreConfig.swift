//
//  AgentCoreConfig.swift
//  Minis
//
//  Configuration and credential state for AgentCore cloud connections.
//

import Foundation

public struct AgentCoreConfig: Codable, Sendable, Equatable {
    public var endpoint: URL?
    public var region: String
    public var gatewayId: String
    public var harnessId: String
    public var defaultActorId: String
    public var isEnabled: Bool
    public var apiKey: String?

    public static let `default` = AgentCoreConfig(
        endpoint: URL(string: "https://opc-copilot-gateway-dd2yv3lwbo.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp"),
        region: "us-west-2",
        gatewayId: "opc-copilot-gateway-dd2yv3lwbo",
        harnessId: "opc_ops_copilot-qD0Xj1JRV6",
        defaultActorId: "founder-general",
        isEnabled: true,
        apiKey: nil
    )

    public init(
        endpoint: URL? = Self.default.endpoint,
        region: String = "us-west-2",
        gatewayId: String = "opc-copilot-gateway-dd2yv3lwbo",
        harnessId: String = "opc_ops_copilot-qD0Xj1JRV6",
        defaultActorId: String = "founder-general",
        isEnabled: Bool = true,
        apiKey: String? = nil
    ) {
        self.endpoint = endpoint
        self.region = region
        self.gatewayId = gatewayId
        self.harnessId = harnessId
        self.defaultActorId = defaultActorId
        self.isEnabled = isEnabled
        self.apiKey = apiKey
    }
}

public final class AgentCoreConfigStore: @unchecked Sendable {
    public static let shared = AgentCoreConfigStore()

    private let key = "minis_agentcore_config"
    private var cachedConfig: AgentCoreConfig

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AgentCoreConfig.self, from: data) {
            self.cachedConfig = decoded
        } else {
            self.cachedConfig = .default
        }
    }

    public var config: AgentCoreConfig {
        get { cachedConfig }
        set {
            cachedConfig = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    public func reset() {
        config = .default
    }
}
