import CoreImage
import CoreGraphics

/// Experimental scene-linear, luminance-only controls. Input should be in a linear RGB working space.
/// These bounded approximations are not Adobe/Lightroom algorithms.
public enum ExperimentalToneService {
    private static let tonalKernel = CIColorKernel(source: """
        kernel vec4 tone(__sample pixel, float amount, float mode) {
            vec3 rgb = max(pixel.rgb, vec3(0.0));
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float t = clamp(y, 0.0, 1.0);
            float a = clamp(amount, -1.0, 1.0);
            float mask = 1.0;
            float delta = 0.0;
            if (mode < 0.5) {
                // Soft S curve, with the pivot at middle gray.
                delta = a * 0.8 * (t - 0.4) * t * (1.0 - t);
            } else if (mode < 1.5) {
                // Monotone shadow shoulder. The previous per-pixel EV mask
                // folded around middle gray, reversing nearby tones.
                // Its polynomial's worst-case slope stays >= 0.65 at +100.
                float shoulder = t * pow(1.0 - t, 3.0);
                delta = (a >= 0.0 ? 1.4 : 0.65) * a * shoulder;
            } else if (mode < 2.5) {
                // Spread negative white compression across the upper tones:
                // retain its useful darkening but avoid a flat middle shoulder.
                // At -100, its narrowest slope is >0.66 (previously ~0.51).
                if (a < 0.0) {
                    mask = smoothstep(0.25, 0.95, t);
                    delta = a * 0.28 * mask * sqrt(max(1.0 - t, 0.0));
                } else {
                    mask = smoothstep(0.32, 0.88, t);
                    delta = a * 0.22 * mask * (1.0 - t);
                }
            }
            float target = clamp(y + delta, 0.0, 1.0);
            float ratio = clamp(target / max(y, 0.00001), 0.0, 4.0);
            return vec4(clamp(rgb * ratio, 0.0, 1.0), pixel.a);
        }
        """)

    private static let detailKernel = CIColorKernel(source: """
        kernel vec4 textureTone(__sample pixel, __sample low, float amount) {
            vec3 rgb = max(pixel.rgb, vec3(0.0));
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float base = dot(max(low.rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
            float detail = y - base;
            // Suppress large discontinuities (avoid bright/dark edge halos).
            float gate = 1.0 - smoothstep(0.035, 0.18, abs(detail));
            float target = clamp(y + clamp(amount, -1.0, 1.0) * detail * 0.65 * gate, 0.0, 1.0);
            float ratio = clamp(target / max(y, 0.00001), 0.0, 4.0);
            return vec4(clamp(rgb * ratio, 0.0, 1.0), pixel.a);
        }
        """)

    // Bounded local dark-channel transmission approximation, not Adobe's model.
    // Positive values change luminance while retaining hue; negative values
    // mix neutral airlight into RGB, intentionally washing out color like mist.
    private static let hazeKernel = CIColorKernel(source: """
        kernel vec4 localHaze(__sample pixel, __sample dark, float amount) {
            vec3 rgb = max(pixel.rgb, vec3(0.0));
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float a = clamp(abs(amount), 0.0, 1.0);
            float localDark = clamp(dark.r, 0.0, 1.0);
            if (amount < 0.0) {
                float veil = a * (0.36 + 0.42 * localDark);
                return vec4(mix(rgb, vec3(0.78), veil), pixel.a);
            }
            float t = clamp(1.0 - localDark * 1.1, 0.35, 1.0);
            float recovered = clamp((y - 0.72 * (1.0 - t)) / t, 0.0, 1.0);
            float target = mix(y, recovered, a * 0.85);
            float ratio = clamp(target / max(y, 0.00001), 0.0, 3.0);
            return vec4(clamp(rgb * ratio, 0.0, 1.0), pixel.a);
        }
        """)

    private static func apply(_ image: CIImage, amount: Int, mode: Float) -> CIImage {
        guard amount != 0, let tonalKernel else { return image }
        return tonalKernel.apply(extent: image.extent, arguments: [image, Float(max(-100, min(100, amount))) / 100, mode]) ?? image
    }

    public static func contrast(_ image: CIImage, amount: Int) -> CIImage { apply(image, amount: amount, mode: 0) }
    public static func shadows(_ image: CIImage, amount: Int) -> CIImage { apply(image, amount: amount, mode: 1) }
    public static func whites(_ image: CIImage, amount: Int) -> CIImage { apply(image, amount: amount, mode: 2) }
    public static func dehaze(_ image: CIImage, amount: Int) -> CIImage {
        guard amount != 0, !image.extent.isEmpty, !image.extent.isInfinite, let hazeKernel else { return image }
        let minimum = image.applyingFilter("CIMinimumComponent")
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 6])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7])
            .cropped(to: image.extent)
        return hazeKernel.apply(extent: image.extent,
            arguments: [image, minimum, Float(max(-100, min(100, amount))) / 100]) ?? image
    }

    public static func texture(_ image: CIImage, amount: Int) -> CIImage {
        guard amount != 0, !image.extent.isEmpty, !image.extent.isInfinite, let detailKernel else { return image }
        let low = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0]).cropped(to: image.extent)
        return detailKernel.apply(extent: image.extent, arguments: [image, low, Float(max(-100, min(100, amount))) / 100]) ?? image
    }
}
