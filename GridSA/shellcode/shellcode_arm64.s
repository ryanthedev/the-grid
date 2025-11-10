// Shellcode for ARM64 - Injected into Dock.app to bootstrap payload loading
// This code runs in Dock's process space and loads the payload bundle

.text
.globl _shellcode_arm64_start
.globl _shellcode_arm64_end
.align 4

_shellcode_arm64_start:
    // Save frame pointer and link register
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    // Save callee-saved registers
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!

    // Stack is already 16-byte aligned from pushes

    // Call pthread_create_from_mach_thread()
    // This bootstraps us from a raw Mach thread into a proper POSIX thread
    // pthread_create_from_mach_thread(NULL)
    mov x0, #0                          // arg0 = NULL
    bl _pthread_create_from_mach_thread

    // Now we're in a real thread, call dlopen() to load the payload
    // dlopen(path, RTLD_NOW)

    // Load address of path string (position-independent)
    adrp x0, path_string@PAGE          // Get page address
    add x0, x0, path_string@PAGEOFF    // Add offset within page
    mov x1, #2                          // arg1 = RTLD_NOW (2)
    bl _dlopen

    // Write magic value to X0 for injection verification
    // Magic: 0x47524944 = "GRID" in ASCII
    mov w0, #0x4944                    // Lower 16 bits: "ID"
    movk w0, #0x4752, lsl #16          // Upper 16 bits: "GR"

    // Infinite loop - thread must not exit
loop:
    yield                              // ARM64 equivalent of x86 pause
    b loop

    // Restore registers (never reached, but good practice)
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

.align 3
// Path to payload bundle (embedded in shellcode)
path_string:
    .asciz "/Library/ScriptingAdditions/grid-sa.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload"

_shellcode_arm64_end:
    nop
