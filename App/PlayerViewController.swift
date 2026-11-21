import AVFoundation
import GameController
import UIKit

struct PlayerConfig {
    var host: String
    var pspID: String
    var pkey: String
    var mac: String
    var nickname: String
    var bitrate: Int
}

/// Shows the PS3 picture, plays its sound and forwards the controls.
final class PlayerViewController: UIViewController {
    var config: PlayerConfig?
    var onClose: ((String) -> Void)?

    private var player: OpaquePointer?
    private let videoView = UIView()
    private let statusLabel = UILabel()
    private let overlay = PadOverlayView()
    private var displayLink: CADisplayLink?
    private var frameBuffer = [UInt8](repeating: 0, count: 1920 * 1088 * 4)
    private var serial: UInt32 = 0
    private var tickCount = 0
    private var gotPicture = false
    private var closed = false
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.backgroundColor = .black
        videoView.layer.contentsGravity = .resizeAspect
        videoView.layer.magnificationFilter = .linear
        videoView.isUserInteractionEnabled = false
        view.addSubview(videoView)

        overlay.onButton = { [weak self] code, down in
            guard let p = self?.player else { return }
            rp_button(p, code, down ? 1 : 0)
        }
        overlay.onAxis = { [weak self] offset, value in
            self?.sendAxis(offset, value)
        }
        overlay.onHome = { [weak self] in
            guard let p = self?.player else { return }
            rp_home(p)
        }
        overlay.onClose = { [weak self] in
            self?.finish("")
        }
        view.addSubview(overlay)

        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "Connecting ..."
        statusLabel.isUserInteractionEnabled = false
        view.addSubview(statusLabel)

        start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoView.frame = view.bounds
        overlay.frame = view.bounds
        let width = min(view.bounds.width * 0.5, 420)
        statusLabel.frame = CGRect(x: (view.bounds.width - width) / 2, y: view.bounds.midY - 50, width: width, height: 100)
    }

    override var prefersStatusBarHidden: Bool { return true }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AppDelegate.rotate(.landscape, .landscapeRight)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AppDelegate.rotate(.allButUpsideDown, .portrait)
    }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func start() {
        guard let c = config else {
            finish("Missing settings.")
            return
        }
        player = rp_start(c.host, c.pspID, c.pkey, c.mac, c.nickname, Int32(c.bitrate))
        if player == nil {
            finish("The settings are not valid.")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        startAudio()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(self, selector: #selector(controllersChanged),
                                               name: .GCControllerDidConnect, object: nil)
        controllersChanged()
    }

    private func startAudio() {
        guard let p = player else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setActive(true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData {
                rp_audio_read(p, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self),
                              Int32(frameCount))
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            // picture still works without sound
        }
        sourceNode = node
    }

    @objc private func tick() {
        guard let p = player else { return }
        var width: Int32 = 0
        var height: Int32 = 0
        var current = serial
        let capacity = Int32(frameBuffer.count)
        let copied = frameBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            return rp_video_copy(p, buffer.baseAddress, capacity, &width, &height, &current)
        }
        serial = current
        if copied == 1 && width > 0 && height > 0 {
            let w = Int(width)
            let h = Int(height)
            let data = Data(frameBuffer.prefix(w * h * 4))
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            if let provider = CGDataProvider(data: data as CFData),
               let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: colorSpace, bitmapInfo: info, provider: provider, decode: nil,
                                   shouldInterpolate: true, intent: .defaultIntent) {
                videoView.layer.contents = image
                if !gotPicture {
                    gotPicture = true
                    statusLabel.isHidden = true
                }
            }
        }

        tickCount += 1
        if tickCount % 20 == 0 {
            let state = rp_state(p)
            var text = [CChar](repeating: 0, count: 256)
            rp_status(p, &text, 256)
            let message = String(cString: text)
            if state == Pad.stateFailed || state == Pad.stateEnded {
                finish(message)
                return
            }
            if state != Pad.stateStreaming {
                gotPicture = false
                statusLabel.text = message
                statusLabel.isHidden = false
            } else if !gotPicture {
                statusLabel.text = message + "\nWaiting for the picture ..."
                statusLabel.isHidden = false
            }
        }
    }

    private func sendAxis(_ offset: Int32, _ value: Float) {
        guard let p = player else { return }
        let scaled = Int32(max(0, min(255, (value + 1) * 127.5)))
        rp_axis(p, offset, scaled)
    }

    private func finish(_ message: String) {
        if closed { return }
        closed = true
        displayLink?.invalidate()
        displayLink = nil
        engine.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        let old = player
        player = nil
        if let old = old {
            DispatchQueue.global(qos: .userInitiated).async {
                rp_stop(old)
            }
        }
        onClose?(message)
    }

    // MARK: - Physical controllers

    @objc private func controllersChanged() {
        for controller in GCController.controllers() {
            bind(controller)
        }
    }

    private func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        func map(_ input: GCControllerButtonInput?, _ code: Int32) {
            input?.pressedChangedHandler = { [weak self] _, _, isPressed in
                guard let p = self?.player else { return }
                rp_button(p, code, isPressed ? 1 : 0)
            }
        }
        map(pad.buttonA, Pad.cross)
        map(pad.buttonB, Pad.circle)
        map(pad.buttonX, Pad.square)
        map(pad.buttonY, Pad.triangle)
        map(pad.leftShoulder, Pad.l1)
        map(pad.rightShoulder, Pad.r1)
        map(pad.leftTrigger, Pad.l2)
        map(pad.rightTrigger, Pad.r2)
        map(pad.dpad.up, Pad.up)
        map(pad.dpad.down, Pad.down)
        map(pad.dpad.left, Pad.left)
        map(pad.dpad.right, Pad.right)
        map(pad.buttonMenu, Pad.start)
        map(pad.buttonOptions, Pad.select)
        map(pad.leftThumbstickButton, Pad.l3)
        map(pad.rightThumbstickButton, Pad.r3)
        pad.buttonHome?.pressedChangedHandler = { [weak self] _, _, isPressed in
            guard isPressed, let p = self?.player else { return }
            rp_home(p)
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.sendAxis(Pad.axisLX, x)
            self?.sendAxis(Pad.axisLY, -y)
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.sendAxis(Pad.axisRX, x)
            self?.sendAxis(Pad.axisRY, -y)
        }
    }
}
