import AppKit

@MainActor
final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    let textView: WriterTextView
    private let scrollView = NSScrollView()
    private let wordLabel = NSTextField(labelWithString: "0 words")
    private let statusLabel = NSTextField(labelWithString: "Markdown")
    private var highlighter: MarkdownHighlighter!
    private var isStyling = false
    private var fontSize = MarkdownHighlighter.defaultFontSize
    private let storage: EditorStorage

    init(document: GonzoDocument) {
        storage = document.storage
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        // The centered writing column sets its width explicitly along with
        // the view and insets, rather than racing automatic width tracking.
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        document.storage.addLayoutManager(layout)
        textView = WriterTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), textContainer: container)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Gonzo"
        window.identifier = NSUserInterfaceItemIdentifier("GonzoDocumentWindow")
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .textBackgroundColor
        window.setFrameAutosaveName("GonzoWriter")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        configureEditor()
        configureLayout(window)
        configureFooter()
        highlighter = MarkdownHighlighter(textView: textView)
        applyFontSize()
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        window.center()
        updateWordCount()
    }

    required init?(coder: NSCoder) { fatalError("Gonzo creates its windows in code") }

    private func configureEditor() {
        textView.delegate = self
        textView.didFinishMouseSelection = { [weak self] in self?.viewportChanged() }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityLabel("Markdown editor")
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
    }

    private func configureLayout(_ window: NSWindow) {
        let content = window.contentView!
        let footer = NSView()
        footer.identifier = NSUserInterfaceItemIdentifier("footer")
        [scrollView, footer].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func configureFooter() {
        guard let footer = window?.contentView?.subviews.first(where: { $0.identifier?.rawValue == "footer" }) else { return }
        let open = iconButton("folder", label: "Open", action: #selector(NSDocumentController.openDocument(_:)))
        let save = iconButton("square.and.arrow.down", label: "Save", action: #selector(NSDocument.save(_:)))
        for label in [wordLabel, statusLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        wordLabel.setAccessibilityLabel("Word count")
        let actions = NSStackView(views: [open, save, statusLabel])
        actions.spacing = 14
        for view in [actions, wordLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            actions.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            wordLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18),
            wordLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: wordLabel.leadingAnchor, constant: -24)
        ])
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
        updateColumn()
        viewportChanged()
    }

    var baseAttributes: [NSAttributedString.Key: Any] { highlighter.baseAttributes }

    func reloadFromDocument() {
        highlighter.invalidate()
        updateWordCount()
        viewportChanged()
        textView.undoManager?.removeAllActions()
    }

    func textDidChange(_ notification: Notification) {
        guard !isStyling else { return }
        isStyling = true
        highlighter.refreshEditedParagraphs()
        isStyling = false
        textView.updateInsertionAttributes()
        updateWordCount()
        // NSTextView's undo registrations notify NSDocument of content changes.
    }

    private func updateWordCount() {
        let count = storage.wordCount
        wordLabel.stringValue = "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isStyling, !textView.isTrackingMouseSelection else { return }
        textView.updateInsertionAttributes()
    }

    @objc private func viewportChanged() {
        guard !isStyling, !textView.isTrackingMouseSelection, highlighter != nil else { return }
        isStyling = true
        highlighter.refreshVisible()
        isStyling = false
        textView.updateInsertionAttributes()
    }

    func windowDidResize(_ notification: Notification) { updateColumn(); viewportChanged() }

    private func updateColumn() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentSize
        guard viewport.width > 0 else { return }
        let width = viewport.width
        let wasStyling = isStyling
        isStyling = true
        textView.writingColumnWidth = fontSize * 0.6 * 65
        textView.minSize = NSSize(width: 0, height: viewport.height)
        textView.setFrameSize(NSSize(width: width, height: max(viewport.height, textView.frame.height)))
        textView.sizeToFit()
        textView.needsDisplay = true
        isStyling = wasStyling
    }

    @objc func biggerText(_ sender: Any?) { fontSize = min(32, fontSize + 1); applyFontSize() }
    @objc func smallerText(_ sender: Any?) { fontSize = max(12, fontSize - 1); applyFontSize() }
    @objc func resetTextSize(_ sender: Any?) { fontSize = MarkdownHighlighter.defaultFontSize; applyFontSize() }

    private func applyFontSize() {
        // Restyle the viewport only. Invalidating the paragraph cache makes
        // off-screen text adopt the new size when it scrolls into view, rather
        // than rewriting and refixing attributes across the whole document.
        highlighter.fontSize = fontSize
        textView.defaultTypingAttributes = highlighter.baseAttributes
        textView.typingAttributes = highlighter.baseAttributes
        updateColumn()
        highlighter.invalidate()
        viewportChanged()
    }

}
