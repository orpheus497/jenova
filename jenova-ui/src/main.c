#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>
#include <errno.h>
#include <limits.h>
#include <libgen.h>
#include <ncurses.h>

#include <gtk/gtk.h>
#include <libappindicator/app-indicator.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

static lua_State *L;
static AppIndicator *global_indicator = NULL;
static char jenova_root[PATH_MAX] = {0};

// Forward declarations
static void run_tui(void);
static void run_tray(int argc, char *argv[]);

char* get_jenova_root() {
    if (jenova_root[0] != '\0') return jenova_root;

    char exe_path[PATH_MAX];
    ssize_t count = readlink("/proc/self/exe", exe_path, PATH_MAX);
    if (count != -1) {
        exe_path[count] = '\0';
        char *bin_dir = dirname(exe_path);
        char root_tmp[PATH_MAX];
        snprintf(root_tmp, sizeof(root_tmp), "%s/..", bin_dir);
        if (realpath(root_tmp, jenova_root) == NULL) {
            snprintf(jenova_root, sizeof(jenova_root), ".");
        }
    } else {
        snprintf(jenova_root, sizeof(jenova_root), ".");
    }
    return jenova_root;
}

void setup_environment() {
    const char *root = get_jenova_root();
    const char *home = getenv("HOME");
    if (!home) home = "";
    const char *old_path = getenv("PATH");
    
    char new_path[4096];
    snprintf(new_path, sizeof(new_path), "%s/bin:%s/.local/bin:/usr/local/bin:/usr/bin:/bin:%s", 
             root, home, old_path ? old_path : "");
    setenv("PATH", new_path, 1);
    setenv("JENOVA_ROOT", root, 1);
}

// Lua C API
static int l_sys_exec_async(lua_State *L_state) {
    const char *cmd = luaL_checkstring(L_state, 1);
    GError *error = NULL;
    if (!g_spawn_command_line_async(cmd, &error)) {
        fprintf(stderr, "Error executing async command: %s\n", error->message);
        g_error_free(error);
    }
    return 0;
}

static int l_sys_exec_sync(lua_State *L_state) {
    const char *cmd = luaL_checkstring(L_state, 1);
    int ret = system(cmd);
    lua_pushinteger(L_state, ret);
    return 1;
}

static int l_quit_app(lua_State *L_state) {
    (void)L_state;
    gtk_main_quit();
    return 0;
}

void init_lua() {
    L = luaL_newstate();
    luaL_openlibs(L);

    lua_pushcfunction(L, l_sys_exec_async);
    lua_setglobal(L, "sys_exec_async");

    lua_pushcfunction(L, l_sys_exec_sync);
    lua_setglobal(L, "sys_exec_sync");

    lua_pushcfunction(L, l_quit_app);
    lua_setglobal(L, "quit_app");

    // Add lib/ to package.path
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const char *cur_path = lua_tostring(L, -1);
    char new_path[4096];
    snprintf(new_path, sizeof(new_path), "%s;%s/lib/?.lua", cur_path, get_jenova_root());
    lua_pop(L, 1);
    lua_pushstring(L, new_path);
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);

    char ui_script[PATH_MAX];
    snprintf(ui_script, sizeof(ui_script), "%s/lib/ui.lua", get_jenova_root());

    if (luaL_dofile(L, ui_script) != LUA_OK) {
        fprintf(stderr, "Failed to load ui.lua: %s\n", lua_tostring(L, -1));
        exit(1);
    }

    // Call ui.init(jenova_root)
    lua_getglobal(L, "ui");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "init");
        if (lua_isfunction(L, -1)) {
            lua_pushstring(L, get_jenova_root());
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                fprintf(stderr, "Error calling ui.init: %s\n", lua_tostring(L, -1));
            }
        } else {
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1); // pop 'ui' table
}

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

// --- TRAY ---

static void on_menu_item_activate(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data) {
    const char *action = (const char *)user_data;
    
    lua_getglobal(L, "ui");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "on_action");
    lua_pushstring(L, action);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        fprintf(stderr, "Error in ui.on_action: %s\n", lua_tostring(L, -1));
    }
    lua_pop(L, 1); // pop 'ui' table
}

static gboolean update_tray_status(gpointer user_data G_GNUC_UNUSED) {
    if (!global_indicator) return TRUE;

    lua_getglobal(L, "ui");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return TRUE; }
    lua_getfield(L, -1, "poll_status");
    if (lua_pcall(L, 0, 1, 0) == LUA_OK) {
        const char *status = lua_tostring(L, -1);
        char icon_path[PATH_MAX];
        
        if (strcmp(status, "active") == 0) {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca.jpg", get_jenova_root());
        } else {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca_grey.jpg", get_jenova_root());
        }
        
        app_indicator_set_icon_full(global_indicator, icon_path, "Jenova Status");
    } else {
        fprintf(stderr, "Error in ui.poll_status: %s\n", lua_tostring(L, -1));
    }
    lua_pop(L, 2); // pop result and 'ui' table

    return TRUE;
}

static void run_tray(int argc, char *argv[]) {
    int lock_fd = open("/tmp/jenova-ui.lock", O_CREAT | O_RDWR, 0666);
    if (lock_fd == -1) {
        perror("open");
        exit(1);
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) == -1) {
        if (errno == EWOULDBLOCK) {
            fprintf(stderr, "Another instance of jenova-ui is already running.\n");
            exit(1);
        }
        close(lock_fd);
        exit(1);
    }

    gtk_init(&argc, &argv);

    int offline_mode = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--offline") == 0) {
            offline_mode = 1;
            break;
        }
    }

    char default_icon[PATH_MAX];
    snprintf(default_icon, sizeof(default_icon), "%s/png/jca_grey.jpg", get_jenova_root());

    global_indicator = app_indicator_new("jenova-ui-tray", default_icon, APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
    app_indicator_set_status(global_indicator, APP_INDICATOR_STATUS_ACTIVE);
    app_indicator_set_icon_full(global_indicator, default_icon, "Jenova (Inactive)");

    GtkWidget *menu = gtk_menu_new();

    // Call Lua to get menu items
    lua_getglobal(L, "ui");
    if (!lua_istable(L, -1)) {
        fprintf(stderr, "ui table not found in lua\n");
        exit(1);
    }
    lua_getfield(L, -1, "get_menu");
    if (lua_pcall(L, 0, 1, 0) == LUA_OK) {
        if (lua_istable(L, -1)) {
            size_t len = lua_objlen(L, -1);
            for (size_t i = 1; i <= len; i++) {
                lua_rawgeti(L, -1, i);
                if (lua_istable(L, -1)) {
                    lua_getfield(L, -1, "separator");
                    if (lua_toboolean(L, -1)) {
                        gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
                        lua_pop(L, 2); // pop boolean and table item
                        continue;
                    }
                    lua_pop(L, 1);

                    lua_getfield(L, -1, "label");
                    const char *label = lua_tostring(L, -1);
                    lua_pop(L, 1);

                    lua_getfield(L, -1, "action");
                    const char *action = lua_tostring(L, -1);
                    lua_pop(L, 1);

                    if (label && action) {
                        GtkWidget *item = gtk_menu_item_new_with_label(label);
                        char *action_dup = strdup(action);
                        g_signal_connect(item, "activate", G_CALLBACK(on_menu_item_activate), action_dup);
                        gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
                    }
                }
                lua_pop(L, 1); // pop table item
            }
        }
    } else {
        fprintf(stderr, "Error getting menu: %s\n", lua_tostring(L, -1));
    }
    lua_pop(L, 2); // pop result and 'ui' table

    gtk_widget_show_all(menu);
    app_indicator_set_menu(global_indicator, GTK_MENU(menu));

    g_signal_connect(global_indicator, "scroll-event", G_CALLBACK(on_menu_item_activate), "tui");

    if (!offline_mode) {
        lua_getglobal(L, "ui");
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "on_action");
            lua_pushstring(L, "start");
            lua_pcall(L, 1, 0, 0);
            
            lua_getfield(L, -1, "on_action");
            lua_pushstring(L, "web");
            lua_pcall(L, 1, 0, 0);
        }
        lua_pop(L, 1);
    }

    g_timeout_add_seconds(3, update_tray_status, NULL);
    update_tray_status(NULL);

    gtk_main();
}

// --- TUI ---

static void draw_box_tui(const char* title, int width, int n_options) {
    attron(COLOR_PAIR(1));
    for(int i = 0; i < width; i++) {
        mvprintw(0, i, "─");
        mvprintw(2, i, "─");
        mvprintw(n_options + 6, i, "─");
    }
    for(int i = 0; i < n_options + 7; i++) {
        mvprintw(i, 0, "│");
        mvprintw(i, width - 1, "│");
    }
    mvprintw(0, 0, "┌");
    mvprintw(0, width - 1, "┐");
    mvprintw(2, 0, "├");
    mvprintw(2, width - 1, "┤");
    mvprintw(n_options + 6, 0, "└");
    mvprintw(n_options + 6, width - 1, "┘");
    
    int title_len = strlen(title);
    mvprintw(1, (width - title_len) / 2, title);
    attroff(COLOR_PAIR(1));
}

void run_tui() {
    int selected = 0;
    int key;

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    start_color();

    init_color(16, 121, 121, 157); // BG
    init_color(17, 863, 843, 729); // FG
    init_color(18, 176, 309, 403); // SEL_BG
    init_color(19, 462, 580, 415); // GREEN
    init_color(20, 764, 250, 262); // RED
    init_color(21, 470, 317, 662); // PURPLE

    init_pair(1, 17, 16); 
    init_pair(2, 17, 18); 
    init_pair(3, 19, 16); 
    init_pair(4, 20, 16); 
    init_pair(5, 21, 16); 
    
    wbkgd(stdscr, COLOR_PAIR(1));

    char labels[20][64];
    char actions[20][64];
    int n_options = 0;

    lua_getglobal(L, "ui");
    if (!lua_istable(L, -1)) { endwin(); fprintf(stderr, "ui table missing\n"); exit(1); }
    lua_getfield(L, -1, "get_tui_menu");
    if (lua_pcall(L, 0, 1, 0) == LUA_OK) {
        if (lua_istable(L, -1)) {
            size_t len = lua_objlen(L, -1);
            for (size_t i = 1; i <= len && i <= 20; i++) {
                lua_rawgeti(L, -1, i);
                lua_getfield(L, -1, "label");
                strncpy(labels[n_options], lua_tostring(L, -1), 63);
                labels[n_options][63] = '\0';
                lua_pop(L, 1);

                lua_getfield(L, -1, "action");
                strncpy(actions[n_options], lua_tostring(L, -1), 63);
                actions[n_options][63] = '\0';
                lua_pop(L, 1);
                
                n_options++;
                lua_pop(L, 1);
            }
        }
    }
    lua_pop(L, 2); // pop result and 'ui' table

    while(1) {
        clear();
        int width = 60;
        
        char status[64] = "inactive";
        lua_getglobal(L, "ui");
        lua_getfield(L, -1, "poll_status");
        if (lua_pcall(L, 0, 1, 0) == LUA_OK) {
            strncpy(status, lua_tostring(L, -1), 63);
            status[63] = '\0';
        }
        lua_pop(L, 2);
        
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
        switch(key) {
            case KEY_UP:
                selected--;
                if (selected < 0) selected = n_options - 1;
                break;
            case KEY_DOWN:
                selected++;
                if (selected >= n_options) selected = 0;
                break;
            case 10: // Enter
                if (strcmp(actions[selected], "exit_tui") == 0) {
                    endwin();
                    return;
                }
                
                lua_getglobal(L, "ui");
                lua_getfield(L, -1, "on_tui_action");
                lua_pushstring(L, actions[selected]);
                lua_pcall(L, 1, 0, 0);
                lua_pop(L, 1);
                
                mvprintw(LINES - 1, 0, "Action executed. Press any key to continue...");
                getch();
                break;
        }
    }
}
