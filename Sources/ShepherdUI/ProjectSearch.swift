import Foundation
import ShepherdCore

/// Fuzzy-filters projects for the project picker, combining the match score
/// with each project's existing frecency score - ported from mac-sesh's
/// `SearchViewModel.filtered`. An empty query keeps the incoming
/// (frecency-sorted) order rather than re-sorting.
public func filterProjects(_ projects: [Project], query: String) -> [Project] {
    guard !query.isEmpty else { return projects }

    return projects
        .compactMap { project -> (Project, Double)? in
            let nameScore = fuzzyScore(query, in: project.name)
            let lastComponent = (project.path as NSString).lastPathComponent
            let pathScore = lastComponent != project.name ? fuzzyScore(query, in: lastComponent) : nil
            guard let fuzzy = [nameScore, pathScore].compactMap({ $0 }).max() else { return nil }
            return (project, fuzzy + project.score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}
