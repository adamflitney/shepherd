import Foundation

private struct PublicKeyWire: Encodable {
    let publicKey: String
    enum CodingKeys: String, CodingKey { case publicKey = "public_key" }
}

/// The shape of a browser `PushSubscription.toJSON()`.
private struct SubscribeBody: Decodable {
    struct Keys: Decodable { let p256dh: String; let auth: String }
    let endpoint: String
    let keys: Keys
}

private struct UnsubscribeBody: Decodable { let endpoint: String }
private struct TestResultWire: Encodable { let delivered: Int }

struct PushAPI {
    let push: PushService

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            switch (request.method, request.path) {
            case ("GET", "/api/push/key"):
                return .json(try JSONEncoder().encode(PublicKeyWire(publicKey: push.publicKey)))
            case ("POST", "/api/push/subscribe"):
                let body = try JSONDecoder().decode(SubscribeBody.self, from: request.body)
                await push.subscribe(PushSubscription(endpoint: body.endpoint, p256dh: body.keys.p256dh, auth: body.keys.auth))
                return .json(Data("{}".utf8))
            case ("POST", "/api/push/unsubscribe"):
                let body = try JSONDecoder().decode(UnsubscribeBody.self, from: request.body)
                await push.unsubscribe(endpoint: body.endpoint)
                return .json(Data("{}".utf8))
            case ("POST", "/api/push/test"):
                let payload = try JSONEncoder().encode(PushMessage(title: "Shepherd", body: "Notifications are working."))
                let delivered = await push.send(payload)
                return .json(try JSONEncoder().encode(TestResultWire(delivered: delivered)))
            default:
                return .notFound()
            }
        } catch {
            return .json(Data(#"{"error":"bad request"}"#.utf8), status: 400)
        }
    }
}
