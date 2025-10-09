//
// SendXMRSheet.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SendXMRSheet: View {
    // Optional defaults coming from ContentView’s detector
    let addressDefault: String?
    let amountDefault: Double?

    // If you want to pass a custom bridge base, change here or make it configurable
    private let bridgeBase = URL(string: "http://127.0.0.1:8787")!

    // UI state
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var amountText: String = ""
    @State private var note: String = ""

    @State private var isEstimating = false
    @State private var isSending = false

    @State private var feeXMR: Double? = nil
    @State private var txid: String? = nil
    @State private var errorMessage: String? = nil
    @State private var confirmations: Int? = nil
    @State private var inPool: Bool? = nil

    // Synthesized init so calls without args still compile
    init(addressDefault: String? = nil, amountDefault: Double? = nil) {
        self.addressDefault = addressDefault
        self.amountDefault = amountDefault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Send XMR (stagenet)")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Group {
                TextField("Recipient subaddress", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 8) {
                    TextField("Amount (XMR)", text: $amountText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: amountText) { _ in feeXMR = nil } // reset estimate on change

                    if let fee = feeXMR {
                        Text(String(format: "fee ≈ %.8f XMR", fee))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Note (optional, for proof message)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let txid {
                VStack(alignment: .leading, spacing: 4) {
                    Text("txid:")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(txid)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)

                    if let confs = confirmations {
                        Text("confirmations: \(confs)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(confs >= 10 ? .green : .secondary)
                    }
                    if let pool = inPool {
                        Text(pool ? "in mempool" : "confirmed on chain")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(pool ? .orange : .green)
                    }
                }
                .padding(.top, 4)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    Task { await estimate() }
                } label: {
                    if isEstimating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Estimate Fee")
                    }
                }
                .disabled(!canEstimate || isEstimating || isSending)
                .buttonStyle(.bordered)

                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .disabled(!canSend || isSending)

                Spacer()
                if txid != nil {
                    Button("Check Status") {
                        Task { await refreshTxStatus() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(minWidth: 520)
        .onAppear {
            // Prefill defaults once
            if address.isEmpty, let a = addressDefault { address = a }
            if amountText.isEmpty, let amt = amountDefault {
                amountText = String(format: "%.12g", amt)
            }
        }
    }

    // MARK: - Validation

    private var parsedAmount: Double? {
        // Accept commas or spaces, normalize
        let normalized = amountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private var canEstimate: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && (parsedAmount ?? 0) > 0
    }

    private var canSend: Bool {
        canEstimate && feeXMR != nil // require an estimate first (your UX choice)
    }

    // MARK: - Networking

    private func estimate() async {
        errorMessage = nil
        feeXMR = nil
        confirmations = nil
        inPool = nil
        isEstimating = true
        defer { isEstimating = false }

        guard let amount = parsedAmount else {
            errorMessage = "Enter a valid amount."
            return
        }

        do {
            let url = bridgeBase.appendingPathComponent("estimate")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "address": address,
                "amount": amount
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

            let (data, resp) = try await URLSession.shared.data(for: req)
            try ensureOK(resp)

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fee = json["fee_xmr"] as? Double {
                feeXMR = fee
            } else {
                throw SimpleError("Unexpected estimate response.")
            }
        } catch {
            errorMessage = "Estimate failed: \(error.localizedDescription)"
        }
    }

    private func send() async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }

        guard let amount = parsedAmount else {
            errorMessage = "Enter a valid amount."
            return
        }

        do {
            let url = bridgeBase.appendingPathComponent("transfer")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "address": address,
                "amount": amount,
                "description": note
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

            let (data, resp) = try await URLSession.shared.data(for: req)
            try ensureOK(resp)

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Bridge might return txid or tx_hash
                let id = (json["txid"] as? String) ?? (json["tx_hash"] as? String)
                guard let id else { throw SimpleError("No txid in response.") }
                txid = id
                feeXMR = json["fee_xmr"] as? Double ?? feeXMR

                // Immediately get status once
                await refreshTxStatus()
            } else {
                throw SimpleError("Unexpected transfer response.")
            }
        } catch {
            errorMessage = "Send failed: \(error.localizedDescription)"
        }
    }

    private func refreshTxStatus() async {
        guard let id = txid else { return }
        errorMessage = nil
        confirmations = nil
        inPool = nil

        do {
            let url = bridgeBase.appendingPathComponent("tx/\(id)")
            let (data, resp) = try await URLSession.shared.data(from: url)
            try ensureOK(resp)

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                confirmations = json["confirmations"] as? Int
                inPool = json["in_pool"] as? Bool
            } else {
                throw SimpleError("Unexpected tx response.")
            }
        } catch {
            errorMessage = "Status check failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SimpleError("HTTP \(code)")
        }
    }

    private struct SimpleError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
