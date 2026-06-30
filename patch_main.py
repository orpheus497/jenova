import re

with open("jenova-ui/src/main.c.bak", "r") as f:
    c = f.read()

# 1. Add GUIState struct after Forward declarations
gui_struct = """/* Forward declarations */
typedef struct {
    GtkWidget *main_window;
    GtkWidget *sidebar_list;
    GtkWidget *chat_view;
    GtkWidget *input_area;
    GtkWidget *btn_send;
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
"""
c = c.replace("/* Forward declarations */", gui_struct)

# 2. Add Chat GUI Functions before init_lua
chat_funcs = """/* ---------------------------------------------------------------------------
 * Chat GUI Functions
 * --------------------------------------------------------------------------- */
static void on_send_clicked(GtkWidget *widget G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
    if (g_ui_state.is_streaming) return;

    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(g_ui_state.input_area));
    GtkTextIter start, end;
    gtk_text_buffer_get_start_iter(buffer, &start);
    gtk_text_buffer_get_end_iter(buffer, &end);
    char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    
    if (text && strlen(text) > 0) {
        lua_getglobal(L, "ui");
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "send_chat");
            if (lua_isfunction(L, -1)) {
                lua_pushstring(L, text);
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    fprintf(stderr, "jenova-ui: error in ui.send_chat: %s\\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
        gtk_text_buffer_set_text(buffer, "", -1);
    }
    g_free(text);
}

static int l_append_chat_message(lua_State *Ls) {
    const char *role = luaL_checkstring(Ls, 1);
    const char *text = luaL_checkstring(Ls, 2);

    if (!g_ui_state.chat_view) return 0;

    GtkWidget *row = gtk_list_box_row_new();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_top(box, 8);
    gtk_widget_set_margin_bottom(box, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);

    GtkWidget *lbl_role = gtk_label_new(role);
    gtk_widget_set_halign(lbl_role, GTK_ALIGN_START);
    GtkStyleContext *ctx = gtk_widget_get_style_context(lbl_role);
    gtk_style_context_add_class(ctx, "chat-role");

    GtkWidget *lbl_text = gtk_label_new(text);
    gtk_label_set_line_wrap(GTK_LABEL(lbl_text), TRUE);
    gtk_label_set_selectable(GTK_LABEL(lbl_text), TRUE);
    gtk_widget_set_halign(lbl_text, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(lbl_text), "chat-text");

    if (strcmp(role, "user") == 0) {
        gtk_style_context_add_class(gtk_widget_get_style_context(box), "chat-bubble-user");
    } else {
        gtk_style_context_add_class(gtk_widget_get_style_context(box), "chat-bubble-assistant");
    }

    gtk_box_pack_start(GTK_BOX(box), lbl_role, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), lbl_text, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(row), box);

    gtk_list_box_insert(GTK_LIST_BOX(g_ui_state.chat_view), row, -1);
    gtk_widget_show_all(row);

    GtkWidget *scrolled = gtk_widget_get_parent(g_ui_state.chat_view);
    if (GTK_IS_VIEWPORT(scrolled)) scrolled = gtk_widget_get_parent(scrolled);
    if (GTK_IS_SCROLLED_WINDOW(scrolled)) {
        GtkAdjustment *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scrolled));
        gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj));
    }
    return 0;
}

static int l_update_last_message(lua_State *Ls) {
    const char *text = luaL_checkstring(Ls, 1);
    if (!g_ui_state.chat_view) return 0;

    GList *children = gtk_container_get_children(GTK_CONTAINER(g_ui_state.chat_view));
    if (!children) return 0;
    GtkWidget *last_row = g_list_last(children)->data;
    
    GtkWidget *box = gtk_bin_get_child(GTK_BIN(last_row));
    if (GTK_IS_BOX(box)) {
        GList *box_children = gtk_container_get_children(GTK_CONTAINER(box));
        if (g_list_length(box_children) >= 2) {
            GtkWidget *lbl_text = g_list_nth_data(box_children, 1);
            if (GTK_IS_LABEL(lbl_text)) {
                gtk_label_set_text(GTK_LABEL(lbl_text), text);
            }
        }
        g_list_free(box_children);
    }
    g_list_free(children);
    
    GtkWidget *scrolled = gtk_widget_get_parent(g_ui_state.chat_view);
    if (GTK_IS_VIEWPORT(scrolled)) scrolled = gtk_widget_get_parent(scrolled);
    if (GTK_IS_SCROLLED_WINDOW(scrolled)) {
        GtkAdjustment *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scrolled));
        gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj));
    }
    return 0;
}

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
            fprintf(stderr, "jenova-ui: error in ui.on_action: %s\\n", lua_tostring(L, -1));
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
        "window.jenova-window { background-color: #131313; }"
        ".glass-panel { background-color: rgba(28, 27, 27, 0.8); border: 1px solid #5e5966; border-radius: 10px; }"
        "label { color: #f0edf2; font-family: sans-serif; }"
        "label.title { font-weight: bold; font-size: 16px; color: #e4b382; }"
        "label.status-active { color: #a3e635; font-weight: bold; }"
        "label.status-inactive { color: #c96464; font-weight: bold; }"
        "label.mode-label { color: #aba0d9; font-weight: bold; }"
        "button { background-color: #2b1e3a; color: #f0edf2; border: 1px solid #5e5966; border-radius: 6px; padding: 8px 16px; font-weight: bold; }"
        "button:hover { background-color: #4b2c70; border-color: #8e7cc3; }"
        "button.stop-btn:hover { background-color: #c96464; border-color: #ffb3b3; }"
        ".chat-bubble-user { background-color: #2b1e3a; border-radius: 8px; margin-top: 5px; }"
        ".chat-bubble-assistant { background-color: #1c1b1b; border: 1px solid #333; border-radius: 8px; margin-top: 5px; }"
        ".chat-role { color: #8e7cc3; font-weight: bold; font-size: 12px; margin-bottom: 4px; }"
        ".chat-text { color: #e0e0e0; font-size: 14px; }"
        "textview.chat-input { background-color: #1c1b1b; color: #f0edf2; border-radius: 8px; padding: 8px; }"
        "list { background-color: transparent; }"
        "row { background-color: transparent; }"
        "row:selected { background-color: transparent; }"
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

    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_container_add(GTK_CONTAINER(g_ui_state.main_window), paned);

    /* LEFT PANE: Sidebar (Controls & Info) */
    GtkWidget *sidebar_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_top(sidebar_vbox, 16);
    gtk_widget_set_margin_bottom(sidebar_vbox, 16);
    gtk_widget_set_margin_start(sidebar_vbox, 16);
    gtk_widget_set_margin_end(sidebar_vbox, 16);
    gtk_widget_set_size_request(sidebar_vbox, 250, -1);
    
    char img_path[PATH_MAX];
    snprintf(img_path, sizeof(img_path), "%s/png/jenova.jpg", get_jenova_root());
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(img_path, NULL);
    GtkWidget *image = gtk_image_new();
    if (pixbuf) {
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixbuf, 200, (int)(gdk_pixbuf_get_height(pixbuf) * (200.0/gdk_pixbuf_get_width(pixbuf))), GDK_INTERP_BILINEAR);
        gtk_image_set_from_pixbuf(GTK_IMAGE(image), scaled);
        g_object_unref(scaled);
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
    g_signal_connect(g_ui_state.btn_start, "clicked", G_CALLBACK(on_gui_button_clicked), "start");
    g_signal_connect(g_ui_state.btn_stop, "clicked", G_CALLBACK(on_gui_button_clicked), "stop");
    g_signal_connect(g_ui_state.btn_lan, "clicked", G_CALLBACK(on_gui_button_clicked), "toggle_lan");
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), g_ui_state.btn_start, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), g_ui_state.btn_stop, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(sidebar_vbox), g_ui_state.btn_lan, FALSE, FALSE, 0);
    
    gtk_paned_pack1(GTK_PANED(paned), sidebar_vbox, FALSE, FALSE);

    /* RIGHT PANE: Chat Area */
    GtkWidget *chat_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    
    /* Scrollable chat messages */
    GtkWidget *scrolled_chat = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled_chat), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scrolled_chat, TRUE);
    gtk_widget_set_margin_start(scrolled_chat, 16);
    gtk_widget_set_margin_end(scrolled_chat, 16);
    gtk_widget_set_margin_top(scrolled_chat, 16);
    
    g_ui_state.chat_view = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(g_ui_state.chat_view), GTK_SELECTION_NONE);
    gtk_container_add(GTK_CONTAINER(scrolled_chat), g_ui_state.chat_view);
    gtk_box_pack_start(GTK_BOX(chat_vbox), scrolled_chat, TRUE, TRUE, 0);

    /* Input Box Area */
    GtkWidget *input_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(input_hbox, 16);
    gtk_widget_set_margin_end(input_hbox, 16);
    gtk_widget_set_margin_top(input_hbox, 16);
    gtk_widget_set_margin_bottom(input_hbox, 16);
    
    GtkWidget *scrolled_input = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled_input), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_size_request(scrolled_input, -1, 60);
    
    g_ui_state.input_area = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(g_ui_state.input_area), GTK_WRAP_WORD_CHAR);
    gtk_style_context_add_class(gtk_widget_get_style_context(g_ui_state.input_area), "chat-input");
    gtk_container_add(GTK_CONTAINER(scrolled_input), g_ui_state.input_area);
    gtk_box_pack_start(GTK_BOX(input_hbox), scrolled_input, TRUE, TRUE, 0);

    g_ui_state.btn_send = gtk_button_new_with_label("Send");
    gtk_widget_set_size_request(g_ui_state.btn_send, 80, -1);
    g_signal_connect(g_ui_state.btn_send, "clicked", G_CALLBACK(on_send_clicked), NULL);
    gtk_box_pack_start(GTK_BOX(input_hbox), g_ui_state.btn_send, FALSE, FALSE, 0);

    gtk_box_pack_start(GTK_BOX(chat_vbox), input_hbox, FALSE, FALSE, 0);
    
    gtk_paned_pack2(GTK_PANED(paned), chat_vbox, TRUE, FALSE);

    gtk_widget_show_all(g_ui_state.main_window);
    g_ui_state.is_visible = 1;
}

/* ---------------------------------------------------------------------------
 * init_lua: Create the Lua state, register C functions, load ui.lua, and"""
c = c.replace("/* ---------------------------------------------------------------------------\n * init_lua: Create the Lua state, register C functions, load ui.lua, and", chat_funcs)

# 3. Add to init_lua
lua_funcs = """    lua_pushcfunction(L, l_quit_app);
    lua_setglobal(L, "quit_app");

    lua_pushcfunction(L, l_append_chat_message);
    lua_setglobal(L, "c_append_chat_message");

    lua_pushcfunction(L, l_update_last_message);
    lua_setglobal(L, "c_update_last_message");"""
c = c.replace('    lua_pushcfunction(L, l_quit_app);\n    lua_setglobal(L, "quit_app");', lua_funcs)

# 4. Modify update_tray_status to update GUI status labels too
tray_status_orig = """        if (status && strcmp(status, "active") == 0) {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca.jpg",
                     get_jenova_root());
        } else {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca_grey.jpg",
                     get_jenova_root());
        }

        app_indicator_set_icon_full(global_indicator, icon_path, "Jenova Status");"""

tray_status_new = """        if (status && strcmp(status, "active") == 0) {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca.jpg",
                     get_jenova_root());
            if (g_ui_state.status_label) {
                gtk_label_set_text(GTK_LABEL(g_ui_state.status_label), "ACTIVE");
                GtkStyleContext *ctx = gtk_widget_get_style_context(g_ui_state.status_label);
                gtk_style_context_remove_class(ctx, "status-inactive");
                gtk_style_context_add_class(ctx, "status-active");
            }
        } else {
            snprintf(icon_path, sizeof(icon_path), "%s/png/jca_grey.jpg",
                     get_jenova_root());
            if (g_ui_state.status_label) {
                gtk_label_set_text(GTK_LABEL(g_ui_state.status_label), "INACTIVE");
                GtkStyleContext *ctx = gtk_widget_get_style_context(g_ui_state.status_label);
                gtk_style_context_remove_class(ctx, "status-active");
                gtk_style_context_add_class(ctx, "status-inactive");
            }
        }

        app_indicator_set_icon_full(global_indicator, icon_path, "Jenova Status");"""
c = c.replace(tray_status_orig, tray_status_new)

# 5. Modify run_tray to call init_gui
run_tray_orig = """    /* Poll server status every 3 seconds */
    g_timeout_add_seconds(3, update_tray_status, NULL);
    update_tray_status(NULL);

    gtk_main();
    return TRUE;"""

run_tray_new = """    /* Initialize Chat GUI Window */
    init_gui();

    /* Poll server status every 3 seconds */
    g_timeout_add_seconds(3, update_tray_status, NULL);
    update_tray_status(NULL);

    gtk_main();
    return TRUE;"""
c = c.replace(run_tray_orig, run_tray_new)

# 6. Add "Open Window" to tray menu
tray_menu_orig = """                    if (label && action) {
                        GtkWidget *item = gtk_menu_item_new_with_label(label);"""

tray_menu_new = """                    if (label && action) {
                        if (strcmp(action, "open_gui") == 0) {
                            GtkWidget *item = gtk_menu_item_new_with_label("Open Window");
                            g_signal_connect_swapped(item, "activate", G_CALLBACK(gtk_widget_show_all), g_ui_state.main_window);
                            gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
                            lua_pop(L, 1);
                            continue;
                        }
                        GtkWidget *item = gtk_menu_item_new_with_label(label);"""
c = c.replace(tray_menu_orig, tray_menu_new)

with open("jenova-ui/src/main.c", "w") as f:
    f.write(c)

print("Patching main.c complete.")
