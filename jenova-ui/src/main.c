#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <errno.h>
#include <limits.h>
#include <libgen.h>
#include <ncurses.h>
#include <sys/types.h>

/* FreeBSD: sysctl for executable path */
#if defined(__FreeBSD__)
#include <sys/sysctl.h>
#endif

/* macOS: _NSGetExecutablePath */
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include <gtk/gtk.h>
#include <libappindicator/app-indicator.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

static lua_State *L = NULL;
static AppIndicator *global_indicator = NULL;
static char jenova_root[PATH_MAX] = {0};

/* Forward declarations */
static void run_tui(void);
static void run_tray(int argc, char *argv[]);
static void rebuild_tray_menu(void);

/* ---------------------------------------------------------------------------
 * get_jenova_root: Resolve the project root from the binary's location.
 *
 * Strategy: find the directory containing the running executable, go up one
 * level (bin/ -> root).  The executable lookup is OS-specific:
 *   FreeBSD  — sysctl KERN_PROC_PATHNAME
 *   Linux    — readlink /proc/self/exe
 *   macOS    — _NSGetExecutablePath
 * Falls back to "." if all methods fail.
 * --------------------------------------------------------------------------- */
char *get_jenova_root(void) {
    if (jenova_root[0] != '\0') return jenova_root;

    char exe_path[PATH_MAX];
    int found = 0;

#if defined(__FreeBSD__)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t len = sizeof(exe_path);
    if (sysctl(mib, 4, exe_path, &len, NULL, 0) == 0) {
        found = 1;
    }
#elif defined(__APPLE__)
    uint32_t bufsize = sizeof(exe_path);
    if (_NSGetExecutablePath(exe_path, &bufsize) == 0) {
        found = 1;
    }
#else
    /* Linux */
    ssize_t count = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (count != -1) {
        exe_path[count] = '\0';
        found = 1;
    }
#endif

    if (found) {
        /* dirname may modify its argument — work on a copy */
        char path_copy[PATH_MAX];
        strncpy(path_copy, exe_path, sizeof(path_copy) - 1);
        path_copy[sizeof(path_copy) - 1] = '\0';
        char *bin_dir = dirname(path_copy);

        char root_tmp[PATH_MAX];
        snprintf(root_tmp, sizeof(root_tmp), "%s/..", bin_dir);
        if (realpath(root_tmp, jenova_root) == NULL) {
            fprintf(stderr, "jenova-ui: warning: realpath(%s) failed: %s\n",
                    root_tmp, strerror(errno));
            snprintf(jenova_root, sizeof(jenova_root), ".");
        }
    } else {
        fprintf(stderr, "jenova-ui: warning: could not determine executable path, using cwd\n");
        snprintf(jenova_root, sizeof(jenova_root), ".");
    }
    return jenova_root;
}

/* ---------------------------------------------------------------------------
 * setup_environment: Prepend bin/ directories to PATH and export JENOVA_ROOT.
 * --------------------------------------------------------------------------- */
void setup_environment(void) {
    const char *root = get_jenova_root();
    const char *home = getenv("HOME");
    if (!home) home = "";
    const char *old_path = getenv("PATH");

    char new_path[8192];
    snprintf(new_path, sizeof(new_path),
             "%s/bin:%s/.local/bin:/usr/local/bin:/usr/bin:/bin:%s",
             root, home, old_path ? old_path : "");
    setenv("PATH", new_path, 1);
    setenv("JENOVA_ROOT", root, 1);
}

/* ---------------------------------------------------------------------------
 * Lua C API functions exposed as globals to the Lua layer.
 * --------------------------------------------------------------------------- */
static int l_sys_exec_async(lua_State *Ls) {
    const char *cmd = luaL_checkstring(Ls, 1);
    GError *error = NULL;
    if (!g_spawn_command_line_async(cmd, &error)) {
        fprintf(stderr, "jenova-ui: async exec error: %s\n", error->message);
        g_error_free(error);
    }
    return 0;
}

static int l_sys_exec_sync(lua_State *Ls) {
    const char *cmd = luaL_checkstring(Ls, 1);
    int ret = system(cmd);
    lua_pushinteger(Ls, ret);
    return 1;
}

static int l_quit_app(lua_State *Ls) {
    (void)Ls;
    gtk_main_quit();
    return 0;
}

/* ---------------------------------------------------------------------------
 * init_lua: Create the Lua state, register C functions, load ui.lua, and
 * call ui.init(jenova_root).
 * --------------------------------------------------------------------------- */
void init_lua(void) {
    L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "jenova-ui: fatal: luaL_newstate() returned NULL\n");
        exit(1);
    }
    luaL_openlibs(L);

    lua_pushcfunction(L, l_sys_exec_async);
    lua_setglobal(L, "sys_exec_async");

    lua_pushcfunction(L, l_sys_exec_sync);
    lua_setglobal(L, "sys_exec_sync");

    lua_pushcfunction(L, l_quit_app);
    lua_setglobal(L, "quit_app");

    /* Add lib/ to package.path so ui.lua can require siblings */
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const char *cur_path = lua_tostring(L, -1);
    char new_path[8192];
    snprintf(new_path, sizeof(new_path), "%s;%s/lib/?.lua",
             cur_path ? cur_path : "", get_jenova_root());
    lua_pop(L, 1);           /* pop old path string */
    lua_pushstring(L, new_path);
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);           /* pop 'package' table */

    /* Load lib/ui.lua */
    char ui_script[PATH_MAX];
    snprintf(ui_script, sizeof(ui_script), "%s/lib/ui.lua", get_jenova_root());

    if (luaL_dofile(L, ui_script) != LUA_OK) {
        fprintf(stderr, "jenova-ui: fatal: failed to load ui.lua: %s\n",
                lua_tostring(L, -1));
        lua_close(L);
        exit(1);
    }

    /* Call ui.init(jenova_root) */
    lua_getglobal(L, "ui");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "init");
        if (lua_isfunction(L, -1)) {
            lua_pushstring(L, get_jenova_root());
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                fprintf(stderr, "jenova-ui: error calling ui.init: %s\n",
                        lua_tostring(L, -1));
                lua_pop(L, 1); /* pop error */
            }
        } else {
            lua_pop(L, 1); /* pop non-function */
        }
    }
    lua_pop(L, 1); /* pop 'ui' table */
}

/* ---------------------------------------------------------------------------
 * main
 * --------------------------------------------------------------------------- */
int main(int argc, char *argv[]) {
    setup_environment();
    init_lua();

    if (argc > 1 && strcmp(argv[1], "tui") == 0) {
        run_tui();
    } else {
        run_tray(argc, argv);
    }

    lua_close(L);
    return 0;
}

/* ===========================================================================
 *  TRAY ICON
 * =========================================================================== */

static void on_menu_item_activate(GtkMenuItem *item G_GNUC_UNUSED,
                                  gpointer user_data) {
    const char *action = (const char *)user_data;

    lua_getglobal(L, "ui");                          /* +1  [ui] */
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "on_action");                /* +1  [ui, fn] */
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return; }
    lua_pushstring(L, action);                       /* +1  [ui, fn, action] */
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {          /* -2 +err or -2 */
        fprintf(stderr, "jenova-ui: error in ui.on_action: %s\n",
                lua_tostring(L, -1));
        lua_pop(L, 1); /* pop error */
    }
    lua_pop(L, 1); /* pop 'ui' table */

    /* Rebuild menu after state-changing actions so labels stay current
     * (e.g., "Enable LAN" -> "Disable LAN" after toggle_lan). */
    if (strcmp(action, "toggle_lan") == 0 ||
        strcmp(action, "start") == 0 ||
        strcmp(action, "stop") == 0 ||
        strcmp(action, "restart") == 0) {
        rebuild_tray_menu();
    }
}

static void free_action_data(gpointer data, GClosure *closure G_GNUC_UNUSED) {
    free(data);
}

/* ---------------------------------------------------------------------------
 * update_tray_status: Polled every 3 seconds by GLib.  Calls ui.poll_status()
 * and swaps the tray icon between jca.jpg (active) and jca_grey.jpg (inactive).
 *
 * Lua stack discipline: push ui table, push+call poll_status, pop result,
 * pop ui table.  Both success and error paths must leave the stack clean.
 * --------------------------------------------------------------------------- */
static gboolean update_tray_status(gpointer user_data G_GNUC_UNUSED) {
    if (!global_indicator) return TRUE;

    lua_getglobal(L, "ui");                          /* +1  [ui] */
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return TRUE; }

    lua_getfield(L, -1, "poll_status");              /* +1  [ui, fn] */
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return TRUE; }

    if (lua_pcall(L, 0, 1, 0) == LUA_OK) {          /* -1 +1  [ui, result] */
        const char *status = lua_tostring(L, -1);
        char icon_path[PATH_MAX];

        if (status && strcmp(status, "active") == 0) {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca.jpg",
                     get_jenova_root());
        } else {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca_grey.jpg",
                     get_jenova_root());
        }

        app_indicator_set_icon_full(global_indicator, icon_path, "Jenova Status");
        lua_pop(L, 1); /* pop result */
    } else {
        /* pcall error: error message is on stack */
        fprintf(stderr, "jenova-ui: error in ui.poll_status: %s\n",
                lua_tostring(L, -1));
        lua_pop(L, 1); /* pop error */
    }

    lua_pop(L, 1); /* pop 'ui' table */
    return TRUE;
}

/* ---------------------------------------------------------------------------
 * run_tray: Single-instance tray icon with GTK main loop.
 * --------------------------------------------------------------------------- */
static void run_tray(int argc, char *argv[]) {
    /* Single-instance lock (per-user) */
    char lock_path[PATH_MAX];
    snprintf(lock_path, sizeof(lock_path), "/tmp/jenova-ui-%d.lock",
             (int)getuid());
    int lock_fd = open(lock_path, O_CREAT | O_RDWR, 0600);
    if (lock_fd == -1) {
        fprintf(stderr, "jenova-ui: cannot open lockfile %s: %s\n",
                lock_path, strerror(errno));
        exit(1);
    }
    /* Set CLOEXEC so child processes don't inherit the lock fd */
    fcntl(lock_fd, F_SETFD, FD_CLOEXEC);
    if (flock(lock_fd, LOCK_EX | LOCK_NB) == -1) {
        if (errno == EWOULDBLOCK) {
            fprintf(stderr, "jenova-ui: another instance is already running.\n");
        } else {
            fprintf(stderr, "jenova-ui: flock error: %s\n", strerror(errno));
        }
        close(lock_fd);
        exit(1);
    }

    gtk_init(&argc, &argv);

    /* Parse --offline flag */
    int offline_mode = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--offline") == 0) {
            offline_mode = 1;
            break;
        }
    }

    /* Create indicator with grey (inactive) icon as default */
    char default_icon[PATH_MAX];
    snprintf(default_icon, sizeof(default_icon), "%s/png/jca_grey.jpg",
             get_jenova_root());

    global_indicator = app_indicator_new(
        "jenova-ui-tray", default_icon,
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
    app_indicator_set_status(global_indicator, APP_INDICATOR_STATUS_ACTIVE);
    app_indicator_set_icon_full(global_indicator, default_icon,
                                "Jenova (Inactive)");

    /* Build initial context menu from Lua */
    rebuild_tray_menu();

    /* Auto-start server and open Web UI unless --offline */
    if (!offline_mode) {
        lua_getglobal(L, "ui");                      /* +1  [ui] */
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "on_action");        /* +1  [ui, fn] */
            if (lua_isfunction(L, -1)) {
                lua_pushstring(L, "start");
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    fprintf(stderr, "jenova-ui: error starting backend: %s\n",
                            lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1); /* pop non-function */
            }

            lua_getfield(L, -1, "on_action");        /* +1  [ui, fn] */
            if (lua_isfunction(L, -1)) {
                lua_pushstring(L, "web");
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    fprintf(stderr, "jenova-ui: error opening web: %s\n",
                            lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1); /* pop non-function */
            }
        }
        lua_pop(L, 1); /* pop 'ui' table */
    }

    /* Poll server status every 3 seconds */
    g_timeout_add_seconds(3, update_tray_status, NULL);
    update_tray_status(NULL);

    gtk_main();
}

/* ===========================================================================
 *  TUI (ncurses)
 * =========================================================================== */

/* ---------------------------------------------------------------------------
 * rebuild_tray_menu: (Re)builds the GTK context menu from ui.get_menu().
 * Called at startup and after state-changing actions (LAN toggle, etc.).
 * --------------------------------------------------------------------------- */
static void rebuild_tray_menu(void) {
    if (!global_indicator) return;

    GtkWidget *menu = gtk_menu_new();

    lua_getglobal(L, "ui");                          /* +1  [ui] */
    if (!lua_istable(L, -1)) {
        fprintf(stderr, "jenova-ui: fatal: ui table not found in Lua state\n");
        lua_pop(L, 1);
        return;
    }

    lua_getfield(L, -1, "get_menu");                 /* +1  [ui, fn] */
    if (lua_pcall(L, 0, 1, 0) == LUA_OK) {          /* -1 +1  [ui, result] */
        if (lua_istable(L, -1)) {
            size_t len = lua_objlen(L, -1);
            for (size_t i = 1; i <= len; i++) {
                lua_rawgeti(L, -1, (int)i);          /* +1  [ui, result, item] */
                if (lua_istable(L, -1)) {
                    lua_getfield(L, -1, "separator");
                    if (lua_toboolean(L, -1)) {
                        gtk_menu_shell_append(GTK_MENU_SHELL(menu),
                                              gtk_separator_menu_item_new());
                        lua_pop(L, 2); /* pop boolean + item table */
                        continue;
                    }
                    lua_pop(L, 1); /* pop separator boolean */

                    lua_getfield(L, -1, "label");
                    const char *label = lua_tostring(L, -1);
                    lua_pop(L, 1);

                    lua_getfield(L, -1, "action");
                    const char *action = lua_tostring(L, -1);
                    lua_pop(L, 1);

                    if (label && action) {
                        GtkWidget *item = gtk_menu_item_new_with_label(label);
                        char *action_dup = strdup(action);
                        if (action_dup) {
                            g_signal_connect_data(
                                item, "activate",
                                G_CALLBACK(on_menu_item_activate),
                                action_dup,
                                (GClosureNotify)free_action_data, 0);
                        }
                        gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
                    }
                }
                lua_pop(L, 1); /* pop item table */
            }
        }
    } else {
        fprintf(stderr, "jenova-ui: error getting menu: %s\n",
                lua_tostring(L, -1));
    }
    lua_pop(L, 2); /* pop result + 'ui' table */

    gtk_widget_show_all(menu);
    app_indicator_set_menu(global_indicator, GTK_MENU(menu));
}

static void draw_box_tui(const char *title, int width, int n_options) {
    /* Clamp box height to terminal size to prevent ncurses OOB writes */
    int max_row = LINES - 1;
    int bottom = n_options + 6;
    if (bottom > max_row) bottom = max_row;

    attron(COLOR_PAIR(1));
    for (int i = 1; i < width - 1; i++) {
        mvaddch(0, i, ACS_HLINE);
        if (2 <= max_row) mvaddch(2, i, ACS_HLINE);
        if (bottom <= max_row) mvaddch(bottom, i, ACS_HLINE);
    }
    for (int i = 1; i < bottom; i++) {
        if (i <= max_row) {
            mvaddch(i, 0, ACS_VLINE);
            mvaddch(i, width - 1, ACS_VLINE);
        }
    }
    mvaddch(0, 0, ACS_ULCORNER);
    mvaddch(0, width - 1, ACS_URCORNER);
    if (2 <= max_row) {
        mvaddch(2, 0, ACS_LTEE);
        mvaddch(2, width - 1, ACS_RTEE);
    }
    if (bottom <= max_row) {
        mvaddch(bottom, 0, ACS_LLCORNER);
        mvaddch(bottom, width - 1, ACS_LRCORNER);
    }

    int title_len = (int)strlen(title);
    mvprintw(1, (width - title_len) / 2, "%s", title);
    attroff(COLOR_PAIR(1));
}

static void run_tui(void) {
    int selected = 0;
    int key;

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    timeout(1000);
    start_color();

    /* Kanagawa / Royal Purple colour palette (ncurses uses 0-1000 range) */
    init_color(16, 121, 121, 157);   /* BG: dark blue-grey */
    init_color(17, 863, 843, 729);   /* FG: warm cream */
    init_color(18, 176, 309, 403);   /* SEL_BG: teal highlight */
    init_color(19, 462, 580, 415);   /* GREEN: muted sage */
    init_color(20, 764, 250, 262);   /* RED: crimson */
    init_color(21, 470, 317, 662);   /* PURPLE: royal purple */

    init_pair(1, 17, 16);  /* default text */
    init_pair(2, 17, 18);  /* selected item */
    init_pair(3, 19, 16);  /* active status */
    init_pair(4, 20, 16);  /* inactive status */
    init_pair(5, 21, 16);  /* box border */

    wbkgd(stdscr, COLOR_PAIR(1));

    /* Load menu items from Lua — extracted into a helper so we can reload
     * labels after state-changing actions (e.g., LAN toggle). */
    char labels[20][64];
    char actions[20][64];
    int n_options = 0;

    /* reload_tui_menu: (re)populates labels[] and actions[] from ui.get_tui_menu() */
    #define reload_tui_menu() do { \
        n_options = 0; \
        lua_getglobal(L, "ui"); \
        if (!lua_istable(L, -1)) { lua_pop(L, 1); break; } \
        lua_getfield(L, -1, "get_tui_menu"); \
        if (lua_pcall(L, 0, 1, 0) == LUA_OK) { \
            if (lua_istable(L, -1)) { \
                size_t _len = lua_objlen(L, -1); \
                for (size_t _i = 1; _i <= _len && _i <= 20; _i++) { \
                    lua_rawgeti(L, -1, (int)_i); \
                    if (!lua_istable(L, -1)) { lua_pop(L, 1); continue; } \
                    lua_getfield(L, -1, "label"); \
                    const char *_lbl = lua_tostring(L, -1); \
                    if (_lbl) { strncpy(labels[n_options], _lbl, 63); labels[n_options][63] = '\0'; } \
                    else { strncpy(labels[n_options], "(unknown)", 63); } \
                    lua_pop(L, 1); \
                    lua_getfield(L, -1, "action"); \
                    const char *_act = lua_tostring(L, -1); \
                    if (_act) { strncpy(actions[n_options], _act, 63); actions[n_options][63] = '\0'; } \
                    else { strncpy(actions[n_options], "noop", 63); } \
                    lua_pop(L, 1); \
                    n_options++; \
                    lua_pop(L, 1); \
                } \
            } \
        } else { \
            fprintf(stderr, "jenova-ui: error loading TUI menu: %s\n", lua_tostring(L, -1)); \
        } \
        lua_pop(L, 2); \
    } while(0)

    reload_tui_menu();

    if (n_options == 0) {
        endwin();
        fprintf(stderr, "jenova-ui: fatal: no TUI menu items loaded\n");
        return;
    }

    /* Main TUI render loop */
    while (1) {
        clear();
        int width = (COLS < 60) ? COLS : 60;

        /* Poll server status — use get_status_info for extended data */
        char status[64] = "inactive";
        char mode[64] = "LOCAL";
        lua_getglobal(L, "ui");                      /* +1 */
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "get_status_info");  /* +1 */
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 1, 0) == LUA_OK) {  /* -1 +1 */
                    if (lua_istable(L, -1)) {
                        lua_getfield(L, -1, "status");
                        const char *s = lua_tostring(L, -1);
                        if (s) {
                            strncpy(status, s, 63);
                            status[63] = '\0';
                        }
                        lua_pop(L, 1); /* pop status */

                        lua_getfield(L, -1, "mode");
                        const char *m = lua_tostring(L, -1);
                        if (m) {
                            strncpy(mode, m, 63);
                            mode[63] = '\0';
                        }
                        lua_pop(L, 1); /* pop mode */
                    }
                    lua_pop(L, 1); /* pop result table */
                } else {
                    lua_pop(L, 1); /* pop error */
                }
            } else {
                lua_pop(L, 1); /* pop non-function */
            }
        }
        lua_pop(L, 1); /* pop 'ui' table */

        /* Draw interface */
        attron(COLOR_PAIR(5));
        draw_box_tui("JENOVA COGNITIVE ARCHITECTURE", width, n_options);
        attroff(COLOR_PAIR(5));

        mvprintw(4, 2, "Status:");

        if (strcmp(status, "active") == 0) {
            attron(COLOR_PAIR(3));
            mvprintw(5, 4, "ACTIVE");
            attroff(COLOR_PAIR(3));
        } else {
            attron(COLOR_PAIR(4));
            mvprintw(5, 4, "INACTIVE");
            attroff(COLOR_PAIR(4));
        }

        /* Show network mode */
        mvprintw(4, 14, "Mode:");
        if (strcmp(mode, "LAN") == 0) {
            attron(COLOR_PAIR(3));
            mvprintw(5, 16, "LAN (0.0.0.0)");
            attroff(COLOR_PAIR(3));
        } else {
            mvprintw(5, 16, "LOCAL (127.0.0.1)");
        }

        for (int i = 0; i < n_options; i++) {
            if (i == selected) {
                attron(COLOR_PAIR(2));
                mvprintw(7 + i, 2, "> %s", labels[i]);
                attroff(COLOR_PAIR(2));
            } else {
                mvprintw(7 + i, 4, "%s", labels[i]);
            }
        }

        refresh();

        key = getch();
        if (key == ERR) continue; /* timeout, just re-render */

        switch (key) {
            case KEY_UP:
                selected--;
                if (selected < 0) selected = n_options - 1;
                break;
            case KEY_DOWN:
                selected++;
                if (selected >= n_options) selected = 0;
                break;
            case 10: /* Enter */
            case KEY_ENTER:
                if (strcmp(actions[selected], "exit_tui") == 0) {
                    endwin();
                    return;
                }

                lua_getglobal(L, "ui");              /* +1  [ui] */
                if (lua_istable(L, -1)) {
                    lua_getfield(L, -1, "on_tui_action"); /* +1  [ui, fn] */
                    if (lua_isfunction(L, -1)) {
                        lua_pushstring(L, actions[selected]);
                        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                            /* Log but don't crash */
                            fprintf(stderr,
                                    "jenova-ui: error in on_tui_action: %s\n",
                                    lua_tostring(L, -1));
                            lua_pop(L, 1);
                        }
                    } else {
                        lua_pop(L, 1); /* pop non-function */
                    }
                }
                lua_pop(L, 1); /* pop 'ui' table */

                /* Reload menu labels (LAN toggle changes label text) */
                reload_tui_menu();
                if (selected >= n_options && n_options > 0)
                    selected = n_options - 1;

                mvprintw(LINES - 1, 0,
                         "Action executed. Press any key to continue...");
                refresh();

                timeout(-1);
                getch();
                timeout(1000);
                break;
            case 'q':
            case 'Q':
                endwin();
                return;
        }
    }
}
