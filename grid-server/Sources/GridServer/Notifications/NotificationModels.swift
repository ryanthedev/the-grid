//
// NotificationModels.swift
// GridServer
//
// Data structures for the notification system.
//

import Foundation
import CoreGraphics

/// Notification anchor positions within a cell
enum NotificationAnchor: String, Codable {
    case topRight = "top-right"
    case topLeft = "top-left"
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case center = "center"
}

/// Position specification for a notification
struct NotificationPosition: Codable {
    /// Cell bounds from CLI (where to anchor the notification)
    let bounds: CGRect
    /// Anchor point within the cell bounds
    let anchor: NotificationAnchor

    private enum CodingKeys: String, CodingKey {
        case bounds, anchor
    }

    init(bounds: CGRect, anchor: NotificationAnchor) {
        self.bounds = bounds
        self.anchor = anchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode anchor
        anchor = try container.decode(NotificationAnchor.self, forKey: .anchor)

        // Decode bounds from nested dict
        let boundsContainer = try container.nestedContainer(keyedBy: BoundsCodingKeys.self, forKey: .bounds)
        let x = try boundsContainer.decode(Double.self, forKey: .x)
        let y = try boundsContainer.decode(Double.self, forKey: .y)
        let width = try boundsContainer.decode(Double.self, forKey: .width)
        let height = try boundsContainer.decode(Double.self, forKey: .height)
        bounds = CGRect(x: x, y: y, width: width, height: height)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(anchor, forKey: .anchor)

        var boundsContainer = container.nestedContainer(keyedBy: BoundsCodingKeys.self, forKey: .bounds)
        try boundsContainer.encode(bounds.origin.x, forKey: .x)
        try boundsContainer.encode(bounds.origin.y, forKey: .y)
        try boundsContainer.encode(bounds.size.width, forKey: .width)
        try boundsContainer.encode(bounds.size.height, forKey: .height)
    }

    private enum BoundsCodingKeys: String, CodingKey {
        case x, y, width, height
    }
}

/// Active notification state (in-memory)
class NotificationState {
    let id: String
    let title: String
    let body: String?
    let buttons: [String]?
    let hasTextInput: Bool
    let textMaxLength: Int
    let timeout: Int?
    let position: NotificationPosition
    let createdAt: Date
    let originSocket: Int32

    /// Server-side timeout timer
    var timeoutTimer: DispatchSourceTimer?

    init(
        id: String,
        title: String,
        body: String?,
        buttons: [String]?,
        hasTextInput: Bool,
        textMaxLength: Int,
        timeout: Int?,
        position: NotificationPosition,
        originSocket: Int32
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.buttons = buttons
        self.hasTextInput = hasTextInput
        self.textMaxLength = textMaxLength
        self.timeout = timeout
        self.position = position
        self.createdAt = Date()
        self.originSocket = originSocket
    }
}

/// Cached notification response (persisted to disk)
struct CachedNotificationResponse: Codable {
    let notificationId: String
    let button: String?
    let text: String?
    let cancelled: Bool
    let timedOut: Bool
    let timestamp: Date

    init(
        notificationId: String,
        button: String? = nil,
        text: String? = nil,
        cancelled: Bool = false,
        timedOut: Bool = false
    ) {
        self.notificationId = notificationId
        self.button = button
        self.text = text
        self.cancelled = cancelled
        self.timedOut = timedOut
        self.timestamp = Date()
    }
}

/// Parameters for creating a notification
struct CreateNotificationParams {
    let notificationId: String
    let title: String
    let body: String?
    let buttons: [String]?
    let textInput: Bool
    let textMaxLength: Int
    let timeout: Int?
    let position: NotificationPosition

    /// Parse from request params
    static func parse(from params: [String: AnyCodable]) -> CreateNotificationParams? {
        guard let notificationId = params["notificationId"]?.value as? String,
              let title = params["title"]?.value as? String else {
            return nil
        }

        let body = params["body"]?.value as? String
        let buttons = params["buttons"]?.value as? [String]
        let textInput = params["textInput"]?.value as? Bool ?? false
        let textMaxLength = (params["textMaxLength"]?.value as? Int) ?? 1000
        let timeout = params["timeout"]?.value as? Int

        // Parse position
        guard let positionDict = params["position"]?.value as? [String: Any],
              let boundsDict = positionDict["bounds"] as? [String: Any],
              let anchorStr = positionDict["anchor"] as? String,
              let anchor = NotificationAnchor(rawValue: anchorStr),
              let x = (boundsDict["x"] as? NSNumber)?.doubleValue,
              let y = (boundsDict["y"] as? NSNumber)?.doubleValue,
              let width = (boundsDict["width"] as? NSNumber)?.doubleValue,
              let height = (boundsDict["height"] as? NSNumber)?.doubleValue else {
            return nil
        }

        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let position = NotificationPosition(bounds: bounds, anchor: anchor)

        return CreateNotificationParams(
            notificationId: notificationId,
            title: title,
            body: body,
            buttons: buttons,
            textInput: textInput,
            textMaxLength: textMaxLength,
            timeout: timeout,
            position: position
        )
    }
}

/// Notification list filter
enum NotificationListFilter: String {
    case active
    case cached
    case all
}
