import SwiftUI

/// The content of the menu bar popover: device list, status, refresh, quit.
struct MenuContent: View {
    @ObservedObject var controller: SonosController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            bodyContent
            Divider()
            footer
        }
        .frame(width: 280)
        .padding(12)
        .task {
            // Refresh once when the popover first opens.
            if controller.devices.isEmpty && !controller.isLoading {
                await controller.refresh()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Text("🦕")
                .font(.title2)
            Text("Sonosaur")
                .font(.headline)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if controller.isLoading {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Sniffing the swamp…")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .padding(.vertical, 12)
        } else if let error = controller.errorMessage {
            Text(error)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .padding(.vertical, 12)
        } else if controller.devices.isEmpty {
            Text("No devices yet — hit Refresh.")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .padding(.vertical, 12)
        } else {
            ForEach(controller.devices) { device in
                DeviceRow(device: device, controller: controller)
                if device.id != controller.devices.last?.id {
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                Task { await controller.refresh() }
            }
            .disabled(controller.isLoading)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.top, 8)
        .font(.subheadline)
    }
}
