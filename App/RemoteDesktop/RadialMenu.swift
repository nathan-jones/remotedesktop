import UIKit

/// A ring of actions that opens under the fingers. Slide to an action and lift
/// to choose it, or lift in the middle and tap one.
final class RadialMenuView: UIView {
    struct Item {
        let title: String
        let symbol: String
        let action: () -> Void
    }

    private let items: [Item]
    private let onDismiss: () -> Void
    private var buttons: [UIButton] = []
    private var centrePoint = CGPoint.zero
    private var highlighted: Int?
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private static let ringRadius: CGFloat = 96
    private static let buttonSize: CGFloat = 72

    init(items: [Item], onDismiss: @escaping () -> Void) {
        self.items = items
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.3)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismiss)))

        for (index, item) in items.enumerated() {
            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: item.symbol)
            configuration.title = item.title
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 11, weight: .semibold)
                return attributes
            }
            configuration.cornerStyle = .capsule
            let button = UIButton(configuration: configuration)
            button.tag = index
            button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            buttons.append(button)
            addSubview(button)
        }
        setHighlighted(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the menu over `parent`, centred as near to `point` as fits.
    func present(in parent: UIView, at point: CGPoint) {
        frame = parent.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let margin = RadialMenuView.ringRadius + RadialMenuView.buttonSize / 2 + 8
        centrePoint = CGPoint(
            x: min(max(point.x, margin), max(margin, bounds.width - margin)),
            y: min(max(point.y, margin), max(margin, bounds.height - margin)))

        for (index, button) in buttons.enumerated() {
            // First item at the top, then clockwise.
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(buttons.count)
            button.bounds = CGRect(x: 0, y: 0, width: RadialMenuView.buttonSize, height: RadialMenuView.buttonSize)
            button.center = CGPoint(x: centrePoint.x + cos(angle) * RadialMenuView.ringRadius,
                                    y: centrePoint.y + sin(angle) * RadialMenuView.ringRadius)
        }

        parent.addSubview(self)
        alpha = 0
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        selectionFeedback.prepare()
    }

    /// Follows the fingers that opened the menu, highlighting the action they point at.
    func track(_ point: CGPoint) {
        let offset = CGPoint(x: point.x - centrePoint.x, y: point.y - centrePoint.y)
        guard hypot(offset.x, offset.y) > 36 else {
            setHighlighted(nil)
            return
        }
        let nearest = buttons.indices.min {
            distance(buttons[$0].center, point) < distance(buttons[$1].center, point)
        }
        setHighlighted(nearest)
    }

    /// The fingers lifted: runs the highlighted action, or leaves the menu open for a tap.
    func release() {
        guard let highlighted else { return }
        items[highlighted].action()
        dismiss()
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func setHighlighted(_ index: Int?) {
        if index != highlighted, index != nil { selectionFeedback.selectionChanged() }
        highlighted = index
        for (position, button) in buttons.enumerated() {
            let active = position == index
            button.configuration?.baseBackgroundColor = active ? .tintColor : UIColor(white: 0.16, alpha: 0.96)
            button.configuration?.baseForegroundColor = .white
            button.transform = active ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        items[sender.tag].action()
        dismiss()
    }

    @objc func dismiss() {
        guard superview != nil else { return }
        UIView.animate(withDuration: 0.12, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
        onDismiss()
    }
}
