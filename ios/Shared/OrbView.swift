import UIKit
import Metal
import QuartzCore

/// UTUVO 光球：取代麥克風圖示的「會聽的球」（主 app 與鍵盤共用）。
///
/// 玻璃殼裡流動的光，Metal 著色器即時算：
///   - 閒置：慢慢流動，停一陣子就定格（省電）。
///   - 聆聽：跟著你的音量膨脹、發亮、流動加速，輪廓隨聲音起伏。
///   - 整理：邊緣光繞圈，像在想。
///   - 改寫模式：換薰衣草色；錯誤：褪色變暗。
/// 著色器在執行期編譯（不需要 Metal Toolchain，開源 clone 下來直接能建）；編好前先顯示靜態漸層。
@MainActor
final class OrbView: UIView {
    enum Phase: Equatable, Sendable { case idle, listening, processing, error }

    var phase: Phase = .idle { didSet { if phase != oldValue { wake() } } }
    var editPalette = false { didSet { if editPalette != oldValue { wake() } } }
    /// 每幀呼叫：回傳目前麥克風音量（dBFS），沒有訊號回 nil。只在 listening 時讀。
    var levelProvider: (() -> Float?)?
    /// 球體直徑佔 view 邊長的比例，其餘留給光暈。
    var sphereFraction: CGFloat = 0.62 { didSet { if sphereFraction != oldValue { setNeedsLayout() } } }
    /// 閒置多久後讓流動慢慢停下、定格（秒）。
    var idleAnimationSeconds: Double = 10

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let fallback = CAGradientLayer()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var idleSince: CFTimeInterval = CACurrentMediaTime()
    private var normalizer = VoiceLevel.Normalizer()
    private var state = OrbUniforms()
    private var idleMotion: Float = 1
    #if DEBUG
    /// 截圖／錄影用：不接麥克風時，用合成的講話音量（像一句話的起伏）。
    var debugSyntheticVoice = false
    private var debugClock: Double = 0
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.device = OrbRenderer.shared.device

        // 著色器編好前（或裝置沒有 Metal）顯示的靜態球。
        fallback.type = .radial
        fallback.colors = [UIColor(red: 1.0, green: 0.84, blue: 0.55, alpha: 1).cgColor,
                           UIColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 1).cgColor,
                           UIColor(red: 0.62, green: 0.16, blue: 0.04, alpha: 1).cgColor]
        fallback.locations = [0, 0.55, 1]
        fallback.startPoint = CGPoint(x: 0.38, y: 0.32)
        fallback.endPoint = CGPoint(x: 1.1, y: 1.1)
        layer.addSublayer(fallback)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: OrbView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
        OrbRenderer.shared.prepare { [weak self] in
            guard let self else { return }
            self.fallback.isHidden = OrbRenderer.shared.pipeline != nil
            self.wake(resetIdle: false)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let d = min(bounds.width, bounds.height) * sphereFraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallback.frame = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        fallback.cornerRadius = d / 2
        CATransaction.commit()
        wake(resetIdle: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() } else { wake(resetIdle: false) }
    }

    // MARK: - 動畫迴圈

    /// 狀態改變（resetIdle）：重新流動、重算閒置時間；版面／深淺色改變只補畫一幀。
    func wake(resetIdle: Bool = true) {
        if resetIdle {
            idleSince = CACurrentMediaTime()
            idleMotion = 1
        }
        startLink()
    }

    private func startLink() {
        guard window != nil, OrbRenderer.shared.pipeline != nil else { return }
        if link == nil {
            let proxy = DisplayLinkProxy(target: self)
            let l = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            lastTimestamp = 0
        }
        updateFrameRate()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func updateFrameRate() {
        guard let link else { return }
        let busy = phase == .listening || phase == .processing
        link.preferredFrameRateRange = busy
            ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            : CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    }

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = Float(lastTimestamp == 0 ? 1.0 / 60 : min(max(now - lastTimestamp, 1.0 / 240), 0.1))
        lastTimestamp = now
        updateFrameRate()
        advance(dt: dt, now: now)
        render()
        // 閒置、數值都收斂、流動已停：定格，不再每幀算。
        if phase == .idle, idleMotion <= 0.001, state.energy < 0.002, state.activity < 0.002,
           state.thinking < 0.002, abs(state.dim - 0) < 0.002, settledPalette {
            stopLink()
        }
    }

    private var settledPalette: Bool { abs(state.editMix - (editPalette ? 1 : 0)) < 0.002 }

    private func advance(dt: Float, now: CFTimeInterval) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // 聲音
        var targetEnergy: Float = 0
        if phase == .listening {
            #if DEBUG
            if debugSyntheticVoice {
                debugClock += Double(dt)
                targetEnergy = Self.syntheticEnergy(debugClock)
            } else if let db = levelProvider?() {
                targetEnergy = normalizer.energy(dbfs: db, dt: dt)
            }
            #else
            if let db = levelProvider?() { targetEnergy = normalizer.energy(dbfs: db, dt: dt) }
            #endif
        }
        state.energy = VoiceLevel.smooth(state.energy, toward: targetEnergy, dt: dt, attack: 0.05, release: 0.22)
        state.activity = VoiceLevel.smooth(state.activity, toward: phase == .listening ? 1 : (phase == .processing ? 0.6 : 0), dt: dt, attack: 0.25, release: 0.45)
        state.thinking = VoiceLevel.smooth(state.thinking, toward: phase == .processing ? 1 : 0, dt: dt, attack: 0.25, release: 0.35)
        state.dim = VoiceLevel.smooth(state.dim, toward: phase == .error ? 1 : 0, dt: dt, attack: 0.2, release: 0.4)
        state.editMix = VoiceLevel.smooth(state.editMix, toward: editPalette ? 1 : 0, dt: dt, attack: 0.25, release: 0.25)

        // 閒置太久：流動慢慢停（不是瞬間凍住）。
        if phase == .idle, now - idleSince > idleAnimationSeconds {
            idleMotion = max(0, idleMotion - dt / 1.5)
        }
        let motion: Float = reduceMotion ? 0.12 : 1
        let speed = (0.12 * idleMotion + 0.22 * state.activity + 1.0 * state.energy + 0.8 * state.thinking) * motion
        state.flow = (state.flow + dt * speed).truncatingRemainder(dividingBy: 5000)
        state.time = (state.time + dt * max(idleMotion, state.activity) * motion).truncatingRemainder(dividingBy: 1000)

        // 邊緣光：整理中繞圈；不整理時回到左上角。
        if state.thinking > 0.05 {
            state.spin += dt * 3.2 * state.thinking * motion
        } else {
            let target = (state.spin / (2 * .pi)).rounded() * 2 * .pi
            state.spin += (target - state.spin) * (1 - exp(-dt / 0.5))
        }
        state.spin = state.spin.truncatingRemainder(dividingBy: 2 * .pi * 64)
        state.ripple = reduceMotion ? 0 : 1
        state.radius = Float(sphereFraction)
        let px = Float(1 / max(1, min(bounds.width, bounds.height) * metalLayer.contentsScale / 2))
        state.aa = px * 1.5
        state.dark = traitCollection.userInterfaceStyle == .dark ? 1 : 0
    }

    private func render() {
        guard let pipeline = OrbRenderer.shared.pipeline, let queue = OrbRenderer.shared.queue,
              bounds.width > 0, let drawable = metalLayer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var u = state
        encoder.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// 合成的一句話：音節起伏＋字間短停頓＋句間長停頓（只給 DEBUG 截圖／錄影）。
    nonisolated static func syntheticEnergy(_ t: Double) -> Float {
        let sentence = t.truncatingRemainder(dividingBy: 4.2)
        guard sentence < 3.1 else { return 0 }
        let syllable = 0.5 + 0.5 * sin(t * 2 * .pi * 4.3) * sin(t * 2 * .pi * 0.9 + 1)
        let word = sentence.truncatingRemainder(dividingBy: 0.78) < 0.62 ? 1.0 : 0.15
        return Float(min(1, max(0, (0.35 + 0.65 * syllable) * word)))
    }
}

/// CADisplayLink 會強引用 target；經過這個弱引用代理，OrbView 才放得掉。（link 加在 main run loop，回呼在主執行緒）
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var target: OrbView?
    init(target: OrbView) { self.target = target }
    @objc func tick(_ link: CADisplayLink) { target?.step(link) }
}

/// 跟著色器的 `OrbUniforms` 一對一（14 個 float，順序不能動）。
struct OrbUniforms {
    var flow: Float = 0
    var spin: Float = 0
    var energy: Float = 0
    var activity: Float = 0
    var thinking: Float = 0
    var editMix: Float = 0
    var dim: Float = 0
    var radius: Float = 0.62
    var aa: Float = 0.004
    var dark: Float = 0
    var time: Float = 0
    var ripple: Float = 1
    var pad0: Float = 0
    var pad1: Float = 0
}

/// 共用的 Metal 裝置、佇列與管線；著色器第一次用到時在背景編譯一次，之後所有光球共用。
@MainActor
final class OrbRenderer {
    static let shared = OrbRenderer()
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private(set) lazy var queue: MTLCommandQueue? = device?.makeCommandQueue()
    private(set) var pipeline: MTLRenderPipelineState?
    private var waiters: [() -> Void] = []
    private var compiling = false
    private(set) var failure: String?

    func prepare(_ done: @escaping () -> Void) {
        if pipeline != nil || failure != nil { done(); return }
        waiters.append(done)
        guard !compiling, let device else {
            if device == nil { failure = "no Metal device"; flush() }
            return
        }
        compiling = true
        let source = OrbShader.source
        let box = DeviceBox(device: device)
        Task.detached(priority: .userInitiated) {
            let result = Self.compile(device: box.device, source: source)
            await MainActor.run {
                switch result {
                case .success(let box): OrbRenderer.shared.pipeline = box.state
                case .failure(let error): OrbRenderer.shared.failure = error.localizedDescription
                }
                OrbRenderer.shared.compiling = false
                OrbRenderer.shared.flush()
            }
        }
    }

    private func flush() {
        let list = waiters
        waiters.removeAll()
        list.forEach { $0() }
    }

    struct PipelineBox: @unchecked Sendable { let state: MTLRenderPipelineState }
    struct DeviceBox: @unchecked Sendable { let device: MTLDevice }

    nonisolated private static func compile(device: MTLDevice, source: String) -> Result<PipelineBox, Error> {
        do {
            let options = MTLCompileOptions()
            if #available(iOS 18.0, *) { options.mathMode = .fast }
            let library = try device.makeLibrary(source: source, options: options)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "orb_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return .success(PipelineBox(state: try device.makeRenderPipelineState(descriptor: descriptor)))
        } catch {
            return .failure(error)
        }
    }
}

/// 光球著色器（MSL 原始碼，執行期編譯）。
enum OrbShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct OrbUniforms {
        float flow; float spin; float energy; float activity; float thinking; float editMix; float dim;
        float radius; float aa; float dark; float time; float ripple; float pad0; float pad1;
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut orb_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = p * 2.0 - 1.0;
        return o;
    }

    // Simplex noise 3D（Ashima Arts / Stefan Gustavson, MIT）
    static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    static float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    static float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
    static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

    static float snoise(float3 v) {
        const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
        const float4 D = float4(0.0, 0.5, 1.0, 2.0);
        float3 i = floor(v + dot(v, C.yyy));
        float3 x0 = v - i + dot(i, C.xxx);
        float3 g = step(x0.yzx, x0.xyz);
        float3 l = 1.0 - g;
        float3 i1 = min(g.xyz, l.zxy);
        float3 i2 = max(g.xyz, l.zxy);
        float3 x1 = x0 - i1 + C.xxx;
        float3 x2 = x0 - i2 + C.yyy;
        float3 x3 = x0 - D.yyy;
        i = mod289(i);
        float4 p = permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0))
                                   + i.y + float4(0.0, i1.y, i2.y, 1.0))
                           + i.x + float4(0.0, i1.x, i2.x, 1.0));
        float n_ = 0.142857142857;
        float3 ns = n_ * D.wyz - D.xzx;
        float4 j = p - 49.0 * floor(p * ns.z * ns.z);
        float4 x_ = floor(j * ns.z);
        float4 y_ = floor(j - 7.0 * x_);
        float4 x = x_ * ns.x + ns.yyyy;
        float4 y = y_ * ns.x + ns.yyyy;
        float4 h = 1.0 - abs(x) - abs(y);
        float4 b0 = float4(x.xy, y.xy);
        float4 b1 = float4(x.zw, y.zw);
        float4 s0 = floor(b0) * 2.0 + 1.0;
        float4 s1 = floor(b1) * 2.0 + 1.0;
        float4 sh = -step(h, float4(0.0));
        float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
        float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
        float3 p0 = float3(a0.xy, h.x);
        float3 p1 = float3(a0.zw, h.y);
        float3 p2 = float3(a1.xy, h.z);
        float3 p3 = float3(a1.zw, h.w);
        float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
        p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
        float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
        m = m * m;
        return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
    }

    fragment float4 orb_fragment(VOut in [[stage_in]], constant OrbUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float r = length(uv);
        float ang = atan2(uv.y, uv.x);
        float t = u.time;

        // 輪廓：閒置微微呼吸；講話時膨脹，邊緣隨聲音起伏。
        float wave = sin(ang * 3.0 + t * 1.7) * 0.55 + sin(ang * 5.0 - t * 2.3) * 0.30 + sin(ang * 2.0 - t * 0.9) * 0.45;
        float R = u.radius * (1.0 + 0.030 * u.activity + 0.075 * u.energy
                              + 0.022 * u.energy * wave * u.ripple
                              + 0.010 * sin(t * 1.1) * (1.0 - u.activity) * u.ripple);
        float rr = r / R;
        float edge = u.aa / R;
        float inside = 1.0 - smoothstep(1.0 - edge, 1.0 + edge, rr);

        // 兩組色：聽寫（琥珀／品牌橘／餘燼）、改寫（薰衣草／靛）
        float e = u.editMix;
        float3 deep = mix(float3(0.40, 0.06, 0.03), float3(0.16, 0.09, 0.42), e);
        float3 mid  = mix(float3(0.97, 0.40, 0.08), float3(0.50, 0.36, 0.95), e);
        float3 hi   = mix(float3(1.00, 0.70, 0.27), float3(0.74, 0.64, 1.00), e);
        float3 pale = mix(float3(1.00, 0.92, 0.76), float3(0.94, 0.91, 1.00), e);
        float3 acc  = mix(float3(1.00, 0.38, 0.46), float3(0.96, 0.52, 0.86), e);
        float3 alt  = mix(float3(0.68, 0.60, 0.95), float3(1.00, 0.62, 0.35), e);

        float3 col = float3(0.0);
        float alpha = 0.0;
        if (rr < 1.0 + 2.0 * edge) {
            float2 p = uv / R;
            float d2 = min(dot(p, p), 1.0);
            float z = sqrt(1.0 - d2);
            float3 n = float3(p, z);
            // 玻璃透鏡：越靠邊緣內容越被壓縮。低頻、大塊色團（像 Siri 的流光，不是岩石紋理）。
            float3 s = float3(p * (0.70 + 0.30 * z), z * 0.6) * 0.85;
            float fl = u.flow;
            float warp = 0.55 + 0.9 * u.energy + 0.35 * u.thinking;
            float3 q = s + warp * float3(snoise(s * 0.9 + float3(0.0, fl * 0.31, fl * 0.13)),
                                         snoise(s * 0.9 + float3(4.1, -fl * 0.27, 1.7)),
                                         0.0);
            // 三個柔和的色場，各自緩慢漂移。
            float a1 = smoothstep(-0.35, 0.75, snoise(q + float3(0.0, 0.0, fl * 0.21)));
            float a2 = smoothstep(-0.25, 0.85, snoise(q * 1.1 + float3(7.3, 2.9, -fl * 0.17)));
            float a3 = smoothstep(-0.10, 0.90, snoise(q * 0.8 + float3(-5.2, 3.3, fl * 0.12)));

            float3 c = mix(mid, hi, 0.35);                 // 底：暖橘
            c = mix(c, acc, a1 * 0.55);                    // 珊瑚
            c = mix(c, hi, a2 * 0.65);                     // 琥珀
            c = mix(c, alt, a3 * 0.12);                    // 一點薰衣草（多了會跟橘混成褐）
            c = mix(c, pale, a2 * a1 * 0.45);              // 色場交疊處最亮

            // 體積：左上亮、右下略深（很輕，保持發光感）。
            float3 L = normalize(float3(-0.45, 0.6, 0.66));
            c *= 0.80 + 0.28 * clamp(dot(n, L), 0.0, 1.0);
            c = mix(c, deep, (1.0 - z) * 0.10 * (1.0 - u.energy));

            // 聲音從裡面點亮核心。
            float core = exp(-d2 * 1.8);
            c += (hi * 0.45 + pale * 0.35) * core * (0.12 + 0.60 * u.energy + 0.25 * u.thinking);

            // 菲涅耳：玻璃殼邊緣的飽和光。
            float fres = pow(1.0 - z, 2.4);
            c = mix(c, mid * 1.15 + hi * 0.25, fres * 0.55);

            // Liquid Glass 邊緣高光：只在邊上的細弧，不是橫過球面的反光帶。
            float rim = smoothstep(0.82, 0.97, rr) * (1.0 - smoothstep(0.985, 1.0, rr));
            float2 key = float2(cos(2.2 + u.spin), sin(2.2 + u.spin));
            float2 pn = p / max(sqrt(d2), 1e-4);
            float k1 = pow(max(dot(pn, key), 0.0), 3.0);
            float k2 = pow(max(dot(pn, -key), 0.0), 4.0);
            c += float3(1.0, 0.97, 0.92) * rim * (0.42 * k1 + 0.14 * k2);

            float luma = dot(c, float3(0.299, 0.587, 0.114));
            c = mix(c, float3(luma), u.dim * 0.75) * (1.0 - 0.2 * u.dim);

            float glassA = mix(0.86, 1.0, smoothstep(0.0, 0.6, z));
            col = c * inside * glassA;
            alpha = inside * glassA;
        }

        // 光暈：跟著聲音變亮變大；深色模式亮一點。
        float outside = max(r - R, 0.0);
        float strength = (0.16 + 0.22 * u.activity + 0.55 * u.energy + 0.20 * u.thinking) * (1.0 - 0.6 * u.dim) * mix(0.85, 1.25, u.dark);
        float halo = exp(-outside / max(R, 1e-3) * (7.5 - 2.5 * u.energy)) * strength;
        halo *= 1.0 - smoothstep(0.92, 1.0, r);
        float ha = halo * (1.0 - alpha);
        col += mix(mid, hi, 0.35) * ha;
        alpha += ha;
        return float4(col, alpha);
    }
    """
}
