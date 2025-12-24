import SwiftUI
import UIKit
import GhosttyKit
import os.log

// MARK: - Font Size Preference

/// Manages the persisted font size preference for terminals
enum FontSizePreference {
    private static let key = "terminalFontSize"
    private static let defaultSize: Float = 11.0
    private static let minSize: Float = 6.0
    private static let maxSize: Float = 36.0

    /// Get the saved font size, or default if not set
    static var current: Float {
        let saved = UserDefaults.standard.float(forKey: key)
        // Return default if not set (0 means not set)
        return saved > 0 ? saved : defaultSize
    }

    /// Save a new font size preference
    static func save(_ size: Float) {
        let clamped = max(minSize, min(maxSize, size))
        UserDefaults.standard.set(clamped, forKey: key)
        Logger.clauntty.info("Font size preference saved: \(clamped)")
    }

    /// Reset to default
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// SwiftUI wrapper for the Ghostty terminal surface
/// Based on: ~/Projects/ghostty/macos/Sources/Ghostty/SurfaceView_UIKit.swift
struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var ghosttyApp: GhosttyApp

    /// Whether this terminal is currently the active tab
    var isActive: Bool = true

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)?

    /// Callback when terminal grid size changes (rows, columns)
    var onTerminalSizeChanged: ((UInt16, UInt16) -> Void)?

    /// Callback to provide SSH output writer to the view
    var onSurfaceReady: ((TerminalSurfaceView) -> Void)?

    func makeUIView(context: Context) -> TerminalSurfaceView {
        guard let app = ghosttyApp.app else {
            Logger.clauntty.error("Cannot create TerminalSurfaceView: GhosttyApp not initialized")
            return TerminalSurfaceView(frame: .zero, app: nil)
        }
        // Start with zero frame - SwiftUI will size it properly via layoutSubviews
        let view = TerminalSurfaceView(frame: .zero, app: app)
        view.onTextInput = onTextInput
        view.onTerminalSizeChanged = onTerminalSizeChanged
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        onSurfaceReady?(view)
        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {
        // Update callbacks if they changed
        uiView.onTextInput = onTextInput
        uiView.onTerminalSizeChanged = onTerminalSizeChanged

        // Handle focus changes when active state changes
        uiView.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: TerminalSurface

        init(_ parent: TerminalSurface) {
            self.parent = parent
        }
    }
}

/// UIKit view that hosts the Ghostty terminal
/// Uses CAMetalLayer for GPU-accelerated rendering
class TerminalSurfaceView: UIView, ObservableObject, UIKeyInput, UITextInputTraits {

    // MARK: - Surface Registry (for routing Ghostty callbacks)

    /// Registry to look up surfaces by pointer (for routing Ghostty action callbacks)
    private static var surfaceRegistry: [UnsafeRawPointer: TerminalSurfaceView] = [:]

    /// Look up surface view by Ghostty surface pointer
    static func find(surface: ghostty_surface_t) -> TerminalSurfaceView? {
        let ptr = UnsafeRawPointer(surface)
        return surfaceRegistry[ptr]
    }

    // MARK: - Published Properties

    @Published var title: String = "Terminal"
    @Published var healthy: Bool = true
    @Published var error: Error? = nil

    // MARK: - Ghostty Surface

    private(set) var surface: ghostty_surface_t?

    // MARK: - Terminal Size

    /// Current terminal grid size (rows, columns)
    private(set) var terminalSize: (rows: UInt16, columns: UInt16) = (24, 80)

    /// Callback when terminal grid size changes (for SSH window resize)
    var onTerminalSizeChanged: ((UInt16, UInt16) -> Void)?

    /// Callback when terminal sets title via OSC escape sequence
    var onTitleChanged: ((String) -> Void)?

    // MARK: - Font Size

    /// Current font size in points (tracked for persistence)
    private var currentFontSize: Float = FontSizePreference.current

    // MARK: - UITextInputTraits

    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // MARK: - SSH Data Flow

    /// Callback for keyboard input - send this data to SSH
    var onTextInput: ((Data) -> Void)? {
        didSet {
            // Also wire up the accessory bar
            accessoryBar.onKeyInput = onTextInput
        }
    }

    /// Keyboard accessory bar with terminal keys
    private let accessoryBar = KeyboardAccessoryView(frame: CGRect(x: 0, y: 0, width: 0, height: 48))

    override var inputAccessoryView: UIView? {
        return accessoryBar
    }

    // MARK: - Initialization

    init(frame: CGRect, app: ghostty_app_t?) {
        super.init(frame: frame)
        setupView()

        guard let app = app else {
            Logger.clauntty.error("TerminalSurfaceView: No app provided")
            return
        }

        // Create surface configuration for iOS
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = UIScreen.main.scale
        // Use saved font size preference, or default if not set
        config.font_size = FontSizePreference.current

        // Create the surface
        guard let surface = ghostty_surface_new(app, &config) else {
            Logger.clauntty.error("ghostty_surface_new failed")
            return
        }

        self.surface = surface

        // Register in static registry for Ghostty callback routing
        let ptr = UnsafeRawPointer(surface)
        Self.surfaceRegistry[ptr] = self

        Logger.clauntty.info("Terminal surface created successfully")
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let surface = self.surface {
            // Unregister from static registry
            let ptr = UnsafeRawPointer(surface)
            Self.surfaceRegistry.removeValue(forKey: ptr)

            ghostty_surface_free(surface)
        }
    }

    // MARK: - Keyboard Handling

    /// Current keyboard height (0 when hidden)
    private var keyboardHeight: CGFloat = 0

    private func setupKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        // Get keyboard height relative to our view
        let keyboardFrameInView = convert(keyboardFrame, from: nil)
        let intersection = bounds.intersection(keyboardFrameInView)
        let newKeyboardHeight = intersection.height

        if newKeyboardHeight != keyboardHeight {
            keyboardHeight = newKeyboardHeight
            Logger.clauntty.info("Keyboard shown, height: \(newKeyboardHeight)")
            updateSizeForKeyboard()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        if keyboardHeight != 0 {
            keyboardHeight = 0
            Logger.clauntty.info("Keyboard hidden")
            updateSizeForKeyboard()
        }
    }

    private func updateSizeForKeyboard() {
        // Recalculate size accounting for keyboard
        // The effective height is reduced by keyboard height
        let effectiveSize = CGSize(
            width: bounds.width,
            height: bounds.height - keyboardHeight
        )
        sizeDidChange(effectiveSize)
    }

    private func setupView() {
        // Configure for Metal rendering - use Ghostty's default background color (#282C34)
        // From ghostty/src/config/Config.zig: background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 }
        backgroundColor = UIColor(red: 40/255.0, green: 44/255.0, blue: 52/255.0, alpha: 1.0) // #282C34

        // Enable user interaction for keyboard
        isUserInteractionEnabled = true

        // Listen for keyboard show/hide to resize terminal
        setupKeyboardNotifications()

        // Add tap gesture for keyboard and paste menu
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)

        // Add scroll gesture (one-finger drag to scroll terminal history)
        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.minimumNumberOfTouches = 1
        scrollGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(scrollGesture)

        // Add long press gesture for text selection
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.3
        addGestureRecognizer(longPressGesture)

        // Allow scroll and long press to work together
        scrollGesture.require(toFail: longPressGesture)
        tapGesture.require(toFail: longPressGesture)

        // Add pinch gesture for font resizing
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchGesture)
    }

    // MARK: - Pinch to Zoom (Font Resize)

    /// Accumulated scale for pinch gesture
    private var pinchAccumulatedScale: CGFloat = 1.0

    /// Threshold for triggering a font size change
    private let pinchScaleThreshold: CGFloat = 0.15

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let surface = self.surface else { return }

        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1.0

        case .changed:
            let scale = gesture.scale
            gesture.scale = 1.0  // Reset for incremental tracking

            pinchAccumulatedScale *= scale

            // Check if we've crossed a threshold
            if pinchAccumulatedScale > 1.0 + pinchScaleThreshold {
                // Increase font size
                increaseFontSize(surface: surface)
                pinchAccumulatedScale = 1.0
            } else if pinchAccumulatedScale < 1.0 - pinchScaleThreshold {
                // Decrease font size
                decreaseFontSize(surface: surface)
                pinchAccumulatedScale = 1.0
            }

        case .ended, .cancelled:
            pinchAccumulatedScale = 1.0

        default:
            break
        }
    }

    private func increaseFontSize(surface: ghostty_surface_t) {
        let action = "increase_font_size:1"
        let success = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        if success {
            currentFontSize = min(currentFontSize + 1, 36)
            FontSizePreference.save(currentFontSize)
            let newSize = currentFontSize
            Logger.clauntty.debug("Font size increased to \(newSize)")
            // Notify SSH of new terminal size after font change
            notifyTerminalSizeChanged(surface: surface)
        }
    }

    private func decreaseFontSize(surface: ghostty_surface_t) {
        let action = "decrease_font_size:1"
        let success = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        if success {
            currentFontSize = max(currentFontSize - 1, 6)
            FontSizePreference.save(currentFontSize)
            let newSize = currentFontSize
            Logger.clauntty.debug("Font size decreased to \(newSize)")
            // Notify SSH of new terminal size after font change
            notifyTerminalSizeChanged(surface: surface)
        }
    }

    /// Reset font size to default (11pt)
    func resetFontSize() {
        guard let surface = self.surface else { return }
        let action = "reset_font_size"
        let success = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        if success {
            currentFontSize = 11.0
            FontSizePreference.reset()
            Logger.clauntty.info("Font size reset to default")
            // Notify SSH of new terminal size after font change
            notifyTerminalSizeChanged(surface: surface)
        }
    }

    /// Query new terminal size and notify callback if changed
    private func notifyTerminalSizeChanged(surface: ghostty_surface_t) {
        // Small delay to let Ghostty recalculate after font change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            let surfaceSize = ghostty_surface_size(surface)
            let newRows = surfaceSize.rows
            let newCols = surfaceSize.columns

            if newRows != self.terminalSize.rows || newCols != self.terminalSize.columns {
                self.terminalSize = (newRows, newCols)
                Logger.clauntty.info("Font change: terminal now \(newCols)x\(newRows)")
                self.onTerminalSizeChanged?(newRows, newCols)
            }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)

        // Clear any existing selection
        clearSelection()

        // If edit menu is visible, dismiss it and don't show a new one
        if isEditMenuVisible {
            dismissEditMenu()
            return
        }

        // Become first responder to show keyboard
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }

        // Only show paste menu if tapping near the cursor and clipboard has content
        if isNearCursor(location) && UIPasteboard.general.hasStrings {
            showEditMenu(at: location)
        }
    }

    /// Check if a point is near the cursor position
    private func isNearCursor(_ point: CGPoint) -> Bool {
        guard let surface = self.surface else { return false }

        // Get cursor position from Ghostty (IME point = cursor location)
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // Define a hit area around the cursor (generous for touch)
        let hitRadius: CGFloat = 50.0
        let cursorRect = CGRect(
            x: CGFloat(x) - hitRadius,
            y: CGFloat(y) - hitRadius,
            width: CGFloat(width) + hitRadius * 2,
            height: CGFloat(height) + hitRadius * 2
        )

        return cursorRect.contains(point)
    }

    /// Clear the current selection by simulating a click
    private func clearSelection() {
        guard let surface = self.surface else { return }
        // A click (press + release at same spot) clears selection
        ghostty_surface_mouse_pos(surface, 0, 0, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    // MARK: - Selection & Copy/Paste

    /// Track if we're in selection mode
    private var isSelecting = false

    /// Track if edit menu is currently visible
    private var isEditMenuVisible = false

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let surface = self.surface else { return }

        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            // Start selection with mouse press at location
            isSelecting = true
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)

        case .changed:
            // Update selection as finger moves
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)

        case .ended:
            // End selection
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            isSelecting = false

            // Show edit menu if there's a selection
            if ghostty_surface_has_selection(surface) {
                showEditMenu(at: location)
            }

        case .cancelled:
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            isSelecting = false

        default:
            break
        }
    }

    private func showEditMenu(at location: CGPoint) {
        // Use UIEditMenuInteraction (iOS 16+)
        let menuConfig = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        if let interaction = interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
            interaction.presentEditMenu(with: menuConfig)
        } else {
            let editInteraction = UIEditMenuInteraction(delegate: self)
            addInteraction(editInteraction)
            editInteraction.presentEditMenu(with: menuConfig)
        }
        isEditMenuVisible = true
    }

    private func dismissEditMenu() {
        if let interaction = interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
            interaction.dismissMenu()
        }
        isEditMenuVisible = false
    }

    // MARK: - UIResponder Copy/Paste

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return surface != nil && ghostty_surface_has_selection(surface!)
        }
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        if action == #selector(selectAll(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc override func copy(_ sender: Any?) {
        guard let surface = self.surface else { return }

        var text = ghostty_text_s()
        if ghostty_surface_read_selection(surface, &text) {
            if let ptr = text.text, text.text_len > 0 {
                let string = String(cString: ptr)
                UIPasteboard.general.string = string
                Logger.clauntty.info("Copied \(text.text_len) characters to clipboard")
            }
            ghostty_surface_free_text(surface, &text)
        }

        // Clear selection after copying
        clearSelection()
    }

    @objc override func paste(_ sender: Any?) {
        guard let string = UIPasteboard.general.string else { return }
        if let data = string.data(using: .utf8) {
            onTextInput?(data)
            Logger.clauntty.info("Pasted \(data.count) bytes from clipboard")
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        // TODO: Implement select all if Ghostty supports it
        Logger.clauntty.debug("Select all not yet implemented")
    }

    // MARK: - Scroll Handling

    /// Accumulated scroll delta for smoother scrolling
    private var scrollAccumulator: CGFloat = 0
    private let scrollThreshold: CGFloat = 10.0  // Points per "line" of scroll

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard let surface = self.surface else { return }

        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            scrollAccumulator = 0

        case .changed:
            // Accumulate vertical scroll (negative = scroll up to see history)
            scrollAccumulator += translation.y

            // Convert to scroll "lines" - Ghostty expects scroll delta in lines
            // Positive y in gesture = finger moving down = scroll up in history
            let scrollLines = scrollAccumulator / scrollThreshold

            if abs(scrollLines) >= 1 {
                // Send scroll to Ghostty (y positive = scroll up/back in history)
                ghostty_surface_mouse_scroll(surface, 0, Double(scrollLines), 0)
                scrollAccumulator = scrollAccumulator.truncatingRemainder(dividingBy: scrollThreshold)
            }

            // Reset translation for incremental tracking
            gesture.setTranslation(.zero, in: self)

        case .ended, .cancelled:
            scrollAccumulator = 0

        default:
            break
        }
    }

    // MARK: - Layer

    // NOTE: We do NOT override layerClass to CAMetalLayer because Ghostty
    // adds its own IOSurfaceLayer as a sublayer. Using default CALayer.

    /// Called by GhosttyKit's Metal renderer to add its IOSurfaceLayer
    /// GhosttyKit calls this on the view, but it's a CALayer method,
    /// so we forward to our layer and set the sublayer's frame.
    @objc(addSublayer:)
    func addSublayer(_ sublayer: CALayer) {
        Logger.clauntty.debug("addSublayer called, layer.bounds=\(NSCoder.string(for: self.layer.bounds))")

        // Store reference first
        ghosttySublayer = sublayer

        // Add to layer hierarchy
        self.layer.addSublayer(sublayer)

        // Immediately trigger size update with current bounds
        // This ensures the sublayer gets the correct size even if layoutSubviews hasn't run yet
        sizeDidChange(self.bounds.size)
    }

    /// Reference to Ghostty's IOSurfaceLayer for frame updates
    private var ghosttySublayer: CALayer?

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        Logger.clauntty.debug("layoutSubviews: bounds=\(NSCoder.string(for: self.bounds))")

        // Account for keyboard when calculating effective size
        let effectiveSize = CGSize(
            width: bounds.width,
            height: bounds.height - keyboardHeight
        )
        sizeDidChange(effectiveSize)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let scale = window!.screen.scale
            let boundsStr = NSCoder.string(for: bounds)
            Logger.clauntty.info("didMoveToWindow: window scale=\(scale), bounds=\(boundsStr)")

            // Account for keyboard when calculating effective size
            let effectiveSize = CGSize(
                width: bounds.width,
                height: bounds.height - keyboardHeight
            )
            sizeDidChange(effectiveSize)

            // Auto-show keyboard when terminal appears (only if this is the active tab)
            // Delay slightly to ensure view hierarchy is ready
            if isActiveTab {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self, self.isActiveTab else { return }
                    _ = self.becomeFirstResponder()
                }
            }
        }
    }

    func sizeDidChange(_ size: CGSize) {
        guard let surface = self.surface else { return }

        // Skip invalid sizes (too small to be useful)
        guard size.width > 50 && size.height > 50 else {
            Logger.clauntty.debug("Skipping invalid size: \(Int(size.width))x\(Int(size.height))")
            return
        }

        // Use window's screen scale, or fall back to main screen
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let pixelWidth = UInt32(size.width * scale)
        let pixelHeight = UInt32(size.height * scale)

        Logger.clauntty.info("sizeDidChange: \(Int(size.width))x\(Int(size.height))pt @\(scale)x = \(pixelWidth)x\(pixelHeight)px")

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)

        // Update sublayer frame and scale to match
        if let sublayer = ghosttySublayer {
            sublayer.frame = CGRect(origin: .zero, size: size)
            sublayer.contentsScale = scale
        }

        // Query terminal grid size and notify if changed
        let surfaceSize = ghostty_surface_size(surface)
        let newRows = surfaceSize.rows
        let newCols = surfaceSize.columns

        Logger.clauntty.info("Terminal grid: \(newCols) cols x \(newRows) rows")

        if newRows != terminalSize.rows || newCols != terminalSize.columns {
            terminalSize = (newRows, newCols)
            Logger.clauntty.info("Terminal size changed, notifying SSH: \(newCols)x\(newRows)")
            onTerminalSizeChanged?(newRows, newCols)
        }
    }

    // MARK: - Focus & Active State

    /// Whether this surface is the active tab
    private var isActiveTab: Bool = true

    /// Set whether this terminal surface is the active tab
    /// Inactive surfaces don't render their cursor and lose keyboard focus
    func setActive(_ active: Bool) {
        guard active != isActiveTab else { return }
        isActiveTab = active

        if active {
            // Becoming active - gain focus and show keyboard
            Logger.clauntty.debug("Surface becoming active")
            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
            focusDidChange(true)
        } else {
            // Becoming inactive - lose focus to hide cursor
            Logger.clauntty.debug("Surface becoming inactive")
            focusDidChange(false)
            if isFirstResponder {
                _ = resignFirstResponder()
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        // Only allow becoming first responder if this is the active tab
        guard isActiveTab else {
            Logger.clauntty.info("becomeFirstResponder: rejected - not active tab")
            return false
        }

        let result = super.becomeFirstResponder()
        Logger.clauntty.info("becomeFirstResponder: result=\(result), isFirstResponder=\(self.isFirstResponder)")
        if result {
            focusDidChange(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            focusDidChange(false)
        }
        return result
    }

    func focusDidChange(_ focused: Bool) {
        guard let surface = self.surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: - SSH Data Flow

    /// Write SSH output to the terminal for display
    /// This feeds data directly to Ghostty's terminal processor
    func writeSSHOutput(_ data: Data) {
        guard let surface = self.surface else {
            Logger.clauntty.warning("Cannot write SSH output: no surface")
            return
        }

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_pty_output(surface, ptr, UInt(data.count))
        }
        Logger.clauntty.debug("SSH output written: \(data.count) bytes")
    }

    // MARK: - UIKeyInput

    var hasText: Bool {
        return true
    }

    func insertText(_ text: String) {
        Logger.clauntty.info("insertText called: '\(text)' (\(text.count) chars)")

        // Check if Ctrl modifier is active from accessory bar
        if accessoryBar.consumeCtrlModifier() {
            // Convert character to control character (Ctrl+A = 0x01, Ctrl+C = 0x03, etc.)
            if let char = text.lowercased().first,
               let asciiValue = char.asciiValue,
               asciiValue >= 97 && asciiValue <= 122 {  // a-z
                let ctrlChar = UInt8(asciiValue - 96)  // a=1, b=2, ..., z=26
                onTextInput?(Data([ctrlChar]))
                Logger.clauntty.debug("Ctrl+\(char) sent as 0x\(String(format: "%02X", ctrlChar))")
                return
            }
        }

        // Convert newline (LF) to carriage return (CR) for terminal compatibility
        // iOS keyboard sends \n but terminals expect \r for Enter
        let terminalText = text.replacingOccurrences(of: "\n", with: "\r")

        // Send text input to SSH (not directly to Ghostty)
        // SSH server will echo it back if needed, and we'll display via writeSSHOutput
        if let data = terminalText.data(using: .utf8) {
            onTextInput?(data)
        }
    }

    func deleteBackward() {
        Logger.clauntty.info("deleteBackward called")
        // Send backspace (ASCII DEL 0x7F or BS 0x08) to SSH
        let backspace = Data([0x7F])  // DEL character
        onTextInput?(backspace)
    }

    // MARK: - Hardware Keyboard Support

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if let data = dataForKey(key) {
                onTextInput?(data)
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    /// Convert UIKey to terminal escape sequence data
    private func dataForKey(_ key: UIKey) -> Data? {
        switch key.keyCode {
        // Escape key
        case .keyboardEscape:
            return Data([0x1B])  // ESC

        // Arrow keys (send ANSI escape sequences)
        case .keyboardUpArrow:
            return Data([0x1B, 0x5B, 0x41])  // ESC [ A
        case .keyboardDownArrow:
            return Data([0x1B, 0x5B, 0x42])  // ESC [ B
        case .keyboardRightArrow:
            return Data([0x1B, 0x5B, 0x43])  // ESC [ C
        case .keyboardLeftArrow:
            return Data([0x1B, 0x5B, 0x44])  // ESC [ D

        // Tab
        case .keyboardTab:
            return Data([0x09])  // TAB

        // Enter/Return
        case .keyboardReturnOrEnter:
            return Data([0x0D])  // CR

        // Function keys
        case .keyboardF1:
            return Data([0x1B, 0x4F, 0x50])  // ESC O P
        case .keyboardF2:
            return Data([0x1B, 0x4F, 0x51])  // ESC O Q
        case .keyboardF3:
            return Data([0x1B, 0x4F, 0x52])  // ESC O R
        case .keyboardF4:
            return Data([0x1B, 0x4F, 0x53])  // ESC O S

        // Home/End/PageUp/PageDown
        case .keyboardHome:
            return Data([0x1B, 0x5B, 0x48])  // ESC [ H
        case .keyboardEnd:
            return Data([0x1B, 0x5B, 0x46])  // ESC [ F
        case .keyboardPageUp:
            return Data([0x1B, 0x5B, 0x35, 0x7E])  // ESC [ 5 ~
        case .keyboardPageDown:
            return Data([0x1B, 0x5B, 0x36, 0x7E])  // ESC [ 6 ~

        // Delete (forward delete)
        case .keyboardDeleteForward:
            return Data([0x1B, 0x5B, 0x33, 0x7E])  // ESC [ 3 ~

        default:
            // Check for Ctrl+key combinations
            if key.modifierFlags.contains(.control), let char = key.characters.first {
                let asciiValue = char.asciiValue ?? 0
                // Ctrl+A through Ctrl+Z = 0x01 through 0x1A
                if asciiValue >= 97 && asciiValue <= 122 {  // a-z
                    return Data([UInt8(asciiValue - 96)])
                }
            }
            return nil
        }
    }
}

// MARK: - UIEditMenuInteractionDelegate

extension TerminalSurfaceView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        // Return default menu with Copy/Paste
        return UIMenu(children: suggestedActions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion {
            self.isEditMenuVisible = false
        }
    }
}

// MARK: - Preview

#Preview {
    TerminalSurface(ghosttyApp: GhosttyApp())
        .ignoresSafeArea()
}
