// Sources/InAppDriver/ScreenControl.swift
#if DEBUG && canImport(UIKit) && !os(watchOS)
import AVFoundation
import UIKit

/// Debug-only, in-process screen access: read the on-screen elements, tap, scroll, type, and take a
/// screenshot — without an external UI-test runner.
///
/// It works from *inside* the app, so it can only see and drive this app's own windows: no system
/// alerts, no home screen, no other apps. Taps are delivered by activating the element under the
/// point (control action / accessibility activation), not by synthesizing a hardware touch — custom
/// gesture-only views that expose no accessibility action cannot be tapped.
///
/// All coordinates are screen **points** (the same space as `accessibilityFrame`); the screenshot is
/// rendered at the screen scale, so its pixels are `scale`× larger.
@MainActor
enum ScreenControl {
    struct Failure: Error {
        let message: String
    }

    // MARK: - Elements

    private struct Element {
        let object: NSObject
        let window: Int
        let frame: CGRect
        let type: String
        let label: String
        let value: String
        let identifier: String
        let traits: [String]
    }

    /// JSON description of the screen: `{"screen":{w,h,scale},"elements":[{type,label,value,id,traits,x,y,w,h,cx,cy}]}`.
    /// Elements are listed back-to-front (later windows are on top); `cx`/`cy` is the point to tap.
    static func dump() -> String {
        let screen = screenBounds()
        let elements = collectElements().map { e -> [String: Any] in
            var item: [String: Any] = [
                "type": e.type,
                "label": e.label,
                "x": rounded(e.frame.minX), "y": rounded(e.frame.minY),
                "w": rounded(e.frame.width), "h": rounded(e.frame.height),
                "cx": rounded(e.frame.midX), "cy": rounded(e.frame.midY),
            ]
            if !e.value.isEmpty { item["value"] = e.value }
            if !e.identifier.isEmpty { item["id"] = e.identifier }
            if !e.traits.isEmpty { item["traits"] = e.traits }
            return item
        }
        let root: [String: Any] = [
            "screen": ["w": rounded(screen.width), "h": rounded(screen.height), "scale": Double(screenScale())],
            "accessibility": accessibilityBootstrapped,
            "elements": elements,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tap

    /// Activates whatever is under the point. Returns a short description of what was done.
    static func tap(x: Double, y: Double) throws -> String {
        let point = CGPoint(x: x, y: y)

        // 1. The accessibility element under the point (topmost window, then smallest frame).
        let hits = collectElements().filter { $0.frame.contains(point) }
        if let top = hits.map(\.window).max() {
            let candidates = hits.filter { $0.window == top }
                .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            for element in candidates {
                if let how = activate(element.object) {
                    return "\(how): \(element.label.isEmpty ? element.type : element.label)"
                }
            }
        }

        // 2. The view under the point and its ancestors (controls, table/collection cells, tap recognizers).
        for window in windows().reversed() {
            let local = window.convert(point, from: window.screen.coordinateSpace)
            guard let hit = window.hitTest(local, with: nil) else { continue }
            var view: UIView? = hit
            while let current = view {
                if let how = activate(current) ?? selectCell(current) ?? fireTapRecognizer(current) {
                    return "\(how): \(String(describing: Swift.type(of: current)))"
                }
                view = current.superview
            }
            break // the topmost window that owns the point decides
        }
        throw Failure(message: "nothing tappable at (\(x), \(y))")
    }

    private static func activate(_ object: NSObject) -> String? {
        if let field = object as? UITextField {
            guard field.isEnabled else { return nil }
            return field.becomeFirstResponder() ? "focus" : nil
        }
        if let textView = object as? UITextView {
            guard textView.isEditable else { return nil }
            return textView.becomeFirstResponder() ? "focus" : nil
        }
        if let toggle = object as? UISwitch {
            guard toggle.isEnabled else { return nil }
            toggle.setOn(!toggle.isOn, animated: true)
            toggle.sendActions(for: .valueChanged)
            return "toggle"
        }
        if let control = object as? UIControl {
            guard control.isEnabled, control.isUserInteractionEnabled else { return nil }
            control.sendActions(for: .touchDown)
            control.sendActions(for: .touchUpInside)
            return "control"
        }
        if !(object is UIView) || object.isAccessibilityElement {
            if object.accessibilityTraits.contains(.notEnabled) { return nil }
            if object.accessibilityActivate() { return "activate" }
        }
        return nil
    }

    private static func selectCell(_ view: UIView) -> String? {
        if let cell = view as? UITableViewCell {
            var parent = cell.superview
            while let current = parent, !(current is UITableView) { parent = current.superview }
            guard let table = parent as? UITableView, let indexPath = table.indexPath(for: cell) else { return nil }
            table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            table.delegate?.tableView?(table, didSelectRowAt: indexPath)
            return "select row"
        }
        if let cell = view as? UICollectionViewCell {
            var parent = cell.superview
            while let current = parent, !(current is UICollectionView) { parent = current.superview }
            guard let collection = parent as? UICollectionView, let indexPath = collection.indexPath(for: cell),
                  let delegate = collection.delegate,
                  delegate.responds(to: #selector(UICollectionViewDelegate.collectionView(_:didSelectItemAt:)))
            else { return nil }
            collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
            delegate.collectionView?(collection, didSelectItemAt: indexPath)
            return "select item"
        }
        return nil
    }

    /// Last resort for views that only have a `UITapGestureRecognizer`: call its target/action pairs
    /// directly. Reads UIKit's private target list, so it is best-effort and simply fails soft.
    private static func fireTapRecognizer(_ view: UIView) -> String? {
        guard view.isUserInteractionEnabled else { return nil }
        for recognizer in view.gestureRecognizers ?? [] where recognizer.isEnabled {
            guard let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1,
                  let targets = tap.value(forKey: "targets") as? [NSObject], !targets.isEmpty else { continue }
            var fired = false
            for entry in targets {
                // description looks like "(action=handleTap:, target=<Foo 0x…>)"
                let description = String(describing: entry)
                guard let target = entry.value(forKey: "target") as? NSObject,
                      let start = description.range(of: "action=")?.upperBound,
                      let end = description[start...].firstIndex(of: ",") else { continue }
                let selector = NSSelectorFromString(String(description[start..<end]))
                guard target.responds(to: selector) else { continue }
                _ = target.perform(selector, with: tap)
                fired = true
            }
            if fired { return "tap recognizer" }
        }
        return nil
    }

    // MARK: - Swipe

    /// Scrolls the scroll view under the start point by the drag distance (finger moves from → to).
    static func swipe(x1: Double, y1: Double, x2: Double, y2: Double) throws -> String {
        let start = CGPoint(x: x1, y: y1)
        let delta = CGPoint(x: x1 - x2, y: y1 - y2)
        for window in windows().reversed() {
            let local = window.convert(start, from: window.screen.coordinateSpace)
            guard let hit = window.hitTest(local, with: nil) else { continue }
            var view: UIView? = hit
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                    let inset = scroll.adjustedContentInset
                    let maxX = max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)
                    let maxY = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
                    let old = scroll.contentOffset
                    let new = CGPoint(
                        x: min(max(old.x + delta.x, -inset.left), maxX),
                        y: min(max(old.y + delta.y, -inset.top), maxY)
                    )
                    if abs(new.x - old.x) > 0.5 || abs(new.y - old.y) > 0.5 {
                        scroll.setContentOffset(new, animated: false)
                        scroll.layoutIfNeeded()
                        return "scrolled by (\(rounded(new.x - old.x)), \(rounded(new.y - old.y)))"
                    }
                }
                view = current.superview
            }
            break
        }
        throw Failure(message: "no scrollable view at (\(x1), \(y1)) that can move in that direction")
    }

    // MARK: - Text

    /// Types into the current first responder (tap a text field first).
    static func type(_ text: String) throws -> String {
        for window in windows().reversed() {
            guard let responder = firstResponder(in: window) else { continue }
            guard let input = responder as? UIKeyInput else { break }
            input.insertText(text)
            return "typed \(text.count) characters"
        }
        throw Failure(message: "no focused text input — tap a text field first")
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Screenshot

    static func screenshotPNG() -> Data? {
        let visible = windows()
        guard !visible.isEmpty else { return nil }
        let bounds = screenBounds()
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale()

        // Video layers render blank in an in-process snapshot — which also hides anything light drawn
        // on top of them. Stand in a still of the current frame for the duration of the render.
        let stills = visible.flatMap { playerLayers(in: $0.layer) }.compactMap(addStill(to:))
        defer { stills.forEach { $0.removeFromSuperlayer() } }

        return UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            for window in visible {
                // `afterScreenUpdates: true` — without it, layers that have not been committed yet
                // (backgrounds, freshly pushed screens, the stills above) come out blank.
                window.drawHierarchy(in: window.frame, afterScreenUpdates: true)
            }
        }
    }

    private static func playerLayers(in layer: CALayer) -> [AVPlayerLayer] {
        if layer.isHidden || layer.opacity < 0.01 { return [] }
        var found: [AVPlayerLayer] = []
        if let player = layer as? AVPlayerLayer { found.append(player) }
        for sublayer in layer.sublayers ?? [] {
            found += playerLayers(in: sublayer)
        }
        return found
    }

    /// Adds the player's current frame as a plain image sublayer and returns it (the caller removes
    /// it). Returns nil when the frame cannot be read synchronously — e.g. a remote stream.
    private static func addStill(to playerLayer: AVPlayerLayer) -> CALayer? {
        guard let player = playerLayer.player, let asset = player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? generator.copyCGImage(at: player.currentTime(), actualTime: nil) else { return nil }

        let still = CALayer()
        still.frame = playerLayer.bounds
        still.contents = frame
        still.masksToBounds = true
        switch playerLayer.videoGravity {
        case .resizeAspectFill: still.contentsGravity = .resizeAspectFill
        case .resize: still.contentsGravity = .resize
        default: still.contentsGravity = .resizeAspect
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.addSublayer(still)
        CATransaction.commit()
        return still
    }

    // MARK: - Collecting

    private static func collectElements() -> [Element] {
        bootstrapAccessibility()
        let screen = screenBounds()
        var out: [Element] = []
        for (index, window) in windows().enumerated() {
            var visited = Set<ObjectIdentifier>()
            collect(window, window: index, screen: screen, depth: 0, visited: &visited, into: &out)
        }
        return out
    }

    private static func collect(
        _ object: NSObject, window: Int, screen: CGRect, depth: Int,
        visited: inout Set<ObjectIdentifier>, into out: inout [Element]
    ) {
        guard depth < 80, visited.insert(ObjectIdentifier(object)).inserted else { return }
        let view = object as? UIView
        if let view, !isVisible(view) { return }
        if object.accessibilityElementsHidden { return }

        if object.isAccessibilityElement {
            var frame = object.accessibilityFrame
            if frame.isEmpty, let view { frame = view.convert(view.bounds, to: view.window?.screen.coordinateSpace ?? view) }
            if !frame.isEmpty, frame.intersects(screen) {
                out.append(Element(
                    object: object, window: window, frame: frame,
                    type: typeName(of: object),
                    label: object.accessibilityLabel ?? "",
                    value: object.accessibilityValue ?? "",
                    identifier: (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "",
                    traits: traitNames(object.accessibilityTraits)
                ))
            }
            return // an accessibility element is a leaf
        }

        if let children = object.accessibilityElements {
            for case let child as NSObject in children {
                collect(child, window: window, screen: screen, depth: depth + 1, visited: &visited, into: &out)
            }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject {
                    collect(child, window: window, screen: screen, depth: depth + 1, visited: &visited, into: &out)
                }
            }
            return
        }
        for subview in view?.subviews ?? [] {
            collect(subview, window: window, screen: screen, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    /// A view reached through `accessibilityElements` skips its ancestors, so check the whole chain.
    private static func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha < 0.01 { return false }
            current = v.superview
        }
        return view.window != nil || view is UIWindow
    }

    private static func typeName(of object: NSObject) -> String {
        if object is UIView { return String(describing: Swift.type(of: object)) }
        let traits = object.accessibilityTraits
        if traits.contains(.button) { return "Button" }
        if traits.contains(.link) { return "Link" }
        if traits.contains(.searchField) { return "SearchField" }
        if traits.contains(.image) { return "Image" }
        if traits.contains(.header) { return "Header" }
        if traits.contains(.adjustable) { return "Adjustable" }
        if traits.contains(.staticText) { return "StaticText" }
        return "Element"
    }

    private static func traitNames(_ traits: UIAccessibilityTraits) -> [String] {
        let known: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.image, "image"),
            (.staticText, "staticText"), (.selected, "selected"), (.notEnabled, "notEnabled"),
            (.adjustable, "adjustable"), (.searchField, "searchField"), (.tabBar, "tabBar"),
        ]
        return known.filter { traits.contains($0.0) }.map(\.1)
    }

    // MARK: - Accessibility bootstrap

    private(set) static var accessibilityBootstrapped = false
    private static var bootstrapAttempted = false

    /// SwiftUI (and some UIKit containers) only build their accessibility tree once the system says
    /// an assistive client is listening. Flip the same switch UI-test frameworks use so the tree
    /// exists without VoiceOver. Private symbols, resolved dynamically; if they are missing the dump
    /// still works for plain UIKit views.
    private static func bootstrapAccessibility() {
        guard !bootstrapAttempted else { return }
        bootstrapAttempted = true
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return }
        typealias Setter = @convention(c) (Int32) -> Void
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let symbol = dlsym(handle, name) {
                unsafeBitCast(symbol, to: Setter.self)(1)
                accessibilityBootstrapped = true
            }
        }
    }

    // MARK: - Windows

    /// `UIApplication.shared` without referencing it directly, so the package still builds when it
    /// is linked into an app-extension-safe target.
    private static var application: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }

    /// Visible windows, back-to-front.
    private static func windows() -> [UIWindow] {
        guard let application else { return [] }
        let all = application.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0.01 }
        return all.enumerated()
            .sorted { ($0.element.windowLevel.rawValue, $0.offset) < ($1.element.windowLevel.rawValue, $1.offset) }
            .map(\.element)
    }

    private static func screenBounds() -> CGRect {
        windows().first?.screen.bounds ?? UIScreen.main.bounds
    }

    private static func screenScale() -> CGFloat {
        windows().first?.screen.scale ?? UIScreen.main.scale
    }

    private static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}
#endif
