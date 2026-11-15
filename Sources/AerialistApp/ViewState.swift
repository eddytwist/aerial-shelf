import SwiftUI

/// SwiftUI's `State` property wrapper under another name.
///
/// In the macOS 27 SDK `@State` resolves to a macro whose implementation ships only with Xcode.
/// The app builds with the Command Line Tools alone, so views use the property wrapper type directly.
typealias ViewState<Value> = SwiftUI.State<Value>
