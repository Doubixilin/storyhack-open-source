import SwiftUI
import WorldbookUI

@main
struct WorldbookIOSApp: App {
  var body: some Scene {
    WindowGroup {
      WorldbookRootView(platform: .iOS)
    }
  }
}
