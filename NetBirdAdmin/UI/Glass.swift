import SwiftUI

// MARK: - Farben

extension Color {
    static let nbOrange = Color(red: 0.965, green: 0.514, blue: 0.188)   // NetBird-Orange
    static let nbBlue = Color(red: 0.20, green: 0.42, blue: 0.95)
    static let nbTeal = Color(red: 0.10, green: 0.75, blue: 0.70)
    static let nbOnline = Color(red: 0.20, green: 0.82, blue: 0.45)
}

// MARK: - Hintergrund

/// Farbiger, leicht animierter Hintergrund, auf dem die Glas-Flächen gut wirken.
struct GlassBackground: View {
    @State private var animate = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.05, green: 0.06, blue: 0.10) : Color(red: 0.93, green: 0.94, blue: 0.97))
            blob(.nbOrange, size: 420, x: animate ? -120 : -60, y: animate ? -260 : -200)
            blob(.nbBlue, size: 460, x: animate ? 140 : 90, y: animate ? 120 : 200)
            blob(.nbTeal, size: 320, x: animate ? -100 : -150, y: animate ? 380 : 320)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { animate = true }
        }
    }

    private func blob(_ c: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(c.opacity(scheme == .dark ? 0.45 : 0.35))
            .frame(width: size, height: size)
            .blur(radius: 90)
            .offset(x: x, y: y)
    }
}

// MARK: - Glas-Fläche

struct GlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 22
    var tint: Color? = nil
    var interactive = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.25)) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.12))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Standard-Karte: Innenabstand + Glas.
    func glassCard(padding: CGFloat = 16, tint: Color? = nil) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(tint: tint)
    }

    /// Listen auf Glas-Hintergrund ohne Systemhintergrund.
    func glassScreen() -> some View {
        self.scrollContentBackground(.hidden)
            .background(GlassBackground())
    }
}

// MARK: - Bausteine

struct StatusDot: View {
    var online: Bool
    var body: some View {
        Circle()
            .fill(online ? Color.nbOnline : Color.gray.opacity(0.6))
            .frame(width: 10, height: 10)
            .shadow(color: online ? Color.nbOnline.opacity(0.8) : .clear, radius: 4)
    }
}

struct Pill: View {
    var text: String
    var color: Color = .nbBlue
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var systemImage: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
            Text(value).font(.title.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .glassCard(tint: color)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .nbOrange
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.gradient)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.35)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct EmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .glassCard()
        .padding()
    }
}

/// Fehler-Banner (unten eingeblendet).
struct ErrorBanner: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button { self.message = nil } label: { Image(systemName: "xmark") }
                }
                .glassCard(padding: 12, tint: .red)
                .padding(.horizontal)
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(6))
                    withAnimation { self.message = nil }
                }
            }
        }
        .animation(.spring, value: message)
    }
}

extension View {
    func errorBanner(_ message: Binding<String?>) -> some View { modifier(ErrorBanner(message: message)) }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
