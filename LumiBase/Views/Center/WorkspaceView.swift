import SwiftUI

/// Center workspace hosting either the GridView or LoupeView
public struct WorkspaceView: View {
    @ObservedObject var appState: AppState
    
    public var body: some View {
        VStack(spacing: 0) {
            // Top Filter Bar
            TopFilterBarView(appState: appState)
            
            Divider().background(LightroomTheme.dividerColor)
            
            // Center View (Grid or Loupe)
            Group {
                switch appState.viewMode {
                case .grid:
                    GridView(appState: appState)
                case .loupe:
                    LoupeView(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PhotoKeyboardFocusSurface(appState: appState))
            
            Divider().background(LightroomTheme.dividerColor)
            
            // Bottom Controls Bar
            BottomControlsBarView(appState: appState)
        }
        .background(LightroomTheme.workspaceBackground)
    }
}

/// Non-hit-testing native bounds marker; never steals image gestures or text focus.
struct PhotoKeyboardFocusSurface: NSViewRepresentable {
    let appState: AppState
    final class Surface: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        appState.photoKeyboardSurfaces.add(view)
        return view
    }
    func updateNSView(_ view: Surface, context: Context) {}
}
