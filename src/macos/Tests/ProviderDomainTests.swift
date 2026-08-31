import XCTest
import MinisProviderDomain

final class ProviderDomainTests: XCTestCase {
    func testDecodesLegacyStringModelConfiguration() throws {
        let data = Data(#"""
        {
          "id": "legacy",
          "displayName": "Legacy endpoint",
          "endpoint": "https://example.test/v1/chat/completions",
          "model": "legacy-model",
          "additionalHeaders": { "X-Test": "1" }
        }
        """#.utf8)

        let configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        XCTAssertEqual(configuration.id, "legacy")
        XCTAssertEqual(configuration.model, ProviderModel(id: "legacy-model"))
        XCTAssertEqual(configuration.providerType, .openAI)
        XCTAssertNil(configuration.unknownProviderTypeRaw)
    }

    func testUnknownProviderTypeRoundTripsWithoutDataLoss() throws {
        let data = Data(#"""
        {
          "id": "future",
          "displayName": "Future provider",
          "endpoint": "https://example.test/chat",
          "model": { "id": "future-model", "displayName": "Future Model", "provider": "Future" },
          "additionalHeaders": {},
          "providerType": "futureProtocolV9"
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        XCTAssertEqual(decoded.providerType, .unsupported)
        XCTAssertEqual(decoded.unknownProviderTypeRaw, "futureProtocolV9")
        XCTAssertEqual(decoded.model.displayName, "Future Model")

        let reencoded = try JSONEncoder().encode(decoded)
        let value = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertEqual(value?["providerType"] as? String, "futureProtocolV9")
    }

    func testAdditiveFieldsAndFutureKeysRemainDecodable() throws {
        let data = Data(#"""
        {
          "endpoint": "https://example.test/chat",
          "model": { "id": "compact-model", "futureModelField": true },
          "futureConfigurationField": { "ignored": true }
        }
        """#.utf8)

        let configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        XCTAssertEqual(configuration.id, "default")
        XCTAssertEqual(configuration.model.id, "compact-model")
        XCTAssertEqual(configuration.additionalHeaders, [:])
    }
}
