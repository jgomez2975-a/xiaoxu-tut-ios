import SwiftUI

/// 配色与排版：与 PC 版 npclab 的深色玻璃保持一致
enum T {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.063)        // #0b0c10
    static let bg2 = Color(red: 0.075, green: 0.082, blue: 0.106)       // #13151b
    static let card = Color.white.opacity(0.055)
    static let cardHi = Color.white.opacity(0.10)
    static let line = Color.white.opacity(0.085)
    static let lineHi = Color.white.opacity(0.16)
    static let txt = Color(red: 0.95, green: 0.955, blue: 0.97)
    static let txt2 = Color.white.opacity(0.58)
    static let txt3 = Color.white.opacity(0.34)

    static let accent = Color(red: 0.39, green: 0.55, blue: 1.0)        // #638cff
    static let green = Color(red: 0.19, green: 0.82, blue: 0.45)
    static let red = Color(red: 1.0, green: 0.32, blue: 0.28)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let purple = Color(red: 0.66, green: 0.44, blue: 1.0)
    static let teal = Color(red: 0.20, green: 0.78, blue: 0.78)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 毛玻璃圆角卡片
struct Glass: ViewModifier {
    var radius: CGFloat = 16
    var strong: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(strong ? T.cardHi : T.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(T.line, lineWidth: 1)
            )
    }
}

extension View {
    func glass(_ radius: CGFloat = 16, strong: Bool = false) -> some View {
        modifier(Glass(radius: radius, strong: strong))
    }
}

/// 全局背景
struct Backdrop: View {
    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            LinearGradient(
                colors: [T.accent.opacity(0.16), .clear, T.purple.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}
