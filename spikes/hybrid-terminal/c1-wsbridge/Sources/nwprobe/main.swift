import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
import Network

// Probe: does NWProtocolWebSocket on a loopback NWListener also answer plain HTTP on the same port?
let port = NWEndpoint.Port(rawValue: UInt16(CommandLine.arguments.dropFirst().first ?? "18741")!)!
let q = DispatchQueue(label: "probe")
let wsOpts = NWProtocolWebSocket.Options()
wsOpts.autoReplyPing = true
wsOpts.maximumMessageSize = 1 << 20
wsOpts.setClientRequestHandler(q) { subprotocols, headers in
    print("client request: subprotocols=\(subprotocols) headers=\(headers)")
    let resp = NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
    return resp
}
let params = NWParameters.tcp
params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
let listener = try NWListener(using: params)
listener.newConnectionHandler = { conn in
    print("new connection")
    conn.stateUpdateHandler = { print("  state: \($0)") }
    conn.start(queue: q)
    func rx() {
        conn.receiveMessage { data, ctx, _, err in
            if let err { print("  rx error: \(err)"); return }
            let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            print("  msg opcode=\(String(describing: meta?.opcode)) bytes=\(data?.count ?? -1)")
            if let data { 
                let m = NWProtocolWebSocket.Metadata(opcode: .binary)
                let c = NWConnection.ContentContext(identifier: "echo", metadata: [m])
                conn.send(content: data, contentContext: c, isComplete: true, completion: .idempotent)
            }
            rx()
        }
    }
    rx()
}
listener.stateUpdateHandler = { print("listener: \($0)") }
listener.start(queue: q)
dispatchMain()
