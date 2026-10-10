import AppKit
import CoreImage
import Foundation

/// Immutable, globally phased log-luminance correction prepared from the two legacy endpoints.
struct AcceptedHighlightsField {
    let correctionImage: CIImage
    let extent: CGRect
    let quarterWidth: Int
    let quarterHeight: Int
    let data: Data?

    init(correctionImage: CIImage, extent: CGRect, quarterWidth: Int, quarterHeight: Int, data: Data? = nil) {
        self.correctionImage = correctionImage
        self.extent = extent
        self.quarterWidth = quarterWidth
        self.quarterHeight = quarterHeight
        self.data = data
    }
}

/// Native accepted-B transform. `prepare` is intentionally synchronous: callers must run it
/// off the main thread. The only CPU work is on the quarter-resolution global guide field.
enum AcceptedHighlightsKernel {
    enum KernelError: Error {
        case mismatchedExtents
        case invalidExtent
        case renderFailed
        case kernelUnavailable
    }

    private static let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!

    /// Produces the accepted globally anchored `[::4, ::4]` field and its two 97-wide
    /// reflect-padded box-filter passes. Input CIImages are the already processed legacy endpoints.
    static func prepare(baseline: CIImage, target: CIImage, context: CIContext) throws -> AcceptedHighlightsField {
        try Task.checkCancellation()
        guard colorKernel != nil else { throw KernelError.kernelUnavailable }
        guard baseline.extent == target.extent else { throw KernelError.mismatchedExtents }
        let extent = baseline.extent.integral
        guard !extent.isInfinite, !extent.isEmpty,
              extent.width * extent.height <= 128_000_000 else { throw KernelError.invalidExtent }
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, extent.width == baseline.extent.width,
              extent.height == baseline.extent.height else { throw KernelError.invalidExtent }
        let lowWidth = (width + 3) / 4, lowHeight = (height + 3) / 4
        // Read only exact top-left `[::4, ::4]` samples. CI's
        // bottom-left origin means the first selected storage row is (height-1) mod 4.
        let lowBaseline = try renderQuarterRGBA(baseline, extent: extent, context: context,
                                                fullWidth: width, fullHeight: height,
                                                lowWidth: lowWidth, lowHeight: lowHeight)

        let lowTarget = try renderQuarterRGBA(target, extent: extent, context: context,
                                              fullWidth: width, fullHeight: height,
                                              lowWidth: lowWidth, lowHeight: lowHeight)

        let count = lowWidth * lowHeight
        var guide = [Float](repeating: 0, count: count)
        var detail = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let bi = i * 4, ti = i * 4
            let br = quantizeSRGBLinear(lowBaseline[bi])
            let bg = quantizeSRGBLinear(lowBaseline[bi + 1])
            let bb = quantizeSRGBLinear(lowBaseline[bi + 2])
            let tr = quantizeSRGBLinear(lowTarget[ti])
            let tg = quantizeSRGBLinear(lowTarget[ti + 1])
            let tb = quantizeSRGBLinear(lowTarget[ti + 2])
            let ber = encodeSRGB(br), beg = encodeSRGB(bg), beb = encodeSRGB(bb)
            let gate = smooth((0.2126 * ber + 0.7152 * beg + 0.0722 * beb) * 255, 140, 235)
            let cr = br * (1 - gate) + tr * gate
            let cg = bg * (1 - gate) + tg * gate
            let cb = bb * (1 - gate) + tb * gate
            let targetY = max(0.2126 * tr + 0.7152 * tg + 0.0722 * tb, 1e-4)
            let fusedY = max(0.2126 * cr + 0.7152 * cg + 0.0722 * cb, 1e-4)
            let g = log2(targetY)
            let d = log2(fusedY) - g
            guide[i] = Float(max(-10.0, min(4.0, g)))
            detail[i] = Float(max(-4.0, min(4.0, d)))
        }

        let meanGuide = boxMeanParallel(guide, width: lowWidth, height: lowHeight)
        let meanDetail = boxMeanParallel(detail, width: lowWidth, height: lowHeight)
        var guideDetail = [Float](repeating: 0, count: count)
        var guideSquared = [Float](repeating: 0, count: count)
        for i in 0..<count {
            guideDetail[i] = guide[i] * detail[i]
            guideSquared[i] = guide[i] * guide[i]
        }
        let meanGuideDetail = boxMeanParallel(guideDetail, width: lowWidth, height: lowHeight)
        let meanGuideSquared = boxMeanParallel(guideSquared, width: lowWidth, height: lowHeight)
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let variance = max(meanGuideSquared[i] - meanGuide[i] * meanGuide[i], 0)
            let rawA = (meanGuideDetail[i] - meanGuide[i] * meanDetail[i]) / (variance + 0.08 * 0.08)
            let clampedA = max(-2.0, min(2.0, rawA))
            a[i] = clampedA
            b[i] = meanDetail[i] - clampedA * meanGuide[i]
        }
        let meanA = boxMeanParallel(a, width: lowWidth, height: lowHeight)
        let meanB = boxMeanParallel(b, width: lowWidth, height: lowHeight)
        var correction = [Float](repeating: 0, count: count)
        for i in 0..<count {
            correction[i] = max(-3.0, min(3.0, meanA[i] * guide[i] + meanB[i]))
        }

        let bytes = correction.withUnsafeBufferPointer { Data(buffer: $0) }
        let lowImage = CIImage(bitmapData: bytes, bytesPerRow: lowWidth * MemoryLayout<Float>.size,
                               size: CGSize(width: lowWidth, height: lowHeight), format: .Rf,
                               colorSpace: nil)
        let sx = extent.width / CGFloat(lowWidth), sy = extent.height / CGFloat(lowHeight)
        let resize = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                       tx: extent.minX, ty: extent.minY)
        let fullCorrection = lowImage.transformed(by: resize).cropped(to: extent)
        return AcceptedHighlightsField(correctionImage: fullCorrection, extent: extent,
                                       quarterWidth: lowWidth, quarterHeight: lowHeight, data: bytes)
    }

    /// Applies the exact accepted pixel stages as a Core Image color kernel (Metal-backed on GPU).
    /// The returned CIImage retains the full source extent, so cropped rendering uses global field coordinates.
    static func apply(baseline: CIImage, target: CIImage, field: AcceptedHighlightsField) -> CIImage {
        precondition(baseline.extent == target.extent && baseline.extent == field.extent,
                     "Accepted highlights inputs and field must share the same full-image extent")
        guard let kernel = colorKernel else { fatalError("Core Image failed to compile the accepted highlights GPU kernel") }
        return kernel.apply(extent: field.extent, arguments: [baseline, target, field.correctionImage])!
    }

    private static func renderQuarterRGBA(_ image: CIImage, extent: CGRect, context: CIContext,
                                          fullWidth: Int, fullHeight: Int,
                                          lowWidth: Int, lowHeight: Int) throws -> [Float] {
        try Task.checkCancellation()
        guard let sampler = quarterSampler else { throw KernelError.kernelUnavailable }
        let phase = CGFloat((fullHeight - 1) % 4)
        let bounds = CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight)
        // Exact pixel-center decimation, NOT an affine resize/downsample. Keep the
        // accepted top-left [::4, ::4] lattice and full-resolution upstream graph.
        guard let sampled = sampler.apply(extent: bounds, roiCallback: { _, rect in
            CGRect(x: extent.minX + rect.minX * 4, y: extent.minY + phase + rect.minY * 4,
                   width: rect.width * 4, height: rect.height * 4).intersection(extent)
        }, image: image, arguments: [CIVector(x: extent.minX, y: extent.minY + phase)]) else {
            throw KernelError.renderFailed
        }
        var low = [Float](repeating: 0, count: lowWidth * lowHeight * 4)
        low.withUnsafeMutableBytes { bytes in
            context.render(sampled, toBitmap: bytes.baseAddress!, rowBytes: lowWidth * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linearSRGB)
        }
        try Task.checkCancellation()
        guard low.allSatisfy({ $0.isFinite }) else { throw KernelError.renderFailed }
        return low
    }

    private static let quarterSampler = CIWarpKernel(source: """
        kernel vec2 exactQuarter(vec2 origin) {
            return origin + floor(destCoord()) * 4.0 + vec2(0.5);
        }
        """)

    private static func quantizeSRGBLinear(_ linear: Float) -> Double {
        let encoded = min(max(encodeSRGB(Double(linear)), 0), 1)
        let q = (encoded * 65535).rounded() / 65535
        return decodeSRGB(q)
    }

    private static func encodeSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(max(value, 0), 1 / 2.4) - 0.055
    }

    private static func decodeSRGB(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    @inline(__always) private static func smooth(_ value: Double, _ low: Double, _ high: Double) -> Double {
        let x = min(max((value - low) / (high - low), 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// scipy.ndimage.uniform_filter(size: 97, mode: "reflect") semantics, using separable
    /// sliding windows and half-sample symmetric border reflection.
    private static func boxMean(_ input: [Float], width: Int, height: Int) -> [Float] {
        let radius = 48, divisor: Float = 97
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for offset in -radius...radius { sum += input[row + reflect(offset, count: width)] }
            for x in 0..<width {
                horizontal[row + x] = sum / divisor
                sum += input[row + reflect(x + radius + 1, count: width)]
                sum -= input[row + reflect(x - radius, count: width)]
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var sum: Float = 0
            for offset in -radius...radius { sum += horizontal[reflect(offset, count: height) * width + x] }
            for y in 0..<height {
                output[y * width + x] = sum / divisor
                sum += horizontal[reflect(y + radius + 1, count: height) * width + x]
                sum -= horizontal[reflect(y - radius, count: height) * width + x]
            }
        }
        return output
    }

    /// Partition independent rows/columns; preserve every column's sequential Float
    /// addition/subtraction order, including reflect padding and output rounding.
    static func boxMeanParallel(_ input: [Float], width: Int, height: Int) -> [Float] {
        guard input.count == width * height, width > 0, height > 0 else { return [] }
        let workers = min(8, ProcessInfo.processInfo.activeProcessorCount)
        guard workers > 1, input.count >= 100_000 else { return boxMean(input, width: width, height: height) }
        let radius = 48, divisor: Float = 97
        var horizontal = [Float](repeating: 0, count: input.count)
        horizontal.withUnsafeMutableBufferPointer { destination in
            input.withUnsafeBufferPointer { source in
                let outputAddress = Int(bitPattern: destination.baseAddress!)
                let sourceAddress = Int(bitPattern: source.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let dest = UnsafeMutablePointer<Float>(bitPattern: outputAddress)!
                    let src = UnsafePointer<Float>(bitPattern: sourceAddress)!
                    for y in stride(from: worker, to: height, by: workers) {
                        let row = y * width
                        var sum: Float = 0
                        for offset in -radius...radius { sum += src[row + reflect(offset, count: width)] }
                        for x in 0..<width {
                            dest[row + x] = sum / divisor
                            sum += src[row + reflect(x + radius + 1, count: width)]
                            sum -= src[row + reflect(x - radius, count: width)]
                        }
                    }
                }
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        output.withUnsafeMutableBufferPointer { destination in
            horizontal.withUnsafeBufferPointer { source in
                let outputAddress = Int(bitPattern: destination.baseAddress!)
                let sourceAddress = Int(bitPattern: source.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let dest = UnsafeMutablePointer<Float>(bitPattern: outputAddress)!
                    let src = UnsafePointer<Float>(bitPattern: sourceAddress)!
                    let first = worker * width / workers
                    let last = (worker + 1) * width / workers
                    for x in first..<last {
                        var sum: Float = 0
                        for offset in -radius...radius { sum += src[reflect(offset, count: height) * width + x] }
                        for y in 0..<height {
                            dest[y * width + x] = sum / divisor
                            sum += src[reflect(y + radius + 1, count: height) * width + x]
                            sum -= src[reflect(y - radius, count: height) * width + x]
                        }
                    }
                }
            }
        }
        return output
    }

    @inline(__always) private static func reflect(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = count * 2
        let folded = ((index % period) + period) % period
        return folded < count ? folded : period - folded - 1
    }

    private static let colorKernel = CIColorKernel(source: #"""
        float sat(float x, float a, float b) { float v = clamp((x-a)/(b-a), 0.0, 1.0); return v*v*(3.0-2.0*v); }
        float3 enc(float3 x) {
            float3 low = x * 12.92;
            float3 hi = 1.055 * pow(max(x, float3(0.0)), float3(1.0/2.4)) - 0.055;
            return clamp(float3(x.r <= 0.0031308 ? low.r : hi.r,
                                x.g <= 0.0031308 ? low.g : hi.g,
                                x.b <= 0.0031308 ? low.b : hi.b), 0.0, 1.0);
        }
        float3 dec(float3 x) {
            float3 low = x / 12.92;
            float3 hi = pow((x + 0.055) / 1.055, float3(2.4));
            return float3(x.r <= 0.04045 ? low.r : hi.r,
                          x.g <= 0.04045 ? low.g : hi.g,
                          x.b <= 0.04045 ? low.b : hi.b);
        }
        float3 q16(float3 x) { return dec(floor(enc(x) * 65535.0 + 0.5) / 65535.0); }
        float3 lab(float3 c) {
            float l = pow(max(0.4122214708*c.r + 0.5363325363*c.g + 0.0514459929*c.b, 0.0), 1.0/3.0);
            float m = pow(max(0.2119034982*c.r + 0.6806995451*c.g + 0.1073969566*c.b, 0.0), 1.0/3.0);
            float s = pow(max(0.0883024619*c.r + 0.2817188376*c.g + 0.6299787005*c.b, 0.0), 1.0/3.0);
            return float3(0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
                          1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
                          0.0259040371*l + 0.7827717662*m - 0.8086757660*s);
        }
        float3 invlab(float3 c) {
            float l = c.x + 0.3963377774*c.y + 0.2158037573*c.z;
            float m = c.x - 0.1055613458*c.y - 0.0638541728*c.z;
            float s = c.x - 0.0894841775*c.y - 1.2914855480*c.z;
            l=l*l*l; m=m*m*m; s=s*s*s;
            return float3(4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
                         -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
                         -0.0041960863*l - 0.7034186147*m + 1.7076147010*s);
        }
        kernel vec4 accepted(__sample baseline, __sample target, __sample correction) {
            float3 be = q16(baseline.rgb);
            float3 te = q16(target.rgb);
            float3 bs = enc(be);
            float d = clamp(correction.r, -3.0, 3.0);
            float3 z = te * exp2(d);
            float3 l = lab(z);
            // Raw chroma from recovered highlights is preserved without artificial yellow tinting.
            float3 enrichedLab = l;

            // GPU Chroma Cap (彩度上限):
            // Lightcraft-inspired perceptual chroma ceiling in Oklab space.
            // As lightness L approaches 1.0, maximum permissible chroma smoothly tapers towards 0
            // following real film/camera highlight bleaching, preventing unnatural yellow/orange
            // or color artifacts in aggressive highlight recovery while preserving hue constancy.
            float curChroma = length(enrichedLab.yz);
            float maxChroma = clamp(pow(max(1.0 - enrichedLab.x, 0.0), 1.5) * 0.35, 0.0, 0.20);
            if (curChroma > maxChroma && curChroma > 1e-6) {
                enrichedLab.yz *= (maxChroma / curChroma);
            }

            z = clamp(invlab(enrichedLab), float3(0.0), float3(4.0));

            // Lightcraft-inspired Gamut Mapping / Chroma Roll-off:
            // Desaturates towards luminance if peak channel exceeds display ceiling (1.0)
            float maxChan = max(z.r, max(z.g, z.b));
            if (maxChan > 1.0) {
                float zy = clamp(dot(z, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
                float t = clamp((1.0 - zy) / max(maxChan - zy, 1e-6), 0.0, 1.0);
                z = zy + (z - zy) * t;
            }

            float y=clamp(dot(z,float3(0.2126,0.7152,0.0722)), 1e-5, 2.0);
            float by=clamp(dot(be,float3(0.2126,0.7152,0.0722)), 1e-5, 2.0);
            float3 cn=z/y, bn=be/by;
            float3 cl=lab(cn), bl=lab(bn);
            float ch=length(cl.yz), bh=length(bl.yz);
            float hue = atan(cl.z, (abs(cl.y) > 1e-7 ? cl.y : 1e-7)) * 57.29577951308232;
            if (hue < 0.0) { hue += 360.0; }
            float chromaGate=sat(hue,15.0,30.0)*(1.0-sat(hue,75.0,95.0))*sat(y,0.025,0.15)*sat(ch,0.03,0.10)*(1.0-sat(max(bs.r,max(bs.g,bs.b)),0.88,0.995))*sat(ch-bh,0.002,0.025);
            float weight=0.45*chromaGate;
            float3 outc=mix(z,bn*y,weight);
            outc += y-dot(outc,float3(0.2126,0.7152,0.0722));
            float3 delta=outc-y;
            float3 bound = float3(
                delta.r > 0.0 ? max(0.0, 1.0-y)/max(delta.r,1e-12) : (delta.r < 0.0 ? max(0.0, y)/max(-delta.r,1e-12) : 1.0),
                delta.g > 0.0 ? max(0.0, 1.0-y)/max(delta.g,1e-12) : (delta.g < 0.0 ? max(0.0, y)/max(-delta.g,1e-12) : 1.0),
                delta.b > 0.0 ? max(0.0, 1.0-y)/max(delta.b,1e-12) : (delta.b < 0.0 ? max(0.0, y)/max(-delta.b,1e-12) : 1.0));
            float limit=clamp(min(bound.r,min(bound.g,bound.b)),0.0,1.0);
            outc=y+delta*limit;
            outc=weight>0.0 ? outc : z;
            return vec4(clamp(outc, 0.0, 1.0), 1.0);
        }
    """#)
}

/// GPU-accelerated, Lightcraft-grade highlight recovery pipeline.
/// Reconstructs unclipped scene-linear dynamic range from multi-exposure RAW endpoints,
/// performs edge-preserving base layer separation via fast guided filtering on log-luminance,
/// attenuates large-scale highlight glare while preserving 100% of micro-contrast ripples/god rays,
/// and applies an extended filmic Reinhard tonemap with specular highlight roll-off.
public enum LightcraftHighlightsKernel {
    private static let blendKernel = CIColorKernel(source: """
        kernel vec4 hdrBlend(__sample ev0, __sample ev2) {
            float y0 = dot(ev0.rgb, vec3(0.2126, 0.7152, 0.0722));
            float t = smoothstep(0.65, 0.95, y0);
            vec3 linearHDR = mix(ev0.rgb, ev2.rgb * 4.0, t);
            return vec4(linearHDR, 1.0);
        }
    """)
    
    private static let packKernel = CIColorKernel(source: """
        kernel vec4 lhPack(__sample s) {
            float y = max(dot(max(s.rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float l = log2(y / 0.18);
            return vec4(l, l * l, 0.0, 1.0);
        }
    """)
    
    private static let coeffsKernel = CIColorKernel(source: """
        kernel vec4 lhCoeffs(__sample m, float eps) {
            float mi = m.r;
            float v = max(m.g - mi * mi, 0.0);
            float a = v / (v + eps);
            return vec4(a, mi - a * mi, 0.0, 1.0);
        }
    """)
    
    private static let applyKernel = CIColorKernel(source: """
        kernel vec4 lhApply(__sample s, __sample ab, float hl) {
            vec3 c = max(s.rgb, vec3(0.0));
            float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float l = log2(y / 0.18);
            float base = ab.r * l + ab.g;
            
            // Lightcraft local highlights on edge-preserving base:
            // Attenuates large-scale illumination while leaving micro-contrast (c / 2^base) 100% intact
            float wh = smoothstep(0.5, 3.2, base);
            float delta = hl * 1.7 * wh;
            vec3 c_toned = c * exp2(delta);
            
            // Lightcraft extended Reinhard tonemap with white point wl = 0.18 * 2^2.9 = 1.343
            float yt = max(dot(c_toned, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            float wl = 0.18 * pow(2.0, 2.9);
            float o = yt * (1.0 + yt / (wl * wl)) / (1.0 + yt);
            o = min(o, 1.0);
            vec3 d = c_toned * (o / yt);
            
            // Specular desaturation & gamut map (real camera highlight bleaching):
            float mx = max(d.r, max(d.g, d.b));
            if (mx > 1.0) {
                float t = clamp((mx - 1.0) / max(mx - o, 1e-6), 0.0, 1.0);
                d = mix(d, vec3(o), t);
            }
            return vec4(clamp(d, 0.0, 1.0), 1.0);
        }
    """)
    
    public struct Field: Sendable {
        public let hdrImage: CIImage
        public let meanABImage: CIImage
        public let extent: CGRect
        
        public init(hdrImage: CIImage, meanABImage: CIImage, extent: CGRect) {
            self.hdrImage = hdrImage
            self.meanABImage = meanABImage
            self.extent = extent
        }
    }
    
    public static func prepare(ev0: CIImage, ev2: CIImage) -> Field? {
        guard let blendKernel, let packKernel, let coeffsKernel else { return nil }
        let extent = ev0.extent
        guard !extent.isInfinite, !extent.isEmpty,
              let hdr = blendKernel.apply(extent: extent, arguments: [ev0, ev2]) else { return nil }
        
        let longEdge = max(extent.width, extent.height)
        let scale = min(1.0, 1024.0 / longEdge)
        let sigma = max(1.0, 0.015 * Double(longEdge * scale))
        
        guard let logLum = packKernel.apply(extent: extent, arguments: [hdr]) else { return nil }
        let small = logLum.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
        ])
        let smallExtent = small.extent
        
        func blur(_ img: CIImage) -> CIImage {
            img.clampedToExtent()
               .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
               .cropped(to: smallExtent)
        }
        
        guard let ab = coeffsKernel.apply(extent: smallExtent, arguments: [blur(small), Float(0.35)]) else { return nil }
        let meanAB = blur(ab).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1.0 / scale, y: 1.0 / scale))
            .cropped(to: extent)
            
        return Field(hdrImage: hdr, meanABImage: meanAB, extent: extent)
    }
    
    public static func apply(field: Field, hlFactor: Float) -> CIImage? {
        guard let applyKernel else { return nil }
        return applyKernel.apply(extent: field.extent, arguments: [field.hdrImage, field.meanABImage, hlFactor])
    }
}

