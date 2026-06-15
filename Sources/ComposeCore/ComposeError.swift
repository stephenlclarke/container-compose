import Foundation

public enum ComposeError: Error, CustomStringConvertible, Equatable {
    case commandFailed(command: String, status: Int32, stderr: String)
    case invalidProject(String)
    case unsupported(String)
    case missingNormalizer(String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(command) failed with exit code \(status)"
            }
            return "\(command) failed with exit code \(status): \(detail)"
        case .invalidProject(let message):
            return "invalid compose project: \(message)"
        case .unsupported(let message):
            return "unsupported compose feature: \(message)"
        case .missingNormalizer(let message):
            return "compose normalizer unavailable: \(message)"
        }
    }
}
