import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum CapturePermission: LocalizedError {
    case microphone, systemAudio

    var settingsSection: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_ScreenCapture"
        }
    }

    var isAuthorized: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .systemAudio: CGPreflightScreenCaptureAccess()
        }
    }

    var errorDescription: String? {
        switch self {
        case .microphone:
            "Enable Audio Button in macOS Settings → Privacy & Security → Microphone."
        case .systemAudio:
            "Allow Mac audio in Screen & System Audio Recording. If already on, remove Audio Button from the list and add it again."
        }
    }

    static func isSystemAudioDenial(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }
}
