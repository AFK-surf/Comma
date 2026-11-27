#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Comma

/// Renders the exact production SwiftUI Live Status views (`LiveStatusCardView`,
/// `LiveStatusExpandedIslandPreview`, `LiveStatusCompactIslandPreview`, `LiveStatusSmallCardView`)
/// into PNG files and XCTAttachments across all 6 generalized Live Activity scenarios.
@MainActor
final class LiveStatusScreenshotTests: XCTestCase {
    private static let referenceEpoch = 1_800_000_000
    private static var referenceDate: Date { Date(timeIntervalSince1970: TimeInterval(referenceEpoch)) }

    private struct Scenario {
        let slug: String
        let label: String
        let state: LiveStatusAttributes.ContentState
    }

    private var scenarios: [Scenario] {
        let now = Self.referenceEpoch
        return [
            Scenario(
                slug: "01-car-active",
                label: "滴滴叫车 · 接驾中 (Car Active)",
                state: LiveStatusAttributes.ContentState(
                    category: "car",
                    status: "active",
                    accent: "green",
                    title: "沪A·D8821 · 白色比亚迪汉",
                    subtitle: "距您 1.2 km · 沿南京西路驶来",
                    compactLabel: nil,
                    etaEpochSeconds: now + 180,
                    progress: 0.65,
                    stepCurrent: 2,
                    stepTotal: 4,
                    stepLabel: "接驾中",
                    detailLeft: "张师傅 · 4.9★",
                    detailRight: "快车 · 约 ¥17",
                    updatedAtEpochSeconds: now
                )
            ),
            Scenario(
                slug: "02-car-attention",
                label: "滴滴叫车 · 司机已到达 (Car Attention)",
                state: LiveStatusAttributes.ContentState(
                    category: "car",
                    status: "attention",
                    accent: "amber",
                    title: "司机已到达上车点",
                    subtitle: "请在静安嘉里中心南门上车",
                    compactLabel: "已到达",
                    etaEpochSeconds: nil,
                    progress: 1.0,
                    stepCurrent: 3,
                    stepTotal: 4,
                    stepLabel: "已到达",
                    detailLeft: "沪A·D8821 · 免费等候 02:45",
                    detailRight: "尾号 4821",
                    updatedAtEpochSeconds: now
                )
            ),
            Scenario(
                slug: "03-delivery",
                label: "美团外卖 · 骑手配送中 (Delivery)",
                state: LiveStatusAttributes.ContentState(
                    category: "delivery",
                    status: "active",
                    accent: "amber",
                    title: "骑手距您 650m · 正在赶来",
                    subtitle: "蓝瓶咖啡（静安嘉里店）等 2 件",
                    compactLabel: nil,
                    etaEpochSeconds: now + 720,
                    progress: 0.72,
                    stepCurrent: 3,
                    stepTotal: 4,
                    stepLabel: "配送中",
                    detailLeft: "美团专送 · 李骑手",
                    detailRight: "预计 12:24",
                    updatedAtEpochSeconds: now
                )
            ),
            Scenario(
                slug: "04-flight",
                label: "航班动态 · 登机口 B12 (Flight)",
                state: LiveStatusAttributes.ContentState(
                    category: "flight",
                    status: "attention",
                    accent: "blue",
                    title: "CA1501 · 北京首都 → 上海虹桥",
                    subtitle: "T3 航站楼 · 请前往登机口",
                    compactLabel: "B12",
                    etaEpochSeconds: now + 1_680,
                    progress: 0.5,
                    stepCurrent: 2,
                    stepTotal: 4,
                    stepLabel: "正在登机",
                    detailLeft: "计划 14:30 起飞",
                    detailRight: "座位 12A",
                    updatedAtEpochSeconds: now
                )
            ),
            Scenario(
                slug: "05-order",
                label: "咖啡取餐码 · A042 (Order)",
                state: LiveStatusAttributes.ContentState(
                    category: "order",
                    status: "active",
                    accent: "amber",
                    title: "生椰拿铁 · 冰 / 不另外加糖",
                    subtitle: "瑞幸咖啡（静安寺店）制作完成",
                    compactLabel: "A042",
                    etaEpochSeconds: nil,
                    progress: 1.0,
                    stepCurrent: 3,
                    stepTotal: 3,
                    stepLabel: "待取餐",
                    detailLeft: "请凭码至吧台取餐",
                    detailRight: "共 1 杯",
                    updatedAtEpochSeconds: now
                )
            ),
            Scenario(
                slug: "06-progress",
                label: "通用进度 · 生产部署 (Progress)",
                state: LiveStatusAttributes.ContentState(
                    category: "progress",
                    status: "active",
                    accent: "brand",
                    title: "生产集群滚动发布 v2.14.0",
                    subtitle: "正在验证 tokyo-prod 节点健康检查",
                    compactLabel: nil,
                    etaEpochSeconds: nil,
                    progress: 0.75,
                    stepCurrent: nil,
                    stepTotal: nil,
                    stepLabel: "部署中",
                    detailLeft: "6 / 8 节点就绪",
                    detailRight: "tokyo-prod",
                    updatedAtEpochSeconds: now
                )
            ),
        ]
    }

    func testRenderLiveStatusVisualEvidence() throws {
        let outputDir = screenshotOutputDirectory()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        for scenario in scenarios {
            let sheet = ScenarioComparisonSheet(
                title: scenario.label,
                state: scenario.state,
                referenceDate: Self.referenceDate
            )
            try renderAndSave(sheet, width: 420, name: scenario.slug, outputDir: outputDir)
        }

        let gallery = LiveStatusGallerySheet(
            items: scenarios.map { ($0.label, $0.state) },
            referenceDate: Self.referenceDate
        )
        try renderAndSave(gallery, width: 880, name: "00-gallery-overview", outputDir: outputDir)
    }

    private func screenshotOutputDirectory() -> URL {
        if let configured = ProcessInfo.processInfo.environment["LIVE_STATUS_SCREENSHOT_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/comma-live-status-screenshots", isDirectory: true)
    }

    private func renderAndSave<V: View>(_ view: V, width: CGFloat, name: String, outputDir: URL) throws {
        let host = UIHostingController(rootView: view
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.dynamicTypeSize, .large))
        host.view.backgroundColor = .clear
        let targetSize = host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height))
        let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: ceil(targetSize.height)))
        host.view.bounds = bounds
        host.view.frame = bounds

        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil

        let png = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(png.count, 2_000, "Rendered PNG for \(name) should be non-trivial")

        let fileURL = outputDir.appendingPathComponent("\(name).png")
        try png.write(to: fileURL, options: .atomic)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct LockScreenDarkPreviewCard: View {
    let state: LiveStatusAttributes.ContentState
    let referenceDate: Date

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        LiveStatusCardView(state: state, isStale: false, referenceDate: referenceDate)
            .background(Color(hex: 0x111214))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 8)
            .environment(\.colorScheme, .dark)
    }
}

private struct LockScreenLightPreviewCard: View {
    let state: LiveStatusAttributes.ContentState
    let referenceDate: Date

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        LiveStatusCardView(state: state, isStale: false, referenceDate: referenceDate)
            .background(Color.white)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 6)
            .environment(\.colorScheme, .light)
    }
}

private struct ScenarioComparisonSheet: View {
    let title: String
    let state: LiveStatusAttributes.ContentState
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color(hex: 0x141619))

            VStack(alignment: .leading, spacing: 12) {
                sectionCaption("DYNAMIC ISLAND · COMPACT & EXPANDED")
                HStack {
                    Spacer()
                    LiveStatusCompactIslandPreview(state: state, referenceDate: referenceDate)
                    Spacer()
                }
                HStack {
                    Spacer()
                    LiveStatusExpandedIslandPreview(state: state, referenceDate: referenceDate)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionCaption("LOCK SCREEN · DARK")
                LockScreenDarkPreviewCard(state: state, referenceDate: referenceDate)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionCaption("LOCK SCREEN · LIGHT")
                LockScreenLightPreviewCard(state: state, referenceDate: referenceDate)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionCaption("WATCH SMART STACK / CARPLAY · SMALL")
                LiveStatusSmallCardView(state: state, isStale: false, referenceDate: referenceDate)
                    .frame(width: 220, height: 92)
                    .background(Color(hex: 0x111214), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 6)
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xD4D7DC), Color(hex: 0xC8CCD2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Color(hex: 0x4A4E57))
    }
}

private struct LiveStatusGallerySheet: View {
    let items: [(String, LiveStatusAttributes.ContentState)]
    let referenceDate: Date

    private let columns = [
        GridItem(.flexible(minimum: 380), spacing: 24, alignment: .top),
        GridItem(.flexible(minimum: 380), spacing: 24, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                CommaMark(size: 20)
                    .foregroundStyle(Color(hex: 0x141619))
                Text("Comma Live Status · All Scenarios")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(hex: 0x141619))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(entry.0)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(hex: 0x262930))
                        HStack {
                            Spacer()
                            LiveStatusCompactIslandPreview(state: entry.1, referenceDate: referenceDate)
                            Spacer()
                        }
                        LiveStatusExpandedIslandPreview(state: entry.1, referenceDate: referenceDate)
                        LockScreenDarkPreviewCard(state: entry.1, referenceDate: referenceDate)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.32), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                }
            }
        }
        .padding(26)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xD4D7DC), Color(hex: 0xC8CCD2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
#endif
