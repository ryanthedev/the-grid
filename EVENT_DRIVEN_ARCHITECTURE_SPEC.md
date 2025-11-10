# Event-Driven Architecture Specification
## macOS Window Manager Event System (yabai)

**Version:** 1.0
**Target Implementation:** Swift
**Based on:** yabai v7.1.16+
**Architecture:** 100% Event-Driven, Zero Polling

---

## Table of Contents

1. [Overview](#overview)
2. [Event Loop Core](#event-loop-core)
3. [Event Sources](#event-sources)
4. [Event Types](#event-types)
5. [Event Registration and Setup](#event-registration-and-setup)
6. [Event Flow and Processing](#event-flow-and-processing)
7. [State Management](#state-management)
8. [Swift Implementation Guide](#swift-implementation-guide)
9. [Performance Considerations](#performance-considerations)
10. [Error Handling](#error-handling)

---

## Overview

yabai uses a **fully event-driven architecture** with zero polling. All state changes are triggered by notifications from macOS subsystems. The system processes events asynchronously through a central event loop with a lock-free queue.

### Key Characteristics

- ✅ **100% event-driven** - No polling loops
- ✅ **Asynchronous processing** - Events queued and processed on dedicated thread
- ✅ **Lock-free queue** - High-performance concurrent event posting
- ✅ **Multiple event sources** - AX API, SkyLight, NSWorkspace, KVO
- ✅ **Type-safe event dispatching** - Compile-time event handler registration
- ✅ **Memory efficient** - Pool allocator for event objects
- ✅ **Thread-safe** - Atomic operations for concurrent access

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Event Sources                           │
├─────────────┬─────────────┬──────────────┬─────────────────────┤
│ AX Observer │ SkyLight    │ NSWorkspace  │ KVO (Process State) │
│ (Per-App)   │ Connection  │ Notifications│                     │
└──────┬──────┴──────┬──────┴───────┬──────┴──────┬──────────────┘
       │             │              │             │
       └─────────────┼──────────────┼─────────────┘
                     │              │
                     ▼              ▼
              ┌──────────────────────────┐
              │   event_loop_post()      │
              │   (Lock-free enqueue)    │
              └────────────┬─────────────┘
                           │
                           ▼
              ┌──────────────────────────┐
              │   Event Queue (FIFO)     │
              │   (Lock-free linked list)│
              └────────────┬─────────────┘
                           │
                           ▼
              ┌──────────────────────────┐
              │  Event Loop Thread       │
              │  (Dedicated pthread)     │
              └────────────┬─────────────┘
                           │
                           ▼
              ┌──────────────────────────┐
              │  Event Handler Dispatch  │
              │  (Switch on event type)  │
              └────────────┬─────────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
    ┌───────────┐  ┌──────────────┐  ┌────────────┐
    │ Window    │  │ Space        │  │ Display    │
    │ Handlers  │  │ Handlers     │  │ Handlers   │
    └───────────┘  └──────────────┘  └────────────┘
            │              │              │
            └──────────────┼──────────────┘
                           │
                           ▼
              ┌──────────────────────────┐
              │  State Updates           │
              │  (Window/Space/Display)  │
              └──────────────────────────┘
```

---

## Event Loop Core

### Data Structures

#### Event Structure
```c
struct event {
    enum event_type type;     // Event type identifier
    int param1;               // First parameter (int)
    void *context;            // Context pointer (typed per event)
    struct event *next;       // Next event in queue
};
```

**Swift Equivalent:**
```swift
class Event {
    let type: EventType
    let param1: Int
    let context: UnsafeMutableRawPointer?
    var next: Event?

    init(type: EventType, param1: Int = 0, context: UnsafeMutableRawPointer? = nil) {
        self.type = type
        self.param1 = param1
        self.context = context
        self.next = nil
    }
}
```

#### Event Loop Structure
```c
struct event_loop {
    bool is_running;          // Loop active flag
    pthread_t thread;         // Event processing thread
    sem_t *semaphore;         // Semaphore for thread wake-up
    struct memory_pool pool;  // Memory pool for events
    struct event *head;       // Queue head (dummy node)
    struct event *tail;       // Queue tail
};
```

**Swift Equivalent:**
```swift
class EventLoop {
    private var isRunning: Bool = false
    private var thread: Thread?
    private let semaphore: DispatchSemaphore
    private var head: Event      // Dummy head node
    private var tail: Event
    private let eventPool: EventPool

    init() {
        self.semaphore = DispatchSemaphore(value: 0)
        self.head = Event(type: .dummy)  // Dummy node
        self.tail = self.head
        self.eventPool = EventPool()
    }
}
```

### Event Posting (Lock-Free Enqueue)

**C Implementation:**
```c
void event_loop_post(struct event_loop *event_loop,
                     enum event_type type,
                     void *context,
                     int param1)
{
    bool success;
    struct event *tail, *new_tail;

    // Allocate new event from pool
    new_tail = memory_pool_push(&event_loop->pool, sizeof(struct event));
    __atomic_store_n(&new_tail->type, type, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->param1, param1, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->context, context, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->next, NULL, __ATOMIC_RELEASE);
    __asm__ __volatile__ ("" ::: "memory");  // Memory barrier

    // Lock-free enqueue using CAS
    do {
        tail = __atomic_load_n(&event_loop->tail, __ATOMIC_RELAXED);
        success = __sync_bool_compare_and_swap(&tail->next, NULL, new_tail);
    } while (!success);
    __sync_bool_compare_and_swap(&event_loop->tail, tail, new_tail);

    // Wake up event loop thread
    sem_post(event_loop->semaphore);
}
```

**Swift Implementation:**
```swift
func post(event type: EventType, context: UnsafeMutableRawPointer? = nil, param1: Int = 0) {
    let newEvent = eventPool.allocate()
    newEvent.type = type
    newEvent.param1 = param1
    newEvent.context = context
    newEvent.next = nil

    // Lock-free enqueue using OSAtomicCompareAndSwap or similar
    var success = false
    repeat {
        let currentTail = atomicLoad(&tail)
        success = atomicCAS(&currentTail.next, expected: nil, newValue: newEvent)
    } while !success

    atomicCAS(&tail, expected: currentTail, newValue: newEvent)

    // Signal event available
    semaphore.signal()
}
```

### Event Processing Loop

**C Implementation:**
```c
static void *event_loop_run(void *context)
{
    struct event *head, *next;
    struct event_loop *event_loop = context;

    while (event_loop->is_running) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        for (;;) {
            // Lock-free dequeue using CAS
            do {
                head = __atomic_load_n(&event_loop->head, __ATOMIC_RELAXED);
                next = __atomic_load_n(&head->next, __ATOMIC_RELAXED);
                if (!next) goto empty;  // Queue empty
            } while (!__sync_bool_compare_and_swap(&event_loop->head, head, next));

            // Dispatch event to handler
            switch (__atomic_load_n(&next->type, __ATOMIC_RELAXED)) {
                case APPLICATION_LAUNCHED:
                    EVENT_HANDLER_APPLICATION_LAUNCHED(
                        __atomic_load_n(&next->context, __ATOMIC_RELAXED),
                        __atomic_load_n(&next->param1, __ATOMIC_RELAXED)
                    );
                    break;
                // ... all event types
            }

            event_signal_flush();  // Flush user-defined signals
            ts_reset();            // Reset thread-local storage
        }

empty:
        [pool drain];
        sem_wait(event_loop->semaphore);  // Wait for next event
    }

    return NULL;
}
```

**Swift Implementation:**
```swift
private func runEventLoop() {
    while isRunning {
        autoreleasepool {
            while true {
                // Lock-free dequeue
                var success = false
                var nextEvent: Event?

                repeat {
                    let currentHead = atomicLoad(&head)
                    nextEvent = atomicLoad(&currentHead.next)

                    guard let next = nextEvent else {
                        // Queue empty
                        break
                    }

                    success = atomicCAS(&head, expected: currentHead, newValue: next)
                } while !success && nextEvent != nil

                guard let event = nextEvent else {
                    break  // Queue empty, wait for signal
                }

                // Dispatch to handler
                dispatch(event: event)
            }
        }

        // Wait for next event
        semaphore.wait()
    }
}

private func dispatch(event: Event) {
    switch event.type {
    case .applicationLaunched:
        handleApplicationLaunched(context: event.context, param: event.param1)
    case .windowCreated:
        handleWindowCreated(context: event.context, param: event.param1)
    // ... all event types
    default:
        break
    }
}
```

---

## Event Sources

### 1. Accessibility API (AX) Observers

**Purpose:** Per-application and per-window event notifications

#### Application-Level Observer

**Setup:**
```c
bool application_observe(struct application *application)
{
    if (AXObserverCreate(application->pid,
                         application_notification_handler,
                         &application->observer_ref) == kAXErrorSuccess) {

        // Register for all application notifications
        CFStringRef notifications[] = {
            kAXCreatedNotification,                // New window created
            kAXFocusedWindowChangedNotification,   // Focus changed
            kAXWindowMovedNotification,            // Window moved
            kAXWindowResizedNotification,          // Window resized
            kAXTitleChangedNotification,           // Title changed
            kAXMenuOpenedNotification,             // Menu opened
            kAXMenuClosedNotification              // Menu closed
        };

        for (int i = 0; i < array_count(notifications); ++i) {
            AXObserverAddNotification(application->observer_ref,
                                     application->ref,
                                     notifications[i],
                                     application);
        }

        // Add observer source to run loop
        CFRunLoopAddSource(CFRunLoopGetMain(),
                          AXObserverGetRunLoopSource(application->observer_ref),
                          kCFRunLoopDefaultMode);

        return true;
    }
    return false;
}
```

**Callback Handler:**
```c
static OBSERVER_CALLBACK(application_notification_handler)
{
    if (CFEqual(notification, kAXCreatedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_CREATED, (void*)CFRetain(element), 0);
    } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void*)(intptr_t)ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXWindowMovedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_MOVED, (void*)(intptr_t)ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXWindowResizedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_RESIZED, (void*)(intptr_t)ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXTitleChangedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_TITLE_CHANGED, (void*)(intptr_t)ax_window_id(element), 0);
    }
    // ... etc
}
```

**Swift Implementation:**
```swift
class ApplicationObserver {
    private let application: Application
    private var observerRef: AXObserver?

    func observe() -> Bool {
        var observer: AXObserver?
        guard AXObserverCreate(application.pid, axCallback, &observer) == .success,
              let observerRef = observer else {
            return false
        }

        self.observerRef = observerRef

        let notifications: [(CFString, AXNotification)] = [
            (kAXCreatedNotification, .windowCreated),
            (kAXFocusedWindowChangedNotification, .windowFocused),
            (kAXWindowMovedNotification, .windowMoved),
            (kAXWindowResizedNotification, .windowResized),
            (kAXTitleChangedNotification, .windowTitleChanged),
            (kAXMenuOpenedNotification, .menuOpened),
            (kAXMenuClosedNotification, .menuClosed)
        ]

        for (axNotif, _) in notifications {
            AXObserverAddNotification(observerRef,
                                     application.axElement,
                                     axNotif,
                                     Unmanaged.passUnretained(self).toOpaque())
        }

        CFRunLoopAddSource(CFRunLoopGetMain(),
                          AXObserverGetRunLoopSource(observerRef),
                          .defaultMode)

        return true
    }
}

// Callback (must be C function or @convention(c) closure)
private func axCallback(observer: AXObserver,
                       element: AXUIElement,
                       notification: CFString,
                       refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let observer = Unmanaged<ApplicationObserver>.fromOpaque(refcon).takeUnretainedValue()

    if CFEqual(notification, kAXCreatedNotification) {
        EventLoop.shared.post(event: .windowCreated, context: element.retain())
    } else if CFEqual(notification, kAXFocusedWindowChangedNotification) {
        let windowID = getWindowID(from: element)
        EventLoop.shared.post(event: .windowFocused, context: windowID.toPointer())
    }
    // ... etc
}
```

#### Window-Level Observer

**Setup:**
```c
bool window_observe(struct window *window)
{
    CFStringRef notifications[] = {
        kAXUIElementDestroyedNotification,      // Window destroyed
        kAXWindowMiniaturizedNotification,      // Window minimized
        kAXWindowDeminiaturizedNotification     // Window restored
    };

    for (int i = 0; i < array_count(notifications); ++i) {
        AXError result = AXObserverAddNotification(
            window->application->observer_ref,
            window->ref,
            notifications[i],
            window
        );

        if (result == kAXErrorSuccess || result == kAXErrorNotificationAlreadyRegistered) {
            window->notification |= 1 << i;
        }
    }

    return (window->notification & AX_WINDOW_ALL) == AX_WINDOW_ALL;
}
```

### 2. SkyLight Connection Notifications

**Purpose:** Window server events (z-order, space creation/destruction)

**Setup:**
```c
typedef void (*connection_callback)(int, int, void*);

// Register callbacks for window server events
SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1204, NULL);  // Mission Control enter
SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1327, NULL);  // Space created (macOS 13+)
SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1328, NULL);  // Space destroyed (macOS 13+)
SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 808, NULL);   // Window ordered (z-order)
SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 804, NULL);   // Window destroyed (macOS 15+)
```

**Callback Handler:**
```c
static CONNECTION_CALLBACK(connection_handler)
{
    if (type == 1204) {
        event_loop_post(&g_event_loop, MISSION_CONTROL_ENTER, NULL, 0);
    } else if (type == 1327) {
        uint64_t sid;
        memcpy(&sid, data, sizeof(uint64_t));
        event_loop_post(&g_event_loop, SLS_SPACE_CREATED, (void*)(intptr_t)sid, 0);
    } else if (type == 1328) {
        uint64_t sid;
        memcpy(&sid, data, sizeof(uint64_t));
        event_loop_post(&g_event_loop, SLS_SPACE_DESTROYED, (void*)(intptr_t)sid, 0);
    } else if (type == 808) {
        uint32_t wid;
        memcpy(&wid, data, sizeof(uint32_t));
        event_loop_post(&g_event_loop, SLS_WINDOW_ORDERED, (void*)(intptr_t)wid, 0);
    } else if (type == 804) {
        uint32_t wid;
        memcpy(&wid, data, sizeof(uint32_t));
        event_loop_post(&g_event_loop, SLS_WINDOW_DESTROYED, (void*)(intptr_t)wid, 0);
    }
}
```

**Swift Implementation:**
```swift
// typealias for SkyLight callback
typealias SLSConnectionCallback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void

class SkyLightObserver {
    private let connectionID: Int32

    func registerCallbacks() {
        let callback: SLSConnectionCallback = { connectionID, eventType, data in
            switch eventType {
            case 1204:  // Mission Control enter
                EventLoop.shared.post(event: .missionControlEnter)
            case 1327:  // Space created
                guard let data = data else { return }
                let spaceID = data.load(as: UInt64.self)
                EventLoop.shared.post(event: .slsSpaceCreated, context: spaceID.toPointer())
            case 1328:  // Space destroyed
                guard let data = data else { return }
                let spaceID = data.load(as: UInt64.self)
                EventLoop.shared.post(event: .slsSpaceDestroyed, context: spaceID.toPointer())
            case 808:   // Window ordered
                guard let data = data else { return }
                let windowID = data.load(as: UInt32.self)
                EventLoop.shared.post(event: .slsWindowOrdered, context: windowID.toPointer())
            case 804:   // Window destroyed
                guard let data = data else { return }
                let windowID = data.load(as: UInt32.self)
                EventLoop.shared.post(event: .slsWindowDestroyed, context: windowID.toPointer())
            default:
                break
            }
        }

        // Register for each event type
        SLSRegisterConnectionNotifyProc(connectionID, callback, 1204, nil)
        SLSRegisterConnectionNotifyProc(connectionID, callback, 1327, nil)
        SLSRegisterConnectionNotifyProc(connectionID, callback, 1328, nil)
        SLSRegisterConnectionNotifyProc(connectionID, callback, 808, nil)
        SLSRegisterConnectionNotifyProc(connectionID, callback, 804, nil)
    }
}
```

**Re-registration for Window Notifications (macOS 15+):**
```c
static void update_window_notifications(void)
{
    int window_count = 0;
    uint32_t window_list[1024] = {0};

    // Collect all tracked windows
    table_for (struct window *window, g_window_manager.window, {
        window_list[window_count++] = window->id;
    })

    // Re-subscribe to get notifications for these windows
    SLSRequestNotificationsForWindows(g_connection, window_list, window_count);
}
```

**When to call:**
- After `APPLICATION_LAUNCHED` handler
- After `APPLICATION_TERMINATED` handler
- After `WINDOW_CREATED` handler
- After `WINDOW_DESTROYED` handler

### 3. NSWorkspace Notifications

**Purpose:** System-level events (space changes, display changes, app visibility)

**Setup:**
```objc
@implementation workspace_context

- (id)init
{
    if ((self = [super init])) {
        // Workspace notifications
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                 selector:@selector(activeDisplayDidChange:)
                 name:@"NSWorkspaceActiveDisplayDidChangeNotification"
                 object:nil];

        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                 selector:@selector(activeSpaceDidChange:)
                 name:NSWorkspaceActiveSpaceDidChangeNotification
                 object:nil];

        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                 selector:@selector(didHideApplication:)
                 name:NSWorkspaceDidHideApplicationNotification
                 object:nil];

        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                 selector:@selector(didUnhideApplication:)
                 name:NSWorkspaceDidUnhideApplicationNotification
                 object:nil];

        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                 selector:@selector(didWake:)
                 name:NSWorkspaceDidWakeNotification
                 object:nil];

        // Distributed notifications
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                 selector:@selector(didChangeMenuBarHiding:)
                 name:@"AppleInterfaceMenuBarHidingChangedNotification"
                 object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                 selector:@selector(didRestartDock:)
                 name:@"NSApplicationDockDidRestartNotification"
                 object:nil];

        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                 selector:@selector(didChangeDockPref:)
                 name:@"com.apple.dock.prefchanged"
                 object:nil];
    }

    return self;
}
@end
```

**Notification Handlers:**
```objc
- (void)activeSpaceDidChange:(NSNotification *)notification
{
    event_loop_post(&g_event_loop, SPACE_CHANGED, NULL, 0);
}

- (void)activeDisplayDidChange:(NSNotification *)notification
{
    event_loop_post(&g_event_loop, DISPLAY_CHANGED, NULL, 0);
}

- (void)didHideApplication:(NSNotification *)notification
{
    pid_t pid = [[[notification userInfo] objectForKey:NSWorkspaceApplicationKey] processIdentifier];
    event_loop_post(&g_event_loop, APPLICATION_HIDDEN, (void*)(intptr_t)pid, 0);
}
```

**Swift Implementation:**
```swift
class WorkspaceObserver {
    init() {
        setupNotifications()
    }

    private func setupNotifications() {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Workspace notifications
        nc.addObserver(self,
                      selector: #selector(activeSpaceDidChange),
                      name: NSWorkspace.activeSpaceDidChangeNotification,
                      object: nil)

        nc.addObserver(self,
                      selector: #selector(activeDisplayDidChange),
                      name: NSWorkspace.activeDisplayDidChangeNotification,
                      object: nil)

        nc.addObserver(self,
                      selector: #selector(didHideApplication),
                      name: NSWorkspace.didHideApplicationNotification,
                      object: nil)

        nc.addObserver(self,
                      selector: #selector(didUnhideApplication),
                      name: NSWorkspace.didUnhideApplicationNotification,
                      object: nil)

        nc.addObserver(self,
                      selector: #selector(didWake),
                      name: NSWorkspace.didWakeNotification,
                      object: nil)

        // Distributed notifications
        dnc.addObserver(self,
                       selector: #selector(menuBarHidingChanged),
                       name: NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"),
                       object: nil)

        NotificationCenter.default.addObserver(self,
                                              selector: #selector(dockDidRestart),
                                              name: NSNotification.Name("NSApplicationDockDidRestartNotification"),
                                              object: nil)

        dnc.addObserver(self,
                       selector: #selector(dockPreferenceChanged),
                       name: NSNotification.Name("com.apple.dock.prefchanged"),
                       object: nil)
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        EventLoop.shared.post(event: .spaceChanged)
    }

    @objc private func activeDisplayDidChange(_ notification: Notification) {
        EventLoop.shared.post(event: .displayChanged)
    }

    @objc private func didHideApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        EventLoop.shared.post(event: .applicationHidden, context: app.processIdentifier.toPointer())
    }
}
```

### 4. Key-Value Observation (KVO)

**Purpose:** Process state changes (activation policy, launch completion)

**Setup:**
```objc
void workspace_application_observe_finished_launching(void *context, struct process *process)
{
    NSRunningApplication *application = __atomic_load_n(&process->ns_application, __ATOMIC_RELAXED);
    if (application) {
        [application addObserver:context
                      forKeyPath:@"finishedLaunching"
                         options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew
                         context:process];
    }
}

void workspace_application_observe_activation_policy(void *context, struct process *process)
{
    NSRunningApplication *application = __atomic_load_n(&process->ns_application, __ATOMIC_RELAXED);
    if (application) {
        [application addObserver:context
                      forKeyPath:@"activationPolicy"
                         options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew
                         context:process];
    }
}
```

**Observer Callback:**
```objc
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if ([keyPath isEqualToString:@"activationPolicy"]) {
        struct process *process = context;
        if (process->terminated) return;

        id result = [change objectForKey:NSKeyValueChangeNewKey];
        if ([result intValue] != process->policy) {
            @try {
                [object removeObserver:self forKeyPath:@"activationPolicy" context:process];
            } @catch (NSException *exception) {}

            process->policy = [result intValue];
            event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, process, 0);
        }
    }

    if ([keyPath isEqualToString:@"finishedLaunching"]) {
        struct process *process = context;
        if (process->terminated) return;

        id result = [change objectForKey:NSKeyValueChangeNewKey];
        if ([result intValue] == 1) {
            @try {
                [object removeObserver:self forKeyPath:@"finishedLaunching" context:process];
            } @catch (NSException *exception) {}

            event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, process, 0);
        }
    }
}
```

**Swift Implementation:**
```swift
class ProcessObserver: NSObject {
    private var observations: [NSKeyValueObservation] = []

    func observeFinishedLaunching(app: NSRunningApplication, process: Process) {
        let observation = app.observe(\.isFinishedLaunching, options: [.initial, .new]) { [weak self] app, change in
            guard let isFinished = change.newValue, isFinished else { return }

            // Remove observation (one-shot)
            self?.observations.removeAll { $0.observation == observation }

            EventLoop.shared.post(event: .applicationLaunched, context: process.toPointer())
        }
        observations.append(observation)
    }

    func observeActivationPolicy(app: NSRunningApplication, process: Process) {
        let observation = app.observe(\.activationPolicy, options: [.initial, .new]) { [weak self] app, change in
            guard let newPolicy = change.newValue else { return }

            if newPolicy.rawValue != process.policy {
                // Remove observation
                self?.observations.removeAll { $0.observation == observation }

                process.policy = newPolicy.rawValue
                EventLoop.shared.post(event: .applicationLaunched, context: process.toPointer())
            }
        }
        observations.append(observation)
    }
}
```

### 5. Carbon Process Manager Events

**Purpose:** Application launch/termination events

**Setup:**
```c
static PROCESS_EVENT_HANDLER(process_handler)
{
    struct process_manager *pm = context;

    ProcessSerialNumber psn;
    if (GetEventParameter(event, kEventParamProcessID, typeProcessSerialNumber,
                         NULL, sizeof(psn), NULL, &psn) != noErr) {
        return -1;
    }

    switch (GetEventKind(event)) {
    case kEventAppLaunched: {
        pid_t pid = process_pid_for_psn(psn);
        struct process *process = process_create(psn, pid);
        if (!process) return noErr;

        table_add(&pm->process, &process->psn, process);
        event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, process, 0);
    } break;

    case kEventAppTerminated: {
        struct process *process = process_manager_find_process(pm, &psn);
        if (!process) return noErr;

        __atomic_store_n(&process->terminated, true, __ATOMIC_RELEASE);
        table_remove(&pm->process, &psn);
        event_loop_post(&g_event_loop, APPLICATION_TERMINATED, process, 0);
    } break;

    case kEventAppFrontSwitched: {
        struct process *process = process_manager_find_process(pm, &psn);
        if (!process) return noErr;

        event_loop_post(&g_event_loop, APPLICATION_FRONT_SWITCHED, process, 0);
    } break;
    }

    return noErr;
}

bool process_manager_begin(struct process_manager *pm)
{
    pm->target = GetApplicationEventTarget();
    pm->handler = NewEventHandlerUPP(process_handler);

    EventTypeSpec events[] = {
        { kEventClassApplication, kEventAppLaunched },
        { kEventClassApplication, kEventAppTerminated },
        { kEventClassApplication, kEventAppFrontSwitched }
    };

    InstallEventHandler(pm->target, pm->handler,
                       array_count(events), events, pm, &pm->ref);

    return true;
}
```

**Swift Implementation:**
```swift
// Carbon APIs are deprecated; use NSWorkspace instead
class ProcessManager {
    init() {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter

        nc.addObserver(self,
                      selector: #selector(applicationDidLaunch),
                      name: NSWorkspace.didLaunchApplicationNotification,
                      object: nil)

        nc.addObserver(self,
                      selector: #selector(applicationDidTerminate),
                      name: NSWorkspace.didTerminateApplicationNotification,
                      object: nil)

        nc.addObserver(self,
                      selector: #selector(applicationDidActivate),
                      name: NSWorkspace.didActivateApplicationNotification,
                      object: nil)
    }

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let process = Process(app: app)
        EventLoop.shared.post(event: .applicationLaunched, context: process.toPointer())
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Find process and post termination event
        EventLoop.shared.post(event: .applicationTerminated, context: process.toPointer())
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        EventLoop.shared.post(event: .applicationFrontSwitched, context: process.toPointer())
    }
}
```

---

## Event Types

### Complete Event Type Enumeration

```c
enum event_type {
    // Application events
    APPLICATION_LAUNCHED,              // App launched and ready
    APPLICATION_TERMINATED,            // App terminated
    APPLICATION_FRONT_SWITCHED,        // App became frontmost
    APPLICATION_VISIBLE,               // App became visible (unhidden)
    APPLICATION_HIDDEN,                // App was hidden

    // Window events (from AX)
    WINDOW_CREATED,                    // New window created
    WINDOW_DESTROYED,                  // Window destroyed
    WINDOW_FOCUSED,                    // Window received focus
    WINDOW_MOVED,                      // Window position changed
    WINDOW_RESIZED,                    // Window size changed
    WINDOW_MINIMIZED,                  // Window minimized
    WINDOW_DEMINIMIZED,                // Window restored from minimized
    WINDOW_TITLE_CHANGED,              // Window title changed

    // Window events (from SkyLight)
    SLS_WINDOW_ORDERED,                // Window z-order changed
    SLS_WINDOW_DESTROYED,              // Window destroyed (SkyLight)
    SLS_SPACE_CREATED,                 // Space created (macOS 13+)
    SLS_SPACE_DESTROYED,               // Space destroyed (macOS 13+)

    // Space events
    SPACE_CHANGED,                     // Active space changed

    // Display events
    DISPLAY_ADDED,                     // Display connected
    DISPLAY_REMOVED,                   // Display disconnected
    DISPLAY_MOVED,                     // Display arrangement changed
    DISPLAY_RESIZED,                   // Display resolution changed
    DISPLAY_CHANGED,                   // Active display changed

    // Mouse events
    MOUSE_DOWN,                        // Mouse button pressed
    MOUSE_UP,                          // Mouse button released
    MOUSE_DRAGGED,                     // Mouse dragged
    MOUSE_MOVED,                       // Mouse moved (for FFM)

    // Mission Control events
    MISSION_CONTROL_SHOW_ALL_WINDOWS,  // Show all windows
    MISSION_CONTROL_SHOW_FRONT_WINDOWS,// Show app windows
    MISSION_CONTROL_SHOW_DESKTOP,      // Show desktop
    MISSION_CONTROL_ENTER,             // Entered Mission Control
    MISSION_CONTROL_CHECK_FOR_EXIT,    // Check if still in MC
    MISSION_CONTROL_EXIT,              // Exited Mission Control

    // System events
    DOCK_DID_RESTART,                  // Dock restarted
    MENU_OPENED,                       // Menu opened
    MENU_CLOSED,                       // Menu closed
    MENU_BAR_HIDDEN_CHANGED,           // Menu bar visibility changed
    DOCK_DID_CHANGE_PREF,              // Dock preferences changed
    SYSTEM_WOKE,                       // System woke from sleep

    // IPC events
    DAEMON_MESSAGE                     // Message from yabai client
};
```

**Swift Enumeration:**
```swift
enum EventType {
    // Application events
    case applicationLaunched
    case applicationTerminated
    case applicationFrontSwitched
    case applicationVisible
    case applicationHidden

    // Window events (AX)
    case windowCreated
    case windowDestroyed
    case windowFocused
    case windowMoved
    case windowResized
    case windowMinimized
    case windowDeminimized
    case windowTitleChanged

    // Window events (SkyLight)
    case slsWindowOrdered
    case slsWindowDestroyed
    case slsSpaceCreated
    case slsSpaceDestroyed

    // Space events
    case spaceChanged

    // Display events
    case displayAdded
    case displayRemoved
    case displayMoved
    case displayResized
    case displayChanged

    // Mouse events
    case mouseDown
    case mouseUp
    case mouseDragged
    case mouseMoved

    // Mission Control events
    case missionControlShowAllWindows
    case missionControlShowFrontWindows
    case missionControlShowDesktop
    case missionControlEnter
    case missionControlCheckForExit
    case missionControlExit

    // System events
    case dockDidRestart
    case menuOpened
    case menuClosed
    case menuBarHiddenChanged
    case dockDidChangePreference
    case systemWoke

    // IPC events
    case daemonMessage
}
```

### Event Context Types

Different events carry different context data:

| Event Type | Context Type | Param1 Type | Description |
|------------|--------------|-------------|-------------|
| `APPLICATION_LAUNCHED` | `struct process*` | - | Process that launched |
| `APPLICATION_TERMINATED` | `struct process*` | - | Process that terminated |
| `WINDOW_CREATED` | `AXUIElementRef` | - | AX element (retained) |
| `WINDOW_FOCUSED` | `uint32_t` (as pointer) | - | Window ID |
| `WINDOW_MOVED` | `uint32_t` (as pointer) | - | Window ID |
| `WINDOW_RESIZED` | `uint32_t` (as pointer) | - | Window ID |
| `WINDOW_DESTROYED` | `struct window*` | - | Window struct |
| `SLS_SPACE_CREATED` | `uint64_t` (as pointer) | - | Space ID |
| `SLS_SPACE_DESTROYED` | `uint64_t` (as pointer) | - | Space ID |
| `SPACE_CHANGED` | `NULL` | - | No context |
| `DISPLAY_CHANGED` | `NULL` | - | No context |
| `MOUSE_DOWN` | `CGEventRef` | Modifier mask | Mouse event |
| `DAEMON_MESSAGE` | - | Socket FD | Socket to read from |

---

## Event Registration and Setup

### Initialization Sequence

**Complete startup flow:**

```c
int main(int argc, char **argv)
{
    // 1. Configure settings and acquire lock
    configure_settings_and_acquire_lock();

    // 2. Get SkyLight connection
    g_connection = SLSMainConnectionID();

    // 3. Start event loop (MUST be first)
    if (!event_loop_begin(&g_event_loop)) {
        error("yabai: could not start event loop! abort..\n");
    }

    // 4. Initialize workspace context (NSWorkspace observers)
    if (!workspace_event_handler_begin(&g_workspace_context)) {
        error("yabai: could not start workspace context! abort..\n");
    }

    // 5. Initialize process manager (Carbon process events)
    if (!process_manager_begin(&g_process_manager)) {
        error("yabai: could not start process manager! abort..\n");
    }

    // 6. Initialize display manager
    if (!display_manager_begin(&g_display_manager)) {
        error("yabai: could not start display manager! abort..\n");
    }

    // 7. Initialize mouse handler (CGEvent tap)
    if (!mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK)) {
        error("yabai: could not start mouse handler! abort..\n");
    }

    // 8. Register SkyLight connection callbacks
    if (workspace_is_macos_monterey() || /* ... newer versions ... */) {
        mission_control_observe();  // AX observer for Dock.app

        if (workspace_is_macos_ventura() || /* ... newer ... */) {
            SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1327, NULL);
            SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1328, NULL);
        }
    } else {
        SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1204, NULL);
    }

    SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 808, NULL);

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 804, NULL);
    }

    // 9. Initialize window and space managers
    window_manager_init(&g_window_manager);
    space_manager_begin(&g_space_manager);
    window_manager_begin(&g_space_manager, &g_window_manager);

    // 10. Subscribe to window notifications (macOS 15+)
    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    // 11. Start message loop (Unix socket for IPC)
    if (!message_loop_begin(g_socket_file)) {
        error("yabai: could not start message loop! abort..\n");
    }

    // 12. Execute config file
    exec_config_file(g_config_file, sizeof(g_config_file));

    // 13. Run main run loop
    [NSApp run];

    return 0;
}
```

**Swift Initialization:**
```swift
class WindowManager {
    private let eventLoop: EventLoop
    private let workspaceObserver: WorkspaceObserver
    private let processManager: ProcessManager
    private let skylightObserver: SkyLightObserver
    private let axObserverManager: AXObserverManager

    func start() {
        // 1. Start event loop (dedicated thread)
        eventLoop.start()

        // 2. Setup NSWorkspace observers
        workspaceObserver = WorkspaceObserver()

        // 3. Setup process manager (app launch/terminate)
        processManager = ProcessManager()

        // 4. Register SkyLight callbacks
        skylightObserver = SkyLightObserver(connectionID: SLSMainConnectionID())
        skylightObserver.registerCallbacks()

        // 5. Initialize managers
        initializeWindowManager()
        initializeSpaceManager()
        initializeDisplayManager()

        // 6. Enumerate existing apps and create AX observers
        enumerateRunningApplications()

        // 7. Start message server (IPC)
        startMessageServer()

        // 8. Load configuration
        loadConfiguration()

        // 9. Run main run loop
        NSApp.run()
    }

    private func enumerateRunningApplications() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }

            let process = Process(app: app)
            let appObserver = ApplicationObserver(application: process)

            if appObserver.observe() {
                axObserverManager.register(observer: appObserver, for: process.pid)

                // Enumerate existing windows
                enumerateWindowsForApplication(process)
            }
        }
    }
}
```

---

## Event Flow and Processing

### Batching and Dirty Flagging

yabai uses **lazy evaluation** with dirty flags to batch window layout updates:

**Pattern:**
```c
// 1. Mark view as dirty when making changes
view_add_window_node_with_insertion_point(view, window, prev_window_id);
window_manager_add_managed_window(&g_window_manager, window, view);
view_set_flag(view, VIEW_IS_DIRTY);

// 2. Batch multiple operations
for (int i = 0; i < window_count; ++i) {
    struct window *window = window_list[i];
    // ... add window to view
    view_set_flag(view, VIEW_IS_DIRTY);
    view_list[view_count++] = view;
}

// 3. Flush all dirty views at once (single AX call per window)
for (int i = 0; i < view_count; ++i) {
    struct view *view = view_list[i];
    if (!space_is_visible(view->sid)) continue;
    if (!view_is_dirty(view)) continue;

    window_node_flush(view->root);  // Recursive AX updates
    view_clear_flag(view, VIEW_IS_DIRTY);
}
```

**Why this matters:**
- AX API calls are **slow** (50-100ms each)
- Batching reduces N AX calls to 1
- Only update visible spaces
- Critical for performance during app launch

**Swift Implementation:**
```swift
struct ViewFlags: OptionSet {
    let rawValue: UInt32
    static let isDirty = ViewFlags(rawValue: 1 << 0)
    static let isValid = ViewFlags(rawValue: 1 << 1)
}

class View {
    var flags: ViewFlags = []
    var spaceID: UInt64
    var root: WindowNode?

    func setDirty() {
        flags.insert(.isDirty)
    }

    func isDirty() -> Bool {
        return flags.contains(.isDirty)
    }

    func flush() {
        guard flags.contains(.isDirty) else { return }
        guard Space.isVisible(spaceID) else { return }

        root?.flushLayout()  // Recursive AX updates
        flags.remove(.isDirty)
    }
}

// Usage in event handler
func handleApplicationLaunched(process: Process) {
    var dirtyViews: [View] = []

    // Batch operations
    for window in process.windows {
        let view = spaceManager.viewForSpace(window.spaceID)
        view.addWindow(window)
        view.setDirty()

        if !dirtyViews.contains(where: { $0.spaceID == view.spaceID }) {
            dirtyViews.append(view)
        }
    }

    // Flush all at once
    for view in dirtyViews {
        view.flush()
    }
}
```

### Debouncing

Some events fire multiple times rapidly; yabai debounces them:

**Window Move/Resize Debouncing:**
```c
static EVENT_HANDLER(WINDOW_MOVED)
{
    // ... validation ...

    CGPoint new_origin = window_ax_origin(window);
    if (CGPointEqualToPoint(new_origin, window->frame.origin)) {
        debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        return;  // Same position, ignore
    }

    // ... process move ...
}
```

**Mouse Resize Throttling:**
```c
static EVENT_HANDLER(MOUSE_DRAGGED)
{
    if (g_mouse_state.current_action == MOUSE_MODE_RESIZE) {
        uint64_t event_time = read_os_timer();
        float dt = ((float)event_time - g_mouse_state.last_moved_time) *
                   (1000.0f / (float)read_os_freq());

        if (dt < 67.67f) goto out;  // ~15 FPS max

        // ... process resize ...
        g_mouse_state.last_moved_time = event_time;
    }
}
```

**Swift Implementation:**
```swift
class EventDebouncer {
    private var lastValue: CGPoint = .zero
    private var lastTime: UInt64 = 0

    func shouldProcess(newValue: CGPoint) -> Bool {
        return !newValue.equalTo(lastValue)
    }

    func shouldThrottle(minimumInterval: TimeInterval) -> Bool {
        let now = mach_absolute_time()
        let elapsed = Double(now - lastTime) / Double(NSEC_PER_SEC)
        return elapsed < minimumInterval
    }

    func update(value: CGPoint) {
        lastValue = value
        lastTime = mach_absolute_time()
    }
}

func handleWindowMoved(windowID: UInt32) {
    guard let window = windowManager.findWindow(windowID) else { return }

    let newOrigin = window.axOrigin()

    if !debouncer.shouldProcess(newValue: newOrigin) {
        print("DEBOUNCED window move for \(windowID)")
        return
    }

    debouncer.update(value: newOrigin)

    // Process move
    window.frame.origin = newOrigin
    // ...
}
```

### Event Invalidation

When windows are destroyed, queued events for that window must be ignored:

**Pattern:**
```c
struct window {
    uint32_t id;
    uint32_t *volatile id_ptr;  // Points to &id, or NULL if invalid
};

// When window destroyed:
if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, NULL)) {
    return;  // Already invalidated
}

// In event handler:
if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
    debug("%s: %d has been marked invalid, ignoring event..\n", __FUNCTION__, window_id);
    return;
}
```

**Why:**
- Events are queued asynchronously
- Window might be destroyed between event post and processing
- Invalid pointer = segfault
- CAS ensures atomic check-and-mark

**Swift Implementation:**
```swift
class Window {
    let id: UInt32
    private var isValid: Bool = true
    private let validityLock = NSLock()

    func invalidate() -> Bool {
        validityLock.lock()
        defer { validityLock.unlock() }

        guard isValid else { return false }
        isValid = false
        return true
    }

    func checkValid() -> Bool {
        validityLock.lock()
        defer { validityLock.unlock() }
        return isValid
    }
}

func handleWindowMoved(windowID: UInt32) {
    guard let window = windowManager.findWindow(windowID),
          window.checkValid() else {
        print("Window \(windowID) invalid, ignoring move event")
        return
    }

    // Process event
}
```

---

## State Management

### Global State

yabai maintains global state managers accessed by event handlers:

```c
// Global state (extern in yabai.c)
struct event_loop g_event_loop;
struct process_manager g_process_manager;
struct display_manager g_display_manager;
struct window_manager g_window_manager;
struct space_manager g_space_manager;
struct mouse_state g_mouse_state;
void *g_workspace_context;
```

**Swift Equivalent:**
```swift
class WindowManagerState {
    static let shared = WindowManagerState()

    let eventLoop: EventLoop
    let processManager: ProcessManager
    let displayManager: DisplayManager
    let windowManager: WindowManager
    let spaceManager: SpaceManager
    let mouseState: MouseState
    let workspaceContext: WorkspaceObserver

    private init() {
        eventLoop = EventLoop()
        processManager = ProcessManager()
        displayManager = DisplayManager()
        windowManager = WindowManager()
        spaceManager = SpaceManager()
        mouseState = MouseState()
        workspaceContext = WorkspaceObserver()
    }
}
```

### Thread Safety

**Event loop is single-threaded** for state mutations:
- All event handlers run on dedicated event loop thread
- No locking needed for state access within handlers
- External threads must post events, not mutate directly

**Atomic operations for:**
- Event queue manipulation (lock-free CAS)
- Window validity flags
- Process termination flags

```c
__atomic_store_n(&process->terminated, true, __ATOMIC_RELEASE);
bool terminated = __atomic_load_n(&process->terminated, __ATOMIC_RELAXED);
```

**Swift:**
```swift
import Foundation

class AtomicBool {
    private var value: Int32

    init(_ initialValue: Bool) {
        value = initialValue ? 1 : 0
    }

    func store(_ newValue: Bool) {
        OSAtomicTestAndSet(0, &value, newValue ? 1 : 0)
    }

    func load() -> Bool {
        return OSAtomicTestAndSet(0, &value, value) != 0
    }
}
```

---

## Swift Implementation Guide

### Complete EventLoop Implementation

```swift
import Foundation
import Cocoa
import ApplicationServices

// MARK: - Event Type

enum EventType: Int {
    case applicationLaunched
    case applicationTerminated
    case windowCreated
    case windowFocused
    case windowMoved
    case windowResized
    // ... all event types
}

// MARK: - Event Structure

class Event {
    let type: EventType
    let param1: Int
    let context: UnsafeMutableRawPointer?
    var next: UnsafeMutablePointer<Event>?

    init(type: EventType, param1: Int = 0, context: UnsafeMutableRawPointer? = nil) {
        self.type = type
        self.param1 = param1
        self.context = context
        self.next = nil
    }
}

// MARK: - Event Loop

class EventLoop {
    static let shared = EventLoop()

    private var isRunning = false
    private var thread: Thread?
    private let semaphore = DispatchSemaphore(value: 0)

    // Lock-free queue
    private var head: UnsafeMutablePointer<Event>
    private var tail: UnsafeMutablePointer<Event>

    private init() {
        // Create dummy head node
        let dummy = UnsafeMutablePointer<Event>.allocate(capacity: 1)
        dummy.initialize(to: Event(type: .applicationLaunched))  // Dummy
        dummy.pointee.next = nil

        head = dummy
        tail = dummy
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true

        thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread?.start()
    }

    func post(event type: EventType, context: UnsafeMutableRawPointer? = nil, param1: Int = 0) {
        let newEvent = UnsafeMutablePointer<Event>.allocate(capacity: 1)
        newEvent.initialize(to: Event(type: type, param1: param1, context: context))
        newEvent.pointee.next = nil

        // Lock-free enqueue
        var success = false
        var currentTail: UnsafeMutablePointer<Event>

        repeat {
            currentTail = atomicLoad(&tail)
            success = atomicCAS(&currentTail.pointee.next, expected: nil, newValue: newEvent)
        } while !success

        // Update tail
        atomicCAS(&tail, expected: currentTail, newValue: newEvent)

        // Signal event available
        semaphore.signal()
    }

    // MARK: - Private Methods

    private func runLoop() {
        while isRunning {
            autoreleasepool {
                processEvents()
            }
            semaphore.wait()
        }
    }

    private func processEvents() {
        while true {
            var currentHead: UnsafeMutablePointer<Event>
            var nextEvent: UnsafeMutablePointer<Event>?
            var success = false

            repeat {
                currentHead = atomicLoad(&head)
                nextEvent = atomicLoad(&currentHead.pointee.next)

                guard let next = nextEvent else {
                    return  // Queue empty
                }

                success = atomicCAS(&head, expected: currentHead, newValue: next)
            } while !success && nextEvent != nil

            guard let event = nextEvent else { return }

            // Dispatch event
            dispatch(event: event.pointee)

            // Free old head
            currentHead.deinitialize(count: 1)
            currentHead.deallocate()
        }
    }

    private func dispatch(event: Event) {
        switch event.type {
        case .applicationLaunched:
            handleApplicationLaunched(context: event.context, param: event.param1)
        case .windowCreated:
            handleWindowCreated(context: event.context, param: event.param1)
        case .windowMoved:
            handleWindowMoved(context: event.context, param: event.param1)
        // ... all event types
        default:
            break
        }
    }

    // MARK: - Atomic Helpers

    private func atomicLoad<T>(_ pointer: inout T) -> T {
        return OSAtomicOr32Barrier(0, UnsafeMutablePointer<Int32>(mutating: &pointer))
    }

    private func atomicCAS<T: AnyObject>(_ pointer: inout T?, expected: T?, newValue: T?) -> Bool {
        return OSAtomicCompareAndSwapPtr(
            UnsafeMutableRawPointer(Unmanaged.passUnretained(expected).toOpaque()),
            UnsafeMutableRawPointer(Unmanaged.passUnretained(newValue).toOpaque()),
            UnsafeMutablePointer(&pointer)
        )
    }
}
```

### Application Observer Implementation

```swift
class ApplicationObserver {
    private weak var application: Application?
    private var observerRef: AXObserver?

    init(application: Application) {
        self.application = application
    }

    func observe() -> Bool {
        guard let app = application else { return false }

        var observer: AXObserver?
        let result = AXObserverCreate(app.pid, axCallbackC, &observer)

        guard result == .success, let obs = observer else {
            return false
        }

        self.observerRef = obs

        // Register notifications
        let notifications: [CFString] = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXTitleChangedNotification,
            kAXMenuOpenedNotification,
            kAXMenuClosedNotification
        ]

        for notification in notifications {
            AXObserverAddNotification(
                obs,
                app.axElement,
                notification,
                Unmanaged.passRetained(self).toOpaque()
            )
        }

        // Add to run loop
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        return true
    }

    deinit {
        if let observer = observerRef {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }
}

// C-style callback
private func axCallbackC(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }

    let appObserver = Unmanaged<ApplicationObserver>.fromOpaque(refcon).takeUnretainedValue()
    appObserver.handleNotification(element: element, notification: notification)
}

extension ApplicationObserver {
    fileprivate func handleNotification(element: AXUIElement, notification: CFString) {
        if CFEqual(notification, kAXCreatedNotification) {
            EventLoop.shared.post(
                event: .windowCreated,
                context: Unmanaged.passRetained(element as CFTypeRef).toOpaque()
            )
        } else if CFEqual(notification, kAXFocusedWindowChangedNotification) {
            if let windowID = getWindowID(from: element) {
                EventLoop.shared.post(
                    event: .windowFocused,
                    context: UnsafeMutableRawPointer(bitPattern: UInt(windowID))
                )
            }
        }
        // ... etc
    }
}
```

---

## Performance Considerations

### Why Event-Driven Matters

**Polling approach** (don't do this):
```swift
// BAD: Constant CPU usage even when idle
func pollWindowState() {
    while true {
        for window in windows {
            let newFrame = window.getFrame()  // Expensive AX call
            if newFrame != window.cachedFrame {
                handleWindowMoved(window)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)  // 10 Hz polling
    }
}
```

**Problems:**
- ❌ Constant CPU usage (10% even when idle)
- ❌ Battery drain
- ❌ Latency (100ms best case)
- ❌ Scales poorly (O(n) windows × poll rate)

**Event-driven approach**:
```swift
// GOOD: Zero CPU when idle, instant response
func setupObservers() {
    for app in runningApps {
        observeApplication(app)  // AX observer setup once
    }
}
```

**Benefits:**
- ✅ Zero CPU when idle
- ✅ Battery friendly
- ✅ Instant response (<10ms)
- ✅ Scales to 1000s of windows

### Memory Pool for Events

yabai uses a memory pool to avoid malloc/free overhead:

```c
struct memory_pool {
    void *memory;
    uint64_t size;
    uint64_t used;
};

bool memory_pool_init(struct memory_pool *pool, uint64_t size) {
    pool->memory = malloc(size);
    pool->size = size;
    pool->used = 0;
    return pool->memory != NULL;
}

void *memory_pool_push(struct memory_pool *pool, uint64_t size) {
    if (pool->used + size > pool->size) return NULL;
    void *result = (char *)pool->memory + pool->used;
    pool->used += size;
    return result;
}
```

**Swift implementation:**
```swift
class EventPool {
    private var pool: UnsafeMutableRawPointer
    private var used: Int = 0
    private let size: Int
    private let lock = NSLock()

    init(size: Int = 512 * 1024) {  // 512 KB
        self.size = size
        self.pool = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    }

    func allocate() -> UnsafeMutablePointer<Event> {
        lock.lock()
        defer { lock.unlock() }

        let eventSize = MemoryLayout<Event>.stride
        guard used + eventSize <= size else {
            // Pool exhausted, allocate separately (rare)
            return UnsafeMutablePointer<Event>.allocate(capacity: 1)
        }

        let ptr = (pool + used).assumingMemoryBound(to: Event.self)
        used += eventSize
        return ptr
    }

    func reset() {
        lock.lock()
        used = 0
        lock.unlock()
    }

    deinit {
        pool.deallocate()
    }
}
```

---

## Error Handling

### Retry Logic

Some AX operations fail temporarily; yabai retries:

```c
if (!application_observe(application)) {
    bool ax_retry = application->ax_retry;

    application_unobserve(application);
    application_destroy(application);

    if (ax_retry) {
        // Retry after 100ms
        __block ProcessSerialNumber psn = process->psn;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC),
                      dispatch_get_main_queue(), ^{
            struct process *_process = process_manager_find_process(&g_process_manager, &psn);
            if (_process) event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, _process, 0);
        });
    }
}
```

**Swift:**
```swift
func handleApplicationLaunched(process: Process) {
    let application = Application(process: process)
    let observer = ApplicationObserver(application: application)

    if !observer.observe() {
        // Retry if AX said "cannot complete"
        if observer.shouldRetry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                EventLoop.shared.post(event: .applicationLaunched, context: process.toPointer())
            }
        }
        return
    }

    // Success, track application
    windowManager.addApplication(application)
}
```

### Race Condition Handling

**KVO race condition:**
```c
if (!workspace_application_is_finished_launching(process)) {
    workspace_application_observe_finished_launching(g_workspace_context, process);

    // Check again in case of race between check and observation
    if (workspace_application_is_finished_launching(process)) {
        // It finished between check and observation, remove observer
        [application removeObserver:g_workspace_context forKeyPath:@"finishedLaunching"];
    } else {
        return;  // Wait for notification
    }
}
```

---

## Conclusion

yabai's event-driven architecture provides:

1. **Zero polling** - All state changes triggered by macOS notifications
2. **High performance** - Lock-free queue, memory pool, batched updates
3. **Scalability** - Handles 1000s of windows with zero idle CPU
4. **Reliability** - Event invalidation, retry logic, race condition handling
5. **Multiple event sources** - AX, SkyLight, NSWorkspace, KVO seamlessly integrated

**Key implementation requirements for Swift:**
- Use `AXObserver` for window/app events
- Use private `SLS*` functions for space/display events
- Use `NSWorkspace` for system events
- Implement lock-free event queue with semaphore
- Batch AX updates with dirty flagging
- Handle race conditions and retries
- Never poll - always event-driven

This architecture is the foundation that enables yabai to manage complex window layouts with minimal resource usage and instant responsiveness.
