import Foundation

/// Defines which develop settings to copy or synchronize between photos, matching Lightroom Classic's Sync / Copy Settings model.
public struct DevelopSyncOptions: Codable, Equatable, Sendable {
    // White Balance
    public var whiteBalance: Bool
    
    // Basic Tone
    public var exposure: Bool
    public var contrast: Bool
    public var highlights: Bool
    public var shadows: Bool
    public var whites: Bool
    public var blacks: Bool
    
    // Presence
    public var texture: Bool
    public var clarity: Bool
    public var dehaze: Bool
    public var vibrance: Bool
    public var saturation: Bool
    
    // Treatment & Profile
    public var cameraProfile: Bool
    public var treatment: Bool // ConvertToGrayscale / Black & White
    
    // Geometry
    public var crop: Bool
    public var lensCorrections: Bool
    
    public init(
        whiteBalance: Bool = true,
        exposure: Bool = true,
        contrast: Bool = true,
        highlights: Bool = true,
        shadows: Bool = true,
        whites: Bool = true,
        blacks: Bool = true,
        texture: Bool = true,
        clarity: Bool = true,
        dehaze: Bool = true,
        vibrance: Bool = true,
        saturation: Bool = true,
        cameraProfile: Bool = true,
        treatment: Bool = true,
        crop: Bool = false, // In Lightroom Classic, crop is unchecked by default
        lensCorrections: Bool = false
    ) {
        self.whiteBalance = whiteBalance
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.vibrance = vibrance
        self.saturation = saturation
        self.cameraProfile = cameraProfile
        self.treatment = treatment
        self.crop = crop
        self.lensCorrections = lensCorrections
    }
    
    // MARK: - Group Helpers
    
    public var allToneEnabled: Bool {
        exposure && contrast && highlights && shadows && whites && blacks
    }
    
    public var anyToneEnabled: Bool {
        exposure || contrast || highlights || shadows || whites || blacks
    }
    
    public mutating func setAllTone(_ enabled: Bool) {
        exposure = enabled
        contrast = enabled
        highlights = enabled
        shadows = enabled
        whites = enabled
        blacks = enabled
    }
    
    public var allPresenceEnabled: Bool {
        texture && clarity && dehaze && vibrance && saturation
    }
    
    public var anyPresenceEnabled: Bool {
        texture || clarity || dehaze || vibrance || saturation
    }
    
    public mutating func setAllPresence(_ enabled: Bool) {
        texture = enabled
        clarity = enabled
        dehaze = enabled
        vibrance = enabled
        saturation = enabled
    }
    
    public var hasAnySelected: Bool {
        whiteBalance || exposure || contrast || highlights || shadows || whites || blacks ||
        texture || clarity || dehaze || vibrance || saturation || cameraProfile || treatment || crop || lensCorrections
    }
    
    public mutating func checkAll(includeCrop: Bool = false) {
        whiteBalance = true
        setAllTone(true)
        setAllPresence(true)
        cameraProfile = true
        treatment = true
        crop = includeCrop
        lensCorrections = false
    }
    
    public mutating func checkNone() {
        whiteBalance = false
        setAllTone(false)
        setAllPresence(false)
        cameraProfile = false
        treatment = false
        crop = false
        lensCorrections = false
    }
    
    /// Preselects only the options that have actual non-default / non-nil adjustments in the source metadata
    public mutating func checkModified(from source: XMPMetadata) {
        whiteBalance = (source.temperature != nil && source.temperature != 0) || (source.tint != nil && source.tint != 0)
        exposure = (source.exposure2012 != nil && source.exposure2012 != 0.0)
        contrast = (source.contrast2012 != nil && source.contrast2012 != 0) || source.experimentalContrast
        highlights = (source.highlights2012 != nil && source.highlights2012 != 0) || source.advancedRAWHighlightRecovery == true
        shadows = (source.shadows2012 != nil && source.shadows2012 != 0) || source.experimentalShadows
        whites = (source.whites2012 != nil && source.whites2012 != 0) || source.experimentalWhites
        blacks = (source.blacks2012 != nil && source.blacks2012 != 0)
        
        texture = (source.texture != nil && source.texture != 0) || source.experimentalTexture
        clarity = (source.clarity2012 != nil && source.clarity2012 != 0)
        dehaze = (source.dehaze != nil && source.dehaze != 0) || source.experimentalDehaze
        vibrance = (source.vibrance != nil && source.vibrance != 0)
        saturation = (source.saturation != nil && source.saturation != 0)
        
        cameraProfile = (source.cameraProfile != nil)
        treatment = (source.convertToGrayscale != nil)
        crop = source.hasCrop
        lensCorrections = source.lensDistortion != nil || source.lensPurpleDefringe != nil ||
            source.lensGreenDefringe != nil || source.lensVignette != nil
    }
    
    // MARK: - Application Logic
    
    /// Copies selected fields from the source metadata to the target metadata
    public func apply(from source: XMPMetadata, to target: inout XMPMetadata) {
        if whiteBalance {
            target.temperature = source.temperature
            target.tint = source.tint
        }
        
        if exposure {
            target.exposure2012 = source.exposure2012
        }
        if contrast {
            target.contrast2012 = source.contrast2012
            target.experimentalContrast = source.experimentalContrast
        }
        if highlights {
            target.highlights2012 = source.highlights2012
            target.advancedRAWHighlightRecovery = source.advancedRAWHighlightRecovery
        }
        if shadows {
            target.shadows2012 = source.shadows2012
            target.experimentalShadows = source.experimentalShadows
        }
        if whites {
            target.whites2012 = source.whites2012
            target.experimentalWhites = source.experimentalWhites
        }
        if blacks {
            target.blacks2012 = source.blacks2012
        }
        
        if texture {
            target.texture = source.texture
            target.experimentalTexture = source.experimentalTexture
        }
        if clarity {
            target.clarity2012 = source.clarity2012
        }
        if dehaze {
            target.dehaze = source.dehaze
            target.experimentalDehaze = source.experimentalDehaze
        }
        if vibrance {
            target.vibrance = source.vibrance
        }
        if saturation {
            target.saturation = source.saturation
        }
        
        if cameraProfile {
            target.cameraProfile = source.cameraProfile
        }
        if treatment {
            target.convertToGrayscale = source.convertToGrayscale
        }
        
        if crop {
            target.hasCrop = source.hasCrop
            target.cropTop = source.cropTop
            target.cropLeft = source.cropLeft
            target.cropBottom = source.cropBottom
            target.cropRight = source.cropRight
            target.cropAngle = source.cropAngle
        }
        if lensCorrections {
            target.lensDistortion = source.lensDistortion
            target.lensPurpleDefringe = source.lensPurpleDefringe
            target.lensGreenDefringe = source.lensGreenDefringe
            target.lensVignette = source.lensVignette
        }
    }
    
    public static let `default` = DevelopSyncOptions()
}
