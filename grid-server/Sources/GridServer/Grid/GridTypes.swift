import Foundation

// MARK: - Direction

enum GridDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down

    init?(from string: String) {
        self.init(rawValue: string.lowercased())
    }
}

// MARK: - Stack Mode

enum GridStackMode: String, Codable, Sendable {
    case vertical
    case horizontal
    case tabs
}

// MARK: - Track Types

enum GridTrackType: String, Codable, Sendable {
    case fr
    case px
    case auto
    case minmax
}

struct GridTrackSize: Equatable, Sendable {
    var type: GridTrackType
    var value: Double = 0
    var min: Double = 0
    var max: Double = 0

    static func parse(_ string: String) throws -> GridTrackSize {
        let s = string.trimmingCharacters(in: .whitespaces)

        if s == "auto" {
            return GridTrackSize(type: .auto)
        }

        // Match Nfr
        if s.hasSuffix("fr") {
            let numStr = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard let value = Double(numStr) else {
                throw GridConfigError.invalidTrackSize(string)
            }
            return GridTrackSize(type: .fr, value: value)
        }

        // Match minmax(Npx, Nfr) - must check before px suffix
        if s.hasPrefix("minmax") {
            return try parseMinmax(s, original: string)
        }

        // Match Npx
        if s.hasSuffix("px") {
            let numStr = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard let value = Double(numStr) else {
                throw GridConfigError.invalidTrackSize(string)
            }
            return GridTrackSize(type: .px, value: value)
        }

        throw GridConfigError.invalidTrackSize(string)
    }

    private static func parseMinmax(_ s: String, original: String) throws -> GridTrackSize {
        // Extract contents between parentheses
        guard let openParen = s.firstIndex(of: "("),
              let closeParen = s.lastIndex(of: ")") else {
            throw GridConfigError.invalidTrackSize(original)
        }
        let inner = s[s.index(after: openParen)..<closeParen]
            .trimmingCharacters(in: .whitespaces)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else {
            throw GridConfigError.invalidTrackSize(original)
        }

        // First part: Npx
        guard parts[0].hasSuffix("px") else {
            throw GridConfigError.invalidTrackSize(original)
        }
        let minStr = String(parts[0].dropLast(2)).trimmingCharacters(in: .whitespaces)
        guard let minVal = Double(minStr) else {
            throw GridConfigError.invalidTrackSize(original)
        }

        // Second part: Nfr
        guard parts[1].hasSuffix("fr") else {
            throw GridConfigError.invalidTrackSize(original)
        }
        let maxStr = String(parts[1].dropLast(2)).trimmingCharacters(in: .whitespaces)
        guard let maxVal = Double(maxStr) else {
            throw GridConfigError.invalidTrackSize(original)
        }

        return GridTrackSize(type: .minmax, min: minVal, max: maxVal)
    }

    var description: String {
        switch type {
        case .fr:
            if value == Double(Int(value)) {
                return "\(Int(value))fr"
            }
            return String(format: "%.2ffr", value)
        case .px:
            if value == Double(Int(value)) {
                return "\(Int(value))px"
            }
            return String(format: "%.2fpx", value)
        case .auto:
            return "auto"
        case .minmax:
            return "minmax(\(Int(min))px, \(Int(max))fr)"
        }
    }
}

// MARK: - Padding

struct GridPaddingValue: Equatable, Sendable {
    var pixels: Double = 0
    var baseMultiple: Double = 0
    var isRelative: Bool = false

    func resolve(baseSpacing: Double) -> Double {
        if isRelative {
            return baseMultiple * baseSpacing
        }
        return pixels
    }

    static func parse(_ value: Any) throws -> GridPaddingValue {
        if let intVal = value as? Int {
            return GridPaddingValue(pixels: Double(intVal))
        }
        if let doubleVal = value as? Double {
            return GridPaddingValue(pixels: doubleVal)
        }
        if let strVal = value as? String {
            let s = strVal.trimmingCharacters(in: .whitespaces)
            // Check for "Nx" pattern (base-relative)
            if s.hasSuffix("x") && !s.hasSuffix("px") {
                let numStr = String(s.dropLast(1))
                guard let mult = Double(numStr) else {
                    throw GridConfigError.invalidPaddingValue(strVal)
                }
                return GridPaddingValue(baseMultiple: mult, isRelative: true)
            }
            // Check for "Npx" pattern
            if s.hasSuffix("px") {
                let numStr = String(s.dropLast(2))
                guard let px = Double(numStr) else {
                    throw GridConfigError.invalidPaddingValue(strVal)
                }
                return GridPaddingValue(pixels: px)
            }
            // Plain number string
            guard let px = Double(s) else {
                throw GridConfigError.invalidPaddingValue(strVal)
            }
            return GridPaddingValue(pixels: px)
        }
        throw GridConfigError.invalidPaddingValue("\(value)")
    }
}

struct GridPadding: Equatable, Sendable {
    var top: GridPaddingValue
    var right: GridPaddingValue
    var bottom: GridPaddingValue
    var left: GridPaddingValue

    func resolve(baseSpacing: Double) -> GridResolvedPadding {
        GridResolvedPadding(
            top: top.resolve(baseSpacing: baseSpacing),
            right: right.resolve(baseSpacing: baseSpacing),
            bottom: bottom.resolve(baseSpacing: baseSpacing),
            left: left.resolve(baseSpacing: baseSpacing)
        )
    }

    var isZero: Bool {
        top.pixels == 0 && top.baseMultiple == 0 && !top.isRelative &&
        right.pixels == 0 && right.baseMultiple == 0 && !right.isRelative &&
        bottom.pixels == 0 && bottom.baseMultiple == 0 && !bottom.isRelative &&
        left.pixels == 0 && left.baseMultiple == 0 && !left.isRelative
    }

    static func parse(_ raw: Any?) throws -> GridPadding? {
        guard let raw = raw else { return nil }

        if let intVal = raw as? Int {
            let pv = GridPaddingValue(pixels: Double(intVal))
            return GridPadding(top: pv, right: pv, bottom: pv, left: pv)
        }
        if let doubleVal = raw as? Double {
            let pv = GridPaddingValue(pixels: doubleVal)
            return GridPadding(top: pv, right: pv, bottom: pv, left: pv)
        }
        if let strVal = raw as? String {
            let pv = try GridPaddingValue.parse(strVal)
            return GridPadding(top: pv, right: pv, bottom: pv, left: pv)
        }
        if let arr = raw as? [Any] {
            let values = try arr.map { try GridPaddingValue.parse($0) }
            switch values.count {
            case 2:
                return GridPadding(top: values[0], right: values[1], bottom: values[0], left: values[1])
            case 4:
                return GridPadding(top: values[0], right: values[1], bottom: values[2], left: values[3])
            default:
                throw GridConfigError.invalidPaddingFormat("array must have 2 or 4 values, got \(values.count)")
            }
        }
        if let dict = raw as? [String: Any] {
            var padding = GridPadding(
                top: GridPaddingValue(),
                right: GridPaddingValue(),
                bottom: GridPaddingValue(),
                left: GridPaddingValue()
            )
            for (key, val) in dict {
                let pv = try GridPaddingValue.parse(val)
                switch key {
                case "top": padding.top = pv
                case "right": padding.right = pv
                case "bottom": padding.bottom = pv
                case "left": padding.left = pv
                default:
                    throw GridConfigError.invalidPaddingFormat("unknown padding key: \(key)")
                }
            }
            return padding
        }
        throw GridConfigError.invalidPaddingFormat("\(type(of: raw))")
    }
}

struct GridResolvedPadding: Sendable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double
}

// MARK: - Cell Border Config

struct GridCellBorderConfig: Sendable {
    var activeCellColor: String?
    var inactiveColor: String?
    var style: String?
}

// MARK: - Cell Definition

struct GridCellDef: Sendable {
    var id: String
    var columnStart: Int
    var columnEnd: Int
    var rowStart: Int
    var rowEnd: Int
    var stackMode: GridStackMode?
    var padding: GridPadding?
    var windowSpacing: GridPaddingValue?
    var border: GridCellBorderConfig?
}

// MARK: - Layout Definition

struct GridLayoutDef: Sendable {
    var id: String
    var name: String
    var description: String
    var columns: [GridTrackSize]
    var rows: [GridTrackSize]
    var cells: [GridCellDef]
    var cellModes: [String: GridStackMode]
    var padding: GridPadding?
    var windowSpacing: GridPaddingValue?
}

// MARK: - Assignment Strategy

enum GridAssignmentStrategy: Sendable {
    case autoFlow
    case pinned
    case preserve
    case position
}

// MARK: - Errors

enum GridConfigError: Error, LocalizedError {
    case invalidTrackSize(String)
    case invalidPaddingValue(String)
    case invalidPaddingFormat(String)
    case invalidSpan(String)
    case layoutNotFound(String)
    case validationError(String)
    case noConfigFound(searchedPaths: [String])

    var errorDescription: String? {
        switch self {
        case .invalidTrackSize(let s): return "invalid track size: \(s)"
        case .invalidPaddingValue(let s): return "invalid padding value: \(s)"
        case .invalidPaddingFormat(let s): return "invalid padding format: \(s)"
        case .invalidSpan(let s): return "invalid span: \(s)"
        case .layoutNotFound(let s): return "layout not found: \(s)"
        case .validationError(let s): return "validation error: \(s)"
        case .noConfigFound(let paths): return "no config found, searched: \(paths.joined(separator: ", "))"
        }
    }
}
