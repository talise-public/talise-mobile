import SwiftUI
import AVFoundation
import Vision

/// `UIViewControllerRepresentable` that owns the live `AVCaptureSession`,
/// renders the preview full-bleed (`.resizeAspectFill`), and reports the
/// first decoded QR string back up to SwiftUI.
///
/// Why a UIKit controller instead of a `UIViewRepresentable`: the capture
/// session's start/stop and the metadata-output delegate are imperative,
/// lifecycle-bound things that read far more cleanly against a view
/// controller's `viewDidAppear`/`viewWillDisappear` than against the
/// representable's update cycle. SwiftUI just hosts it.
///
/// Layering: this view goes BEHIND `ScanToPayView`'s overlay (corner
/// brackets + caption) so the live frame fills the screen and the
/// brackets float on top.
struct QRScannerView: UIViewControllerRepresentable {
    /// Drives the torch. Bound to `ScanToPayView.flashOn` — the controller
    /// applies it whenever the binding changes (and on session start).
    var torchOn: Bool
    /// Monotonic re-arm token. After an unrecognized code the parent bumps
    /// this; the controller compares against its last-seen value and calls
    /// `resumeDetection()` so the scanner reads the next code instead of
    /// staying latched on the first emit.
    var resumeToken: Int
    /// First-detection callback. The controller debounces so this fires
    /// exactly once per scanned code; the parent decides whether to keep
    /// scanning (unrecognized code → resume) or tear down (valid → route).
    var onCode: (String) -> Void
    /// Continuous OCR callback. When `ocrEnabled` is true the controller runs
    /// Vision text recognition on the live frames and hands the parent the
    /// recognized strings (one array per processed frame, throttled). The
    /// parent extracts the bank + 10-digit account and debounces the lock.
    /// `nil` (the default) leaves the bank-scan path off — QR only.
    var onText: (([String]) -> Void)? = nil
    /// Master switch for the OCR video-data path. When false the controller
    /// never attaches the video output (QR-only — the original behaviour).
    var ocrEnabled: Bool = false
    /// Reports whether a usable capture device + input exists. False on the
    /// simulator (no camera) and on any device where `AVCaptureDevice`
    /// returns nil or the input can't be added. `ScanToPayView` renders the
    /// "Camera unavailable" fallback when this is false.
    var onCameraAvailability: (Bool) -> Void
    /// Reports whether the active device has a torch, so the parent can
    /// hide the flash toggle when there's nothing to drive.
    var onTorchAvailability: (Bool) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onText = onText
        vc.ocrEnabled = ocrEnabled
        vc.onCameraAvailability = onCameraAvailability
        vc.onTorchAvailability = onTorchAvailability
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        // Re-apply the latest closures (SwiftUI rebuilds them each pass)
        // and push the torch state down.
        vc.onCode = onCode
        vc.onText = onText
        vc.ocrEnabled = ocrEnabled
        vc.onCameraAvailability = onCameraAvailability
        vc.onTorchAvailability = onTorchAvailability
        vc.setTorch(torchOn)
        if resumeToken != context.coordinator.lastResumeToken {
            context.coordinator.lastResumeToken = resumeToken
            vc.resumeDetection()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks the last re-arm token so a torch toggle (which also triggers
    /// `updateUIViewController`) doesn't spuriously re-arm detection.
    final class Coordinator {
        var lastResumeToken = 0
    }
}

/// The imperative half. Owns the session, the preview layer, and the
/// metadata delegate. All session mutation runs on a dedicated serial
/// queue because `startRunning()` blocks.
final class ScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate {
    var onCode: ((String) -> Void)?
    var onText: (([String]) -> Void)?
    /// When true the controller attaches a video-data output and runs Vision
    /// text recognition on the frames. Set before the view loads so we know
    /// whether to add the output during `configureSession`.
    var ocrEnabled = false
    var onCameraAvailability: ((Bool) -> Void)?
    var onTorchAvailability: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var device: AVCaptureDevice?
    /// Set once we hand a code up — prevents the metadata delegate from
    /// firing the callback on every subsequent frame for the same code.
    private var didEmit = false
    /// Off-main serial queue for session start/stop (both block).
    private let sessionQueue = DispatchQueue(label: "io.talise.scan.session")
    private var configuredOK = false

    // MARK: OCR plumbing
    /// Dedicated queue for the video-data sample-buffer callback so Vision
    /// work never blocks the metadata (.main) delegate or the session queue.
    private let videoQueue = DispatchQueue(label: "io.talise.scan.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    /// Guards against piling up Vision requests: we only run a new one once
    /// the previous frame finished. Vision OCR is ~hundreds of ms/frame.
    private var ocrInFlight = false
    /// Throttle OCR to a couple of frames per second — plenty for reading a
    /// static placard, and keeps the camera buttery + the battery sane.
    private var lastOCRTime = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard configuredOK else { return }
        // start is allowed to be called when already running (no-op).
        didEmit = false
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Setup

    private func configureSession() {
        // No camera at all (simulator, or hardware without a back camera):
        // bail out cleanly and report unavailability. Never leave a frozen
        // black preview.
        guard let device = AVCaptureDevice.default(for: .video) else {
            onCameraAvailability?(false)
            onTorchAvailability?(false)
            return
        }
        self.device = device

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            onCameraAvailability?(false)
            onTorchAvailability?(false)
            return
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onCameraAvailability?(false)
            onTorchAvailability?(false)
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            onCameraAvailability?(false)
            onTorchAvailability?(false)
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        // Only QR — restrict the output so we don't waste cycles decoding
        // barcode types we'll never route.
        metadataOutput.metadataObjectTypes = [.qr]

        // OCR path: attach a video-data output so we can run Vision text
        // recognition on the live frames (bank-placard → off-ramp). Added
        // only when the parent opted in; QR-only mode never pays the cost.
        if ocrEnabled {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        configuredOK = true
        onCameraAvailability?(true)
        onTorchAvailability?(device.hasTorch)
    }

    // MARK: - Torch

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            // Locking can fail if the device is mid-reconfiguration; the
            // toggle just no-ops this frame, no need to surface it.
        }
    }

    // MARK: - Metadata delegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmit,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else {
            return
        }
        didEmit = true
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        onCode?(value)
    }

    /// Lets the parent re-arm detection after an unrecognized code so the
    /// scanner keeps reading instead of latching on the bad value.
    func resumeDetection() {
        didEmit = false
    }

    // MARK: - Video data delegate (Vision OCR)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard ocrEnabled, onText != nil, !ocrInFlight else { return }
        // Throttle to ~3 fps — reading a static placard doesn't need more,
        // and Vision OCR is expensive.
        let now = Date()
        guard now.timeIntervalSince(lastOCRTime) > 0.33 else { return }
        lastOCRTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        ocrInFlight = true

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self else { return }
            defer { self.ocrInFlight = false }
            guard let results = req.results as? [VNRecognizedTextObservation] else { return }
            let strings = results.compactMap { $0.topCandidates(1).first?.string }
            guard !strings.isEmpty else { return }
            DispatchQueue.main.async { self.onText?(strings) }
        }
        // Accurate recognition — placards are small, dense, and we want the
        // 10-digit account read reliably. usesLanguageCorrection off so a
        // digit string isn't "corrected" into words.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ocrInFlight = false
        }
    }
}
