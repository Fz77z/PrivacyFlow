import CoreGraphics
import Foundation

/// A display's usable area, in top-left, y-down coordinates measured from the
/// primary display, so it compares directly with a remembered position.
public struct WorkArea: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func contains(_ centre: Centre) -> Bool {
        centre.x >= x && centre.x <= x + width && centre.y >= y && centre.y <= y + height
    }
}

/// The middle of the capsule, in top-left, y-down coordinates.
///
/// The centre is remembered rather than a corner because the capsule changes
/// size in minimal mode: a centre stays put while a corner moves.
public struct Centre: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Remembering where the user put the capsule, in `window.json`.
public enum WindowPosition {
    private struct Stored: Codable {
        var center_x: Double
        var center_y: Double
    }

    public static func url(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("window.json")
    }

    /// Where the capsule was last left, if that is still on a connected display.
    ///
    /// A remembered position is not trusted. The capsule is borderless, so
    /// macOS does not rescue one restored off screen, and with no Dock icon a
    /// capsule nobody can see is an app nobody can reach.
    public static func load(from dataDirectory: URL, areas: [WorkArea]) -> Centre? {
        guard let data = try? Data(contentsOf: url(in: dataDirectory)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        let centre = Centre(x: stored.center_x, y: stored.center_y)
        guard centre.x.isFinite, centre.y.isFinite, isReachable(centre, areas: areas) else {
            return nil
        }
        return centre
    }

    /// Record where the capsule now sits. A failure loses a convenience and
    /// nothing else, so it is returned for logging rather than shown.
    public static func save(_ centre: Centre, to dataDirectory: URL) -> String? {
        do {
            let data = try JSONEncoder().encode(Stored(center_x: centre.x, center_y: centre.y))
            try data.write(to: url(in: dataDirectory), options: .atomic)
            return nil
        } catch {
            return "PrivacyFlow could not remember the capsule's position: \(error.localizedDescription)"
        }
    }

    /// Whether a centre lands on a display. An empty list means the displays
    /// could not be read, which is not permission to restore anything.
    public static func isReachable(_ centre: Centre, areas: [WorkArea]) -> Bool {
        area(for: centre, in: areas) != nil
    }

    public static func area(for centre: Centre, in areas: [WorkArea]) -> WorkArea? {
        areas.first { $0.contains(centre) }
    }

    /// The top left corner for a window of `size` centred on `centre`, pushed
    /// back inside the display the centre is on, not the first display, so a
    /// capsule on a second monitor is never dragged onto the primary one.
    public static func place(_ centre: Centre, size: CGSize, areas: [WorkArea]) -> (x: Double, y: Double) {
        let left = centre.x - size.width / 2
        let top = centre.y - size.height / 2
        guard let area = area(for: centre, in: areas) else {
            return (left.rounded(), top.rounded())
        }
        // A window larger than the display makes the bounds cross, and the
        // left and top edges win: a capsule running off the right is still
        // grabbable, one running off the left is not.
        func clamp(_ value: Double, low: Double, span: Double, extent: Double) -> Double {
            max(min(value, low + span - extent), low)
        }
        return (
            clamp(left, low: area.x, span: area.width, extent: size.width).rounded(),
            clamp(top, low: area.y, span: area.height, extent: size.height).rounded()
        )
    }
}
