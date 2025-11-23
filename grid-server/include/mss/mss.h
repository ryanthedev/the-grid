#ifndef MSS_H
#define MSS_H

#include <stddef.h>
#include "mss_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Logging
// ============================================================================

/**
 * Logging callback function type.
 *
 * @param message Log message (null-terminated string)
 */
typedef void (*mss_log_callback)(const char *message);

/**
 * Set optional logging callback for diagnostic output.
 *
 * @param callback Function to call with log messages, or NULL to disable
 */
void mss_set_log_callback(mss_log_callback callback);

// ============================================================================
// Context Management
// ============================================================================

/**
 * Create a new scripting addition context.
 *
 * @param socket_path Optional custom socket path. If NULL, uses default
 *                    /tmp/mss_<username>.socket
 * @return New context or NULL on failure
 */
mss_context *mss_create(const char *socket_path);

/**
 * Destroy a scripting addition context and free resources.
 *
 * @param ctx Context to destroy
 */
void mss_destroy(mss_context *ctx);

/**
 * Get the socket path used by this context.
 *
 * @param ctx Context
 * @return Socket path (do not free)
 */
const char *mss_get_socket_path(mss_context *ctx);

/**
 * Get SA capabilities from handshake.
 *
 * @param ctx Context
 * @param capabilities Output for capability flags (MSS_CAP_*)
 * @param version Output for SA version string (do not free)
 * @return MSS_SUCCESS or error code
 */
int mss_handshake(mss_context *ctx, uint32_t *capabilities, const char **version);

// ============================================================================
// Installation & Loading (requires root)
// ============================================================================

/**
 * Install the scripting addition to /Library/ScriptingAdditions/.
 * Requires root privileges.
 *
 * @param ctx Context
 * @return MSS_SUCCESS or error code
 */
int mss_install(mss_context *ctx);

/**
 * Uninstall the scripting addition from /Library/ScriptingAdditions/.
 * Requires root privileges.
 *
 * @param ctx Context
 * @return MSS_SUCCESS or error code
 */
int mss_uninstall(mss_context *ctx);

/**
 * Load the scripting addition into Dock.app.
 * Automatically installs if not already installed.
 * Requires root privileges.
 *
 * @param ctx Context
 * @return MSS_SUCCESS or error code
 */
int mss_load(mss_context *ctx);

/**
 * Check system requirements for scripting addition.
 * Validates root privileges, SIP configuration, and boot arguments (ARM64).
 * Does not install or load anything - just validates prerequisites.
 *
 * @param ctx Context
 * @return MSS_SUCCESS if requirements met, or specific error code
 */
int mss_check_requirements(mss_context *ctx);

// ============================================================================
// Space Operations
// ============================================================================

/**
 * Create a new space on the display containing the specified space.
 *
 * @param ctx Context
 * @param sid Space ID on the target display
 * @return true on success, false on failure
 */
bool mss_space_create(mss_context *ctx, uint64_t sid);

/**
 * Destroy a space.
 *
 * @param ctx Context
 * @param sid Space ID to destroy
 * @return true on success, false on failure
 */
bool mss_space_destroy(mss_context *ctx, uint64_t sid);

/**
 * Focus (switch to) a space.
 *
 * @param ctx Context
 * @param sid Space ID to focus
 * @return true on success, false on failure
 */
bool mss_space_focus(mss_context *ctx, uint64_t sid);

/**
 * Move a space to another display.
 *
 * @param ctx Context
 * @param src_sid Source space ID to move
 * @param dst_sid Destination space ID (determines target display)
 * @param src_prev_sid Previous space on source display to focus
 * @param focus Whether to focus the moved space on destination display
 * @return true on success, false on failure
 */
bool mss_space_move(mss_context *ctx, uint64_t src_sid,
                          uint64_t dst_sid, uint64_t src_prev_sid, bool focus);

// ============================================================================
// Window Operations
// ============================================================================

/**
 * Move a window to absolute coordinates.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param x X coordinate
 * @param y Y coordinate
 * @return true on success, false on failure
 */
bool mss_window_move(mss_context *ctx, uint32_t wid, int x, int y);

/**
 * Set window opacity instantly.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param opacity Opacity value (0.0 to 1.0)
 * @return true on success, false on failure
 */
bool mss_window_set_opacity(mss_context *ctx, uint32_t wid, float opacity);

/**
 * Fade window opacity over a duration.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param opacity Target opacity value (0.0 to 1.0)
 * @param duration Duration in seconds
 * @return true on success, false on failure
 */
bool mss_window_fade_opacity(mss_context *ctx, uint32_t wid,
                                   float opacity, float duration);

/**
 * Set window layer level.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param layer Layer level (MSS_LAYER_*)
 * @return true on success, false on failure
 */
bool mss_window_set_layer(mss_context *ctx, uint32_t wid,
                                enum mss_window_layer layer);

/**
 * Set window sticky state (visible on all spaces).
 *
 * @param ctx Context
 * @param wid Window ID
 * @param sticky true to make sticky, false otherwise
 * @return true on success, false on failure
 */
bool mss_window_set_sticky(mss_context *ctx, uint32_t wid, bool sticky);

/**
 * Set window shadow state.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param shadow true to enable shadow, false to disable
 * @return true on success, false on failure
 */
bool mss_window_set_shadow(mss_context *ctx, uint32_t wid, bool shadow);

/**
 * Focus a window.
 *
 * @param ctx Context
 * @param wid Window ID
 * @return true on success, false on failure
 */
bool mss_window_focus(mss_context *ctx, uint32_t wid);

/**
 * Scale/transform a window (picture-in-picture mode).
 *
 * @param ctx Context
 * @param wid Window ID
 * @param x Target X coordinate
 * @param y Target Y coordinate
 * @param w Target width
 * @param h Target height
 * @return true on success, false on failure
 */
bool mss_window_scale(mss_context *ctx, uint32_t wid,
                            float x, float y, float w, float h);

/**
 * Order one window relative to another.
 *
 * @param ctx Context
 * @param wid Window ID to order
 * @param order Order mode (MSS_ORDER_*)
 * @param relative_wid Window ID to order relative to
 * @return true on success, false on failure
 */
bool mss_window_order(mss_context *ctx, uint32_t wid,
                            enum mss_window_order order, uint32_t relative_wid);

/**
 * Order multiple windows to front.
 *
 * @param ctx Context
 * @param window_list Array of window IDs
 * @param count Number of windows
 * @return true on success, false on failure
 */
bool mss_window_order_in(mss_context *ctx, uint32_t *window_list, int count);

/**
 * Move a window to a space.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param sid Space ID
 * @return true on success, false on failure
 */
bool mss_window_move_to_space(mss_context *ctx, uint32_t wid, uint64_t sid);

/**
 * Move multiple windows to a space.
 *
 * @param ctx Context
 * @param window_list Array of window IDs
 * @param count Number of windows
 * @param sid Space ID
 * @return true on success, false on failure
 */
bool mss_window_list_move_to_space(mss_context *ctx, uint32_t *window_list,
                                         int count, uint64_t sid);

/**
 * Resize a window.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param width New width in pixels
 * @param height New height in pixels
 * @return true on success, false on failure
 */
bool mss_window_resize(mss_context *ctx, uint32_t wid, int width, int height);

/**
 * Set window frame (position and size).
 *
 * @param ctx Context
 * @param wid Window ID
 * @param x X coordinate
 * @param y Y coordinate
 * @param width Width in pixels
 * @param height Height in pixels
 * @return true on success, false on failure
 */
bool mss_window_set_frame(mss_context *ctx, uint32_t wid,
                                 int x, int y, int width, int height);

/**
 * Minimize a window.
 *
 * @param ctx Context
 * @param wid Window ID
 * @return true on success, false on failure
 */
bool mss_window_minimize(mss_context *ctx, uint32_t wid);

/**
 * Unminimize (restore) a window.
 *
 * @param ctx Context
 * @param wid Window ID
 * @return true on success, false on failure
 */
bool mss_window_unminimize(mss_context *ctx, uint32_t wid);

/**
 * Check if a window is minimized.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param result Output for minimized state
 * @return true on success, false on failure
 */
bool mss_window_is_minimized(mss_context *ctx, uint32_t wid, bool *result);

// ============================================================================
// Window Query Operations
// ============================================================================

/**
 * Get window opacity.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param opacity Output for opacity value (0.0 to 1.0)
 * @return true on success, false on failure
 */
bool mss_window_get_opacity(mss_context *ctx, uint32_t wid, float *opacity);

/**
 * Get window frame (position and size).
 *
 * @param ctx Context
 * @param wid Window ID
 * @param x Output for X coordinate
 * @param y Output for Y coordinate
 * @param width Output for width
 * @param height Output for height
 * @return true on success, false on failure
 */
bool mss_window_get_frame(mss_context *ctx, uint32_t wid,
                                 int *x, int *y, int *width, int *height);

/**
 * Check if window is sticky.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param sticky Output for sticky state
 * @return true on success, false on failure
 */
bool mss_window_is_sticky(mss_context *ctx, uint32_t wid, bool *sticky);

/**
 * Get window layer level.
 *
 * @param ctx Context
 * @param wid Window ID
 * @param layer Output for layer level
 * @return true on success, false on failure
 */
bool mss_window_get_layer(mss_context *ctx, uint32_t wid,
                                 enum mss_window_layer *layer);


// ============================================================================
// Window Animation (Advanced)
// ============================================================================

/**
 * Swap in proxy windows (hide real windows, show proxies).
 * Used for window swap animations.
 *
 * @param ctx Context
 * @param animations Array of window/proxy pairs
 * @param count Number of pairs
 * @return true on success, false on failure
 */
bool mss_window_swap_proxy_in(mss_context *ctx,
                                    struct mss_window_animation *animations,
                                    int count);

/**
 * Swap out proxy windows (show real windows, hide proxies).
 * Used for window swap animations.
 *
 * @param ctx Context
 * @param animations Array of window/proxy pairs
 * @param count Number of pairs
 * @return true on success, false on failure
 */
bool mss_window_swap_proxy_out(mss_context *ctx,
                                     struct mss_window_animation *animations,
                                     int count);


// ============================================================================
// Display Operations
// ============================================================================

/**
 * Get display count.
 *
 * @param ctx Context
 * @param count Output for display count
 * @return MSS_SUCCESS or error code
 */
int mss_display_get_count(mss_context *ctx, uint32_t *count);

/**
 * Get list of display IDs.
 *
 * @param ctx Context
 * @param displays Output array for display IDs
 * @param max_count Maximum number of displays to return
 * @return MSS_SUCCESS or error code
 */
int mss_display_get_list(mss_context *ctx, uint32_t *displays, size_t max_count);

#ifdef __cplusplus
}
#endif

#endif
