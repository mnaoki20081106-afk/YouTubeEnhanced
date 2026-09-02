/* Synchronous stand-ins for the libdispatch calls the Learning Filter sources
   use. Test scaffolding only — see README.md in this directory. */
#ifndef LF_TEST_DISPATCH_H
#define LF_TEST_DISPATCH_H
#include <stdint.h>

typedef long dispatch_once_t;
typedef void (^dispatch_block_t)(void);
typedef struct dispatch_queue_s *dispatch_queue_t;
typedef uint64_t dispatch_time_t;

#define DISPATCH_TIME_NOW 0ull
#ifndef NSEC_PER_SEC
#define NSEC_PER_SEC 1000000000ull
#endif
#define QOS_CLASS_UTILITY 0x11

static inline void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block) {
    if (!*predicate) {
        *predicate = 1;
        block();
    }
}
static inline dispatch_queue_t dispatch_get_main_queue(void) { return (dispatch_queue_t)0; }
static inline dispatch_queue_t dispatch_get_global_queue(long identifier, unsigned long flags) {
    (void)identifier;
    (void)flags;
    return (dispatch_queue_t)0;
}
static inline void dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    (void)queue;
    block();
}
static inline dispatch_time_t dispatch_time(dispatch_time_t when, long long delta) {
    (void)when;
    return (dispatch_time_t)delta;
}
static inline void dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when;
    (void)queue;
    block();
}
#endif
