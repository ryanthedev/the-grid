#ifndef MSS_TYPES_H
#define MSS_TYPES_H

#include <stdint.h>
#include <stdbool.h>

// Library version
#define MSS_VERSION "0.0.6"

// Window animation structure for swap operations
struct mss_window_animation {
    uint32_t wid;
    uint32_t proxy_wid;
};

// Window layer levels
enum mss_window_layer {
    MSS_LAYER_BELOW  = 3,   // kCGBackstopMenuLevel
    MSS_LAYER_NORMAL = 4,   // kCGNormalWindowLevel
    MSS_LAYER_ABOVE  = 5    // kCGFloatingWindowLevel
};

// Window order modes
enum mss_window_order {
    MSS_ORDER_OUT   = 0,
    MSS_ORDER_ABOVE = 1,
    MSS_ORDER_BELOW = -1
};

// Error codes
enum mss_error {
    MSS_SUCCESS           = 0,
    MSS_ERROR_INIT        = -1,   // Failed to initialize
    MSS_ERROR_ROOT        = -2,   // Root privileges required
    MSS_ERROR_CONNECTION  = -3,   // Connection failed
    MSS_ERROR_INSTALL     = -4,   // Installation failed
    MSS_ERROR_LOAD        = -5,   // Loading failed
    MSS_ERROR_NOT_LOADED  = -6,   // SA not loaded
    MSS_ERROR_OPERATION   = -7,   // Operation failed
    MSS_ERROR_INVALID_ARG = -8    // Invalid argument
};

// Capability flags (from handshake)
#define MSS_CAP_DOCK_SPACES  0x01
#define MSS_CAP_DPPM         0x02
#define MSS_CAP_ADD_SPACE    0x04
#define MSS_CAP_REM_SPACE    0x08
#define MSS_CAP_MOV_SPACE    0x10
#define MSS_CAP_SET_WINDOW   0x20
#define MSS_CAP_ANIM_TIME    0x40
#define MSS_CAP_ALL          0x7F

// Opaque context structure (defined in client.m)
typedef struct mss_context mss_context;

#endif
