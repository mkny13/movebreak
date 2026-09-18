import Foundation

enum RoutineOfferState {
    case generated(Routine)
    case local(routines: [Routine], label: String)
    case empty(message: String)
    case error(message: String, fallback: [Routine], fallbackLabel: String)
}

/// Fetches only on an explicit prompt/manual invocation. A generation token plus transport
/// cancellation prevents a dismissed or superseded request from delivering stale UI state.
final class GroundworkRoutineProvider {
    typealias ClientFactory = () throws -> GroundworkClient?

    private let cache: GroundworkRoutineCache
    private let clientFactory: ClientFactory
    private var request: GroundworkRequestCancellation?
    private var generation = UUID()

    init(
        cache: GroundworkRoutineCache = GroundworkRoutineCache(),
        clientFactory: @escaping ClientFactory = { try GroundworkClient.configured() }
    ) {
        self.cache = cache
        self.clientFactory = clientFactory
    }

    @discardableResult
    func requestOffer(
        localRoutines: [Routine],
        completion: @escaping (UUID, RoutineOfferState) -> Void
    ) -> UUID {
        cancel()
        let token = UUID()
        generation = token
        let locationID = Preferences.groundworkLocationID ?? ""
        let duration = Preferences.groundworkDurationMinutes

        let client: GroundworkClient?
        do {
            client = try clientFactory()
        } catch {
            deliver(
                token: token,
                state: .error(
                    message: "Groundwork configuration could not be read.",
                    fallback: localRoutines,
                    fallbackLabel: "Local fallback — not clinically revalidated"
                ),
                completion: completion
            )
            return token
        }

        guard let client, let origin = GroundworkOrigin(url: client.baseURL), !locationID.isEmpty else {
            let state = cache.resolve(
                result: nil,
                origin: nil,
                locationID: locationID,
                durationMinutes: duration,
                localRoutines: localRoutines
            )
            deliver(token: token, state: offer(from: state, localRoutines: localRoutines), completion: completion)
            return token
        }

        request = client.fetchRoutine(locationID: locationID, durationMinutes: duration) { [weak self] result in
            guard let self else { return }
            let availability = self.cache.resolve(
                result: result,
                origin: origin,
                locationID: locationID,
                durationMinutes: duration,
                localRoutines: localRoutines
            )
            self.deliver(
                token: token,
                state: self.offer(from: availability, localRoutines: localRoutines),
                completion: completion
            )
        }
        return token
    }

    func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
    }

    private func deliver(
        token: UUID,
        state: RoutineOfferState,
        completion: @escaping (UUID, RoutineOfferState) -> Void
    ) {
        onMain { [weak self] in
            guard let self, self.generation == token else { return }
            self.request = nil
            completion(token, state)
        }
    }

    private func offer(from availability: GroundworkRoutineAvailability, localRoutines: [Routine]) -> RoutineOfferState {
        switch availability {
        case .unconfigured(let routines, let label), .bundledDefaults(let routines, let label):
            return .local(routines: routines, label: label)
        case .live(let response):
            guard let generated = response.routine else {
                return .empty(message: "Groundwork did not offer a routine for this break.")
            }
            return .generated(Routine(
                generated: generated,
                provenance: .live,
                sourceLabel: "Generated now by Groundwork"
            ))
        case .validEmpty:
            return .empty(message: "Groundwork did not offer a routine for this break.")
        case .authFailed:
            return .error(
                message: "Groundwork authentication failed.",
                fallback: localRoutines,
                fallbackLabel: "Local fallback — not clinically revalidated"
            )
        case .unavailable(let cached):
            if let cached, let generated = cached.response.routine {
                return .generated(Routine(generated: generated, provenance: .cached, sourceLabel: cached.label))
            }
            return .error(
                message: "Groundwork is unavailable.",
                fallback: localRoutines,
                fallbackLabel: "Local fallback — not clinically revalidated"
            )
        case .malformed(let cached):
            if let cached, let generated = cached.response.routine {
                return .generated(Routine(generated: generated, provenance: .cached, sourceLabel: cached.label))
            }
            return .error(
                message: "Groundwork returned an unreadable routine.",
                fallback: localRoutines,
                fallbackLabel: "Local fallback — not clinically revalidated"
            )
        }
    }
}
