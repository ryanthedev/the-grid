import Foundation

/// Represents the different types of messages that can be sent over the socket
enum MessageType: String, Codable {
    case request
    case response
    case event
}

/// Base message envelope that wraps all message types
struct Message: Codable {
    let type: MessageType
    let request: Request?
    let response: Response?
    let event: Event?

    init(request: Request) {
        self.type = .request
        self.request = request
        self.response = nil
        self.event = nil
    }

    init(response: Response) {
        self.type = .response
        self.request = nil
        self.response = response
        self.event = nil
    }

    init(event: Event) {
        self.type = .event
        self.request = nil
        self.response = nil
        self.event = event
    }
}

/// Request message sent from client to server
struct Request: Codable {
    let id: String
    let method: String
    let params: [String: AnyCodable]?

    init(id: String = UUID().uuidString, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Response message sent from server back to client
struct Response: Codable {
    let id: String  // Matches the request ID
    let result: AnyCodable?
    let error: ErrorInfo?

    init(id: String, result: AnyCodable) {
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: String, error: ErrorInfo) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// Error information for failed requests
struct ErrorInfo: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?

    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Event message broadcast from server to clients
struct Event: Codable {
    let eventType: String
    let data: AnyCodable?
    let timestamp: Date

    init(eventType: String, data: AnyCodable? = nil) {
        self.eventType = eventType
        self.data = data
        self.timestamp = Date()
    }
}

/// Helper type to encode/decode arbitrary JSON values
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if container.decodeNil() {
            value = Optional<Any>.none as Any
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case is Optional<Any>:
            try container.encodeNil()
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Unsupported value type"
            ))
        }
    }
}
