#include "AudioSupport.h"
#include <stdatomic.h>
#include <stdlib.h>

enum { RS_LEASE_CLOSED = 1, RS_LEASE_ACTIVE = 2 };
struct RSCaptureLease { _Atomic unsigned gate; };
RSCaptureLease *rs_capture_lease_create(void) {
    RSCaptureLease *lease = calloc(1, sizeof(*lease));
    if (!lease) return NULL;
    atomic_init(&lease->gate, 0);
    if (!atomic_is_lock_free(&lease->gate)) { free(lease); return NULL; }
    return lease;
}
int rs_capture_lease_enter(RSCaptureLease *lease) {
    if (!lease) return 0;
    unsigned expected = 0;
    // CoreAudio normally serializes this IOProc. Reject overlap rather than
    // admitting two writers to its single-producer ring. Never spin on the IO thread.
    return atomic_compare_exchange_strong_explicit(&lease->gate, &expected,
        RS_LEASE_ACTIVE, memory_order_acquire, memory_order_relaxed);
}
void rs_capture_lease_leave(RSCaptureLease *lease) {
    atomic_fetch_sub_explicit(&lease->gate, RS_LEASE_ACTIVE, memory_order_release);
}
int rs_capture_lease_retire(RSCaptureLease *lease) {
    if (!lease) return 1;
    return (atomic_fetch_or_explicit(&lease->gate, RS_LEASE_CLOSED,
        memory_order_acq_rel) & RS_LEASE_ACTIVE) == 0;
}
int rs_capture_lease_idle(RSCaptureLease *lease) {
    return !lease || atomic_load_explicit(&lease->gate, memory_order_acquire) == RS_LEASE_CLOSED;
}
int rs_capture_lease_destroy(RSCaptureLease *lease) {
    if (!lease) return 1;
    if (!rs_capture_lease_retire(lease)) return 0;
    free(lease);
    return 1;
}
