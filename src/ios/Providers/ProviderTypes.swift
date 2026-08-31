import Foundation

// MARK: - iOS Provider Presentation

/// UI/catalog behavior layered on the shared Foundation-only provider identity.
extension ProviderType {

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openAI: return "OpenAI"
        case .antigravity: return "Antigravity"
        case .openRouter: return "OpenRouter"
        case .openAIResponses: return "Responses API (v3)"
        case .xAI: return "xAI (Grok)"
        case .kimiCode: return "Kimi Code"
        case .unsupported: return "Unsupported"
        }
    }

    /// Built-in models for this provider type.
    var builtInModels: [LLMModel] {
        switch self {
        case .anthropic: return LLMModel.allAnthropic
        case .gemini: return LLMModel.allGemini
        case .openAI: return LLMModel.allOpenAI
        case .antigravity: return LLMModel.allAntigravity
        case .openRouter: return LLMModel.allOpenRouter
        case .openAIResponses: return LLMModel.allOpenAI
        case .xAI: return XAIModelsAPI.allModels
        case .kimiCode: return KimiModelsAPI.allModels
        case .unsupported: return []
        }
    }

    /// Short description shown under the provider name in the Add Provider
    /// picker — what kinds of services this protocol supports, rather than a
    /// raw built-in model count. Localized; English key, translations in
    /// Localizable.xcstrings.
    var pickerSubtitle: String {
        switch self {
        case .openAI, .openAIResponses:
            return String(localized: "Works with Codex, DeepSeek, Moonshot, Groq and other compatible vendors")
        case .anthropic:
            return String(localized: "Works with Claude and Anthropic-protocol-compatible services")
        case .gemini:
            return String(localized: "Works with the Gemini series and Google AI Studio")
        case .openRouter:
            return String(localized: "Aggregates GPT, Claude, Gemini, Llama and other mainstream models")
        case .xAI:
            return String(localized: "Works with the Grok series of models")
        case .kimiCode:
            return String(localized: "Sign in with your Kimi Code / Coding Plan subscription")
        case .antigravity:
            return String(localized: "\(builtInModels.count) built-in models")
        case .unsupported:
            return String(localized: "\(builtInModels.count) built-in models")
        }
    }

    /// Default modality assumed for custom models added to this provider.
    var defaultModality: ModelModality {
        switch self {
        case .anthropic: return .vision
        case .gemini:    return .fullMultimodal
        case .openAI:    return .vision
        case .antigravity: return .fullMultimodal
        case .openRouter: return .vision
        case .openAIResponses: return .vision
        case .xAI: return .vision
        case .kimiCode: return .vision
        case .unsupported: return .vision
        }
    }

    /// True when this build can't actually use the provider (synced from a newer app).
    var isUnsupported: Bool { self == .unsupported }
}
