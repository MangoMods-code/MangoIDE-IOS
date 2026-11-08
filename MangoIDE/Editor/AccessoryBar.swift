import UIKit

/// The scrollable row of coding keys above the keyboard.
final class AccessoryBar: UIInputView {
    enum Key: Equatable {
        case text(String), tab, outdent, left, right, up, down, undo, redo, comment, snippets, dismiss
    }

    var onKey: ((Key) -> Void)?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var buttons: [UIButton] = []

    init(config: EditorConfig, theme: EditorTheme) {
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth

        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12)
        ])

        add(symbol: "arrow.right.to.line", key: .tab)
        add(symbol: "arrow.left.to.line", key: .outdent)
        if config.accessoryArrows {
            add(symbol: "arrow.left", key: .left)
            add(symbol: "arrow.up", key: .up)
            add(symbol: "arrow.down", key: .down)
            add(symbol: "arrow.right", key: .right)
        }
        if config.accessoryUndo {
            add(symbol: "arrow.uturn.backward", key: .undo)
            add(symbol: "arrow.uturn.forward", key: .redo)
        }
        add(symbol: "number", key: .comment)
        add(symbol: "text.badge.plus", key: .snippets)
        for token in config.accessoryKeys.split(separator: " ") where !token.isEmpty {
            add(title: String(token), key: .text(String(token)))
        }
        add(symbol: "keyboard.chevron.compact.down", key: .dismiss)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    func applyTheme(_ theme: EditorTheme) {
        for b in buttons {
            b.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 1, alpha: 0.9)
            b.tintColor = theme.isDark ? .white : .label
            b.setTitleColor(theme.isDark ? .white : .label, for: .normal)
        }
    }

    private func makeButton(_ key: Key) -> UIButton {
        let b = UIButton(type: .system)
        b.layer.cornerRadius = 7
        b.layer.cornerCurve = .continuous
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        b.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.onKey?(key)
        }, for: .touchUpInside)
        buttons.append(b)
        stack.addArrangedSubview(b)
        return b
    }

    private func add(symbol: String, key: Key) {
        let b = makeButton(key)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
    }

    private func add(title: String, key: Key) {
        let b = makeButton(key)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)
    }
}

extension AccessoryBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
