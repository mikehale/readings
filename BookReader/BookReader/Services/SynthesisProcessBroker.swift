import Foundation

enum SynthesisPhase: Equatable {
    case idle
    case preparing
    case running
    case stopping
    case cancelled
    case completed
    case failed

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .running: return "Synthesizing"
        case .stopping: return "Stopping"
        case .cancelled: return "Cancelled"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .running, .stopping: return true
        default: return false
        }
    }
}

enum SynthesisCancelError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        "Synthesis stopped."
    }
}

/// Tracks the in-flight CLI process so Stop can terminate edge-tts / XTTS.
final class SynthesisProcessBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    func beginJob() {
        lock.lock()
        cancelRequested = false
        process = nil
        lock.unlock()
    }

    func register(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelRequested {
            process.terminate()
            throw SynthesisCancelError.cancelled
        }
        self.process = process
    }

    func unregister(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process {
            self.process = nil
        }
    }

    /// Terminate the running CLI (and escalate to SIGKILL if needed).
    func cancel() {
        lock.lock()
        cancelRequested = true
        let running = process
        lock.unlock()

        guard let running else { return }
        if running.isRunning {
            running.terminate()
        }
        let pid = running.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if running.isRunning {
                running.interrupt()
                kill(pid, SIGKILL)
            }
        }
    }

    func throwIfCancelled() throws {
        lock.lock()
        let cancelled = cancelRequested
        lock.unlock()
        if cancelled { throw SynthesisCancelError.cancelled }
    }
}
