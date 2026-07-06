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

    /// Called with the final transcript when recording ends on its OWN (a silence
    /// timeout), so the caller can submit the question without a manual stop tap.
    var onFinish: ((String) -> Void)?
    private var silenceTimer: DispatchWorkItem?
    private static let silenceTimeout: TimeInterval = 2.5

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
        // Re-entry guard: ignore taps while already requesting permission or
        // recording, so a rapid double-tap can't spawn duplicate permission prompts.
        if state == .recording || state == .requestingPermission { return }
        guard await ensureAuthorized() else {
            NSLog("[Novex.Voice] not authorized — bailing")
            return
        }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            NSLog("[Novex.Voice] recognizer unavailable (locale: \(recognizer?.locale.identifier ?? "nil"))")
            state = .error("Speech recognizer not available for this locale")
            throw NSError(domain: "Novex.Voice", code: 1)
        }
        // Privacy-critical: Novex only ever transcribes ON-DEVICE. If the offline
        // model for this locale isn't installed we DO NOT fall back to the network;
        // we surface a clear error instead (mail-derived audio must never leave the Mac).
        if #available(macOS 13.0, *), !recognizer.supportsOnDeviceRecognition {
            state = .error("On-device dictation isn't installed for your language. Add it in System Settings > Keyboard > Dictation, then try again.")
            throw NSError(domain: "Novex.Voice", code: 2)
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
        // A 0-channel / 0-rate format (no input device, or a device change mid-setup)
        // makes installTap raise an uncatchable NSException. Bail gracefully instead.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            recognitionRequest = nil
            state = .error("No microphone input is available right now.")
            throw NSError(domain: "Novex.Voice", code: 3)
        }
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
        scheduleSilenceTimeout()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    self.scheduleSilenceTimeout()   // reset the timer while speech flows
                }
                // CRITICAL: an error (recognizer duration cap, device change, model
                // failure) must fully TEAR DOWN the engine, not just flip state to
                // idle - otherwise the mic stays hot and keeps recording invisibly.
                if error != nil {
                    self.stopRecording()
                }
            }
        }
    }

    /// Auto-stop after a stretch of silence, then hand the final transcript to the
    /// caller so the question submits without a manual stop tap.
    private func scheduleSilenceTimeout() {
        silenceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoStop() }
        silenceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceTimeout, execute: work)
    }

    private func autoStop() {
        guard state == .recording else { return }
        let final = stopRecording().trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty { onFinish?(final) }
    }

    /// Stops recording and returns the final transcript (whatever the
    /// recognizer has produced so far).
    @discardableResult
    func stopRecording(resetTranscript: Bool = false) -> String {
        silenceTimer?.cancel()
        silenceTimer = nil
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
