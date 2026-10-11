import AppKit
import CoreImage
import Foundation

/// Optical Exposure Kernel with Lightcraft-grade Reinhard Shoulder and Specular Highlight Bleaching.
///
/// In physical photography (and Lightcraft), exposure is a uniform radiance gain (2^EV) in scene space.
/// Applying a raw linear multiplier (like CIExposureAdjust) to a display-referred or tone-curved image
/// blows highlights into clipping while leaving shadows underdeveloped.
///
/// OpticalExposureKernel applies:
/// 1. Full optical photon gain (2^EV) in shadows and midtones.
/// 2. Smooth Reinhard asymptotic shoulder compression in highlights (H(y) = y / (2^-EV + (1 - 2^-EV)*y)),
///    anchoring pure white at exactly 1.0 and preserving fine cloud/skin gradients.
/// 3. Specular highlight desaturation to prevent hue clipping at the white point.
public enum OpticalExposureKernel {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 opticalExposure(__sample s, float ev, float whites) {
            vec3 c = max(s.rgb, vec3(0.0));
            
            // Bypass if EV is zero
            if (abs(ev) < 0.001) {
                return s;
            }
            
            float gain = pow(2.0, ev);
            float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
            
            if (ev > 0.0) {
                // Adaptive shoulder parameter: alpha = 1.0 - 2^(-ev)
                // At ev = 0, alpha = 0 (identity). As ev increases, alpha approaches 1.0.
                // Whites slider modulates the shoulder hardness (+whites lifts shoulder, -whites deepens headroom).
                float wFactor = clamp(whites / 100.0, -1.0, 1.0);
                float alphaMod = 1.0 - 0.25 * wFactor;
                float invGain = pow(2.0, -ev);
                float alpha = max(0.0, (1.0 - invGain) * alphaMod);
                
                // Optical Reinhard shoulder response:
                // y_target = y / (invGain + alpha * y)
                // When y -> 0 (shadows): dy_target/dy = 1/invGain = 2^ev (Full optical gain!)
                // When y -> 1 (highlights): y_target smoothly approaches 1.0 without clipping!
                float denom = max(invGain + alpha * y, 1e-6);
                float yTarget = min(y / denom, 1.0);
                
                // Apply luminance scale to RGB channels
                float scale = yTarget / y;
                vec3 toned = c * scale;
                
                // Specular highlight desaturation & gamut map (Lightcraft camera highlight bleaching):
                // Highly saturated channels approaching 1.0 naturally bleach toward white
                // rather than distorting hue into neon artifacts.
                float mx = max(toned.r, max(toned.g, toned.b));
                if (mx > 1.0) {
                    float t = clamp((mx - 1.0) / max(mx - yTarget, 1e-6), 0.0, 1.0);
                    toned = mix(toned, vec3(yTarget), t);
                }
                
                return vec4(clamp(toned, 0.0, 1.0), s.a);
            } else {
                // Negative exposure: smooth linear optical pulldown
                vec3 toned = c * gain;
                return vec4(max(toned, vec3(0.0)), s.a);
            }
        }
    """)

    /// Applies optical exposure compensation with Reinhard highlight shoulder protection.
    /// - Parameters:
    ///   - image: Input CIImage.
    ///   - ev: Exposure compensation in EV stops (e.g. +1.0, -0.5).
    ///   - whites: Whites slider adjustment in range [-100, 100], default 0.
    /// - Returns: Processed CIImage with optical exposure applied.
    public static func apply(image: CIImage, ev: Float, whites: Float = 0.0) -> CIImage {
        guard let kernel, !image.extent.isInfinite, abs(ev) > 0.001 else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, ev, whites]) ?? image
    }
}
