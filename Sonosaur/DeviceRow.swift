import SwiftUI

/// A single row in the popover: room name, volume percentage, and a slider.
struct DeviceRow: View {
    let device: SonosDevice
    @ObservedObject var controller: SonosController

    // Local copy so the slider binds without hitting the controller on every frame.
    @State private var localVolume: Double

    init(device: SonosDevice, controller: SonosController) {
        self.device = device
        self.controller = controller
        _localVolume = State(initialValue: device.volume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "hifispeaker.fill")
                    .foregroundStyle(.secondary)
                Text(device.roomName)
                    .font(.headline)
                Spacer()
                Text("\(Int(localVolume.rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            Slider(
                value: $localVolume,
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    if !editing {
                        controller.flushVolume(device: device, volume: localVolume)
                    }
                }
            )
            .tint(.accentColor)
        }
        .padding(.vertical, 4)
        // Sync localVolume if another path (e.g. refresh) updates the model.
        .onChange(of: device.volume) { newValue in
            localVolume = newValue
        }
        // Debounce SOAP calls while the slider is being dragged.
        .onChange(of: localVolume) { newValue in
            controller.setVolume(device: device, volume: newValue)
        }
    }
}
