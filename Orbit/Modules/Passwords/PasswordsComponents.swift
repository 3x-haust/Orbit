import AppKit
import SwiftUI
import Observation

/// What the Passwords page is showing, shared so Quick Access can open an item there.
@MainActor @Observable
final class PasswordsUI {
    static let shared = PasswordsUI()

    enum Section: Hashable {
        case all, favorites, kind(VaultItem.Kind), tag(String), watchtower, settings
    }

    var section: Section = .all
    var selectedID: UUID?
    var editing: VaultItem?
    var search = ""

    func select(_ item: VaultItem) {
        section = .all
        search = ""
        selectedID = item.id
        editing = nil
    }
}

/// A monogram tile: the site's first letter, or the kind's symbol.
struct ItemIcon: View {
    let item: VaultItem
    var size: CGFloat = 32

    var body: some View {
        let letter = (item.hosts.first ?? item.title).first.map { String($0).uppercased() }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint)
            if item.kind == .login, let letter {
                Text(letter).font(.system(size: size * 0.46, weight: .bold, design: .rounded)).foregroundStyle(.white)
            } else {
                Image(systemName: item.kind.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    /// A steady colour per site, all muted so the page stays black and white.
    private var tint: Color {
        guard item.kind == .login else { return Color(white: 0.24) }
        let key = item.hosts.first ?? item.title
        let hue = Double(abs(key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 })) / 997
        return Color(hue: hue, saturation: 0.35, brightness: 0.42)
    }
}

/// A live one-time code with its countdown ring.
struct TOTPView: View {
    let totp: String
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let t = TOTP(totp) {
                let code = t.code(at: context.date)
                let left = t.secondsLeft(at: context.date)
                HStack(spacing: Space.compact) {
                    Text(code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code)
                        .font(.system(size: compact ? 15 : 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(left <= 5 ? Palette.accent : Palette.ink)
                    ZStack {
                        Circle().stroke(Palette.hairline, lineWidth: 2.5)
                        Circle().trim(from: 0, to: CGFloat(left) / CGFloat(t.period))
                            .stroke(left <= 5 ? Palette.accent : Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(left)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                    }
                    .frame(width: 18, height: 18)
                }
            } else {
                Text("Invalid code setup").font(.orbitCaption).foregroundStyle(Palette.accent)
            }
        }
    }
}

/// Strength as a five-step bar with its word.
struct StrengthBar: View {
    let password: String

    var body: some View {
        let level = PasswordStrength.level(password)
        HStack(spacing: Space.compact) {
            HStack(spacing: 3) {
                ForEach(0..<5) { i in
                    Capsule().fill(i <= level.rawValue && !password.isEmpty ? color(level) : Palette.raised).frame(height: 4)
                }
            }
            .frame(width: 120)
            Text(password.isEmpty ? "" : level.title.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func color(_ l: PasswordStrength.Level) -> Color {
        switch l {
        case .terrible, .weak: Palette.accent
        case .fair: Palette.inkSecondary
        case .good, .great: Palette.ink
        }
    }
}

/// The lock screen, used by the page and Quick Access.
struct LockedCard: View {
    var compact = false
    var busy = false
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool
    private var vault: Vault { Vault.shared }

    var body: some View {
        VStack(spacing: compact ? Space.related : Space.standard) {
            Image(systemName: "lock.fill")
                .font(.system(size: compact ? 24 : 30, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: compact ? 52 : 64, height: compact ? 52 : 64)
                .background(Circle().fill(Palette.raised))
            Text("Orbit Passwords is locked").font(compact ? .orbitSection : .orbitTitle)
            if vault.secretKeyMissing {
                Text("This Mac doesn’t have the vault’s Secret Key. Restore it from your Emergency Kit on the Passwords page.")
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            } else {
                HStack(spacing: Space.compact) {
                    SecureField("Master Password", text: $password)
                        .textFieldStyle(.plain)
                        .font(.orbitBody)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(error == nil ? Palette.hairline : Palette.accent, lineWidth: 1))
                        .focused($focused)
                        .onSubmit(unlock)
                        .frame(width: 260)
                    Button(action: unlock) {
                        Image(systemName: working ? "ellipsis" : "arrow.right").font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(Palette.canvas)
                            .background(Circle().fill(Palette.ink))
                    }
                    .buttonStyle(.plain)
                    .disabled(password.isEmpty || working)
                }
                if let error { Text(error).font(.orbitCaption).foregroundStyle(Palette.accent) }
                HStack(spacing: Space.compact) {
                    if vault.canUseTouchID {
                        Button { Task { await vault.unlockWithTouchID() } } label: { Label("Touch ID", systemImage: "touchid") }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    if vault.canUseFace {
                        Button { vault.unlockWithFace() } label: { Label("Face", systemImage: "faceid") }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
                if vault.masterDue, vault.touchIDEnabled {
                    Text("It’s been two weeks — enter your Master Password so you don’t forget it.")
                        .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(compact ? Space.group : Space.major)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        let attempt = password
        Task {
            do {
                try await vault.unlock(password: attempt)
                password = ""
            } catch {
                self.error = "That’s not the Master Password.".loc
                password = ""
                focused = true
            }
            working = false
        }
    }
}

/// Generator controls; `onUse` takes the password into an item.
struct GeneratorView: View {
    var onUse: ((String) -> Void)?
    @State private var options = Vault.shared.generatorOptions
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.compact) {
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: "arrow.clockwise", help: "New password") { regenerate() }
                IconButton(symbol: "doc.on.doc", help: "Copy") { Vault.shared.copy(value, what: "Password") }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
            HStack {
                Text("%.0f bits".loc(PasswordGenerator.entropy(options))).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                Spacer()
                Picker("", selection: $options.style) {
                    ForEach(PasswordGenerator.Style.allCases) { Text($0.title.loc).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            switch options.style {
            case .random:
                stepper("Length", value: $options.length, range: 8...64)
                Toggle("Numbers", isOn: $options.digits)
                Toggle("Symbols", isOn: $options.symbols)
                Toggle("Avoid look-alike characters", isOn: $options.avoidAmbiguous)
            case .memorable:
                stepper("Words", value: $options.words, range: 3...10)
                Picker("Separator", selection: $options.separator) {
                    Text("-").tag("-"); Text(".").tag("."); Text("_").tag("_"); Text("Space".loc).tag(" ")
                }
                Toggle("Capitalize", isOn: $options.capitalize)
                Toggle("Add a number", isOn: $options.digits)
            case .pin:
                stepper("Digits", value: $options.pinLength, range: 4...12)
            }
            if let onUse {
                HStack { Spacer(); Button("Use Password") { onUse(value) }.buttonStyle(PillButtonStyle()) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.orbitBody)
        .onAppear { if value.isEmpty { regenerate() } }
        .onChange(of: options) { Vault.shared.generatorOptions = options; regenerate() }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title.loc)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)").font(.orbitBody.monospacedDigit()).frame(width: 26, alignment: .trailing)
        }
    }

    private func regenerate() { value = PasswordGenerator.make(options) }
}
