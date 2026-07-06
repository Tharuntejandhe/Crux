import Foundation
import AVFoundation
import Speech
import Observation

/// Push-to-talk voice input using Apple's on-device Speech framework.
/// Free, private, no network. Requires NSMicrophoneUsageDescription and
/// NSSpeechRecognitionUsageDescription in Info.plist.
@MainActor
@Observable
final class VoiceService {
    enum State: Equatable {
        case idle
        case requestingPermission
        case denied(String)
        case recording
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript: String = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    // MARK: - Permissions

    func ensureAuthorized() async -> Bool {
        NSLog("[Novex.Voice] ensureAuthorized: starting")
        state = .requestingPermission

        // Speech recognition permission
        let speechAuth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        NSLog("[Novex.Voice] speech auth status = \(speechAuth.rawValue)")
        guard speechAuth == .authorized else {
            state = .denied("Speech recognition denied. Enable it in Settings > Privacy > Speech Recognition")
            return false
        }

        // Microphone permission
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        NSLog("[Novex.Voice] mic granted = \(micGranted)")
        guard micGranted else {
            state = .denied("Microphone denied. Enable it in Settings > Privacy > Microphone")
            return false
        }

        state = .idle
        return true
    }

    // MARK: - Recording

    func startRecording() async throws {
        NSLog("[Novex.Voice] startRecording called")
        guard await ensureAuthorized() else {
            NSLog("[Novex.Voice] not authorized — bailing")
            return
        }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            NSLog("[Novex.Voice] recognizer unavailable (locale: \(recognizer?.locale.identifier ?? "nil"))")
            state = .error("Speech recognizer not available for this locale")
            throw NSError(domain: "Novex.Voice", code: 1)
        }
        NSLog("[Novex.Voice] recognizer ready, locale=\(recognizer.locale.identifier)")

        // Cancel any previous task.
        stopRecording(resetTranscript: false)
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            NSLog("[Novex.Voice] audio engine started successfully")
        } catch {
            NSLog("[Novex.Voice] audio engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            state = .error("Audio engine: \(error.localizedDescription)")
            throw error
        }

        state = .recording
        NSLog("[Novex.Voice] state = recording")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil {
                    self.state = .idle
                }
            }
        }
    }

    /// Stops recording and returns the final transcript (whatever the
    /// recognizer has produced so far).
    @discardableResult
    func stopRecording(resetTranscript: Bool = false) -> String {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.finish()
        recognitionTask = nil
        let final = transcript
        if resetTranscript { transcript = "" }
        state = .idle
        return final
    }
}
