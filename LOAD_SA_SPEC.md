# Complete Specification: yabai Scripting Addition (load-sa)

## Overview

The scripting addition is a code injection mechanism that injects a dynamic library into Dock.app to gain elevated privileges for operations impossible via the Accessibility API alone.

## 1. System Requirements

### macOS Security Settings
- **SIP Flags**: Must disable specific protections:
  - `CSR_ALLOW_UNRESTRICTED_FS` (0x02) - Filesystem protections
  - `CSR_ALLOW_TASK_FOR_PID` (0x04) - Process debugging
- **ARM64 Additional**: Requires nvram boot-arg `-arm64e_preview_abi`
- **Execution**: Must run as root

### Version Support
- **x86_64**: macOS 11.0+ (Big Sur through Sequoia)
- **ARM64**: macOS 12.0+ (Monterey through Tahoe 26.0+)

## 2. Installation Structure

```
/Library/ScriptingAdditions/yabai.osax/
├── Contents/
│   ├── Info.plist              # osax metadata
│   ├── MacOS/
│   │   └── loader              # Injection binary (universal)
│   └── Resources/
│       └── payload.bundle/
│           ├── Contents/
│           │   ├── Info.plist  # Payload metadata
│           │   └── MacOS/
│           │       └── payload # Injected library (universal)
```

**Version**: Currently `"2.1.23"` (defined in `src/osax/common.h`)

## 3. Injection Process

### Step 1: Locate Target Process
```objectivec
NSArray *list = [NSRunningApplication
    runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
```
- Find running Dock.app instance
- Verify it's fully launched
- Extract PID

### Step 2: Acquire Task Port
```c
task_for_pid(mach_task_self(), pid, &task)
```
- Requires disabled SIP (CSR_ALLOW_TASK_FOR_PID)
- Returns Mach task port for memory/thread manipulation

### Step 3: Allocate Remote Memory

**Stack Segment** (16KB, RW):
```c
mach_vm_allocate(task, &stack, 16384, VM_FLAGS_ANYWHERE);
vm_protect(task, stack, 16384, TRUE, VM_PROT_READ | VM_PROT_WRITE);
```

**Code Segment** (RX):
```c
mach_vm_allocate(task, &code, sizeof(shellcode), VM_FLAGS_ANYWHERE);
vm_protect(task, code, sizeof(shellcode), FALSE, VM_PROT_EXECUTE | VM_PROT_READ);
```

### Step 4: Inject Shellcode

**Shellcode Purpose**: Spawn thread that calls `dlopen()` on payload

**x86_64 Shellcode Structure**:
```c
// Write shellcode to remote memory
mach_vm_write(task, code, (vm_offset_t)shell_code, sizeof(shell_code));

// Prepare registers
x86_thread_state64_t state = {};
state.__rip = code;                    // Instruction pointer
state.__rsp = stack + (stack_size/2);  // Stack pointer

// Create running thread
thread_create_running(task, x86_THREAD_STATE64,
                     (thread_state_t)&state, ...);
```

**ARM64 Shellcode Structure**:
```c
// Write shellcode to remote memory
mach_vm_write(task, code, (vm_offset_t)shell_code, sizeof(shell_code));

// Prepare registers with pointer authentication
arm_thread_state64_t state = {};
__darwin_arm_thread_state64_set_pc_fptr(state,
    ptrauth_sign_unauthenticated((void*)code, ptrauth_key_asia, 0));
__darwin_arm_thread_state64_set_sp(state, stack + (stack_size/2));

// Version-specific thread creation
if (macOS >= 14.4) {
    thread_create_running(...);
} else {
    thread_create(...);
    thread_set_state(...);
    thread_resume(...);
}
```

**Shellcode Actions**:
1. Call `pthread_create_from_mach_thread()` to spawn proper pthread
2. New thread calls `dlopen("/Library/.../payload.bundle/Contents/MacOS/payload", RTLD_NOW)`
3. Set magic value `0x79616265` ("yabe") in register for verification

### Step 5: Verification
```c
// Poll for magic value (200ms timeout, 10 attempts)
for (int i = 0; i < 10; i++) {
    thread_get_state(thread, ...);
    if (register_value == 0x79616265) {  // Success!
        return 0;
    }
    usleep(20000);  // Wait 20ms
}
```

## 4. Payload Initialization

### Constructor Entry Point
```objectivec
__attribute__((constructor))
void load_payload(void) {
    const char *user = getenv("USER");
    char socket_file[255];
    snprintf(socket_file, sizeof(socket_file),
             "/tmp/yabai-sa_%s.socket", user);

    if (start_daemon(socket_file)) {
        NSLog(@"[yabai-sa] now listening..");
    }
}
```

### Internal Structure Discovery

**Technique**: Pattern matching in Dock.app binary to find internal APIs

**Required Structures**:
- `dock_spaces` - Space management object
- `dp_desktop_picture_manager` - Desktop wallpaper manager
- `add_space_fp` - Function pointer to create space
- `remove_space_fp` - Function pointer to destroy space
- `move_space_fp` - Function pointer to move space
- `set_front_window_fp` - Function pointer to focus window
- `animation_time_addr` - Animation timing (patched to 0 for instant animations)

**Pattern Matching Algorithm**:
```c
uint64_t hex_find_seq(uint64_t start_addr, const char *hex_pattern) {
    // 1. Parse hex pattern (supports wildcards '??')
    // 2. Search memory byte-by-byte for match
    // 3. Return address of match or 0
}
```

**x86_64 Example** (Sequoia 15.x):
```c
// Pattern for dock_spaces pointer
const char *pattern = "?? ?? ?? 00 48 8B 38 48 8B 35 ?? ?? ?? 00 89 DA...";
uint64_t addr = hex_find_seq(baseaddr + 0x1234000, pattern);
int32_t offset = *(int32_t*)addr;
dock_spaces = [(*(id*)(addr + offset + 0x4)) retain];
```

**ARM64 Example** (Sequoia 15.x):
```c
// Pattern uses ADRP + ADD instruction encoding
uint64_t addr = hex_find_seq(baseaddr + offset, pattern);
uint64_t decoded_offset = decode_adrp_add(addr, addr - baseaddr);
dock_spaces = [(*(id*)(baseaddr + decoded_offset)) retain];
```

**decode_adrp_add() Function**:
```c
uint64_t decode_adrp_add(uint64_t addr, uint64_t offset) {
    uint32_t adrp_inst = *(uint32_t*)addr;
    uint32_t add_inst = *(uint32_t*)(addr + 4);

    // Extract ADRP immediate (21 bits)
    uint64_t immhi = (adrp_inst >> 5) & 0x7FFFF;
    uint64_t immlo = (adrp_inst >> 29) & 0x3;
    int64_t adrp_imm = ((immhi << 2) | immlo) << 12;

    // Extract ADD immediate (12 bits)
    uint64_t add_imm = (add_inst >> 10) & 0xFFF;

    // Calculate PC-relative address
    uint64_t page = (offset & ~0xFFF) + adrp_imm;
    return page + add_imm;
}
```

### Version-Specific Patterns

Each macOS version requires different patterns and offsets:

```c
uint64_t get_dock_spaces_offset(NSOperatingSystemVersion v) {
    if (v.majorVersion == 15) return 0x1234000;  // Sequoia
    if (v.majorVersion == 14) return 0x1200000;  // Sonoma
    // ... etc
}

const char *get_dock_spaces_pattern(NSOperatingSystemVersion v) {
    if (v.majorVersion == 15) return "48 8B 38 48 8B 35...";
    if (v.majorVersion == 14) return "48 8B 3D ?? ?? ??...";
    // ... etc
}
```

## 5. Communication Protocol

### Socket Setup

**Path**: `/tmp/yabai-sa_{username}.socket`

**Server** (Payload in Dock.app):
```c
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
snprintf(addr.sun_path, sizeof(addr.sun_path),
         "/tmp/yabai-sa_%s.socket", user);

int sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
unlink(addr.sun_path);
bind(sockfd, (struct sockaddr*)&addr, sizeof(addr));
chmod(addr.sun_path, 0600);
listen(sockfd, SOMAXCONN);

// Accept connections on background thread
pthread_create(&thread, NULL, &handle_connection, NULL);
```

**Client** (yabai):
```c
int sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
struct sockaddr_un addr = { .sun_family = AF_UNIX };
snprintf(addr.sun_path, sizeof(addr.sun_path), socket_path);
connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
```

### Message Format

**Wire Protocol**:
```
[2-byte length (int16_t)][1-byte opcode][variable payload]
```

**Opcodes**:
```c
enum sa_opcode {
    SA_OPCODE_HANDSHAKE             = 0x01,
    SA_OPCODE_SPACE_FOCUS           = 0x02,
    SA_OPCODE_SPACE_CREATE          = 0x03,
    SA_OPCODE_SPACE_DESTROY         = 0x04,
    SA_OPCODE_SPACE_MOVE            = 0x05,
    SA_OPCODE_WINDOW_MOVE           = 0x06,
    SA_OPCODE_WINDOW_OPACITY        = 0x07,
    SA_OPCODE_WINDOW_OPACITY_FADE   = 0x08,
    SA_OPCODE_WINDOW_LAYER          = 0x09,
    SA_OPCODE_WINDOW_STICKY         = 0x0A,
    SA_OPCODE_WINDOW_SHADOW         = 0x0B,
    SA_OPCODE_WINDOW_FOCUS          = 0x0C,
    SA_OPCODE_WINDOW_SCALE          = 0x0D,
    SA_OPCODE_WINDOW_SWAP_PROXY_IN  = 0x0E,
    SA_OPCODE_WINDOW_SWAP_PROXY_OUT = 0x0F,
    SA_OPCODE_WINDOW_ORDER          = 0x10,
    SA_OPCODE_WINDOW_ORDER_IN       = 0x11,
    SA_OPCODE_WINDOW_LIST_TO_SPACE  = 0x12,
    SA_OPCODE_WINDOW_TO_SPACE       = 0x13,
};
```

### Serialization (Sender)

```c
// Initialize buffer
char bytes[0x1000];
int16_t length = 1 + sizeof(int16_t);  // opcode + length prefix

// Pack values
memcpy(bytes + length, &value1, sizeof(value1));
length += sizeof(value1);
memcpy(bytes + length, &value2, sizeof(value2));
length += sizeof(value2);

// Send
*(int16_t*)bytes = length - sizeof(int16_t);  // Write length
bytes[sizeof(int16_t)] = opcode;              // Write opcode
send(sockfd, bytes, length, 0);
recv(sockfd, &dummy, 1, 0);  // Wait for ACK
```

### Deserialization (Receiver)

```c
char buffer[BUFSIZ];
recv(sockfd, buffer, sizeof(buffer), 0);

int16_t length = *(int16_t*)buffer;
char opcode = buffer[sizeof(int16_t)];
char *message = buffer + sizeof(int16_t) + 1;

// Unpack values
memcpy(&value1, message, sizeof(value1));
message += sizeof(value1);
memcpy(&value2, message, sizeof(value2));
message += sizeof(value2);

// Send ACK
send(sockfd, "X", 1, 0);
```

### Example: Focus Space

**Client**:
```c
bool scripting_addition_focus_space(uint64_t sid) {
    char bytes[0x1000];
    int16_t length = 1 + sizeof(int16_t);

    // Pack space ID
    memcpy(bytes + length, &sid, sizeof(sid));
    length += sizeof(sid);

    // Send
    *(int16_t*)bytes = length - sizeof(int16_t);
    bytes[sizeof(int16_t)] = SA_OPCODE_SPACE_FOCUS;

    return send_and_wait(bytes, length);
}
```

**Server**:
```c
void do_space_focus(char *message) {
    uint64_t sid;
    memcpy(&sid, message, sizeof(sid));

    // Call Dock.app internal API
    // [dock_spaces switchToSpace:sid];
}
```

## 6. Handshake & Capability Negotiation

### Handshake Request
```c
// Client sends 3 bytes
char bytes[3] = { 0x01, 0x00, SA_OPCODE_HANDSHAKE };
send(sockfd, bytes, 3, 0);
```

### Handshake Response

**Response Format**:
```
[null-terminated version string][4-byte capability flags]
```

**Server Implementation**:
```c
void do_handshake(int sockfd) {
    uint32_t attrib = 0;

    // Set capability bits
    if (dock_spaces != nil)                attrib |= 0x01;
    if (dp_desktop_picture_manager != nil) attrib |= 0x02;
    if (add_space_fp)                      attrib |= 0x04;
    if (remove_space_fp)                   attrib |= 0x08;
    if (move_space_fp)                     attrib |= 0x10;
    if (set_front_window_fp)               attrib |= 0x20;
    if (animation_time_addr)               attrib |= 0x40;

    char bytes[BUFSIZ];
    int version_len = strlen("2.1.23");

    memcpy(bytes, "2.1.23", version_len);
    bytes[version_len] = '\0';
    memcpy(bytes + version_len + 1, &attrib, sizeof(uint32_t));

    send(sockfd, bytes, version_len + 1 + sizeof(uint32_t) + 1, 0);
}
```

**Client Parsing**:
```c
char rsp[BUFSIZ];
int len = recv(sockfd, rsp, sizeof(rsp) - 1, 0);

// Find null terminator
char *zero = rsp;
while (*zero != '\0') ++zero;

// Extract version and capabilities
char version[256];
uint32_t attrib;
memcpy(version, rsp, zero - rsp + 1);
memcpy(&attrib, zero + 1, sizeof(uint32_t));
```

### Capability Flags

```c
#define OSAX_ATTRIB_DOCK_SPACES   0x01  // Space management works
#define OSAX_ATTRIB_DPPM          0x02  // Desktop pictures work
#define OSAX_ATTRIB_ADD_SPACE     0x04  // Can create spaces
#define OSAX_ATTRIB_REM_SPACE     0x08  // Can destroy spaces
#define OSAX_ATTRIB_MOV_SPACE     0x10  // Can move spaces
#define OSAX_ATTRIB_SET_WINDOW    0x20  // Can focus windows
#define OSAX_ATTRIB_ANIM_TIME     0x40  // Animation patching works

#define OSAX_ATTRIB_ALL           0x7F  // All capabilities
```

### Validation

```c
// Version must match exactly
if (!strcmp(version, "2.1.23")) {
    // All capabilities must be present
    if ((attrib & OSAX_ATTRIB_ALL) == OSAX_ATTRIB_ALL) {
        return SUCCESS;  // Fully operational
    }
    return ERROR_UNSUPPORTED_OS;  // Pattern matching failed
}
return ERROR_VERSION_MISMATCH;  // Need to reinstall/restart Dock
```

## 7. Opcode Implementations

### Space Operations

**SA_OPCODE_SPACE_CREATE** (0x03):
```c
// Payload: [uint64_t display_id]
void do_space_create(char *message) {
    uint64_t did;
    memcpy(&did, message, sizeof(did));

    // Call: add_space_fp(dock_spaces, display_id)
    typedef void (*add_space_func)(id, uint64_t);
    ((add_space_func)add_space_fp)(dock_spaces, did);
}
```

**SA_OPCODE_SPACE_DESTROY** (0x04):
```c
// Payload: [uint64_t space_id]
void do_space_destroy(char *message) {
    uint64_t sid;
    memcpy(&sid, message, sizeof(sid));

    // Call: remove_space_fp(dock_spaces, space_id)
    typedef void (*remove_space_func)(id, uint64_t);
    ((remove_space_func)remove_space_fp)(dock_spaces, sid);
}
```

**SA_OPCODE_SPACE_MOVE** (0x05):
```c
// Payload: [uint64_t space_id][uint64_t dest_space_id]
void do_space_move(char *message) {
    uint64_t src_sid, dst_sid;
    memcpy(&src_sid, message, sizeof(src_sid));
    message += sizeof(src_sid);
    memcpy(&dst_sid, message, sizeof(dst_sid));

    // Call: move_space_fp(dock_spaces, src_sid, dst_sid)
    typedef void (*move_space_func)(id, uint64_t, uint64_t);
    ((move_space_func)move_space_fp)(dock_spaces, src_sid, dst_sid);
}
```

### Window Operations

**SA_OPCODE_WINDOW_OPACITY** (0x07):
```c
// Payload: [uint32_t wid][float opacity]
void do_window_opacity(char *message) {
    uint32_t wid;
    float opacity;
    memcpy(&wid, message, sizeof(wid));
    message += sizeof(wid);
    memcpy(&opacity, message, sizeof(opacity));

    // SkyLight API
    SLSSetWindowOpacity(_connection, wid, opacity);
}
```

**SA_OPCODE_WINDOW_OPACITY_FADE** (0x08):
```c
// Payload: [uint32_t wid][float opacity][float duration]
void do_window_opacity_fade(char *message) {
    uint32_t wid;
    float opacity, duration;
    memcpy(&wid, message, sizeof(wid));
    message += sizeof(wid);
    memcpy(&opacity, message, sizeof(opacity));
    message += sizeof(opacity);
    memcpy(&duration, message, sizeof(duration));

    // Store fade info and animate on background thread
    window_fade_entry *entry = malloc(sizeof(window_fade_entry));
    entry->wid = wid;
    entry->opacity = opacity;
    entry->duration = duration;

    table_add(&window_fade_table, &wid, entry);
    pthread_create(&entry->thread, NULL, window_fade_thread, entry);
}
```

**SA_OPCODE_WINDOW_LAYER** (0x09):
```c
// Payload: [uint32_t wid][int layer]
// layer: -1 (below), 0 (normal), 1 (above)
void do_window_layer(char *message) {
    uint32_t wid;
    int layer;
    memcpy(&wid, message, sizeof(wid));
    message += sizeof(wid);
    memcpy(&layer, message, sizeof(layer));

    int sublevel = (layer == -1) ? -1 : (layer == 1) ? 1 : 0;
    SLSSetWindowSubLevel(_connection, wid, sublevel);
}
```

**SA_OPCODE_WINDOW_STICKY** (0x0A):
```c
// Payload: [uint32_t wid][int sticky]
void do_window_sticky(char *message) {
    uint32_t wid;
    int sticky;
    memcpy(&wid, message, sizeof(wid));
    message += sizeof(wid);
    memcpy(&sticky, message, sizeof(sticky));

    uint64_t tags[2] = { 0, 0 };
    tags[0] = sticky ? kCGSAllSpacesMask : 0;
    SLSSetWindowTags(_connection, wid, tags, 64);
}
```

**SA_OPCODE_WINDOW_FOCUS** (0x0C):
```c
// Payload: [uint32_t wid]
void do_window_focus(char *message) {
    uint32_t wid;
    memcpy(&wid, message, sizeof(wid));

    // Call: set_front_window_fp(dock_spaces, wid)
    typedef void (*set_front_window_func)(id, uint32_t);
    ((set_front_window_func)set_front_window_fp)(dock_spaces, wid);
}
```

**SA_OPCODE_WINDOW_TO_SPACE** (0x13):
```c
// Payload: [uint32_t wid][uint64_t space_id]
void do_window_to_space(char *message) {
    uint32_t wid;
    uint64_t sid;
    memcpy(&wid, message, sizeof(wid));
    message += sizeof(wid);
    memcpy(&sid, message, sizeof(sid));

    // Move window to space
    CFArrayRef window_list = CFArrayCreate(NULL, (void*)&wid, 1, NULL);
    SLSMoveWindowsToManagedSpace(_connection, window_list, sid);
    CFRelease(window_list);
}
```

## 8. Build Process

### Payload Binary
```bash
# Compile universal payload (x86_64 + arm64e)
xcrun clang src/osax/payload.m -shared -fPIC -O3 \
    -mmacosx-version-min=11.0 \
    -arch x86_64 -arch arm64e \
    -framework Foundation -framework Carbon -framework SkyLight \
    -o src/osax/payload

# Convert to C byte array
xxd -i -a src/osax/payload src/osax/payload_bin.c
```

### Loader Binary
```bash
# Compile universal loader
xcrun clang src/osax/loader.m -O3 \
    -mmacosx-version-min=11.0 \
    -arch x86_64 -arch arm64e \
    -framework Cocoa \
    -o src/osax/loader

# Convert to C byte array
xxd -i -a src/osax/loader src/osax/loader_bin.c
```

### Embedding in Main Binary
```bash
# Generate osax sources (includes payload_bin.c and loader_bin.c)
make $(OSAX_SRC)

# Compile main binary with embedded sections
clang src/manifest.m -o bin/yabai \
    -sectcreate __TEXT __info_plist src/osax/Info.plist \
    -sectcreate __TEXT __payload src/osax/payload_bin.c \
    -sectcreate __TEXT __loader src/osax/loader_bin.c
```

### Extraction at Runtime
```c
unsigned long payload_size;
unsigned char *payload_data = getsectiondata(
    mach_header, "__TEXT", "__payload", &payload_size);

// Write to temporary file or use directly
FILE *f = fopen("/tmp/payload", "wb");
fwrite(payload_data, 1, payload_size, f);
fclose(f);
```

## 9. Error Handling

### SIP Detection
```c
bool scripting_addition_is_sip_friendly(void) {
    uint32_t flags = 0;

    if (csr_get_active_config(&flags) == 0) {
        return (flags & CSR_ALLOW_UNRESTRICTED_FS) &&
               (flags & CSR_ALLOW_TASK_FOR_PID);
    }
    return false;
}
```

### ARM64e ABI Detection
```c
#ifdef __arm64__
bool scripting_addition_is_arm64e_enabled(void) {
    char buf[1024];
    size_t size = sizeof(buf);

    if (sysctlbyname("kern.bootargs", buf, &size, NULL, 0) == 0) {
        return strstr(buf, "-arm64e_preview_abi") != NULL;
    }
    return false;
}
#endif
```

### Failure Modes

1. **SIP Protected**:
   - Error: "System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!"
   - Action: User must disable SIP flags and reboot

2. **Not Root**:
   - Error: "yabai-sa must be run as root!"
   - Action: Run with `sudo`

3. **ARM64e ABI Missing**:
   - Error: "missing required nvram boot-arg '-arm64e_preview_abi'!"
   - Action: User must set nvram boot-arg and reboot

4. **Dock.app Not Found**:
   - Error: "could not locate Dock.app process!"
   - Action: Wait for Dock.app to launch

5. **Task Port Denied**:
   - Error: "could not retrieve task port for pid: %d"
   - Action: Check SIP settings

6. **Injection Failed**:
   - Error: "failed to inject payload into Dock.app!"
   - Action: Check system logs, verify binary integrity

7. **Pattern Matching Failed**:
   - Capability flags = 0 (or partial)
   - Error: "payload doesn't support this macOS version!"
   - Action: Update yabai or report issue

8. **Version Mismatch**:
   - Error: "payload is outdated, updating.." or "..restarting Dock.app.."
   - Action: Automatic reinstall or Dock restart

### Recovery

**Auto-Update**:
```c
if (version_mismatch) {
    if (!is_latest_installed) {
        scripting_addition_install();  // Reinstall
    } else {
        scripting_addition_restart_dock();  // Just restart
    }
}
```

**Manual Recovery**:
```bash
# Uninstall
sudo yabai --uninstall-sa

# Reinstall
sudo yabai --load-sa
```

**Dock Restart**:
```bash
killall Dock
```

## 10. Security Considerations

### Code Signing
- Payload must be ad-hoc signed: `codesign -s - -f payload`
- Loader must be ad-hoc signed: `codesign -s - -f loader`
- No Apple Developer certificate required (SIP disabled)

### Permissions
- Socket file: `chmod 0600` (owner-only access)
- Installation directory: `/Library/ScriptingAdditions/` (requires root)
- Runtime: Runs as Dock.app user (`_windowserver`)

### Attack Surface
- Unix socket local only (AF_UNIX)
- No network exposure
- Socket path includes username for isolation
- Validation of opcodes and payload sizes
- No arbitrary code execution from socket
- Fixed message format prevents injection attacks

### Memory Safety
- Stack allocation: 16KB fixed size
- Shellcode: Fixed size, no dynamic allocation
- Pattern matching: Bounded search ranges
- No buffer overflows in message handling

## 11. Implementation Reference

### Key Files in yabai

| File | Purpose |
|------|---------|
| `src/yabai.c:218-219` | Command entry point (`--load-sa`) |
| `src/sa.m` | Main SA management (install, load, handshake) |
| `src/osax/loader.m` | Injection implementation |
| `src/osax/payload.m` | Injected code (main payload) |
| `src/osax/x64_payload.m` | x86_64 patterns and helpers |
| `src/osax/arm64_payload.m` | ARM64 patterns and helpers |
| `src/osax/common.h` | Shared constants (opcodes, version, flags) |

### Critical Functions

**Injection** (`src/osax/loader.m`):
- `main()` - Entry point, locates Dock.app
- `mach_loader_inject_payload()` - Core injection logic
- Architecture-specific shellcode arrays

**Pattern Matching** (`src/osax/payload.m`):
- `hex_find_seq()` - Search for byte patterns
- `init_instances()` - Find Dock.app internal structures
- `decode_adrp_add()` - ARM64 instruction decoder

**Communication** (`src/osax/payload.m`):
- `start_daemon()` - Unix socket server setup
- `handle_connection()` - Connection handler thread
- `handle_message()` - Opcode dispatcher
- `do_*()` functions - Individual opcode handlers

**Client API** (`src/sa.m`):
- `scripting_addition_load()` - Main load function
- `scripting_addition_perform_validation()` - Handshake and version check
- `scripting_addition_*()` functions - Per-opcode client functions

## 12. Swift Implementation Guidelines

### Mach APIs
```swift
import Darwin.Mach

func injectPayload(pid: pid_t, payloadPath: String) throws {
    var task: mach_port_t = 0
    guard task_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS else {
        throw InjectionError.taskPortFailed
    }

    var stack: mach_vm_address_t = 0
    let stackSize: mach_vm_size_t = 16384
    guard mach_vm_allocate(task, &stack, stackSize, VM_FLAGS_ANYWHERE) == KERN_SUCCESS else {
        throw InjectionError.allocationFailed
    }

    guard vm_protect(task, stack, stackSize, 1,
                     VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS else {
        throw InjectionError.protectionFailed
    }

    var code: mach_vm_address_t = 0
    let shellcode = createShellcode(payloadPath: payloadPath)
    guard mach_vm_allocate(task, &code, mach_vm_size_t(shellcode.count),
                          VM_FLAGS_ANYWHERE) == KERN_SUCCESS else {
        throw InjectionError.allocationFailed
    }

    // Continue with injection...
}
```

### Pattern Matching
```swift
func hexFindSeq(startAddress: UInt64, pattern: String, searchRange: Int = 0x100000) -> UInt64 {
    let patternBytes = parseHexPattern(pattern)

    guard let memory = UnsafeRawPointer(bitPattern: UInt(startAddress)) else {
        return 0
    }

    for offset in 0..<searchRange {
        if matchesPattern(at: memory.advanced(by: offset), pattern: patternBytes) {
            return startAddress + UInt64(offset)
        }
    }
    return 0
}

func parseHexPattern(_ pattern: String) -> [(UInt8?, Bool)] {
    let components = pattern.split(separator: " ")
    return components.map { component in
        if component == "??" {
            return (nil, true)  // Wildcard
        } else {
            return (UInt8(component, radix: 16), false)
        }
    }
}

func matchesPattern(at pointer: UnsafeRawPointer, pattern: [(UInt8?, Bool)]) -> Bool {
    for (index, (byte, isWildcard)) in pattern.enumerated() {
        if isWildcard { continue }
        if let expectedByte = byte {
            let actualByte = pointer.load(fromByteOffset: index, as: UInt8.self)
            if actualByte != expectedByte {
                return false
            }
        }
    }
    return true
}
```

### ARM64 Instruction Decoding
```swift
#if arch(arm64)
func decodeAdrpAdd(address: UInt64, offset: UInt64) -> UInt64 {
    guard let ptr = UnsafePointer<UInt32>(bitPattern: UInt(address)) else {
        return 0
    }

    let adrpInst = ptr.pointee
    let addInst = ptr.advanced(by: 1).pointee

    // Extract ADRP immediate (21 bits)
    let immhi = UInt64((adrpInst >> 5) & 0x7FFFF)
    let immlo = UInt64((adrpInst >> 29) & 0x3)
    let adrpImm = Int64(((immhi << 2) | immlo) << 12)

    // Extract ADD immediate (12 bits)
    let addImm = UInt64((addInst >> 10) & 0xFFF)

    // Calculate PC-relative address
    let page = (offset & ~0xFFF) &+ UInt64(bitPattern: adrpImm)
    return page &+ addImm
}
#endif
```

### Socket Communication
```swift
import Foundation

class ScriptingAdditionClient {
    private let socketPath: String

    init(username: String) {
        self.socketPath = "/tmp/yabai-sa_\(username).socket"
    }

    func connect() throws -> Int32 {
        let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockfd >= 0 else {
            throw SAError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            _ = socketPath.withCString { path in
                strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self),
                       path, ptr.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sockfd, sockaddrPtr, addrLen)
            }
        }) == 0 else {
            close(sockfd)
            throw SAError.connectionFailed
        }

        return sockfd
    }

    func focusSpace(_ sid: UInt64) throws {
        let sockfd = try connect()
        defer { close(sockfd) }

        var message = Data()
        var length = Int16(1 + MemoryLayout<UInt64>.size)
        message.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })
        message.append(0x02)  // SA_OPCODE_SPACE_FOCUS
        message.append(contentsOf: withUnsafeBytes(of: sid) { Data($0) })

        try message.withUnsafeBytes { ptr in
            guard send(sockfd, ptr.baseAddress!, message.count, 0) == message.count else {
                throw SAError.sendFailed
            }
        }

        var ack: UInt8 = 0
        guard recv(sockfd, &ack, 1, 0) == 1 else {
            throw SAError.receiveFailed
        }
    }

    func handshake() throws -> (version: String, capabilities: UInt32) {
        let sockfd = try connect()
        defer { close(sockfd) }

        var request: [UInt8] = [0x01, 0x00, 0x01]  // SA_OPCODE_HANDSHAKE
        guard send(sockfd, &request, 3, 0) == 3 else {
            throw SAError.sendFailed
        }

        var response = [UInt8](repeating: 0, count: 256)
        guard recv(sockfd, &response, response.count, 0) > 0 else {
            throw SAError.receiveFailed
        }

        // Find null terminator
        guard let nullIndex = response.firstIndex(of: 0) else {
            throw SAError.invalidResponse
        }

        let version = String(cString: response)
        let capabilitiesData = Data(response[(nullIndex + 1)...(nullIndex + 4)])
        let capabilities = capabilitiesData.withUnsafeBytes {
            $0.load(as: UInt32.self)
        }

        return (version, capabilities)
    }
}

enum SAError: Error {
    case socketCreationFailed
    case connectionFailed
    case sendFailed
    case receiveFailed
    case invalidResponse
}
```

### Pointer Authentication (ARM64)
```swift
#if arch(arm64)
import ptrauth

func signCodePointer(_ ptr: UnsafeRawPointer) -> UInt64 {
    let signed = ptrauth_sign_unauthenticated(
        ptr,
        .ptrauth_key_asia,
        0
    )
    return UInt64(UInt(bitPattern: signed))
}

func createSignedThreadState(pc: UInt64, sp: UInt64) -> arm_thread_state64_t {
    var state = arm_thread_state64_t()

    let pcPtr = UnsafeRawPointer(bitPattern: UInt(pc))!
    __darwin_arm_thread_state64_set_pc_fptr(&state,
        ptrauth_sign_unauthenticated(pcPtr, .ptrauth_key_asia, 0))
    __darwin_arm_thread_state64_set_sp(&state, sp)

    return state
}
#endif
```

### Shellcode Generation
```swift
#if arch(x86_64)
func createX64Shellcode(payloadPath: String) -> [UInt8] {
    // x86_64 shellcode to call dlopen
    // This is a simplified example - actual shellcode is more complex
    var shellcode: [UInt8] = [
        0x48, 0x83, 0xEC, 0x08,  // sub rsp, 8
        // ... full shellcode here
    ]
    return shellcode
}
#elseif arch(arm64)
func createARM64Shellcode(payloadPath: String) -> [UInt8] {
    // ARM64 shellcode to call dlopen
    var shellcode: [UInt8] = [
        0xFD, 0x7B, 0xBF, 0xA9,  // stp x29, x30, [sp, #-16]!
        // ... full shellcode here
    ]
    return shellcode
}
#endif
```

## 13. Testing & Validation

### Prerequisites Check
```swift
func validatePrerequisites() throws {
    // Check if running as root
    guard getuid() == 0 else {
        throw ValidationError.notRoot
    }

    // Check SIP status
    var config: UInt32 = 0
    guard csr_get_active_config(&config) == 0 else {
        throw ValidationError.sipCheckFailed
    }

    let requiredFlags: UInt32 = 0x02 | 0x04  // CSR_ALLOW_UNRESTRICTED_FS | CSR_ALLOW_TASK_FOR_PID
    guard (config & requiredFlags) == requiredFlags else {
        throw ValidationError.sipEnabled
    }

    #if arch(arm64)
    // Check ARM64e ABI
    var bootargs = [CChar](repeating: 0, count: 1024)
    var size = bootargs.count
    guard sysctlbyname("kern.bootargs", &bootargs, &size, nil, 0) == 0 else {
        throw ValidationError.bootargsCheckFailed
    }

    let bootargsStr = String(cString: bootargs)
    guard bootargsStr.contains("-arm64e_preview_abi") else {
        throw ValidationError.arm64eAbiMissing
    }
    #endif
}
```

### Verification After Injection
```swift
func verifyInjection(thread: thread_t, timeoutMs: Int = 200) throws {
    let attempts = timeoutMs / 20

    for _ in 0..<attempts {
        #if arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)

        guard thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64),
                              &state, &count) == KERN_SUCCESS else {
            continue
        }

        if state.__rax == 0x79616265 {  // Magic value "yabe"
            return
        }
        #elseif arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)

        guard thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64),
                              &state, &count) == KERN_SUCCESS else {
            continue
        }

        if state.__x.0 == 0x79616265 {  // Magic value "yabe"
            return
        }
        #endif

        usleep(20000)  // Wait 20ms
    }

    throw InjectionError.verificationFailed
}
```

---

## Appendix: Complete Message Flow Example

### Example: Create Space on Display 1

1. **Client prepares message**:
   ```
   Length: 0x08 (8 bytes)
   Opcode: 0x03 (SA_OPCODE_SPACE_CREATE)
   Payload: 0x0000000000000001 (display_id = 1)

   Wire format: [08 00] [03] [01 00 00 00 00 00 00 00]
   ```

2. **Client sends to socket**:
   - Connect to `/tmp/yabai-sa_{user}.socket`
   - Send 11 bytes total (2 + 1 + 8)

3. **Server receives and processes**:
   - Read 2 bytes → length = 8
   - Read 1 byte → opcode = 0x03
   - Read 8 bytes → display_id = 1
   - Call `add_space_fp(dock_spaces, 1)`

4. **Server acknowledges**:
   - Send single byte: `'X'`

5. **Client receives ACK**:
   - Read 1 byte
   - Return success

### Example: Set Window Opacity with Fade

1. **Client prepares message**:
   ```
   Length: 0x0C (12 bytes)
   Opcode: 0x08 (SA_OPCODE_WINDOW_OPACITY_FADE)
   Payload:
     - wid: 0x00012345 (4 bytes)
     - opacity: 0x3F000000 (0.5 as float, 4 bytes)
     - duration: 0x3F800000 (1.0 as float, 4 bytes)

   Wire format: [0C 00] [08] [45 23 01 00] [00 00 00 3F] [00 00 80 3F]
   ```

2. **Server processes**:
   - Extract wid = 0x12345
   - Extract opacity = 0.5
   - Extract duration = 1.0
   - Create fade animation on background thread
   - Send ACK

This specification provides everything needed to reimplement the yabai scripting addition loading mechanism in Swift or any other language.
