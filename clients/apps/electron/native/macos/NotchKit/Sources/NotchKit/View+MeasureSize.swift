import SwiftUI

private struct NotchMeasuredSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    func onMeasuredSizeChange(_ action: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: NotchMeasuredSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(NotchMeasuredSizeKey.self, perform: action)
    }
}
