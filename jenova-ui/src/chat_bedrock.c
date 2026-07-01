#include "chat_bedrock.h"
#include <string.h>

static GtkWidget *g_chat_vbox = NULL;
static GtkWidget *g_chat_listbox = NULL;
static GtkWidget *g_chat_input = NULL;
static lua_State *g_lua_state = NULL;
static GHashTable *g_message_labels = NULL;
static GHashTable *g_message_spinners = NULL;
static int g_message_id_counter = 0;

void chat_bedrock_init(GtkWidget *chat_vbox) {
    g_chat_vbox = chat_vbox;
    g_message_labels = g_hash_table_new(g_direct_hash, g_direct_equal);
    g_message_spinners = g_hash_table_new(g_direct_hash, g_direct_equal);
}

void chat_bedrock_load_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    const char *css = 
        ".chat-msg-user { background-color: #2b1e3a; color: #f0edf2; padding: 12px 16px; border-radius: 12px; margin: 4px 8px; }\n"
        ".chat-msg-ai { background-color: transparent; color: #f0edf2; padding: 12px 16px; margin: 4px 8px; }\n"
        ".chat-avatar { font-weight: 800; color: #e4b382; margin-right: 8px; font-size: 11px; }\n"
        ".chat-input-box { border-top: 1px solid rgba(228, 179, 130, 0.2); padding-top: 8px; margin-top: 8px; }\n"
        ".chat-list-box { background: transparent; }\n"
        ".chat-list-row { background: transparent; border: none; }\n"
        ".chat-list-row:hover { background: transparent; }\n";
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
                                              GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static int l_bedrock_create_chat_feed(lua_State *L) {
    if (!g_chat_vbox) return 0;
    
    GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_widget_set_hexpand(scroll, TRUE);
    gtk_style_context_add_class(gtk_widget_get_style_context(scroll), "glass-panel");

    g_chat_listbox = gtk_list_box_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(g_chat_listbox), "chat-list-box");
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(g_chat_listbox), GTK_SELECTION_NONE);
    
    gtk_container_add(GTK_CONTAINER(scroll), g_chat_listbox);
    gtk_box_pack_start(GTK_BOX(g_chat_vbox), scroll, TRUE, TRUE, 0);
    gtk_widget_show_all(scroll);
    
    return 0;
}

/* Callback for when user hits Enter or clicks Send */
static void on_chat_input_activated(GtkWidget *widget G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
    if (!g_chat_input) return;
    const char *text = gtk_entry_get_text(GTK_ENTRY(g_chat_input));
    if (strlen(text) == 0) return;
    
    if (g_lua_state) {
        lua_getglobal(g_lua_state, "ui");
        if (lua_istable(g_lua_state, -1)) {
            lua_getfield(g_lua_state, -1, "on_chat_submit");
            if (lua_isfunction(g_lua_state, -1)) {
                lua_pushstring(g_lua_state, text);
                if (lua_pcall(g_lua_state, 1, 0, 0) != LUA_OK) {
                    g_printerr("Error calling ui.on_chat_submit: %s\n", lua_tostring(g_lua_state, -1));
                    lua_pop(g_lua_state, 1);
                }
            } else {
                lua_pop(g_lua_state, 1);
            }
        }
        lua_pop(g_lua_state, 1);
    }
    
    gtk_entry_set_text(GTK_ENTRY(g_chat_input), "");
}

static int l_bedrock_create_chat_input(lua_State *L) {
    if (!g_chat_vbox) return 0;
    
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_style_context_add_class(gtk_widget_get_style_context(box), "chat-input-box");
    
    g_chat_input = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(g_chat_input), "Type a message to Jenova...");
    gtk_widget_set_hexpand(g_chat_input, TRUE);
    g_signal_connect(g_chat_input, "activate", G_CALLBACK(on_chat_input_activated), NULL);
    
    GtkWidget *btn_send = gtk_button_new_with_label("Send");
    g_signal_connect(btn_send, "clicked", G_CALLBACK(on_chat_input_activated), NULL);
    
    gtk_box_pack_start(GTK_BOX(box), g_chat_input, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(box), btn_send, FALSE, FALSE, 0);
    
    gtk_box_pack_start(GTK_BOX(g_chat_vbox), box, FALSE, FALSE, 0);
    gtk_widget_show_all(box);
    
    return 0;
}

static void scroll_to_bottom() {
    if (!g_chat_listbox) return;
    GtkWidget *parent = gtk_widget_get_parent(g_chat_listbox);
    if (GTK_IS_VIEWPORT(parent)) {
        parent = gtk_widget_get_parent(parent);
    }
    if (GTK_IS_SCROLLED_WINDOW(parent)) {
        GtkAdjustment *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(parent));
        gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj));
    }
}

static int l_bedrock_create_message_bubble(lua_State *L) {
    if (!g_chat_listbox) return 0;
    
    const char *role = luaL_checkstring(L, 1);
    const char *text = luaL_checkstring(L, 2);
    
    GtkWidget *row = gtk_list_box_row_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(row), "chat-list-row");
    
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    
    GtkWidget *avatar = gtk_label_new(g_strcmp0(role, "user") == 0 ? "USER" : "JENOVA");
    gtk_widget_set_valign(avatar, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(avatar), "chat-avatar");
    
    GtkWidget *msg_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(msg_label), text);
    gtk_label_set_line_wrap(GTK_LABEL(msg_label), TRUE);
    gtk_label_set_selectable(GTK_LABEL(msg_label), TRUE);
    gtk_label_set_xalign(GTK_LABEL(msg_label), 0.0);
    
    if (g_strcmp0(role, "user") == 0) {
        gtk_style_context_add_class(gtk_widget_get_style_context(box), "chat-msg-user");
        gtk_widget_set_halign(box, GTK_ALIGN_END);
    } else {
        gtk_style_context_add_class(gtk_widget_get_style_context(box), "chat-msg-ai");
        gtk_widget_set_halign(box, GTK_ALIGN_START);
    }
    
    gtk_box_pack_start(GTK_BOX(box), avatar, FALSE, FALSE, 0);
    
    GtkWidget *spinner = gtk_spinner_new();
    gtk_box_pack_start(GTK_BOX(box), spinner, FALSE, FALSE, 0);
    // Spinner is intentionally not shown yet
    
    gtk_box_pack_start(GTK_BOX(box), msg_label, TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(row), box);
    
    gtk_widget_show_all(row);
    gtk_list_box_insert(GTK_LIST_BOX(g_chat_listbox), row, -1);
    
    int id = ++g_message_id_counter;
    g_hash_table_insert(g_message_labels, GINT_TO_POINTER(id), msg_label);
    g_hash_table_insert(g_message_spinners, GINT_TO_POINTER(id), spinner);
    
    scroll_to_bottom();
    
    lua_pushinteger(L, id);
    return 1;
}

static int l_bedrock_set_message_markup(lua_State *L) {
    int id = luaL_checkinteger(L, 1);
    const char *text = luaL_checkstring(L, 2);
    
    GtkWidget *msg_label = g_hash_table_lookup(g_message_labels, GINT_TO_POINTER(id));
    if (msg_label && GTK_IS_LABEL(msg_label)) {
        gtk_label_set_markup(GTK_LABEL(msg_label), text);
        scroll_to_bottom();
    }
    return 0;
}

static int l_bedrock_set_message_loading(lua_State *L) {
    int id = luaL_checkinteger(L, 1);
    gboolean is_loading = lua_toboolean(L, 2);
    
    GtkWidget *spinner = g_hash_table_lookup(g_message_spinners, GINT_TO_POINTER(id));
    if (spinner && GTK_IS_SPINNER(spinner)) {
        if (is_loading) {
            gtk_widget_show(spinner);
            gtk_spinner_start(GTK_SPINNER(spinner));
        } else {
            gtk_spinner_stop(GTK_SPINNER(spinner));
            gtk_widget_hide(spinner);
        }
    }
    return 0;
}

static int l_bedrock_show_error(lua_State *L) {
    int id = luaL_checkinteger(L, 1);
    const char *err_text = luaL_checkstring(L, 2);
    
    GtkWidget *msg_label = g_hash_table_lookup(g_message_labels, GINT_TO_POINTER(id));
    if (msg_label && GTK_IS_LABEL(msg_label)) {
        char *markup = g_strdup_printf("<span foreground=\"#ff5555\"><b>Error:</b> %s</span>", err_text);
        gtk_label_set_markup(GTK_LABEL(msg_label), markup);
        g_free(markup);
    }
    return 0;
}

void chat_bedrock_register_lua(lua_State *L) {
    g_lua_state = L;
    
    lua_pushcfunction(L, l_bedrock_create_chat_feed);
    lua_setglobal(L, "bedrock_create_chat_feed");
    
    lua_pushcfunction(L, l_bedrock_create_chat_input);
    lua_setglobal(L, "bedrock_create_chat_input");
    
    lua_pushcfunction(L, l_bedrock_create_message_bubble);
    lua_setglobal(L, "bedrock_create_message_bubble");
    
     
     

    lua_pushcfunction(L, l_bedrock_set_message_markup);
    lua_setglobal(L, "bedrock_set_message_markup");

    lua_pushcfunction(L, l_bedrock_set_message_loading);
    lua_setglobal(L, "bedrock_set_message_loading");

    lua_pushcfunction(L, l_bedrock_show_error);
    lua_setglobal(L, "bedrock_show_error");
}
