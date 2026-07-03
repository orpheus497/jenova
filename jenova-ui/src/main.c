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
#include <dirent.h>
#include <sys/stat.h>

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
#include "chat_bedrock.h"

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
    GtkWidget *chats_list;
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
    GtkWidget *notebook;
    GtkWidget *editor_textview;
    GtkWidget *editor_path_label;
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

typedef struct {
    lua_State *L;
    int callback_ref;
    GPid pid;
} StreamState;

static void on_stream_child_exit(GPid pid, gint status G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
    g_spawn_close_pid(pid);
}

static gboolean on_stream_read(GIOChannel *source, GIOCondition condition, gpointer data) {
    StreamState *state = (StreamState *)data;
    gchar buf[4096];
    gsize bytes_read;
    
    GIOStatus status = g_io_channel_read_chars(source, buf, sizeof(buf) - 1, &bytes_read, NULL);
    if (status == G_IO_STATUS_NORMAL && bytes_read > 0) {
        buf[bytes_read] = '\0';
        
        lua_rawgeti(state->L, LUA_REGISTRYINDEX, state->callback_ref);
        lua_pushstring(state->L, buf);
        if (lua_pcall(state->L, 1, 0, 0) != LUA_OK) {
            g_printerr("Lua stream callback error: %s\n", lua_tostring(state->L, -1));
            lua_pop(state->L, 1);
        }
        return TRUE;
    }
    
    if (status == G_IO_STATUS_EOF || (condition & (G_IO_ERR | G_IO_HUP))) {
        lua_rawgeti(state->L, LUA_REGISTRYINDEX, state->callback_ref);
        lua_pushnil(state->L);
        if (lua_pcall(state->L, 1, 0, 0) != LUA_OK) {
            g_printerr("Lua stream EOF callback error: %s\n", lua_tostring(state->L, -1));
            lua_pop(state->L, 1);
        }
        luaL_unref(state->L, LUA_REGISTRYINDEX, state->callback_ref);
        g_free(state);
        return FALSE;
    }
    return TRUE;
}

static int l_sys_exec_stream(lua_State *Ls) {
    const char *cmd = luaL_checkstring(Ls, 1);
    if (!lua_isfunction(Ls, 2)) {
        luaL_error(Ls, "Expected callback function as 2nd argument");
        return 0;
    }
    
    lua_pushvalue(Ls, 2);
    int ref = luaL_ref(Ls, LUA_REGISTRYINDEX);
    
    char *wrapped_cmd = wrap_jenova_cmd(cmd);
    gint out_fd;
    GPid pid;
    GError *error = NULL;
    gchar **argv = NULL;
    
    if (g_shell_parse_argv(wrapped_cmd, NULL, &argv, &error) &&
        g_spawn_async_with_pipes(NULL, argv, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &pid, NULL, &out_fd, NULL, &error)) {
        
        StreamState *state = g_new(StreamState, 1);
        state->L = Ls;
        state->callback_ref = ref;
        state->pid = pid;
        
        g_child_watch_add(pid, on_stream_child_exit, NULL);
        
        GIOChannel *channel = g_io_channel_unix_new(out_fd);
        g_io_channel_set_close_on_unref(channel, TRUE);
        g_io_channel_set_encoding(channel, NULL, NULL);
        g_io_channel_set_flags(channel, G_IO_FLAG_NONBLOCK, NULL);
        g_io_add_watch(channel, G_IO_IN | G_IO_HUP | G_IO_ERR, on_stream_read, state);
        g_io_channel_unref(channel);
    } else {
        g_printerr("sys_exec_stream error: %s\n", error->message);
        g_error_free(error);
        luaL_unref(Ls, LUA_REGISTRYINDEX, ref);
    }
    
    if (argv) g_strfreev(argv);
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

static void on_detect_hardware_clicked(GtkWidget *widget G_GNUC_UNUSED, gpointer data) {
    GtkWidget *dialog = (GtkWidget *)data;
    
    lua_getglobal(L, "require");
    lua_pushstring(L, "settings");
    if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
        lua_getfield(L, -1, "detect_hardware");
        lua_pushstring(L, get_jenova_root());
        if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
            const char *res = lua_tostring(L, -1);
            
            GtkWidget *msg = gtk_message_dialog_new(GTK_WINDOW(dialog),
                                                    GTK_DIALOG_DESTROY_WITH_PARENT,
                                                    GTK_MESSAGE_INFO,
                                                    GTK_BUTTONS_OK,
                                                    "Hardware Detection Result:\n%s", res ? res : "No result");
            gtk_dialog_run(GTK_DIALOG(msg));
            gtk_widget_destroy(msg);
            
            lua_pop(L, 1);
        } else {
            g_printerr("detect_hardware failed: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    } else {
        g_printerr("Failed to require settings: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

static void show_settings_dialog(void) {
    GtkWidget *dialog = gtk_dialog_new_with_buttons("Settings & Configuration",
                                                    GTK_WINDOW(g_ui_state.main_window),
                                                    GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                                    "Cancel", GTK_RESPONSE_CANCEL,
                                                    "Save", GTK_RESPONSE_ACCEPT,
                                                    NULL);
    gtk_window_set_default_size(GTK_WINDOW(dialog), 400, 300);
    GtkWidget *content_area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    gtk_container_set_border_width(GTK_CONTAINER(content_area), 16);
    gtk_box_set_spacing(GTK_BOX(content_area), 8);

    lua_getglobal(L, "require");
    lua_pushstring(L, "settings");
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        g_printerr("Failed to require settings: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        gtk_widget_destroy(dialog);
        return;
    }
    
    char conf_path[PATH_MAX];
    snprintf(conf_path, sizeof(conf_path), "%s/etc/jenova.conf", get_jenova_root());
    
    lua_getfield(L, -1, "parse_config");
    lua_pushstring(L, conf_path);
    
    char ctx_size[64] = "8192";
    char backend[64] = "Vulkan0";
    char spec_decode[64] = "0";

    if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "map");
            if (lua_istable(L, -1)) {
                lua_getfield(L, -1, "CTX_SIZE");
                if (lua_isstring(L, -1)) {
                    strncpy(ctx_size, lua_tostring(L, -1), sizeof(ctx_size)-1);
                    ctx_size[sizeof(ctx_size)-1] = '\0';
                }
                lua_pop(L, 1);
                
                lua_getfield(L, -1, "DEVICES");
                if (lua_isstring(L, -1)) {
                    strncpy(backend, lua_tostring(L, -1), sizeof(backend)-1);
                    backend[sizeof(backend)-1] = '\0';
                }
                lua_pop(L, 1);

                lua_getfield(L, -1, "JENOVA_DRAFT");
                if (lua_isstring(L, -1)) {
                    strncpy(spec_decode, lua_tostring(L, -1), sizeof(spec_decode)-1);
                    spec_decode[sizeof(spec_decode)-1] = '\0';
                }
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    } else {
        g_printerr("Failed to parse config: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 12);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 16);
    gtk_box_pack_start(GTK_BOX(content_area), grid, TRUE, TRUE, 0);
    
    GtkWidget *lbl_ctx = gtk_label_new("Context Size:");
    gtk_widget_set_halign(lbl_ctx, GTK_ALIGN_END);
    GtkWidget *entry_ctx = gtk_entry_new();
    gtk_entry_set_text(GTK_ENTRY(entry_ctx), ctx_size);
    gtk_grid_attach(GTK_GRID(grid), lbl_ctx, 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), entry_ctx, 1, 0, 1, 1);
    
    GtkWidget *lbl_backend = gtk_label_new("Backend Device:");
    gtk_widget_set_halign(lbl_backend, GTK_ALIGN_END);
    GtkWidget *entry_backend = gtk_entry_new();
    gtk_entry_set_text(GTK_ENTRY(entry_backend), backend);
    gtk_grid_attach(GTK_GRID(grid), lbl_backend, 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), entry_backend, 1, 1, 1, 1);

    GtkWidget *lbl_spec = gtk_label_new("Speculative Decoding:");
    gtk_widget_set_halign(lbl_spec, GTK_ALIGN_END);
    GtkWidget *switch_spec = gtk_switch_new();
    gtk_switch_set_active(GTK_SWITCH(switch_spec), strcmp(spec_decode, "1") == 0);
    gtk_widget_set_halign(switch_spec, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), lbl_spec, 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), switch_spec, 1, 2, 1, 1);

    GtkWidget *btn_detect = gtk_button_new_with_label("Auto-Detect Hardware");
    g_signal_connect(btn_detect, "clicked", G_CALLBACK(on_detect_hardware_clicked), dialog);
    gtk_grid_attach(GTK_GRID(grid), btn_detect, 0, 3, 2, 1);
    
    gtk_widget_show_all(dialog);
    gint response = gtk_dialog_run(GTK_DIALOG(dialog));
    
    if (response == GTK_RESPONSE_ACCEPT) {
        const gchar *new_ctx = gtk_entry_get_text(GTK_ENTRY(entry_ctx));
        const gchar *new_backend = gtk_entry_get_text(GTK_ENTRY(entry_backend));
        gboolean new_spec = gtk_switch_get_active(GTK_SWITCH(switch_spec));
        
        lua_getfield(L, -1, "parse_config");
        lua_pushstring(L, conf_path);
        if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
            lua_getfield(L, -2, "save_config");
            lua_pushstring(L, conf_path);
            lua_pushvalue(L, -3);
            
            lua_newtable(L);
            lua_pushstring(L, "CTX_SIZE"); lua_pushstring(L, new_ctx); lua_settable(L, -3);
            lua_pushstring(L, "DEVICES"); lua_pushstring(L, new_backend); lua_settable(L, -3);
            lua_pushstring(L, "JENOVA_DRAFT"); lua_pushstring(L, new_spec ? "1" : "0"); lua_settable(L, -3);
            
            if (lua_pcall(L, 3, 1, 0) != LUA_OK) {
                g_printerr("Failed to save config: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            } else {
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
        } else {
            lua_pop(L, 1);
        }
    }
    
    lua_pop(L, 1); // pop settings_module
    gtk_widget_destroy(dialog);
}

static void on_chats_list_row_activated(GtkListBox *box G_GNUC_UNUSED, GtkListBoxRow *row, gpointer data G_GNUC_UNUSED) {
    const gchar *conv_id = g_object_get_data(G_OBJECT(row), "conv_id");
    if (!conv_id) return;
    
    lua_getglobal(L, "ui");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "on_action");
        if (lua_isfunction(L, -1)) {
            lua_pushstring(L, "switch_chat");
            lua_pushstring(L, conv_id);
            if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                g_printerr("error in on_action: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}

static void on_gui_button_clicked(GtkWidget *widget G_GNUC_UNUSED, gpointer data) {
    const char *action = (const char *)data;
    
    if (strcmp(action, "settings") == 0) {
        show_settings_dialog();
        return;
    }

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
        "notebook, notebook stack { background-color: transparent; border: none; box-shadow: none; }\n"
        "notebook header { background-color: transparent; border: none; box-shadow: none; border-bottom: 2px solid rgba(43, 30, 58, 0.5); padding-top: 5px; }\n"
        "notebook tab { background-color: transparent; border: none; padding: 2px 12px; box-shadow: none; transition: all 0.2s ease-in-out; margin: 0 4px; border-radius: 8px 8px 0 0; }\n"
        "notebook tab label { color: #5e5966; font-family: 'Inter', 'Segoe UI', sans-serif; font-weight: 600; font-size: 14px; }\n"
        "notebook tab:hover { background-color: #1c1b1b; }\n"
        "notebook tab:hover label { color: #f0edf2; }\n"
        "notebook tab:checked { background-color: #2b1e3a; border-bottom: none; box-shadow: inset 0 -3px 0 0 #e4b382; }\n"
        "notebook tab:checked label { color: #e4b382; }\n"
        /* Glass Panel */
        ".glass-panel { background-color: rgba(43, 30, 58, 0.4); border: 1px solid rgba(228, 179, 130, 0.1); border-radius: 12px; padding: 16px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }\n"
        ".sidebar-panel { background-color: rgba(19, 19, 19, 0.7); border: none; border-radius: 0 24px 24px 0; padding: 16px; box-shadow: 4px 0 15px rgba(0,0,0,0.5); }\n"
        /* Labels */
        "label { color: #f0edf2; font-family: 'DejaVuSansM Nerd Font', 'DejaVu Sans Mono', monospace; font-size: 12pt; }\n"
        "label.title { font-weight: 800; font-size: 24px; color: #e4b382; letter-spacing: 1px; text-shadow: 0 2px 4px rgba(0,0,0,0.5); }\n"
        "label.status-active { color: #a3e635; font-weight: 700; font-size: 14px; }\n"
        "label.status-inactive { color: #c96464; font-weight: 700; font-size: 14px; }\n"
        "label.mode-label { color: #aba0d9; font-weight: 700; font-size: 14px; }\n"
        ".color-note { color: #e4b382; }\n"
        ".color-file { color: #c96464; }\n"
        ".color-chat { color: #7b52ab; }\n"
        ".color-chat:hover, .color-note:hover, .color-file:hover { color: #f0edf2; }\n"
        /* Buttons */
        "button { background-image: none; background-color: #2b1e3a; color: #f0edf2; border: 1px solid rgba(228, 179, 130, 0.2); border-radius: 8px; padding: 4px 10px; font-weight: 600; font-size: 12px; font-family: 'DejaVuSansM Nerd Font', 'DejaVu Sans Mono', monospace; box-shadow: 0 2px 4px rgba(0,0,0,0.2); transition: all 0.2s ease; }\n"
        "button:hover { background-color: #3d2b52; border-color: rgba(228, 179, 130, 0.4); box-shadow: 0 4px 8px rgba(0,0,0,0.4); }\n"
        "button:active { background-color: #1a1223; box-shadow: none; }\n"
        "button.stop-btn:hover { background-color: #c96464; border-color: #ffb3b3; color: #ffffff; }\n"
        /* Sidebar Elements */
        ".logo-box { border: 1px solid rgba(43, 30, 58, 0.3); border-radius: 12px; box-shadow: 0 0 15px rgba(43, 30, 58, 0.4); overflow: hidden; }\n"
        ".sidebar-btn { background-color: transparent; border: none; box-shadow: none; border-radius: 8px; padding: 8px 12px; font-weight: 400; font-size: 13px; }\n"
        ".sidebar-btn:hover { background-color: rgba(255, 255, 255, 0.05); color: #7b52ab; }\n"
        ".section-header { font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: 600; color: #9fa0a6; letter-spacing: 2px; text-transform: uppercase; background-color: transparent; border: none; box-shadow: none; padding: 4px 8px; }\n"
        ".section-header:hover { color: #f0edf2; background-color: transparent; }\n"
        ".tree-item { background-color: transparent; color: #f0edf2; border: none; box-shadow: none; border-radius: 6px; padding: 6px 12px; font-size: 13px; font-weight: 400; }\n"
        ".tree-item:hover { background-color: rgba(255, 255, 255, 0.05); }\n"
        ".tree-header { font-size: 10px; font-weight: 700; color: #7b52ab; letter-spacing: 1px; text-transform: uppercase; margin-top: 8px; margin-bottom: 4px; }\n"
        ;
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
                                              GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
    
    chat_bedrock_load_css();
}


static void on_sidebar_item_clicked(GtkButton *btn, gpointer user_data G_GNUC_UNUSED) {
    const char *filepath = g_object_get_data(G_OBJECT(btn), "filepath");
    if (!filepath) return;
    
    lua_getglobal(L, "ui");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "on_file_clicked");
    if (lua_isfunction(L, -1)) {
        lua_pushstring(L, filepath);
        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            fprintf(stderr, "jenova-ui: error in ui.on_file_clicked: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    } else {
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

static GtkWidget* create_tree_item_button(const char *label_text, const char *icon_name, const char *filepath, GCallback click_cb) {
    GtkWidget *btn = gtk_button_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(btn), "tree-item");
    GtkWidget *lbl = gtk_label_new(label_text);
    gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
    
    if (icon_name) {
        GtkWidget *btn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget *icon = gtk_image_new_from_icon_name(icon_name, GTK_ICON_SIZE_BUTTON);
        gtk_box_pack_start(GTK_BOX(btn_box), icon, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(btn_box), lbl, TRUE, TRUE, 0);
        gtk_container_add(GTK_CONTAINER(btn), btn_box);
    } else {
        gtk_container_add(GTK_CONTAINER(btn), lbl);
    }
    
    if (filepath) {
        g_object_set_data_full(G_OBJECT(btn), "filepath", g_strdup(filepath), g_free);
    }
    if (click_cb) {
        g_signal_connect(btn, "clicked", click_cb, NULL);
    }
    return btn;
}

static void populate_container_from_dir(const char *dir_path, GtkWidget *container, const char *icon_name, gboolean only_md, GCallback click_cb) {
    if (!container) return;
    DIR *dir = opendir(dir_path);
    if (!dir) return;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        if (only_md && !strstr(ent->d_name, ".md")) continue;
        
        char name_no_ext[256];
        snprintf(name_no_ext, sizeof(name_no_ext), "%s", ent->d_name);
        if (only_md) {
            char *dot = strrchr(name_no_ext, '.');
            if (dot) *dot = '\0';
        }
        if (strlen(name_no_ext) > 27) {
            name_no_ext[27] = '.'; name_no_ext[28] = '.'; name_no_ext[29] = '.'; name_no_ext[30] = '\0';
        }
        char abs_path[PATH_MAX];
        snprintf(abs_path, sizeof(abs_path), "%s/%s", dir_path, ent->d_name);
        GtkWidget *btn = create_tree_item_button(name_no_ext, icon_name, abs_path, click_cb);
        gtk_box_pack_start(GTK_BOX(container), btn, FALSE, FALSE, 0);
    }
    closedir(dir);
}

static void populate_sidebar_dynamic(GtkWidget *ws_container, GtkWidget *chats_container, GtkWidget *notes_container, GtkWidget *files_container) {
    char default_ws_path[PATH_MAX];
    const char *jca_env = getenv("JENOVA_WORKSPACES");
    if (jca_env) {
        snprintf(default_ws_path, sizeof(default_ws_path), "%s/default", jca_env);
    } else {
        const char *home = getenv("HOME");
        snprintf(default_ws_path, sizeof(default_ws_path), "%s/JCA/Workspaces/default", home ? home : "/tmp");
    }
    
    DIR *dir = opendir(default_ws_path);
    if (!dir) return;
    
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        
        char full_path[PATH_MAX];
        snprintf(full_path, sizeof(full_path), "%s/%s", default_ws_path, ent->d_name);
        
        struct stat st;
        if (stat(full_path, &st) == 0 && S_ISDIR(st.st_mode)) {
            if (strcmp(ent->d_name, "Chats") == 0) {
                DIR *cdir = opendir(full_path);
                if (cdir) {
                    struct dirent *cent;
                    while ((cent = readdir(cdir)) != NULL) {
                        if (strstr(cent->d_name, ".md")) {
                            char name_no_ext[256];
                            strncpy(name_no_ext, cent->d_name, sizeof(name_no_ext));
                            char *dot = strrchr(name_no_ext, '.');
                            if (dot) *dot = '\0';
                            if (strlen(name_no_ext) > 27) {
                                name_no_ext[27] = '.'; name_no_ext[28] = '.'; name_no_ext[29] = '.'; name_no_ext[30] = '\0';
                            }
                            
                            GtkWidget *btn = gtk_button_new_with_label(name_no_ext);
                            gtk_label_set_xalign(GTK_LABEL(gtk_bin_get_child(GTK_BIN(btn))), 0.0);
                            gtk_style_context_add_class(gtk_widget_get_style_context(btn), "tree-item");
                            
                            char abs_path[PATH_MAX];
                            snprintf(abs_path, sizeof(abs_path), "%s/%s", full_path, cent->d_name);
                            g_object_set_data_full(G_OBJECT(btn), "filepath", g_strdup(abs_path), g_free);
                            g_signal_connect(btn, "clicked", G_CALLBACK(on_sidebar_item_clicked), NULL);
                            
                            gtk_box_pack_start(GTK_BOX(chats_container), btn, FALSE, FALSE, 0);
                        }
                    }
                    closedir(cdir);
                }
            } else if (strcmp(ent->d_name, "Notes") == 0) {
                DIR *ndir = opendir(full_path);
                if (ndir) {
                    struct dirent *nent;
                    while ((nent = readdir(ndir)) != NULL) {
                        if (strstr(nent->d_name, ".md")) {
                            char name_no_ext[256];
                            strncpy(name_no_ext, nent->d_name, sizeof(name_no_ext));
                            char *dot = strrchr(name_no_ext, '.');
                            if (dot) *dot = '\0';
                            if (strlen(name_no_ext) > 27) {
                                name_no_ext[27] = '.'; name_no_ext[28] = '.'; name_no_ext[29] = '.'; name_no_ext[30] = '\0';
                            }
                            
                            GtkWidget *btn = gtk_button_new();
                            gtk_style_context_add_class(gtk_widget_get_style_context(btn), "tree-item");
                            GtkWidget *btn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                            GtkWidget *icon = gtk_image_new_from_icon_name("text-x-generic-symbolic", GTK_ICON_SIZE_BUTTON);
                            GtkWidget *lbl = gtk_label_new(name_no_ext);
                            gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END);
                            gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
                            gtk_box_pack_start(GTK_BOX(btn_box), icon, FALSE, FALSE, 0);
                            gtk_box_pack_start(GTK_BOX(btn_box), lbl, TRUE, TRUE, 0);
                            gtk_container_add(GTK_CONTAINER(btn), btn_box);
                            
                            char abs_path[PATH_MAX];
                            snprintf(abs_path, sizeof(abs_path), "%s/%s", full_path, nent->d_name);
                            g_object_set_data_full(G_OBJECT(btn), "filepath", g_strdup(abs_path), g_free);
                            g_signal_connect(btn, "clicked", G_CALLBACK(on_sidebar_item_clicked), NULL);
                            
                            gtk_box_pack_start(GTK_BOX(notes_container), btn, FALSE, FALSE, 0);
                        }
                    }
                    closedir(ndir);
                }
            } else if (strcmp(ent->d_name, "Files") == 0) {
                populate_container_from_dir(full_path, files_container, "text-x-generic-symbolic", FALSE, G_CALLBACK(on_sidebar_item_clicked));
            } else {
                GtkWidget *exp = gtk_expander_new(NULL);
                GtkWidget *hdr_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                GtkWidget *icon = gtk_image_new_from_icon_name("folder-symbolic", GTK_ICON_SIZE_MENU);
                GtkWidget *lbl = gtk_label_new(ent->d_name);
                gtk_box_pack_start(GTK_BOX(hdr_box), icon, FALSE, FALSE, 0);
                gtk_box_pack_start(GTK_BOX(hdr_box), lbl, TRUE, TRUE, 0);
                gtk_expander_set_label_widget(GTK_EXPANDER(exp), hdr_box);
                
                GtkWidget *inner_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
                gtk_container_add(GTK_CONTAINER(exp), inner_vbox);
                
                // Parse Chats
                char sub_path[PATH_MAX];
                snprintf(sub_path, sizeof(sub_path), "%s/Chats", full_path);
                DIR *cdir = opendir(sub_path);
                if (cdir) {
                    GtkWidget *c_hdr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
                    GtkWidget *c_lbl = gtk_label_new(NULL);
                    gtk_label_set_markup(GTK_LABEL(c_lbl), "<span color='#7b52ab' font_desc='JetBrains Mono Bold 10' letter_spacing='500'>CHATS</span>");
                    gtk_box_pack_start(GTK_BOX(c_hdr), c_lbl, TRUE, TRUE, 4);
                    gtk_box_pack_start(GTK_BOX(inner_vbox), c_hdr, FALSE, FALSE, 4);
                    
                    struct dirent *cent;
                    while ((cent = readdir(cdir)) != NULL) {
                        if (strstr(cent->d_name, ".md")) {
                            char name_no_ext[256];
                            strncpy(name_no_ext, cent->d_name, sizeof(name_no_ext));
                            char *dot = strrchr(name_no_ext, '.');
                            if (dot) *dot = '\0';
                            if (strlen(name_no_ext) > 27) {
                                name_no_ext[27] = '.'; name_no_ext[28] = '.'; name_no_ext[29] = '.'; name_no_ext[30] = '\0';
                            }
                            
                            GtkWidget *btn = gtk_button_new();
                            gtk_style_context_add_class(gtk_widget_get_style_context(btn), "tree-item");
                            GtkWidget *lbl = gtk_label_new(name_no_ext);
                            gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END);
                            gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
                            gtk_container_add(GTK_CONTAINER(btn), lbl);
                            
                            char abs_path[PATH_MAX];
                            snprintf(abs_path, sizeof(abs_path), "%s/%s", sub_path, cent->d_name);
                            g_object_set_data_full(G_OBJECT(btn), "filepath", g_strdup(abs_path), g_free);
                            g_signal_connect(btn, "clicked", G_CALLBACK(on_sidebar_item_clicked), NULL);
                            
                            gtk_box_pack_start(GTK_BOX(inner_vbox), btn, FALSE, FALSE, 0);
                        }
                    }
                    closedir(cdir);
                }

                // Parse Notes
                snprintf(sub_path, sizeof(sub_path), "%s/Notes", full_path);
                DIR *ndir = opendir(sub_path);
                if (ndir) {
                    GtkWidget *n_hdr = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
                    GtkWidget *n_lbl = gtk_label_new(NULL);
                    gtk_label_set_markup(GTK_LABEL(n_lbl), "<span color='#e4b382' font_desc='JetBrains Mono Bold 10' letter_spacing='500'>NOTES</span>");
                    gtk_box_pack_start(GTK_BOX(n_hdr), n_lbl, TRUE, TRUE, 4);
                    gtk_box_pack_start(GTK_BOX(inner_vbox), n_hdr, FALSE, FALSE, 4);
                    
                    struct dirent *nent;
                    while ((nent = readdir(ndir)) != NULL) {
                        if (strstr(nent->d_name, ".md")) {
                            char name_no_ext[256];
                            strncpy(name_no_ext, nent->d_name, sizeof(name_no_ext));
                            char *dot = strrchr(name_no_ext, '.');
                            if (dot) *dot = '\0';
                            if (strlen(name_no_ext) > 27) {
                                name_no_ext[27] = '.'; name_no_ext[28] = '.'; name_no_ext[29] = '.'; name_no_ext[30] = '\0';
                            }
                            
                            GtkWidget *btn = gtk_button_new();
                            gtk_style_context_add_class(gtk_widget_get_style_context(btn), "tree-item");
                            GtkWidget *btn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                            GtkWidget *bicon = gtk_image_new_from_icon_name("text-x-generic-symbolic", GTK_ICON_SIZE_BUTTON);
                            GtkWidget *blbl = gtk_label_new(name_no_ext);
                            gtk_label_set_ellipsize(GTK_LABEL(blbl), PANGO_ELLIPSIZE_END);
                            gtk_label_set_xalign(GTK_LABEL(blbl), 0.0);
                            gtk_box_pack_start(GTK_BOX(btn_box), bicon, FALSE, FALSE, 0);
                            gtk_box_pack_start(GTK_BOX(btn_box), blbl, TRUE, TRUE, 0);
                            gtk_container_add(GTK_CONTAINER(btn), btn_box);
                            
                            char abs_path[PATH_MAX];
                            snprintf(abs_path, sizeof(abs_path), "%s/%s", sub_path, nent->d_name);
                            g_object_set_data_full(G_OBJECT(btn), "filepath", g_strdup(abs_path), g_free);
                            g_signal_connect(btn, "clicked", G_CALLBACK(on_sidebar_item_clicked), NULL);
                            
                            gtk_box_pack_start(GTK_BOX(inner_vbox), btn, FALSE, FALSE, 0);
                        }
                    }
                    closedir(ndir);
                }

                // Files Button
                GtkWidget *btn_files = gtk_button_new();
                gtk_style_context_add_class(gtk_widget_get_style_context(btn_files), "tree-item");
                gtk_style_context_add_class(gtk_widget_get_style_context(btn_files), "color-file");
                GtkWidget *f_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                GtkWidget *f_icon = gtk_image_new_from_icon_name("folder-symbolic", GTK_ICON_SIZE_BUTTON);
                GtkWidget *f_lbl = gtk_label_new("Files");
                gtk_box_pack_start(GTK_BOX(f_box), f_icon, FALSE, FALSE, 0);
                gtk_box_pack_start(GTK_BOX(f_box), f_lbl, FALSE, FALSE, 0);
                gtk_container_add(GTK_CONTAINER(btn_files), f_box);
                gtk_widget_set_margin_top(btn_files, 4);
                
                char abs_path[PATH_MAX];
                snprintf(abs_path, sizeof(abs_path), "%s/Files", full_path);
                g_object_set_data_full(G_OBJECT(btn_files), "filepath", g_strdup(abs_path), g_free);
                g_signal_connect(btn_files, "clicked", G_CALLBACK(on_sidebar_item_clicked), NULL);
                
                gtk_box_pack_start(GTK_BOX(inner_vbox), btn_files, FALSE, FALSE, 2);
                
                gtk_box_pack_start(GTK_BOX(ws_container), exp, FALSE, FALSE, 2);
            }
        }
    }
    closedir(dir);
    
    gtk_widget_show_all(ws_container);
    gtk_widget_show_all(chats_container);
    gtk_widget_show_all(notes_container);
    if (files_container) gtk_widget_show_all(files_container);
}

static void on_editor_save_clicked(GtkWidget *widget G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
    if (!g_ui_state.editor_path_label || !g_ui_state.editor_textview) return;
    const char *path = gtk_label_get_text(GTK_LABEL(g_ui_state.editor_path_label));
    if (!path || strcmp(path, "No file loaded") == 0) return;
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(g_ui_state.editor_textview));
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buf, &start, &end);
    char *text = gtk_text_buffer_get_text(buf, &start, &end, FALSE);
    FILE *f = fopen(path, "w");
    if (f) {
        fputs(text, f);
        fclose(f);
    }
    g_free(text);
}

static void on_toggle_sidebar_clicked(GtkButton *btn, gpointer revealer) {
    (void)btn;
    gboolean is_revealed = gtk_revealer_get_reveal_child(GTK_REVEALER(revealer));
    gtk_revealer_set_reveal_child(GTK_REVEALER(revealer), !is_revealed);
}

static void init_gui(void) {
    load_css();
    g_ui_state.main_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(g_ui_state.main_window), "JENOVA AI - Native UI");
    gtk_window_set_default_size(GTK_WINDOW(g_ui_state.main_window), 1000, 700);
    gtk_window_set_position(GTK_WINDOW(g_ui_state.main_window), GTK_WIN_POS_CENTER);
    
    GtkStyleContext *ctx = gtk_widget_get_style_context(g_ui_state.main_window);
    gtk_style_context_add_class(ctx, "jenova-window");
    g_signal_connect(g_ui_state.main_window, "delete-event", G_CALLBACK(on_window_delete_event), NULL);

    GtkWidget *overlay = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(g_ui_state.main_window), overlay);

    GtkWidget *bg_canvas = create_neural_canvas();
    gtk_container_add(GTK_CONTAINER(overlay), bg_canvas);

    GtkWidget *main_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    
    GtkWidget *sidebar_revealer = gtk_revealer_new();
    gtk_revealer_set_transition_type(GTK_REVEALER(sidebar_revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT);
    gtk_revealer_set_transition_duration(GTK_REVEALER(sidebar_revealer), 250);
    gtk_revealer_set_reveal_child(GTK_REVEALER(sidebar_revealer), TRUE);
    
    /* LEFT SIDEPANEL */
    GtkWidget *sidebar_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_style_context_add_class(gtk_widget_get_style_context(sidebar_vbox), "sidebar-panel");
    gtk_widget_set_size_request(sidebar_vbox, 280, -1);
    
    // Header Logo & Title
    GtkWidget *header_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
    
    GtkWidget *logo_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_style_context_add_class(gtk_widget_get_style_context(logo_box), "logo-box");
    char img_path[PATH_MAX];
    snprintf(img_path, sizeof(img_path), "%s/png/jenova.jpg", get_jenova_root());
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(img_path, NULL);
    GtkWidget *image = gtk_image_new();
    if (pixbuf) {
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixbuf, 48, 48, GDK_INTERP_BILINEAR);
        if (scaled) {
            gtk_image_set_from_pixbuf(GTK_IMAGE(image), scaled);
            g_object_unref(scaled);
        }
        g_object_unref(pixbuf);
    }
    gtk_container_add(GTK_CONTAINER(logo_box), image);
    gtk_box_pack_start(GTK_BOX(header_hbox), logo_box, FALSE, FALSE, 0);
    
    GtkWidget *title_lbl = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title_lbl), 
        "<span font_desc='Inter Bold 11' letter_spacing='-500'>"
        "<span color='#7b52ab'>JENOVA</span>\n"
        "<span color='#c96464'>COGNITIVE</span>\n"
        "<span color='#e4b382'>ARCHITECTURE</span>"
        "</span>");
    gtk_label_set_justify(GTK_LABEL(title_lbl), GTK_JUSTIFY_LEFT);
    gtk_label_set_xalign(GTK_LABEL(title_lbl), 0.0);
    gtk_box_pack_start(GTK_BOX(header_hbox), title_lbl, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), header_hbox, FALSE, FALSE, 8);
    
    // Action Grid
    GtkWidget *action_grid = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(action_grid), 4);
    gtk_grid_set_row_spacing(GTK_GRID(action_grid), 4);
    gtk_grid_set_column_homogeneous(GTK_GRID(action_grid), TRUE);
    
    struct {
        const char *label; const char *icon_name; const char *action; int col; int row;
    } actions[] = {
        {"New chat", "document-new-symbolic", "new_chat", 0, 0},
        {"Search", "system-search-symbolic", "search", 1, 0},
        {"MCP Ser...", "network-server-symbolic", "mcp", 0, 1},
        {"Settings", "preferences-system-symbolic", "settings", 1, 1}
    };
    
    for (int i=0; i<4; i++) {
        GtkWidget *btn = gtk_button_new();
        gtk_style_context_add_class(gtk_widget_get_style_context(btn), "sidebar-btn");
        
        GtkWidget *btn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget *icon = gtk_image_new_from_icon_name(actions[i].icon_name, GTK_ICON_SIZE_BUTTON);
        GtkWidget *lbl = gtk_label_new(actions[i].label);
        gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
        
        gtk_box_pack_start(GTK_BOX(btn_box), icon, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(btn_box), lbl, TRUE, TRUE, 0);
        gtk_container_add(GTK_CONTAINER(btn), btn_box);
        
        g_signal_connect(btn, "clicked", G_CALLBACK(on_gui_button_clicked), (gpointer)actions[i].action);
        gtk_grid_attach(GTK_GRID(action_grid), btn, actions[i].col, actions[i].row, 1, 1);
    }
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), action_grid, FALSE, FALSE, 8);
    
    GtkWidget *sidebar_scroll_win = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sidebar_scroll_win), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(sidebar_scroll_win, TRUE);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), sidebar_scroll_win, TRUE, TRUE, 0);

    GtkWidget *sidebar_scroll_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(sidebar_scroll_win), sidebar_scroll_vbox);

    // Workspaces
    GtkWidget *ws_exp = gtk_expander_new(NULL);
    GtkWidget *ws_hdr_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *ws_lbl = gtk_label_new("WORKSPACES");
    gtk_style_context_add_class(gtk_widget_get_style_context(ws_lbl), "section-header");
    gtk_box_pack_start(GTK_BOX(ws_hdr_box), ws_lbl, TRUE, TRUE, 0);
    
    GtkWidget *icon_grid = gtk_image_new_from_icon_name("view-grid-symbolic", GTK_ICON_SIZE_MENU);
    GtkWidget *icon_folder = gtk_image_new_from_icon_name("folder-new-symbolic", GTK_ICON_SIZE_MENU);
    gtk_box_pack_start(GTK_BOX(ws_hdr_box), icon_grid, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(ws_hdr_box), icon_folder, FALSE, FALSE, 0);
    
    gtk_expander_set_label_widget(GTK_EXPANDER(ws_exp), ws_hdr_box);
    gtk_expander_set_expanded(GTK_EXPANDER(ws_exp), FALSE);
    GtkWidget *ws_container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_container_add(GTK_CONTAINER(ws_exp), ws_container);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), ws_exp, FALSE, FALSE, 4);
    
    // CHATS
    GtkWidget *chats_exp = gtk_expander_new(NULL);
    GtkWidget *chats_lbl = gtk_label_new("CHATS");
    gtk_style_context_add_class(gtk_widget_get_style_context(chats_lbl), "section-header");
    gtk_expander_set_label_widget(GTK_EXPANDER(chats_exp), chats_lbl);
    gtk_expander_set_expanded(GTK_EXPANDER(chats_exp), FALSE);
    GtkWidget *chats_container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_container_add(GTK_CONTAINER(chats_exp), chats_container);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), chats_exp, FALSE, FALSE, 4);
    
    // GLOBAL ASSETS
    GtkWidget *ga_lbl = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(ga_lbl), "<span color='#7b52ab' font_desc='JetBrains Mono 10' letter_spacing='1000'>GLOBAL ASSETS</span>");
    gtk_label_set_xalign(GTK_LABEL(ga_lbl), 0.0);
    gtk_widget_set_margin_top(ga_lbl, 8);
    gtk_widget_set_margin_bottom(ga_lbl, 4);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), ga_lbl, FALSE, FALSE, 0);
    
    // New Note Button
    GtkWidget *btn_new_note = gtk_button_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_new_note), "tree-item");
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_new_note), "color-note");
    GtkWidget *nn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *nn_icon = gtk_image_new_from_icon_name("text-x-generic-symbolic", GTK_ICON_SIZE_BUTTON);
    GtkWidget *nn_lbl = gtk_label_new("New Note");
    gtk_box_pack_start(GTK_BOX(nn_box), nn_icon, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(nn_box), nn_lbl, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(btn_new_note), nn_box);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), btn_new_note, FALSE, FALSE, 2);
    
    // Notes Container (for unassigned notes)
    GtkWidget *notes_container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), notes_container, FALSE, FALSE, 2);
    
    // Files Container (for unassigned files)
    GtkWidget *files_container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), files_container, FALSE, FALSE, 2);
    
    // Notes & Files row
    GtkWidget *nf_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_set_homogeneous(GTK_BOX(nf_hbox), TRUE);
    
    GtkWidget *btn_notes = gtk_button_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_notes), "tree-item");
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_notes), "color-note");
    GtkWidget *bn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(bn_box, GTK_ALIGN_CENTER);
    GtkWidget *bn_icon = gtk_image_new_from_icon_name("text-x-generic-symbolic", GTK_ICON_SIZE_BUTTON);
    GtkWidget *bn_lbl = gtk_label_new("Notes");
    gtk_box_pack_start(GTK_BOX(bn_box), bn_icon, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(bn_box), bn_lbl, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(btn_notes), bn_box);
    
    GtkWidget *btn_files = gtk_button_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_files), "tree-item");
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_files), "color-file");
    GtkWidget *bf_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(bf_box, GTK_ALIGN_CENTER);
    GtkWidget *bf_icon = gtk_image_new_from_icon_name("folder-symbolic", GTK_ICON_SIZE_BUTTON);
    GtkWidget *bf_lbl = gtk_label_new("Files");
    gtk_box_pack_start(GTK_BOX(bf_box), bf_icon, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(bf_box), bf_lbl, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(btn_files), bf_box);
    
    gtk_box_pack_start(GTK_BOX(nf_hbox), btn_notes, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(nf_hbox), btn_files, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_scroll_vbox), nf_hbox, FALSE, FALSE, 2);
    
    // Dynamic list reference (to keep compilation happy if referenced elsewhere)
    g_ui_state.chats_list = NULL; 
    
    GtkWidget *spacer = gtk_label_new(""); 
    gtk_widget_set_vexpand(spacer, TRUE);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), spacer, TRUE, TRUE, 0);
    
    gtk_container_add(GTK_CONTAINER(sidebar_revealer), sidebar_vbox);
    gtk_box_pack_start(GTK_BOX(main_hbox), sidebar_revealer, FALSE, FALSE, 0);

    /* RIGHT SIDE: Notebook */
    GtkWidget *notebook = gtk_notebook_new();
    gtk_notebook_set_tab_pos(GTK_NOTEBOOK(notebook), GTK_POS_TOP);
    
    GtkWidget *btn_toggle_sidebar = gtk_button_new_from_icon_name("sidebar-show-symbolic", GTK_ICON_SIZE_BUTTON);
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_toggle_sidebar), "sidebar-btn");
    gtk_widget_set_margin_start(btn_toggle_sidebar, 8);
    gtk_widget_set_margin_end(btn_toggle_sidebar, 8);
    g_signal_connect(btn_toggle_sidebar, "clicked", G_CALLBACK(on_toggle_sidebar_clicked), sidebar_revealer);
    gtk_notebook_set_action_widget(GTK_NOTEBOOK(notebook), btn_toggle_sidebar, GTK_PACK_START);
    gtk_widget_show_all(btn_toggle_sidebar);

    /* TAB 1: Chat Bedrock */
    GtkWidget *chat_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(chat_vbox, 16);
    gtk_widget_set_margin_bottom(chat_vbox, 16);
    gtk_widget_set_margin_start(chat_vbox, 16);
    gtk_widget_set_margin_end(chat_vbox, 16);
    
    chat_bedrock_init(chat_vbox);

    GtkWidget *tab1_label = gtk_label_new("Chat");
    gtk_notebook_append_page(GTK_NOTEBOOK(notebook), chat_vbox, tab1_label);
    
    /* TAB 2: Workspace Organizer */
    GtkWidget *organizer_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(organizer_vbox, 16);
    gtk_widget_set_margin_bottom(organizer_vbox, 16);
    gtk_widget_set_margin_start(organizer_vbox, 16);
    gtk_widget_set_margin_end(organizer_vbox, 16);
    
    // Organizer toolbar
    GtkWidget *org_toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *org_title = gtk_label_new("Workspace Organizer");
    gtk_style_context_add_class(gtk_widget_get_style_context(org_title), "title");
    GtkWidget *btn_new_ws = gtk_button_new_with_label("+ New Workspace");
    gtk_box_pack_start(GTK_BOX(org_toolbar), org_title, FALSE, FALSE, 0);
    GtkWidget *org_spacer = gtk_label_new("");
    gtk_widget_set_hexpand(org_spacer, TRUE);
    gtk_box_pack_start(GTK_BOX(org_toolbar), org_spacer, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(org_toolbar), btn_new_ws, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(organizer_vbox), org_toolbar, FALSE, FALSE, 0);

    // Organizer split view
    GtkWidget *org_paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    
    // Left: Workspaces List
    GtkWidget *ws_scroll = gtk_scrolled_window_new(NULL, NULL);
    GtkWidget *ws_list = gtk_list_box_new(); // Stub for workspaces
    gtk_container_add(GTK_CONTAINER(ws_scroll), ws_list);
    gtk_widget_set_size_request(ws_scroll, 200, -1);
    gtk_paned_pack1(GTK_PANED(org_paned), ws_scroll, FALSE, FALSE);
    
    // Right: Content Grid (Files/Chats)
    GtkWidget *content_scroll = gtk_scrolled_window_new(NULL, NULL);
    GtkWidget *content_tree = gtk_tree_view_new(); // Stub for workspace contents
    GtkCellRenderer *cr = gtk_cell_renderer_text_new();
    GtkTreeViewColumn *c1 = gtk_tree_view_column_new_with_attributes("Item Name", cr, "text", 0, NULL);
    GtkTreeViewColumn *c2 = gtk_tree_view_column_new_with_attributes("Type", cr, "text", 1, NULL);
    gtk_tree_view_append_column(GTK_TREE_VIEW(content_tree), c1);
    gtk_tree_view_append_column(GTK_TREE_VIEW(content_tree), c2);
    gtk_container_add(GTK_CONTAINER(content_scroll), content_tree);
    gtk_paned_pack2(GTK_PANED(org_paned), content_scroll, TRUE, FALSE);
    
    gtk_box_pack_start(GTK_BOX(organizer_vbox), org_paned, TRUE, TRUE, 0);

    GtkWidget *tab2_label = gtk_label_new("Organizer");
    gtk_notebook_append_page(GTK_NOTEBOOK(notebook), organizer_vbox, tab2_label);
    
    // Tab 3: Text Editor
    GtkWidget *editor_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *editor_toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(editor_toolbar, 6);
    gtk_widget_set_margin_bottom(editor_toolbar, 6);
    gtk_widget_set_margin_start(editor_toolbar, 12);
    gtk_widget_set_margin_end(editor_toolbar, 12);
    GtkWidget *btn_save = gtk_button_new_with_label("Save");
    g_signal_connect(btn_save, "clicked", G_CALLBACK(on_editor_save_clicked), NULL);
    gtk_style_context_add_class(gtk_widget_get_style_context(btn_save), "suggest-btn");
    GtkWidget *editor_path_lbl = gtk_label_new("No file loaded");
    gtk_label_set_xalign(GTK_LABEL(editor_path_lbl), 0.0);
    gtk_widget_set_hexpand(editor_path_lbl, TRUE);
    gtk_box_pack_start(GTK_BOX(editor_toolbar), editor_path_lbl, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(editor_toolbar), btn_save, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(editor_vbox), editor_toolbar, FALSE, FALSE, 0);
    
    GtkWidget *editor_scroll = gtk_scrolled_window_new(NULL, NULL);
    GtkWidget *text_view = gtk_text_view_new();
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(text_view), TRUE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(text_view), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_pixels_above_lines(GTK_TEXT_VIEW(text_view), 2);
    gtk_text_view_set_pixels_below_lines(GTK_TEXT_VIEW(text_view), 2);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(text_view), 8);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(text_view), 8);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(text_view), 8);
    gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(text_view), 8);
    gtk_container_add(GTK_CONTAINER(editor_scroll), text_view);
    gtk_box_pack_start(GTK_BOX(editor_vbox), editor_scroll, TRUE, TRUE, 0);
    
    g_ui_state.editor_textview = text_view;
    g_ui_state.editor_path_label = editor_path_lbl;
    g_ui_state.notebook = notebook;
    
    GtkWidget *tab3_label = gtk_label_new("Editor");
    gtk_notebook_append_page(GTK_NOTEBOOK(notebook), editor_vbox, tab3_label);

    gtk_box_pack_start(GTK_BOX(main_hbox), notebook, TRUE, TRUE, 0);

    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), main_hbox);

    populate_sidebar_dynamic(ws_container, chats_container, notes_container, files_container);

    gtk_widget_show_all(g_ui_state.main_window);
    g_ui_state.is_visible = 1;
    
    // Notify Lua that GUI is ready
    if (L) {
        lua_getglobal(L, "ui");
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "on_gui_ready");
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    g_printerr("Error calling ui.on_gui_ready: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
    }
}

static int l_bedrock_clear_chat_list(lua_State *L G_GNUC_UNUSED) {
    if (!g_ui_state.chats_list) return 0;
    GList *children = gtk_container_get_children(GTK_CONTAINER(g_ui_state.chats_list));
    for (GList *iter = children; iter != NULL; iter = g_list_next(iter)) {
        gtk_widget_destroy(GTK_WIDGET(iter->data));
    }
    g_list_free(children);
    return 0;
}

static int l_bedrock_add_chat_list_item(lua_State *L) {
    if (!g_ui_state.chats_list) return 0;
    const char *conv_id = luaL_checkstring(L, 1);
    const char *title = luaL_checkstring(L, 2);
    
    GtkWidget *row = gtk_list_box_row_new();
    GtkWidget *label = gtk_label_new(title);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_margin_start(label, 8);
    gtk_widget_set_margin_end(label, 8);
    gtk_widget_set_margin_top(label, 4);
    gtk_widget_set_margin_bottom(label, 4);
    gtk_container_add(GTK_CONTAINER(row), label);
    
    g_object_set_data_full(G_OBJECT(row), "conv_id", g_strdup(conv_id), g_free);
    
    gtk_list_box_insert(GTK_LIST_BOX(g_ui_state.chats_list), row, -1);
    gtk_widget_show_all(row);
    
    return 0;
}

static int l_bedrock_set_editor_content(lua_State *L) {
    const char *filepath = luaL_checkstring(L, 1);
    const char *content = luaL_checkstring(L, 2);
    if (g_ui_state.editor_path_label) {
        gtk_label_set_text(GTK_LABEL(g_ui_state.editor_path_label), filepath);
    }
    if (g_ui_state.editor_textview) {
        GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(g_ui_state.editor_textview));
        gtk_text_buffer_set_text(buf, content, -1);
    }
    if (g_ui_state.notebook) {
        gtk_notebook_set_current_page(GTK_NOTEBOOK(g_ui_state.notebook), 2);
    }
    return 0;
}

static int l_bedrock_set_active_tab(lua_State *L) {
    int page_num = luaL_checkinteger(L, 1);
    if (g_ui_state.notebook) {
        gtk_notebook_set_current_page(GTK_NOTEBOOK(g_ui_state.notebook), page_num);
    }
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

    lua_pushcfunction(L, l_sys_exec_stream);
    lua_setglobal(L, "sys_exec_stream");

    lua_pushcfunction(L, l_sys_exec_sync);
    lua_setglobal(L, "sys_exec_sync");

    lua_pushcfunction(L, l_sys_exec_read);
    lua_setglobal(L, "sys_exec_read");

    lua_pushcfunction(L, l_quit_app);
    lua_setglobal(L, "quit_app");

    lua_pushcfunction(L, l_bedrock_clear_chat_list);
    lua_setglobal(L, "bedrock_clear_chat_list");

    lua_pushcfunction(L, l_bedrock_add_chat_list_item);
    lua_setglobal(L, "bedrock_add_chat_list_item");
    
    lua_pushcfunction(L, l_bedrock_set_editor_content);
    lua_setglobal(L, "bedrock_set_editor_content");

    lua_pushcfunction(L, l_bedrock_set_active_tab);
    lua_setglobal(L, "bedrock_set_active_tab");

    /* Register the Native Chat Bedrock functions */
    chat_bedrock_register_lua(L);

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
