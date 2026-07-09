#ifndef WORKSPACE_EXPLORER_H
#define WORKSPACE_EXPLORER_H

#include <gtk/gtk.h>
#include <json-glib/json-glib.h>

// Initialize the workspaces tab layout and logic
void workspace_explorer_init(GtkWidget *parent_vbox);

// Push local filesystem state to jenova-snapshot.json
void workspace_explorer_push_local(void);

// Pull from jenova-snapshot.json to local filesystem (or reload UI)
void workspace_explorer_pull_origin(void);

#endif // WORKSPACE_EXPLORER_H
