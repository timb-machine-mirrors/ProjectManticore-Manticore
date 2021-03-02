//
//  utils.h
//  reton
//
//  Created by Luca on 18.02.21.
//

#include "../Misc/support.h"


struct proc_cred {
    char posix_cred[0x100]; // HACK big enough
    kptr_t cr_label;
    kptr_t sandbox_slot;
};

void patch_TF_PLATFORM(kptr_t task);
void proc_set_root_cred(kptr_t proc, struct proc_cred **old_cred);
int perform_root_patches(kptr_t ucred);
char *get_path_for_pid(pid_t pid);
pid_t pid_of_process(const char *name);
bool restartSpringBoard(void);
int runCommandv(const char *cmd, int argc, const char * const* argv, void (^unrestrict)(pid_t), bool wait);
pid_t look_for_proc_basename(const char *base_name);
void patch_amfid(pid_t amfid_pid);
BOOL setCSFlagsByPID(pid_t pid);
uint64_t binary_load_address(mach_port_t tp);
