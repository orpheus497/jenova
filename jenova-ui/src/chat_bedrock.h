#ifndef JENOVA_CHAT_BEDROCK_H
#define JENOVA_CHAT_BEDROCK_H

#include <gtk/gtk.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

/* Initializes the bedrock with the container for the chat layout */
void chat_bedrock_init(GtkWidget *chat_vbox);

/* Injects chat-specific WebUI styling into GTK */
void chat_bedrock_load_css(void);

/* Registers the C-to-Lua Bridge functions into the global Lua environment */
void chat_bedrock_register_lua(lua_State *L);

#endif // JENOVA_CHAT_BEDROCK_H
