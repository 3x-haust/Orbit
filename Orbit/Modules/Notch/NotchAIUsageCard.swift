import SwiftUI

extension NotchAIUsageMode {
    var title: String {
        switch self {
        case .used: "Quota used"
        case .remaining: "Remaining"
        }
    }
}

extension NotchAIUsagePeriod {
    var title: String {
        switch self {
        case .fiveHours: "5 hours"
        case .weekly: "1 week"
        case .all: "All limits"
        }
    }

    func includes(_ minutes: Int) -> Bool {
        switch self {
        case .fiveHours: minutes == 300
        case .weekly: minutes == 10080
        case .all: true
        }
    }
}

struct NotchAIUsageCard: View {
    private let overrideOptions: NotchAIUsageOptions?
    private var options: NotchAIUsageOptions { overrideOptions ?? NotchCenter.shared.config.aiUsage }
    @State private var readings: [NotchAIProfile.ID: Reading] = [:]

    init(options: NotchAIUsageOptions? = nil) {
        overrideOptions = options
    }

    private struct Reading: Sendable {
        let profile: NotchAIProfile
        let result: NotchAIUsageResult
    }

    var body: some View {
        let profiles = options.profiles.filter(\.isVisible)
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    heading
                    Spacer(minLength: 0)
                    modeLabel
                }
                VStack(alignment: .leading, spacing: 2) {
                    heading
                    modeLabel
                }
            }
            if profiles.isEmpty {
                Text("Choose profiles in Notch Settings")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let list = VStack(alignment: .leading, spacing: 8) {
                        ForEach(profiles) { profile in
                            profileView(profile, now: context.date)
                        }
                    }
                    .padding(.trailing, 4)
                    // A fitting ScrollView still consumes swipes before the notch can close.
                    ViewThatFits(in: .vertical) {
                        list.fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            list
                        }
                        .defaultScrollAnchor(.topLeading)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: profiles) {
            guard !profiles.isEmpty else { return }
            await refresh(profiles)
        }
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Image(systemName: NotchHomeWidget.aiUsage.symbol)
                .accessibilityHidden(true)
            Text("AI Usage")
        }
        .font(.system(size: 11, weight: .semibold))
        .fixedSize()
    }

    private var modeLabel: some View {
        Text(options.mode.title.loc)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize()
    }

    private func refresh(_ profiles: [NotchAIProfile]) async {
        while !Task.isCancelled {
            await withTaskGroup(of: Reading.self) { group in
                for profile in profiles {
                    group.addTask {
                        let result = await NotchAIUsageService.shared.read(profile)
                        return Reading(profile: profile, result: result)
                    }
                }
                for await reading in group {
                    guard !Task.isCancelled else { break }
                    readings[reading.profile.id] = reading
                }
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func profileView(_ profile: NotchAIProfile, now: Date) -> some View {
        let reading = readings[profile.id]
        let result = reading?.profile == profile ? reading?.result : nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: profile.name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .help(profile.name)
            switch result {
            case .available(let snapshot):
                let windows = snapshot.windows.filter { options.period.includes($0.minutes) }
                if windows.isEmpty {
                    stateText("Selected limit unavailable")
                } else {
                    ForEach(Array(NotchAIQuotaWindow.pairs(windows).enumerated()), id: \.offset) { _, pair in
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) {
                                ForEach(pair) { window in
                                    quotaWindow(window, now: now)
                                        .frame(minWidth: 115)
                                }
                            }
                            HStack(spacing: 10) {
                                ForEach(pair) { window in
                                    quotaWindow(window, now: now, compact: true)
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(pair) { window in
                                    quotaWindow(window, now: now, compact: true)
                                }
                            }
                        }
                    }
                }
            case .sessionCost(let cost):
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        stateText("Estimated session cost")
                        Spacer(minLength: 0)
                        costAmount(cost)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        stateText("Estimated session cost")
                        costAmount(cost)
                    }
                }
                .help("Updated %@".loc(cost.observedAt.formatted(date: .abbreviated, time: .shortened)))
                .accessibilityElement(children: .combine)
            case .missing: stateText("Waiting for quota data")
            case .unreadable: stateText("Can’t read source folder")
            case .invalid: stateText("Invalid quota data")
            case nil: stateText("Checking…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaWindow(_ window: NotchAIQuotaWindow, now: Date, compact: Bool = false) -> some View {
        NotchAIWindowView(window: window, mode: options.mode, now: now, colorByUsage: options.colorByUsage, compact: compact)
    }

    private func costAmount(_ cost: NotchAISessionCost) -> some View {
        Text(cost.usd.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .fixedSize()
    }

    private func stateText(_ text: String) -> some View {
        Text(text.loc)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension NotchAIQuotaWindow {
    func isCurrent(at date: Date) -> Bool {
        let expiry = resetAt ?? observedAt.addingTimeInterval(Double(minutes) * 60)
        return date < expiry
    }
}

struct NotchAIWindowView: View {
    let window: NotchAIQuotaWindow
    let mode: NotchAIUsageMode
    let now: Date
    var colorByUsage = true
    var compact = false

    private var barColor: Color {
        guard colorByUsage else { return Palette.brand }
        switch NotchAIQuotaLevel(usedPercent: window.usedPercent) {
        case .plentiful: return Palette.deepGreen
        case .comfortable: return Color(nsColor: .systemGreen)
        case .low: return Palette.brand
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    private var periodTitle: String {
        switch window.minutes {
        case 300: return "5h".loc
        case 10080: return "1w".loc
        case let minutes where minutes.isMultiple(of: 1440):
            return "%lldd".loc(minutes / 1440)
        case let minutes where minutes.isMultiple(of: 60):
            return "%lldh".loc(minutes / 60)
        default:
            return "%lldm".loc(window.minutes)
        }
    }

    var percentage: Double? {
        guard window.isCurrent(at: now) else { return nil }
        let used = window.usedPercent / 100
        return mode == .used ? used : 1 - used
    }

    private var resetCountdown: String? {
        guard let countdown = NotchAIResetCountdown(resetAt: window.resetAt, now: now) else { return nil }
        return "\(countdown.value)\(countdown.unit == .hours ? "h" : "m")"
    }

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            if compact, let percentage {
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 2)
                    .overlay {
                        Circle().trim(from: 0, to: percentage)
                            .stroke(barColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(periodTitle)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize()
            if let percentage {
                if !compact {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.white.opacity(0.14))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(barColor)
                                    .frame(width: geometry.size.width * percentage)
                            }
                    }
                    .frame(minWidth: 24, maxWidth: .infinity)
                    .frame(height: 3)
                }
                Text(percentage.formatted(.percent.precision(.fractionLength(0))))
                    .fixedSize()
                if let resetCountdown {
                    Text(resetCountdown)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                        .accessibilityLabel("Resets in %@".loc(resetCountdown))
                }
                if compact { Spacer(minLength: 0) }
            } else {
                Spacer(minLength: 0)
                Text("Expired")
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .font(.system(size: compact ? 9 : 10, weight: .medium))
        .monospacedDigit()
        .help(window.resetAt.map { "Resets %@".loc($0.formatted(date: .abbreviated, time: .shortened)) }
            ?? "Updated %@".loc(window.observedAt.formatted(date: .abbreviated, time: .shortened)))
        .accessibilityElement(children: .combine)
    }
}
