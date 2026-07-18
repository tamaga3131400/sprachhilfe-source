import Foundation
import SprachhilfePluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sprachhilfe", category: "EventBus")

@MainActor
final class EventBus: EventBusProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var shared: EventBus!

    private struct Subscription: Sendable {
        let id: UUID
        let handler: @Sendable (SprachhilfeEvent) async -> Void
    }

    private var subscriptions: [Subscription] = []

    @discardableResult
    nonisolated func subscribe(handler: @escaping @Sendable (SprachhilfeEvent) async -> Void) -> UUID {
        let id = UUID()
        let subscription = Subscription(id: id, handler: handler)
        DispatchQueue.main.async {
            self.subscriptions.append(subscription)
        }
        return id
    }

    nonisolated func unsubscribe(id: UUID) {
        DispatchQueue.main.async {
            self.subscriptions.removeAll { $0.id == id }
        }
    }

    func emit(_ event: SprachhilfeEvent) {
        let handlers = subscriptions.map { $0.handler }
        for handler in handlers {
            Task.detached {
                await handler(event)
            }
        }
        logger.debug("Emitted event to \(handlers.count) subscriber(s)")
    }
}
