import Foundation

// StateEventHandler that maps configurable grid events to notifications.
// Registered with EventRouter; one instance handles all mapped event types.
// Deep module: callers provide a config, this hides all event-to-notification
// translation details.
class NotificationEventHandler: StateEventHandler {
    private let store: NotificationStore
    private let config: NotificationEventConfig

    init(store: NotificationStore, config: NotificationEventConfig) {
        self.store = store
        self.config = config
        // Register with EventRouter in a Task (matches FocusTracker/BorderEvents pattern)
        Task {
            await EventRouter.shared.register(self)
            JSONLogger.shared.log("notify.event.handler.init", data: [
                "rule_count": config.rules.count
            ])
        }
    }

    // MARK: - StateEventHandler

    func handle(_ event: StateEvent, context: EventContext) async throws {
        // Get the logInfo name for this event to look it up in the rules map
        let (eventName, _) = event.logInfo

        // Guard: skip if no rule for this event type
        guard let rule = config.rules[eventName] else { return }

        // Build title and body: substitute {event} token with the event name
        let title = rule.title.replacingOccurrences(of: "{event}", with: eventName)
        let body = rule.body.replacingOccurrences(of: "{event}", with: eventName)

        let notification = GridNotification(
            source: "event",
            title: title,
            body: body,
            priority: rule.priority
        )
        await store.add(notification)

        // Refresh the panel view model if the panel is visible.
        // Must hop to MainActor because NotificationPanelManager is @MainActor.
        await MainActor.run {
            if let vm = NotificationPanelManager.shared.currentViewModel {
                vm.refreshNotifications()
            }
        }
    }

    // MARK: - Lifecycle

    // Unregisters this handler from EventRouter. Call when the handler is no longer needed.
    func stop() async {
        await EventRouter.shared.unregister(self)
    }
}
