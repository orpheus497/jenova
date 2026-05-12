/******************************************************************************
 * Jenova UI                                                                  *
 *                                                                            *
 * A unified TUI and tray icon application for managing the Jenova Cognitive  *
 * Architecture. This application can be run in two modes:                    *
 *                                                                            *
 * - Tray mode (default): Creates a system tray icon with a menu for          *
 *   managing the Jenova backend.                                             *
 * - TUI mode ("tui" argument): Launches a terminal-based user interface for  *
 *   managing the Jenova backend.                                             *
 ******************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>
#include <errno.h>
#include <ncurses.h>

// Forward declarations
static void run_tui(void);
void draw_menu_tui(int selected, int width);
void draw_box_tui(const char* title, int width);
char* get_status_tui();
void execute_action(int selected);

// TUI options
const char* options[] = {
    "Start Backend",
    "Stop Backend",
    "Restart Backend",
    "Launch J-Vim",
    "Launch Web UI",
    "Exit"
};
int n_options = sizeof(options) / sizeof(char*);

#include <gtk/gtk.h>
#include <libappindicator/app-indicator.h>


// Forward declarations for Tray
static void run_tray(int argc, char *argv[]);
static void menu_start(GtkMenuItem *item, gpointer user_data);
static void menu_stop(GtkMenuItem *item, gpointer user_data);
static void menu_restart(GtkMenuItem *item, gpointer user_data);
static void menu_web_ui(GtkMenuItem *item, gpointer user_data);
static void menu_tui(GtkMenuItem *item, gpointer user_data);
static void menu_quit(GtkMenuItem *item, gpointer user_data);


/******************************************************************************
 * main                                                                       *
 *                                                                            *
 * The main entry point for the application. Parses command-line arguments    *
 * to determine whether to run the TUI or the tray icon.                      *
 ******************************************************************************/
int main(int argc, char *argv[]) {
    if (argc > 1 && strcmp(argv[1], "tui") == 0) {
        run_tui();
    } else {
        run_tray(argc, argv);
    }
    return 0;
}

/******************************************************************************
 * Tray Icon                                                                  *
 *                                                                            *
 * This section contains the code for the system tray icon. It uses GTK and   *
 * libappindicator to create the icon and its menu.                           *
 ******************************************************************************/

// --- TRAY ---
// Helper function to run shell commands asynchronously
static void run_command_async(const char *command) {
    g_spawn_command_line_async(command, NULL);
}

// Callback functions for the tray menu items
static void menu_start(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data G_GNUC_UNUSED) { run_command_async("jenova-ca start"); }
static void menu_stop(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data G_GNUC_UNUSED) { run_command_async("jenova-ca stop"); }
static void menu_restart(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data G_GNUC_UNUSED) { run_command_async("jenova-ca restart"); }
static void menu_web_ui(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data G_GNUC_UNUSED) { run_command_async("xdg-open http://localhost:8080"); }
static void menu_tui(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data G_GNUC_UNUSED) { run_command_async("jenova-term jenova-ui tui"); }
static void menu_quit(GtkMenuItem *item G_GNUC_UNUSED, gpointer user_data G_GNUC_UNUSED) {
    run_command_async("jenova-ca stop");
    gtk_main_quit();
}

// The main function for the tray icon
static void run_tray(int argc, char *argv[]) {
    // Single instance lock
    int lock_fd = open("/tmp/jenova-ui.lock", O_CREAT | O_RDWR, 0666);
    if (lock_fd == -1) {
        perror("open");
        exit(1);
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) == -1) {
        if (errno == EWOULDBLOCK) {
            fprintf(stderr, "Another instance of jenova-ui is already running.\\n");
            exit(1);
        }
        close(lock_fd);
        exit(1);
    }

    gtk_init(&argc, &argv);

    // Check for offline mode
    int offline_mode = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--offline") == 0) {
            offline_mode = 1;
            break;
        }
    }

    // Create the tray icon
    AppIndicator *indicator = app_indicator_new("jenova-ui-tray", "jca", APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);
    app_indicator_set_icon_full(indicator, "jca", "Jenova");

    // Create the tray menu
    GtkWidget *menu = gtk_menu_new();
    GtkWidget *item;

    item = gtk_menu_item_new_with_label("Open Web UI");
    g_signal_connect(item, "activate", G_CALLBACK(menu_web_ui), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);

    item = gtk_menu_item_new_with_label("System");
    g_signal_connect(item, "activate", G_CALLBACK(menu_tui), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    
    item = gtk_menu_item_new_with_label("Start Server");
    g_signal_connect(item, "activate", G_CALLBACK(menu_start), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    
    item = gtk_menu_item_new_with_label("Stop Server");
    g_signal_connect(item, "activate", G_CALLBACK(menu_stop), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    
    item = gtk_menu_item_new_with_label("Restart Server");
    g_signal_connect(item, "activate", G_CALLBACK(menu_restart), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    
    item = gtk_menu_item_new_with_label("Quit");
    g_signal_connect(item, "activate", G_CALLBACK(menu_quit), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);

    gtk_widget_show_all(menu);
    app_indicator_set_menu(indicator, GTK_MENU(menu));

    // On left-click, open the TUI
    g_signal_connect(indicator, "scroll-event", G_CALLBACK(menu_tui), NULL);

    if (!offline_mode) {
        run_command_async("jenova-ca start");
        run_command_async("xdg-open http://localhost:8080");
    }

    gtk_main();
}


/******************************************************************************
 * TUI                                                                        *
 *                                                                            *
 * This section contains the code for the terminal-based user interface. It   *
 * uses ncurses to create the UI and handle user input.                       *
 ******************************************************************************/
// --- TUI (in C) ---
void run_tui() {
    int selected = 0;
    int key;

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    start_color();

    // Define colors (Kanagawa & Royal Purple)
    init_color(16, 121, 121, 157); // BG
    init_color(17, 863, 843, 729); // FG
    init_color(18, 176, 309, 403); // SEL_BG
    init_color(19, 462, 580, 415); // GREEN
    init_color(20, 764, 250, 262); // RED
    init_color(21, 470, 317, 662); // PURPLE

    // Define color pairs
    init_pair(1, 17, 16); // FG on BG
    init_pair(2, 17, 18); // FG on SEL_BG
    init_pair(3, 19, 16); // GREEN on BG
    init_pair(4, 20, 16); // RED on BG
    init_pair(5, 21, 16); // PURPLE on BG
    
    wbkgd(stdscr, COLOR_PAIR(1));

    while(1) {
        clear();
        int width = 60;
        
        char* status = get_status_tui();
        
        attron(COLOR_PAIR(5));
        draw_box_tui("JENOVA COGNITIVE ARCHITECTURE", width);
        attroff(COLOR_PAIR(5));
        
        mvprintw(4, 2, "Status:");
        
        if (strstr(status, "running") != NULL) {
            attron(COLOR_PAIR(3));
            mvprintw(5, 4, "ACTIVE");
            attroff(COLOR_PAIR(3));
        } else {
            attron(COLOR_PAIR(4));
            mvprintw(5, 4, "INACTIVE");
            attroff(COLOR_PAIR(4));
        }
        free(status);

        draw_menu_tui(selected, width);
        
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
                if (selected == n_options - 1) {
                    endwin();
                    return;
                }
                execute_action(selected);
                // Pause to show action result
                mvprintw(LINES - 1, 0, "Action executed. Press any key to continue...");
                getch();
                break;
        }
    }
}


void execute_action(int selected) {
    switch(selected) {
        case 0: system("jenova-ca start &"); break;
        case 1: system("jenova-ca stop &"); break;
        case 2: system("jenova-ca restart &"); break;
        case 3: system("jenova-term jvim &"); break;
        case 4: system("xdg-open http://localhost:8080 &"); break;
    }
}

void draw_box_tui(const char* title, int width) {
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

void draw_menu_tui(int selected, int width) {
    for (int i = 0; i < n_options; i++) {
        if (i == selected) {
            attron(COLOR_PAIR(2));
            mvprintw(7 + i, 2, "> %s", options[i]);
            attroff(COLOR_PAIR(2));
        } else {
            mvprintw(7 + i, 4, "%s", options[i]);
        }
    }
}

char* get_status_tui() {
    FILE *fp;
    char *buffer = malloc(1024);
    if (!buffer) {
        perror("malloc");
        exit(EXIT_FAILURE);
    }
    
    fp = popen("jenova-ca status", "r");
    if (fp == NULL) {
        strncpy(buffer, "Error: popen failed to get status", 1023);
        buffer[1023] = '\0';
        return buffer;
    }
    
    size_t n = fread(buffer, 1, 1023, fp);
    if (n == 0 && ferror(fp)) {
        strncpy(buffer, "Error: fread failed to get status", 1023);
        buffer[1023] = '\0';
    } else {
        buffer[n] = '\0';
    }
    
    pclose(fp);
    
    return buffer;
}
