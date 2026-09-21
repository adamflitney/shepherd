import SwiftUI
import ShepherdCore

public struct SessionRowView: View {
    let session: Session
    let isSelected: Bool
    let onPrompt: (() -> Void)?

    public init(session: Session, isSelected: Bool, onPrompt: (() -> Void)? = nil) {
        self.session = session
        self.isSelected = isSelected
        self.onPrompt = onPrompt
    }

    private var display: AttentionDisplay { attentionDisplay(for: session.attention.kind) }

    /// Priority, per the user's own usage: a Herdr workspace ("space") is
    /// normally one session, so its label is the primary identifier;
    /// directory and the pane's own label are useful but secondary/tertiary.
    /// Each line is dropped if it would just repeat one already shown above it.
    private var primaryLine: String { session.group?.label ?? session.title }

    private var directoryLine: String? {
        guard let cwd = session.workingDirectory else { return nil }
        let dir = cwd.lastPathComponent
        return dir.caseInsensitiveCompare(primaryLine) == .orderedSame ? nil : dir
    }

    private var paneLine: String? {
        let title = session.title
        if title.caseInsensitiveCompare(primaryLine) == .orderedSame { return nil }
        if let directoryLine, title.caseInsensitiveCompare(directoryLine) == .orderedSame { return nil }
        return title
    }

    private var badgeColor: Color {
        switch session.attention.kind {
        case .blocked: .red
        case .done: .green
        case .working: .blue
        case .idle: .secondary
        case .unknown: .gray
        }
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: display.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(badgeColor)
                .imageScale(.large)
                .accessibilityLabel(display.label)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(primaryLine)
                        .font(.body)
                        .lineLimit(1)
                    if let directoryLine {
                        Text(directoryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let paneLine {
                    Text(paneLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let onPrompt, session.capabilities.contains(.prompt) {
                Button(action: onPrompt) {
                    Image(systemName: "bubble.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if session.isFocused {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
