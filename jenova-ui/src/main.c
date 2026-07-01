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
#include "canvas.h"

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <webkit2/webkit2.h>

static lua_State *L = NULL;
static AppIndicator *global_indicator = NULL;
static char jenova_root[PATH_MAX] = {0};

/* Forward declarations */
typedef struct {
    GtkWidget *main_window;
    GtkWidget *sidebar_list;
    GtkWidget *webview;
    GtkWidget *status_label;
    GtkWidget *mode_label;
    GtkWidget *btn_start;
    GtkWidget *btn_stop;
    GtkWidget *btn_restart;
    GtkWidget *btn_lan;
    GtkWidget *btn_web;
    char current_status[32];
    char current_mode[64];
    char current_conv_id[64];
    int is_visible;
    int is_streaming;
} GUIState;

static GUIState g_ui_state = {0};

static void run_tui(void);
static gboolean run_tray(int argc, char *argv[]);
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
/* ---------------------------------------------------------------------------
 * setup_environment: Prepend bin/ directories to PATH and export JENOVA_ROOT.
 * --------------------------------------------------------------------------- */
void setup_environment(void) {
    const char *root = get_jenova_root();
    const char *home = getenv("HOME");
    if (!home) home = "";
    const char *old_path = getenv("PATH");

    char *new_path = NULL;
    if (asprintf(&new_path, "%s/bin:%s/.local/bin:/usr/local/bin:/usr/bin:/bin:%s",
                 root, home, old_path ? old_path : "") != -1) {
        setenv("PATH", new_path, 1);
        free(new_path);
    }
    
    setenv("JENOVA_ROOT", root, 1);
}

/* ---------------------------------------------------------------------------
 * Lua C API functions exposed as globals to the Lua layer.
 * --------------------------------------------------------------------------- */
static char *wrap_jenova_cmd(const char *cmd) {
    if (strstr(cmd, "jenova-ca") || strstr(cmd, "jenova-term") || strstr(cmd, "jenova-ui")) {
        const char *old_ld = getenv("LD_LIBRARY_PATH");
        const char *root = getenv("JENOVA_ROOT");
        char *new_ld = NULL;
        if (old_ld && *old_ld != '\0') {
            if (asprintf(&new_ld, "%s/external/ext_bin/bin:%s", root ? root : ".", old_ld) == -1) new_ld = NULL;
        } else {
            if (asprintf(&new_ld, "%s/external/ext_bin/bin", root ? root : ".") == -1) new_ld = NULL;
        }
        char *wrapped = NULL;
        if (new_ld) {
            char *quoted_ld = g_shell_quote(new_ld);
            if (asprintf(&wrapped, "env LD_LIBRARY_PATH=%s %s", quoted_ld, cmd) == -1) wrapped = NULL;
            g_free(quoted_ld);
            free(new_ld);
        }
        return wrapped ? wrapped : strdup(cmd);
    }
    return strdup(cmd);
}

static int l_sys_exec_async(lua_State *Ls) {
    const char *cmd = luaL_checkstring(Ls, 1);
    char *wrapped_cmd = wrap_jenova_cmd(cmd);
    GError *error = NULL;
    if (!g_spawn_command_line_async(wrapped_cmd, &error)) {
        fprintf(stderr, "jenova-ui: async exec error: %s\n", error->message);
        g_error_free(error);
    }
    free(wrapped_cmd);
    return 0;
}

static int l_sys_exec_sync(lua_State *Ls) {
    const char *cmd = luaL_checkstring(Ls, 1);
    char *wrapped_cmd = wrap_jenova_cmd(cmd);
    gint exit_status = 0;
    GError *error = NULL;

    if (g_spawn_command_line_sync(wrapped_cmd, NULL, NULL, &exit_status, &error)) {
        lua_pushinteger(Ls, exit_status);
    } else {
        fprintf(stderr, "jenova-ui: sync exec error: %s\n", error->message);
        g_error_free(error);
        lua_pushinteger(Ls, -1);
    }
    free(wrapped_cmd);
    return 1;
}

static int l_sys_exec_read(lua_State *Ls) {
    const char *cmd = luaL_checkstring(Ls, 1);
    char *wrapped_cmd = wrap_jenova_cmd(cmd);
    gchar *stdout_str = NULL;
    gint exit_status = 0;

    if (g_spawn_command_line_sync(wrapped_cmd, &stdout_str, NULL, &exit_status, NULL)) {
        lua_pushstring(Ls, stdout_str ? stdout_str : "");
        g_free(stdout_str);
    } else {
        lua_pushnil(Ls);
    }
    free(wrapped_cmd);
    return 1;
}

static int l_quit_app(lua_State *Ls) {
    (void)Ls;
    gtk_main_quit();
    return 0;
}

/* Chat GUI functions replaced by WebKit embedded WebUI */
static gboolean on_window_delete_event(GtkWidget *widget, GdkEvent *event G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
    gtk_widget_hide(widget);
    g_ui_state.is_visible = 0;
    return TRUE; // Prevent destruction
}

static void on_gui_button_clicked(GtkWidget *widget G_GNUC_UNUSED, gpointer data) {
    const char *action = (const char *)data;
    lua_getglobal(L, "ui");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "on_action");
    if (lua_isfunction(L, -1)) {
        lua_pushstring(L, action);
        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            fprintf(stderr, "jenova-ui: error in ui.on_action: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    } else {
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

static void load_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    const char *css = 
        "window.jenova-window { background-color: transparent; }\n"
        /* GtkNotebook styling */
        "notebook { background-color: transparent; }\n"
        "notebook header { background-color: transparent; border-bottom: 2px solid rgba(43, 30, 58, 0.5); padding-top: 5px; }\n"
        "notebook tab { background-color: transparent; border: none; padding: 2px 12px; box-shadow: none; transition: all 0.2s ease-in-out; margin: 0 4px; border-radius: 8px 8px 0 0; }\n"
        "notebook tab label { color: #5e5966; font-family: 'Inter', 'Segoe UI', sans-serif; font-weight: 600; font-size: 14px; }\n"
        "notebook tab:hover { background-color: #1c1b1b; }\n"
        "notebook tab:hover label { color: #f0edf2; }\n"
        "notebook tab:checked { background-color: #2b1e3a; border-bottom: none; box-shadow: inset 0 -3px 0 0 #e4b382; }\n"
        "notebook tab:checked label { color: #e4b382; }\n"
        /* Glass Panel */
        ".glass-panel { background-color: rgba(43, 30, 58, 0.4); border: 1px solid rgba(228, 179, 130, 0.1); border-radius: 12px; padding: 16px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }\n"
        /* Labels */
        "label { color: #f0edf2; font-family: 'Inter', 'Segoe UI', sans-serif; }\n"
        "label.title { font-weight: 800; font-size: 24px; color: #e4b382; letter-spacing: 1px; text-shadow: 0 2px 4px rgba(0,0,0,0.5); }\n"
        "label.status-active { color: #a3e635; font-weight: 700; font-size: 14px; }\n"
        "label.status-inactive { color: #c96464; font-weight: 700; font-size: 14px; }\n"
        "label.mode-label { color: #aba0d9; font-weight: 700; font-size: 14px; }\n"
        /* Buttons */
        "button { background-image: none; background-color: #2b1e3a; color: #f0edf2; border: 1px solid rgba(228, 179, 130, 0.2); border-radius: 8px; padding: 4px 10px; font-weight: 600; font-size: 12px; font-family: 'Inter', 'Segoe UI', sans-serif; box-shadow: 0 2px 4px rgba(0,0,0,0.2); transition: all 0.2s ease; }\n"
        "button:hover { background-color: #3d2b52; border-color: rgba(228, 179, 130, 0.4); box-shadow: 0 4px 8px rgba(0,0,0,0.4); }\n"
        "button:active { background-color: #1a1223; box-shadow: none; }\n"
        "button.stop-btn:hover { background-color: #c96464; border-color: #ffb3b3; color: #ffffff; }\n"
        ;
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
                                              GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static void init_gui(void) {
    load_css();
    g_ui_state.main_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(g_ui_state.main_window), "JENOVA AI - Native UI");
    gtk_window_set_default_size(GTK_WINDOW(g_ui_state.main_window), 900, 600);
    gtk_window_set_position(GTK_WINDOW(g_ui_state.main_window), GTK_WIN_POS_CENTER);
    
    GtkStyleContext *ctx = gtk_widget_get_style_context(g_ui_state.main_window);
    gtk_style_context_add_class(ctx, "jenova-window");
    g_signal_connect(g_ui_state.main_window, "delete-event", G_CALLBACK(on_window_delete_event), NULL);

    GtkWidget *overlay = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(g_ui_state.main_window), overlay);

    GtkWidget *bg_canvas = create_neural_canvas();
    gtk_container_add(GTK_CONTAINER(overlay), bg_canvas);

    GtkWidget *notebook = gtk_notebook_new();
    gtk_notebook_set_tab_pos(GTK_NOTEBOOK(notebook), GTK_POS_TOP);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), notebook);

    /* TAB 1: WebKit WebUI Container */
    g_ui_state.webview = webkit_web_view_new();
    
    WebKitSettings *settings = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(g_ui_state.webview));
    webkit_settings_set_enable_webgl(settings, TRUE);
    webkit_settings_set_enable_developer_extras(settings, TRUE);

    const char *proxy_port_str = getenv("JENOVA_PROXY_PORT");
    if (!proxy_port_str) proxy_port_str = getenv("JENOVA_PORT");

    long port = 8080;
    if (proxy_port_str) {
        char *endptr;
        long p = strtol(proxy_port_str, &endptr, 10);
        if (*proxy_port_str != '\0' && *endptr == '\0' && p > 0 && p <= 65535) {
            port = p;
        }
    }

    char file_uri[PATH_MAX];
    snprintf(file_uri, sizeof(file_uri), "http://127.0.0.1:%ld/", port);
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(g_ui_state.webview), file_uri);
    
    GtkWidget *tab1_label = gtk_label_new("Jenova AI");
    gtk_notebook_append_page(GTK_NOTEBOOK(notebook), g_ui_state.webview, tab1_label);

    /* TAB 2: Switchboard (Controls & Info) */
    GtkWidget *sidebar_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_top(sidebar_vbox, 16);
    gtk_widget_set_margin_bottom(sidebar_vbox, 16);
    gtk_widget_set_margin_start(sidebar_vbox, 16);
    gtk_widget_set_margin_end(sidebar_vbox, 16);
    
    char img_path[PATH_MAX];
    snprintf(img_path, sizeof(img_path), "%s/png/jenova.jpg", get_jenova_root());
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(img_path, NULL);
    GtkWidget *image = gtk_image_new();
    if (pixbuf) {
        int w = gdk_pixbuf_get_width(pixbuf);
        int h = gdk_pixbuf_get_height(pixbuf);
        if (w > 0) {
            int dest_h = (int)(h * (50.0 / w));
            if (dest_h <= 0) dest_h = 1;
            GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixbuf, 50, dest_h, GDK_INTERP_BILINEAR);
            if (scaled) {
                gtk_image_set_from_pixbuf(GTK_IMAGE(image), scaled);
                g_object_unref(scaled);
            }
        }
        g_object_unref(pixbuf);
    }
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), image, FALSE, FALSE, 0);

    GtkWidget *title_lbl = gtk_label_new("JENOVA AI");
    gtk_style_context_add_class(gtk_widget_get_style_context(title_lbl), "title");
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), title_lbl, FALSE, FALSE, 0);

    GtkWidget *status_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_style_context_add_class(gtk_widget_get_style_context(status_box), "glass-panel");
    gtk_widget_set_margin_top(status_box, 10);
    gtk_widget_set_margin_bottom(status_box, 10);
    
    GtkWidget *status_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_halign(status_hbox, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(status_hbox, 16);
    GtkWidget *status_title = gtk_label_new("Status:");
    g_ui_state.status_label = gtk_label_new("INACTIVE");
    gtk_style_context_add_class(gtk_widget_get_style_context(g_ui_state.status_label), "status-inactive");
    gtk_box_pack_start(GTK_BOX(status_hbox), status_title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(status_hbox), g_ui_state.status_label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(status_box), status_hbox, FALSE, FALSE, 0);

    GtkWidget *mode_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_halign(mode_hbox, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_bottom(mode_hbox, 16);
    GtkWidget *mode_title = gtk_label_new("Mode:");
    g_ui_state.mode_label = gtk_label_new("LOCAL");
    gtk_style_context_add_class(gtk_widget_get_style_context(g_ui_state.mode_label), "mode-label");
    gtk_box_pack_start(GTK_BOX(mode_hbox), mode_title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(mode_hbox), g_ui_state.mode_label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(status_box), mode_hbox, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), status_box, FALSE, FALSE, 0);

    g_ui_state.btn_start = gtk_button_new_with_label("Start Server");
    g_ui_state.btn_stop = gtk_button_new_with_label("Stop Server");
    gtk_style_context_add_class(gtk_widget_get_style_context(g_ui_state.btn_stop), "stop-btn");
    g_ui_state.btn_lan = gtk_button_new_with_label("Toggle LAN");
    
    GtkWidget *btn_workspaces = gtk_button_new_with_label("Open Workspaces");
    GtkWidget *btn_config = gtk_button_new_with_label("Edit Config");

    g_signal_connect(g_ui_state.btn_start, "clicked", G_CALLBACK(on_gui_button_clicked), "start");
    g_signal_connect(g_ui_state.btn_stop, "clicked", G_CALLBACK(on_gui_button_clicked), "stop");
    g_signal_connect(g_ui_state.btn_lan, "clicked", G_CALLBACK(on_gui_button_clicked), "toggle_lan");
    g_signal_connect(btn_workspaces, "clicked", G_CALLBACK(on_gui_button_clicked), "open_workspaces");
    g_signal_connect(btn_config, "clicked", G_CALLBACK(on_gui_button_clicked), "edit_config");

    gtk_box_pack_start(GTK_BOX(sidebar_vbox), g_ui_state.btn_start, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), g_ui_state.btn_stop, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), g_ui_state.btn_lan, FALSE, FALSE, 0);
    
    /* Add a small separator line before utilities */
    GtkWidget *separator = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(separator, 10);
    gtk_widget_set_margin_bottom(separator, 10);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), separator, FALSE, FALSE, 0);
    
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), btn_workspaces, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), btn_config, FALSE, FALSE, 0);
    
    GtkWidget *tab2_label = gtk_label_new("Control Panel");
    gtk_notebook_append_page(GTK_NOTEBOOK(notebook), sidebar_vbox, tab2_label);

    gtk_widget_show_all(g_ui_state.main_window);
    g_ui_state.is_visible = 1;
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

    lua_pushcfunction(L, l_sys_exec_read);
    lua_setglobal(L, "sys_exec_read");

    lua_pushcfunction(L, l_quit_app);
    lua_setglobal(L, "quit_app");

    /* Native Chat functions removed */

    /* Add lib/ to package.path so ui.lua can require siblings */
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const char *cur_path = lua_tostring(L, -1);
    char *new_path = NULL;
    if (asprintf(&new_path, "%s;%s/lib/?.lua",
                 cur_path ? cur_path : "", get_jenova_root()) != -1) {
        lua_pop(L, 1);           /* pop old path string */
        lua_pushstring(L, new_path);
        lua_setfield(L, -2, "path");
        free(new_path);
    }
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

    int force_tui = 0;
    int force_tray = 0;

    if (argc > 1 && strcmp(argv[1], "tui") == 0) {
        force_tui = 1;
    } else if (argc > 1 && strcmp(argv[1], "tray") == 0) {
        force_tray = 1;
    }

    if (force_tui) {
        run_tui();
    } else {
        if (run_tray(argc, argv)) {
            // Started successfully (and blocked on gtk_main)
        } else {
            if (force_tray) {
                fprintf(stderr, "jenova-ui: tray mode requested but GTK initialization failed.\n");
                lua_close(L);
                return 1;
            }
            fprintf(stderr, "jenova-ui: system tray/GTK initialization failed, falling back to TUI mode.\n");
            run_tui();
        }
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

static GPid status_pid = 0;
static GString *status_output = NULL;

static gboolean on_status_output_read(GIOChannel *source, GIOCondition condition, gpointer data G_GNUC_UNUSED) {
    gchar buf[512];
    gsize bytes_read = 0;
    GError *error = NULL;
    GIOStatus status = g_io_channel_read_chars(source, buf, sizeof(buf) - 1, &bytes_read, &error);

    if (status == G_IO_STATUS_NORMAL) {
        buf[bytes_read] = '\0';
        g_string_append(status_output, buf);
    } else if (status == G_IO_STATUS_ERROR && error) {
        g_error_free(error);
    }

    if (status == G_IO_STATUS_EOF || (condition & G_IO_ERR)) {
        int is_active = (status_output->str && strstr(status_output->str, "is ready") != NULL);
        char icon_path[PATH_MAX];
        int was_active = (strcmp(g_ui_state.current_status, "active") == 0);

        if (is_active) {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca.jpg", get_jenova_root());
            if (g_ui_state.status_label) {
                gtk_label_set_text(GTK_LABEL(g_ui_state.status_label), "ACTIVE");
                GtkStyleContext *ctx = gtk_widget_get_style_context(g_ui_state.status_label);
                gtk_style_context_remove_class(ctx, "status-inactive");
                gtk_style_context_add_class(ctx, "status-active");
            }
            if (!was_active && g_ui_state.webview) {
                webkit_web_view_reload(WEBKIT_WEB_VIEW(g_ui_state.webview));
            }
            strncpy(g_ui_state.current_status, "active", sizeof(g_ui_state.current_status)-1);
        } else {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca_grey.jpg", get_jenova_root());
            if (g_ui_state.status_label) {
                gtk_label_set_text(GTK_LABEL(g_ui_state.status_label), "INACTIVE");
                GtkStyleContext *ctx = gtk_widget_get_style_context(g_ui_state.status_label);
                gtk_style_context_remove_class(ctx, "status-active");
                gtk_style_context_add_class(ctx, "status-inactive");
            }
            strncpy(g_ui_state.current_status, "inactive", sizeof(g_ui_state.current_status)-1);
        }

        if (global_indicator) {
            app_indicator_set_icon_full(global_indicator, icon_path, "Jenova Status");
        }

        g_string_free(status_output, TRUE);
        status_output = NULL;
        if (status_pid != 0) {
            g_spawn_close_pid(status_pid);
            status_pid = 0;
        }
        return FALSE; /* Stop listening */
    }
    return TRUE;
}

static gboolean update_tray_status(gpointer user_data G_GNUC_UNUSED) {
    if (!global_indicator) return TRUE;

    /* Update proxy state non-blockingly via Lua */
    lua_getglobal(L, "ui");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "update_proxy_state");
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                fprintf(stderr, "jenova-ui: error in ui.update_proxy_state: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    /* If an async check is already running, skip this cycle */
    if (status_pid != 0) return TRUE;

    char *wrapped_cmd = wrap_jenova_cmd("jenova-ca status");
    gchar **argv;
    GError *error = NULL;
    if (g_shell_parse_argv(wrapped_cmd, NULL, &argv, &error)) {
        gint status_out_fd = -1;
        if (g_spawn_async_with_pipes(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, &status_pid, NULL, &status_out_fd, NULL, &error)) {
            status_output = g_string_new("");
            GIOChannel *channel = g_io_channel_unix_new(status_out_fd);
            g_io_channel_set_encoding(channel, NULL, NULL);
            g_io_channel_set_close_on_unref(channel, TRUE);
            g_io_add_watch(channel, G_IO_IN | G_IO_ERR | G_IO_HUP, on_status_output_read, NULL);
            g_io_channel_unref(channel);
        } else {
            g_error_free(error);
        }
        g_strfreev(argv);
    } else {
        g_error_free(error);
    }
    free(wrapped_cmd);

    return TRUE;
}

/* ---------------------------------------------------------------------------
 * run_tray: Single-instance tray icon with GTK main loop.
 * --------------------------------------------------------------------------- */
static gboolean run_tray(int argc, char *argv[]) {
    if (!gtk_init_check(&argc, &argv)) {
        return FALSE;
    }

    /* Single-instance lock (per-user) */
    char lock_path[PATH_MAX];
    char dir_path[PATH_MAX - 32];
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    
    int lock_fd = -1;
    int n1 = snprintf(dir_path, sizeof(dir_path), "%s/.jenova", home);
    if (n1 >= 0 && n1 < (int)sizeof(dir_path)) {
        int n2 = snprintf(lock_path, sizeof(lock_path), "%s/ui.lock", dir_path);
        if (n2 >= 0 && n2 < (int)sizeof(lock_path)) {
            /* Ensure .jenova directory exists */
            g_mkdir_with_parents(dir_path, 0700);
            lock_fd = open(lock_path, O_CREAT | O_RDWR, 0600);
        }
    }

    if (lock_fd == -1) {
        fprintf(stderr, "jenova-ui: cannot safely create or open lockfile\n");
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

    /* Initialize Chat GUI Window */
    init_gui();

    /* Build initial context menu from Lua */
    rebuild_tray_menu();

    /* Poll server status every 3 seconds */
    g_timeout_add_seconds(3, update_tray_status, NULL);
    update_tray_status(NULL);

    gtk_main();
    return TRUE;
}

/* ===========================================================================
 *  TUI (ncurses)
 * =========================================================================== */

/* ---------------------------------------------------------------------------
 * rebuild_tray_menu: (Re)builds the GTK context menu from ui.get_menu().
 * Called at startup and after state-changing actions (LAN toggle, etc.).
 * --------------------------------------------------------------------------- */
static void present_main_window(GtkWidget *win) {
    gtk_widget_show_all(win);
    gtk_window_present(GTK_WINDOW(win));
    g_ui_state.is_visible = 1;
}

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
                        if (strcmp(action, "open_gui") == 0) {
                            GtkWidget *item = gtk_menu_item_new_with_label("Open Window");
                            g_signal_connect_swapped(item, "activate", G_CALLBACK(present_main_window), g_ui_state.main_window);
                            gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
                            lua_pop(L, 1);
                            continue;
                        }
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
        if (strncmp(mode, "LAN", 3) == 0) {
            attron(COLOR_PAIR(3));
            mvprintw(5, 16, "%s", mode);
            attroff(COLOR_PAIR(3));
        } else {
            mvprintw(5, 16, "%s", mode);
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
