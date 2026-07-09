//
//  AgentModeTitlebarAccessoryViewController.swift
//  RepoPrompt
//
//  Xcode-style titlebar accessory that places Agent Mode controls
//  near the traffic lights using NSTitlebarAccessoryViewController.
//

import Cocoa

struct AgentModeTitlebarChatMenuSnapshot: Equatable {
    let isPinned: Bool
}

struct AgentModeTitlebarChatMenuActions {
    let togglePin: () -> Void
    let rename: () -> Void
    let stash: () -> Void
    let delete: () -> Void
}

// MARK: - Titlebar Button

private final class TitlebarAccessoryIconButton: NSButton {
    private let symbolName: String
    private let accessibilityLabelText: String
    private let normalAlpha: CGFloat
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(symbolName: String, accessibilityLabel: String, toolTip: String, normalAlpha: CGFloat = 0.7) {
        self.symbolName = symbolName
        accessibilityLabelText = accessibilityLabel
        self.normalAlpha = normalAlpha
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 28)
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    private func updateAppearance() {
        if isHighlighted {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        contentTintColor = NSColor.labelColor.withAlphaComponent(isHovering ? 1.0 : normalAlpha)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabelText)
    }
}

private final class AgentModeTitlebarMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbolName: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performHandler(_:)), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performHandler(_ sender: NSMenuItem) {
        _ = sender
        handler()
    }
}

// MARK: - AppKit Titlebar Accessory Controller

@MainActor
final class AgentModeTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private var onNewSession: () -> Void
    private var hasChatOptions: () -> Bool
    private var chatMenuSnapshot: () -> AgentModeTitlebarChatMenuSnapshot?
    private var chatMenuActions: AgentModeTitlebarChatMenuActions

    private weak var newSessionButton: TitlebarAccessoryIconButton?
    private weak var chatOptionsButton: TitlebarAccessoryIconButton?

    init(
        onNewSession: @escaping () -> Void,
        hasChatOptions: @escaping () -> Bool,
        chatMenuSnapshot: @escaping () -> AgentModeTitlebarChatMenuSnapshot?,
        chatMenuActions: AgentModeTitlebarChatMenuActions
    ) {
        self.onNewSession = onNewSession
        self.hasChatOptions = hasChatOptions
        self.chatMenuSnapshot = chatMenuSnapshot
        self.chatMenuActions = chatMenuActions
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let newButton = TitlebarAccessoryIconButton(
            symbolName: "square.and.pencil",
            accessibilityLabel: "New Session",
            toolTip: "New Session"
        )
        newButton.target = self
        newButton.action = #selector(performNewSession(_:))
        stack.addArrangedSubview(newButton)
        newSessionButton = newButton

        let optionsButton = TitlebarAccessoryIconButton(
            symbolName: "ellipsis",
            accessibilityLabel: "Chat Options",
            toolTip: "Chat Options"
        )
        optionsButton.target = self
        optionsButton.action = #selector(showChatOptionsMenu(_:))
        stack.addArrangedSubview(optionsButton)
        chatOptionsButton = optionsButton

        view = stack
        refreshChatOptionsVisibility()
    }

    /// Updates action closures without recreating the controller.
    func update(
        onNewSession: @escaping () -> Void,
        hasChatOptions: @escaping () -> Bool,
        chatMenuSnapshot: @escaping () -> AgentModeTitlebarChatMenuSnapshot?,
        chatMenuActions: AgentModeTitlebarChatMenuActions
    ) {
        self.onNewSession = onNewSession
        self.hasChatOptions = hasChatOptions
        self.chatMenuSnapshot = chatMenuSnapshot
        self.chatMenuActions = chatMenuActions
        refreshChatOptionsVisibility()
    }

    func refreshChatOptionsVisibility() {
        guard let chatOptionsButton else { return }
        let shouldHide = !hasChatOptions()
        guard chatOptionsButton.isHidden != shouldHide else { return }

        chatOptionsButton.isHidden = shouldHide
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
    }

    @objc private func performNewSession(_ sender: NSButton) {
        _ = sender
        onNewSession()
        refreshChatOptionsVisibility()
    }

    @objc private func showChatOptionsMenu(_ sender: NSButton) {
        guard let snapshot = chatMenuSnapshot() else {
            refreshChatOptionsVisibility()
            return
        }

        let menu = NSMenu(title: "Chat Options")
        menu.autoenablesItems = false
        menu.addItem(AgentModeTitlebarMenuItem(
            title: snapshot.isPinned ? "Unpin Chat" : "Pin Chat",
            symbolName: snapshot.isPinned ? "pin.slash" : "pin",
            handler: { [weak self] in self?.chatMenuActions.togglePin() }
        ))
        menu.addItem(AgentModeTitlebarMenuItem(
            title: "Rename Chat…",
            symbolName: "pencil",
            handler: { [weak self] in self?.chatMenuActions.rename() }
        ))
        menu.addItem(AgentModeTitlebarMenuItem(
            title: "Stash Chat",
            symbolName: "tray.and.arrow.down",
            handler: { [weak self] in self?.chatMenuActions.stash() }
        ))
        menu.addItem(.separator())
        menu.addItem(AgentModeTitlebarMenuItem(
            title: "Delete Chat…",
            symbolName: "trash",
            handler: { [weak self] in self?.chatMenuActions.delete() }
        ))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
        refreshChatOptionsVisibility()
    }
}
