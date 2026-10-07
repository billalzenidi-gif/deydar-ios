// Position GPS pour le site, via CoreLocation : une seule demande d'autorisation (celle d'iOS), délais et
// « maximumAge » respectés, suivi continu (watchPosition) arrêté dès qu'il n'est plus demandé.
import CoreLocation

final class LocationBridge: NSObject, CLLocationManagerDelegate {
    enum Failure {
        case denied, unavailable, timeout
        var code: Int { switch self { case .denied: return 1; case .unavailable: return 2; case .timeout: return 3 } }
    }

    /// Réponse au site : (identifiant de la demande, position, erreur).
    var deliver: ((Int, CLLocation?, Failure?) -> Void)?
    /// « granted », « denied » ou « prompt » : état de l'autorisation, renvoyé au site à chaque changement.
    var onAuthorizationChange: ((String) -> Void)?

    private let manager = CLLocationManager()
    private var once: [Int: DispatchWorkItem] = [:]
    private var watchers = Set<Int>()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var state: String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "granted"
        case .denied, .restricted: return "denied"
        default: return "prompt"
        }
    }

    func request(id: Int, watch: Bool, highAccuracy: Bool, timeoutMs: Int, maximumAgeMs: Int) {
        manager.desiredAccuracy = highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        if watch {
            watchers.insert(id)
        } else {
            if maximumAgeMs > 0, state == "granted", let last = manager.location,
               -last.timestamp.timeIntervalSinceNow * 1000 <= Double(maximumAgeMs) {
                deliver?(id, last, nil)
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.once.removeValue(forKey: id) != nil else { return }
                self.deliver?(id, nil, .timeout)
                self.stopIfIdle()
            }
            once[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(1000, timeoutMs)), execute: work)
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: failAll(.denied)
        default: start()
        }
    }

    func clear(id: Int) {
        watchers.remove(id)
        stopIfIdle()
    }

    private func start() {
        if watchers.isEmpty { manager.requestLocation() } else { manager.startUpdatingLocation() }
    }

    private func stopIfIdle() {
        if watchers.isEmpty { manager.stopUpdatingLocation() }
    }

    private func failAll(_ failure: Failure) {
        for (id, work) in once { work.cancel(); deliver?(id, nil, failure) }
        once.removeAll()
        for id in watchers { deliver?(id, nil, failure) }
        if failure == .denied { watchers.removeAll(); manager.stopUpdatingLocation() }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(state)
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !once.isEmpty || !watchers.isEmpty { start() }
        case .denied, .restricted:
            failAll(.denied)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        for (id, work) in once { work.cancel(); deliver?(id, location, nil) }
        once.removeAll()
        for id in watchers { deliver?(id, location, nil) }
        stopIfIdle()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError {
            if clError.code == .denied { failAll(.denied); return }
            // Position pas encore connue : pour un suivi continu, CoreLocation réessaie tout seul.
            if clError.code == .locationUnknown, once.isEmpty { return }
        }
        for (id, work) in once { work.cancel(); deliver?(id, nil, .unavailable) }
        once.removeAll()
    }
}
