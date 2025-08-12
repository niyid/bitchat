import Foundation

public struct XMRIntent {
    public let address: String
    public let amount: Double?
}

private let addrRegex: NSRegularExpression = {
    // 95-char (primary) or 106-char (subaddress)
    // Prefixes:
    //  - mainnet: '4' (primary), '8' (subaddress)
    //  - stagenet/testnet: '5' (primary), '7' (subaddress)
    let pattern = #"(?:(?:[4|5])[0-9A-Za-z]{94}|(?:[7|8])[0-9A-Za-z]{105})"#
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

public func isXMRAddress(_ s: String) -> Bool {
    let len = s.count
    guard (len == 95 || len == 106) else { return false }
    let r = NSRange(location: 0, length: s.utf16.count)
    return addrRegex.firstMatch(in: s, options: [], range: r) != nil
}

private func findNearbyAmount(in s: String) -> Double? {
    // Matches: 0.01, 0,01, "0.01 XMR", "amount=0.01"
    let rx = try! NSRegularExpression(pattern: #"(?:^|[^\d])(\d+(?:[.,]\d+)?)(?:\s*)(?:xmr|XMR)?\b"#)
    let r = NSRange(location: 0, length: s.utf16.count)
    if let m = rx.firstMatch(in: s, options: [], range: r), m.numberOfRanges >= 2,
       let rr = Range(m.range(at: 1), in: s) {
        let raw = String(s[rr]).replacingOccurrences(of: ",", with: ".")
        return Double(raw)
    }
    return nil
}

public func parseXMRIntent(_ text: String) -> XMRIntent? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // 1) monero: URI
    if s.lowercased().hasPrefix("monero:"),
       let url = URL(string: s) {
        // Address can be host or path depending on the URI form
        let addrCandidate = (url.host?.isEmpty == false) ? url.host! : url.path.replacingOccurrences(of: "/", with: "")
        guard isXMRAddress(addrCandidate) else { return nil }

        var amount: Double? = nil
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let qs = comps.queryItems {
            if let a = qs.first(where: { .name.lowercased() == "tx_amount" || .name.lowercased() == "amount" })?.value {
                amount = Double(a.replacingOccurrences(of: ",", with: "."))
            }
        }
        return XMRIntent(address: addrCandidate, amount: amount)
    }

    // 2) raw address in free text
    let r = NSRange(location: 0, length: s.utf16.count)
    if let m = addrRegex.firstMatch(in: s, options: [], range: r),
       let rr = Range(m.range, in: s) {
        let address = String(s[rr])
        let amt = findNearbyAmount(in: s)
        return XMRIntent(address: address, amount: amt)
    }

    return nil
}
