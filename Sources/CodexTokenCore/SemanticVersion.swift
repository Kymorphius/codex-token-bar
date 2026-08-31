import Foundation

public enum SemanticVersion {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = numericParts(of: normalized(candidate))
        let currentParts = numericParts(of: normalized(current))
        let count = max(candidateParts.count, currentParts.count)

        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    public static func normalized(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    private static func numericParts(of version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}
