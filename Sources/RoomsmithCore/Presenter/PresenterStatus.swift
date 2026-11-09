import Foundation

// Presenter mode: user-visible state and its transitions. Pure; the engine feeds it events.

public enum PresenterFailure: Sendable, Equatable {
    case localNetworkDenied
    case noNetworkInterface
    case serverFailed(String)
    case encoderFailed(String)
    case playerFailed(String)
    case displayRemoved
    /// The listener died after it was ready (e.g. the network interface went away).
    case serverStopped

    public var message: String {
        switch self {
        case .localNetworkDenied:
            "Local network access denied – allow Roomsmith in System Settings › Privacy & Security › Local Network"
        case .noNetworkInterface:
            "No local network found – connect this Mac to the same Wi-Fi or Ethernet network as the Apple TV"
        case .serverFailed(let d):
            "Could not start the stream server: \(d)"
        case .encoderFailed(let d):
            "Video encoding failed: \(d)"
        case .playerFailed(let d):
            "Playback failed: \(d)"
        case .displayRemoved:
            "The presenter display was disconnected"
        case .serverStopped:
            "Stream server stopped – network changed?"
        }
    }
}

public enum PresenterState: Sendable, Equatable {
    case idle
    case starting
    /// Streaming and playing on this Mac; `latencyEstimate` in seconds.
    case live(latencyEstimate: Double)
    /// An AirPlay route plays the stream.
    case external(routeName: String)
    case stopping
    case failed(String)
}

public enum PresenterEvent: Sendable, Equatable {
    case startRequested
    /// Encoder and server run and the player has the stream.
    case ready(latencyEstimate: Double)
    case latencyUpdated(Double)
    case externalPlaybackChanged(active: Bool, routeName: String?)
    case stopRequested
    case stopped
    case failure(PresenterFailure)
}

public struct PresenterStatus: Sendable, Equatable {
    public private(set) var state: PresenterState = .idle
    /// Last known latency, kept while an AirPlay route is active.
    public private(set) var lastLatency: Double = 0

    public init() {}

    public var isActive: Bool {
        switch state {
        case .idle, .failed: false
        default: true
        }
    }

    /// Applies an event; returns false if it does not fit the current state (state unchanged).
    @discardableResult
    public mutating func apply(_ event: PresenterEvent) -> Bool {
        switch (state, event) {
        case (.idle, .startRequested), (.failed, .startRequested):
            state = .starting
        case (.starting, .ready(let l)):
            lastLatency = l
            state = .live(latencyEstimate: l)
        case (.starting, .externalPlaybackChanged(true, let name)), (.live, .externalPlaybackChanged(true, let name)):
            state = .external(routeName: name ?? "AirPlay")
        case (.external, .externalPlaybackChanged(true, let name)):
            state = .external(routeName: name ?? "AirPlay")
        case (.external, .externalPlaybackChanged(false, _)):
            state = .live(latencyEstimate: lastLatency)
        case (.live, .latencyUpdated(let l)):
            lastLatency = l
            state = .live(latencyEstimate: l)
        case (.external, .latencyUpdated(let l)):
            lastLatency = l
        case (.starting, .stopRequested), (.live, .stopRequested), (.external, .stopRequested):
            state = .stopping
        case (.stopping, .stopped), (.starting, .stopped), (.live, .stopped), (.external, .stopped):
            state = .idle
        case (.idle, .stopRequested), (.idle, .stopped), (.failed, .stopRequested), (.failed, .stopped):
            return false
        case (.stopping, .failure):
            state = .idle   // already on the way down; the failure no longer matters
        case (_, .failure(let f)):
            state = .failed(f.message)
        default:
            return false
        }
        return true
    }

    /// One line for the panel.
    public var line: String {
        switch state {
        case .idle: "Not presenting"
        case .starting: "Starting…"
        case .live(let l): l > 0 ? String(format: "Live preview on this Mac (about %.1f s delay)", l) : "Live preview on this Mac"
        case .external(let r): "Playing on \(r)"
        case .stopping: "Stopping…"
        case .failed(let m): m
        }
    }
}
