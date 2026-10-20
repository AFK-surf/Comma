import SwiftUI
import CommaCore

/// A Task referenced under a message rather than in its text: its status icon, then its title.
struct TaskReferenceLabel: View {
    let title: String?
    let task: TaskSummary?

    var body: some View {
        HStack(spacing: 6) {
            if let task {
                TaskStatusIcon(bucket: task.bucket, size: 16)
            } else {
                // The desktop reference card's Task glyph, while the Task itself is unknown.
                CentralIcon("central-planning", size: 16, relativeTo: .subheadline)
                    .foregroundStyle(CommaTheme.sidebarIcon)
            }
            Text(task?.title ?? title ?? String(localized: "Task"))
                .font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.map { String(localized: $0.bucket.label) } ?? "")
    }
}

extension EnvironmentValues {
    /// The store whose Tasks give an inline Task in a message its current title and status, when the surface has one.
    @Entry var inlineTaskStore: CommaStore? = nil
}

/// Desktop `InlineTask` metrics at the body size: a 20pt status icon in a pill 2pt taller, padded 4pt before the
/// icon and 8pt after the title, 2pt from the prose on each side, with the desktop's 6pt corners.
enum InlineTaskMetrics {
    static let margin: CGFloat = 2, leading: CGFloat = 4, gap: CGFloat = 2, trailing: CGFloat = 8, radius: CGFloat = 6
    /// How far below the baseline the icon sits, as a share of its side, so it centres on the text.
    static let drop: CGFloat = 0.2
}

/// Marks the runs of one inline Task, so `InlineTaskPills` draws a pill behind them.
struct InlineTaskPill: TextAttribute { let index: Int }

/// Marks the space an inline Task keeps for its status glyph, which `InlineTaskPills` draws there; nil while its status
/// is not known.
struct InlineTaskIcon: TextAttribute { let bucket: TaskBucket? }

extension MarkdownInline {
    /// `value` as one `Text`, each inline Task link drawn as the desktop `InlineTask`: room for the status icon, then
    /// the title in the prose's colour and weight. `InlineTaskPills` draws the pill and the icon behind them. The link
    /// stays on the title, so a tap opens the Task.
    static func text(_ value: AttributedString, iconSide: CGFloat, summary: ((String) -> TaskSummary?)?) -> Text {
        guard namesTask(value) else { return Text(value) }
        let runs = value.runs[\.link]
        var result = Text(verbatim: "")
        for (index, (link, range)) in runs.enumerated() {
            guard let link, let (id, sent) = inlineTask(link), let target = URL(string: "comma:task/" + id) else {
                result = result + Text(AttributedString(value[range]))
                continue
            }
            let task = summary?(id)
            // A Task this device cannot look up, named by a link that carries no status, shows the neutral glyph.
            let bucket = task?.bucket ?? sent
            let written = String(value[range].characters)
            let name = task?.title ?? (written.isEmpty || written == id ? String(localized: "Task") : written)
            // A word joiner keeps the title on the icon's line; the trailing padding and margin are the last
            // character's kerning, so nothing between them can break.
            var title = AttributedString("\u{2060}" + name)
            title.link = target
            title.foregroundColor = bucket == .archived ? CommaTheme.textQuaternary : CommaTheme.textPrimary
            if let last = title.characters.indices.last {
                title[last..<title.endIndex].kern = InlineTaskMetrics.trailing + InlineTaskMetrics.margin
            }
            let pill = InlineTaskPill(index: index)
            result = result
                + Text(iconSpace(bucket, side: iconSide)).customAttribute(pill)
                    .customAttribute(InlineTaskIcon(bucket: bucket))
                + Text(title).customAttribute(pill)
        }
        return result
    }

    static func namesTask(_ value: AttributedString) -> Bool {
        value.runs[\.link].contains { $0.0.flatMap(inlineTask) != nil }
    }

    /// The Task an inline link names, and the status it was sent with; nil for any other link.
    static func inlineTask(_ url: URL) -> (id: String, status: TaskBucket?)? {
        let parts = url.absoluteString.split(separator: "#", maxSplits: 1)
        guard let base = parts.first.flatMap({ URL(string: String($0)) }),
              let id = TaskMention.conversationID(from: base) else { return nil }
        return (id, parts.count > 1 ? TaskBucket(rawValue: String(parts[1])) : nil)
    }

    /// The width of the status glyph with the pill's leading margin, padding and gap around it, and 1pt high, so the
    /// line keeps the font's height in every layout of the text; `InlineTaskPills` draws the glyph. VoiceOver reads it
    /// as the status.
    private static func iconSpace(_ bucket: TaskBucket?, side: CGFloat) -> Image {
        let width = InlineTaskMetrics.margin + InlineTaskMetrics.leading + side + InlineTaskMetrics.gap
        return Image(size: CGSize(width: width, height: 1), label: bucket.map { Text($0.label) }) { _ in }
    }
}

/// Draws the pill behind each inline Task's runs, one per line it spans (desktop `.comma-inline-task`), and its
/// status glyph in the space the text keeps for it, and not the text itself. Selectable text ignores a `TextRenderer`,
/// so the pills draw from a copy of the text laid out beneath it, outside the selection. The copy and the selectable
/// text place a line alike only while nothing in it is taller than the font, so the glyph is drawn here rather than
/// in the text.
struct InlineTaskPills: TextRenderer {
    let iconSide: CGFloat
    let fill: Color

    /// Room for a pill where it reaches past the first or the last line.
    var displayPadding: EdgeInsets {
        let overhang = iconSide * InlineTaskMetrics.drop
        return EdgeInsets(top: overhang, leading: 0, bottom: overhang, trailing: 0)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var pills: [(pill: InlineTaskPill, rect: CGRect)] = []
            var icons: [(bucket: TaskBucket?, x: CGFloat)] = []
            for run in line {
                guard let pill = run[InlineTaskPill.self] else { continue }
                let bounds = run.typographicBounds
                if let icon = run[InlineTaskIcon.self] { icons.append((icon.bucket, bounds.rect.minX)) }
                if pills.last?.pill == pill {
                    pills[pills.count - 1].rect = pills[pills.count - 1].rect.union(bounds.rect)
                } else {
                    pills.append((pill, bounds.rect))
                }
            }
            let mid = line.typographicBounds.origin.y - iconSide * (0.5 - InlineTaskMetrics.drop)
            for (_, rect) in pills {
                let height = iconSide + 2
                let pill = CGRect(x: rect.minX + InlineTaskMetrics.margin, y: mid - height / 2,
                                  width: rect.width - 2 * InlineTaskMetrics.margin, height: height)
                context.fill(Path(roundedRect: pill, cornerRadius: InlineTaskMetrics.radius, style: .continuous),
                             with: .color(fill))
            }
            for (bucket, x) in icons {
                let frame = CGRect(x: x + InlineTaskMetrics.margin + InlineTaskMetrics.leading, y: mid - iconSide / 2,
                                   width: iconSide, height: iconSide)
                // The glyph masks a fill of the status colour; a template's own shading is lost in a context.
                var glyph = context
                glyph.clipToLayer { layer in layer.draw(layer.resolve(Image(bucket?.iconName ?? TaskBucket.neutralIconName)), in: frame) }
                glyph.fill(Path(frame), with: .color(bucket?.tint ?? CommaTheme.sidebarIcon))
            }
        }
    }
}

extension View {
    /// Pills under `text`'s inline Tasks, when it names any; `text` must be laid out as this view lays it out, and
    /// selection must be set on this view rather than an ancestor, which would draw the copy as plain text.
    @ViewBuilder func inlineTaskPills(_ text: Text, has tasks: Bool, iconSide: CGFloat, lineSpacing: CGFloat = 0) -> some View {
        if tasks {
            background(alignment: .topLeading) {
                text.lineSpacing(lineSpacing)
                    .textRenderer(InlineTaskPills(iconSide: iconSide, fill: CommaTheme.inlineTaskPill))
                    .accessibilityHidden(true)
            }
        } else {
            self
        }
    }
}
