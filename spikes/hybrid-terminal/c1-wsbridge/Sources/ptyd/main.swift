import Foundation
let argv = Array(CommandLine.arguments.dropFirst())
let o = parseOpts(Array(argv.dropFirst()))
switch argv.first {
case "daemon":
    let home = o.val["home"]!
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    Holder(home: home, sockPath: home + "/ptyd.sock", single: false).run()
case "hold":
    let home = o.val["home"]!, id = o.val["id"]!
    try? FileManager.default.createDirectory(atPath: home + "/s", withIntermediateDirectories: true)
    let h = Holder(home: home, sockPath: home + "/s/\(id).sock", single: true)
    var req: [String: Any] = ["id": id, "cmd": o.rest.first ?? "/bin/sh", "args": Array(o.rest.dropFirst()), "cwd": o.val["cwd"] ?? NSHomeDirectory(),
                              "cols": Int(o.val["cols"] ?? "100")!, "rows": Int(o.val["rows"] ?? "30")!]
    if let c = o.val["claude-sid"] { req["claudeSID"] = c }
    _ = h.spawn(req)
    h.run()
case "c":
    clientMain(o)
default:
    print("usage: ptyd daemon|hold|c ...")
}
