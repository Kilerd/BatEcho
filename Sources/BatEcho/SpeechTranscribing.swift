import Foundation

@MainActor
protocol SpeechTranscribing: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func requestAuthorization()
    func start(localeID: String) throws
    func stop()
    func cancel()
}
