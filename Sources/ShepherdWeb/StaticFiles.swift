import Foundation

/// `Bundle.module`'s generated accessor is unreliable when run via
/// `swift run` from a different working directory (same caveat
/// `HookInstaller.locateBundledScript` already documents for the main
/// app) - falling back to a path relative to this source file covers
/// `swift run ShepherdWeb` during development, which is this prototype's
/// only supported way to run for now.
func locatePublicDirectory() -> URL {
    if let bundled = Bundle.module.resourceURL?.appendingPathComponent("Public"),
       FileManager.default.fileExists(atPath: bundled.path) {
        return bundled
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
