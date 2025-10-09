import Foundation
#if canImport(Combine)
import Combine
#endif

// Basic config
enum XMRConfig {
    static let baseURL = URL(string: "http://127.0.0.1:8787")! // your bridge
    static let apiKey: String? = nil // set if you enabled XMR_BRIDGE_KEY
}

// Generic client
final class XMRClient {
    private let session: URLSession = .shared

    private func makeRequest(path: String, method: String = "GET", json: Any? = nil) throws -> URLRequest {
        var req = URLRequest(url: XMRConfig.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = XMRConfig.apiKey { req.setValue(k, forHTTPHeaderField: "x-api-key") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
        }
        return req
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    // MARK: DTOs
    struct Health: Decodable { let ok: Bool; let version: Int?; let release: Bool? }
    struct AddressResp: Decodable { let ok: Bool?; let address: String; let addressIndex: Int?; let accountIndex: Int? }
    struct EstimateResp: Decodable { let feeXmr: Double; let txMetadata: String }
    struct TransferResp: Decodable { let ok: Bool?; let txid: String?; let txHash: String?; let feeXmr: Double? }
    struct TxResp: Decodable { let ok: Bool?; let txid: String; let inPool: Bool; let confirmations: Int; let amountXmr: Double; let feeXmr: Double?; let timestamp: TimeInterval? }
    struct ProofResp: Decodable { let ok: Bool?; let txid: String; let address: String; let message: String?; let signature: String }
    struct VerifyResp: Decodable { let ok: Bool?; let good: Bool; let inPool: Bool; let receivedXmr: Double }

    // MARK: Calls
    func health() async throws -> Health {
        let req = try makeRequest(path: "health")
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }

    func createAddress(label: String) async throws -> AddressResp {
        let req = try makeRequest(path: "address", method: "POST", json: ["label": label])
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }

    func estimate(address: String, amount: Double) async throws -> EstimateResp {
        let req = try makeRequest(path: "estimate", method: "POST", json: ["address": address, "amount": amount])
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }

    func transfer(address: String, amount: Double) async throws -> TransferResp {
        let req = try makeRequest(path: "transfer", method: "POST", json: ["address": address, "amount": amount])
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }

    func txStatus(txid: String) async throws -> TxResp {
        let req = try makeRequest(path: "tx/\(txid)")
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }

    func createProof(txid: String, address: String, message: String?) async throws -> ProofResp {
        var body: [String: Any] = ["txid": txid, "address": address]
        if let m = message { body["message"] = m }
        let req = try makeRequest(path: "proof", method: "POST", json: body)
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }

    func verifyProof(txid: String, address: String, message: String?, signature: String) async throws -> VerifyResp {
        let req = try makeRequest(path: "verify", method: "POST",
                                  json: ["txid": txid, "address": address, "message": message ?? "", "signature": signature])
        let (d, _) = try await session.data(for: req)
        return try decode(d)
    }
}
