import Foundation

public enum RecognitionError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
