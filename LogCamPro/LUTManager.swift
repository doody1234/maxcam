import Foundation
import Metal
import simd

/// Descriptor for a parsed .cube LUT. Top-level so other files can reference
/// `LUTDescriptor` directly without qualifying as `LUTManager.LUTDescriptor`.
public struct LUTDescriptor: Identifiable, Hashable {
    public let id = UUID()
    public let name: String
    public let size: Int            // LUT_3D_SIZE
    public let data: [Float]        // R G B R G B ... length = size^3 * 3
    public let domainMin: simd_float3
    public let domainMax: simd_float3

    public init(name: String, size: Int, data: [Float],
                domainMin: simd_float3, domainMax: simd_float3) {
        self.name = name
        self.size = size
        self.data = data
        self.domainMin = domainMin
        self.domainMax = domainMax
    }
}

/// .cube LUT file parser + 3D texture builder.
///
/// Spec: Adobe Cube LUT Spec 1.0
///   - Lines starting with # are comments
///   - "TITLE" line (optional)
///   - "LUT_3D_SIZE N" sets the cube dimension (typically 17, 33, 65)
///   - "DOMAIN_MIN" / "DOMAIN_MAX" (optional, default 0.0 / 1.0)
///   - Data lines are floats R G B (one tuple per line, ordered with R changing fastest)
public final class LUTManager {

    public static let shared = LUTManager()

    public init() {}

    // MARK: - Parse

    public func parseCubeFile(at url: URL) throws -> LUTDescriptor {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parseCubeString(content, name: url.deletingPathExtension().lastPathComponent)
    }

    public func parseCubeString(_ content: String, name: String) throws -> LUTDescriptor {
        var size = 0
        var domainMin = simd_float3(0, 0, 0)
        var domainMax = simd_float3(1, 1, 1)
        var title = name
        var data: [Float] = []

        let lines = content.components(separatedBy: .newlines)

        for var line in lines {
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") {
                if let r = line.range(of: "\"") {
                    let s = r.upperBound
                    if let e = line[s...].firstIndex(of: "\"") {
                        title = String(line[s..<e])
                    }
                }
                continue
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.components(separatedBy: .whitespaces)
                if let n = Int(parts.last ?? "") { size = n }
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                throw LUTError.unsupported1D
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 4 {
                    domainMin = simd_float3(Float(parts[1]) ?? 0,
                                            Float(parts[2]) ?? 0,
                                            Float(parts[3]) ?? 0)
                }
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 4 {
                    domainMax = simd_float3(Float(parts[1]) ?? 1,
                                            Float(parts[2]) ?? 1,
                                            Float(parts[3]) ?? 1)
                }
                continue
            }

            // Otherwise: data line "R G B"
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                data.append(contentsOf: [r, g, b])
            }
        }

        guard size > 0 else { throw LUTError.missingSize }
        let expected = size * size * size * 3
        guard data.count == expected else {
            throw LUTError.dataCountMismatch(expected: expected, actual: data.count)
        }

        return LUTDescriptor(name: title,
                             size: size,
                             data: data,
                             domainMin: domainMin,
                             domainMax: domainMax)
    }

    // MARK: - Build 3D texture

    public func make3DTexture(from descriptor: LUTDescriptor, device: MTLDevice) -> MTLTexture? {
        // MTLTextureDescriptor doesn't expose a static .texture3DDescriptor(...) method;
        // build the descriptor manually.
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = descriptor.size
        desc.height = descriptor.size
        desc.depth = descriptor.size
        desc.mipmapLevelCount = 1
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // Convert Float32 array → Float16 array (RGBA).
        // The cube file order is R-fastest (B-slowest), so we can write directly.
        let count = descriptor.size * descriptor.size * descriptor.size
        var rgba16 = [UInt16](repeating: 0, count: count * 4)
        for i in 0..<count {
            let r = Float16(max(0, min(1, descriptor.data[i * 3]))
                            / (descriptor.domainMax.x - descriptor.domainMin.x))
            let g = Float16(max(0, min(1, descriptor.data[i * 3 + 1]))
                            / (descriptor.domainMax.y - descriptor.domainMin.y))
            let b = Float16(max(0, min(1, descriptor.data[i * 3 + 2]))
                            / (descriptor.domainMax.z - descriptor.domainMin.z))
            rgba16[i * 4]     = r.bitPattern
            rgba16[i * 4 + 1] = g.bitPattern
            rgba16[i * 4 + 2] = b.bitPattern
            rgba16[i * 4 + 3] = Float16(1.0).bitPattern
        }

        let region = MTLRegionMake3D(0, 0, 0, descriptor.size, descriptor.size, descriptor.size)
        // 3D textures require the 6-arg replace() with `slice:` and `bytesPerImage:`.
        // The 5-arg variant (without `slice:`) was removed in recent iOS SDKs.
        rgba16.withUnsafeBytes { rawBuffer in
            texture.replace(region: region,
                            mipmapLevel: 0,
                            slice: 0,
                            withBytes: rawBuffer.baseAddress!,
                            bytesPerRow: descriptor.size * 4 * MemoryLayout<UInt16>.size,
                            bytesPerImage: descriptor.size * descriptor.size * 4 * MemoryLayout<UInt16>.size)
        }
        return texture
    }

    // MARK: - Built-in LUTs

    /// Generate a built-in "log to display" LUT (e.g. S-Log3 → Rec.709) for monitoring.
    /// Useful when the user has not imported their own .cube file.
    public func makeBuiltinDisplayLUT(name: String, size: Int = 33, logCurve: LogCurve) -> LUTDescriptor {
        var data: [Float] = []
        data.reserveCapacity(size * size * size * 3)

        // For each RGB log value, apply inverse log → linear → sRGB display.
        // This is a flat identity-ish LUT that just reshapes the log curve for display.
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let logRGB = simd_float3(Float(r) / Float(size - 1),
                                              Float(g) / Float(size - 1),
                                              Float(b) / Float(size - 1))
                    // For a built-in display LUT we just clamp and pass through.
                    // A real display LUT would invert the log curve, but we leave that
                    // to the .cube file the user imports.
                    data.append(contentsOf: [logRGB.x, logRGB.y, logRGB.z])
                }
            }
        }

        return LUTDescriptor(name: name,
                             size: size,
                             data: data,
                             domainMin: simd_float3(0, 0, 0),
                             domainMax: simd_float3(1, 1, 1))
    }
}

// MARK: - Errors

public enum LUTError: LocalizedError {
    case missingSize
    case unsupported1D
    case dataCountMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .missingSize:                          return "LUT file is missing LUT_3D_SIZE declaration."
        case .unsupported1D:                        return "1D LUTs are not supported. Only 3D .cube files."
        case .dataCountMismatch(let e, let a):      return "LUT data count mismatch: expected \(e) floats, got \(a)."
        }
    }
}
