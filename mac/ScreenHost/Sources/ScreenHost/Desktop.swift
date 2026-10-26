import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import ScreenProtocol

struct Desktop {
    static func access(request: Bool = false) -> ScreenWire.Access {
        let screen = CGPreflightScreenCaptureAccess()
        let input = AXIsProcessTrusted()
        if request {
            if !screen { CGRequestScreenCaptureAccess() }
            if !input { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        }
        return .init(screen: screen, input: input)
    }

    static func locked(session: [String: Any]? = CGSessionCopyCurrentDictionary() as? [String: Any]) -> Bool {
        session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func displays() -> [ScreenWire.Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id }
            let mode = CGDisplayCopyDisplayMode(id)
            return .init(id: id, name: screen?.localizedName ?? "Display \(id)",
                         frame: .init(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                         pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                         pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id), isMain: id == CGMainDisplayID())
        }
    }

    static var pointer: ScreenWire.Point {
        let point = CGEvent(source: nil)?.location ?? .zero
        return .init(x: point.x, y: point.y)
    }

    static func wake() {
        var assertion = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("Term Screen connection" as CFString, kIOPMUserActiveLocal, &assertion)
    }
}

final class DisplayPower {
    private var assertion = IOPMAssertionID(0)
    func hold(_ active: Bool) {
        if active && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Term Screen streaming" as CFString, &assertion)
        } else if !active && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
    deinit { hold(false) }
}

final class Clipboard {
    static let types = ["public.utf8-plain-text", "public.rtf", "public.html", "public.png", "public.url"]
    private let pasteboard: NSPasteboard
    private var count: Int

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        count = pasteboard.changeCount
    }

    func reset() { count = pasteboard.changeCount }

    func changed() -> ScreenWire.Clipboard? {
        guard count != pasteboard.changeCount else { return nil }
        count = pasteboard.changeCount
        var items = Self.types.compactMap { type -> ScreenWire.ClipboardItem? in
            guard let data = pasteboard.data(forType: .init(type)) else { return nil }
            return .init(type: type, data: data)
        }
        if !items.contains(where: { $0.type == "public.png" }),
           let tiff = pasteboard.data(forType: .tiff),
           let image = NSBitmapImageRep(data: tiff),
           let png = image.representation(using: .png, properties: [:]) {
            items.append(.init(type: "public.png", data: png))
        }
        return .init(items: items)
    }

    func set(_ clipboard: ScreenWire.Clipboard) {
        let item = NSPasteboardItem()
        for representation in clipboard.items where Self.types.contains(representation.type) {
            item.setData(representation.data, forType: .init(representation.type))
        }
        pasteboard.clearContents()
        if !item.types.isEmpty { pasteboard.writeObjects([item]) }
        count = pasteboard.changeCount
    }
}

final class Cursor {
    private var previous: Data?
    func reset() { previous = nil }
    func changed() -> ScreenWire.CursorImage? {
        guard let cursor = NSCursor.currentSystem else {
            guard previous != Data() else { return nil }
            previous = Data()
            return .init(png: Data(), scale: 1, hotX: 0, hotY: 0)
        }
        guard let tiff = cursor.image.tiffRepresentation, tiff != previous,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        previous = tiff
        return .init(png: png, scale: Double(bitmap.pixelsWide) / max(1, cursor.image.size.width),
                     hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y)
    }
}
