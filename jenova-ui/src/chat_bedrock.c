#include "chat_bedrock.h"
#include <string.h>
#include <stdlib.h>
#include <webkit2/webkit2.h>

static GtkWidget *g_chat_vbox = NULL;
static GtkWidget *g_webview = NULL;
static GtkWidget *g_chat_input = NULL;
static lua_State *g_lua_state = NULL;
static int g_message_id_counter = 0;

static const char *HTML_TEMPLATE = 
"<!DOCTYPE html>"
"<html><head><meta charset='utf-8'>"
"<script src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'></script>"
"<link rel='stylesheet' href='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.7.0/styles/atom-one-dark.min.css'>"
"<script src='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.7.0/highlight.min.js'></script>"
"<style>"
"body { background: transparent; color: #f0edf2; font-family: 'DejaVuSansM Nerd Font', 'DejaVu Sans Mono', monospace; font-size: 12pt; padding: 16px; margin: 0; }"
".bubble-container { display: flex; flex-direction: column; margin-bottom: 24px; }"
".bubble-user { align-items: flex-end; }"
".bubble-ai { align-items: flex-start; }"
".avatar { font-weight: 800; color: #e4b382; margin-bottom: 8px; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; }"
".bubble { max-width: 85%; padding: 16px; }"
".bubble-user .bubble { background-color: #2b1e3a; border-radius: 12px 12px 0 12px; }"
".bubble-ai .bubble { background-color: rgba(43, 30, 58, 0.4); border: 1px solid rgba(228, 179, 130, 0.2); border-radius: 12px 12px 12px 0; }"
"pre { background: #1e1e1e; padding: 12px; border-radius: 8px; overflow-x: auto; border: 1px solid #333; }"
"code { font-family: 'DejaVuSansM Nerd Font', 'DejaVu Sans Mono', monospace; }"
"p { margin: 0 0 12px 0; line-height: 1.6; }"
"p:last-child { margin-bottom: 0; }"
".thinking { color: #888; font-style: italic; font-size: 0.9em; }"
"</style>"
"<script>"
"marked.setOptions({"
"  highlight: function(code, lang) {"
"    const language = hljs.getLanguage(lang) ? lang : 'plaintext';"
"    return hljs.highlight(code, { language }).value;"
"  }"
"});"
"function escapeHtml(text) {"
"  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');"
"}"
"function createBubble(id, role, text) {"
"  const container = document.createElement('div');"
"  container.id = 'msg-' + id;"
"  container.className = 'bubble-container ' + (role === 'user' ? 'bubble-user' : 'bubble-ai');"
"  const avatar = document.createElement('div');"
"  avatar.className = 'avatar';"
"  avatar.innerText = role === 'user' ? 'USER' : 'JENOVA';"
"  const bubble = document.createElement('div');"
"  bubble.className = 'bubble';"
"  bubble.innerHTML = role === 'user' ? escapeHtml(text).replace(/\\n/g, '<br>') : marked.parse(text);"
"  container.appendChild(avatar);"
"  container.appendChild(bubble);"
"  document.body.appendChild(container);"
"  window.scrollTo(0, document.body.scrollHeight);"
"}"
"function updateBubble(id, text) {"
"  const container = document.getElementById('msg-' + id);"
"  if(container) {"
"    const bubble = container.querySelector('.bubble');"
"    bubble.innerHTML = marked.parse(text);"
"    window.scrollTo(0, document.body.scrollHeight);"
"  }"
"}"
"function clearFeed() {"
"  document.body.innerHTML = '';"
"}"
"</script>"
"</head><body></body></html>";

void chat_bedrock_init(GtkWidget *chat_vbox) {
    g_chat_vbox = chat_vbox;
}

void chat_bedrock_load_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    const char *css = 
        ".chat-input-box { border-top: 1px solid rgba(228, 179, 130, 0.2); padding-top: 8px; margin-top: 8px; }\n";
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
                                              GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static void escape_js_string(const char *src, char *dst) {
    while (*src) {
        if (*src == '\\' || *src == '"' || *src == '\'') {
            *dst++ = '\\';
        } else if (*src == '\n') {
            *dst++ = '\\'; *dst++ = 'n';
            src++; continue;
        } else if (*src == '\r') {
            *dst++ = '\\'; *dst++ = 'r';
            src++; continue;
        }
        *dst++ = *src++;
    }
    *dst = '\0';
}

static int l_bedrock_create_chat_feed(lua_State *L) {
    (void)L;
    if (!g_chat_vbox) return 0;
    
    g_webview = webkit_web_view_new();
    WebKitSettings *settings = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(g_webview));
    webkit_settings_set_enable_javascript(settings, TRUE);
    
    webkit_web_view_load_html(WEBKIT_WEB_VIEW(g_webview), HTML_TEMPLATE, NULL);
    
    GdkRGBA transparent = {0, 0, 0, 0};
    webkit_web_view_set_background_color(WEBKIT_WEB_VIEW(g_webview), &transparent);
    
    gtk_widget_set_vexpand(g_webview, TRUE);
    gtk_widget_set_hexpand(g_webview, TRUE);
    
    gtk_box_pack_start(GTK_BOX(g_chat_vbox), g_webview, TRUE, TRUE, 0);
    gtk_widget_show_all(g_webview);
    
    return 0;
}

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
    (void)L;
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

static int l_bedrock_create_message_bubble(lua_State *L) {
    if (!g_webview) return 0;
    
    const char *role = luaL_checkstring(L, 1);
    const char *text = luaL_checkstring(L, 2);
    
    int id = ++g_message_id_counter;
    
    char *escaped_text = malloc(strlen(text) * 2 + 1);
    escape_js_string(text, escaped_text);
    
    size_t script_len = strlen(escaped_text) + 256;
    char *script = malloc(script_len);
    snprintf(script, script_len, "createBubble('%d', '%s', '%s');", id, role, escaped_text);
    webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(g_webview), script, NULL, NULL, NULL);
    
    free(script);
    free(escaped_text);
    
    lua_pushinteger(L, id);
    return 1;
}

static int l_bedrock_set_message_markup(lua_State *L) {
    if (!g_webview) return 0;
    
    int id = luaL_checkinteger(L, 1);
    const char *text = luaL_checkstring(L, 2);
    
    char *escaped_text = malloc(strlen(text) * 2 + 1);
    escape_js_string(text, escaped_text);
    
    size_t script_len = strlen(escaped_text) + 256;
    char *script = malloc(script_len);
    snprintf(script, script_len, "updateBubble('%d', '%s');", id, escaped_text);
    webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(g_webview), script, NULL, NULL, NULL);
    
    free(script);
    free(escaped_text);
    return 0;
}

static int l_bedrock_set_message_loading(lua_State *L) {
    (void)L;
    return 0; // Handled by CSS/JS if needed later
}

static int l_bedrock_show_error(lua_State *L) {
    if (!g_webview) return 0;
    
    int id = luaL_checkinteger(L, 1);
    const char *text = luaL_checkstring(L, 2);
    
    char *escaped_text = malloc(strlen(text) * 2 + 1);
    escape_js_string(text, escaped_text);
    
    size_t script_len = strlen(escaped_text) + 256;
    char *script = malloc(script_len);
    snprintf(script, script_len, "updateBubble('%d', '<span style=\"color:#ff5555\"><b>Error:</b> %s</span>');", id, escaped_text);
    webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(g_webview), script, NULL, NULL, NULL);
    
    free(script);
    free(escaped_text);
    return 0;
}

static int l_bedrock_clear_chat_feed(lua_State *L) {
    if (!g_webview) return 0;
    webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(g_webview), "clearFeed();", NULL, NULL, NULL);
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

    lua_pushcfunction(L, l_bedrock_clear_chat_feed);
    lua_setglobal(L, "bedrock_clear_chat_feed");
}
