@preconcurrency import MetalKit
import QuartzCore
import WindowBurnCore

enum BurnRendererError: LocalizedError {
  case commandQueue
  case shaderCompilation(String)
  case shaderFunction
  case pipeline(String)
  case texture(String)
  case sampler

  var errorDescription: String? {
    switch self {
    case .commandQueue:
      "Metal could not create a command queue."
    case .shaderCompilation(let message):
      "The burn shader did not compile: \(message)"
    case .shaderFunction:
      "The burn shader entry points are missing."
    case .pipeline(let message):
      "The burn render pipeline could not be created: \(message)"
    case .texture(let message):
      "The captured window could not become a Metal texture: \(message)"
    case .sampler:
      "Metal could not create a texture sampler."
    }
  }
}

enum BurnRendererStyle {
  case sweep
  case torch(initialIgnitions: [BurnIgnitionPoint])
  case soakAndBurn(initialSoakPoints: [BurnIgnitionPoint])
}

@MainActor
final class BurnRenderer: NSObject, MTKViewDelegate {
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let texture: MTLTexture
  private let sampler: MTLSamplerState
  private let profile: BurnProfile
  private let style: BurnRendererStyle
  private let horizontalPadding: Float
  private let verticalPadding: Float
  private let completion: () -> Void
  private var ignitionField: TorchIgnitionField
  private var soakTrail: SoakTrail
  private var startTime: CFTimeInterval?
  private var soakEndedAt: TimeInterval?
  private var burnStartedAt: TimeInterval?
  private var hasCompleted = false

  init(
    device: MTLDevice,
    image: CGImage,
    profile: BurnProfile,
    style: BurnRendererStyle,
    horizontalPadding: Float,
    verticalPadding: Float,
    completion: @escaping () -> Void
  ) throws {
    guard let commandQueue = device.makeCommandQueue() else {
      throw BurnRendererError.commandQueue
    }
    self.commandQueue = commandQueue
    self.profile = profile
    self.style = style
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.completion = completion
    var ignitionField = TorchIgnitionField()
    if case .torch(let initialIgnitions) = style {
      for ignition in initialIgnitions {
        ignitionField.add(point: ignition, startedAt: 0)
      }
    }
    self.ignitionField = ignitionField
    var soakTrail = SoakTrail()
    if case .soakAndBurn(let initialSoakPoints) = style {
      for point in initialSoakPoints {
        _ = soakTrail.add(point)
      }
    }
    self.soakTrail = soakTrail

    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: Self.shaderSource, options: nil)
    } catch {
      throw BurnRendererError.shaderCompilation(error.localizedDescription)
    }
    guard
      let vertexFunction = library.makeFunction(name: "burnVertex"),
      let fragmentFunction = library.makeFunction(name: "burnFragment")
    else {
      throw BurnRendererError.shaderFunction
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    do {
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      throw BurnRendererError.pipeline(error.localizedDescription)
    }

    do {
      texture = try MTKTextureLoader(device: device).newTexture(
        cgImage: image,
        options: [
          .origin: MTKTextureLoader.Origin.topLeft,
          .SRGB: false,
        ]
      )
    } catch {
      throw BurnRendererError.texture(error.localizedDescription)
    }

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.sAddressMode = .clampToZero
    samplerDescriptor.tAddressMode = .clampToZero
    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
      throw BurnRendererError.sampler
    }
    self.sampler = sampler

    super.init()
  }

  func start() {
    startTime = CACurrentMediaTime()
  }

  @discardableResult
  func addIgnition(_ point: BurnIgnitionPoint) -> Bool {
    guard case .torch = style else { return false }
    let previousCount = ignitionField.ignitions.count
    let elapsed = startTime.map { CACurrentMediaTime() - $0 } ?? 0
    ignitionField.add(point: point, startedAt: elapsed)
    return ignitionField.ignitions.count > previousCount
  }

  @discardableResult
  func finishSoaking() -> Bool {
    guard case .soakAndBurn = style, soakEndedAt == nil else { return false }
    soakEndedAt = startTime.map { CACurrentMediaTime() - $0 } ?? 0
    return true
  }

  @discardableResult
  func addSoakPoint(_ point: BurnIgnitionPoint) -> Bool {
    guard case .soakAndBurn = style, soakEndedAt == nil else { return false }
    return soakTrail.add(point)
  }

  @discardableResult
  func igniteSoakedWindow(at point: BurnIgnitionPoint) -> Bool {
    guard case .soakAndBurn = style, burnStartedAt == nil else { return false }
    let elapsed = startTime.map { CACurrentMediaTime() - $0 } ?? 0
    if soakEndedAt == nil {
      soakEndedAt = elapsed
    }
    burnStartedAt = elapsed
    ignitionField.add(point: point, startedAt: elapsed)
    return true
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard
      !hasCompleted,
      let drawable = view.currentDrawable,
      let renderPass = view.currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
    else { return }

    let now = CACurrentMediaTime()
    let elapsed = startTime.map { now - $0 } ?? 0
    let burnElapsed: TimeInterval
    if case .soakAndBurn = style {
      burnElapsed = burnStartedAt.map { max(0, elapsed - $0) } ?? 0
    } else {
      burnElapsed = elapsed
    }
    var timing = SIMD2<Float>(
      Float(BurnTiming.progress(elapsed: burnElapsed, duration: profile.duration)),
      Float(elapsed)
    )
    var padding = SIMD2<Float>(horizontalPadding, verticalPadding)
    var aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
    var variation = SIMD4<Float>(
      profile.seed,
      profile.tilt,
      profile.turbulence,
      profile.charWidth
    )
    let effectMode: Float = {
      switch style {
      case .sweep: 0
      case .torch: 1
      case .soakAndBurn: 2
      }
    }()
    var mode = SIMD4<Float>(
      effectMode,
      Float(ignitionField.ignitions.count),
      Float(profile.duration),
      Float(soakTrail.points.count)
    )
    let soakingDuration = min(elapsed, soakEndedAt ?? elapsed)
    var wetInfo = SIMD4<Float>(
      soakTrail.points.isEmpty ? 0 : SoakEffect.wetness(heldFor: soakingDuration),
      burnStartedAt == nil ? (soakEndedAt == nil ? 0 : 1) : 2,
      0,
      0
    )
    var wetUniforms = soakTrail.points.enumerated().map { index, point in
      SIMD4<Float>(
        point.x,
        point.y,
        profile.seed + Float(index) * 11.73,
        0
      )
    }
    if wetUniforms.isEmpty {
      wetUniforms.append(.zero)
    }
    var ignitionUniforms = ignitionField.ignitions.enumerated().map { index, ignition in
      SIMD4<Float>(
        ignition.point.x,
        ignition.point.y,
        Float(ignition.startedAt),
        profile.seed + Float(index) * 17.31
      )
    }
    if ignitionUniforms.isEmpty {
      ignitionUniforms.append(.zero)
    }

    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(texture, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)
    encoder.setFragmentBytes(&timing, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    encoder.setFragmentBytes(&padding, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.setFragmentBytes(&aspect, length: MemoryLayout<Float>.stride, index: 2)
    encoder.setFragmentBytes(&variation, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
    encoder.setFragmentBytes(&mode, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
    ignitionUniforms.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 5)
    }
    wetUniforms.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 6)
    }
    encoder.setFragmentBytes(&wetInfo, length: MemoryLayout<SIMD4<Float>>.stride, index: 7)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()

    let canComplete: Bool = {
      if case .soakAndBurn = style { return burnStartedAt != nil }
      return true
    }()
    if canComplete, timing.x >= 1 {
      hasCompleted = true
      view.isPaused = true
      completion()
    }
  }

  private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut burnVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        const float2 coordinates[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };

        VertexOut output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        output.uv = coordinates[vertexID];
        return output;
    }

    float hash21(float2 point) {
        point = fract(point * float2(123.34, 456.21));
        point += dot(point, point + 45.32);
        return fract(point.x * point.y);
    }

    float valueNoise(float2 point) {
        float2 cell = floor(point);
        float2 local = fract(point);
        local = local * local * (3.0 - 2.0 * local);

        float a = hash21(cell);
        float b = hash21(cell + float2(1.0, 0.0));
        float c = hash21(cell + float2(0.0, 1.0));
        float d = hash21(cell + float2(1.0, 1.0));
        return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
    }

    float fbm(float2 point) {
        float value = 0.0;
        float amplitude = 0.5;
        for (int octave = 0; octave < 4; octave++) {
            value += valueNoise(point) * amplitude;
            point = point * 2.03 + 17.17;
            amplitude *= 0.5;
        }
        return value;
    }

    fragment float4 burnFragment(
        VertexOut input [[stage_in]],
        texture2d<float> image [[texture(0)]],
        sampler imageSampler [[sampler(0)]],
        constant float2 &timing [[buffer(0)]],
        constant float2 &padding [[buffer(1)]],
        constant float &aspect [[buffer(2)]],
        constant float4 &variation [[buffer(3)]],
        constant float4 &mode [[buffer(4)]],
        constant float4 *ignitions [[buffer(5)]],
        constant float4 *wetPoints [[buffer(6)]],
        constant float4 &wetInfo [[buffer(7)]]
    ) {
        float progress = timing.x;
        float time = timing.y;
        float seed = variation.x;
        float tilt = variation.y;
        float turbulence = variation.z;
        float charWidth = variation.w;
        float effectMode = mode.x;
        float radialMode = step(0.5, effectMode);
        float soakMode = step(1.5, effectMode);
        uint ignitionCount = uint(mode.y);
        float burnDuration = max(mode.z, 0.001);
        uint wetPointCount = uint(mode.w);
        float2 contentSize = 1.0 - padding * 2.0;
        float2 imageUV = (input.uv - padding) / contentSize;

        float horizontalMask = step(0.0, imageUV.x) * step(imageUV.x, 1.0);
        float insideMask = horizontalMask * step(0.0, imageUV.y) * step(imageUV.y, 1.0);

        float2 seedOffset = float2(seed * 0.0137, seed * 0.0319);
        float coarse = fbm(float2(imageUV.x * 6.4 * turbulence, seedOffset.x));
        float detail = valueNoise(float2(imageUV.x * 41.0, seedOffset.y));
        float fibers = sin(imageUV.x * (71.0 + seed * 0.003) + seed) * 0.5 + 0.5;
        float ragged = (coarse - 0.5) * 0.19 * turbulence
            + (detail - 0.5) * 0.052
            + (fibers - 0.5) * 0.016;
        float front = progress * 1.24 - 0.12
            + tilt * (imageUV.x - 0.5)
            + ragged;
        float signedDistance = imageUV.y - front;

        if (radialMode > 0.5 && ignitionCount > 0) {
            float nearestFront = 1000.0;
            float maximumRadius = length(float2(aspect, 1.0)) + 0.12;
            for (uint index = 0; index < ignitionCount; index++) {
                float4 ignition = ignitions[index];
                float age = max(0.0, time - ignition.z);
                float ignitionProgress = clamp(age / burnDuration, 0.0, 1.0);
                float2 delta = (imageUV - ignition.xy) * float2(aspect, 1.0);
                float radialGrain = fbm(
                    imageUV * float2(13.0, 11.0)
                    + float2(ignition.w * 0.011, ignition.w * 0.019)
                );
                float radialFibers = valueNoise(
                    imageUV * float2(47.0, 39.0)
                    + ignition.w * 0.007
                );
                float radialRagged = (radialGrain - 0.5) * 0.13 * turbulence
                    + (radialFibers - 0.5) * 0.035;
                float radius = ignitionProgress * maximumRadius;
                nearestFront = min(nearestFront, length(delta) - radius + radialRagged);
            }
            signedDistance = nearestFront;
        } else if (soakMode > 0.5) {
            signedDistance = 1000.0;
        }

        float grain = fbm(imageUV * float2(31.0, 19.0) + seedOffset * 3.7);
        float pinholeNoise = valueNoise(imageUV * float2(83.0, 47.0) + seedOffset * 8.1);
        float charCore = insideMask
            * step(0.0, signedDistance)
            * smoothstep(charWidth, 0.0, signedDistance);
        float heatStain = insideMask
            * step(0.0, signedDistance)
            * smoothstep(charWidth * 2.65, charWidth * 0.30, signedDistance);
        float pores = charCore
            * smoothstep(0.64, 0.91, pinholeNoise + charCore * 0.23);

        float keep = smoothstep(-0.015, 0.023, signedDistance);
        keep *= 1.0 - pores * 0.94;
        float2 sourceUV = imageUV;
        float wetMask = 0.0;
        if (soakMode > 0.5 && wetPointCount > 0) {
            float wetness = wetInfo.x;
            float wetReach = 0.10 + wetness * 0.88;
            float seepNoise = fbm(
                imageUV * float2(17.0, 12.0) + seedOffset * 5.0
            );
            for (uint index = 0; index < wetPointCount; index++) {
                float4 wetPoint = wetPoints[index];
                float2 wetDelta = imageUV - wetPoint.xy;
                float downward = smoothstep(-0.035, 0.055, wetDelta.y);
                float reachMask = 1.0 - smoothstep(
                    wetReach * 0.68,
                    wetReach,
                    wetDelta.y
                );
                float streamWander = (
                    sin(wetDelta.y * 33.0 + wetPoint.z * 0.031) * 0.5
                    + valueNoise(float2(wetDelta.y * 9.0, wetPoint.z * 0.013))
                    - 0.5
                ) * (0.024 + wetness * 0.045);
                float streamWidth = 0.014 + wetness * 0.040
                    + max(0.0, wetDelta.y) * 0.035;
                float stream = smoothstep(
                    streamWidth,
                    streamWidth * 0.18,
                    abs(wetDelta.x - streamWander)
                ) * downward * reachMask;
                float splashDistance = length(float2(
                    wetDelta.x * aspect,
                    wetDelta.y * 1.8
                ));
                float splash = smoothstep(
                    0.105 + wetness * 0.105,
                    0.014,
                    splashDistance
                );
                float seep = smoothstep(
                    0.12 + seepNoise * 0.045,
                    0.018,
                    abs(wetDelta.x - streamWander * 0.55)
                ) * downward * reachMask * (0.38 + seepNoise * 0.62);
                wetMask = max(wetMask, max(splash, max(stream, seep * 0.68)));
            }
            wetMask *= insideMask * wetness;

            float ripple = sin(
                imageUV.y * 95.0
                + time * 2.6
                + fbm(imageUV * 21.0 + seedOffset) * 8.0
            );
            sourceUV.x += ripple * wetMask * (0.004 + wetness * 0.009);
            sourceUV.y += (seepNoise - 0.5) * wetMask * 0.012;
        }

        float4 source = image.sample(imageSampler, clamp(sourceUV, 0.0, 1.0));
        if (wetMask > 0.001) {
            float blurRadius = (0.0025 + wetInfo.x * 0.0085) * wetMask;
            float4 blurred = source;
            blurred += image.sample(
                imageSampler,
                clamp(sourceUV + float2(blurRadius, 0.0), 0.0, 1.0)
            );
            blurred += image.sample(
                imageSampler,
                clamp(sourceUV - float2(blurRadius, 0.0), 0.0, 1.0)
            );
            blurred += image.sample(
                imageSampler,
                clamp(sourceUV + float2(0.0, blurRadius * 1.65), 0.0, 1.0)
            );
            blurred += image.sample(
                imageSampler,
                clamp(sourceUV - float2(0.0, blurRadius * 0.72), 0.0, 1.0)
            );
            source = mix(source, blurred / 5.0, wetMask * 0.88);
            float luminance = dot(source.rgb, float3(0.299, 0.587, 0.114));
            source.rgb = mix(
                source.rgb,
                mix(float3(luminance), float3(0.74, 0.67, 0.34), 0.24),
                wetMask * 0.42
            );
            source.rgb *= 1.0 - wetMask * 0.12;
        }
        source.a *= insideMask * keep;

        float3 scorchedPaper = mix(
            float3(0.19, 0.055, 0.012),
            float3(0.012, 0.006, 0.004),
            clamp(charCore * 0.92 + grain * 0.22, 0.0, 1.0)
        );
        source.rgb = mix(source.rgb, source.rgb * float3(0.72, 0.33, 0.12), heatStain * 0.48);
        source.rgb = mix(source.rgb, scorchedPaper, charCore * (0.84 + grain * 0.15));

        float ashCrust = insideMask
            * step(signedDistance, 0.0)
            * smoothstep(-charWidth * 0.58, -0.002, signedDistance)
            * (0.35 + grain * 0.65);
        float effectMask = mix(horizontalMask, insideMask, radialMode);
        float emberOuter = effectMask
            * smoothstep(charWidth * 0.62, 0.0, abs(signedDistance));
        float emberCore = effectMask * smoothstep(0.024, 0.0, abs(signedDistance));

        float flameMotion = fbm(float2(
            imageUV.x * (10.0 + turbulence * 2.0) + seedOffset.x,
            time * 4.6 + seedOffset.y
        ));
        float flameDetail = valueNoise(float2(
            imageUV.x * 57.0 + seedOffset.y,
            time * 7.4 + seedOffset.x
        ));
        float flameReach = 0.075 + coarse * 0.10 + flameMotion * 0.095;
        float flame = effectMask
            * step(signedDistance, 0.0)
            * smoothstep(-flameReach, -0.005, signedDistance);
        flame *= 0.38 + flameDetail * 0.62;

        float heat = clamp(1.0 - abs(signedDistance) * 27.0, 0.0, 1.0);
        float3 emberColor = mix(
            float3(0.50, 0.018, 0.003),
            float3(1.0, 0.87, 0.11),
            heat
        );
        float3 flameColor = mix(
            float3(0.46, 0.012, 0.002),
            float3(1.0, 0.34, 0.008),
            clamp(1.0 + signedDistance / max(flameReach, 0.001), 0.0, 1.0)
        );

        float sparkCell = floor(imageUV.x * 64.0);
        float sparkSeed = hash21(float2(sparkCell + seedOffset.x, 9.7 + seedOffset.y));
        float sparkX = (sparkCell + sparkSeed) / 64.0;
        float sparkTravel = fmod(time * (0.31 + sparkSeed * 0.47) + sparkSeed, 0.43);
        float sparkY = front - 0.025 - sparkTravel;
        float2 sparkDelta = float2((imageUV.x - sparkX) * aspect, imageUV.y - sparkY);
        float spark = horizontalMask
            * (1.0 - radialMode)
            * step(0.66, sparkSeed)
            * smoothstep(0.010, 0.0015, length(sparkDelta));

        float ashCell = floor(imageUV.x * 43.0);
        float ashSeed = hash21(float2(ashCell + seedOffset.y, 23.1 + seedOffset.x));
        float ashX = (ashCell + ashSeed) / 43.0;
        float ashTravel = fmod(time * (0.12 + ashSeed * 0.22) + ashSeed * 0.7, 0.36);
        float ashY = front - 0.05 - ashTravel;
        float2 ashDelta = float2((imageUV.x - ashX) * aspect, imageUV.y - ashY);
        float ashFleck = horizontalMask
            * (1.0 - radialMode)
            * step(0.61, ashSeed)
            * smoothstep(0.014, 0.003, length(ashDelta));

        float smokeDistance = -signedDistance;
        float smoke = effectMask
            * step(0.03, smokeDistance)
            * smoothstep(0.34, 0.055, smokeDistance)
            * (0.12 + 0.22 * fbm(float2(
                imageUV.x * 5.0 + time * 0.25 + seedOffset.x,
                imageUV.y * 4.0 + seedOffset.y
            )));

        float fireAlpha = max(emberOuter * 0.80, max(emberCore, flame * 0.90));
        float3 fireRGB = emberColor * (emberOuter * 0.82 + emberCore * 1.45)
            + flameColor * flame * 1.20;
        float debrisAlpha = max(ashCrust * 0.88, ashFleck * 0.72);
        float outputAlpha = max(source.a, max(fireAlpha, max(spark, max(smoke, debrisAlpha))));
        float3 outputRGB = source.rgb * source.a
            + fireRGB
            + float3(1.0, 0.46, 0.05) * spark * 2.2
            + float3(0.12, 0.085, 0.055) * ashCrust * 0.72
            + float3(0.055, 0.045, 0.040) * ashFleck * 0.80
            + float3(0.12, 0.105, 0.105) * smoke;

        outputRGB = outputAlpha > 0.0 ? outputRGB / outputAlpha : 0.0;
        return float4(outputRGB, outputAlpha);
    }
    """#
}
