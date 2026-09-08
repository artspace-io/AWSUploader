import Foundation

public enum AWSUploaderError: LocalizedError {
    case invalidConfiguration(String)
    case invalidCredentials
    case invalidObjectName
    case fileNotFound(URL)
    case credentialFetchFailed(Error)
    case registrationFailed(Error)
    case uploadFailed(Error)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "Invalid AWS upload configuration: \(reason)"
        case .invalidCredentials:
            return "The temporary AWS credentials are invalid."
        case .invalidObjectName:
            return "The S3 object name must not be empty."
        case .fileNotFound(let url):
            return "The upload file does not exist: \(url.path)"
        case .credentialFetchFailed(let error):
            return "Failed to fetch temporary AWS credentials: \(error.localizedDescription)"
        case .registrationFailed(let error):
            return "Failed to register the S3 transfer utility: \(error.localizedDescription)"
        case .uploadFailed(let error):
            return "Failed to upload the S3 object: \(error.localizedDescription)"
        case .cancelled:
            return "The upload was cancelled."
        }
    }
}
