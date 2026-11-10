import AppCore
import SwiftUI

struct AutomaticTripStartsPicker: View {
    @Environment(MileageAppModel.self) private var model

    var body: some View {
        Picker("Start Trips With", selection: Binding(
            get: { model.automaticTripStartMode },
            set: { _ = model.setAutomaticTripStartMode($0) }
        )) {
            Text("Motion").tag(AutomaticTripStartMode.motionDetection)
            Text("Bluetooth").tag(AutomaticTripStartMode.bluetoothOrCarPlay)
            Text("Both").tag(AutomaticTripStartMode.both)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Text("Start Trips With"))
        .accessibilityIdentifier("settingsAutomaticTripStartsPicker")
    }
}
