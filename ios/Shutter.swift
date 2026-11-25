import Foundation

/// Drives the glasses' camera the way their own capture button does.
///
/// Visor does the same thing from the phone side (`core/connection/Shutter.kt`):
/// svc28 SNIntent (message 2300) carrying an Android-style intent —
/// `{1 action, 2 repeated SNIntentData}` and each SNIntentData is
/// `{1 key, 2 bool, 3 int, 4 double, 5 string}`.
///
/// Actions used here:
/// - photo: `action.robusta.capture` + launch type PHOTO, referrer SHORT_BUTTON, IS_MODAL
/// - start video: `com.meta.smartglass.app.intent.action.AGENTIC_START_RECORDING` + capture_type
/// - stop video: `com.meta.smartglass.app.intent.action.CLOSE_APP_CAPTURE`
enum Shutter {
    static let service = 28
    static let mtSnIntent: UInt16 = 2300

    static let actionPhoto = "action.robusta.capture"
    static let actionStartRecording = "com.meta.smartglass.app.intent.action.AGENTIC_START_RECORDING"
    static let actionCloseCapture = "com.meta.smartglass.app.intent.action.CLOSE_APP_CAPTURE"

    static let keyLaunchType = "com.meta.smartglass.intent.action.LAUNCH_TYPE"
    static let keyReferrer = "android.intent.extra.REFERRER_NAME"
    static let keyIsModal = "IS_MODAL"
    static let keyCaptureType = "capture_type"

    static let launchTypePhoto = "CAPTURE_EXTRA_LAUNCH_TYPE_PHOTO"
    static let launchTypeVideo = "CAPTURE_EXTRA_LAUNCH_TYPE_VIDEO"

    /// One SNIntentData with a string value.
    static func data(_ key: String, _ value: String) -> Data {
        PB.string(1, key) + PB.string(5, value)
    }

    /// One SNIntentData with a bool value.
    static func data(_ key: String, _ value: Bool) -> Data {
        PB.string(1, key) + PB.uint(2, value ? 1 : 0)
    }

    static func intent(_ action: String, _ items: [Data] = []) -> Data {
        items.reduce(PB.string(1, action)) { $0 + PB.bytes(2, $1) }
    }

    /// The glasses confirm this intent with a camera-state update.
    static func photoPayload() -> Data {
        intent(actionPhoto, [
            data(keyLaunchType, launchTypePhoto),
            data(keyReferrer, "SHORT_BUTTON"),
            data(keyIsModal, true),
        ])
    }

    /// `kind` is `video` or `hyperlapse`, matching `Shutter.VideoKind` in Visor.
    static func startVideoPayload(kind: String = "video") -> Data {
        intent(actionStartRecording, [data(keyCaptureType, kind)])
    }

    static func stopVideoPayload() -> Data {
        intent(actionCloseCapture)
    }
}

extension Session {
    func shutterPhoto() throws -> GlassesState {
        try confirmedShutter(Shutter.photoPayload()) { $0 == Status.photoStarted }
    }

    func startVideo() throws -> GlassesState {
        try confirmedShutter(Shutter.startVideoPayload()) { $0 == Status.videoStarted }
    }

    func stopVideo() throws -> GlassesState {
        try confirmedShutter(Shutter.stopVideoPayload()) { [0, 3, 5, 7, 10].contains($0) }
    }
}
