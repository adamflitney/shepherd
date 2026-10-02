import Foundation

/// Finds the bundled web assets without ever touching `Bundle.module`:
/// its generated accessor calls `fatalError` when neither of its hardcoded
/// paths resolves, which inside an assembled `.app` would crash the whole
/// menu bar app. `scripts/build-app.sh` puts this target's resource bundle
/// in `Contents/Resources/`; for `swift run` the bundle sits next to the
/// executable, and the source tree is the last-resort dev fallback.
func locatePublicDirectory() -> URL {
    let bundleName = "Shepherd_ShepherdWebKit.bundle/Public"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName),
        Bundle.main.bundleURL.appendingPathComponent(bundleName),
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
    ].compactMap { $0 }
    if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return found
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Public")
}

/// A top-level `let` in `main.swift` itself only initializes once
/// execution reaches its line, in file order - and `main.swift` never gets
/// there, since it blocks forever on `Task.sleep` right after starting the
/// server. Keeping this (and `serveStaticFile` below) in an ordinary file
/// instead sidesteps that: this initializes eagerly at process start like
/// any other global, regardless of what `main.swift` is doing.
private let contentTypes = [
    "html": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "json": "application/json",
    "webmanifest": "application/manifest+json",
    "png": "image/png",
    "svg": "image/svg+xml",
]

func serveStaticFile(_ path: String, from directory: URL) -> HTTPServer.Response {
    let requestedPath = path == "/" ? "/index.html" : path
    // Reject any attempt to escape `directory` via `..` before resolving -
    // this server is meant for a home network, not the open internet, but
    // path traversal costs nothing to rule out.
    guard !requestedPath.contains("..") else { return .notFound() }

    let fileURL = directory.appendingPathComponent(String(requestedPath.dropFirst()))
    guard let data = try? Data(contentsOf: fileURL) else { return .notFound() }
    let contentType = contentTypes[fileURL.pathExtension] ?? "application/octet-stream"
    return HTTPServer.Response(status: 200, headers: ["Content-Type": contentType], body: data)
}
