import AppKit
import EventKit
import IOBluetooth
import IOKit.ps
import SwiftUI

/// Things that happen on their own and show up in the notch: power, Focus, Bluetooth devices,
/// downloads. Every source is event-driven and only installed while its activity is turned on.
@MainActor @Observable
final class NotchLive {
    static let shared = NotchLive()

    /// For the open notch's battery chip; nil on desktops.
    private(set) var battery: BatteryState?

    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var focusObservers: [Any] = []
    @ObservationIgnored private var bluetooth: NotchBluetooth?
    @ObservationIgnored private var config: NotchCenter.Config?

    private init() {}

    /// nil turns everything off.
    func apply(_ config: NotchCenter.Config?) {
        self.config = config
        let on = config != nil

        if on, powerSource == nil {
            battery = Battery.read()
            let source = IOPSNotificationCreateRunLoopSource({ _ in
                MainActor.assumeIsolated { NotchLive.shared.powerChanged() }
            }, nil)?.takeRetainedValue()
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                powerSource = source
            }
        } else if !on, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
        }

        let focus = config?.live.contains(NotchPrefs.liveFocus) == true
        if focus, focusObservers.isEmpty {
            let dnc = DistributedNotificationCenter.default()
            for (name, enabled) in [("_NSDoNotDisturbEnabledNotification", true), ("_NSDoNotDisturbDisabledNotification", false)] {
                focusObservers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { NotchLive.shared.focusChanged(enabled) }
                })
            }
        } else if !focus {
            focusObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            focusObservers.removeAll()
        }

        let bt = config?.live.contains(NotchPrefs.liveBluetooth) == true
        if bt, bluetooth == nil { bluetooth = NotchBluetooth() } else if !bt { bluetooth?.stop(); bluetooth = nil }

        NotchDownloads.shared.watch(config?.live.contains(NotchPrefs.liveDownloads) == true)
    }

    private func powerChanged() {
        let before = battery
        battery = Battery.read()
        guard let now = battery, config?.live.contains(NotchPrefs.liveCharging) == true else { return }
        if now.onAC, before?.onAC == false {
            NotchCenter.shared.flash(ear: .charging(true), for: 3)
        } else if !now.onAC, before?.onAC == true {
            NotchCenter.shared.flash(ear: .charging(false), for: 2)
        }
    }

    private func focusChanged(_ on: Bool) {
        NotchCenter.shared.flash(.init(symbol: on ? "moon.fill" : "moon", tint: on ? .indigo : .white.opacity(0.8),
                                       title: on ? "Focus On" : "Focus Off", detail: nil, trailing: nil), for: 2.2)
    }
}

// MARK: - Bluetooth

/// Connect and disconnect notices, with battery levels when the device reports them (AirPods: each
/// bud and the case). IOBluetooth tells about every connection — classic and the AirPods' audio link
/// — on the main run loop; its battery figures arrive a moment after the link, so the notice waits
/// for them briefly. One notice per device per connection, however many times the link flaps.
final class NotchBluetooth: NSObject {
    private var connect: IOBluetoothUserNotification?
    private var disconnects: [String: IOBluetoothUserNotification] = [:]
    /// When each device last got a notice, so a flapping link doesn't repeat it.
    private var shown: [String: Date] = [:]
    /// IOBluetooth reports every device that's already connected right after registering.
    private let started = Date()

    override init() {
        super.init()
        connect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    func stop() {
        connect?.unregister()
        connect = nil
        disconnects.values.forEach { $0.unregister() }
        disconnects.removeAll()
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? "?"
        if disconnects[key] == nil, let n = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
            disconnects[key] = n
        }
        guard Date().timeIntervalSince(started) > 3 else { return }
        if let last = shown[key], Date().timeIntervalSince(last) < 15 { return }
        shown[key] = Date()
        // Give the battery figures a moment to arrive, but not so long the notice feels late.
        tellWhenReady(device, key: key, tries: 0)
    }

    private func tellWhenReady(_ device: IOBluetoothDevice, key: String, tries: Int) {
        let levels = Self.levels(of: device)
        if levels.isEmpty, tries < 4, Self.reportsBattery(device) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tellWhenReady(device, key: key, tries: tries + 1) }
            return
        }
        let name = device.name ?? "Device".loc
        let symbol = Self.symbol(for: device)
        Task { @MainActor in
            NotchCenter.shared.flash(.init(symbol: symbol, tint: .accentColor, title: "Connected", detail: name,
                                           trailing: nil, levels: levels), for: 3.2)
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        let key = device.addressString ?? device.name ?? "?"
        disconnects[key] = nil
        shown[key] = nil
        let name = device.name ?? "Device".loc
        let symbol = Self.symbol(for: device)
        Task { @MainActor in
            NotchCenter.shared.flash(.init(symbol: symbol, tint: .white.opacity(0.6), title: "Disconnected", detail: name, trailing: nil), for: 2)
        }
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods.gen3" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") { return "magicmouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }

    /// Apple devices answer these (not public API, so each is checked before it's asked).
    private static func number(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)), let n = device.value(forKey: key) as? NSNumber,
              n.intValue > 0, n.intValue <= 100 else { return nil }
        return n.intValue
    }

    private static func reportsBattery(_ device: IOBluetoothDevice) -> Bool {
        device.responds(to: NSSelectorFromString("batteryPercentSingle")) && ((device.name ?? "").lowercased().contains("airpods")
            || (device.name ?? "").lowercased().contains("beats") || device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio))
    }

    /// Left, right and case for AirPods; one level for everything else.
    static func levels(of device: IOBluetoothDevice) -> [NotchCenter.Peek.Level] {
        let pro = (device.name ?? "").lowercased().contains("pro")
        var out: [NotchCenter.Peek.Level] = []
        if let l = number(device, "batteryPercentLeft") { out.append(.init(symbol: "airpod.left", percent: l)) }
        if let r = number(device, "batteryPercentRight") { out.append(.init(symbol: "airpod.right", percent: r)) }
        if !out.isEmpty {
            if let c = number(device, "batteryPercentCase") {
                out.append(.init(symbol: pro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill", percent: c))
            }
            return out
        }
        for key in ["batteryPercentCombined", "batteryPercentSingle", "headsetBattery"] {
            if let n = number(device, key) { return [.init(symbol: "battery.75percent", percent: n)] }
        }
        return []
    }
}

// MARK: - Timer

/// Quick timers and pomodoro. No ticking of its own: the views count down from the end date, and a
/// single scheduled block fires at the end.
@MainActor @Observable
final class NotchTimer {
    static let shared = NotchTimer()

    enum Kind { case plain, focus, rest }

    private(set) var end: Date?
    private(set) var pausedLeft: TimeInterval?
    private(set) var total: TimeInterval = 0
    private(set) var kind: Kind = .plain
    private(set) var round = 1
    var pomodoro: Bool { kind != .plain }

    var isRunning: Bool { end != nil || pausedLeft != nil }
    var isPaused: Bool { pausedLeft != nil }

    var label: String {
        switch kind {
        case .plain: "Timer"
        case .focus: "Focus"
        case .rest: "Break"
        }
    }

    @ObservationIgnored private var work: DispatchWorkItem?

    private init() {}

    func remaining(at date: Date = .now) -> TimeInterval {
        if let pausedLeft { return pausedLeft }
        guard let end else { return 0 }
        return max(0, end.timeIntervalSince(date))
    }

    func start(minutes: Double) {
        kind = .plain
        run(minutes * 60)
    }

    func startPomodoro() {
        round = 1
        kind = .focus
        run(25 * 60)
    }

    func pause() {
        guard let end else { return }
        pausedLeft = max(0, end.timeIntervalSinceNow)
        self.end = nil
        work?.cancel()
    }

    func resume() {
        guard let left = pausedLeft else { return }
        pausedLeft = nil
        schedule(left)
    }

    func add(minutes: Double) {
        let s = minutes * 60
        total += s
        if let left = pausedLeft { pausedLeft = left + s } else if let end { schedule(end.timeIntervalSinceNow + s) }
    }

    func stop() {
        work?.cancel()
        end = nil
        pausedLeft = nil
        kind = .plain
    }

    private func run(_ seconds: TimeInterval) {
        total = seconds
        pausedLeft = nil
        schedule(seconds)
    }

    private func schedule(_ seconds: TimeInterval) {
        work?.cancel()
        end = Date().addingTimeInterval(seconds)
        let w = DispatchWorkItem { [weak self] in self?.finished() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func finished() {
        NSSound(named: "Glass")?.play()
        switch kind {
        case .plain:
            end = nil
            NotchCenter.shared.flash(.init(symbol: "timer", tint: Palette.brand, title: "Time's Up", detail: nil, trailing: NotchTimer.clock(total)), for: 4)
        case .focus:
            kind = .rest
            run(5 * 60)
            NotchCenter.shared.flash(.init(symbol: "cup.and.saucer.fill", tint: .green, title: "Take a Break", detail: "5 min".loc, trailing: nil), for: 4)
        case .rest:
            round += 1
            kind = .focus
            run(25 * 60)
            NotchCenter.shared.flash(.init(symbol: "leaf.fill", tint: Palette.brand, title: "Back to Focus", detail: "Round %ld".loc(round), trailing: nil), for: 4)
        }
    }

    /// 4:05, 1:02:09
    nonisolated static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 25m, 1h
    nonisolated static func short(_ t: TimeInterval) -> String {
        let m = max(0, Int((t / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60)h" : "\(m)m"
    }
}

// MARK: - Downloads

/// Files still downloading in ~/Downloads (Safari's .download, Chrome's .crdownload, Firefox's
/// .part). The folder is watched for changes; sizes are only re-read while something is downloading.
@MainActor @Observable
final class NotchDownloads {
    static let shared = NotchDownloads()

    struct Item: Equatable {
        var url: URL
        var bytes: Int64
        /// The name it will have once done.
        var finalName: String
    }

    private(set) var items: [Item] = []

    var summary: String {
        guard let biggest = items.max(by: { $0.bytes < $1.bytes }) else { return "" }
        return items.count > 1 ? "\(items.count)×" : ByteCountFormatter.string(fromByteCount: biggest.bytes, countStyle: .file)
    }

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var tick: Timer?
    private static let extensions: Set<String> = ["download", "crdownload", "part", "partial"]
    private static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads") }

    private init() {}

    func watch(_ on: Bool) {
        if on, source == nil {
            let fd = open(Self.folder.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { NotchDownloads.shared.scan() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
            scan()
        } else if !on, let s = source {
            s.cancel()
            source = nil
            tick?.invalidate()
            tick = nil
            items = []
        }
    }

    private func scan() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        let now = names.compactMap { name -> Item? in
            let url = Self.folder.appendingPathComponent(name)
            guard Self.extensions.contains(url.pathExtension.lowercased()) else { return nil }
            return Item(url: url, bytes: Self.size(of: url), finalName: url.deletingPathExtension().lastPathComponent)
        }
        // Anything that vanished and left its finished file behind is done.
        for old in items where !now.contains(where: { $0.url == old.url }) {
            if fm.fileExists(atPath: Self.folder.appendingPathComponent(old.finalName).path) {
                NotchCenter.shared.flash(.init(symbol: "checkmark.circle.fill", tint: .green, title: "Downloaded", detail: old.finalName, trailing: nil))
            }
        }
        if now != items { withAnimation(NotchCenter.morph) { items = now } }
        if now.isEmpty {
            tick?.invalidate()
            tick = nil
        } else if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { NotchDownloads.shared.scan() }
            }
        }
    }

    /// Safari's .download is a folder.
    nonisolated private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.fileSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }
}

// MARK: - Calendar

/// What's left of today, for the Home tab. Read when the tab appears, never in the background.
@MainActor @Observable
final class NotchCalendar {
    static let shared = NotchCalendar()

    private(set) var events: [EKEvent] = []
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    @ObservationIgnored private lazy var store = EKEventStore()
    @ObservationIgnored private var loadedAt: Date?

    private init() {}

    func load() {
        #if DEBUG
        if debugPlaceholders { return }
        #endif
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        loadedAt = Date()
        let cal = Calendar.current
        let now = Date()
        let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now.addingTimeInterval(3600 * 12)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        events = store.events(matching: predicate).sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    func requestAccess() {
        if access == .denied || access == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                NotchCalendar.shared.loadedAt = nil
                NotchCalendar.shared.load()
            }
        }
    }

    #if DEBUG
    @ObservationIgnored private var debugPlaceholders = false

    /// Debug: made-up events in place of the user's, for promo frames; nil goes back to the real ones.
    func debugPlaceholder(_ items: [(title: String, hour: Int, minute: Int, minutes: Int)]?) {
        guard let items else {
            debugPlaceholders = false
            loadedAt = nil
            load()
            return
        }
        debugPlaceholders = true
        access = .fullAccess
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.cgColor = NSColor(Palette.brand).cgColor
        let cal = Calendar.current
        events = items.map { item in
            let e = EKEvent(eventStore: store)
            e.calendar = calendar
            e.title = item.title
            e.startDate = cal.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: Date()) ?? Date()
            e.endDate = e.startDate.addingTimeInterval(Double(item.minutes) * 60)
            return e
        }
    }
    #endif

    static func when(_ e: EKEvent) -> String {
        if e.isAllDay { return "All day".loc }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        let start = e.startDate.formatted(f)
        let mins = Int(e.startDate.timeIntervalSinceNow / 60)
        if mins > 0, mins < 60 { return "%@ · in %ld min".loc(start, mins) }
        if mins <= 0 { return "Now · until %@".loc(e.endDate.formatted(f)) }
        return "\(start) – \(e.endDate.formatted(f))"
    }
}
