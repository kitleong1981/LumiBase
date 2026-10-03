import Foundation

/// Comparison modes for Before / After inspection in Loupe View
public enum ComparisonMode: String, CaseIterable, Sendable {
    case off = "Off"
    case splitLeftRight = "Left / Right Split"
    case sideBySide = "Left / Right Side-by-Side"
    case splitTopBottom = "Top / Bottom Split"
    
    public var isSplit: Bool {
        self == .splitLeftRight || self == .splitTopBottom
    }
    
    public var isSideBySide: Bool {
        self == .sideBySide
    }
    
    public var isActive: Bool {
        self != .off
    }
    
    public var iconName: String {
        switch self {
        case .off: return "rectangle"
        case .splitLeftRight: return "rectangle.split.2x1"
        case .sideBySide: return "square.split.2x1"
        case .splitTopBottom: return "rectangle.split.1x2"
        }
    }
    
    public var displayName: String {
        switch self {
        case .off: return "Single Image (After)"
        case .splitLeftRight: return "Left / Right Split (Y)"
        case .sideBySide: return "Side-by-Side (⇧Y)"
        case .splitTopBottom: return "Top / Bottom Split"
        }
    }
}
