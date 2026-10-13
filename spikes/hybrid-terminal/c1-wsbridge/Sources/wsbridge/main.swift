import Foundation
import Security
setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
var tokenFile = ""
while !args.isEmpty {
    let a = args.removeFirst()
    func val() -> String { args.isEmpty ? "" : args.removeFirst() }
    switch a {
    case "--port": Cfg.port = UInt16(val()) ?? 18750
    case "--holder": Cfg.holderSock = val()
    case "--token-file": tokenFile = val()
    case "--allow-host": Cfg.allowHosts.insert(val().lowercased())
    case "--allow-cwd": Cfg.allowCwds.append(URL(fileURLWithPath: val()).resolvingSymlinksInPath().path)
    case "--allow-shell": Cfg.allowShell = true
    case "--owner": Cfg.owner = val()
    case "--max-pending": Cfg.maxPending = Int(val()) ?? Cfg.maxPending
    default: print("unknown arg \(a)"); exit(2)
    }
}
if let t = try? String(contentsOfFile: tokenFile, encoding: .utf8) { Cfg.token = t.trimmingCharacters(in: .whitespacesAndNewlines) }
else {
    var b = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
    Cfg.token = Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    FileManager.default.createFile(atPath: tokenFile, contents: Data(Cfg.token.utf8), attributes: [.posixPermissions: 0o600])
}
signal(SIGPIPE, SIG_IGN)
let server = try Server()
server.start()
// stats on SIGUSR1
signal(SIGUSR1, SIG_IGN)
let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: q)
src.setEventHandler { log("stats \(server.stats) peers=\(server.peers.count) sessions=\(server.sessions.count)") }
src.resume()
dispatchMain()
