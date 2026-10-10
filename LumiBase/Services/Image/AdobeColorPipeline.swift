import Foundation
import CoreImage
import AppKit

/// Adobe Lightroom PV2012 Color Pipeline for 1:1 color and tone rendering
public final class AdobeColorPipeline: Sendable {
    public static let shared = AdobeColorPipeline()
    
    private let dcpManager = DCPProfileManager.shared
    
    public init() {}
    
    /// Processes a raw CIImage through the calibrated Adobe Camera Raw emulation pipeline
    public func process(
        image: CIImage,
        cameraModel: String?,
        xmp: XMPMetadata?,
        baseHolder: BaseImageHolder? = nil
    ) -> CIImage {
        guard let xmp = xmp else {
            return image
        }
        
        let isRaw = baseHolder?.isRaw ?? false
        let hasDevelopEdits = xmp.hasDevelopEdits
        
        // If non-raw without develop edits, passthrough untouched
        if !isRaw && !hasDevelopEdits {
            return image
        }
        
        var current = image
        
        // 1. Exposure Compensation (EV Delta)
        // If RAW demosaicing already applied native EV, only apply the live delta
        let targetEV = xmp.exposure2012 ?? 0.0
        let baseEV = Double(baseHolder?.baseExposure ?? 0.0)
        let deltaEV = targetEV - baseEV
        if abs(deltaEV) > 0.01 {
            current = current.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: deltaEV
            ])
        }
        
        // 2. White Balance / Kelvin Temperature & Tint Delta
        if isRaw, let cameraTemp = baseHolder?.baseTemperature {
            let targetTemp = Float(xmp.temperature ?? Int(cameraTemp))
            let cameraTint = baseHolder?.baseTint ?? 0.0
            let targetTint = Float(xmp.tint ?? Int(cameraTint))
            let deltaTemp = Double(targetTemp - cameraTemp)
            let deltaTint = Double(targetTint - cameraTint)
            
            if abs(deltaTemp) > 10.0 || abs(deltaTint) > 0.5 {
                // Adobe Planckian chromaticity calibration
                let rGain = max(0.4, min(2.5, 1.0 + (deltaTemp / 1000.0) * 0.155))
                let bGain = max(0.4, min(2.5, 1.0 - (deltaTemp / 1000.0) * 0.145))
                let gGain = max(0.4, min(2.5, 1.0 - (deltaTint / 100.0) * 0.15))
                current = current.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: rGain, y: 0.0, z: 0.0, w: 0.0),
                    "inputGVector": CIVector(x: 0.0, y: gGain, z: 0.0, w: 0.0),
                    "inputBVector": CIVector(x: 0.0, y: 0.0, z: bGain, w: 0.0),
                    "inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
                ])
            }
        } else if let temp = xmp.temperature, temp > 0 {
            let tint = CGFloat(xmp.tint ?? 0)
            let deltaTemp = CGFloat(temp - 5500) * 0.65
            let deltaTint = tint * 0.50
            if abs(deltaTemp) > 25 || abs(deltaTint) > 1.0 {
                current = current.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 5500.0 + deltaTemp, y: deltaTint),
                    "inputTargetNeutral": CIVector(x: 5500.0, y: 0.0)
                ])
            }
        }
        
        // 3. Contrast & Dehaze Contrast (Lightroom PV2012 midtone punch)
        let dehaze = Double(xmp.dehaze ?? 0)
        let contrastVal = Double(xmp.contrast2012 ?? 0) + (dehaze * 0.40)
        if contrastVal != 0 {
            let contrastFactor = max(0.6, min(1.6, 1.0 + (contrastVal / 100.0 * 0.20)))
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrastFactor
            ])
        }
        
        // 4. Black & White or Vibrance and Saturation (Color enrichment before tone luminosity mapping)
        let isBW = (xmp.convertToGrayscale == true) || (xmp.saturation == -100)
        let hl = Double(xmp.highlights2012 ?? 0)
        let hlFactor = hl / 100.0
        // Natural highlight desaturation: in Adobe PV2012, positive highlights roll off gently towards specular white
        let hlDesatScale = hlFactor > 0 ? max(0.80, 1.0 - (hlFactor * 0.20)) : 1.0
        
        if isBW {
            current = current.applyingFilter("CIPhotoEffectMono")
        } else {
            let vib = Double(xmp.vibrance ?? 0)
            let totalVib = ((vib / 100.0 * 0.80) + (dehaze / 100.0 * 0.20)) * hlDesatScale
            if abs(totalVib) > 0.01 {
                current = current.applyingFilter("CIVibrance", parameters: [
                    "inputAmount": totalVib
                ])
            }
            
            // Saturation (-100 = 0.0 / Mono, 0 = 1.0 / Neutral, +100 = 2.0 / Vivid)
            let sat = Double(xmp.saturation ?? 0)
            let dehazeSatBoost = dehaze / 100.0 * 0.10
            let rawSat = 1.0 + (((sat / 100.0 * 0.40) + dehazeSatBoost) * hlDesatScale)
            let saturationFactor = max(0.0, min(2.0, rawSat))
            if abs(saturationFactor - 1.0) > 0.005 {
                current = current.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: saturationFactor
                ])
            }
        }
        
        // 5. PV2012 Basic Tone Curve (Highlights, Shadows, Whites, Blacks)
        let sh = Double(xmp.shadows2012 ?? 0)
        let whites = Double(xmp.whites2012 ?? 0)
        let blacks = Double(xmp.blacks2012 ?? 0)
        let shFactor = sh / 100.0
        let wFactor = whites / 100.0
        let bFactor = blacks / 100.0
        
        let isRawImage = baseHolder?.isRaw ?? false
        let isAdvancedRaw = isRawImage && NativeHighlightsService.isAdvancedEnabled(for: xmp)
        
        let hasToneEdits = (hl != 0) || (sh != 0) || (whites != 0) || (blacks != 0) || (dehaze != 0)
        if hasToneEdits {
            // For RAW files with Advanced RAW Highlight Recovery enabled, preserve calibrated weights for AcceptedHighlightsKernel parity;
            // for standard pipeline (RAW without Advanced Recovery or non-RAW files), apply full PV2012 highlight rolloff.
            let hlP1: Double
            let hlP2: Double
            let hlP3: Double
            let hlP4: Double
            
            if isAdvancedRaw {
                hlP1 = 0.0
                hlP2 = hlFactor * 0.08
                hlP3 = hlFactor * 0.08
                hlP4 = 0.0
            } else {
                if hlFactor < 0 {
                    // Highlights -100 rolls off the shoulder (p3) to recover cloud details,
                    // while preserving the White Point (p4 = 1.0) and midtones (p2 = 0.50),
                    // exactly matching Lightroom and Lightcraft!
                    hlP1 = 0.0
                    hlP2 = 0.0
                    hlP3 = hlFactor * 0.10
                    hlP4 = 0.0
                } else {
                    hlP1 = 0.0
                    hlP2 = 0.0
                    hlP3 = hlFactor * 0.12
                    hlP4 = 0.0
                }
            }

            let p0Y = max(0.0, min(0.04, 0.0 + (bFactor * 0.01)))
            let p1Y = max(0.12, min(0.35, 0.24 + hlP1 + (shFactor * 0.06) + (bFactor * 0.20)))
            let p2Y = max(0.40, min(0.65, 0.50 + hlP2 + (shFactor * 0.03)))
            let p3Y = isAdvancedRaw
                ? max(0.60, min(0.90, 0.75 + hlP3 + (wFactor * 0.06)))
                : max(0.55, min(0.90, 0.75 + hlP3 + (wFactor * 0.06)))
            let p4Y = max(0.92, min(1.0, 1.0 + (wFactor * 0.03) + hlP4))
            
            current = current.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p0Y),
                "inputPoint1": CIVector(x: 0.25, y: p1Y),
                "inputPoint2": CIVector(x: 0.50, y: p2Y),
                "inputPoint3": CIVector(x: 0.75, y: p3Y),
                "inputPoint4": CIVector(x: 1.0, y: p4Y)
            ])
            
            // 5b. Lightcraft-inspired Highlight Roll-off & Specular Desaturation
            // Replaces halo-inducing unsharp masks with a continuous, edge-preserving Hermite
            // shoulder curve that preserves cloud 3D volume, hue constancy, and natural specular desaturation.
            let hasHLAdjustment = (hl != 0)
            let hasExposureBoost = (xmp.exposure2012 ?? 0) > 0 || (xmp.whites2012 ?? 0) > 0
            if !isAdvancedRaw && (hasHLAdjustment || hasExposureBoost) {
                current = HighlightRollOffKernel.shared.apply(image: current, hlFactor: Float(hlFactor))
            }
        }

        
        // 7. Texture (Fine Detail: >0 Sharpen, <0 Skin Soften)
        if let texture = xmp.texture, texture != 0 {
            if texture > 0 {
                let texIntensity = min(1.0, Double(texture) / 100.0 * 0.8)
                current = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 1.2,
                    kCIInputIntensityKey: texIntensity
                ])
            } else {
                let softenFactor = Double(abs(texture)) / 100.0 * 0.45
                let blurred = current.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 1.5
                ]).cropped(to: current.extent)
                current = current.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred,
                    "inputTime": softenFactor
                ])
            }
        }
        
        // 8. Clarity (Midtone Local Contrast: >0 Punch, <0 Dreamy Glow)
        if let clarity = xmp.clarity2012, clarity != 0 {
            if clarity > 0 {
                let clarIntensity = min(0.8, Double(clarity) / 100.0 * 0.6)
                current = current.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 12.0,
                    kCIInputIntensityKey: clarIntensity
                ])
            } else {
                let glowFactor = Double(abs(clarity)) / 100.0 * 0.40
                let blurred = current.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 10.0
                ]).cropped(to: current.extent)
                current = current.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred,
                    "inputTime": glowFactor
                ])
            }
        }
        
        // 9. Crop and Straighten (Rotation & Crop Box)
        if xmp.hasCrop {
            let extent = current.extent
            if !extent.isEmpty && extent.width > 0 && extent.height > 0 {
                // 9a. Angle / Straighten Rotation around image center
                let angleDeg = xmp.cropAngle ?? 0.0
                if abs(angleDeg) > 0.01 {
                    let radians = CGFloat(-angleDeg * .pi / 180.0)
                    let centerX = extent.midX
                    let centerY = extent.midY
                    
                    var transform = CGAffineTransform(translationX: centerX, y: centerY)
                    transform = transform.rotated(by: radians)
                    transform = transform.translatedBy(x: -centerX, y: -centerY)
                    
                    current = current.transformed(by: transform)
                }
                
                // 9b. Bounding Crop Box (normalized coordinates [0, 1])
                let top = CGFloat(xmp.cropTop ?? 0.0)
                let left = CGFloat(xmp.cropLeft ?? 0.0)
                let bottom = CGFloat(xmp.cropBottom ?? 1.0)
                let right = CGFloat(xmp.cropRight ?? 1.0)
                
                if top > 0.001 || left > 0.001 || bottom < 0.999 || right < 0.999 {
                    let cropX = extent.origin.x + (left * extent.width)
                    let cropY = extent.origin.y + ((1.0 - bottom) * extent.height)
                    let cropW = max(1.0, (right - left) * extent.width)
                    let cropH = max(1.0, (bottom - top) * extent.height)
                    let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                    current = current.cropped(to: cropRect)
                }
            }
        }
        
        return current
    }
}

/// Lightcraft-inspired highlight roll-off and specular desaturation kernel.
/// Replaces halo-prone unsharp masks with continuous, edge-preserving Hermite shoulder scaling
/// and specular highlight desaturation to prevent harsh channel clipping artifacts.
public final class HighlightRollOffKernel: @unchecked Sendable {
    public static let shared = HighlightRollOffKernel()
    
    private let kernel: CIColorKernel?
    
    public init() {
        self.kernel = CIColorKernel(source: """
            kernel vec4 highlightRollOff(__sample src, float hlFactor) {
                vec3 c = clamp(src.rgb, 0.0, 4.0);
                float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
                
                // 1. Proportional highlight attenuation / recovery (Hue-Preserving)
                // In Lightcraft, local highlights are scaled proportionally on RGB based on
                // a smooth Hermite shoulder curve, preventing the color/hue distortions of 1D curves.
                // Midtones (y <= 0.55) are preserved; highlight zone (y > 0.55) rolls off smoothly.
                float gain = 1.0;
                if (hlFactor < 0.0) {
                    // Negative highlights: Smooth Hermite shoulder compression
                    // Targets the 0.60~0.92 highlight band while preserving specular highlights (1.0)
                    float w = clamp((y - 0.55) / (0.95 - 0.55), 0.0, 1.0);
                    float smoothW = w * w * (3.0 - 2.0 * w);
                    // Taper down near 1.0 so specular white reflections and sun stay brilliant
                    float specularTaper = 1.0 - smoothstep(0.88, 1.0, y) * 0.55;
                    gain = 1.0 + hlFactor * 0.25 * smoothW * specularTaper;
                } else if (hlFactor > 0.0) {
                    // Positive highlights: smooth specular roll-off
                    float w = clamp((y - 0.55) / (1.0 - 0.55), 0.0, 1.0);
                    float smoothW = w * w * (3.0 - 2.0 * w);
                    gain = 1.0 + hlFactor * 0.18 * smoothW;
                }
                vec3 adjusted = c * max(0.0, gain);
                
                // 2. Lightcraft-inspired Specular Highlight Desaturation
                // In Lightcraft (finish.wgsl: if (mx > 1.0)), desaturation only applies to
                // genuinely clipping channels. Saturated blue sky (mx = 0.85~0.95) is NEVER desaturated!
                float mx = max(adjusted.r, max(adjusted.g, adjusted.b));
                if (mx > 0.985) {
                    float t = clamp((mx - 0.985) / 0.015, 0.0, 1.0);
                    float adjY = dot(adjusted, vec3(0.2126, 0.7152, 0.0722));
                    adjusted = mix(adjusted, vec3(adjY), t * 0.75);
                }
                
                return vec4(clamp(adjusted, 0.0, 1.0), src.a);
            }
        """)
    }
    
    public func apply(image: CIImage, hlFactor: Float, enableSpecularRollOff: Bool = true) -> CIImage {
        guard let kernel = kernel else { return image }
        if hlFactor == 0 && !enableSpecularRollOff { return image }
        return kernel.apply(extent: image.extent, arguments: [image, hlFactor]) ?? image
    }
}
