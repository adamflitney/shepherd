import Foundation

/// Runs a subprocess and collects its output without ever blocking it: both pipes are drained while
/// the process runs, because a child that writes more than a pipe holds (about 64 KB, which a full
/// `ps` listing exceeds) stalls forever if nobody reads until it exits.
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: String, _ arguments: [String], stdin: String? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let inPipe = stdin == nil ? nil : Pipe()
                process.standardInput = inPipe ?? FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let inPipe, let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                // stderr is drained on its own thread so neither pipe can fill while we read the other
                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}
