import Foundation

/// Ported from mac-sesh's `Projects.swift` - git-repo discovery plus frecency
/// scoring, for the project picker that replaces the plain-path creation
/// form. `UserDefaults` storage uses its own key so it can't collide with
/// mac-sesh's own visit history even if both apps somehow ran side by side.

// ── Types ─────────────────────────────────────────────────────────────────────

public struct Project: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public var score: Double

    public init(name: String, path: String, score: Double = 0) {
        self.name = name
        self.path = path
        self.score = score
    }
}

// ── Discovery ─────────────────────────────────────────────────────────────────

/// Scans each directory for immediate subdirectories containing a .git folder.
public func findGitProjects(in directories: [URL]) -> [Project] {
    directories.flatMap { dir -> [Project] in
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return [] }

        return entries.compactMap { entry in
            var isDir: ObjCBool = false
            let gitPath = entry.appendingPathComponent(".git").path
            guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
                return nil
            }
            return Project(name: entry.lastPathComponent, path: entry.path)
        }
    }
}

/// String-path overload for convenience.
public func findGitProjects(in directories: [String]) -> [Project] {
    findGitProjects(in: directories.map { URL(fileURLWithPath: $0) })
}

public func projectName(fromPath path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

// ── Frecency scoring ──────────────────────────────────────────────────────────

/// Scores a project based on visit recency and frequency.
/// Visits within the last day count most; older visits decay exponentially.
public func frecencyScore(visits: [Date]) -> Double {
    let now = Date()
    return visits.reduce(0.0) { score, visit in
        let hours = now.timeIntervalSince(visit) / 3600
        let weight: Double = switch hours {
        case ..<24:     4.0   // within a day
        case ..<168:    2.0   // within a week
        case ..<720:    0.5   // within a month
        default:        0.1
        }
        return score + weight
    }
}

/// Applies stored visit history to a list of projects and sorts by score descending.
public func scored(_ projects: [Project], visits: [String: [Date]]) -> [Project] {
    projects
        .map { project in
            var p = project
            p.score = frecencyScore(visits: visits[project.path] ?? [])
            return p
        }
        .sorted { $0.score > $1.score }
}

// ── Visit storage ─────────────────────────────────────────────────────────────

private let visitsKey = "Shepherd.projectVisits"
private let maxVisitsPerProject = 50

/// Records a visit to a project path, keeping only the most recent visits.
public func recordVisit(to path: String) {
    var all = loadVisits()
    var projectVisits = all[path] ?? []
    projectVisits.append(Date())
    if projectVisits.count > maxVisitsPerProject {
        projectVisits = Array(projectVisits.suffix(maxVisitsPerProject))
    }
    all[path] = projectVisits
    saveVisits(all)
}

public func loadVisits() -> [String: [Date]] {
    guard let data = UserDefaults.standard.data(forKey: visitsKey),
          let decoded = try? JSONDecoder().decode([String: [Date]].self, from: data)
    else { return [:] }
    return decoded
}

private func saveVisits(_ visits: [String: [Date]]) {
    guard let data = try? JSONEncoder().encode(visits) else { return }
    UserDefaults.standard.set(data, forKey: visitsKey)
}
