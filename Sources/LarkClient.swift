import Foundation

// MARK: - Wire format

/// Every lark-cli response is this envelope. Note that lark-cli exits 0 even on
/// API failure, so `ok` is the only reliable success signal.
struct LarkEnvelope<T: Decodable>: Decodable {
    let ok: Bool?
    let identity: String?
    let data: T?
    let error: LarkAPIError?
}

struct LarkAPIError: Decodable {
    let type: String?
    let subtype: String?
    let code: Int?
    let message: String?
    let logID: String?

    enum CodingKeys: String, CodingKey {
        case type, subtype, code, message
        case logID = "log_id"
    }
}

enum LarkError: Error, CustomStringConvertible {
    /// The Lark token is gone or expired; the user must re-run `lark-cli auth login`.
    case authExpired(String)
    case api(code: Int, message: String)
    case cliMissing(String)
    case launchFailed(String)
    case badOutput(String)

    var description: String {
        switch self {
        case .authExpired(let m):  return "Lark authentication expired: \(m)"
        case .api(let c, let m):   return "Lark API error \(c): \(m)"
        case .cliMissing(let p):   return "lark-cli not found at \(p)"
        case .launchFailed(let m): return "could not run lark-cli: \(m)"
        case .badOutput(let m):    return "unexpected lark-cli output: \(m)"
        }
    }

    var isAuthExpired: Bool {
        if case .authExpired = self { return true }
        return false
    }
}

// MARK: - Client

/// Thin wrapper over the `lark-cli` binary. Uses an argv array via Process, so no
/// shell is involved and no quoting or injection is possible.
struct LarkClient {
    let cliPath: String

    init(cliPath: String) { self.cliPath = cliPath }

    // Lark token-related API codes, plus lark-cli's own auth failures.
    private static let authCodes: Set<Int> = [99991661, 99991663, 99991664, 99991668, 20005, 20006]

    func decode<T: Decodable>(_ type: T.Type, args: [String]) throws -> T {
        let out = try raw(args: args)
        let envelope: LarkEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(LarkEnvelope<T>.self, from: out)
        } catch {
            // An auth prompt or panic can come back as non-JSON text.
            let text = String(data: out, encoding: .utf8) ?? "<binary>"
            if Self.looksLikeAuthFailure(text) { throw LarkError.authExpired(Self.firstLine(text)) }
            throw LarkError.badOutput("\(error) — got: \(Self.firstLine(text))")
        }

        if envelope.ok != true {
            let e = envelope.error
            let code = e?.code ?? -1
            let message = e?.message ?? "unknown error"
            if Self.authCodes.contains(code)
                || e?.type == "auth"
                || Self.looksLikeAuthFailure(message) {
                throw LarkError.authExpired(message)
            }
            throw LarkError.api(code: code, message: message)
        }

        guard let value = envelope.data else {
            throw LarkError.badOutput("response had ok:true but no data")
        }
        return value
    }

    /// Runs lark-cli and returns raw stdout.
    func raw(args: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw LarkError.cliMissing(cliPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        // lark-cli is a Node script with a `#!/usr/bin/env node` shebang. Under
        // launchd the inherited PATH is only /usr/bin:/bin:/usr/sbin:/sbin, so
        // `env node` fails with exit 127 and the agent looks broken. Put the usual
        // Node locations back on PATH for the child.
        env["PATH"] = LarkClient.childPATH(inherited: env["PATH"], cliPath: cliPath)
        process.environment = env

        do {
            try process.run()
        } catch {
            throw LarkError.launchFailed(String(describing: error))
        }

        // Read before waiting, so a large agenda cannot fill the pipe buffer and deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if outData.isEmpty {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            if Self.looksLikeAuthFailure(errText) {
                throw LarkError.authExpired(Self.firstLine(errText))
            }
            if process.terminationStatus == 127 {
                throw LarkError.launchFailed(
                    "lark-cli could not start — node is not on PATH. "
                        + "Detail: \(Self.firstLine(errText))")
            }
            throw LarkError.badOutput(
                "empty stdout (exit \(process.terminationStatus)): \(Self.firstLine(errText))")
        }
        return outData
    }

    /// PATH for the lark-cli child: the directories Node is normally installed in,
    /// the CLI's own directory, any nvm install, then whatever we inherited.
    static func childPATH(inherited: String?, cliPath: String) -> String {
        var dirs: [String] = [
            "/usr/local/bin",       // node installed from nodejs.org / older Homebrew
            "/opt/homebrew/bin",    // Apple-silicon Homebrew
            "/opt/local/bin",       // MacPorts
            URL(fileURLWithPath: cliPath).deletingLastPathComponent().path,
        ]

        // nvm keeps node under ~/.nvm/versions/node/<version>/bin.
        let nvm = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvm, includingPropertiesForKeys: nil) {
            dirs += versions
                .map { $0.appendingPathComponent("bin").path }
                .sorted()
                .reversed()   // newest version first
        }

        dirs += (inherited ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func looksLikeAuthFailure(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("auth login")
            || t.contains("not authenticated")
            || t.contains("unauthorized")
            || t.contains("token expired")
            || t.contains("invalid token")
            || t.contains("re-authenticate")
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return String(line.prefix(240))
    }
}
