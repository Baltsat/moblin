import CoreBluetooth

let bluetoothNotAllowedMessage = "⚠️ Days is not allowed to use Bluetooth"

extension Model: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_: CBCentralManager) {
        bluetoothAllowed = CBCentralManager.authorization == .allowedAlways
    }
}
