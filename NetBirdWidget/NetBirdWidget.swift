import WidgetKit
import SwiftUI

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

@main
struct NetBirdWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetBirdStatusWidget()
    }
}

struct NetBirdStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NetBirdStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetGlassBackground() }
        }
        .configurationDisplayName("NetBird Status")
        .description("Clients online, Exit-Nodes, Proxy-Services und Update-Status.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

struct WidgetGlassBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark
                           ? [Color(red: 0.12, green: 0.13, blue: 0.22), Color(red: 0.03, green: 0.04, blue: 0.08)]
                           : [Color(red: 0.95, green: 0.95, blue: 0.98), Color(red: 0.86, green: 0.88, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [WidgetColors.orange.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
            RadialGradient(colors: [WidgetColors.blue.opacity(0.35), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 240)
        }
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .systemSmall: SmallView(s: s)
            case .systemMedium: MediumView(s: s)
            case .systemLarge: LargeView(s: s)
            case .accessoryCircular: CircularView(s: s)
            case .accessoryRectangular: RectangularView(s: s)
            case .accessoryInline: Text("NetBird \(s.peersOnline)/\(s.peersTotal) online")
            default: SmallView(s: s)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bird.fill").font(.title2).foregroundStyle(WidgetColors.orange)
                Text("App öffnen, um Daten zu laden").font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GlassTile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
    }
}

private struct OnlineRing: View {
    let online: Int
    let total: Int
    var lineWidth: CGFloat = 7
    var fraction: Double { total == 0 ? 0 : Double(online) / Double(total) }
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [WidgetColors.online, WidgetColors.teal, WidgetColors.online], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(online)").font(.system(.title2, design: .rounded).bold()).monospacedDigit()
                Text("/\(total)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Header: View {
    let s: WidgetSnapshot
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bird.fill").foregroundStyle(WidgetColors.orange)
            Text(s.serverName).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if s.ipv6Enabled {
                Text("v6").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(WidgetColors.teal.opacity(0.25), in: Capsule()).foregroundStyle(WidgetColors.teal)
            }
        }
    }
}

private struct UpdateBadge: View {
    let s: WidgetSnapshot
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: s.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal.fill")
                .foregroundStyle(s.updateAvailable ? WidgetColors.orange : WidgetColors.online)
            Text(s.updateAvailable ? "Update \(s.latestVersion ?? "")" : "Server aktuell")
                .font(.caption2.weight(.semibold)).lineLimit(1)
        }
    }
}

private struct SmallView: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(s: s)
            HStack {
                OnlineRing(online: s.peersOnline, total: s.peersTotal).frame(width: 64, height: 64)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Label("\(s.exitNodes)", systemImage: "door.right.hand.open").font(.caption2)
                    Label("\(s.servicesActive)", systemImage: "arrow.triangle.branch").font(.caption2)
                }
                .labelStyle(.titleAndIcon)
            }
            UpdateBadge(s: s)
        }
    }
}

private struct MediumView: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Header(s: s)
                Text(s.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                OnlineRing(online: s.peersOnline, total: s.peersTotal).frame(width: 72, height: 72)
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        tile("Exit-Nodes", "\(s.exitNodesEnabled)/\(s.exitNodes)", "door.right.hand.open", WidgetColors.blue)
                        tile("Proxy", "\(s.servicesActive)/\(s.servicesTotal)", "arrow.triangle.branch",
                             s.servicesWithIssues > 0 ? .red : WidgetColors.orange)
                    }
                    HStack(spacing: 6) {
                        tile("Server", s.installedVersion ?? "–", s.updateAvailable ? "arrow.down.circle" : "checkmark.seal",
                             s.updateAvailable ? WidgetColors.orange : WidgetColors.online)
                        tile("Veraltet", "\(s.outdatedClients)", "exclamationmark.arrow.circlepath",
                             s.outdatedClients > 0 ? WidgetColors.orange : WidgetColors.online)
                    }
                }
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        GlassTile {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.caption.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LargeView: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediumView(s: s)
            GlassTile {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(s.peers.prefix(7)) { p in
                        HStack(spacing: 6) {
                            Circle().fill(p.online ? WidgetColors.online : .gray).frame(width: 7, height: 7)
                            Text(p.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            if p.outdated {
                                Image(systemName: "arrow.down.circle").font(.caption2).foregroundStyle(WidgetColors.orange)
                            }
                            Text(p.ip).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            UpdateBadge(s: s)
        }
    }
}

private struct CircularView: View {
    let s: WidgetSnapshot
    var body: some View {
        Gauge(value: Double(s.peersOnline), in: 0...Double(max(s.peersTotal, 1))) {
            Image(systemName: "bird.fill")
        } currentValueLabel: {
            Text("\(s.peersOnline)")
        }
        .gaugeStyle(.accessoryCircular)
    }
}

private struct RectangularView: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("NetBird", systemImage: "bird.fill").font(.headline)
            Text("\(s.peersOnline)/\(s.peersTotal) online · \(s.servicesActive) Proxy").font(.caption)
            Text(s.updateAvailable ? "Update \(s.latestVersion ?? "") verfügbar" : "Server aktuell").font(.caption2)
        }
    }
}

#Preview(as: .systemMedium) {
    NetBirdStatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .placeholder)
}
