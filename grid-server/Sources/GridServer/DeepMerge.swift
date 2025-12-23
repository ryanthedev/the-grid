import Foundation

/// Deep merge two dictionaries with XDG config semantics:
/// - Objects: merge recursively
/// - Arrays: override replaces base
/// - NSNull/nil: removes key from result
/// - Scalars: override wins
public func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
    var result = base

    for (key, overrideValue) in override {
        // null/NSNull removes the key
        if overrideValue is NSNull {
            result.removeValue(forKey: key)
            continue
        }

        guard let baseValue = result[key] else {
            result[key] = overrideValue
            continue
        }

        // If both are dictionaries, merge recursively
        if let baseDict = baseValue as? [String: Any],
           let overrideDict = overrideValue as? [String: Any] {
            result[key] = deepMerge(baseDict, overrideDict)
        } else {
            // Override wins (including arrays)
            result[key] = overrideValue
        }
    }

    return result
}
