import Foundation

#if os(macOS) && arch(arm64)
import Metal

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value = value else { throw ProbeError(message) }
    return value
}

func probe() throws -> Int32 {
    let device = try require(MTLCreateSystemDefaultDevice(), "no Metal device")
    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("METAL DEVICE: \(device.name)") // Diagnostic only; never used to classify.
    let queue = try require(device.makeCommandQueue(), "no command queue")
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Output { float4 position [[position]]; float4 color; };
    struct Packed { packed_float2 position; packed_float4 color; };
    vertex Output pulled(uint id [[vertex_id]], const device Packed* points [[buffer(30)]]) {
        return {float4(float2(points[id].position), 0.0, 1.0), float4(points[id].color)};
    }
    fragment float4 red(Output input [[stage_in]]) { return input.color; }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = try require(library.makeFunction(name: "pulled"), "no vertex function")
    pipelineDescriptor.fragmentFunction = try require(library.makeFunction(name: "red"), "no fragment function")
    pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    let positions: [Float] = [-1, -1, 1, 0, 0, 1, 1, -1, 1, 0, 0, 1, -1, 1, 1, 0, 0, 1]
    let vertices = try positions.withUnsafeBytes {
        try require(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared), "no vertex buffer")
    }
    let indices: [UInt32] = [0, 1, 2]
    let sourceIndex = try indices.withUnsafeBytes {
        try require(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared), "no upload buffer")
    }

    // One case from the PoC: H=65536, low-16-bit sentinel H & 65535 = 0.
    let offset = 65536
    let length = 4096
    let allocation = device.heapBufferSizeAndAlign(length: length, options: .storageModePrivate)
    guard allocation.align > 0, offset % allocation.align == 0, allocation.size <= offset else {
        throw ProbeError("heap alignment or allocation size incompatible with the PoC")
    }
    let heapDescriptor = MTLHeapDescriptor()
    heapDescriptor.type = .placement
    heapDescriptor.storageMode = .private
    heapDescriptor.hazardTrackingMode = .tracked
    heapDescriptor.size = 2097152
    let heap = try require(device.makeHeap(descriptor: heapDescriptor), "no placement heap")
    defer { withExtendedLifetime(heap) {} }
    let intended = try require(heap.makeBuffer(length: length, options: .storageModePrivate, offset: offset), "no intended index buffer")
    let sentinel = try require(heap.makeBuffer(length: length, options: .storageModePrivate, offset: offset & 65535), "no sentinel buffer")
    guard intended.heapOffset == offset, sentinel.heapOffset == 0 else {
        throw ProbeError("unexpected placement-heap offsets")
    }

    let side = 64
    let byteCount = side * side * 4
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
    textureDescriptor.usage = .renderTarget
    textureDescriptor.storageMode = .private
    let target = try require(device.makeTexture(descriptor: textureDescriptor), "no render target")
    let readback = try require(device.makeBuffer(length: byteCount, options: .storageModeShared), "no pixel readback buffer")
    let indexReadback = try require(device.makeBuffer(length: 32, options: .storageModeShared), "no index readback buffer")

    func render(_ mode: String, triangleAtSentinel: Bool = false) throws -> [UInt8] {
        let command = try require(queue.makeCommandBuffer(), "no command buffer")
        let upload = try require(command.makeBlitCommandEncoder(), "no upload encoder")
        upload.fill(buffer: intended, range: 0..<length, value: 0)
        upload.fill(buffer: sentinel, range: 0..<length, value: 0)
        upload.copy(from: sourceIndex, sourceOffset: 0,
            to: triangleAtSentinel ? sentinel : intended, destinationOffset: 0, size: sourceIndex.length)
        upload.copy(from: intended, sourceOffset: 0, to: indexReadback, destinationOffset: 0, size: 12)
        upload.copy(from: sentinel, sourceOffset: 0, to: indexReadback, destinationOffset: 16, size: 12)
        upload.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let encoder = try require(command.makeRenderCommandEncoder(descriptor: pass), "no render encoder")
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 30)
        encoder.setCullMode(.none)
        switch mode {
        case "nonindexed":
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case "compact", "wide":
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: 3, indexType: .uint32,
                indexBuffer: intended, indexBufferOffset: 0, instanceCount: 1,
                baseVertex: 0, baseInstance: mode == "wide" ? 65536 : 0)
        default: // Clear-only reference.
            break
        }
        encoder.endEncoding()
        let blit = try require(command.makeBlitCommandEncoder(), "no readback encoder")
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: side, height: side, depth: 1),
            to: readback, destinationOffset: 0, destinationBytesPerRow: side * 4,
            destinationBytesPerImage: byteCount)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, command.error == nil else {
            throw ProbeError("GPU command failed: \(String(describing: command.error))")
        }
        let words = indexReadback.contents().assumingMemoryBound(to: UInt32.self)
        let expectedReal: [UInt32] = triangleAtSentinel ? [0, 0, 0] : indices
        let expectedSentinel: [UInt32] = triangleAtSentinel ? indices : [0, 0, 0]
        guard Array(UnsafeBufferPointer(start: words, count: 3)) == expectedReal,
              Array(UnsafeBufferPointer(start: words.advanced(by: 4), count: 3)) == expectedSentinel else {
            throw ProbeError("uploaded index data failed readback verification")
        }
        let bytes = Array(UnsafeBufferPointer(
            start: readback.contents().assumingMemoryBound(to: UInt8.self), count: byteCount))
        let redPixels = stride(from: 0, to: byteCount, by: 4).filter { bytes[$0] == 255 }.count
        print("RESULT scenario=\(triangleAtSentinel ? "sentinel" : "real") mode=\(mode) red=\(redPixels)")
        return bytes
    }

    let clear = try render("clear")
    let triangle = try render("nonindexed")
    guard triangle != clear else { throw ProbeError("nonindexed triangle control did not render") }
    var matchesSignature = true
    var rendersCorrectly = true
    for triangleAtSentinel in [false, true] {
        let compact = try render("compact", triangleAtSentinel: triangleAtSentinel)
        let wide = try render("wide", triangleAtSentinel: triangleAtSentinel)
        let expected = triangleAtSentinel ? clear : triangle
        let truncated = triangleAtSentinel ? triangle : clear
        guard wide == expected else { throw ProbeError("forced-wide control rendered incorrectly") }
        matchesSignature = matchesSignature && compact == truncated
        rendersCorrectly = rendersCorrectly && compact == expected
    }
    if matchesSignature {
        print("DETECTED: virtualized macOS on Apple Silicon indicated by the PoC's Apple Paravirtual rendering signature")
        return 0
    }
    if rendersCorrectly {
        print("NOT_DETECTED: PoC renders correctly; a fixed virtual driver can also produce this result")
        return 1
    }
    throw ProbeError("rendering matches neither the full PoC signature nor correct behavior")
}

do {
    exit(try probe())
} catch {
    print("UNKNOWN: \(error)")
    exit(2)
}
#else
print("UNKNOWN: this probe requires native arm64 macOS")
exit(2)
#endif
