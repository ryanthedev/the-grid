# Shellcode for x86_64 - Injected into Dock.app to bootstrap payload loading
# This code runs in Dock's process space and loads the payload bundle

.text
.globl _shellcode_x86_64_start
.globl _shellcode_x86_64_end

_shellcode_x86_64_start:
    # Save all registers
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # Align stack to 16 bytes (required for function calls)
    andq $-16, %rsp

    # Call pthread_create_from_mach_thread()
    # This bootstraps us from a raw Mach thread into a proper POSIX thread
    # pthread_create_from_mach_thread(NULL)
    xorq %rdi, %rdi                     # arg0 = NULL
    call _pthread_create_from_mach_thread

    # Now we're in a real thread, call dlopen() to load the payload
    # dlopen("/Library/ScriptingAdditions/grid-sa.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload", RTLD_NOW)

    # Load address of path string (position-independent)
    leaq path_string(%rip), %rdi        # arg0 = path
    movq $2, %rsi                        # arg1 = RTLD_NOW (2)
    call _dlopen

    # Write magic value to RAX for injection verification
    # Magic: 0x47524944 = "GRID" in ASCII
    movq $0x47524944, %rax

    # Infinite loop - thread must not exit
loop:
    pause
    jmp loop

    # Restore registers (never reached, but good practice)
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

# Path to payload bundle (embedded in shellcode)
path_string:
    .asciz "/Library/ScriptingAdditions/grid-sa.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload"

_shellcode_x86_64_end:
    nop
