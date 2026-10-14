import UIKit

/// Draws the in-place selection over the terminal: a tinted band over the
/// selected cells and, like a text view, a handle at each end. The view never
/// takes touches; the terminal hit-tests the handles itself.
///
/// Shape layers, not `draw(_:)`: a drawn view the size of the terminal would
/// hold a full-screen bitmap for every retained terminal, almost always empty.
final class TerminalSelectionOverlayView: UIView {
    static let knobDiameter: CGFloat = 10
    static let barWidth: CGFloat = 2

    private let bandLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()

    var spanRects: [CGRect] = [] {
        didSet {
            guard oldValue != spanRects else { return }
            isHidden = spanRects.isEmpty
            updatePaths()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        // Ghostty adds its render layer to the terminal after this view is
        // in place; the highlight must still draw above it.
        layer.zPosition = 1
        layer.addSublayer(bandLayer)
        layer.addSublayer(handleLayer)
        accessibilityIdentifier = "terminal.selection"
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The knob above the first selected cell.
    var startKnob: CGRect? {
        guard let first = spanRects.first else { return nil }
        return Self.knob(centeredAt: CGPoint(x: first.minX, y: first.minY - Self.knobDiameter / 2))
    }

    /// The knob below the last selected cell.
    var endKnob: CGRect? {
        guard let last = spanRects.last else { return nil }
        return Self.knob(centeredAt: CGPoint(x: last.maxX, y: last.maxY + Self.knobDiameter / 2))
    }

    private static func knob(centeredAt center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - knobDiameter / 2,
            y: center.y - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTint()
    }

    private func applyTint() {
        bandLayer.fillColor = tintColor.withAlphaComponent(0.3).cgColor
        handleLayer.fillColor = tintColor.cgColor
    }

    private func updatePaths() {
        let band = UIBezierPath()
        for spanRect in spanRects {
            band.append(UIBezierPath(rect: spanRect))
        }
        let handles = UIBezierPath()
        if let first = spanRects.first, let knob = startKnob {
            handles.append(UIBezierPath(rect: CGRect(
                x: first.minX - Self.barWidth / 2, y: first.minY,
                width: Self.barWidth, height: first.height)))
            handles.append(UIBezierPath(ovalIn: knob))
        }
        if let last = spanRects.last, let knob = endKnob {
            handles.append(UIBezierPath(rect: CGRect(
                x: last.maxX - Self.barWidth / 2, y: last.minY,
                width: Self.barWidth, height: last.height)))
            handles.append(UIBezierPath(ovalIn: knob))
        }
        bandLayer.path = band.cgPath
        handleLayer.path = handles.cgPath
    }
}

/// Text selection on the terminal grid, the way a long press selects in a
/// text view: the word (or whole link) under the finger first, the drag
/// extends it, handles adjust it afterwards, and an edit menu offers Copy.
///
/// The selection is Heeler's, not Ghostty's: a finger produces no pointer
/// events for the engine's own selection, and emulating clicks would reach a
/// TUI that tracks the mouse. It is read from the visible rows and cleared by
/// a tap, a scroll, a resize, or output that changes the selected rows, so it
/// can never silently drift off the text it was made on.
@MainActor
final class TerminalSelectionController: NSObject {
    /// Shorter than the edit-menu interaction's own press, which the terminal
    /// still carries for pointer users, so a finger reaches this one first.
    static let longPressDuration: TimeInterval = 0.4
    /// How far from a handle's knob a drag may start and still grab it.
    static let handleHitRadius: CGFloat = 22

    private weak var terminal: HeelerTerminalView?
    private let overlay = TerminalSelectionOverlayView()
    private var editMenu: UIEditMenuInteraction?
    private(set) var selection: TerminalGridSelection?
    /// The rows the selection was made against.
    private var grid: TerminalViewportRows?
    private var viewportText = ""
    /// The link under the long press, when it landed on one.
    private(set) var link: TerminalViewportLink?
    private var draggedEnd: TerminalGridSelection.SelectionEnd?

    private lazy var longPress: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(
            target: self, action: #selector(handleLongPress(_:)))
        gesture.minimumPressDuration = Self.longPressDuration
        gesture.allowableMovement = 10
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.delegate = self
        return gesture
    }()

    private lazy var handlePan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(
            target: self, action: #selector(handleHandlePan(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()

    init(terminal: HeelerTerminalView) {
        self.terminal = terminal
        super.init()
    }

    /// Adds the overlay, the gestures and the edit menu to the terminal. The
    /// scroll pan yields to a drag that starts on a handle.
    func install(scrollGesture: UIGestureRecognizer) {
        guard let terminal else { return }
        overlay.frame = terminal.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminal.addSubview(overlay)
        terminal.addGestureRecognizer(longPress)
        terminal.addGestureRecognizer(handlePan)
        scrollGesture.require(toFail: handlePan)
        let menu = UIEditMenuInteraction(delegate: self)
        terminal.addInteraction(menu)
        editMenu = menu
    }

    func owns(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === longPress || gestureRecognizer === handlePan
    }

    var hasSelection: Bool { selection != nil }

    var selectedText: String? {
        guard let selection, let grid else { return nil }
        return TerminalSelectionText.text(of: selection, in: grid)
    }

    /// Drops the selection, its overlay and its menu.
    func clear() {
        guard selection != nil || link != nil else { return }
        selection = nil
        grid = nil
        link = nil
        draggedEnd = nil
        overlay.spanRects = []
        editMenu?.dismissMenu()
    }

    /// A touch anywhere but on a handle ends the selection, as it does in a
    /// text view; the gesture that follows (a tap, a scroll, a new long
    /// press) then starts clean.
    func touchesBegan(_ touches: Set<UITouch>) {
        guard selection != nil, let terminal else { return }
        let onHandle = touches.contains { touch in
            touch.type == .direct && handle(at: touch.location(in: terminal)) != nil
        }
        if !onHandle {
            clear()
        }
    }

    /// Fresh visible text: the selection stays only while the rows it covers
    /// still read as they did when it was made.
    func viewportTextDidChange(_ text: String) {
        guard let selection, let grid else { return }
        let fresh = TerminalViewportRows(viewportText: text, columns: grid.columns)
        for row in selection.start.row...max(selection.end.row, selection.start.row)
        where fresh.row(row) != grid.row(row) {
            clear()
            return
        }
    }

    /// Repositions the highlight after a layout pass; the grid may have moved.
    func layout() {
        guard let terminal else { return }
        overlay.frame = terminal.bounds
        redraw()
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let text = selectedText, !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        return true
    }

    // MARK: Gestures

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let terminal else { return }
        let point = gesture.location(in: terminal)
        switch gesture.state {
        case .began:
            guard let cell = terminal.gridPointMapper.cell(at: point),
                let grid = terminal.readViewportRows()
            else { return }
            self.grid = grid
            viewportText = grid.text
            editMenu?.dismissMenu()
            if let link = TerminalLinkHitTest.link(in: grid, row: cell.row, column: cell.column),
                let linkSelection = TerminalGridSelection(spans: link.spans)
            {
                self.link = link
                selection = linkSelection
            } else if let row = grid.row(cell.row) {
                link = nil
                selection = TerminalGridSelection(
                    span: TerminalSelectionText.wordSpan(
                        in: row, atColumn: cell.column, rowIndex: cell.row))
            } else {
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            redraw()
        case .changed:
            guard selection != nil, let cell = terminal.gridPointMapper.cell(at: point) else { return }
            selection?.extend(to: TerminalGridCell(row: cell.row, column: cell.column))
            redraw()
        case .ended:
            presentMenu()
        default:
            break
        }
    }

    @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard let terminal else { return }
        switch gesture.state {
        case .began, .changed:
            guard let draggedEnd,
                let cell = terminal.gridPointMapper.cell(at: gesture.location(in: terminal))
            else { return }
            editMenu?.dismissMenu()
            selection?.move(draggedEnd, to: TerminalGridCell(row: cell.row, column: cell.column))
            redraw()
        case .ended:
            draggedEnd = nil
            presentMenu()
        case .cancelled, .failed:
            draggedEnd = nil
        default:
            break
        }
    }

    private func handle(at point: CGPoint) -> TerminalGridSelection.SelectionEnd? {
        let radius = Self.handleHitRadius
        if let knob = overlay.startKnob, knob.insetBy(dx: -radius, dy: -radius).contains(point) {
            return .start
        }
        if let knob = overlay.endKnob, knob.insetBy(dx: -radius, dy: -radius).contains(point) {
            return .end
        }
        return nil
    }

    private func redraw() {
        guard let terminal, let selection, let grid else {
            overlay.spanRects = []
            return
        }
        let mapper = terminal.gridPointMapper
        overlay.spanRects = selection.spans(columns: grid.columns).map { mapper.rect(for: $0) }
    }

    private var selectionBounds: CGRect? {
        var bounds: CGRect?
        for rect in overlay.spanRects {
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        return bounds
    }

    // MARK: Menu

    private func presentMenu() {
        guard let editMenu, selection != nil, let bounds = selectionBounds else { return }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: CGPoint(x: bounds.midX, y: bounds.minY)))
    }

    private func menuActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
                self?.clear()
            },
        ]
        if let link {
            actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) {
                [weak self] _ in
                guard let self else { return }
                _ = terminal?.open(link)
                clear()
            })
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) {
                [weak self] _ in
                UIPasteboard.general.string = link.target
                self?.clear()
            })
        }
        actions.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) {
            [weak self] _ in
            self?.selectAll()
        })
        actions.append(UIAction(title: "Select Text…", image: UIImage(systemName: "text.cursor")) {
            [weak self] _ in
            self?.presentTextSheet()
        })
        return actions
    }

    private func selectAll() {
        guard let grid, grid.rowCount > 0, grid.columns > 0 else { return }
        link = nil
        selection = TerminalGridSelection(
            anchor: TerminalGridCell(row: 1, column: 1),
            focus: TerminalGridCell(row: grid.rowCount, column: grid.columns))
        redraw()
        // The menu that ran this action is still on its way out.
        DispatchQueue.main.async { [weak self] in
            self?.presentMenu()
        }
    }

    /// The Select Text sheet, with the current selection already highlighted,
    /// for a finer selection than cells allow.
    private func presentTextSheet() {
        guard let terminal, let selection, let grid else { return }
        let anchorRange = TerminalSelectionText.utf16Range(of: selection, in: grid)
        let text = viewportText
        clear()
        TerminalTextSelectionPresenter.present(text: text, anchorRange: anchorRange, from: terminal)
    }
}

extension TerminalSelectionController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let terminal else { return false }
        if gestureRecognizer === longPress {
            let point = gestureRecognizer.location(in: terminal)
            if selection != nil, handle(at: point) != nil {
                return false
            }
            return terminal.gridPointMapper.cell(at: point) != nil
        }
        if gestureRecognizer === handlePan {
            guard selection != nil,
                let end = handle(at: gestureRecognizer.location(in: terminal))
            else { return false }
            draggedEnd = end
            return true
        }
        return true
    }
}

extension TerminalSelectionController: @MainActor UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard selection != nil else { return nil }
        return UIMenu(children: menuActions())
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionBounds ?? .null
    }
}
