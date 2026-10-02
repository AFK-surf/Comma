import SwiftUI
import UIKit
import CommaCore

// MARK: - Provider logos

/// A connected app's mark: the desktop's brand artwork when this app ships it, else the source's own icon,
/// else a neutral glyph. Monochrome marks (GitHub, Notion) follow the text colour.
struct ProviderLogo: View {
    let source: RecommendationSource?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = ProviderArtwork.image(source?.appID) {
                Image(uiImage: image).resizable().scaledToFit().foregroundStyle(CommaTheme.textPrimary)
            } else if let url = source?.iconURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().padding(size * 0.1)
            .foregroundStyle(CommaTheme.sidebarIcon)
    }
}

/// Provider artwork shipped in the asset catalog, keyed like the desktop logo resolver.
enum ProviderArtwork {
    /// The decorative sample shown before any source is connected, as on the desktop.
    static let samples = ["linear", "slack", "github", "googledrive"]

    static func image(_ appID: String?) -> UIImage? {
        guard let key = RecommendationSource.brandKey(appID) else { return nil }
        let name = "provider-" + (key == "googleworkspace" ? "google" : key)
        return UIImage(named: name)
    }

    /// A mark sized for a line of text, for use inside a `Text`.
    @MainActor static func inline(_ appID: String?, pointSize: CGFloat, tint: UIColor) -> Image? {
        guard let image = image(appID) else { return nil }
        let key = "\(appID ?? "")-\(pointSize)-\(tint.hashValue)"
        if let cached = cache[key] { return Image(uiImage: cached) }
        let source = image.renderingMode == .alwaysTemplate ? image.withTintColor(tint, renderingMode: .alwaysOriginal) : image
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: pointSize, height: pointSize))
        }
        cache[key] = rendered
        return Image(uiImage: rendered)
    }

    @MainActor private static var cache: [String: UIImage] = [:]
}

// MARK: - Widget families

/// The three layouts of a Routine card, sized like Home Screen widgets. The sidebar shows medium cards;
/// the Routines sheet shows large ones; small is the single-glance layout.
enum RoutineCardFamily: CaseIterable {
    case small, medium, large

    /// Widget canvas heights on a 6.1–6.3" iPhone. Width follows the container, except small, which is square.
    var height: CGFloat {
        switch self {
        case .small, .medium: 158
        case .large: 354
        }
    }
    var maxItems: Int {
        switch self {
        case .small: 1
        case .medium: 2
        case .large: 4
        }
    }
    var lineLimit: Int { self == .large ? 2 : 1 }
    static let cornerRadius: CGFloat = 22
    static let contentMargin: CGFloat = 14
}

/// What a Routine can ask the app to do. A prompt only fills the composer.
struct RoutineActions {
    let usePrompt: (String) -> Void
    let openTask: (String) -> Void
    let openURL: (URL) -> Void

    func perform(_ item: RecommendationItem) {
        if let task = item.linkedTaskID { openTask(task) } else if let action = item.action { perform(action) }
    }

    func perform(_ action: RecommendationAction) {
        switch action {
        case .openURL(let url, _): openURL(url)
        case .prompt(let prompt, _, let member): usePrompt(member ? Self.memberRequest(prompt) : prompt)
        }
    }

    /// A member row's prompt is their own task; the composer asks Comma for help with it in their voice.
    static func memberRequest(_ task: String) -> String {
        var words = task
        // "Decide whether…" follows "Help me" in lower case; "GitHub" or "PR" keep their case.
        if let first = words.first, first.isUppercase, words.dropFirst().prefix(while: \.isLetter).allSatisfy(\.isLowercase) {
            words = first.lowercased() + words.dropFirst()
        }
        return String(localized: "Help me \(words)")
    }
}

// MARK: - Card

/// One Routine card in a widget family, styled after the desktop Routines card: the source mark and a
/// quiet title, then rows of prose with inline source chips.
struct RoutineCardView: View {
    let card: RecommendationCard
    let feed: RecommendationFeed
    let family: RoutineCardFamily
    let actions: RoutineActions
    /// Widget surfaces keep the family's fixed canvas; the Routines sheet lets the card fit its content.
    var fitsContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: family == .small ? 8 : 6) {
            heading
            if let fallback = card.fallbackText {
                Text(fallback).font(.system(size: 14)).foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(fitsContent ? nil : family == .large ? 10 : 3)
                    .padding(.horizontal, 2)
            } else if family == .small {
                smallBody
            } else {
                rows
            }
            if !fitsContent { Spacer(minLength: 0) }
            footer
        }
        .padding(.top, RoutineCardFamily.contentMargin)
        .padding([.horizontal, .bottom], family == .small ? RoutineCardFamily.contentMargin : 6)
        .frame(maxWidth: family == .small ? family.height : .infinity, alignment: .topLeading)
        .frame(height: fitsContent ? nil : family.height, alignment: .top)
        .background(CommaTheme.cardPrimary, in: RoundedRectangle(cornerRadius: RoutineCardFamily.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RoutineCardFamily.cornerRadius, style: .continuous)
            .strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: RoutineCardFamily.cornerRadius, style: .continuous))
    }

    private var heading: some View {
        HStack(spacing: 8) {
            ProviderLogo(source: feed.source(for: card), size: 20)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(CommaTheme.textQuaternary).lineLimit(1)
        }
        .padding(.horizontal, family == .small ? 0 : 8)
    }

    /// The desktop renames the "googlecalendar" app id the model sometimes uses as a title.
    private var title: String {
        let key = RecommendationSource.brandKey(card.title)
        if feed.source(for: card)?.appID == "googlecalendar", key == "googlecalendar" || key == "googlecaleandar" { return "Google Calendar" }
        return card.title
    }

    /// Small: one glance and one tap target, the first item.
    @ViewBuilder private var smallBody: some View {
        if let item = card.items.first {
            Button { actions.perform(item) } label: {
                RoutineItemText(item: item, feed: feed, lineLimit: 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(card.items.prefix(family.maxItems)) { item in
                Button { actions.perform(item) } label: {
                    HStack(spacing: 8) {
                        if let url = item.imageURL {
                            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { CommaTheme.bgTertiary }
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        RoutineItemText(item: item, feed: feed, lineLimit: family.lineLimit)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RoutineActionGlyph(item: item)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(RoutineRowButtonStyle())
                .accessibilityLabel(Text(item.text.isEmpty ? (item.title ?? "") : item.text))
                .accessibilityHint(Text(item.action?.label ?? ""))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let hidden = max(0, card.items.count - family.maxItems)
        if family == .large, let action = card.footerAction {
            Button { actions.perform(action) } label: {
                HStack {
                    Text(action.label).font(.system(size: 14)).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(CommaTheme.sidebarIcon)
                }
                .padding(.horizontal, 8).frame(minHeight: 36)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(RoutineRowButtonStyle())
        } else if hidden > 0 {
            Text("+\(hidden) more").font(.system(size: 12, weight: .medium)).foregroundStyle(CommaTheme.textPlaceholder)
                .padding(.horizontal, family == .small ? 0 : 8).padding(.bottom, family == .small ? 0 : 6)
        }
    }
}

/// An item's prose, with links and Tasks as tinted inline chips carrying their source mark.
struct RoutineItemText: View {
    let item: RecommendationItem
    let feed: RecommendationFeed
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = item.title {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
            }
            if !item.parts.isEmpty {
                RoutineProse(parts: item.parts, feed: feed, size: 14, color: CommaTheme.textPrimary)
                    .lineLimit(lineLimit)
            } else if let detail = item.detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(CommaTheme.textTertiary).lineLimit(lineLimit)
            }
        }
    }
}

/// Briefing prose: text runs, and chips for links and Tasks drawn like the desktop's inline sources.
struct RoutineProse: View {
    let parts: [RecommendationPart]
    let feed: RecommendationFeed
    let size: CGFloat
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        parts.reduce(Text("")) { text, part in
            switch part {
            case .text(let value):
                return text + Text(Self.inlineMarkdown(value)).foregroundColor(color)
            case .link(let label, _, let source), .task(let label, _, let source):
                return text + chip(label: label, sourceID: source)
            }
        }
        .font(.system(size: size))
    }

    private func chip(label: String, sourceID: String?) -> Text {
        var run = AttributedString("\u{2009}" + label + "\u{2009}")
        run.backgroundColor = CommaTheme.bgTertiary
        run.foregroundColor = CommaTheme.textTertiary
        let tint = UIColor(CommaTheme.textSecondary).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        let appID = feed.source(sourceID)?.appID
        // An inline image cannot carry a run background, so the mark leads the tinted label.
        if let mark = ProviderArtwork.inline(appID, pointSize: size - 1, tint: tint) {
            return Text(mark).baselineOffset(-2) + Text("\u{2009}") + Text(run)
        }
        return Text(run)
    }

    /// The model writes light Markdown (bold, code); render it, keep everything else literal.
    static func inlineMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
}

/// The desktop row's trailing affordance: add to chat for prompts, open for links and Tasks.
private struct RoutineActionGlyph: View {
    let item: RecommendationItem
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(CommaTheme.sidebarIcon)
            .frame(width: 18)
    }
    private var symbol: String {
        if item.linkedTaskID != nil { return "chevron.right" }
        switch item.action {
        case .prompt: return "plus.circle"
        case .openURL: return "arrow.up.right"
        case nil: return ""
        }
    }
}

/// Rows have no resting surface; a press paints the quaternary fill, like the desktop hover.
struct RoutineRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(CommaTheme.bgTertiary.opacity(configuration.isPressed ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Empty and status states

/// A card-sized state for when there is no briefing: the app marks Comma reads from and one line of copy.
struct RoutineStatusCard: View {
    let feed: RecommendationFeed?
    let model: RoutinesModel
    let family: RoutineCardFamily
    var refresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if showsLogos {
                HStack(spacing: -4) {
                    let connected = (feed?.sources ?? []).filter(\.enabled).prefix(4)
                    if connected.isEmpty {
                        ForEach(ProviderArtwork.samples, id: \.self) { mark(ProviderLogo(source: RecommendationSource(connectionID: $0, appID: $0, appName: $0), size: 16)) }
                    } else {
                        ForEach(Array(connected)) { mark(ProviderLogo(source: $0, size: 16)) }
                    }
                }
            }
            Group {
                if model.isRefreshing {
                    Text("Generating your briefing…").shimmering()
                } else {
                    Text(message)
                }
            }
            .font(.system(size: 13)).foregroundStyle(CommaTheme.textQuaternary).multilineTextAlignment(.center)
            if let refresh, !model.isRefreshing, feed?.canRefresh == true || model.failure == .unavailable {
                Button("Refresh", action: refresh).font(.system(size: 13, weight: .medium)).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: family.height)
        .background(CommaTheme.cardPrimary.opacity(0.6), in: RoundedRectangle(cornerRadius: RoutineCardFamily.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RoutineCardFamily.cornerRadius, style: .continuous)
            .strokeBorder(CommaTheme.borderPrimary, style: StrokeStyle(lineWidth: 0.5, dash: feed?.hasSnapshot == true ? [] : [4, 3])))
    }

    private var showsLogos: Bool { model.failure != .unavailable || feed != nil }

    private func mark(_ logo: ProviderLogo) -> some View {
        logo.padding(5).background(CommaTheme.cardPrimary, in: Circle())
            .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
    }

    private var message: LocalizedStringKey {
        if model.failure == .rateLimited { return "Too many refreshes in the last hour. Try again later." }
        if model.failure == .unavailable { return "Routines couldn’t be loaded." }
        guard let feed else { return "Loading…" }
        if feed.hasSnapshot { return "Nothing new in your apps to brief today." }
        if feed.canRefresh {
            return feed.lastError == "renderer_declined" ? "Nothing new in your apps to brief today." : "Refresh to generate your first briefing."
        }
        return "No routines yet. Connect apps on the desktop so Comma can brief you."
    }
}

/// Names the sources only the member can repair; reconnecting happens in Plugins on the desktop.
struct RoutineReconnectNotice: View {
    let feed: RecommendationFeed?
    var body: some View {
        let names = (feed?.sourcesNeedingReconnect ?? []).map(\.appName)
        if !names.isEmpty {
            Label {
                Text("Routines can’t read \(names.formatted(.list(type: .and))). Reconnect it in Plugins on the desktop.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CommaTheme.attention)
            }
            .font(.system(size: 12)).foregroundStyle(CommaTheme.textTertiary)
        }
    }
}

private extension View {
    /// The desktop's shiny text, for copy that waits on a server run.
    func shimmering() -> some View {
        modifier(Shimmer())
    }
}

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width / 2)
                        .offset(x: phase * proxy.size.width)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 } }
    }
}
