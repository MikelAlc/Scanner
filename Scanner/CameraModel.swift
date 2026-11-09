//
//  CameraModel.swift
//  Insight
//
//  iOS 17+ rewrite: @Observable + @MainActor, dedicated session queue,
//  rotation coordinator, flash / flip / tap-to-focus / pinch-zoom.
//
//  Required Info.plist keys:
//    NSCameraUsageDescription
//    NSPhotoLibraryAddUsageDescription
//
 
import AVFoundation
import Observation
import Photos
import PhotosUI
import SwiftUI
 
// MARK: - Model
 
@Observable
@MainActor
final class CameraModel: NSObject {
 
    // MARK: Observable state (drives the UI)
 
    private(set) var capturedPhotos: [Data] = []
    var isTaken = false
    var isSaved = false
    var alert = false                       // camera permission denied / restricted
    var errorMessage: String?
    var isInterrupted = false
    var picData = Data()
    var flag = 0
    
    var photoTexts: [PhotoText] = []
    var showResults = false
    var isRecognizing = false
 
    var flashMode: AVCaptureDevice.FlashMode = .off
    private(set) var cameraPosition: AVCaptureDevice.Position = .back
    private(set) var isFlashAvailable = false
    private(set) var zoomFactor: CGFloat = 1.0
 
    /// Bind this to a PhotosPicker: `PhotosPicker(selection: $camera.picDataPicker)`
    var picDataPicker: PhotosPickerItem? {
        didSet {
            guard let item = picDataPicker else { return }
            Task { await loadPickedItem(item) }
        }
    }
 
    // MARK: Capture infrastructure (not observed)
 
    /// Session work happens on `sessionQueue`; these are only touched there
    /// (or are thread-safe to hand to the preview layer).
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCapturePhotoOutput()
    nonisolated private let sessionQueue = DispatchQueue(label: "insight.camera.session")
    @ObservationIgnored nonisolated(unsafe) private var currentInput: AVCaptureDeviceInput?
 
    // Main-actor-only bookkeeping
    @ObservationIgnored private var activeDevice: AVCaptureDevice?
    @ObservationIgnored private var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
 
    private enum SetupResult: Sendable {
        case success
        case failure(String)
    }
 
    // MARK: Lifecycle
 
    override init() {
        super.init()
        registerObservers()
    }
 
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
 
    /// Call from `.task { camera.start() }` or `.onAppear`.
    func start() {
        Task {
            guard await ensureAuthorized() else { return }
            let result: SetupResult = await withCheckedContinuation { continuation in
                sessionQueue.async {
                    continuation.resume(returning: self.configureAndRun())
                }
            }
            switch result {
            case .success:
                activeDevice = Self.device(for: cameraPosition)
                isFlashAvailable = activeDevice?.isFlashAvailable ?? false
                updateRotationCoordinator()
            case .failure(let message):
                errorMessage = message
            }
        }
    }
 
    /// Call from `.onDisappear`.
    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
 
    private func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { alert = true }
            return granted
        case .denied:
            alert = true
            return false
        case .restricted:
            errorMessage = "Camera access is restricted on this device."
            return false
        @unknown default:
            return false
        }
    }
 
    // MARK: Session configuration (sessionQueue)
 
    nonisolated private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
 
    nonisolated private func configureAndRun() -> SetupResult {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .photo
 
            guard let device = Self.device(for: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input),
                  session.canAddOutput(output) else {
                session.commitConfiguration()
                return .failure("Camera unavailable on this device.")
            }
 
            session.addInput(input)
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .quality
            session.commitConfiguration()
            currentInput = input
        }
 
        if !session.isRunning { session.startRunning() }
        return .success
    }
 
    nonisolated private func swapInput(to position: AVCaptureDevice.Position) -> Bool {
        guard let device = Self.device(for: position),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
 
        session.beginConfiguration()
        defer { session.commitConfiguration() }
 
        let oldInput = currentInput
        if let oldInput { session.removeInput(oldInput) }
 
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            currentInput = newInput
            return true
        }
 
        // Roll back
        if let oldInput, session.canAddInput(oldInput) { session.addInput(oldInput) }
        return false
    }
 
    // MARK: Interruptions & runtime errors
 
    private func registerObservers() {
        let center = NotificationCenter.default
 
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.isInterrupted = true }
        })
 
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.isInterrupted = false }
        })
 
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        })
    }
 
    // MARK: Preview / rotation
 
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        updateRotationCoordinator()
    }
 
    private func updateRotationCoordinator() {
        guard let device = activeDevice, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { layer.connection?.videoRotationAngle = angle }
        }
    }
 
    // MARK: Camera controls
 
    func cycleFlash() {
        guard isFlashAvailable else { return }
        switch flashMode {
        case .off:  flashMode = .auto
        case .auto: flashMode = .on
        default:    flashMode = .off
        }
    }
 
    func flipCamera() {
        guard !isSwitching, !isTaken else { return }
        isSwitching = true
        let target: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
 
        sessionQueue.async {
            let success = self.swapInput(to: target)
            Task { @MainActor in self.finishFlip(to: target, success: success) }
        }
    }
 
    private func finishFlip(to position: AVCaptureDevice.Position, success: Bool) {
        isSwitching = false
        guard success else {
            errorMessage = "Couldn't switch cameras."
            return
        }
        cameraPosition = position
        activeDevice = Self.device(for: position)
        zoomFactor = 1.0
        isFlashAvailable = activeDevice?.isFlashAvailable ?? false
        if !isFlashAvailable { flashMode = .off }
        updateRotationCoordinator()
    }
 
    func setZoom(_ factor: CGFloat) {
        guard let device = activeDevice else { return }
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        let clamped = min(max(factor, 1), maxZoom)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            zoomFactor = clamped
        } catch {
            errorMessage = "Couldn't change zoom."
        }
    }
 
    /// `devicePoint` is in the capture device's (0...1) coordinate space.
    func focus(at devicePoint: CGPoint) {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
 
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
        } catch {
            // Focus is best-effort; ignore.
        }
    }
 
    // MARK: Capture
 
    func takePicture() {
        guard !isTaken, !isCapturing, session.isRunning else { return }
        isCapturing = true
 
        let flash = flashMode
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
 
        sessionQueue.async {
            if let angle,
               let connection = self.output.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
 
            let settings = AVCapturePhotoSettings()
            if self.output.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
 
    func retakePicture() {
        picData = Data()
        isSaved = false
        withAnimation { isTaken = false }
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
 
    private func captureSucceeded(_ jpeg: Data) {
        isCapturing = false
        picData = jpeg
        withAnimation { isTaken = true }
    }
 
    private func captureFailed(_ message: String) {
        isCapturing = false
        errorMessage = message
    }
 
    // MARK: Saving
 
    func savePicture() {
        guard let image = UIImage(data: picData) else {
            errorMessage = "No photo to save."
            return
        }
        let data = picData
 
      
        flag += 1
 
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                errorMessage = "Photos access is needed to save pictures."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                isSaved = true
            } catch {
                errorMessage = "Couldn't save photo: \(error.localizedDescription)"
            }
        }
    }
 
    // MARK: Photo picker
 
    private func loadPickedItem(_ item: PhotosPickerItem) async {
        defer { picDataPicker = nil }   // allow re-picking the same photo
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Couldn't read the selected photo."
                return
            }
            let jpeg = await Task.detached { Self.jpegData(from: raw) }.value
            guard let jpeg else {
                errorMessage = "Couldn't process the selected photo."
                return
            }
            picData = jpeg
            withAnimation { isTaken = true }
        
        } catch {
            errorMessage = "Failed to load photo: \(error.localizedDescription)"
        }
    }
 
    // MARK: Image normalization (camera + picker both end up as JPEG @ 0.8)
 
    nonisolated private static func jpegData(from data: Data, quality: CGFloat = 0.8) -> Data? {
        UIImage(data: data)?.jpegData(compressionQuality: quality)
    }
}
 
// MARK: - AVCapturePhotoCaptureDelegate
 
extension CameraModel: AVCapturePhotoCaptureDelegate {
 
    // Called on an arbitrary queue, so it must be nonisolated.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        if let error {
            let message = error.localizedDescription
            Task { @MainActor in self.captureFailed(message) }
            return
        }
 
        guard let raw = photo.fileDataRepresentation(),
              let jpeg = Self.jpegData(from: raw) else {
            Task { @MainActor in self.captureFailed("Couldn't process the photo.") }
            return
        }
 
        // Only stop the session once the photo actually exists.
        sessionQueue.async { self.session.stopRunning() }
        Task { @MainActor in self.captureSucceeded(jpeg) }
    }
    
    func nextPicture() {
        guard isTaken else { return }
        capturedPhotos.append(picData)
        retakePicture()          // clears the current photo and restarts the camera
    }

    func cancelAll() {
        capturedPhotos.removeAll()
        retakePicture()
    }

    func done() {
        guard !isRecognizing else { return }
        if isTaken { nextPicture() }          // adds the current photo, returns to camera
        let photos = capturedPhotos
        guard !photos.isEmpty else { return }

        isRecognizing = true
        Task {
            photoTexts = await TextRecognizer.recognize(photos)
            isRecognizing = false
            showResults = true
        }
    }
    
    func finishResults() {
        capturedPhotos.removeAll()
        photoTexts.removeAll()
    }
}
 
// MARK: - Preview
 
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
 
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
 
struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel
 
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreview(view.previewLayer)
 
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePinch(_:))))
        return view
    }
 
    func updateUIView(_ uiView: PreviewView, context: Context) {}
 
    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }
    
    
 
    @MainActor
    final class Coordinator: NSObject {
        let camera: CameraModel
        private var baseZoom: CGFloat = 1
 
        init(camera: CameraModel) { self.camera = camera }
 
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView else { return }
            let layerPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            camera.focus(at: devicePoint)
        }
 
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:   baseZoom = camera.zoomFactor
            case .changed: camera.setZoom(baseZoom * gesture.scale)
            default:       break
            }
        }
    }
}
 
// MARK: - Helpers
 
extension NSMutableData {
    func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            self.append(data)
        }
    }
}
 
