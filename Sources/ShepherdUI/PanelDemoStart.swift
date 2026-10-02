/// Which tab the panel opens on, and what's typed in its filter, for
/// `--demo-panel` screenshot runs. `tab` is `create`, `ask` or `review`.
public struct PanelDemoStart: Sendable {
    public var tab: String
    public var query: String

    public init(tab: String, query: String = "") {
        self.tab = tab
        self.query = query
    }
}
