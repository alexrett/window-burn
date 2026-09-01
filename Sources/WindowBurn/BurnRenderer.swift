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
  private struct PipelineResources {
    let render: MTLRenderPipelineState
    let clearWet: MTLComputePipelineState
    let accumulateWet: MTLComputePipelineState
    let initializeCombustion: MTLComputePipelineState
    let stepCombustion: MTLComputePipelineState
  }

  private static var pipelineResourcesByRegistryID: [UInt64: PipelineResources] = [:]

  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let clearWetPipeline: MTLComputePipelineState
  private let accumulateWetPipeline: MTLComputePipelineState
  private let initializeCombustionPipeline: MTLComputePipelineState
  private let stepCombustionPipeline: MTLComputePipelineState
  private let texture: MTLTexture
  private let backdropTexture: MTLTexture
  private let wetAccumulationTexture: MTLTexture
  private let combustionStateTextures: [MTLTexture]
  private let sampler: MTLSamplerState
  private let profile: BurnProfile
  private let visualProfile: BurnVisualProfile
  private let wetVisualProfile: WetVisualProfile
  private let combustionProfile: CombustionProfile
  private let style: BurnRendererStyle
  private let horizontalPadding: Float
  private let verticalPadding: Float
  private let completion: () -> Void
  private var ignitionField: TorchIgnitionField
  private var wetDepositQueue: WetDepositQueue
  private var isWetTextureInitialized = false
  private var isCombustionStateInitialized = false
  private var currentCombustionTextureIndex = 0
  private var startTime: CFTimeInterval?
  private var lastDrawTime: CFTimeInterval?
  private var soakEndedAt: TimeInterval?
  private var burnStartedAt: TimeInterval?
  private var hasCompleted = false

  init(
    device: MTLDevice,
    image: CGImage,
    backdropImage: CGImage?,
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
    self.visualProfile = .cinematic
    self.wetVisualProfile = .cinematic
    self.combustionProfile = .cinematic
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
    var wetDepositQueue = WetDepositQueue()
    if case .soakAndBurn(let initialSoakPoints) = style {
      for point in initialSoakPoints {
        _ = wetDepositQueue.add(point)
      }
    }
    self.wetDepositQueue = wetDepositQueue

    let pipelineResources = try Self.pipelineResources(for: device)
    pipeline = pipelineResources.render
    clearWetPipeline = pipelineResources.clearWet
    accumulateWetPipeline = pipelineResources.accumulateWet
    initializeCombustionPipeline = pipelineResources.initializeCombustion
    stepCombustionPipeline = pipelineResources.stepCombustion

    let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
    let wetTextureWidth: Int
    let wetTextureHeight: Int
    if imageAspect >= 1 {
      wetTextureWidth = 256
      wetTextureHeight = max(64, Int((256 / imageAspect).rounded()))
    } else {
      wetTextureWidth = max(64, Int((256 * imageAspect).rounded()))
      wetTextureHeight = 256
    }
    let wetTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r16Float,
      width: wetTextureWidth,
      height: wetTextureHeight,
      mipmapped: false
    )
    wetTextureDescriptor.storageMode = .private
    wetTextureDescriptor.usage = [.shaderRead, .shaderWrite]
    guard let wetAccumulationTexture = device.makeTexture(descriptor: wetTextureDescriptor) else {
      throw BurnRendererError.texture("Metal could not create the wet accumulation texture.")
    }
    self.wetAccumulationTexture = wetAccumulationTexture

    let combustionTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float,
      width: wetTextureWidth,
      height: wetTextureHeight,
      mipmapped: false
    )
    combustionTextureDescriptor.storageMode = .private
    combustionTextureDescriptor.usage = [.shaderRead, .shaderWrite]
    guard
      let firstCombustionTexture = device.makeTexture(
        descriptor: combustionTextureDescriptor
      ),
      let secondCombustionTexture = device.makeTexture(
        descriptor: combustionTextureDescriptor
      )
    else {
      throw BurnRendererError.texture("Metal could not create the combustion state textures.")
    }
    combustionStateTextures = [firstCombustionTexture, secondCombustionTexture]

    let textureLoader = MTKTextureLoader(device: device)
    let textureOptions: [MTKTextureLoader.Option: Any] = [
      .origin: MTKTextureLoader.Origin.topLeft,
      .SRGB: false,
    ]
    do {
      texture = try textureLoader.newTexture(
        cgImage: image,
        options: textureOptions
      )
      backdropTexture = try textureLoader.newTexture(
        cgImage: backdropImage ?? image,
        options: textureOptions
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
    let now = CACurrentMediaTime()
    startTime = now
    lastDrawTime = now
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
    return wetDepositQueue.add(point)
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
      let commandBuffer = commandQueue.makeCommandBuffer()
    else { return }

    let now = CACurrentMediaTime()
    let elapsed = startTime.map { now - $0 } ?? 0
    let frameDuration = min(max(now - (lastDrawTime ?? now), 0), 1.0 / 15.0)
    lastDrawTime = now
    var wetDeposits = wetDepositQueue.takePendingDeposits().map { point in
      SIMD4<Float>(
        point.x,
        point.y,
        profile.seed + point.x * 137.3 + point.y * 271.9,
        0.34
      )
    }
    if soakEndedAt == nil, let activePoint = wetDepositQueue.latestPoint {
      wetDeposits.append(
        SIMD4<Float>(
          activePoint.x,
          activePoint.y,
          profile.seed + activePoint.x * 137.3 + activePoint.y * 271.9,
          max(0.012, Float(frameDuration) * 0.82)
        )
      )
    }
    guard encodeWetFieldUpdates(wetDeposits, on: commandBuffer) else { return }

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
    let impactFade: Float = {
      guard let soakEndedAt else { return 1 }
      return max(0, 1 - Float((elapsed - soakEndedAt) / 0.24))
    }()
    let activeWetPoint = impactFade > 0 ? wetDepositQueue.latestPoint : nil
    var mode = SIMD4<Float>(
      effectMode,
      Float(ignitionField.ignitions.count),
      Float(profile.duration),
      activeWetPoint == nil ? 0 : 1
    )
    let soakingDuration = min(elapsed, soakEndedAt ?? elapsed)
    let hasWetContent = wetDepositQueue.totalPointCount > 0
    var wetInfo = SIMD4<Float>(
      hasWetContent ? SoakEffect.wetness(heldFor: soakingDuration) : 0,
      burnStartedAt == nil ? (soakEndedAt == nil ? 0 : 1) : 2,
      hasWetContent ? SoakEffect.amount(heldFor: soakingDuration) : 0,
      hasWetContent ? 1 : 0
    )
    var flameLayers = SIMD4<Float>(
      visualProfile.hotCoreWidth,
      visualProfile.emberWidth,
      visualProfile.glowWidth,
      visualProfile.flameReach
    )
    var fireMaterial = SIMD4<Float>(
      visualProfile.sparkDensity,
      visualProfile.residualCharOpacity,
      visualProfile.radialContourWarp,
      visualProfile.radialBiteDepth
    )
    var waterOptics = SIMD4<Float>(
      wetVisualProfile.refractionStrength,
      wetVisualProfile.dispersionStrength,
      wetVisualProfile.reflectionStrength,
      wetVisualProfile.highlightIntensity
    )
    var waterDetail = SIMD4<Float>(
      wetVisualProfile.dropletDensity,
      wetVisualProfile.verticalSag,
      wetVisualProfile.urineTintStrength,
      0
    )
    var waterGeometry = SIMD4<Float>(
      wetVisualProfile.impactRadius,
      wetVisualProfile.absorptionRadius,
      wetVisualProfile.backgroundBlurRadius,
      wetVisualProfile.backgroundBlurStrength
    )
    var wetPaperDamage = SIMD4<Float>(
      wetVisualProfile.wrinkleStartDensity,
      wetVisualProfile.wrinkleFullDensity,
      wetVisualProfile.tearStartDensity,
      wetVisualProfile.tearFullDensity
    )
    var wetUniforms =
      activeWetPoint.map { point in
        [SIMD4<Float>(point.x, point.y, profile.seed + 11.73, impactFade)]
      } ?? []
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

    guard
      encodeCombustionFieldUpdate(
        progress: timing.x,
        elapsed: Float(elapsed),
        frameDuration: Float(frameDuration),
        effectMode: effectMode,
        ignitionUniforms: ignitionUniforms,
        on: commandBuffer
      )
    else { return }
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
      return
    }

    encoder.setRenderPipelineState(pipeline)
    encoder.setViewport(
      MTLViewport(
        originX: 0,
        originY: 0,
        width: Double(drawable.texture.width),
        height: Double(drawable.texture.height),
        znear: 0,
        zfar: 1
      )
    )
    encoder.setFragmentTexture(texture, index: 0)
    encoder.setFragmentTexture(wetAccumulationTexture, index: 1)
    encoder.setFragmentTexture(backdropTexture, index: 2)
    encoder.setFragmentTexture(
      combustionStateTextures[currentCombustionTextureIndex],
      index: 3
    )
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
    encoder.setFragmentBytes(
      &flameLayers,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 8
    )
    encoder.setFragmentBytes(
      &fireMaterial,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 9
    )
    encoder.setFragmentBytes(
      &waterOptics,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 10
    )
    encoder.setFragmentBytes(
      &waterDetail,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 11
    )
    encoder.setFragmentBytes(
      &waterGeometry,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 12
    )
    encoder.setFragmentBytes(
      &wetPaperDamage,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 13
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()

    let canComplete: Bool = {
      if case .soakAndBurn = style { return burnStartedAt != nil }
      return true
    }()
    let completionProgress = CombustionVisualModel.completionProgress(
      isRadial: effectMode > 0.5
    )
    if canComplete, timing.x >= completionProgress {
      hasCompleted = true
      view.isPaused = true
      completion()
    }
  }

  private func encodeWetFieldUpdates(
    _ deposits: [SIMD4<Float>],
    on commandBuffer: MTLCommandBuffer
  ) -> Bool {
    if !isWetTextureInitialized {
      guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else {
        return false
      }
      clearEncoder.setComputePipelineState(clearWetPipeline)
      clearEncoder.setTexture(wetAccumulationTexture, index: 0)
      clearEncoder.dispatchThreads(
        MTLSize(
          width: wetAccumulationTexture.width,
          height: wetAccumulationTexture.height,
          depth: 1
        ),
        threadsPerThreadgroup: computeThreadgroupSize(for: clearWetPipeline)
      )
      clearEncoder.endEncoding()
      isWetTextureInitialized = true
    }

    var fieldInfo = SIMD4<Float>(
      Float(texture.width) / Float(max(1, texture.height)),
      wetVisualProfile.absorptionRadius,
      wetVisualProfile.verticalSag,
      profile.seed
    )
    let maximumBatchSize = 64
    for batchStart in stride(from: 0, to: deposits.count, by: maximumBatchSize) {
      guard let accumulateEncoder = commandBuffer.makeComputeCommandEncoder() else {
        return false
      }
      let batchEnd = min(batchStart + maximumBatchSize, deposits.count)
      let batchUniforms = Array(deposits[batchStart..<batchEnd])
      var pointCount = UInt32(batchUniforms.count)
      accumulateEncoder.setComputePipelineState(accumulateWetPipeline)
      accumulateEncoder.setTexture(wetAccumulationTexture, index: 0)
      batchUniforms.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        accumulateEncoder.setBytes(baseAddress, length: bytes.count, index: 0)
      }
      accumulateEncoder.setBytes(
        &pointCount,
        length: MemoryLayout<UInt32>.stride,
        index: 1
      )
      accumulateEncoder.setBytes(
        &fieldInfo,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 2
      )
      accumulateEncoder.dispatchThreads(
        MTLSize(
          width: wetAccumulationTexture.width,
          height: wetAccumulationTexture.height,
          depth: 1
        ),
        threadsPerThreadgroup: computeThreadgroupSize(for: accumulateWetPipeline)
      )
      accumulateEncoder.endEncoding()
    }
    return true
  }

  private func encodeCombustionFieldUpdate(
    progress: Float,
    elapsed: Float,
    frameDuration: Float,
    effectMode: Float,
    ignitionUniforms: [SIMD4<Float>],
    on commandBuffer: MTLCommandBuffer
  ) -> Bool {
    if !isCombustionStateInitialized {
      guard let initializeEncoder = commandBuffer.makeComputeCommandEncoder() else {
        return false
      }
      initializeEncoder.setComputePipelineState(initializeCombustionPipeline)
      initializeEncoder.setTexture(wetAccumulationTexture, index: 0)
      initializeEncoder.setTexture(combustionStateTextures[0], index: 1)
      initializeEncoder.dispatchThreads(
        MTLSize(
          width: combustionStateTextures[0].width,
          height: combustionStateTextures[0].height,
          depth: 1
        ),
        threadsPerThreadgroup: computeThreadgroupSize(for: initializeCombustionPipeline)
      )
      initializeEncoder.endEncoding()
      isCombustionStateInitialized = true
      currentCombustionTextureIndex = 0
    }

    let nextCombustionTextureIndex = 1 - currentCombustionTextureIndex
    guard let stepEncoder = commandBuffer.makeComputeCommandEncoder() else {
      return false
    }
    var timing = SIMD4<Float>(
      progress,
      elapsed,
      Float(profile.duration),
      frameDuration
    )
    let acceptsNewMoisture = effectMode > 1.5 && ignitionField.ignitions.isEmpty
    var mode = SIMD4<Float>(
      effectMode,
      Float(ignitionField.ignitions.count),
      acceptsNewMoisture ? 1 : 0,
      0
    )
    var fieldInfo = SIMD4<Float>(
      Float(texture.width) / Float(max(1, texture.height)),
      profile.seed,
      profile.tilt,
      profile.turbulence
    )
    var physics = SIMD4<Float>(
      combustionProfile.ignitionThreshold,
      combustionProfile.moistureResistance,
      combustionProfile.evaporationRate,
      combustionProfile.fuelBurnRate
    )
    var dynamics = SIMD4<Float>(
      combustionProfile.heatDecay,
      combustionProfile.spreadRate,
      combustionProfile.heatRelease,
      combustionProfile.maximumHeat
    )
    var edgeShape = SIMD2<Float>(
      visualProfile.radialContourWarp,
      visualProfile.radialBiteDepth
    )

    stepEncoder.setComputePipelineState(stepCombustionPipeline)
    stepEncoder.setTexture(
      combustionStateTextures[currentCombustionTextureIndex],
      index: 0
    )
    stepEncoder.setTexture(wetAccumulationTexture, index: 1)
    stepEncoder.setTexture(combustionStateTextures[nextCombustionTextureIndex], index: 2)
    ignitionUniforms.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      stepEncoder.setBytes(baseAddress, length: bytes.count, index: 0)
    }
    stepEncoder.setBytes(&timing, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
    stepEncoder.setBytes(&mode, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
    stepEncoder.setBytes(&fieldInfo, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
    stepEncoder.setBytes(&physics, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
    stepEncoder.setBytes(&dynamics, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
    stepEncoder.setBytes(&edgeShape, length: MemoryLayout<SIMD2<Float>>.stride, index: 6)
    stepEncoder.dispatchThreads(
      MTLSize(
        width: combustionStateTextures[nextCombustionTextureIndex].width,
        height: combustionStateTextures[nextCombustionTextureIndex].height,
        depth: 1
      ),
      threadsPerThreadgroup: computeThreadgroupSize(for: stepCombustionPipeline)
    )
    stepEncoder.endEncoding()
    currentCombustionTextureIndex = nextCombustionTextureIndex
    return true
  }

  private func computeThreadgroupSize(
    for pipeline: MTLComputePipelineState
  ) -> MTLSize {
    let width = pipeline.threadExecutionWidth
    let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
    return MTLSize(width: width, height: height, depth: 1)
  }

  private static func pipelineResources(for device: MTLDevice) throws -> PipelineResources {
    if let cached = pipelineResourcesByRegistryID[device.registryID] {
      return cached
    }

    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: shaderSource, options: nil)
    } catch {
      throw BurnRendererError.shaderCompilation(error.localizedDescription)
    }
    guard
      let vertexFunction = library.makeFunction(name: "burnVertex"),
      let fragmentFunction = library.makeFunction(name: "burnFragment"),
      let clearWetFunction = library.makeFunction(name: "clearWetField"),
      let accumulateWetFunction = library.makeFunction(name: "accumulateWetField"),
      let initializeCombustionFunction = library.makeFunction(name: "initializeCombustionField"),
      let stepCombustionFunction = library.makeFunction(name: "stepCombustionField")
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
      let resources = PipelineResources(
        render: try device.makeRenderPipelineState(descriptor: descriptor),
        clearWet: try device.makeComputePipelineState(function: clearWetFunction),
        accumulateWet: try device.makeComputePipelineState(function: accumulateWetFunction),
        initializeCombustion: try device.makeComputePipelineState(
          function: initializeCombustionFunction
        ),
        stepCombustion: try device.makeComputePipelineState(
          function: stepCombustionFunction
        )
      )
      pipelineResourcesByRegistryID[device.registryID] = resources
      return resources
    } catch {
      throw BurnRendererError.pipeline(error.localizedDescription)
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

    float radialEdgeOffset(
        float2 uv,
        float2 physicalDelta,
        float ignitionProgress,
        float ignitionSeed,
        float turbulence,
        float contourWarpStrength,
        float biteDepth
    ) {
        float radialDistance = length(physicalDelta);
        float2 radialDirection = physicalDelta / max(radialDistance, 0.0001);
        float radialGrain = fbm(
            uv * float2(13.0, 11.0)
            + float2(ignitionSeed * 0.011, ignitionSeed * 0.019)
        );
        float radialFibers = valueNoise(
            uv * float2(47.0, 39.0) + ignitionSeed * 0.007
        );
        float offset = (radialGrain - 0.5) * 0.13 * turbulence
            + (radialFibers - 0.5) * 0.035;
        float contourNoise = fbm(
            radialDirection * 2.15
            + float2(ignitionSeed * 0.023, ignitionSeed * 0.037)
        );
        float biteNoise = valueNoise(
            radialDirection * 7.7
            + float2(ignitionSeed * 0.041, ignitionSeed * 0.029)
        );
        float frontMaturity = smoothstep(0.05, 0.30, ignitionProgress);
        float contourWarp = (contourNoise - 0.47) * contourWarpStrength;
        float bite = pow(smoothstep(0.68, 0.91, biteNoise), 1.7) * biteDepth;
        return offset + (contourWarp + bite) * frontMaturity;
    }

    kernel void clearWetField(
        texture2d<float, access::write> wetField [[texture(0)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= wetField.get_width()
            || position.y >= wetField.get_height()) {
            return;
        }
        wetField.write(float4(0.0), position);
    }

    kernel void accumulateWetField(
        texture2d<float, access::read_write> wetField [[texture(0)]],
        constant float4 *wetPoints [[buffer(0)]],
        constant uint &wetPointCount [[buffer(1)]],
        constant float4 &fieldInfo [[buffer(2)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= wetField.get_width()
            || position.y >= wetField.get_height()) {
            return;
        }

        float2 fieldSize = float2(
            wetField.get_width(),
            wetField.get_height()
        );
        float2 uv = (float2(position) + 0.5) / fieldSize;
        float aspect = fieldInfo.x;
        float absorptionRadius = fieldInfo.y;
        float verticalSag = fieldInfo.z;
        float density = wetField.read(position).r;

        for (uint index = 0; index < wetPointCount; index++) {
            float4 wetPoint = wetPoints[index];
            float2 physicalDelta = (uv - wetPoint.xy) * float2(aspect, 1.0);
            float distance = length(physicalDelta);
            float angle = atan2(physicalDelta.y, physicalDelta.x);
            float radialDirectionY = distance > 0.0001
                ? physicalDelta.y / distance
                : 0.0;
            float edgeVariation = sin(angle * 3.0 + wetPoint.z * 0.021) * 0.075;
            edgeVariation += sin(angle * 7.0 - wetPoint.z * 0.013) * 0.045;
            edgeVariation += (valueNoise(
                uv * float2(31.0, 27.0) + wetPoint.z * 0.017
            ) - 0.5) * 0.16;
            float radius = absorptionRadius * (0.90 + edgeVariation);
            radius += verticalSag
                * 0.42
                * smoothstep(-0.18, 0.92, radialDirectionY);
            float contribution = 1.0 - smoothstep(
                radius * 0.42,
                radius,
                distance
            );
            contribution *= 0.78 + valueNoise(
                uv * float2(83.0, 49.0) + wetPoint.z * 0.011
            ) * 0.22;
            density += contribution * max(0.0, wetPoint.w);
        }

        wetField.write(float4(min(density, 64.0), 0.0, 0.0, 1.0), position);
    }

    kernel void initializeCombustionField(
        texture2d<float, access::read> wetField [[texture(0)]],
        texture2d<float, access::write> combustionState [[texture(1)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= combustionState.get_width()
            || position.y >= combustionState.get_height()) {
            return;
        }

        float wetDensity = wetField.read(position).r;
        float moisture = clamp(log2(1.0 + max(0.0, wetDensity)) * 0.32, 0.0, 1.0);
        combustionState.write(float4(0.0, moisture, 1.0, 0.0), position);
    }

    kernel void stepCombustionField(
        texture2d<float, access::read> currentState [[texture(0)]],
        texture2d<float, access::read> wetField [[texture(1)]],
        texture2d<float, access::write> nextState [[texture(2)]],
        constant float4 *ignitions [[buffer(0)]],
        constant float4 &timing [[buffer(1)]],
        constant float4 &mode [[buffer(2)]],
        constant float4 &fieldInfo [[buffer(3)]],
        constant float4 &physics [[buffer(4)]],
        constant float4 &dynamics [[buffer(5)]],
        constant float2 &edgeShape [[buffer(6)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= nextState.get_width()
            || position.y >= nextState.get_height()) {
            return;
        }

        uint2 left = uint2(max(int(position.x) - 1, 0), position.y);
        uint2 right = uint2(min(position.x + 1, currentState.get_width() - 1), position.y);
        uint2 above = uint2(position.x, max(int(position.y) - 1, 0));
        uint2 below = uint2(position.x, min(position.y + 1, currentState.get_height() - 1));
        float4 state = currentState.read(position);
        float neighborHeat = (
            currentState.read(left).r
            + currentState.read(right).r
            + currentState.read(above).r
            + currentState.read(below).r * 1.35
        ) / 4.35;

        float2 fieldSize = float2(nextState.get_width(), nextState.get_height());
        float2 uv = (float2(position) + 0.5) / fieldSize;
        float progress = timing.x;
        float time = timing.y;
        float burnDuration = max(timing.z, 0.001);
        float deltaTime = clamp(timing.w, 0.0, 1.0 / 15.0);
        float effectMode = mode.x;
        uint ignitionCount = uint(mode.y);
        float aspect = fieldInfo.x;
        float seed = fieldInfo.y;
        float tilt = fieldInfo.z;
        float turbulence = fieldInfo.w;
        float2 seedOffset = float2(seed * 0.0137, seed * 0.0319);

        float sourceHeat = 0.0;
        if (effectMode < 0.5) {
            float coarse = fbm(float2(uv.x * 6.4 * turbulence, seedOffset.x));
            float detail = valueNoise(float2(uv.x * 41.0, seedOffset.y));
            float fibers = sin(uv.x * (71.0 + seed * 0.003) + seed) * 0.5 + 0.5;
            float ragged = (coarse - 0.5) * 0.19 * turbulence
                + (detail - 0.5) * 0.052
                + (fibers - 0.5) * 0.016;
            float front = progress * 1.24 - 0.12
                + tilt * (uv.x - 0.5)
                + sin(uv.x * 3.14159265) * 0.055
                + ragged;
            float frontHeat = 1.0 - smoothstep(0.012, 0.060, abs(uv.y - front));
            float passedFront = 1.0 - step(front - 0.025, uv.y);
            sourceHeat = max(frontHeat, passedFront * 0.34 * (1.0 - state.a));
        } else if (ignitionCount > 0) {
            float maximumRadius = length(float2(aspect, 1.0)) + 0.12;
            for (uint index = 0; index < ignitionCount; index++) {
                float4 ignition = ignitions[index];
                float age = max(0.0, time - ignition.z);
                float ignitionProgress = clamp(age / burnDuration, 0.0, 1.0);
                float radius = ignitionProgress * maximumRadius;
                float2 physicalDelta = (uv - ignition.xy) * float2(aspect, 1.0);
                float frontDistance = length(physicalDelta) - radius
                    + radialEdgeOffset(
                        uv,
                        physicalDelta,
                        ignitionProgress,
                        ignition.w,
                        turbulence,
                        edgeShape.x,
                        edgeShape.y
                    );
                float frontHeat = 1.0 - smoothstep(
                    0.012,
                    0.060,
                    abs(frontDistance)
                );
                float passedFront = 1.0 - smoothstep(-0.065, 0.0, frontDistance);
                sourceHeat = max(
                    sourceHeat,
                    max(frontHeat, passedFront * 0.34 * (1.0 - state.a))
                );
            }
        }

        float ignitionThreshold = physics.x;
        float moistureResistance = physics.y;
        float evaporationRate = physics.z;
        float fuelBurnRate = physics.w;
        float heatDecay = dynamics.x;
        float spreadRate = dynamics.y;
        float heatRelease = dynamics.z;
        float maximumHeat = dynamics.w;

        float heat = clamp(state.r, 0.0, maximumHeat);
        float moisture = clamp(state.g, 0.0, 1.0);
        float fuel = clamp(state.b, 0.0, 1.0);
        float damage = clamp(state.a, 0.0, 1.0);
        if (mode.z > 0.5) {
            float depositedMoisture = clamp(
                log2(1.0 + max(0.0, wetField.read(position).r)) * 0.32,
                0.0,
                1.0
            );
            moisture = max(moisture, depositedMoisture);
        }

        float retainedHeat = heat * max(0.0, 1.0 - heatDecay * deltaTime);
        float spreadHeat = clamp(neighborHeat, 0.0, maximumHeat) * spreadRate;
        float nextHeat = min(
            max(max(retainedHeat, spreadHeat), max(sourceHeat, 0.0)),
            maximumHeat
        );
        float evaporatedMoisture = min(
            moisture,
            nextHeat * evaporationRate * deltaTime
        );
        float nextMoisture = moisture - evaporatedMoisture;
        nextHeat = max(
            0.0,
            nextHeat - evaporatedMoisture * moistureResistance * 0.85
        );
        float combustibleHeat = max(
            0.0,
            nextHeat - ignitionThreshold - nextMoisture * moistureResistance
        );
        float burnedFuel = min(fuel, combustibleHeat * fuelBurnRate * deltaTime);
        float nextFuel = fuel - burnedFuel;
        nextHeat = min(nextHeat + burnedFuel * heatRelease, maximumHeat);
        float nextDamage = max(damage, 1.0 - nextFuel);

        nextState.write(
            float4(nextHeat, nextMoisture, nextFuel, nextDamage),
            position
        );
    }

    fragment float4 burnFragment(
        VertexOut input [[stage_in]],
        texture2d<float> image [[texture(0)]],
        texture2d<float> wetField [[texture(1)]],
        texture2d<float> backdrop [[texture(2)]],
        texture2d<float> combustionState [[texture(3)]],
        sampler imageSampler [[sampler(0)]],
        constant float2 &timing [[buffer(0)]],
        constant float2 &padding [[buffer(1)]],
        constant float &aspect [[buffer(2)]],
        constant float4 &variation [[buffer(3)]],
        constant float4 &mode [[buffer(4)]],
        constant float4 *ignitions [[buffer(5)]],
        constant float4 *wetPoints [[buffer(6)]],
        constant float4 &wetInfo [[buffer(7)]],
        constant float4 &flameLayers [[buffer(8)]],
        constant float4 &fireMaterial [[buffer(9)]],
        constant float4 &waterOptics [[buffer(10)]],
        constant float4 &waterDetail [[buffer(11)]],
        constant float4 &waterGeometry [[buffer(12)]],
        constant float4 &wetPaperDamage [[buffer(13)]]
    ) {
        float progress = timing.x;
        float time = timing.y;
        float seed = variation.x;
        float tilt = variation.y;
        float turbulence = variation.z;
        float charWidth = variation.w;
        float hotCoreWidth = flameLayers.x;
        float emberWidth = flameLayers.y;
        float glowWidth = flameLayers.z;
        float maximumFlameReach = flameLayers.w;
        float sparkDensity = fireMaterial.x;
        float residualCharOpacity = fireMaterial.y;
        float radialContourWarp = fireMaterial.z;
        float radialBiteDepth = fireMaterial.w;
        float refractionStrength = waterOptics.x;
        float dispersionStrength = waterOptics.y;
        float reflectionStrength = waterOptics.z;
        float highlightIntensity = waterOptics.w;
        float dropletDensity = waterDetail.x;
        float verticalSag = waterDetail.y;
        float urineTintStrength = waterDetail.z;
        float impactRadius = waterGeometry.x;
        float absorptionRadius = waterGeometry.y;
        float backgroundBlurRadius = waterGeometry.z;
        float backgroundBlurStrength = waterGeometry.w;
        float wrinkleStartDensity = wetPaperDamage.x;
        float wrinkleFullDensity = wetPaperDamage.y;
        float tearStartDensity = wetPaperDamage.z;
        float tearFullDensity = wetPaperDamage.w;
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
        float4 combustion = combustionState.sample(
            imageSampler,
            clamp(imageUV, 0.0, 1.0)
        );
        float combustionHeat = combustion.r * insideMask;
        float combustionMoisture = combustion.g * insideMask;
        float combustionDamage = combustion.a * insideMask;

        float2 seedOffset = float2(seed * 0.0137, seed * 0.0319);
        float coarse = fbm(float2(imageUV.x * 6.4 * turbulence, seedOffset.x));
        float detail = valueNoise(float2(imageUV.x * 41.0, seedOffset.y));
        float fibers = sin(imageUV.x * (71.0 + seed * 0.003) + seed) * 0.5 + 0.5;
        float ragged = (coarse - 0.5) * 0.19 * turbulence
            + (detail - 0.5) * 0.052
            + (fibers - 0.5) * 0.016;
        float broadArc = sin(imageUV.x * 3.14159265) * 0.055;
        float front = progress * 1.24 - 0.12
            + tilt * (imageUV.x - 0.5)
            + broadArc
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
                float radialDistance = length(delta);
                float radialRagged = radialEdgeOffset(
                    imageUV,
                    delta,
                    ignitionProgress,
                    ignition.w,
                    turbulence,
                    radialContourWarp,
                    radialBiteDepth
                );
                float radius = ignitionProgress * maximumRadius;
                nearestFront = min(nearestFront, radialDistance - radius + radialRagged);
            }
            signedDistance = nearestFront;
        } else if (soakMode > 0.5) {
            signedDistance = 1000.0;
        }

        float grain = fbm(imageUV * float2(31.0, 19.0) + seedOffset * 3.7);
        float pinholeNoise = valueNoise(imageUV * float2(83.0, 47.0) + seedOffset * 8.1);
        float scorchBand = insideMask
            * step(0.0, signedDistance)
            * (1.0 - smoothstep(0.0, charWidth * 1.35, signedDistance));
        scorchBand *= 0.58 + grain * 0.42;
        float stateScorch = smoothstep(0.06, 0.34, combustionDamage)
            * (1.0 - smoothstep(0.72, 0.98, combustionDamage));
        scorchBand *= mix(1.0, stateScorch, soakMode);
        float pores = scorchBand
            * smoothstep(0.74, 0.95, pinholeNoise + scorchBand * 0.18);

        float edgeBreakup = (pinholeNoise - 0.5) * hotCoreWidth * 1.8;
        float keep = smoothstep(
            -hotCoreWidth * 0.55,
            hotCoreWidth * 1.65,
            signedDistance + edgeBreakup
        );
        float radialEffectVisibility = mix(
            1.0,
            1.0 - smoothstep(0.60, 0.82, progress),
            radialMode
        );
        float terminalMaterialVisibility = mix(
            1.0,
            1.0 - smoothstep(0.70, 0.82, progress),
            radialMode
        );
        float physicalBorderDistance = min(
            min(imageUV.x, 1.0 - imageUV.x) * aspect,
            min(imageUV.y, 1.0 - imageUV.y)
        );
        float lateBorderSuppression = mix(
            1.0,
            smoothstep(0.0, 0.085, physicalBorderDistance),
            radialMode * smoothstep(0.48, 0.70, progress)
        );
        radialEffectVisibility *= lateBorderSuppression;
        float damageContour = fbm(
            imageUV * float2(6.8, 5.4) + seedOffset * 4.3
        );
        float damageFibers = valueNoise(
            imageUV * float2(37.0, 29.0) + seedOffset * 9.7
        );
        float damageBreakup = (damageContour - 0.47)
            * radialContourWarp * 3.0;
        damageBreakup += (damageFibers - 0.5) * radialBiteDepth * 2.0;
        float activeDamageEdge = smoothstep(0.10, 0.44, combustionDamage)
            * (1.0 - smoothstep(0.84, 1.0, combustionDamage));
        float fractureMaturity = radialMode * smoothstep(0.05, 0.30, progress);
        float fracturedDamage = clamp(
            combustionDamage
                + damageBreakup * activeDamageEdge * fractureMaturity,
            0.0,
            1.0
        );
        float stateKeep = 1.0 - smoothstep(0.50, 0.98, fracturedDamage);
        keep = max(keep, stateKeep) * terminalMaterialVisibility;
        float2 sourceUV = imageUV;
        float wetMask = 0.0;
        float waterThickness = 0.0;
        float wetRim = 0.0;
        float dropletMask = 0.0;
        float dropletRim = 0.0;
        float dropletHighlight = 0.0;
        float2 dropletDelta = float2(0.0);
        float dropletRadius = 0.01;
        float2 waterNormalXY = float2(0.0);
        float absorptionMask = 0.0;
        float liquidMask = 0.0;
        float localFluidDensity = 0.0;
        float wrinkleMask = 0.0;
        float wrinkleRidge = 0.0;
        float paperFoldLighting = 0.0;
        float2 paperFoldNormal = float2(0.0);
        float ruptureMask = 0.0;
        float tornEdge = 0.0;
        float tornLip = 0.0;
        float tornShadow = 0.0;
        float depositedMoisture = 0.0;
        float steamSource = 0.0;
        float steamPlume = 0.0;
        if (soakMode > 0.5 && wetInfo.w > 0.5) {
            float wetness = wetInfo.x;
            float fluidAmount = max(wetInfo.z, wetness);
            float overflow = max(0.0, fluidAmount - 1.0);
            float absorptionGrowth = 1.0 + log2(1.0 + overflow) * 0.20;
            float liquidGrowth = 1.0 + log2(1.0 + overflow) * 0.10;
            float stillSoaking = 1.0 - step(0.5, wetInfo.y);
            float seepNoise = fbm(
                imageUV * float2(17.0, 12.0) + seedOffset * 5.0
            );
            float2 wetTexel = 1.0 / float2(
                wetField.get_width(),
                wetField.get_height()
            );
            float bakedDensity = wetField.sample(
                imageSampler,
                clamp(imageUV, 0.0, 1.0)
            ).r * insideMask;
            localFluidDensity = bakedDensity;
            depositedMoisture = clamp(
                log2(1.0 + max(0.0, bakedDensity)) * 0.32,
                0.0,
                1.0
            );
            float evaporatedMoisture = max(
                0.0,
                depositedMoisture - combustionMoisture
            );
            float boilingMoisture = smoothstep(0.12, 0.78, combustionHeat)
                * max(
                    smoothstep(0.02, 0.32, evaporatedMoisture),
                    smoothstep(0.16, 0.76, combustionMoisture) * 0.75
                );
            steamSource = min(0.62, boilingMoisture * 0.62);

            for (uint plumeLayer = 0; plumeLayer < 4; plumeLayer++) {
                float layer = float(plumeLayer);
                float travel = fmod(
                    time * (0.040 + layer * 0.012) + layer * 0.051,
                    0.22
                );
                float sway = sin(
                    time * (1.7 + layer * 0.23)
                        + imageUV.y * 13.0
                        + layer * 2.1
                ) * (0.007 + travel * 0.12);
                float2 plumeUV = imageUV + float2(sway, 0.018 + travel);
                float plumeInside = step(0.0, plumeUV.x)
                    * step(plumeUV.x, 1.0)
                    * step(0.0, plumeUV.y)
                    * step(plumeUV.y, 1.0);
                float plumeDensity = wetField.sample(
                    imageSampler,
                    clamp(plumeUV, 0.0, 1.0)
                ).r * plumeInside;
                float plumeDepositedMoisture = clamp(
                    log2(1.0 + max(0.0, plumeDensity)) * 0.32,
                    0.0,
                    1.0
                );
                float4 plumeCombustion = combustionState.sample(
                    imageSampler,
                    clamp(plumeUV, 0.0, 1.0)
                ) * plumeInside;
                float plumeEvaporated = max(
                    0.0,
                    plumeDepositedMoisture - plumeCombustion.g
                );
                float plumeBoiling = smoothstep(0.12, 0.78, plumeCombustion.r)
                    * max(
                        smoothstep(0.02, 0.32, plumeEvaporated),
                        smoothstep(0.16, 0.76, plumeCombustion.g) * 0.75
                    );
                float plumeLife = 1.0 - smoothstep(0.08, 0.22, travel);
                steamPlume = max(
                    steamPlume,
                    plumeBoiling * plumeLife * (0.48 - layer * 0.055)
                );
            }
            absorptionMask = smoothstep(0.018, 0.28, bakedDensity);
            liquidMask = smoothstep(0.28, 1.40, bakedDensity)
                * mix(0.62, 1.0, stillSoaking);
            waterThickness = clamp(bakedDensity * 0.20, 0.0, 0.62);
            wetMask = max(absorptionMask * 0.62, liquidMask);

            float wrinkleProgress = smoothstep(
                wrinkleStartDensity,
                wrinkleFullDensity,
                bakedDensity
            );
            float2 paperCoordinate = imageUV * float2(aspect, 1.0);
            float foldWarp = fbm(
                imageUV * float2(10.0, 8.0) + seedOffset * 4.3
            ) * 6.0;
            float foldPhaseA = dot(
                paperCoordinate,
                float2(0.84, 0.54)
            ) * 49.0 + foldWarp;
            float foldPhaseB = dot(
                paperCoordinate,
                float2(-0.48, 0.88)
            ) * 38.0 - foldWarp * 0.72;
            float foldWaveA = sin(foldPhaseA);
            float foldWaveB = sin(foldPhaseB);
            float foldGateA = smoothstep(
                0.28,
                0.64,
                valueNoise(imageUV * float2(15.0, 12.0) + seedOffset * 7.0)
            );
            float foldGateB = smoothstep(
                0.34,
                0.70,
                valueNoise(imageUV * float2(11.0, 17.0) - seedOffset * 5.0)
            );
            float ridgeA = (1.0 - smoothstep(0.035, 0.30, abs(foldWaveA)))
                * foldGateA;
            float ridgeB = (1.0 - smoothstep(0.045, 0.32, abs(foldWaveB)))
                * foldGateB;
            wrinkleRidge = max(ridgeA, ridgeB * 0.78);
            wrinkleMask = wrinkleProgress * absorptionMask;
            paperFoldNormal = float2(
                0.84 * ridgeA * sign(foldWaveA)
                    - 0.48 * ridgeB * sign(foldWaveB),
                0.54 * ridgeA * sign(foldWaveA)
                    + 0.88 * ridgeB * sign(foldWaveB)
            );
            paperFoldLighting = clamp(
                (
                    cos(foldPhaseA) * ridgeA * 0.72
                    + cos(foldPhaseB) * ridgeB * 0.48
                ) * wrinkleMask,
                -1.0,
                1.0
            );

            float tearProgress = smoothstep(
                tearStartDensity,
                tearFullDensity,
                bakedDensity
            );
            float fractureNoise = mix(
                fbm(imageUV * float2(19.0, 15.0) + seedOffset * 11.0),
                valueNoise(imageUV * float2(47.0, 31.0) - seedOffset * 13.0),
                0.28
            );
            float fractureThreshold = mix(0.30, 0.70, fractureNoise)
                - wrinkleRidge * 0.22;
            float ruptureSignal = tearProgress - fractureThreshold;
            ruptureMask = smoothstep(-0.10, 0.10, ruptureSignal)
                * absorptionMask;
            tornEdge = (
                1.0 - smoothstep(0.035, 0.28, abs(ruptureSignal))
            ) * smoothstep(0.02, 0.18, tearProgress)
                * absorptionMask;
            tornLip = tornEdge * (1.0 - step(0.0, ruptureSignal));
            tornShadow = tornEdge * step(0.0, ruptureSignal);
            float fieldLeft = wetField.sample(
                imageSampler,
                clamp(imageUV - float2(wetTexel.x, 0.0), 0.0, 1.0)
            ).r;
            float fieldRight = wetField.sample(
                imageSampler,
                clamp(imageUV + float2(wetTexel.x, 0.0), 0.0, 1.0)
            ).r;
            float fieldUp = wetField.sample(
                imageSampler,
                clamp(imageUV - float2(0.0, wetTexel.y), 0.0, 1.0)
            ).r;
            float fieldDown = wetField.sample(
                imageSampler,
                clamp(imageUV + float2(0.0, wetTexel.y), 0.0, 1.0)
            ).r;
            waterNormalXY = float2(
                fieldLeft - fieldRight,
                fieldUp - fieldDown
            ) * 0.38;
            float activeImpactRim = 0.0;
            float activeImpactAmount = 0.0;
            for (uint index = 0; index < wetPointCount; index++) {
                float4 wetPoint = wetPoints[index];
                float2 wetDelta = imageUV - wetPoint.xy;
                float widthSeed = hash21(float2(wetPoint.z * 0.193, 43.1));
                float activeImpact = clamp(wetPoint.w, 0.0, 1.0);

                float edgeNoise = fbm(
                    imageUV * float2(31.0, 27.0)
                    + float2(wetPoint.z * 0.017, wetPoint.z * 0.029)
                );
                float fiberNoise = valueNoise(
                    imageUV * float2(83.0, 49.0)
                    + float2(wetPoint.z * 0.031, wetPoint.z * 0.011)
                );
                float2 filmDelta = wetDelta * float2(aspect, 1.0);
                float filmDistance = length(filmDelta);
                float filmAngle = atan2(filmDelta.y, filmDelta.x);
                float localRadius = mix(
                    impactRadius,
                    absorptionRadius,
                    wetness
                ) * mix(0.91, 1.07, widthSeed) * absorptionGrowth;
                float radialDirectionY = filmDistance > 0.0001
                    ? filmDelta.y / filmDistance
                    : 0.0;
                float capillaryLobes = sin(
                    filmAngle * 3.0 + wetPoint.z * 0.021
                ) * 0.075;
                capillaryLobes += sin(
                    filmAngle * 7.0 - wetPoint.z * 0.013
                ) * 0.045;
                float gravitySag = verticalSag
                    * wetness
                    * 0.42
                    * (1.0 + log2(1.0 + overflow) * 0.12)
                    * smoothstep(-0.18, 0.92, radialDirectionY);
                float edgeRadius = localRadius
                    * (
                        0.82
                        + edgeNoise * 0.24
                        + (fiberNoise - 0.5) * 0.08
                        + capillaryLobes
                    )
                    + gravitySag;
                float wetFilm = 1.0 - smoothstep(
                    edgeRadius * 0.48,
                    edgeRadius,
                    filmDistance
                );
                wetFilm *= 0.80 + edgeNoise * 0.20;

                float liquidRadius = mix(
                    impactRadius * 0.68,
                    impactRadius * 1.16,
                    wetness
                ) * liquidGrowth;
                float liquidEdgeRadius = liquidRadius
                    * (
                        0.80
                        + edgeNoise * 0.18
                        + capillaryLobes * 0.88
                    )
                    + gravitySag * 0.58;
                float liquidFilm = 1.0 - smoothstep(
                    liquidEdgeRadius * 0.40,
                    liquidEdgeRadius,
                    filmDistance
                );
                liquidFilm *= mix(0.62, 1.0, stillSoaking);

                float impactDistance = length(
                    wetDelta * float2(aspect, 1.0)
                );
                float impactPulse = 0.91 + sin(time * 22.0) * 0.09;
                float impactBody = (
                    1.0 - smoothstep(
                        impactRadius * 0.10,
                        impactRadius * 0.72,
                        impactDistance
                    )
                ) * activeImpact * impactPulse;
                float sprayNoise = valueNoise(float2(
                    filmAngle * 7.0 + wetPoint.z * 0.019,
                    impactDistance * 91.0 + time * 1.7
                ));
                float impactRing = (
                    smoothstep(
                        impactRadius * 0.48,
                        impactRadius * 0.72,
                        impactDistance
                    )
                    * (
                        1.0 - smoothstep(
                            impactRadius * 0.72,
                            impactRadius * 1.02,
                            impactDistance
                        )
                    )
                ) * activeImpact * smoothstep(0.46, 0.78, sprayNoise);
                float sprayHalo = (
                    1.0 - smoothstep(
                        impactRadius * 0.62,
                        absorptionRadius * 1.16,
                        impactDistance
                    )
                ) * smoothstep(0.62, 0.88, sprayNoise)
                    * activeImpact;

                float liveWetFilm = wetFilm * activeImpact * 0.08;
                float liveLiquidFilm = liquidFilm * activeImpact * 0.10;
                float localWet = max(
                    liveWetFilm,
                    max(
                        liveLiquidFilm,
                        max(impactBody * 0.30, sprayHalo * 0.16)
                    )
                );
                absorptionMask = 1.0
                    - (1.0 - absorptionMask)
                        * (1.0 - max(liveWetFilm, sprayHalo * 0.08));
                float liquidContribution = max(
                    liveLiquidFilm,
                    impactBody * 0.24
                );
                liquidMask = 1.0
                    - (1.0 - liquidMask) * (1.0 - liquidContribution);
                absorptionMask = clamp(absorptionMask, 0.0, 1.0);
                liquidMask = clamp(
                    liquidMask,
                    0.0,
                    1.0
                );
                waterThickness = max(
                    waterThickness,
                    max(
                        liveLiquidFilm * 0.38,
                        max(impactBody * 0.32, sprayHalo * 0.12)
                    )
                );
                localFluidDensity += liveLiquidFilm * 0.36;
                localFluidDensity += impactBody * max(1.0, fluidAmount) * 0.54;
                activeImpactRim = max(
                    activeImpactRim,
                    max(impactRing, sprayHalo * 0.34)
                );
                activeImpactAmount = max(activeImpactAmount, activeImpact);

                if (localWet > wetMask) {
                    float2 radialNormal = filmDistance > 0.0001
                        ? normalize(filmDelta)
                        : float2(0.0, -1.0);
                    float2 capillaryNormal = float2(
                        edgeNoise - 0.5,
                        fiberNoise - 0.5
                    );
                    waterNormalXY = normalize(
                        radialNormal + capillaryNormal * 0.38
                    );
                    wetMask = localWet;
                }
            }

            float absorbedRim = smoothstep(0.08, 0.36, liquidMask)
                * (1.0 - smoothstep(0.36, 0.76, liquidMask));
            float rimBreakup = smoothstep(
                0.57,
                0.82,
                fbm(imageUV * float2(43.0, 37.0) + seedOffset * 8.0)
            );
            wetRim = max(
                absorbedRim * rimBreakup * 0.12,
                activeImpactRim * 0.64
            );

            float2 dropletGrid = float2(34.0 * aspect, 26.0);
            float2 dropletCell = floor(imageUV * dropletGrid);
            float dropSeed = hash21(dropletCell + seedOffset * 13.0);
            float dropSeedY = hash21(dropletCell.yx + seedOffset * 21.0 + 7.3);
            float2 dropletCenter = (
                dropletCell + float2(dropSeed, dropSeedY)
            ) / dropletGrid;
            dropletDelta = (imageUV - dropletCenter) * float2(aspect, 1.0);
            dropletRadius = mix(0.0032, 0.0086, hash21(dropletCell + 41.7));
            float dropletDistance = length(dropletDelta);
            float dropletBody = 1.0 - smoothstep(
                dropletRadius * 0.72,
                dropletRadius,
                dropletDistance
            );
            float dropletGate = step(1.0 - dropletDensity, dropSeed)
                * smoothstep(0.20, 0.62, wetMask)
                * mix(0.38, 1.0, activeImpactAmount);
            dropletMask = dropletBody * dropletGate;
            dropletRim = smoothstep(
                dropletRadius * 0.38,
                dropletRadius * 0.76,
                dropletDistance
            ) * dropletBody * dropletGate;
            dropletHighlight = 1.0 - smoothstep(
                dropletRadius * 0.10,
                dropletRadius * 0.34,
                length(dropletDelta + float2(
                    dropletRadius * 0.25,
                    dropletRadius * 0.28
                ))
            );
            dropletHighlight *= dropletGate;

            if (dropletMask > 0.001) {
                float2 dropletNormal = dropletDelta / max(dropletRadius, 0.001);
                waterNormalXY = mix(
                    waterNormalXY,
                    dropletNormal,
                    dropletMask * 0.20
                );
            }

            float remainingMoistureRatio = depositedMoisture > 0.0001
                ? clamp(combustionMoisture / depositedMoisture, 0.0, 1.0)
                : 0.0;
            float wetRetention = mix(
                1.0,
                0.05 + smoothstep(0.02, 0.90, remainingMoistureRatio) * 0.95,
                step(1.5, wetInfo.y)
            );
            absorptionMask *= insideMask * wetness * wetRetention;
            liquidMask *= insideMask * wetness * wetRetention;
            dropletMask *= wetRetention;
            dropletRim *= wetRetention;
            dropletHighlight *= wetRetention;
            localFluidDensity *= wetRetention;
            wetMask = max(
                max(absorptionMask * 0.62, liquidMask),
                dropletMask
            );
            waterThickness = max(waterThickness, dropletMask) * wetness * wetRetention;
            wetRim = max(wetRim, dropletRim) * insideMask * wetness * wetRetention;
            float ripple = sin(
                imageUV.y * 95.0
                + fbm(imageUV * 21.0 + seedOffset) * 8.0
            );
            float2 microCoordinate = imageUV * float2(73.0, 57.0)
                + seedOffset * 9.0;
            float2 microNormal = float2(
                valueNoise(microCoordinate + float2(0.41, 0.0))
                    - valueNoise(microCoordinate - float2(0.41, 0.0)),
                valueNoise(microCoordinate + float2(0.0, 0.41))
                    - valueNoise(microCoordinate - float2(0.0, 0.41))
            );
            waterNormalXY += microNormal * 0.07;
            waterNormalXY += float2(
                ripple * 0.025,
                (seepNoise - 0.5) * 0.05
            );
            waterNormalXY = clamp(waterNormalXY, -0.55, 0.55);
            sourceUV += waterNormalXY
                * refractionStrength
                * wetMask
                * (0.34 + waterThickness * 0.36);
            sourceUV += paperFoldNormal
                * (0.0011 + wrinkleProgress * 0.0014)
                * wrinkleMask
                * (1.0 - ruptureMask * 0.72);
        }

        float combustibleMask = 1.0 - clamp(ruptureMask, 0.0, 1.0);
        scorchBand *= combustibleMask;
        pores *= combustibleMask;
        keep *= 1.0 - pores * 0.82;

        float4 source = image.sample(imageSampler, clamp(sourceUV, 0.0, 1.0));
        if (absorptionMask > 0.001) {
            float densityBlur = log2(1.0 + max(0.0, localFluidDensity));
            float blurScale = 0.82 + densityBlur * 0.34;
            float2 blurStep = float2(
                backgroundBlurRadius / max(aspect, 0.001),
                backgroundBlurRadius
            ) * blurScale;
            float3 blurredSource = source.rgb * 4.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + float2(blurStep.x, 0.0), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV - float2(blurStep.x, 0.0), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + float2(0.0, blurStep.y), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV - float2(0.0, blurStep.y), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + blurStep, 0.0, 1.0)
            ).rgb;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV - blurStep, 0.0, 1.0)
            ).rgb;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + float2(blurStep.x, -blurStep.y), 0.0, 1.0)
            ).rgb;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + float2(-blurStep.x, blurStep.y), 0.0, 1.0)
            ).rgb;
            float2 halfBlurStep = blurStep * 0.5;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + float2(halfBlurStep.x, 0.0), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV - float2(halfBlurStep.x, 0.0), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV + float2(0.0, halfBlurStep.y), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource += image.sample(
                imageSampler,
                clamp(sourceUV - float2(0.0, halfBlurStep.y), 0.0, 1.0)
            ).rgb * 2.0;
            blurredSource /= 24.0;
            source.rgb = mix(
                source.rgb,
                blurredSource,
                clamp(
                    absorptionMask
                        * backgroundBlurStrength
                        * (0.72 + densityBlur * 0.20),
                    0.0,
                    1.0
                )
            );
            source.rgb *= 1.0 - absorptionMask
                * (0.07 + min(densityBlur * 0.018, 0.09));
        }
        if (wetMask > 0.001) {
            float2 dispersionOffset = waterNormalXY
                * dispersionStrength
                * wetMask;
            float red = image.sample(
                imageSampler,
                clamp(sourceUV + dispersionOffset, 0.0, 1.0)
            ).r;
            float blue = image.sample(
                imageSampler,
                clamp(sourceUV - dispersionOffset, 0.0, 1.0)
            ).b;
            source.rgb = float3(red, source.g, blue);

            float3 waterNormal = normalize(float3(
                -waterNormalXY.x * 2.7,
                -waterNormalXY.y * 2.7,
                1.0
            ));
            float3 lightDirection = normalize(float3(-0.42, -0.58, 0.70));
            float3 halfVector = normalize(lightDirection + float3(0.0, 0.0, 1.0));
            float specular = pow(max(dot(waterNormal, halfVector), 0.0), 30.0);
            float reflectionBand = smoothstep(
                0.78,
                0.99,
                sin(
                    imageUV.y * 31.0
                    - imageUV.x * 7.0
                    + seedOffset.x
                ) * 0.5 + 0.5
            );
            float2 reflectionUV = clamp(
                sourceUV + float2(
                    waterNormalXY.x * 0.034,
                    -0.055 - waterNormalXY.y * 0.026
                ),
                0.0,
                1.0
            );
            float3 reflected = image.sample(imageSampler, reflectionUV).rgb;
            float fresnel = 0.08 + pow(1.0 - max(waterNormal.z, 0.0), 2.2);
            float reflectionAmount = clamp(
                wetMask * reflectionStrength * (0.20 + fresnel * 1.25)
                    + dropletRim * 0.035,
                0.0,
                0.22
            );
            float3 reflectionTint = mix(
                reflected,
                float3(0.66, 0.80, 0.94),
                0.10
            );
            source.rgb = mix(source.rgb, reflectionTint, reflectionAmount);

            float3 urineTint = float3(0.93, 0.72, 0.19);
            float3 absorbedEdgeTint = float3(0.57, 0.34, 0.055);
            float visibleAbsorption = smoothstep(
                0.015,
                0.34,
                absorptionMask
            );
            float visibleLiquid = smoothstep(
                0.015,
                0.24,
                liquidMask
            );
            float tintAmount = clamp(
                (
                    visibleAbsorption * 0.24
                    + visibleLiquid * 0.10
                ) * urineTintStrength,
                0.0,
                0.30
            );
            source.rgb = mix(source.rgb, urineTint, tintAmount);
            source.rgb.b *= 1.0 - tintAmount * 0.18;
            float sourceLuminance = dot(
                source.rgb,
                float3(0.2126, 0.7152, 0.0722)
            );
            float darkSurfaceBoost = mix(
                0.055,
                0.018,
                smoothstep(0.14, 0.72, sourceLuminance)
            );
            source.rgb += urineTint
                * visibleLiquid
                * urineTintStrength
                * darkSurfaceBoost;
            source.rgb += urineTint
                * visibleAbsorption
                * urineTintStrength
                * 0.042;
            float absorbedEdge = smoothstep(0.05, 0.34, absorptionMask)
                * (1.0 - smoothstep(0.58, 0.94, absorptionMask));
            source.rgb = mix(
                source.rgb,
                absorbedEdgeTint,
                absorbedEdge * urineTintStrength * 0.22
            );
            source.rgb += urineTint * wetRim * 0.035;

            float highlight = specular * wetMask * (0.055 + waterThickness * 0.08);
            highlight += wetRim * (0.012 + reflectionBand * 0.025);
            highlight += dropletHighlight * 0.07 + dropletRim * 0.012;
            source.rgb += float3(1.0, 0.88, 0.42)
                * highlight
                * highlightIntensity;
            source.rgb *= 1.0 - wetMask * 0.02;
            float4 softReflection = image.sample(
                imageSampler,
                clamp(reflectionUV + waterNormalXY * 0.006, 0.0, 1.0)
            );
            source.rgb = mix(
                source.rgb,
                softReflection.rgb,
                waterThickness * wetMask * 0.008
            );
        }
        if (wrinkleMask > 0.001) {
            source.rgb *= 1.0 + paperFoldLighting * 0.22;
            source.rgb += float3(0.90, 0.83, 0.64)
                * max(paperFoldLighting, 0.0)
                * 0.070;
            source.rgb *= 1.0 - max(-paperFoldLighting, 0.0) * 0.26;
            source.rgb += float3(0.76, 0.70, 0.56)
                * wrinkleRidge
                * wrinkleMask
                * 0.032;
        }
        if (tornEdge > 0.001 || ruptureMask > 0.001) {
            float3 soakedFiber = float3(0.24, 0.12, 0.028);
            float3 raisedFiber = float3(0.68, 0.52, 0.24);
            float3 revealedBackground = backdrop.sample(
                imageSampler,
                clamp(imageUV, 0.0, 1.0)
            ).rgb;
            source.rgb = mix(source.rgb, raisedFiber, tornLip * 0.68);
            source.rgb = mix(source.rgb, soakedFiber, tornShadow * 0.84);
            source.rgb = mix(source.rgb, revealedBackground, ruptureMask);
            source.a = max(source.a, ruptureMask);
        }
        float burnedResidue = insideMask
            * step(signedDistance, 0.0)
            * residualCharOpacity
            * combustibleMask
            * terminalMaterialVisibility
            * (0.42 + grain * 0.58);
        source.a *= insideMask * max(keep, burnedResidue);

        float localEffectCoverage = max(
            max(absorptionMask, liquidMask),
            max(dropletMask, max(ruptureMask, tornEdge))
        );
        float localOverlayCoverage = smoothstep(
            0.004,
            0.055,
            localEffectCoverage
        );
        float preserveNativeWindow = soakMode
            * (1.0 - step(1.5, wetInfo.y));
        source.a *= mix(1.0, localOverlayCoverage, preserveNativeWindow);

        float3 toastedSource = source.rgb * float3(0.50, 0.16, 0.035);
        float3 edgeSoot = mix(
            float3(0.16, 0.025, 0.004),
            float3(0.018, 0.006, 0.002),
            grain
        );
        source.rgb = mix(source.rgb, toastedSource, scorchBand * 0.46);
        source.rgb = mix(source.rgb, edgeSoot, scorchBand * scorchBand * 0.64);

        float effectMask = mix(horizontalMask, insideMask, radialMode)
            * combustibleMask
            * radialEffectVisibility;
        float edgeDistance = abs(signedDistance);
        float burnedDistance = max(0.0, -signedDistance);
        float combustionActivity = smoothstep(0.10, 0.72, combustionHeat)
            * (1.0 - smoothstep(0.88, 1.0, combustionDamage));
        float moistureDamping = 1.0
            - smoothstep(0.08, 0.72, combustionMoisture) * 0.96;
        effectMask *= max(0.028, combustionActivity) * moistureDamping;
        float edgeFlicker = 0.58 + 0.42 * valueNoise(float2(
            imageUV.x * 127.0 + seedOffset.y,
            time * 17.0 + seedOffset.x
        ));
        float hotCore = effectMask
            * (1.0 - smoothstep(0.0, hotCoreWidth, edgeDistance))
            * edgeFlicker;
        float emberEdge = effectMask
            * (1.0 - smoothstep(hotCoreWidth * 0.42, emberWidth, edgeDistance))
            * (0.76 + edgeFlicker * 0.24);
        float glow = effectMask
            * (1.0 - smoothstep(emberWidth * 0.48, glowWidth, edgeDistance));
        float tornEdgeArrival = tornEdge
            * (1.0 - smoothstep(hotCoreWidth * 0.45, glowWidth * 1.35, edgeDistance))
            * moistureDamping
            * radialEffectVisibility;
        hotCore = max(hotCore, tornEdgeArrival * edgeFlicker * 0.82);
        emberEdge = max(emberEdge, tornEdgeArrival * 0.74);
        glow = max(glow, tornEdgeArrival * 0.52);

        float flameMotion = fbm(float2(
            imageUV.x * (8.0 + turbulence * 2.8) + time * 0.42 + seedOffset.x,
            imageUV.y * 2.7 - time * 2.9 + seedOffset.y
        ));
        float flameDetail = fbm(
            imageUV * float2(31.0, 12.0)
            + float2(seedOffset.y - time * 0.75, seedOffset.x - time * 4.1)
        );
        float broadLicks = valueNoise(float2(
            imageUV.x * 13.0 - time * 0.38 + seedOffset.y,
            time * 0.72 + seedOffset.x
        ));
        float fineLicks = valueNoise(float2(
            imageUV.x * 39.0 + time * 0.21 + seedOffset.x,
            time * 1.27 + seedOffset.y
        ));
        float lickHeight = pow(
            clamp(broadLicks * 0.72 + fineLicks * 0.38, 0.0, 1.0),
            1.65
        );
        float flameReach = maximumFlameReach
            * (0.16 + lickHeight * 0.84)
            * (0.82 + flameMotion * 0.31);
        float flameEnvelope = effectMask
            * step(signedDistance, 0.0)
            * (1.0 - smoothstep(hotCoreWidth * 0.65, flameReach, burnedDistance));
        float flameBreakup = smoothstep(
            0.25,
            0.73,
            flameDetail + flameMotion * 0.28
        );
        float breakupMix = smoothstep(emberWidth, flameReach, burnedDistance);
        float flame = flameEnvelope
            * mix(1.0, 0.44 + flameBreakup * 0.56, breakupMix);
        float flamePhase = clamp(burnedDistance / max(flameReach, 0.001), 0.0, 1.0);

        float3 deepRed = float3(0.72, 0.006, 0.001);
        float3 orange = float3(1.0, 0.16, 0.002);
        float3 gold = float3(1.0, 0.68, 0.055);
        float3 hotWhite = float3(1.0, 0.96, 0.72);
        float3 flameColor = mix(deepRed, orange, 1.0 - flamePhase);
        flameColor = mix(
            flameColor,
            gold,
            pow(1.0 - flamePhase, 2.4)
        );

        float sparkCell = floor(imageUV.x * 92.0);
        float sparkSeed = hash21(float2(sparkCell + seedOffset.x, 9.7 + seedOffset.y));
        float sparkDrift = hash21(float2(sparkCell + seedOffset.y, 31.4));
        float sparkX = (sparkCell + sparkSeed) / 92.0;
        float sparkTravel = fmod(
            time * (0.24 + sparkSeed * 0.38) + sparkSeed * 0.73,
            0.48
        );
        sparkX += (sparkDrift - 0.5) * sparkTravel * 0.12;
        float sparkY = front - 0.018 - sparkTravel;
        float2 sparkDelta = float2(
            (imageUV.x - sparkX) * aspect,
            imageUV.y - sparkY
        );
        float sparkHead = 1.0 - smoothstep(0.0012, 0.0065, length(sparkDelta));
        float sparkTrail = 1.0 - smoothstep(
            0.0015,
            0.0072,
            length(float2(sparkDelta.x, sparkDelta.y * 0.38))
        );
        float sparkFlicker = 0.55 + 0.45 * sin(time * 31.0 + sparkSeed * 63.0);
        float spark = horizontalMask
            * (1.0 - radialMode)
            * step(1.0 - sparkDensity, sparkSeed)
            * max(sparkHead, sparkTrail * 0.28)
            * sparkFlicker;

        if (radialMode > 0.5 && ignitionCount > 0) {
            float maximumRadius = length(float2(aspect, 1.0)) + 0.12;
            for (uint index = 0; index < ignitionCount; index++) {
                float4 ignition = ignitions[index];
                float age = max(0.0, time - ignition.z);
                float ignitionProgress = clamp(age / burnDuration, 0.0, 1.0);
                float radius = ignitionProgress * maximumRadius;
                for (uint particle = 0; particle < 3; particle++) {
                    float particleSeed = hash21(float2(
                        ignition.w + float(particle) * 19.13,
                        7.1 + float(particle) * 5.7
                    ));
                    float driftSeed = hash21(float2(
                        ignition.w * 0.37,
                        float(particle) * 13.7 + 2.3
                    ));
                    float particleAge = fmod(
                        age * (0.31 + particleSeed * 0.31) + particleSeed * 0.61,
                        0.54
                    );
                    float angle = particleSeed * 6.2831853;
                    float2 particlePosition = ignition.xy + float2(
                        cos(angle) / aspect,
                        sin(angle)
                    ) * max(0.0, radius - emberWidth * 0.45);
                    particlePosition.x += (driftSeed - 0.5) * particleAge * 0.12;
                    particlePosition.y -= particleAge * (0.22 + particleSeed * 0.34);
                    float2 particleDelta = float2(
                        (imageUV.x - particlePosition.x) * aspect,
                        imageUV.y - particlePosition.y
                    );
                    float particleHead = 1.0 - smoothstep(
                        0.0013,
                        0.007,
                        length(particleDelta)
                    );
                    float particleTrail = 1.0 - smoothstep(
                        0.0018,
                        0.009,
                        length(float2(particleDelta.x, particleDelta.y * 0.25))
                    );
                    float active = step(0.02, age)
                        * step(1.0 - sparkDensity, driftSeed);
                    spark = max(
                        spark,
                        insideMask
                            * combustibleMask
                            * active
                            * max(particleHead, particleTrail * 0.42)
                    );
                }
            }
        }
        spark *= radialEffectVisibility * mix(1.0, moistureDamping, soakMode);

        float smoke = effectMask
            * step(emberWidth, burnedDistance)
            * (1.0 - smoothstep(glowWidth, maximumFlameReach * 2.15, burnedDistance))
            * (0.045 + 0.10 * fbm(float2(
                imageUV.x * 5.0 + time * 0.25 + seedOffset.x,
                imageUV.y * 4.0 - time * 0.34 + seedOffset.y
            )));
        float steamNoise = fbm(float2(
            imageUV.x * 7.0 + time * 0.18 + seedOffset.y,
            imageUV.y * 6.0 - time * 0.72 + seedOffset.x
        ));
        float steam = insideMask
            * soakMode
            * radialEffectVisibility
            * max(steamSource, steamPlume)
            * (0.70 + steamNoise * 0.30);

        float fireAlpha = max(
            glow * 0.32,
            max(emberEdge * 0.78, max(hotCore, flame * 0.92))
        );
        float3 fireRGB = float3(0.98, 0.055, 0.002) * glow * 0.48
            + orange * emberEdge * 1.05
            + flameColor * flame * 1.58
            + hotWhite * hotCore * 1.95;
        float outputAlpha = max(source.a, max(fireAlpha, max(spark, max(smoke, steam))));
        float3 outputRGB = source.rgb * source.a
            + fireRGB
            + float3(1.0, 0.48, 0.045) * spark * 2.20
            + float3(0.10, 0.075, 0.068) * smoke
            + float3(0.80, 0.88, 0.92) * steam * 1.18;

        outputRGB = outputAlpha > 0.0 ? outputRGB / outputAlpha : 0.0;
        return float4(outputRGB, outputAlpha);
    }
    """#
}
