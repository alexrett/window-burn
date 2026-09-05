import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let rendererPath =
  CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
  ?? "Sources/WindowBurn/BurnRenderer.swift"
let renderer = try String(contentsOfFile: rendererPath, encoding: .utf8)
let beginning = renderer.range(of: "private static let shaderSource = #\"\"\"")!.upperBound
let ending = renderer.range(of: "\"\"\"#", range: beginning..<renderer.endIndex)!.lowerBound
let source = String(renderer[beginning..<ending])
let library = try device.makeLibrary(source: source, options: nil)
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "burnVertex")
descriptor.fragmentFunction = library.makeFunction(name: "burnFragment")
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
descriptor.colorAttachments[0].isBlendingEnabled = true
descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
let size = 32
var pixels = [UInt8](repeating: 0, count: size * size * 4)
for y in 0..<size {
  for x in 0..<size {
    let a = [0, 64, 128, 192, 255][x % 5]
    let i = (y * size + x) * 4
    pixels[i] = UInt8(a * (y < 16 ? 3 : 1) / 4)
    pixels[i + 1] = UInt8(a / 3)
    pixels[i + 2] = UInt8(a / 5)
    pixels[i + 3] = UInt8(a)
  }
}
func texture(_ format: MTLPixelFormat, pixels: [UInt8]) -> MTLTexture {
  let td = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: format, width: size, height: size, mipmapped: false)
  td.storageMode = .shared
  td.usage = [.shaderRead, .renderTarget]
  let result = device.makeTexture(descriptor: td)!
  pixels.withUnsafeBytes {
    result.replace(
      region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!,
      bytesPerRow: size * 4)
  }
  return result
}
let original = texture(.rgba8Unorm, pixels: pixels)
let blank = texture(.rgba8Unorm, pixels: [UInt8](repeating: 0, count: pixels.count))
let sd = MTLSamplerDescriptor()
sd.minFilter = .linear
sd.magFilter = .linear
sd.sAddressMode = .clampToZero
sd.tAddressMode = .clampToZero
let sampler = device.makeSamplerState(descriptor: sd)!
for (name, replacement, rendering) in [
  ("compositor-cover", SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 1, 0, 0)),
  ("native-shadow-prestart", SIMD4<Float>(1, 1, 0, 0), SIMD4<Float>(0, 0, 0, 0)),
  ("active-dry-material", SIMD4<Float>(1, 1, 0, 0), SIMD4<Float>(1, 0, 0, 0)),
] {
  let target = texture(.bgra8Unorm, pixels: [UInt8](repeating: 0, count: pixels.count))
  let pass = MTLRenderPassDescriptor()
  pass.colorAttachments[0].texture = target
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
  pass.colorAttachments[0].loadAction = .clear
  pass.colorAttachments[0].storeAction = .store
  let command = queue.makeCommandBuffer()!
  let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
  encoder.setRenderPipelineState(pipeline)
  for index in 0...5 {
    encoder.setFragmentTexture(index == 1 || index == 3 ? blank : original, index: index)
  }
  encoder.setFragmentSamplerState(sampler, index: 0)
  for index in 0...16 {
    var value = SIMD4<Float>(repeating: 0)
    if index == 2 { value.x = 1 }
    if index == 3 { value = SIMD4(1, 0, 1, 0.03) }
    if index == 4 { value = SIMD4(2, 0, 3, 0) }
    if index == 7 { value = SIMD4(0, 2, 0, 0) }
    if index == 8 { value = SIMD4(0.0038, 0.024, 0.094, 0.2) }
    if index == 11 { value.w = 1.333 }
    if index == 15 { value = replacement }
    if index == 16 { value = rendering }
    encoder.setFragmentBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: index)
  }
  encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
  encoder.endEncoding()
  command.commit()
  command.waitUntilCompleted()
  guard command.status == .completed else {
    fatalError("GPU failed: \(String(describing: command.error))")
  }
  var output = [UInt8](repeating: 0, count: pixels.count)
  target.getBytes(
    &output, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
  var maximumDifference = 0
  for i in stride(from: 0, to: pixels.count, by: 4) {
    for (outChannel, inChannel) in [(0, 2), (1, 1), (2, 0), (3, 3)] {
      maximumDifference = max(
        maximumDifference, abs(Int(output[i + outChannel]) - Int(pixels[i + inChannel])))
    }
  }
  print(
    "\(name): max byte difference=\(maximumDifference), GPU=\((command.gpuEndTime-command.gpuStartTime)*1000)ms"
  )
  guard maximumDifference <= 1 else { exit(1) }
}

// Optional GPU-only stress measurement; upload, simulation and compositor time are excluded.
if CommandLine.arguments.contains("--benchmark") {
  func upload<T>(width: Int, height: Int, format: MTLPixelFormat, values: [T]) -> MTLTexture {
    let description = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: false)
    description.storageMode = .shared
    description.usage = [.shaderRead, .renderTarget]
    let texture = device.makeTexture(descriptor: description)!
    values.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: $0.count / height)
    }
    return texture
  }

  for (width, height) in [(1856, 1260), (3588, 2350)] {
    let aspect = Float(width) / Float(height)
    var fullImage = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: fullImage.count, by: 4) {
      fullImage[index] = UInt8(80 + (index / 4 % width) % 176)
      fullImage[index + 1] = UInt8(80 + (index / 4 / width) % 176)
      fullImage[index + 2] = 130
    }
    let fullTexture = upload(width: width, height: height, format: .rgba8Unorm, values: fullImage)
    let target = upload(width: width, height: height, format: .bgra8Unorm, values: fullImage)
    let fieldWidth = 512
    let fieldHeight = Int(512 / aspect)
    for wet in [false, true] {
      var wetPixels = [Float16](repeating: 0, count: fieldWidth * fieldHeight)
      var statePixels = [Float16](repeating: 0, count: fieldWidth * fieldHeight * 4)
      for y in 0..<fieldHeight {
        for x in 0..<fieldWidth {
          let uv = SIMD2(Float(x) / Float(fieldWidth), Float(y) / Float(fieldHeight))
          let dx = (uv.x - 0.5) * aspect
          let dy = uv.y - 0.60
          let distance = sqrt(dx * dx + dy * dy)
          let front = distance - 0.36
          let reaction = exp(-front * front * 280)
          let damage = min(1, max(0, 0.5 - front * 7))
          let moisture = wet ? exp(-distance * distance * 8) : 0
          let i = y * fieldWidth + x
          wetPixels[i] = Float16(moisture * 3.2)
          statePixels[i * 4] = Float16(reaction * 1.3)
          statePixels[i * 4 + 1] = Float16(moisture * 0.30)
          statePixels[i * 4 + 2] = Float16(1 - damage)
          statePixels[i * 4 + 3] = Float16(damage)
        }
      }
      let wetTexture = upload(
        width: fieldWidth, height: fieldHeight, format: .r16Float, values: wetPixels)
      let stateTexture = upload(
        width: fieldWidth, height: fieldHeight, format: .rgba16Float, values: statePixels)
      var samples: [Double] = []
      for frame in 0..<24 {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        for index in 0...5 {
          encoder.setFragmentTexture(
            index == 1 ? wetTexture : index == 3 ? stateTexture : fullTexture,
            index: index)
        }
        encoder.setFragmentSamplerState(sampler, index: 0)
        let values: [SIMD4<Float>] = [
          SIMD4(0.25, 1.5 + Float(frame) / 60, 0, 0),
          SIMD4(0.08, 0.12, 0, 0),
          SIMD4(aspect, 0, 0, 0),
          SIMD4(73.9, 0, 1.15, 0.075),
          SIMD4(wet ? 2 : 1, 1, 6, wet ? 1 : 0),
          SIMD4(0.5, 0.6, 0, 73.9),
          SIMD4(0.48, 0.52, 73.9, 0.8),
          SIMD4(1, 2, 3, wet ? 1 : 0),
          SIMD4(0.0038, 0.024, 0.094, 0.20),
          SIMD4(0.28, 0, 0.195, 0.076),
          SIMD4(0.00045, 0.000008, 0.028, 0.20),
          SIMD4(0.055, 0.034, 0.56, 1.333),
          SIMD4(0.064, 0.155, 0.0032, 0.28),
          SIMD4(0.62, 1.8, 3, 5.4),
          .zero,
          SIMD4(1, 0, 0, 0),
          SIMD4(1, 0, 0, 0),
        ]
        for (index, var value) in values.enumerated() {
          encoder.setFragmentBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: index)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { fatalError("Benchmark render failed") }
        if frame >= 4 { samples.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
      }
      samples.sort()
      let label = wet ? "soak-and-burn" : "dry-burn"
      print(
        "benchmark \(device.name) \(width)x\(height) \(label): median=\(samples[10])ms p95=\(samples[18])ms; 20 measured frames, GPU fragment pass only"
      )
    }
  }
}
