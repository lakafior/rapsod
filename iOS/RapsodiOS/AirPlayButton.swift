// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import SwiftUI

/// Systemowy przycisk wyboru wyjścia dźwięku (AirPlay, słuchawki Bluetooth, głośnik telefonu).
/// SwiftUI nie ma własnego odpowiednika, więc to cienka osłona `AVRoutePickerView`; listę
/// urządzeń i samo przełączenie obsługuje system.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        view.activeTintColor = .tintColor
        view.isAccessibilityElement = true
        view.accessibilityLabel = "AirPlay i wyjście dźwięku"
        view.accessibilityTraits = .button
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
