import Foundation
import IOKit.pwr_mgt

/// Runs as root (a launchd daemon Orbit registers through SMAppService) and writes fan targets to the SMC
/// for Orbit only. Every fan goes back to macOS when Orbit disconnects, stops renewing, or the helper stops.
final class Service: NSObject, FanHelperProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "com.lyu.orbit.fanhelper.smc")
    /// Fans under manual control and when Orbit last renewed each one.
    private var leases: [Int: Date] = [:]
    private var watchdog: DispatchSourceTimer?
    private lazy var charge = ChargeGuard(queue: queue)

    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var rootPort: io_connect_t = 0

    override init() {
        super.init()
        queue.async { self.charge.start() }
        watchSleep()
    }

    /// System sleep and wake, straight from IOKit (a daemon gets no NSWorkspace notifications).
    private func watchSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &powerPort, { context, _, message, argument in
            guard let context else { return }
            let me = Unmanaged<Service>.fromOpaque(context).takeUnretainedValue()
            switch message {
            case 0xE000_0280: // kIOMessageSystemWillSleep (a C macro Swift can't import)
                me.queue.sync { me.charge.willSleep() }
                IOAllowPowerChange(me.rootPort, Int(bitPattern: argument))
            case 0xE000_0270: // kIOMessageCanSystemSleep
                IOAllowPowerChange(me.rootPort, Int(bitPattern: argument))
            case 0xE000_0300: // kIOMessageSystemHasPoweredOn
                me.queue.async { me.charge.didWake() }
            default: break
            }
        }, &powerNotifier)
        if let powerPort { IONotificationPortSetDispatchQueue(powerPort, DispatchQueue(label: "com.lyu.orbit.fanhelper.power")) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.queue.async {
                self?.releaseAll()
                self?.charge.clientGone()
            }
        }
        connection.resume()
        return true
    }

    func version(reply: @escaping (Int) -> Void) { reply(FanHelper.version) }

    func setFan(_ fan: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let info = SMC.shared.fans().first(where: { $0.id == fan }) else { return reply("No fan \(fan)") }
            let hot = (SMC.shared.temperatures().chip ?? 0) >= FanHelper.hotLimit
            guard SMC.shared.setManual(fan: fan, rpm: hot ? info.max : rpm) else { return reply("The SMC refused the new speed") }
            self.leases[fan] = Date()
            self.startWatchdog()
            reply(nil)
        }
    }

    func setAutomatic(_ fan: Int, reply: @escaping (String?) -> Void) {
        queue.async {
            self.leases[fan] = nil
            reply(SMC.shared.setAutomatic(fan: fan) ? nil : "The SMC refused automatic mode")
        }
    }

    func setSleepDisabled(_ on: Bool, reply: @escaping (String?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        do {
            try p.run()
            p.waitUntilExit()
            reply(p.terminationStatus == 0 ? nil : "pmset exited with \(p.terminationStatus)")
        } catch {
            reply(error.localizedDescription)
        }
    }

    func setChargePolicy(limit: Int, floor: Int, heatLimit: Double, led: Int, asleep: Bool, reply: @escaping (String?) -> Void) {
        queue.async { reply(self.charge.setPolicy(limit: limit, floor: floor, heatLimit: heatLimit, led: led, asleep: asleep)) }
    }

    func setDischarge(to target: Int, reply: @escaping (String?) -> Void) {
        queue.async { reply(self.charge.setDischarge(to: target)) }
    }

    func chargeState(reply: @escaping (String) -> Void) {
        queue.async { reply(self.charge.state()) }
    }

    func releaseAll() {
        for fan in SMC.shared.fans() { SMC.shared.setAutomatic(fan: fan.id) }
        leases.removeAll()
    }

    /// Hands lapsed fans back to macOS, and keeps the rest at full speed while the chip is too hot.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for (fan, renewed) in self.leases where Date().timeIntervalSince(renewed) > FanHelper.leaseSeconds {
                self.leases[fan] = nil
                SMC.shared.setAutomatic(fan: fan)
            }
            if (SMC.shared.temperatures().chip ?? 0) >= FanHelper.hotLimit {
                for fan in SMC.shared.fans() where self.leases[fan.id] != nil { SMC.shared.setManual(fan: fan.id, rpm: fan.max) }
            }
        }
        timer.resume()
        watchdog = timer
    }

    func stop() {
        queue.sync {
            releaseAll()
            charge.restoreNormal()
        }
    }
}

let service = Service()
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    service.stop()
    exit(0)
}
termination.resume()

let listener = NSXPCListener(machServiceName: FanHelper.label)
listener.setConnectionCodeSigningRequirement(FanHelper.clientRequirement)
listener.delegate = service
listener.resume()
dispatchMain()
