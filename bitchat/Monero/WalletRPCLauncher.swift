#if os(macOS)
//
// WalletRPCLauncher.swift (macOS)
// bitchat – bundles & spawns monero-wallet-rpc locally
// Public domain – https://unlicense.org
//

import Foundation

final class WalletRPCLauncher {
    static let shared = WalletRPCLauncher()
    private init() {}

    private let fm = FileManager.default

    private var appSupport: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("bitchat", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var binDir: URL { appSupport.appendingPathComponent("bin", isDirectory: true) }
    private var walletsDir: URL { appSupport.appendingPathComponent("wallets", isDirectory: true) }
    private var logsDir: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }
    private var rpcDst: URL { binDir.appendingPathComponent("monero-wallet-rpc") }
    private var walletPath: URL { walletsDir.appendingPathComponent("demo") }
    private var logPath: URL { logsDir.appendingPathComponent("wallet-rpc.log") }

    private var process: Process?

    private func ensureInstalledFromBundle() throws {
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: walletsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: rpcDst.path) {
            guard let src = Bundle.main.url(forResource: "monero-wallet-rpc", withExtension: nil) else {
                throw NSError(domain: "WalletRPC", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Bundled monero-wallet-rpc not found in app resources"])
            }
            try fm.copyItem(at: src, to: rpcDst)
            // make it executable
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", rpcDst.path]
            try? chmod.run()
            chmod.waitUntilExit()
        }
    }

    @discardableResult
    func startIfNeeded(
        stagenet: Bool = true,
        port: Int = 18083,
        daemonURL envDaemon: String? = ProcessInfo.processInfo.environment["BITCHAT_DAEMON_URL"]
    ) throws -> Int {
        if process?.isRunning == true { return port }
        try ensureInstalledFromBundle()

        let daemonURL = envDaemon ?? "http://127.0.0.1:38081"

        if !fm.fileExists(atPath: logPath.path) { fm.createFile(atPath: logPath.path, contents: nil) }
        let logHandle = try FileHandle(forWritingTo: logPath)
        try? logHandle.seekToEnd()

        let p = Process()
        p.executableURL = rpcDst
        var args: [String] = []
        if stagenet { args.append("--stagenet") }
        args += [
            "--daemon-address", daemonURL,
            "--trusted-daemon",
            "--rpc-bind-ip", "127.0.0.1",
            "--rpc-bind-port", "\(port)",
            "--disable-rpc-login",
            "--wallet-file", walletPath.path,
            "--password", "XMRm4x!2025secure",
            "--log-level", "1"
        ]
        p.arguments = args
        p.standardOutput = logHandle
        p.standardError  = logHandle
        try p.run()
        process = p

        // Wait until wallet-rpc answers get_version (≤15s)
        let ok = waitReadyJSONRPC(URL(string: "http://127.0.0.1:\(port)/json_rpc")!, timeout: 15)
        if !ok {
            stop()
            throw NSError(domain: "WalletRPC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "wallet-rpc did not become ready (see \(logPath.path))"])
        }
        return port
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
    }

    private func waitReadyJSONRPC(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let body: [String: Any] = ["jsonrpc":"2.0","id":0,"method":"get_version"]
        let payload = try? JSONSerialization.data(withJSONObject: body)

        while Date() < deadline {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload

            let sem = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let d = data,
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String:Any],
                   obj["result"] != nil {
                    ok = true
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 0.5)
            if ok { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
#endif
