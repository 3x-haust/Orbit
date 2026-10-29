import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Ring, launcher & clipboard
    static let ring = Self("ring", default: .init(.space, modifiers: [.control, .option]))
    static let launcher = Self("launcher", default: .init(.space, modifiers: [.option]))
    static let clipboard = Self("clipboard", default: .init(.v, modifiers: [.command, .shift]))
    static let snippets = Self("snippets", default: .init(.x, modifiers: [.option, .shift]))

    // Capture — mirrors macOS digits with ⌥⇧ so system ⇧⌘3/4/5 keep working.
    static let captureArea = Self("captureArea", default: .init(.four, modifiers: [.option, .shift]))
    static let captureScreen = Self("captureScreen", default: .init(.three, modifiers: [.option, .shift]))
    static let captureWindow = Self("captureWindow", default: .init(.five, modifiers: [.option, .shift]))
    static let captureText = Self("captureText", default: .init(.two, modifiers: [.option, .shift]))
    static let captureRepeat = Self("captureRepeat")
    static let captureScrolling = Self("captureScrolling")
    static let colorPicker = Self("colorPicker", default: .init(.c, modifiers: [.option, .shift]))
    static let shelf = Self("shelf", default: .init(.s, modifiers: [.option, .shift]))
    static let translate = Self("translate", default: .init(.t, modifiers: [.option, .shift]))

    // Window — Rectangle-compatible defaults.
    static let winLeft = Self("winLeft", default: .init(.leftArrow, modifiers: [.control, .option]))
    static let winRight = Self("winRight", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let winTop = Self("winTop", default: .init(.upArrow, modifiers: [.control, .option]))
    static let winBottom = Self("winBottom", default: .init(.downArrow, modifiers: [.control, .option]))
    static let winTopLeft = Self("winTopLeft", default: .init(.u, modifiers: [.control, .option]))
    static let winTopRight = Self("winTopRight", default: .init(.i, modifiers: [.control, .option]))
    static let winBottomLeft = Self("winBottomLeft", default: .init(.j, modifiers: [.control, .option]))
    static let winBottomRight = Self("winBottomRight", default: .init(.k, modifiers: [.control, .option]))
    static let winFirstThird = Self("winFirstThird", default: .init(.d, modifiers: [.control, .option]))
    static let winCenterThird = Self("winCenterThird", default: .init(.f, modifiers: [.control, .option]))
    static let winLastThird = Self("winLastThird", default: .init(.g, modifiers: [.control, .option]))
    static let winMaximize = Self("winMaximize", default: .init(.return, modifiers: [.control, .option]))
    static let winCenter = Self("winCenter", default: .init(.c, modifiers: [.control, .option]))
    static let winRestore = Self("winRestore", default: .init(.delete, modifiers: [.control, .option]))
    static let winNextDisplay = Self("winNextDisplay", default: .init(.rightArrow, modifiers: [.control, .option, .command]))
    static let winPreviousDisplay = Self("winPreviousDisplay", default: .init(.leftArrow, modifiers: [.control, .option, .command]))
}
