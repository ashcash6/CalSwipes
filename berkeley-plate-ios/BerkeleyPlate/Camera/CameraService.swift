import AVFoundation
import Combine
import Foundation

enum CameraStatus: Equatable {
    case idle, requestingPermission, ready, capturing, denied, interrupted, failed(String)
}

/// Capture configuration, starts/stops and delegate bookkeeping are confined to `queue`.
/// Observable properties are published only on the main queue.
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var status: CameraStatus = .idle
    @Published private(set) var photo: CapturedPhoto?
    private let queue = DispatchQueue(label: "BerkeleyPlate.Camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var shouldRun = false
    private var inFlight = false
    private var generation = UUID()
    private var delegates: [Int64: PhotoDelegate] = [:]
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.publish(.interrupted)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.shouldRun else { return }
                self.beginRunning()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.publish(.failed("The camera was interrupted. Tap Try again to reconnect."))
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func publish(_ value: CameraStatus) {
        DispatchQueue.main.async { [weak self] in self?.status = value }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.beginRunning()
            case .notDetermined:
                self.publish(.requestingPermission)
                AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                    self?.queue.async { [weak self] in
                        guard let self, self.shouldRun else { return }
                        if allowed { self.beginRunning() } else { self.publish(.denied) }
                    }
                }
            case .denied, .restricted: self.publish(.denied)
            @unknown default: self.publish(.denied)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.generation = UUID()
            self.inFlight = false
            if self.session.isRunning { self.session.stopRunning() }
            self.publish(.idle)
        }
    }

    func discardPhoto() {
        DispatchQueue.main.async { [weak self] in self?.photo = nil }
    }

    private func configure() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraFailure.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.photo), session.canAddInput(input) else { throw CameraFailure.configuration }
        session.sessionPreset = .photo
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraFailure.configuration
        }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        configured = true
    }

    private func beginRunning() {
        guard shouldRun else { return }
        do {
            try configure()
            if !session.isRunning { session.startRunning() }
            if session.isInterrupted { publish(.interrupted) }
            else if inFlight { publish(.capturing) }
            else { publish(session.isRunning ? .ready : .failed("Camera did not start. Please try again.")) }
        } catch { publish(.failed(error.localizedDescription)) }
    }

    func capture() {
        queue.async { [weak self] in
            guard let self, self.shouldRun, self.session.isRunning, !self.inFlight else { return }
            self.inFlight = true
            self.publish(.capturing)
            let capturedAt = Date()
            let generation = self.generation
            let settings = self.output.availablePhotoCodecTypes.contains(.jpeg)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) : AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90 // Portrait-only UI; EXIF normalized in CapturedPhoto.prepare.
            }
            let id = settings.uniqueID
            let delegate = PhotoDelegate { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.delegates[id] = nil
                    guard self.shouldRun, self.generation == generation else { return }
                    self.inFlight = false
                    do {
                        let prepared = try CapturedPhoto.prepare(result.get(), capturedAt: capturedAt)
                        DispatchQueue.main.async { [weak self] in self?.photo = prepared }
                        self.publish(.ready)
                    } catch { self.publish(.failed(error.localizedDescription)) }
                }
            }
            self.delegates[id] = delegate
            self.output.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private var result: Result<Data, Error> = .failure(CameraFailure.capture)
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data) }
        else { result = .failure(CameraFailure.invalidPhoto) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}
