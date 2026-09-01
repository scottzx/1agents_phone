import SwiftUI
import UIKit

enum MinisNavigationHeaderAlignment {
    case center
    case leading

    fileprivate var frameAlignment: SwiftUI.Alignment {
        switch self {
        case .center: return .center
        case .leading: return .leading
        }
    }
}

/// Shared inline-navigation title used by the app home and conversation pages.
/// Callers choose placement/alignment; an optional accessory slot supports
/// compact status badges or actions without duplicating title typography.
struct MinisNavigationHeader<Accessory: View>: View {
    typealias Alignment = MinisNavigationHeaderAlignment

    let title: String
    var alignment: Alignment
    var leadingInset: CGFloat
    var onTitleTap: (() -> Void)?
    private let accessory: Accessory

    init(
        title: String,
        alignment: Alignment = .center,
        leadingInset: CGFloat = 0,
        onTitleTap: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.alignment = alignment
        self.leadingInset = leadingInset
        self.onTitleTap = onTitleTap
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            titleContent
                .layoutPriority(1)
            accessory
                .fixedSize()
        }
        .padding(.leading, alignment == .leading ? leadingInset : 0)
        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
    }

    @ViewBuilder
    private var titleContent: some View {
        if let onTitleTap {
            Button(action: onTitleTap) {
                titleLabel
            }
            .buttonStyle(.plain)
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        Text(title)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .accessibilityAddTraits(.isHeader)
    }
}

extension MinisNavigationHeader where Accessory == EmptyView {
    init(
        title: String,
        alignment: Alignment = .center,
        leadingInset: CGFloat = 0,
        onTitleTap: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            alignment: alignment,
            leadingInset: leadingInset,
            onTitleTap: onTitleTap,
            accessory: { EmptyView() }
        )
    }
}

/// A page-owned navigation header container that hosts custom Leading, Center and Trailing slots.
struct MinisCustomPageHeader<Leading: View, Center: View, Trailing: View>: View {
    private let leading: Leading
    private let center: Center
    private let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            center
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 88)

            HStack(spacing: 0) {
                leading
                    .fixedSize()
                Spacer(minLength: 0)
                trailing
                    .fixedSize()
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }
}

/// A page-owned navigation header. Unlike a system `.toolbar`, this view is
/// part of the destination's own hierarchy, so its back button, title and
/// actions travel together during push/pop and interactive swipe transitions.
struct MinisPageHeader<Leading: View, Trailing: View>: View {
    let title: String
    var alignment: MinisNavigationHeaderAlignment
    var onTitleTap: (() -> Void)?
    var titleBlurRadius: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    init(
        title: String,
        alignment: MinisNavigationHeaderAlignment = .center,
        onTitleTap: (() -> Void)? = nil,
        titleBlurRadius: CGFloat = 0,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.alignment = alignment
        self.onTitleTap = onTitleTap
        self.titleBlurRadius = titleBlurRadius
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        Group {
            if alignment == .center {
                ZStack {
                    MinisNavigationHeader(
                        title: title,
                        alignment: .center,
                        onTitleTap: onTitleTap
                    )
                    .blur(radius: titleBlurRadius)
                    .allowsHitTesting(titleBlurRadius == 0)
                    .padding(.horizontal, 88)
                    .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 0) {
                        leading
                            .fixedSize()
                        Spacer(minLength: 0)
                        trailing
                            .fixedSize()
                    }
                }
            } else {
                HStack(spacing: 10) {
                    leading
                        .fixedSize()

                    MinisNavigationHeader(
                        title: title,
                        alignment: .leading,
                        onTitleTap: onTitleTap
                    )
                    .blur(radius: titleBlurRadius)
                    .allowsHitTesting(titleBlurRadius == 0)
                    .layoutPriority(1)

                    trailing
                        .fixedSize()
                }
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }
}

/// Consistent circular control used in the leading/trailing slots of
/// `MinisPageHeader`.
struct MinisHeaderIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Keeps UINavigationController's native leading-edge interactive pop active
/// when a destination hides only the visual navigation bar. The navigation
/// controller remains the transition owner; this bridge does not install a
/// competing drag gesture or alter the system animator.
struct MinisInteractivePopBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enableInteractivePopWhenPossible()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var owningNavigationController: UINavigationController?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enableInteractivePopWhenPossible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopWhenPossible()
        }

        func enableInteractivePopWhenPossible() {
            let apply = { [weak self] in
                guard let self,
                      let navigationController = self.resolveNavigationController(),
                      let gesture = navigationController.interactivePopGestureRecognizer
                else { return }

                self.owningNavigationController = navigationController
                // SwiftUI can leave the recognizer enabled but install a
                // delegate that refuses begin after hiding the navigation bar.
                // Own both pieces so the gesture has one explicit condition.
                gesture.delegate = self
                gesture.isEnabled = navigationController.viewControllers.count > 1
            }

            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController = owningNavigationController
                    ?? resolveNavigationController()
            else { return false }
            return navigationController.viewControllers.count > 1
                && navigationController.transitionCoordinator == nil
        }

        private func resolveNavigationController() -> UINavigationController? {
            if let owningNavigationController { return owningNavigationController }
            if let navigationController { return navigationController }

            var ancestor = parent
            while let current = ancestor {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }
                ancestor = current.parent
            }

            guard let root = viewIfLoaded?.window?.rootViewController else { return nil }
            return Self.findNavigationController(in: root)
        }

        private static func findNavigationController(
            in controller: UIViewController
        ) -> UINavigationController? {
            if let navigationController = controller as? UINavigationController {
                return navigationController
            }
            if let presented = controller.presentedViewController,
               let match = findNavigationController(in: presented) {
                return match
            }
            for child in controller.children {
                if let match = findNavigationController(in: child) {
                    return match
                }
            }
            return nil
        }
    }
}
