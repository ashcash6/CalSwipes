import CoreLocation
import Foundation

/// Detects the nearest Berkeley dining hall using a one-shot location fix.
/// Defaults to nil (caller uses Crossroads) when location is unavailable,
/// denied, or no hall is within the detection radius.
@MainActor
final class LocationService: NSObject {
    static let shared = LocationService()

    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<Hall?, Never>?

    private static let hallCoordinates: [(Hall, CLLocationCoordinate2D)] = [
        (.crossroads,   CLLocationCoordinate2D(latitude: 37.8688, longitude: -122.2593)),
        (.cafe3,        CLLocationCoordinate2D(latitude: 37.8730, longitude: -122.2574)),
        (.foothill,     CLLocationCoordinate2D(latitude: 37.8762, longitude: -122.2463)),
        (.clarkKerr,    CLLocationCoordinate2D(latitude: 37.8654, longitude: -122.2474)),
        (.goldenBear,   CLLocationCoordinate2D(latitude: 37.8698, longitude: -122.2598)),
        (.theDen,       CLLocationCoordinate2D(latitude: 37.8676, longitude: -122.2601)),
    ]
    private static let detectionRadius: CLLocationDistance = 350

    func nearestHall() async -> Hall? {
        await withTaskGroup(of: Hall?.self) { group in
            group.addTask { await self.locateHall() }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func locateHall() async -> Hall? {
        let mgr = CLLocationManager()
        manager = mgr
        let status = mgr.authorizationStatus
        guard status != .denied && status != .restricted else { return nil }

        return await withCheckedContinuation { cont in
            continuation = cont
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
            if status == .notDetermined {
                mgr.requestWhenInUseAuthorization()
            } else {
                mgr.requestLocation()
            }
        }
    }

    private static func closestHall(to location: CLLocation) -> Hall? {
        let closest = hallCoordinates.min {
            location.distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude)) <
            location.distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
        }
        guard let (hall, coord) = closest else { return nil }
        let dist = location.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        return dist <= detectionRadius ? hall : nil
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            let hall = LocationService.closestHall(to: location)
            self?.continuation?.resume(returning: hall)
            self?.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.continuation?.resume(returning: nil)
            self?.continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager?.requestLocation()
            } else if status == .denied || status == .restricted {
                self.continuation?.resume(returning: nil)
                self.continuation = nil
            }
        }
    }
}
