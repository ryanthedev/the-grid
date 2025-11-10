//
// loader.m
// Grid Scripting Addition Loader
//
// Performs Mach port injection to load the Grid SA payload into Dock.app
// This binary must be run as root to inject into system processes.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/thread_act.h>
#import <libproc.h>
#import <sys/sysctl.h>

#include "../shellcode/shellcode.h"

// MARK: - Constants

#define DOCK_PROCESS_NAME "Dock"
#define SOCKET_PATH_FMT "/tmp/grid-sa_%s.socket"
#define SOCKET_WAIT_TIMEOUT 5  // seconds

// MARK: - Utility Functions

/**
 * Get the process ID for a process by name
 */
static pid_t get_process_pid(const char *process_name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size;

    // Get size needed
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
        return 0;
    }

    // Allocate buffer
    struct kinfo_proc *processes = malloc(size);
    if (!processes) {
        return 0;
    }

    // Get process list
    if (sysctl(mib, 4, processes, &size, NULL, 0) < 0) {
        free(processes);
        return 0;
    }

    // Search for our process
    int process_count = size / sizeof(struct kinfo_proc);
    pid_t result_pid = 0;

    for (int i = 0; i < process_count; i++) {
        if (strncmp(processes[i].kp_proc.p_comm, process_name, MAXCOMLEN) == 0) {
            result_pid = processes[i].kp_proc.p_pid;
            break;
        }
    }

    free(processes);
    return result_pid;
}

/**
 * Get current macOS version
 */
static void get_os_version(int *major, int *minor, int *patch) {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    *major = (int)version.majorVersion;
    *minor = (int)version.minorVersion;
    *patch = (int)version.patchVersion;
}

/**
 * Get architecture name
 */
static const char *get_architecture(void) {
#if defined(__x86_64__)
    return "x86_64";
#elif defined(__arm64__)
    return "ARM64";
#else
    return "unknown";
#endif
}

/**
 * Print beautiful status message
 */
static void print_status(const char *icon, const char *message) {
    fprintf(stdout, "%s %s\n", icon, message);
    fflush(stdout);
}

/**
 * Print error message with recovery suggestion
 */
static void print_error(const char *message, const char *suggestion) {
    fprintf(stderr, "❌ %s\n", message);
    if (suggestion) {
        fprintf(stderr, "   💡 %s\n", suggestion);
    }
    fflush(stderr);
}

// MARK: - Mach Injection

/**
 * Verify that injected shellcode has executed by checking for magic value
 * Returns true if magic value detected in register, false otherwise
 */
static bool verify_injection(thread_act_t thread, int timeout_ms) {
    const uint32_t GRID_MAGIC = 0x47524944;  // "GRID" in ASCII
    int attempts = timeout_ms / 20;

    fprintf(stdout, "   Verifying shellcode execution");
    fflush(stdout);

    for (int i = 0; i < attempts; i++) {
#if defined(__x86_64__)
        x86_thread_state64_t state;
        mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;

        kern_return_t kr = thread_get_state(thread, x86_THREAD_STATE64,
                                           (thread_state_t)&state, &count);
        if (kr == KERN_SUCCESS) {
            if (state.__rax == GRID_MAGIC) {
                fprintf(stdout, "\n");
                print_status("✓", "Injection verified (magic value detected in RAX)");
                return true;
            }
        }
#elif defined(__arm64__)
        arm_thread_state64_t state;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;

        kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                           (thread_state_t)&state, &count);
        if (kr == KERN_SUCCESS) {
            if (state.__x[0] == GRID_MAGIC) {
                fprintf(stdout, "\n");
                print_status("✓", "Injection verified (magic value detected in X0)");
                return true;
            }
        }
#endif

        // Print progress dots
        if (i % 5 == 0) {
            fprintf(stdout, ".");
            fflush(stdout);
        }

        usleep(20000);  // 20ms
    }

    fprintf(stdout, "\n");
    print_error("Injection verification failed", "Shellcode may not have executed properly");
    return false;
}

/**
 * Inject shellcode into target process and create execution thread
 */
static bool inject_payload(pid_t target_pid) {
    kern_return_t kr;
    mach_port_t task = MACH_PORT_NULL;
    mach_vm_address_t code_address = 0;
    thread_act_t thread = MACH_PORT_NULL;
    bool success = false;

    int os_major, os_minor, os_patch;
    get_os_version(&os_major, &os_minor, &os_patch);

    print_status("🔍", "Acquiring task port for Dock...");

    // Get task port for target process (requires root)
    kr = task_for_pid(mach_task_self(), target_pid, &task);
    if (kr != KERN_SUCCESS) {
        print_error("Failed to get task port for Dock",
                   "Ensure you're running as root: sudo ./loader");
        print_error("Also check SIP is disabled: csrutil status",
                   "Filesystem Protections and Debugging Restrictions must be disabled");
        return false;
    }

    print_status("✓", "Task port acquired");

    // Select appropriate shellcode for architecture
    const uint8_t *shellcode;
    size_t shellcode_size;

#if defined(__x86_64__)
    shellcode = shellcode_x86_64;
    shellcode_size = shellcode_x86_64_size;
    print_status("📦", "Using x86_64 shellcode");
#elif defined(__arm64__)
    shellcode = shellcode_arm64;
    shellcode_size = shellcode_arm64_size;
    print_status("📦", "Using ARM64 shellcode");
#else
    #error "Unsupported architecture"
#endif

    // Allocate memory in target process for shellcode
    print_status("💾", "Allocating memory in Dock's address space...");

    kr = mach_vm_allocate(task, &code_address, shellcode_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        print_error("Failed to allocate memory in target process", NULL);
        goto cleanup;
    }

    print_status("✓", "Memory allocated");

    // Write shellcode to allocated memory
    print_status("✍️ ", "Writing shellcode...");

    kr = mach_vm_write(task, code_address, (vm_offset_t)shellcode, shellcode_size);
    if (kr != KERN_SUCCESS) {
        print_error("Failed to write shellcode to target process", NULL);
        goto cleanup;
    }

    print_status("✓", "Shellcode written");

    // Make memory executable
    print_status("🔐", "Setting memory permissions...");

    kr = vm_protect(task, code_address, shellcode_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        print_error("Failed to set memory permissions", NULL);
        goto cleanup;
    }

    print_status("✓", "Memory is executable");

    // Create thread to execute shellcode
    // Try multiple methods as macOS 15.6 may block certain APIs
    print_status("🧵", "Creating execution thread...");

#if defined(__x86_64__)
    // x86_64 thread creation
    x86_thread_state64_t state;
    memset(&state, 0, sizeof(state));

    state.__rip = code_address;  // Instruction pointer
    state.__rsp = code_address + shellcode_size - 8;  // Stack pointer (grows down)
    state.__rbp = state.__rsp;  // Base pointer

    // Method 1: Try the old reliable method (create + set + resume)
    fprintf(stdout, "   Attempt 1: thread_create + thread_set_state + thread_resume\n");
    kr = thread_create(task, &thread);
    if (kr == KERN_SUCCESS) {
        kr = thread_set_state(thread, x86_THREAD_STATE64,
                             (thread_state_t)&state,
                             x86_THREAD_STATE64_COUNT);
        if (kr == KERN_SUCCESS) {
            kr = thread_resume(thread);
            if (kr == KERN_SUCCESS) {
                fprintf(stdout, "   ✓ Method 1 succeeded\n");
            } else {
                fprintf(stdout, "   ✗ thread_resume failed: %d (%s)\n", kr, mach_error_string(kr));
            }
        } else {
            fprintf(stdout, "   ✗ thread_set_state failed: %d (%s)\n", kr, mach_error_string(kr));
        }
    } else {
        fprintf(stdout, "   ✗ thread_create failed: %d (%s)\n", kr, mach_error_string(kr));
    }

    // Method 2: If method 1 failed and we're on macOS 14.4+, try thread_create_running
    if (kr != KERN_SUCCESS && (os_major >= 15 || (os_major == 14 && os_minor >= 4))) {
        fprintf(stdout, "   Attempt 2: thread_create_running (atomic)\n");
        if (thread != MACH_PORT_NULL) {
            thread_terminate(thread);
            mach_port_deallocate(mach_task_self(), thread);
            thread = MACH_PORT_NULL;
        }

        kr = thread_create_running(task, x86_THREAD_STATE64,
                                   (thread_state_t)&state,
                                   x86_THREAD_STATE64_COUNT, &thread);
        if (kr == KERN_SUCCESS) {
            fprintf(stdout, "   ✓ Method 2 succeeded\n");
        } else {
            fprintf(stdout, "   ✗ thread_create_running failed: %d (%s)\n", kr, mach_error_string(kr));
        }
    }

#elif defined(__arm64__)
    // ARM64 thread creation
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));

    // Set up thread state
    __darwin_arm_thread_state64_set_pc_fptr(state, (void *)code_address);
    __darwin_arm_thread_state64_set_sp(state, code_address + shellcode_size - 16);
    state.__x[28] = state.__sp;  // Frame pointer (use x28 instead of x29)

    // Method 1: Try the old reliable method (create + set + resume)
    fprintf(stdout, "   Attempt 1: thread_create + thread_set_state + thread_resume\n");
    kr = thread_create(task, &thread);
    if (kr == KERN_SUCCESS) {
        kr = thread_set_state(thread, ARM_THREAD_STATE64,
                             (thread_state_t)&state,
                             ARM_THREAD_STATE64_COUNT);
        if (kr == KERN_SUCCESS) {
            kr = thread_resume(thread);
            if (kr == KERN_SUCCESS) {
                fprintf(stdout, "   ✓ Method 1 succeeded\n");
            } else {
                fprintf(stdout, "   ✗ thread_resume failed: %d (%s)\n", kr, mach_error_string(kr));
            }
        } else {
            fprintf(stdout, "   ✗ thread_set_state failed: %d (%s)\n", kr, mach_error_string(kr));
        }
    } else {
        fprintf(stdout, "   ✗ thread_create failed: %d (%s)\n", kr, mach_error_string(kr));
    }

    // Method 2: If method 1 failed and we're on macOS 14.4+, try thread_create_running
    if (kr != KERN_SUCCESS && (os_major >= 15 || (os_major == 14 && os_minor >= 4))) {
        fprintf(stdout, "   Attempt 2: thread_create_running (atomic)\n");
        if (thread != MACH_PORT_NULL) {
            thread_terminate(thread);
            mach_port_deallocate(mach_task_self(), thread);
            thread = MACH_PORT_NULL;
        }

        kr = thread_create_running(task, ARM_THREAD_STATE64,
                                   (thread_state_t)&state,
                                   ARM_THREAD_STATE64_COUNT, &thread);
        if (kr == KERN_SUCCESS) {
            fprintf(stdout, "   ✓ Method 2 succeeded\n");
        } else {
            fprintf(stdout, "   ✗ thread_create_running failed: %d (%s)\n", kr, mach_error_string(kr));
        }
    }
#endif

    if (kr != KERN_SUCCESS) {
        print_error("All thread creation methods failed", NULL);
        fprintf(stderr, "\n");
        fprintf(stderr, "Diagnostic Information:\n");
        fprintf(stderr, "  Final error code: %d (0x%x)\n", kr, kr);
        fprintf(stderr, "  Error string: %s\n", mach_error_string(kr));
        fprintf(stderr, "  macOS version: %d.%d.%d\n", os_major, os_minor, os_patch);
        fprintf(stderr, "\n");
        fprintf(stderr, "Possible causes:\n");
        fprintf(stderr, "  1. SIP not fully disabled - try: csrutil disable\n");
        fprintf(stderr, "  2. Additional macOS 15+ protections\n");
        fprintf(stderr, "  3. Dock process has special guards\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Try:\n");
        fprintf(stderr, "  • Full SIP disable: Boot to Recovery, run 'csrutil disable'\n");
        fprintf(stderr, "  • Check current SIP: csrutil status\n");
        fprintf(stderr, "  • Reboot after changing SIP settings\n");
        fprintf(stderr, "\n");
        goto cleanup;
    }

    print_status("✓", "Thread created and running");

    // Verify that shellcode actually executed
    fprintf(stdout, "\n");
    if (!verify_injection(thread, 200)) {
        print_error("Shellcode did not execute", "Thread was created but payload didn't load");
        fprintf(stderr, "This may indicate:\n");
        fprintf(stderr, "  • Shellcode incompatibility with this macOS version\n");
        fprintf(stderr, "  • Missing libraries or symbols\n");
        fprintf(stderr, "  • Check Console.app for crash logs\n");
        fprintf(stderr, "\n");
        goto cleanup;
    }

    success = true;

cleanup:
    if (task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), task);
    }
    if (thread != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), thread);
    }

    return success;
}

/**
 * Wait for payload to create its socket
 */
static bool wait_for_socket(const char *socket_path, int timeout_seconds) {
    print_status("⏳", "Waiting for payload to initialize...");

    for (int i = 0; i < timeout_seconds * 10; i++) {
        if (access(socket_path, F_OK) == 0) {
            print_status("✓", "Socket created successfully");
            return true;
        }
        usleep(100000);  // 100ms
    }

    return false;
}

// MARK: - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Print banner
        fprintf(stdout, "\n");
        fprintf(stdout, "╔═══════════════════════════════════════╗\n");
        fprintf(stdout, "║   Grid Scripting Addition Loader     ║\n");
        fprintf(stdout, "╚═══════════════════════════════════════╝\n");
        fprintf(stdout, "\n");

        // Check if running as root
        if (getuid() != 0) {
            print_error("Must run as root", "Usage: sudo ./loader");
            return 1;
        }

        // Get system info
        int os_major, os_minor, os_patch;
        get_os_version(&os_major, &os_minor, &os_patch);

        fprintf(stdout, "System Information:\n");
        fprintf(stdout, "  macOS Version:  %d.%d.%d\n", os_major, os_minor, os_patch);
        fprintf(stdout, "  Architecture:   %s\n", get_architecture());
        fprintf(stdout, "\n");

        // Find Dock process
        print_status("🔍", "Looking for Dock process...");

        pid_t dock_pid = get_process_pid(DOCK_PROCESS_NAME);
        if (dock_pid == 0) {
            print_error("Could not find Dock process", "Is Dock running?");
            return 1;
        }

        fprintf(stdout, "   Found Dock with PID: %d\n", dock_pid);

        // Perform injection
        fprintf(stdout, "\n");
        print_status("🚀", "Injecting payload into Dock...");

        if (!inject_payload(dock_pid)) {
            print_error("Injection failed", NULL);
            return 1;
        }

        // Build socket path
        const char *username = getenv("SUDO_USER");
        if (!username) {
            username = getenv("USER");
        }
        if (!username) {
            username = "unknown";
        }

        char socket_path[256];
        snprintf(socket_path, sizeof(socket_path), SOCKET_PATH_FMT, username);

        // Wait for socket to appear
        fprintf(stdout, "\n");
        if (!wait_for_socket(socket_path, SOCKET_WAIT_TIMEOUT)) {
            print_error("Socket not created within timeout",
                       "Check Console.app for [GridSA] logs from Dock process");
            return 1;
        }

        // Success!
        fprintf(stdout, "\n");
        fprintf(stdout, "╔═══════════════════════════════════════╗\n");
        fprintf(stdout, "║         🎉 SUCCESS! 🎉                ║\n");
        fprintf(stdout, "╚═══════════════════════════════════════╝\n");
        fprintf(stdout, "\n");
        fprintf(stdout, "Grid SA is loaded and running\n");
        fprintf(stdout, "Socket: %s\n", socket_path);
        fprintf(stdout, "\n");

        return 0;
    }
}
