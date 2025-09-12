import SwiftUI

struct SendXMRSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let xmr = XMRClient()

    @State private var address = ""
    @State private var amountStr = "0.005"
    @State private var fee: Double?
    @State private var txid = ""
    @State private var status = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Monero").font(.title2).bold()

            TextField("Destination address", text: )
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                TextField("Amount (XMR)", text: )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if let f = fee {
                    Text("Fee ≈ \(String(format: "%.8f", f)) XMR")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !txid.isEmpty {
                Text("txid: \(txid)").font(.footnote).textSelection(.enabled)
            }
            if !status.isEmpty {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if let e = error {
                Text(e).foregroundStyle(.red).font(.footnote)
            }

            HStack {
                Button("Estimate") { Task { await doEstimate() } }.disabled(isBusy)
                Button("Send") { Task { await doSend() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || fee == nil)
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    private func amount() -> Double? { Double(amountStr.replacingOccurrences(of: ",", with: ".")) }

    private func doEstimate() async {
        error = nil; fee = nil; status = ""
        guard let amt = amount(), !address.isEmpty else { error = "Enter address and amount"; return }
        isBusy = true; defer { isBusy = false }
        do {
            let r = try await xmr.estimate(address: address, amount: amt)
            fee = r.feeXmr
        } catch { self.error = error.localizedDescription }
    }

    private func doSend() async {
        error = nil; status = ""; txid = ""
        guard let amt = amount(), !address.isEmpty else { error = "Enter address and amount"; return }
        isBusy = true; defer { isBusy = false }
        do {
            let r = try await xmr.transfer(address: address, amount: amt)
            txid = r.txid ?? r.txHash ?? ""
            status = "Broadcasted. Waiting for confirmations…"
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let t = try await xmr.txStatus(txid: txid)
                status = "Confirmations: \(t.confirmations)"
                if t.confirmations >= 1 { break }
            }
        } catch { self.error = error.localizedDescription }
    }
}
