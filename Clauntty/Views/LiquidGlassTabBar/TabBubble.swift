import UIKit
import os.log

private let logger = Logger(subsystem: "com.clauntty", category: "TabBubble")

/// Represents the type of tab for styling purposes
enum TabType {
    case terminal(Session.State)
    case web(WebTab.State)
}

/// Individual tab bubble with liquid glass effect
/// Expands Safari-style with two rows when tapped
class TabBubble: UIView {

    // MARK: - Properties

    var tabId: UUID?
    var tabType: TabType = .terminal(.disconnected)
    var title: String = "" {
        didSet { updateTitleLabel() }
    }
    /// Title to show when expanded (URL for web tabs)
    var expandedTitle: String = "" {
        didSet { updateTitleLabel() }
    }
    /// Port for web tabs (e.g., 3000)
    var webPort: Int = 0 {
        didSet { portPrefixLabel.text = ":\(webPort)" }
    }
    /// Path for web tabs (e.g., /api/users)
    var webPath: String = "/" {
        didSet { urlTextField.text = webPath }
    }
    /// Connection string like "ubuntu@devbox.example.com"
    var connectionInfo: String = "" {
        didSet { connectionLabel.text = connectionInfo }
    }

    private func updateTitleLabel() {
        // In expanded state for web tabs, show the URL
        if isExpanded && !expandedTitle.isEmpty {
            titleLabel.text = expandedTitle
        } else {
            titleLabel.text = title
        }
    }
    var isActiveTab: Bool = false {
        didSet { updateActiveState() }
    }
    var isExpanded: Bool = false {
        didSet {
            if oldValue != isExpanded {
                animateExpansion()
            }
        }
    }

    /// Callback when this bubble is tapped (collapsed state)
    var onTap: (() -> Void)?

    /// Callbacks for expanded state actions
    var onDisconnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onTabs: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onDismiss: (() -> Void)?

    // Web-specific callbacks
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onShare: (() -> Void)?
    var onNavigate: ((String) -> Void)?  // Called when user enters a new path

    // MARK: - Constants

    private let statusSize: CGFloat = 8
    private let horizontalPadding: CGFloat = 16
    private let buttonSize: CGFloat = 44
    private let topRowHeight: CGFloat = 44
    private let bottomRowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 4

    // MARK: - Views

    /// Glass effect container
    private let containerEffectView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.isInteractive = true
            effect = glassEffect
        } else {
            effect = UIBlurEffect(style: .systemMaterial)
        }
        let view = UIVisualEffectView(effect: effect)
        view.clipsToBounds = true
        return view
    }()

    /// Darker background for top row (expanded state)
    private let topRowBackground: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        view.layer.cornerRadius = 22
        view.alpha = 0
        return view
    }()

    /// Status indicator - circle for terminal
    private let statusView = UIView()

    /// Pulsing ring for waiting-for-input state
    private let waitingRingView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.layer.borderColor = UIColor.systemBlue.cgColor
        view.layer.borderWidth = 1.5
        view.isHidden = true
        return view
    }()

    /// Whether this tab is waiting for input (shows pulsing ring)
    var isWaitingForInput: Bool = false {
        didSet {
            updateWaitingRing()
        }
    }

    /// Globe icon for web tabs
    private let globeImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = UIImage(systemName: "globe", withConfiguration: config)
        let imageView = UIImageView(image: image)
        imageView.tintColor = .systemBlue
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    /// Title label (session name / URL) - used in collapsed state and terminal expanded
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// Port prefix label (non-editable :3000 part)
    private let portPrefixLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.alpha = 0
        return label
    }()

    /// Editable path field for web tabs (expanded state only)
    private let urlTextField: UITextField = {
        let field = UITextField()
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = .label
        field.textAlignment = .left
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.placeholder = "/"
        field.alpha = 0
        return field
    }()

    /// Connection info label (ubuntu@host.com) - shown in bottom row when expanded
    private let connectionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.alpha = 0
        return label
    }()

    // MARK: - Top Row Buttons (expanded)

    /// Terminal icon (left of title in top row) or Disconnect for terminal
    private let leftActionButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.setImage(UIImage(systemName: "terminal", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    /// Reconnect/Reload button (right of title in top row)
    private let rightActionButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    // MARK: - Bottom Row Buttons (expanded)

    /// Tabs button (left side of bottom row)
    private let tabsButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "square.on.square", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    /// New tab button (right side of bottom row)
    private let newTabButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "plus", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    // Web-specific bottom row buttons
    private let backButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "chevron.left", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    private let forwardButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "chevron.right", withConfiguration: config), for: .normal)
        button.tintColor = .secondaryLabel
        button.alpha = 0
        return button
    }()

    private let shareButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.alpha = 0
        return button
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear

        // Setup container with glass effect
        containerEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerEffectView)

        // Setup top row background (for expanded state)
        topRowBackground.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(topRowBackground)

        // Setup status indicator (circle)
        statusView.translatesAutoresizingMaskIntoConstraints = true
        statusView.layer.cornerRadius = statusSize / 2
        containerEffectView.contentView.addSubview(statusView)

        // Setup waiting ring (pulsing blue ring around status)
        waitingRingView.translatesAutoresizingMaskIntoConstraints = true
        waitingRingView.layer.cornerRadius = 6  // Slightly larger than status (8/2 + 2)
        containerEffectView.contentView.addSubview(waitingRingView)

        // Setup globe icon (hidden by default)
        globeImageView.translatesAutoresizingMaskIntoConstraints = true
        globeImageView.isHidden = true
        containerEffectView.contentView.addSubview(globeImageView)

        // Setup labels
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(titleLabel)

        // Setup URL components for web tabs
        portPrefixLabel.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(portPrefixLabel)

        urlTextField.translatesAutoresizingMaskIntoConstraints = true
        urlTextField.delegate = self
        containerEffectView.contentView.addSubview(urlTextField)

        connectionLabel.translatesAutoresizingMaskIntoConstraints = true
        containerEffectView.contentView.addSubview(connectionLabel)

        // Setup buttons
        setupButtons()
        setupConstraints()
        setupGestures()
    }

    private func setupButtons() {
        let buttons = [leftActionButton, rightActionButton, tabsButton, newTabButton,
                       backButton, forwardButton, shareButton]

        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            containerEffectView.contentView.addSubview(button)
        }

        // Add targets
        leftActionButton.addTarget(self, action: #selector(handleLeftAction), for: .touchUpInside)
        rightActionButton.addTarget(self, action: #selector(handleRightAction), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(handleTabs), for: .touchUpInside)
        newTabButton.addTarget(self, action: #selector(handleNewTab), for: .touchUpInside)
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(handleForward), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            containerEffectView.topAnchor.constraint(equalTo: topAnchor),
            containerEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    // MARK: - Actions

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if isExpanded {
            // Tap on background area dismisses
            let location = gesture.location(in: containerEffectView.contentView)
            let buttons = [leftActionButton, rightActionButton, tabsButton, newTabButton,
                          backButton, forwardButton, shareButton]
            for button in buttons where button.alpha > 0 && button.frame.contains(location) {
                return // Let button handle it
            }
            onDismiss?()
        } else {
            onTap?()
        }
    }

    @objc private func handleLeftAction() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch tabType {
        case .terminal:
            onDisconnect?()
        case .web:
            // Reader mode or similar
            break
        }
    }

    @objc private func handleRightAction() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch tabType {
        case .terminal:
            onReconnect?()
        case .web:
            onReload?()
        }
    }

    @objc private func handleTabs() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTabs?()
    }

    @objc private func handleNewTab() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onNewTab?()
    }

    @objc private func handleBack() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onBack?()
    }

    @objc private func handleForward() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onForward?()
    }

    @objc private func handleShare() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onShare?()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        containerEffectView.layer.cornerRadius = isExpanded ? 26 : min(bounds.height / 2, 20)
        layoutContent()
    }

    private func layoutContent() {
        let width = bounds.width
        let height = bounds.height

        guard width > 0 && height > 0 else { return }

        if isExpanded {
            layoutExpandedContent(width: width, height: height)
        } else {
            layoutCollapsedContent(width: width, height: height)
        }
    }

    private func layoutCollapsedContent(width: CGFloat, height: CGFloat) {
        let centerY = height / 2

        // Determine icon size based on tab type
        let isWeb: Bool
        switch tabType {
        case .web: isWeb = true
        case .terminal: isWeb = false
        }

        let iconSize: CGFloat = isWeb ? 14 : statusSize  // Globe is 14, status dot is 8

        // Calculate actual text width for proper centering
        let maxTitleWidth = width - iconSize - 6 - horizontalPadding * 2
        let actualTitleSize = titleLabel.sizeThatFits(CGSize(width: maxTitleWidth, height: height))
        let titleWidth = min(actualTitleSize.width, maxTitleWidth)

        let gap: CGFloat = 6
        let contentWidth = iconSize + gap + titleWidth
        let startX = (width - contentWidth) / 2

        statusView.frame = CGRect(x: startX, y: centerY - statusSize / 2, width: statusSize, height: statusSize)
        // Center waiting ring on status (12x12 ring around 8x8 status)
        let ringSize: CGFloat = 12
        waitingRingView.frame = CGRect(
            x: statusView.frame.midX - ringSize / 2,
            y: statusView.frame.midY - ringSize / 2,
            width: ringSize,
            height: ringSize
        )
        globeImageView.frame = CGRect(x: startX, y: centerY - 7, width: 14, height: 14)

        let titleX = startX + iconSize + gap
        titleLabel.frame = CGRect(x: titleX, y: 0, width: titleWidth, height: height)
        titleLabel.textAlignment = .left

        // Hide expanded elements
        topRowBackground.frame = .zero
        connectionLabel.frame = .zero
        urlTextField.frame = .zero
        portPrefixLabel.frame = .zero

        // Hide all buttons off-screen
        let offscreen = CGRect(x: -100, y: 0, width: buttonSize, height: buttonSize)
        [leftActionButton, rightActionButton, tabsButton, newTabButton,
         backButton, forwardButton, shareButton].forEach { $0.frame = offscreen }
    }

    private func layoutExpandedContent(width: CGFloat, height: CGFloat) {
        let padding = horizontalPadding
        let topRowY: CGFloat = 8
        let bottomRowY = topRowY + topRowHeight + rowSpacing

        // Top row background (darker pill)
        let topRowBgInset: CGFloat = 8
        topRowBackground.frame = CGRect(
            x: topRowBgInset,
            y: topRowY,
            width: width - topRowBgInset * 2,
            height: topRowHeight
        )

        // Top row: [leftAction] [status] [title] [rightAction]
        let topRowCenterY = topRowY + topRowHeight / 2

        leftActionButton.frame = CGRect(
            x: padding,
            y: topRowCenterY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )

        rightActionButton.frame = CGRect(
            x: width - padding - buttonSize,
            y: topRowCenterY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )

        // Status/globe next to left button
        let statusX = leftActionButton.frame.maxX + 8
        statusView.frame = CGRect(x: statusX, y: topRowCenterY - statusSize / 2, width: statusSize, height: statusSize)
        // Center waiting ring on status in expanded state
        let expandedRingSize: CGFloat = 12
        waitingRingView.frame = CGRect(
            x: statusView.frame.midX - expandedRingSize / 2,
            y: statusView.frame.midY - expandedRingSize / 2,
            width: expandedRingSize,
            height: expandedRingSize
        )
        globeImageView.frame = CGRect(x: statusX, y: topRowCenterY - 8, width: 16, height: 16)

        // Title/URL centered in remaining space
        let titleX = statusX + statusSize + 8
        let titleWidth = rightActionButton.frame.minX - titleX - 8
        let titleFrame = CGRect(x: titleX, y: topRowY, width: titleWidth, height: topRowHeight)

        switch tabType {
        case .terminal:
            titleLabel.frame = titleFrame
            titleLabel.textAlignment = .center
            urlTextField.frame = .zero
            portPrefixLabel.frame = .zero
        case .web:
            // Web tabs: [port prefix :3000] [editable path field /api/users]
            titleLabel.frame = .zero

            // Calculate port prefix width
            let portText = ":\(webPort)"
            let portSize = (portText as NSString).size(withAttributes: [.font: portPrefixLabel.font!])
            let portWidth = ceil(portSize.width) + 4

            portPrefixLabel.frame = CGRect(x: titleX, y: topRowY, width: portWidth, height: topRowHeight)
            urlTextField.frame = CGRect(x: titleX + portWidth, y: topRowY, width: titleWidth - portWidth, height: topRowHeight)
        }

        // Bottom row layout depends on tab type
        let bottomRowCenterY = bottomRowY + bottomRowHeight / 2

        switch tabType {
        case .terminal:
            // Terminal: [tabs] [connection info] [+]
            tabsButton.frame = CGRect(
                x: padding,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            newTabButton.frame = CGRect(
                x: width - padding - buttonSize,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            // Connection label in center
            let connX = tabsButton.frame.maxX + 8
            let connWidth = newTabButton.frame.minX - connX - 8
            connectionLabel.frame = CGRect(x: connX, y: bottomRowY, width: connWidth, height: bottomRowHeight)

            // Hide web buttons
            [backButton, forwardButton, shareButton].forEach { $0.frame = CGRect(x: -100, y: 0, width: buttonSize, height: buttonSize) }

        case .web:
            // Web: [<] [>] [share] [tabs] [+] - like Safari
            let buttonSpacing = (width - padding * 2 - buttonSize * 5) / 4

            backButton.frame = CGRect(
                x: padding,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            forwardButton.frame = CGRect(
                x: backButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            shareButton.frame = CGRect(
                x: forwardButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            tabsButton.frame = CGRect(
                x: shareButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            newTabButton.frame = CGRect(
                x: tabsButton.frame.maxX + buttonSpacing,
                y: bottomRowCenterY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )

            // Hide connection label for web
            connectionLabel.frame = .zero
        }
    }

    /// Hide content before glass expansion animation
    func hideContentForExpansion() {
        statusView.alpha = 0
        globeImageView.alpha = 0
        titleLabel.alpha = 0
    }

    /// Access to the glass effect layer for corner radius animation
    var glassLayer: CALayer {
        return containerEffectView.layer
    }

    /// Get current corner radius
    var glassCornerRadius: CGFloat {
        return containerEffectView.layer.cornerRadius
    }

    /// Set corner radius (for animation)
    func setGlassCornerRadius(_ radius: CGFloat) {
        containerEffectView.layer.cornerRadius = radius
    }

    /// Hide all content before glass collapse animation
    func hideContentForCollapse() {
        // Hide everything - both expanded and collapsed content
        statusView.alpha = 0
        globeImageView.alpha = 0
        titleLabel.alpha = 0
        topRowBackground.alpha = 0
        leftActionButton.alpha = 0
        rightActionButton.alpha = 0
        tabsButton.alpha = 0
        newTabButton.alpha = 0
        connectionLabel.alpha = 0
        backButton.alpha = 0
        forwardButton.alpha = 0
        shareButton.alpha = 0
        portPrefixLabel.alpha = 0
        urlTextField.alpha = 0
    }

    /// Show expanded content with pop animation (called after scale animation completes)
    func showExpandedContent() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update button icons with appropriate sizes
        if isTerminal {
            // Terminate button - smaller icon
            let terminateConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: terminateConfig), for: .normal)
            leftActionButton.tintColor = .systemRed
            // No reload button for terminal
            rightActionButton.alpha = 0
            rightActionButton.isHidden = true
        } else {
            let webConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "doc.text", withConfiguration: webConfig), for: .normal)
            leftActionButton.tintColor = .label
            rightActionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: webConfig), for: .normal)
            rightActionButton.isHidden = false
        }

        // Update tabs and new tab button icons - slightly smaller
        let bottomRowConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        tabsButton.setImage(UIImage(systemName: "square.on.square", withConfiguration: bottomRowConfig), for: .normal)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: bottomRowConfig), for: .normal)

        // Update title
        updateTitleLabel()
        if !isTerminal {
            urlTextField.text = webPath
        }

        // Layout for expanded state
        isExpanded = true
        layoutContent()

        // Get views to animate (no rightActionButton for terminal - no reload button)
        let expandedViews: [UIView] = isTerminal
            ? [topRowBackground, leftActionButton, tabsButton, newTabButton, connectionLabel, statusView, titleLabel]
            : [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, backButton, forwardButton, shareButton, portPrefixLabel, urlTextField, globeImageView]

        // Set initial state
        for view in expandedViews {
            view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            view.alpha = 0
        }

        // Animate to visible
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            for view in expandedViews {
                view.transform = .identity
                view.alpha = 1
            }
        }
    }

    /// Show collapsed content with pop animation (called after collapse scale animation completes)
    func showCollapsedContent() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update title for collapsed state
        isExpanded = false
        updateTitleLabel()
        layoutContent()

        // Get views to animate
        let collapsedViews: [UIView] = isTerminal
            ? [statusView, titleLabel]
            : [globeImageView, titleLabel]

        // Set initial state
        for view in collapsedViews {
            view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            view.alpha = 0
        }

        // Animate to visible
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            for view in collapsedViews {
                view.transform = .identity
                view.alpha = 1
            }
        }
    }

    private func animateExpansion() {
        let isTerminal: Bool
        switch tabType {
        case .terminal: isTerminal = true
        case .web: isTerminal = false
        }

        // Update button icons based on tab type
        if isTerminal {
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "xmark.circle", withConfiguration: config), for: .normal)
            leftActionButton.tintColor = .systemRed
            rightActionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: config), for: .normal)
        } else {
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            leftActionButton.setImage(UIImage(systemName: "doc.text", withConfiguration: config), for: .normal)
            leftActionButton.tintColor = .label
            rightActionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: config), for: .normal)
        }

        // Update title for expanded state (URL for web tabs)
        updateTitleLabel()

        // Update URL text field text for web tabs (just the path, not port)
        if !isTerminal && isExpanded {
            urlTextField.text = webPath
        }

        // Layout content first so positions are correct
        layoutContent()

        if isExpanded {
            // Pop-in animation: start scaled down and invisible, then pop to full size
            // For terminal: show title in top row, connection label below (no reload button)
            // For web: show globe + URL components
            let expandedViews: [UIView] = isTerminal
                ? [topRowBackground, leftActionButton, tabsButton, newTabButton, connectionLabel, statusView, titleLabel]
                : [topRowBackground, leftActionButton, rightActionButton, tabsButton, newTabButton, backButton, forwardButton, shareButton, portPrefixLabel, urlTextField, globeImageView]

            // Set initial state: scaled down and invisible
            for view in expandedViews {
                view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                view.alpha = 0
            }

            // Animate to full size with spring
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                for view in expandedViews {
                    view.transform = .identity
                    view.alpha = 1
                }
            }
        } else {
            // Collapsing - reverse scale animation (pop in from center)
            // First hide expanded content instantly
            topRowBackground.alpha = 0
            leftActionButton.alpha = 0
            rightActionButton.alpha = 0
            tabsButton.alpha = 0
            newTabButton.alpha = 0
            connectionLabel.alpha = 0
            backButton.alpha = 0
            forwardButton.alpha = 0
            shareButton.alpha = 0
            urlTextField.alpha = 0
            portPrefixLabel.alpha = 0

            // Collapsed content - start scaled down
            let collapsedViews: [UIView] = isTerminal
                ? [statusView, titleLabel]
                : [globeImageView, titleLabel]

            for view in collapsedViews {
                view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                view.alpha = 0
            }

            // Pop in collapsed content
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                for view in collapsedViews {
                    view.transform = .identity
                    view.alpha = 1
                }
            }
        }
    }

    // MARK: - Configuration

    func configure(session: Session) {
        tabId = session.id
        tabType = .terminal(session.state)
        title = session.title
        connectionInfo = session.connectionString
        isWaitingForInput = session.isWaitingForInput

        statusView.isHidden = false
        globeImageView.isHidden = true

        updateStatusColor()
    }

    func configure(webTab: WebTab) {
        tabId = webTab.id
        tabType = .web(webTab.state)
        title = webTab.title
        expandedTitle = webTab.urlDisplayString  // Show port + path when expanded
        connectionInfo = ""  // Not used for web tabs

        // Set port and path for editable URL
        webPort = webTab.localPort
        if let url = webTab.currentURL {
            var path = url.path
            if let query = url.query { path += "?\(query)" }
            webPath = path.isEmpty ? "/" : path
        } else {
            webPath = "/"
        }

        statusView.isHidden = true
        globeImageView.isHidden = false

        updateGlobeColor()
    }

    private func updateStatusColor() {
        switch tabType {
        case .terminal(let state):
            switch state {
            case .connected:
                statusView.backgroundColor = .systemGreen
            case .connecting:
                statusView.backgroundColor = .systemOrange
            case .disconnected:
                statusView.backgroundColor = .systemGray
            case .error:
                statusView.backgroundColor = .systemRed
            }
        case .web:
            break
        }
    }

    private func updateWaitingRing() {
        // Only show ring for non-active tabs waiting for input
        let shouldShowRing = isWaitingForInput && !isActiveTab

        if shouldShowRing {
            waitingRingView.isHidden = false
            // Start pulsing animation
            startPulsingAnimation()
        } else {
            waitingRingView.isHidden = true
            // Stop pulsing animation
            waitingRingView.layer.removeAnimation(forKey: "pulseAnimation")
        }
    }

    private func startPulsingAnimation() {
        // Remove existing animation
        waitingRingView.layer.removeAnimation(forKey: "pulseAnimation")

        // Create pulsing opacity animation
        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 0.3
        pulseAnimation.duration = 0.8
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        waitingRingView.layer.add(pulseAnimation, forKey: "pulseAnimation")
    }

    private func updateGlobeColor() {
        switch tabType {
        case .web(let state):
            switch state {
            case .connected:
                globeImageView.tintColor = .systemBlue
            case .connecting:
                globeImageView.tintColor = .systemOrange
            case .error:
                globeImageView.tintColor = .systemRed
            case .closed:
                globeImageView.tintColor = .systemGray
            }
        case .terminal:
            break
        }
    }

    private func updateActiveState() {
        titleLabel.textColor = isActiveTab ? .label : .secondaryLabel
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isExpanded && bounds.contains(point) {
            let contentPoint = convert(point, to: containerEffectView.contentView)

            // Check URL text field first (for web tabs)
            if urlTextField.alpha > 0 && urlTextField.frame.contains(contentPoint) {
                return urlTextField
            }

            let buttons = [leftActionButton, rightActionButton, tabsButton, newTabButton,
                          backButton, forwardButton, shareButton]
            for button in buttons where button.alpha > 0 && button.frame.contains(contentPoint) {
                return button
            }
            return self
        }
        return super.hitTest(point, with: event)
    }
}

// MARK: - UITextFieldDelegate

extension TabBubble: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // User pressed "Go" - navigate to the entered path
        if let path = textField.text {
            onNavigate?(path)
        }
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Select all text for easy replacement
        textField.selectAll(nil)
    }
}
