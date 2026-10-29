import AppKit
import SwiftUI

/// System page: scroll direction per device, wheel steps, speed and smooth scrolling.
struct ScrollingSection: View {
    @Bindable private var scroll = ScrollReverser.shared

    var body: some View {
        SettingsGroup(title: "Scrolling", footer: "macOS uses one direction for every device. Orbit lets the mouse and the trackpad each go their own way.") {
            SettingsRow(title: "Separate mouse and trackpad", subtitle: scroll.enabled ? nil : "Off — macOS’s single setting applies to both.", symbol: "arrow.up.arrow.down") {
                Toggle("", isOn: $scroll.enabled.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
            }
            if scroll.enabled {
                RowDivider()
                ScrollDiagram(scroll: scroll)
                    .padding(.horizontal, Space.standard)
                    .padding(.vertical, 12)
                RowDivider()
                SettingsRow(title: "Mouse", subtitle: "Direction for scroll wheels and Magic Mouse.", symbol: "computermouse") {
                    ChipPicker(selection: $scroll.mouseNatural, options: [(true, "Natural"), (false, "Standard")])
                }
                RowDivider()
                SettingsRow(title: "Trackpad", subtitle: "Direction for two-finger scrolling.", symbol: "rectangle.and.hand.point.up.left") {
                    ChipPicker(selection: $scroll.trackpadNatural, options: [(true, "Natural"), (false, "Standard")])
                }
                RowDivider()
                SettingsRow(title: "Sideways too", subtitle: "Use the same direction for horizontal scrolling.", symbol: "arrow.left.arrow.right") {
                    Toggle("", isOn: $scroll.horizontal).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Smooth wheel scrolling", subtitle: "Glide between notches instead of jumping a line at a time.", symbol: "water.waves") {
                    Toggle("", isOn: $scroll.smooth).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Lines per notch", subtitle: scroll.smooth ? "Off while smooth scrolling glides instead." : "Each click of the wheel scrolls exactly this far, however fast you turn it.", symbol: "list.number") {
                    ChipPicker(selection: $scroll.step, options: [(0, "Off"), (1, "1"), (3, "3"), (5, "5"), (8, "8")])
                        .disabled(scroll.smooth)
                }
                RowDivider()
                SettingsRow(title: "Wheel speed", subtitle: scroll.step > 0 && !scroll.smooth ? "Off while lines per notch is set." : "Mice only; trackpads keep their own feel.", symbol: "gauge.with.dots.needle.50percent") {
                    HStack(spacing: 8) {
                        Slider(value: $scroll.speed, in: 0.5...4, step: 0.25).frame(width: 140)
                            .disabled(scroll.step > 0 && !scroll.smooth)
                        Text(String(format: "%.2g×", scroll.speed))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                if !AXIsProcessTrusted() {
                    RowDivider()
                    SettingsRow(title: "Needs Accessibility", subtitle: "Orbit changes scroll events as they happen, which macOS allows only with Accessibility.", symbol: "exclamationmark.triangle") {
                        Button("Open Permissions") { MainWindow.show(.setup) }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }
        }
        .onAppear { scroll.refreshSystemSetting() }
    }
}

/// Two little devices; each arrow shows where the page goes when the fingers move down, and the
/// device that scrolled last lights up.
private struct ScrollDiagram: View {
    let scroll: ScrollReverser

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            HStack(spacing: 14) {
                card(.mouse, symbol: "computermouse", title: "Mouse", natural: scroll.mouseNatural, now: ctx.date)
                card(.trackpad, symbol: "rectangle.and.hand.point.up.left", title: "Trackpad", natural: scroll.trackpadNatural, now: ctx.date)
            }
        }
    }

    private func card(_ device: ScrollReverser.Device, symbol: String, title: String, natural: Bool, now: Date) -> some View {
        let live = scroll.lastDevice == device && (scroll.lastScroll.map { now.timeIntervalSince($0) < 1.5 } ?? false)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(live ? Palette.accent : Palette.ink)
                .frame(width: 34)
            // Fingers move down → the page moves down (natural) or up (standard).
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                Text("→").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                Image(systemName: "doc.plaintext").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                Image(systemName: natural ? "arrow.down" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(title.loc).font(.orbitBodyEmphasized)
                Text((live ? "Scrolling now" : natural ? "Natural" : "Standard").loc)
                    .font(.orbitCaption)
                    .foregroundStyle(live ? Palette.accent : Palette.inkSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised.opacity(live ? 1 : 0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(live ? Palette.accent.opacity(0.6) : .clear, lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: live)
    }
}
