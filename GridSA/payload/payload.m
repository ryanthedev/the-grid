#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <pwd.h>

// MARK: - SkyLight API Declarations

typedef int CGSConnectionID;
typedef CGSConnectionID (*SLSMainConnectionID_f)(void);
typedef void (*SLSMoveWindowsToManagedSpace_f)(CGSConnectionID cid, CFArrayRef window_list, uint64_t sid);
typedef void (*SLSSpaceSetCompatID_f)(CGSConnectionID cid, uint64_t sid, uint32_t workspace);
typedef void (*SLSSetWindowListWorkspace_f)(CGSConnectionID cid, uint32_t *window_list, int count, uint32_t workspace);

// Function pointers (loaded dynamically)
static SLSMainConnectionID_f _SLSMainConnectionID = NULL;
static SLSMoveWindowsToManagedSpace_f _SLSMoveWindowsToManagedSpace = NULL;
static SLSSpaceSetCompatID_f _SLSSpaceSetCompatID = NULL;
static SLSSetWindowListWorkspace_f _SLSSetWindowListWorkspace = NULL;

// macOS version detection for API compatibility
static bool requires_compat_workaround(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];

    // Monterey 12.7+
    if (v.majorVersion == 12 && v.minorVersion >= 7) return true;

    // Ventura 13.6+
    if (v.majorVersion == 13 && v.minorVersion >= 6) return true;

    // Sonoma 14.5+
    if (v.majorVersion == 14 && v.minorVersion >= 5) return true;

    // Sequoia 15.0+ (and future versions)
    return v.majorVersion >= 15;
}

// Load SkyLight functions
static bool load_skylight_functions(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!handle) {
        NSLog(@"[GridSA] Failed to load SkyLight framework");
        return false;
    }

    _SLSMainConnectionID = (SLSMainConnectionID_f)dlsym(handle, "SLSMainConnectionID");
    _SLSMoveWindowsToManagedSpace = (SLSMoveWindowsToManagedSpace_f)dlsym(handle, "SLSMoveWindowsToManagedSpace");
    _SLSSpaceSetCompatID = (SLSSpaceSetCompatID_f)dlsym(handle, "SLSSpaceSetCompatID");
    _SLSSetWindowListWorkspace = (SLSSetWindowListWorkspace_f)dlsym(handle, "SLSSetWindowListWorkspace");

    if (!_SLSMainConnectionID) {
        NSLog(@"[GridSA] Failed to load SLSMainConnectionID");
        return false;
    }

    // Check which API path is available
    bool needs_compat = requires_compat_workaround();

    if (needs_compat) {
        if (!_SLSSpaceSetCompatID || !_SLSSetWindowListWorkspace) {
            NSLog(@"[GridSA] Failed to load compatibility workaround functions");
            return false;
        }
        NSLog(@"[GridSA] Using compatibility workaround for modern macOS");
    } else {
        if (!_SLSMoveWindowsToManagedSpace) {
            NSLog(@"[GridSA] Failed to load SLSMoveWindowsToManagedSpace");
            return false;
        }
        NSLog(@"[GridSA] Using direct SLSMoveWindowsToManagedSpace API");
    }

    NSLog(@"[GridSA] SkyLight functions loaded successfully");
    return true;
}

// MARK: - Socket Communication

#define SA_SOCKET_PATH_FMT "/tmp/grid-sa_%s.socket"
#define SA_MAX_CONNECTION_COUNT 32

// Opcodes for communication protocol
enum {
    SA_OPCODE_HANDSHAKE = 0x01,
    SA_OPCODE_WINDOW_TO_SPACE = 0x13,
    SA_OPCODE_WINDOW_LIST_TO_SPACE = 0x12
};

// Global state
static pthread_t g_daemon_thread;
static int g_socket_fd = -1;
static bool g_running = false;

// MARK: - Utility Functions

static inline char *file_manager_get_socket_path(void) {
    char *user = getenv("USER");
    if (!user) {
        struct passwd *pw = getpwuid(getuid());
        user = pw->pw_name;
    }

    char *socket_path = malloc(strlen(SA_SOCKET_PATH_FMT) + strlen(user) + 1);
    sprintf(socket_path, SA_SOCKET_PATH_FMT, user);
    return socket_path;
}

static inline void pack_bytes(char **cursor, void *bytes, size_t size) {
    memcpy(*cursor, bytes, size);
    *cursor += size;
}

static inline void unpack_bytes(char **cursor, void *bytes, size_t size) {
    memcpy(bytes, *cursor, size);
    *cursor += size;
}

// MARK: - Message Handlers

static void handle_handshake(int sockfd) {
    NSLog(@"[GridSA] Received handshake");

    // Version string
    const char *version = "1.0.0";
    size_t version_len = strlen(version);

    // Capability flags
    uint32_t capabilities = 0;

    // Bit 0: SLSMainConnectionID available
    if (_SLSMainConnectionID != NULL) {
        capabilities |= (1 << 0);
    }

    // Bit 1: Direct window movement available (old macOS)
    if (_SLSMoveWindowsToManagedSpace != NULL && !requires_compat_workaround()) {
        capabilities |= (1 << 1);
    }

    // Bit 2: Compatibility workaround available (modern macOS)
    if (_SLSSpaceSetCompatID != NULL && _SLSSetWindowListWorkspace != NULL && requires_compat_workaround()) {
        capabilities |= (1 << 2);
    }

    // Build response: [version_string\0][uint32_t capabilities]
    char response[256];
    char *cursor = response;

    // Pack version string (null-terminated)
    memcpy(cursor, version, version_len + 1);
    cursor += version_len + 1;

    // Pack capabilities
    memcpy(cursor, &capabilities, sizeof(uint32_t));
    cursor += sizeof(uint32_t);

    size_t response_len = cursor - response;

    // Send response
    send(sockfd, response, response_len, 0);

    NSLog(@"[GridSA] Handshake complete - version: %s, capabilities: 0x%08x", version, capabilities);
}

static void handle_window_to_space(int sockfd, char *message) {
    // Unpack space ID (8 bytes)
    uint64_t space_id;
    unpack_bytes(&message, &space_id, sizeof(uint64_t));

    // Unpack window ID (4 bytes)
    uint32_t window_id;
    unpack_bytes(&message, &window_id, sizeof(uint32_t));

    NSLog(@"[GridSA] Moving window %u to space %llu", window_id, space_id);

    // Get connection ID
    CGSConnectionID connection = _SLSMainConnectionID();

    if (!requires_compat_workaround()) {
        // Direct API path (older macOS)
        NSLog(@"[GridSA] Using direct SLSMoveWindowsToManagedSpace");

        CFNumberRef window_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &window_id);
        CFArrayRef window_list = CFArrayCreate(NULL, (const void **)&window_number, 1, &kCFTypeArrayCallBacks);

        _SLSMoveWindowsToManagedSpace(connection, window_list, space_id);

        CFRelease(window_list);
        CFRelease(window_number);
    } else {
        // Compatibility workaround for modern macOS (12.7+, 13.6+, 14.5+, 15.0+)
        NSLog(@"[GridSA] Using compatibility workaround (macOS 12.7+)");

        // Magic value: "GRID" in ASCII (0x47524944)
        const uint32_t compat_id = 0x47524944;

        // Set temporary compatibility workspace ID
        _SLSSpaceSetCompatID(connection, space_id, compat_id);

        // Move window using compatibility ID
        _SLSSetWindowListWorkspace(connection, &window_id, 1, compat_id);

        // Clear compatibility ID
        _SLSSpaceSetCompatID(connection, space_id, 0x0);
    }

    // Send success response
    uint8_t response = 1;
    send(sockfd, &response, 1, 0);

    NSLog(@"[GridSA] Window move completed");
}

static void handle_window_list_to_space(int sockfd, char *message) {
    // Unpack space ID (8 bytes)
    uint64_t space_id;
    unpack_bytes(&message, &space_id, sizeof(uint64_t));

    // Unpack window count (4 bytes)
    int32_t count;
    unpack_bytes(&message, &count, sizeof(int32_t));

    NSLog(@"[GridSA] Moving %d windows to space %llu", count, space_id);

    // Unpack window IDs into array
    uint32_t *window_ids = malloc(count * sizeof(uint32_t));
    for (int32_t i = 0; i < count; i++) {
        unpack_bytes(&message, &window_ids[i], sizeof(uint32_t));
    }

    // Get connection ID
    CGSConnectionID connection = _SLSMainConnectionID();

    if (!requires_compat_workaround()) {
        // Direct API path (older macOS)
        NSLog(@"[GridSA] Using direct SLSMoveWindowsToManagedSpace");

        CFNumberRef *window_numbers = malloc(count * sizeof(CFNumberRef));
        for (int32_t i = 0; i < count; i++) {
            window_numbers[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &window_ids[i]);
        }

        CFArrayRef window_list = CFArrayCreate(NULL, (const void **)window_numbers, count, &kCFTypeArrayCallBacks);
        _SLSMoveWindowsToManagedSpace(connection, window_list, space_id);

        CFRelease(window_list);
        for (int32_t i = 0; i < count; i++) {
            CFRelease(window_numbers[i]);
        }
        free(window_numbers);
    } else {
        // Compatibility workaround for modern macOS (12.7+, 13.6+, 14.5+, 15.0+)
        NSLog(@"[GridSA] Using compatibility workaround (macOS 12.7+)");

        // Magic value: "GRID" in ASCII (0x47524944)
        const uint32_t compat_id = 0x47524944;

        // Set temporary compatibility workspace ID
        _SLSSpaceSetCompatID(connection, space_id, compat_id);

        // Move all windows using compatibility ID
        _SLSSetWindowListWorkspace(connection, window_ids, count, compat_id);

        // Clear compatibility ID
        _SLSSpaceSetCompatID(connection, space_id, 0x0);
    }

    // Cleanup
    free(window_ids);

    // Send success response
    uint8_t response = 1;
    send(sockfd, &response, 1, 0);

    NSLog(@"[GridSA] Window list move completed");
}

static void handle_client_message(int sockfd, char *message, int length) {
    if (length < 1) {
        NSLog(@"[GridSA] Invalid message: too short");
        return;
    }

    uint8_t opcode = message[0];
    message++; // Move past opcode

    switch (opcode) {
        case SA_OPCODE_HANDSHAKE:
            handle_handshake(sockfd);
            break;
        case SA_OPCODE_WINDOW_TO_SPACE:
            handle_window_to_space(sockfd, message);
            break;
        case SA_OPCODE_WINDOW_LIST_TO_SPACE:
            handle_window_list_to_space(sockfd, message);
            break;
        default:
            NSLog(@"[GridSA] Unknown opcode: 0x%02x", opcode);
            uint8_t error = 0;
            send(sockfd, &error, 1, 0);
            break;
    }
}

static void handle_client_connection(int client_fd) {
    char buffer[1024];
    ssize_t bytes_read;

    while ((bytes_read = recv(client_fd, buffer, sizeof(buffer), 0)) > 0) {
        handle_client_message(client_fd, buffer, (int)bytes_read);
    }

    close(client_fd);
}

// MARK: - Socket Server

static void *daemon_thread_proc(void *arg) {
    @autoreleasepool {
        NSLog(@"[GridSA] Daemon thread started in process: %@", [[NSProcessInfo processInfo] processName]);

        char *socket_path = file_manager_get_socket_path();
        NSLog(@"[GridSA] Socket path: %s", socket_path);

        // Remove existing socket file if present
        unlink(socket_path);

        // Create Unix domain socket
        g_socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (g_socket_fd == -1) {
            NSLog(@"[GridSA] Failed to create socket");
            free(socket_path);
            return NULL;
        }

        // Bind socket
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

        if (bind(g_socket_fd, (struct sockaddr *)&addr, sizeof(addr)) == -1) {
            NSLog(@"[GridSA] Failed to bind socket");
            close(g_socket_fd);
            free(socket_path);
            return NULL;
        }

        // Listen for connections
        if (listen(g_socket_fd, SA_MAX_CONNECTION_COUNT) == -1) {
            NSLog(@"[GridSA] Failed to listen on socket");
            close(g_socket_fd);
            unlink(socket_path);
            free(socket_path);
            return NULL;
        }

        NSLog(@"[GridSA] Listening on socket: %s", socket_path);

        g_running = true;

        // Accept connections
        while (g_running) {
            struct sockaddr_un client_addr;
            socklen_t client_len = sizeof(client_addr);

            int client_fd = accept(g_socket_fd, (struct sockaddr *)&client_addr, &client_len);
            if (client_fd == -1) {
                if (g_running) {
                    NSLog(@"[GridSA] Accept failed");
                }
                continue;
            }

            NSLog(@"[GridSA] Client connected");

            // Handle client in same thread (could use dispatch_async for concurrent handling)
            handle_client_connection(client_fd);

            NSLog(@"[GridSA] Client disconnected");
        }

        // Cleanup
        close(g_socket_fd);
        unlink(socket_path);
        free(socket_path);

        NSLog(@"[GridSA] Daemon thread stopped");
    }
    return NULL;
}

static void start_daemon(void) {
    NSLog(@"[GridSA] Starting daemon...");
    pthread_create(&g_daemon_thread, NULL, &daemon_thread_proc, NULL);
    pthread_detach(g_daemon_thread);
}

static void stop_daemon(void) {
    NSLog(@"[GridSA] Stopping daemon...");
    g_running = false;

    if (g_socket_fd != -1) {
        close(g_socket_fd);
        g_socket_fd = -1;
    }
}

// MARK: - Scripting Addition Entry Point

__attribute__((constructor))
static void osax_load(void) {
    @autoreleasepool {
        NSString *process_name = [[NSProcessInfo processInfo] processName];
        NSLog(@"[GridSA] Loaded into process: %@", process_name);

        // Only run in Dock.app
        if (![process_name isEqualToString:@"Dock"]) {
            NSLog(@"[GridSA] Not running in Dock, skipping initialization");
            return;
        }

        NSLog(@"[GridSA] Initializing in Dock.app");

        // Load SkyLight functions
        if (!load_skylight_functions()) {
            NSLog(@"[GridSA] Failed to initialize - SkyLight functions not available");
            return;
        }

        start_daemon();

        // Register cleanup on exit
        atexit(stop_daemon);
    }
}
