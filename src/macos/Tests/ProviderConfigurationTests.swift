import Foundation
import MinisProviderDomain
import Testing

@Suite("Provider configuration compatibility")
struct ProviderConfigurationTests {
    @Test("legacy records default to API-key authentication")
    func legacyCredentialDefault() throws {
        let data = Data(#"{"id":"legacy","displayName":"Legacy","endpoint":"https:\/\/example.com\/v1\/chat\/completions","model":"legacy-model","additionalHeaders":{},"providerType":"openAI"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)

        #expect(decoded.credentialType == .apiKey)
        #expect(decoded.model.id == "legacy-model")
    }

    @Test("OAuth authentication round-trips without a secret")
    func oauthRoundTrip() throws {
        let value = ProviderConfiguration(
            id: "oauth-provider",
            displayName: "OAuth Provider",
            endpoint: URL(string: "https://example.com/messages")!,
            model: ProviderModel(id: "model"),
            providerType: .anthropic,
            credentialType: .oauth
        )

        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(object["credentialType"] as? String == "oauth")
        #expect(object["secret"] == nil)
        #expect(object["apiKey"] == nil)
    }
}
