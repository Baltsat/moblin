import CoreLocation

/// user-req: place per scene at near-zero battery: a 100 m one-shot at take start and at most every 10 min after the
/// coarse (cell/Wi-Fi, no GPS) tracker reports a move; names are reverse-geocoded once per ~200 m cell.
@MainActor
final class DaysPlace: NSObject, CLLocationManagerDelegate {
    static let shared = DaysPlace()
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastFix: Date?
    private var lastCell: String?
    private var recording = false
    private let cacheKey = "daysPlaceNames"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func takeStarted() {
        recording = true
        lastFix = nil
        lastCell = nil
        manager.requestLocation()
    }

    func takeStopped() {
        recording = false
    }

    func moved(_ location: CLLocation) {
        guard recording, let lastFix, Date().timeIntervalSince(lastFix) > 600 else {
            return
        }
        self.lastFix = Date()
        manager.requestLocation()
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        Task { @MainActor in
            self.record(location)
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            daysLog("place fix failed \(error.localizedDescription)")
        }
    }

    private func cell(_ location: CLLocation) -> String {
        String(format: "%.3f,%.3f",
               (location.coordinate.latitude * 500).rounded() / 500,
               (location.coordinate.longitude * 500).rounded() / 500)
    }

    private func record(_ location: CLLocation) {
        guard recording, let model = MoblinApp.globalModel else {
            return
        }
        lastFix = Date()
        model.driveRecordLocation(location: location)
        let cell = cell(location)
        guard cell != lastCell else {
            return
        }
        lastCell = cell
        if let name = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String])?[cell] {
            emit(name, location)
            return
        }
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            let mark = placemarks?.first
            let name = mark?.areasOfInterest?.first ?? mark?.name ?? mark?.subLocality ?? mark?.locality
            Task { @MainActor in
                guard let name else {
                    return
                }
                var cache = UserDefaults.standard.dictionary(forKey: self.cacheKey) as? [String: String] ?? [:]
                cache[cell] = name
                UserDefaults.standard.set(cache, forKey: self.cacheKey)
                self.emit(name, location)
            }
        }
    }

    private func emit(_ name: String, _ location: CLLocation) {
        let values: [String: Any] = [
            "name": name,
            "lat": (location.coordinate.latitude * 1000).rounded() / 1000,
            "lon": (location.coordinate.longitude * 1000).rounded() / 1000,
            "acc": Int(location.horizontalAccuracy),
            "fix_ms": Int64(location.timestamp.timeIntervalSince1970 * 1000),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values) else {
            return
        }
        driveUploader.event(type: "place", detail: String(decoding: data, as: UTF8.self))
        daysLog("place \(name)")
    }
}
