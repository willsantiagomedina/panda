#ifndef PANDA_FRONTMOST_H
#define PANDA_FRONTMOST_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <CoreGraphics/CoreGraphics.h>

#define PANDA_FRONTMOST_TEXT_CAPACITY 1024
#define PANDA_FRONTMOST_PATH_CAPACITY 4096
#define PANDA_MAX_RUNNING_APPS 256
#define PANDA_MAX_WINDOW_IDS 256

typedef struct PandaFrontmostApp {
    pid_t pid;
    char name[PANDA_FRONTMOST_TEXT_CAPACITY];
    char bundle_path[PANDA_FRONTMOST_PATH_CAPACITY];
    char executable_path[PANDA_FRONTMOST_PATH_CAPACITY];
} PandaFrontmostApp;

typedef struct PandaWindowInfo {
    uint32_t window_id;
    pid_t pid;
    CGRect bounds;
    bool is_on_screen;
} PandaWindowInfo;

typedef struct PandaBorderFrame {
    uint32_t window_id;
    bool is_active;
} PandaBorderFrame;

enum {
    PANDA_MOD_COMMAND = 1u << 0,
    PANDA_MOD_CONTROL = 1u << 1,
    PANDA_MOD_OPTION = 1u << 2,
    PANDA_MOD_SHIFT = 1u << 3,
};

bool pandaCopyFrontmostApp(PandaFrontmostApp *out_app);

// Get all running GUI applications (via NSWorkspace)
// Returns the number of apps copied into the buffer
int pandaListRunningGuiApps(PandaFrontmostApp *out_apps, int capacity);

// Get all windows on the current Space (via CGWindowListCopyWindowInfo)
// Returns the number of windows copied into the buffer
int pandaListWindowsOnCurrentSpace(PandaWindowInfo *out_windows, int capacity);

// NSScreen helpers
void *NSScreen_mainScreen(void);
CGRect NSScreen_visibleFrame(void *screen);
CGRect NSScreen_frame(void *screen);

// Accessibility permission helpers
bool pandaPromptForAccessibility(void);

// Border overlay helpers
void pandaEnsureAppKitReady(void);
void pandaSyncBorders(const PandaBorderFrame *frames, int count);
void pandaClearBorders(void);
void pandaSetBordersVisible(bool visible);
pid_t pandaCurrentProcessId(void);

// Keyboard helpers (for desktop switching/moving and daemon hotkeys)
bool pandaPostKeyChord(uint16_t key_code, uint32_t modifiers);

// Global hotkeys
void pandaHotkeysInitialize(void);
bool pandaRegisterHotkey(uint32_t hotkey_id, uint16_t key_code, uint32_t modifiers);
void pandaClearHotkeys(void);
int pandaDrainHotkeys(uint32_t *out_hotkey_ids, int capacity);

#endif
