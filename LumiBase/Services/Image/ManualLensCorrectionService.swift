import CoreImage
import Foundation

/// Profile-free, manual geometric and optical corrections. Amounts are clamped to slider ranges.
public enum ManualLensCorrectionService {
    // Inverse radial mapping: sampling the original at a different radius moves actual image
    // features in the opposite direction. Normalize to the farthest corner, not the edge.
    private static let radialWarp = CIWarpKernel(source: """
        kernel vec2 manualRadial(float cx, float cy, float rx, float ry, float strength,
                                 float minX, float minY, float maxX, float maxY) {
            vec2 p = destCoord();
            vec2 d = vec2((p.x - cx) / rx, (p.y - cy) / ry);
            float r2 = dot(d, d) * 0.5;
            float factor = 1.0 + strength * r2;
            vec2 source = vec2(cx + (p.x - cx) * factor, cy + (p.y - cy) * factor);
            return clamp(source, vec2(minX, minY), vec2(maxX, maxY));
        }
    """)

    // A 3x3 neutral local chroma reference only affects chromatic excess on an edge;
    // a large uniform colored region retains its original color.
    private static let fringeKernel = CIKernel(source: """
        kernel vec4 manualDefringe(sampler src, float purple, float green) {
            vec2 p = destCoord();
            vec4 center = sample(src, samplerTransform(src, p));
            vec3 mean = vec3(0.0);
            float minL = 100.0;
            float maxL = -100.0;
            for (int y = -2; y <= 2; y += 2) {
                for (int x = -2; x <= 2; x += 2) {
                    vec3 neighbor = sample(src, samplerTransform(src, p + vec2(float(x), float(y)))).rgb;
                    mean += neighbor;
                    float l = dot(neighbor, vec3(0.2126, 0.7152, 0.0722));
                    minL = min(minL, l);
                    maxL = max(maxL, l);
                }
            }
            mean /= 9.0;
            float edge = smoothstep(0.035, 0.15, maxL - minL);
            float magenta = max(0.0, (center.r + center.b) * 0.5 - center.g);
            float lime = max(0.0, center.g - (center.r + center.b) * 0.5);
            float pWeight = purple * edge * smoothstep(0.05, 0.25, magenta);
            float gWeight = green * edge * smoothstep(0.05, 0.25, lime);
            vec3 neutral = vec3(dot(center.rgb, vec3(0.2126, 0.7152, 0.0722)));
            vec3 corrected = mix(center.rgb, neutral, max(pWeight, gWeight) * 0.75);
            return vec4(corrected, center.a);
        }
    """)

    private static let vignetteKernel = CIColorKernel(source: """
        kernel vec4 manualVignette(__sample pixel, float cx, float cy, float rx, float ry, float amount) {
            vec2 p = destCoord();
            vec2 d = vec2((p.x - cx) / rx, (p.y - cy) / ry);
            float radius = clamp(dot(d, d) * 0.5, 0.0, 1.0);
            float falloff = radius * radius * (3.0 - 2.0 * radius);
            float multiplier = exp2(amount * falloff);
            return vec4(pixel.rgb * multiplier, pixel.a);
        }
    """)

    public static func process(image: CIImage, distortion: Int, purpleDefringe: Int,
                               greenDefringe: Int, vignette: Int) -> CIImage {
        let distortion = max(-100, min(100, distortion))
        let purple = max(0, min(100, purpleDefringe))
        let green = max(0, min(100, greenDefringe))
        let vignette = max(-100, min(100, vignette))
        if distortion == 0 && purple == 0 && green == 0 && vignette == 0 { return image }
        let bounds = image.extent
        guard !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return image }
        let cx = bounds.midX, cy = bounds.midY
        let rx = max(bounds.width / 2, 0.5), ry = max(bounds.height / 2, 0.5)
        var output = image
        if distortion != 0, let radialWarp {
            let clamped = image.clampedToExtent()
            let arguments: [Any] = [cx, cy, rx, ry, CGFloat(distortion) / 250,
                                    bounds.minX + 0.5, bounds.minY + 0.5,
                                    bounds.maxX - 0.5, bounds.maxY - 0.5]
            output = radialWarp.apply(extent: bounds,
                roiCallback: { _, _ in bounds }, image: clamped,
                arguments: arguments) ?? output
            output = output.cropped(to: bounds)
        }
        if purple != 0 || green != 0, let fringeKernel {
            let clamped = output.clampedToExtent()
            output = fringeKernel.apply(extent: bounds,
                roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
                arguments: [clamped, CGFloat(purple) / 100, CGFloat(green) / 100]) ?? output
            output = output.cropped(to: bounds)
        }
        if vignette != 0, let vignetteKernel {
            output = vignetteKernel.apply(extent: bounds, arguments: [output, cx, cy, rx, ry,
                                                                       CGFloat(vignette) / 100]) ?? output
        }
        return output.cropped(to: bounds)
    }
}
