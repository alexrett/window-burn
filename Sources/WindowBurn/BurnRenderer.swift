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
  case presentation(String)

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
    case .presentation(let message):
      "The captured window was not presented: \(message)"
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

  static func prewarm(device: MTLDevice) throws {
    _ = try pipelineResources(for: device)
  }

  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let clearWetPipeline: MTLComputePipelineState
  private let accumulateWetPipeline: MTLComputePipelineState
  private let initializeCombustionPipeline: MTLComputePipelineState
  private let stepCombustionPipeline: MTLComputePipelineState
  private let texture: MTLTexture
  private var handoffTexture: MTLTexture?
  private let backdropTexture: MTLTexture
  private let shadowTexture: MTLTexture
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
  private let cornerRadius: Float
  private let shadowSamplingOffset: SIMD2<Float>
  private let hasCapturedWindowShadow: Bool
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
  private var isHandoffPrepared = false
  private var isReplacementSurfaceActive = false
  private var shouldSynchronizeNextFrame = false
  private var hasCompleted = false
  private var presentationContinuation: CheckedContinuation<Void, Error>?
  private var presentationID: UUID?
  private var presentationTimeout: Task<Void, Never>?

  /// A fixed clock for the reproducible visual preview. Normal interactions use the display clock.
  var previewElapsedTime: TimeInterval?
  private var previousPreviewElapsedTime: TimeInterval?
  private(set) var lastGPUFrameDuration: TimeInterval = 0

  init(
    device: MTLDevice,
    image: CGImage,
    backdropImage: CGImage?,
    shadowImage: CGImage?,
    handoffImage: CGImage? = nil,
    shadowSamplingOffset: CGPoint,
    profile: BurnProfile,
    style: BurnRendererStyle,
    horizontalPadding: Float,
    verticalPadding: Float,
    cornerRadius: Float,
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
    self.cornerRadius = cornerRadius
    self.shadowSamplingOffset = SIMD2<Float>(
      Float(shadowSamplingOffset.x),
      Float(shadowSamplingOffset.y)
    )
    self.hasCapturedWindowShadow = shadowImage != nil
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
      wetTextureWidth = 512
      wetTextureHeight = max(128, Int((512 / imageAspect).rounded()))
    } else {
      wetTextureWidth = max(128, Int((512 * imageAspect).rounded()))
      wetTextureHeight = 512
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

    do {
      texture = try Self.makePremultipliedTexture(image: image, device: device)
      backdropTexture = try Self.makePremultipliedTexture(
        image: backdropImage ?? image, device: device)
      shadowTexture = try Self.makePremultipliedTexture(image: shadowImage ?? image, device: device)
      handoffTexture = try handoffImage.map {
        try Self.makePremultipliedTexture(image: $0, device: device)
      }
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
    guard startTime == nil else { return }
    let now = CACurrentMediaTime()
    startTime = now
    lastDrawTime = now
  }

  func synchronizeNextFrame() {
    shouldSynchronizeNextFrame = true
  }

  func activateReplacementSurface() {
    isReplacementSurfaceActive = true
    shouldSynchronizeNextFrame = true
  }

  func setHandoffImage(_ image: CGImage?) throws {
    handoffTexture = try image.map {
      try Self.makePremultipliedTexture(image: $0, device: texture.device)
    }
  }

  private static func makePremultipliedTexture(image: CGImage, device: MTLDevice) throws
    -> MTLTexture
  {
    let rowBytes = image.width * 4
    // This must match ScreenCaptureKit and CAMetalLayer to avoid clipping native colors.
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: rowBytes,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      ),
      let pixels = context.data
    else { throw BurnRendererError.texture("the premultiplied image buffer could not be created") }
    context.setBlendMode(.copy)
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: image.width,
      height: image.height,
      mipmapped: false
    )
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw BurnRendererError.texture("the premultiplied texture could not be created")
    }
    texture.replace(
      region: MTLRegionMake2D(0, 0, image.width, image.height),
      mipmapLevel: 0,
      withBytes: pixels,
      bytesPerRow: rowBytes
    )
    return texture
  }

  /// GPU completion alone does not mean the compositor has displayed the drawable.
  func presentFrame(in view: MTKView) async throws {
    guard presentationContinuation == nil else {
      throw BurnRendererError.presentation("another presentation is still pending")
    }
    let id = UUID()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      presentationID = id
      presentationContinuation = continuation
      presentationTimeout = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self?.finishPresentation(
          id: id,
          error: BurnRendererError.presentation("the display did not acknowledge the frame")
        )
      }
      view.draw()
    }
  }

  private func finishPresentation(id: UUID?, error: Error? = nil) {
    guard id == presentationID, let continuation = presentationContinuation else { return }
    presentationContinuation = nil
    presentationID = nil
    presentationTimeout?.cancel()
    presentationTimeout = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  @discardableResult
  func prepareForIgnitionHandoff() -> Bool {
    guard case .soakAndBurn = style, burnStartedAt == nil else { return false }
    isHandoffPrepared = true
    shouldSynchronizeNextFrame = true
    return true
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
    isHandoffPrepared = false
    burnStartedAt = elapsed
    ignitionField.add(point: point, startedAt: elapsed)
    return true
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard !hasCompleted else { return }
    let drawableRequestedAt = CACurrentMediaTime()
    let nextDrawable = view.currentDrawable
    InputDiagnostics.drawableWait(CACurrentMediaTime() - drawableRequestedAt)
    guard
      let drawable = nextDrawable,
      let renderPass = view.currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      finishPresentation(
        id: presentationID,
        error: BurnRendererError.presentation("no drawable or command buffer is available")
      )
      return
    }

    let now = CACurrentMediaTime()
    let elapsed = previewElapsedTime ?? startTime.map { now - $0 } ?? 0
    let clockDelta =
      previewElapsedTime.map { $0 - (previousPreviewElapsedTime ?? 0) }
      ?? now - (lastDrawTime ?? now)
    let frameDuration = isHandoffPrepared ? 0 : min(max(clockDelta, 0), 1.0 / 15.0)
    previousPreviewElapsedTime = previewElapsedTime
    lastDrawTime = now
    var wetDeposits = wetDepositQueue.takePendingDeposits().map { point in
      SIMD4<Float>(
        point.x,
        point.y,
        profile.seed + point.x * 137.3 + point.y * 271.9,
        0.34
      )
    }
    if soakEndedAt == nil, frameDuration > 0, let activePoint = wetDepositQueue.latestPoint {
      wetDeposits.append(
        SIMD4<Float>(
          activePoint.x,
          activePoint.y,
          profile.seed + activePoint.x * 137.3 + activePoint.y * 271.9,
          Float(frameDuration) * 0.82
        )
      )
    }
    guard encodeWetFieldUpdates(wetDeposits, on: commandBuffer) else {
      finishPresentation(id: presentationID, error: BurnRendererError.presentation("wet encoder"))
      return
    }

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
      burnStartedAt == nil && !isHandoffPrepared ? (soakEndedAt == nil ? 0 : 1) : 2,
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
      WetMaterialOptics.refractiveIndex
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
    var windowCornerRadius = cornerRadius
    var replacementInfo = SIMD4<Float>(
      isReplacementSurfaceActive ? 1 : 0,
      hasCapturedWindowShadow ? 1 : 0,
      shadowSamplingOffset.x,
      shadowSamplingOffset.y
    )
    var renderingInfo = SIMD4<Float>(
      startTime != nil || previewElapsedTime != nil ? 1 : 0,
      handoffTexture == nil ? 0 : 1,
      isHandoffPrepared ? 1 : 0,
      0
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
    else {
      finishPresentation(
        id: presentationID, error: BurnRendererError.presentation("combustion encoder"))
      return
    }
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
      finishPresentation(
        id: presentationID, error: BurnRendererError.presentation("render encoder"))
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
    encoder.setFragmentTexture(shadowTexture, index: 4)
    encoder.setFragmentTexture(handoffTexture ?? texture, index: 5)
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
    encoder.setFragmentBytes(
      &windowCornerRadius,
      length: MemoryLayout<Float>.stride,
      index: 14
    )
    encoder.setFragmentBytes(
      &replacementInfo,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 15
    )
    encoder.setFragmentBytes(
      &renderingInfo,
      length: MemoryLayout<SIMD4<Float>>.stride,
      index: 16
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    let pendingPresentationID = presentationID
    if let pendingPresentationID {
      drawable.addPresentedHandler { [weak self] _ in
        Task { @MainActor in
          self?.finishPresentation(id: pendingPresentationID)
        }
      }
    }
    commandBuffer.addCompletedHandler { [weak self] buffer in
      let duration = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
      let failure = buffer.status == .error ? buffer.error?.localizedDescription : nil
      Task { @MainActor in
        self?.lastGPUFrameDuration = duration
        if let failure {
          self?.finishPresentation(
            id: pendingPresentationID,
            error: BurnRendererError.presentation(failure)
          )
        }
      }
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    if shouldSynchronizeNextFrame {
      commandBuffer.waitUntilCompleted()
      shouldSynchronizeNextFrame = false
    }

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
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
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

    float paperGrain(float2 physicalUV, float seed) {
        float2 offset = float2(seed * 0.0137, seed * 0.0319);
        float bundles = valueNoise(physicalUV * float2(48.0, 240.0) + offset);
        float fibers = valueNoise(physicalUV * float2(153.0, 610.0) + offset * 3.1);
        return bundles * 0.68 + fibers * 0.32;
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
            contribution *= 0.70 + paperGrain(uv * float2(aspect, 1.0), fieldInfo.w) * 0.30;
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

        if (deltaTime <= 0.0) {
            nextState.write(float4(heat, moisture, fuel, damage), position);
            return;
        }
        float retainedHeat = heat * exp(-heatDecay * deltaTime);
        float heatDifference = max(0.0, clamp(neighborHeat, 0.0, maximumHeat) - heat);
        float spreadHeat = heatDifference * (1.0 - exp(-spreadRate * 8.0 * deltaTime));
        float nextHeat = min(
            max(retainedHeat + spreadHeat, max(sourceHeat, 0.0)),
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
        texture2d<float> windowShadow [[texture(4)]],
        texture2d<float> handoffImage [[texture(5)]],
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
        constant float4 &wetPaperDamage [[buffer(13)]],
        constant float &windowCornerRadius [[buffer(14)]],
        constant float4 &replacementInfo [[buffer(15)]],
        constant float4 &renderingInfo [[buffer(16)]]
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

        // A presented, unmodified compositor cover bridges the native window handoff.
        // Both this cover and all material textures have an explicit premultiplied layout.
        if (replacementInfo.x < 0.5 && renderingInfo.y > 0.5
            && (renderingInfo.x < 0.5 || renderingInfo.z > 0.5)) {
            return handoffImage.sample(imageSampler, input.uv);
        }
        if (renderingInfo.x < 0.5) {
            float4 original = image.sample(imageSampler, imageUV);
            float4 shadow = windowShadow.sample(imageSampler, input.uv + replacementInfo.zw);
            return replacementInfo.x * replacementInfo.y > 0.5 ? shadow : original;
        }

        float horizontalMask = step(0.0, imageUV.x) * step(imageUV.x, 1.0);
        float rectangleMask = horizontalMask
            * step(0.0, imageUV.y)
            * step(imageUV.y, 1.0);
        float capturedShape = image.sample(imageSampler, imageUV).a;
        float insideMask = rectangleMask * capturedShape;
        float contentAspect = aspect * contentSize.x / max(contentSize.y, 0.001);
        float2 shapePosition = (imageUV - 0.5) * float2(contentAspect, 1.0);
        float2 shapeHalfSize = float2(contentAspect * 0.5, 0.5);
        float shapeRadius = min(
            windowCornerRadius,
            min(shapeHalfSize.x, shapeHalfSize.y)
        );
        float2 roundedDelta = abs(shapePosition)
            - (shapeHalfSize - shapeRadius);
        float roundedRectangleDistance = length(max(roundedDelta, 0.0))
            + min(max(roundedDelta.x, roundedDelta.y), 0.0)
            - shapeRadius;
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
            float maximumRadius = length(float2(contentAspect, 1.0)) + 0.12;
            for (uint index = 0; index < ignitionCount; index++) {
                float4 ignition = ignitions[index];
                float age = max(0.0, time - ignition.z);
                float ignitionProgress = clamp(age / burnDuration, 0.0, 1.0);
                float2 delta = (imageUV - ignition.xy) * float2(contentAspect, 1.0);
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

        float grain = paperGrain(imageUV * float2(contentAspect, 1.0), seed);
        float pinholeNoise = valueNoise(imageUV * float2(83.0, 47.0) + seedOffset * 8.1);
        float scorchBand = insideMask
            * step(0.0, signedDistance)
            * (1.0 - smoothstep(0.0, charWidth * 1.35, signedDistance));
        scorchBand *= 0.58 + grain * 0.42;
        float stateScorch = smoothstep(0.01, 0.12, combustionDamage);
        scorchBand *= mix(1.0, stateScorch, soakMode);
        float pores = scorchBand
            * smoothstep(0.74, 0.95, pinholeNoise + scorchBand * 0.18);

        float edgeBreakup = (pinholeNoise - 0.5) * hotCoreWidth * 1.8;
        float keep = smoothstep(
            -hotCoreWidth * 0.55,
            hotCoreWidth * 1.65,
            signedDistance + edgeBreakup
        );
        float physicalBorderDistance = -roundedRectangleDistance;
        float borderSuppression = mix(
            1.0,
            smoothstep(0.0, 0.085, physicalBorderDistance),
            radialMode
        );
        float radialEffectVisibility = borderSuppression;
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
        keep = mix(keep, min(keep, stateKeep), radialMode);
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
            float2 paperCoordinate = imageUV * float2(contentAspect, 1.0);
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
                float2 filmDelta = wetDelta * float2(contentAspect, 1.0);
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
                    wetDelta * float2(contentAspect, 1.0)
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

            float2 dropletGrid = float2(34.0 * contentAspect, 26.0);
            float2 dropletCell = floor(imageUV * dropletGrid);
            float dropSeed = hash21(dropletCell + seedOffset * 13.0);
            float dropSeedY = hash21(dropletCell.yx + seedOffset * 21.0 + 7.3);
            float2 dropletCenter = (
                dropletCell + float2(dropSeed, dropSeedY)
            ) / dropletGrid;
            dropletDelta = (imageUV - dropletCenter) * float2(contentAspect, 1.0);
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

        float curlBand = (1.0 - smoothstep(0.0, hotCoreWidth * 7.0, abs(signedDistance)))
            * smoothstep(0.06, 0.32, combustionDamage) * insideMask * combustibleMask;
        float2 burnNormal = normalize(float2(dfdx(signedDistance), dfdy(signedDistance))
            + float2(0.00001));
        sourceUV += burnNormal * curlBand * float2(0.0018 / contentAspect, 0.0018);

        float4 source = image.sample(imageSampler, sourceUV);
        source.rgb = source.a > 0.0001 ? source.rgb / source.a : float3(0.0);
        if (absorptionMask > 0.001) {
            float densityBlur = log2(1.0 + max(0.0, localFluidDensity));
            float blurScale = 0.82 + densityBlur * 0.34;
            float2 blurStep = float2(
                backgroundBlurRadius / max(contentAspect, 0.001),
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
            // Absorbed liquid changes transmission; a free surface contributes reflection.
            // Beer-Lambert extinction does not turn black printed pixels yellow.
            float opticalDepth = max(0.0, waterThickness * 1.8 + absorptionMask * 0.38)
                * urineTintStrength;
            float3 transmittance = exp(-float3(0.11, 0.26, 1.15) * opticalDepth);
            float3 linearSource = pow(max(source.rgb, 0.0), float3(2.2));
            linearSource *= transmittance;
            float fiberDarkening = absorptionMask * (0.035 + grain * 0.075);
            linearSource *= 1.0 - fiberDarkening;

            float3 waterNormal = normalize(float3(-waterNormalXY * 1.65, 1.0));
            float3 lightDirection = normalize(float3(-0.46, -0.62, 0.64));
            float3 halfVector = normalize(lightDirection + float3(0.0, 0.0, 1.0));
            float normalReflectance = pow((1.0 - waterDetail.w) / (1.0 + waterDetail.w), 2.0);
            float fresnel = normalReflectance
                + (1.0 - normalReflectance) * pow(1.0 - max(waterNormal.z, 0.0), 5.0);
            float freeSurface = max(liquidMask * 0.55, dropletMask);
            float3 reflectedDirection = reflect(float3(0.0, 0.0, -1.0), waterNormal);
            // A broad studio/sky lobe is a stable environment approximation, not moving stripes.
            float sky = smoothstep(-0.25, 0.75, reflectedDirection.y);
            float3 environment = mix(float3(0.10, 0.12, 0.15), float3(0.76, 0.84, 0.95), sky);
            float specularAlignment = max(dot(waterNormal, halfVector), 0.0);
            float specular = pow(specularAlignment, 120.0)
                + pow(specularAlignment, 14.0) * 0.08;
            float reflectionAmount = clamp(
                freeSurface * fresnel + wetRim * reflectionStrength * 0.25,
                0.0,
                0.8
            );
            linearSource = linearSource * (1.0 - reflectionAmount)
                + environment * reflectionAmount;
            linearSource += float3(0.98, 0.99, 1.0)
                * (specular * freeSurface * 0.10
                    + dropletHighlight * 0.16
                    + wetRim * 0.008)
                * highlightIntensity;
            source.rgb = pow(max(linearSource, 0.0), float3(1.0 / 2.2));
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
            * (0.42 + grain * 0.58);
        // Preserve source coverage once; squaring captured alpha darkens rounded borders.
        source.a = capturedShape * rectangleMask * max(keep, burnedResidue);

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

        float3 toastedSource = source.rgb * float3(0.46, 0.23, 0.08);
        float3 edgeSoot = mix(
            float3(0.080, 0.053, 0.032),
            float3(0.014, 0.012, 0.010),
            grain
        );
        source.rgb = mix(source.rgb, toastedSource, scorchBand * 0.46);
        source.rgb = mix(source.rgb, edgeSoot, scorchBand * scorchBand * 0.86);
        source.rgb *= 1.0 + curlBand * dot(burnNormal, float2(-0.45, -0.65)) * 0.30;
        float ashFibers = smoothstep(0.68, 0.88, grain)
            * scorchBand * smoothstep(0.45, 0.82, combustionDamage);
        source.rgb = mix(source.rgb, float3(0.31, 0.29, 0.26), ashFibers * 0.4);

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
        float emberPatches = smoothstep(0.30, 0.74, grain * 0.72 + edgeFlicker * 0.28);
        hotCore *= emberPatches * 0.28;
        emberEdge *= 0.45 + emberPatches * 0.25;
        glow *= 0.35;

        // Integrate a short buoyant column above the actual reacting material. Each
        // sample follows a rising, curling streamline back down to its fuel source.
        // This is a 2.5D participating-medium approximation, not a 3D fluid solver.
        float2 gasCoordinate = imageUV * float2(contentAspect, 1.0);
        float curl = fbm(gasCoordinate * float2(8.0, 5.0)
            + float2(seedOffset.x, time * 1.4)) - 0.5;
        float opticalDepth = 0.0;
        float hotGas = 0.0;
        for (uint layer = 0; layer < 8; layer++) {
            float heightFraction = pow((float(layer) + 0.35) / 8.0, 1.5);
            float rise = maximumFlameReach * heightFraction;
            float2 foot = imageUV + float2(
                (curl * rise * 0.46
                    + sin(time * 3.1 + imageUV.y * 19.0 + heightFraction * 4.0)
                        * rise * 0.12) / contentAspect,
                rise
            );
            float footInside = step(0.0, foot.x) * step(foot.x, 1.0)
                * step(0.0, foot.y) * step(foot.y, 1.0);
            float4 fuelState = combustionState.sample(imageSampler, clamp(foot, 0.0, 1.0));
            float fuelShape = image.sample(imageSampler, foot).a * footInside;
            float reaction = smoothstep(0.23, 0.78, fuelState.r)
                * smoothstep(0.015, 0.14, fuelState.a)
                * smoothstep(0.01, 0.40, fuelState.b)
                * (1.0 - smoothstep(0.08, 0.72, fuelState.g))
                * fuelShape;
            float gasNoise = fbm(float2(
                gasCoordinate.x * 31.0 + curl * heightFraction * 2.2 + seedOffset.y,
                imageUV.y * 19.0 + time * 4.8 + float(layer) * 3.713
            ));
            float tongue = smoothstep(0.20 + heightFraction * 0.27, 0.76, gasNoise);
            float entrainment = pow(1.0 - heightFraction, 1.5);
            float density = reaction * tongue * entrainment * 0.42;
            opticalDepth += density;
            hotGas += density * clamp(fuelState.r / 1.5, 0.0, 1.0)
                * (1.0 - heightFraction * 0.62);
        }
        float flame = 1.0 - exp(-opticalDepth * 3.4);
        float gasTemperature = opticalDepth > 0.0001 ? hotGas / opticalDepth : 0.0;
        // Incandescent soot cools from pale yellow at its reaction zone to red at the tips.
        float3 deepRed = float3(0.74, 0.025, 0.002);
        float3 orange = float3(1.0, 0.25, 0.015);
        float3 gold = float3(1.0, 0.73, 0.22);
        float3 hotWhite = float3(1.0, 0.94, 0.72);
        float3 flameColor = mix(deepRed, orange, smoothstep(0.10, 0.38, gasTemperature));
        flameColor = mix(flameColor, gold, smoothstep(0.38, 0.78, gasTemperature));
        flameColor = mix(flameColor, hotWhite, smoothstep(0.72, 1.0, gasTemperature) * 0.65);

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
            (imageUV.x - sparkX) * contentAspect,
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
            float maximumRadius = length(float2(contentAspect, 1.0)) + 0.12;
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
                        cos(angle) / contentAspect,
                        sin(angle)
                    ) * max(0.0, radius - emberWidth * 0.45);
                    particlePosition.x += (driftSeed - 0.5) * particleAge * 0.12;
                    particlePosition.y -= particleAge * (0.22 + particleSeed * 0.34);
                    float2 particleDelta = float2(
                        (imageUV.x - particlePosition.x) * contentAspect,
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
                imageUV.y * 4.0 + time * 0.34 + seedOffset.y
            )));
        float steamNoise = fbm(float2(
            imageUV.x * 7.0 + time * 0.18 + seedOffset.y,
            imageUV.y * 6.0 + time * 0.72 + seedOffset.x
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
        // The padded capture also contains the body: only use it outside that crop.
        // Corners already belong to the original body and must not receive alpha twice.
        float exterior = 1.0 - rectangleMask;
        float shadowVisibility = exterior * smoothstep(0.08, 0.72, keep)
            * replacementInfo.x * replacementInfo.y;
        float4 capturedShadow = windowShadow.sample(imageSampler, input.uv + replacementInfo.zw);
        float4 surface = float4(source.rgb * source.a, source.a);
        surface += capturedShadow * shadowVisibility * (1.0 - surface.a);

        float vaporAlpha = clamp(smoke + steam * 0.52, 0.0, 0.7);
        float3 vaporColor = mix(float3(0.11, 0.10, 0.09), float3(0.78, 0.83, 0.86),
            steam / max(smoke + steam, 0.001));
        float3 outputRGB = vaporColor * vaporAlpha + surface.rgb * (1.0 - vaporAlpha);
        float outputAlpha = vaporAlpha + surface.a * (1.0 - vaporAlpha);
        fireAlpha = clamp(fireAlpha, 0.0, 0.96);
        float3 radiance = 1.0 - exp(-fireRGB * 1.1);
        outputRGB = radiance * fireAlpha + outputRGB * (1.0 - fireAlpha);
        outputAlpha = fireAlpha + outputAlpha * (1.0 - fireAlpha);
        float sparkAlpha = clamp(spark, 0.0, 1.0);
        outputRGB = float3(1.0, 0.68, 0.22) * sparkAlpha + outputRGB * (1.0 - sparkAlpha);
        outputAlpha = sparkAlpha + outputAlpha * (1.0 - sparkAlpha);
        return float4(outputRGB, outputAlpha);
    }
    """#
}
