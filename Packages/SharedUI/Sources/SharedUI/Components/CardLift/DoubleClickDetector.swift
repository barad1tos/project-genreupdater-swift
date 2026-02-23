// DoubleClickDetector.swift -- NSViewRepresentable for macOS double-click detection.

import AppKit
import SwiftUI

// MARK: - Double Click Detector

/// Transparent overlay that detects double-clicks without interfering with single-click List selection.
///
/// Place as an `.overlay` on List rows. Single clicks propagate normally through `super.mouseDown`;
/// double clicks additionally fire the `action` closure.
public struct DoubleClickDetector: NSViewRepresentable {
    private let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    public func makeNSView(context: Context) -> DoubleClickNSView {
        DoubleClickNSView(action: action)
    }

    public func updateNSView(_ nsView: DoubleClickNSView, context: Context) {
        nsView.action = action
    }

    // MARK: - NSView Subclass

    // periphery:ignore
    /// Custom NSView that fires an action on double-click while allowing single-click propagation.
    public class DoubleClickNSView: NSView {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 {
                action()
            }
        }
    }
}
