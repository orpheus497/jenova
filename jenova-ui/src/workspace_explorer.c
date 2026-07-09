#include "workspace_explorer.h"
#include <dirent.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static GtkWidget *flowbox = NULL;
static GtkWidget *status_label = NULL;

static gchar* get_workspaces_root() {
    const char *env_ws = g_getenv("JENOVA_WORKSPACES");
    if (env_ws) {
        return g_strdup(env_ws);
    }
    const char *home = g_getenv("HOME");
    if (!home) home = "/tmp";
    return g_build_filename(home, "JCA", "Workspaces", NULL);
}

static void on_pull_clicked(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    workspace_explorer_pull_origin();
}

static void on_push_clicked(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    workspace_explorer_push_local();
}

static void populate_workspaces() {
    // Clear existing children
    GList *children, *iter;
    children = gtk_container_get_children(GTK_CONTAINER(flowbox));
    for(iter = children; iter != NULL; iter = g_list_next(iter))
        gtk_widget_destroy(GTK_WIDGET(iter->data));
    g_list_free(children);

    gchar *root = get_workspaces_root();
    g_mkdir_with_parents(root, 0755);

    GDir *dir = g_dir_open(root, 0, NULL);
    if (dir) {
        const gchar *name;
        while ((name = g_dir_read_name(dir)) != NULL) {
            if (name[0] == '.') continue;
            
            gchar *full_path = g_build_filename(root, name, NULL);
            if (g_file_test(full_path, G_FILE_TEST_IS_DIR)) {
                // Create card
                GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
                gtk_style_context_add_class(gtk_widget_get_style_context(card), "glass-panel");
                gtk_widget_set_size_request(card, 220, 100);
                
                GtkWidget *hbox_title = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                GtkWidget *icon = gtk_label_new("📁");
                GtkWidget *lbl_name = gtk_label_new(name);
                gtk_style_context_add_class(gtk_widget_get_style_context(lbl_name), "title");
                gtk_label_set_xalign(GTK_LABEL(lbl_name), 0.0);
                
                gtk_box_pack_start(GTK_BOX(hbox_title), icon, FALSE, FALSE, 0);
                gtk_box_pack_start(GTK_BOX(hbox_title), lbl_name, TRUE, TRUE, 0);
                gtk_box_pack_start(GTK_BOX(card), hbox_title, FALSE, FALSE, 0);
                
                // Add ListBox for files
                GtkWidget *list_box = gtk_list_box_new();
                gtk_style_context_add_class(gtk_widget_get_style_context(list_box), "sidebar-scroll");
                gtk_list_box_set_selection_mode(GTK_LIST_BOX(list_box), GTK_SELECTION_NONE);
                
                // Scan inner directory (e.g., Notes, Chats, etc. or directly inside)
                GDir *inner_dir = g_dir_open(full_path, 0, NULL);
                if (inner_dir) {
                    const gchar *file_name;
                    int count = 0;
                    while ((file_name = g_dir_read_name(inner_dir)) != NULL && count < 3) {
                        if (file_name[0] == '.') continue;
                        
                        GtkWidget *item_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                        GtkWidget *file_icon = gtk_label_new(g_str_has_suffix(file_name, ".md") ? "📝" : "📄");
                        GtkWidget *file_lbl = gtk_label_new(file_name);
                        gtk_label_set_xalign(GTK_LABEL(file_lbl), 0.0);
                        gtk_label_set_ellipsize(GTK_LABEL(file_lbl), PANGO_ELLIPSIZE_END);
                        gtk_box_pack_start(GTK_BOX(item_box), file_icon, FALSE, FALSE, 0);
                        gtk_box_pack_start(GTK_BOX(item_box), file_lbl, TRUE, TRUE, 0);
                        
                        gtk_list_box_insert(GTK_LIST_BOX(list_box), item_box, -1);
                        count++;
                    }
                    g_dir_close(inner_dir);
                }
                
                gtk_box_pack_start(GTK_BOX(card), list_box, TRUE, TRUE, 0);
                
                GtkWidget *btn_enter = gtk_button_new_with_label("Enter Workspace →");
                gtk_widget_set_halign(btn_enter, GTK_ALIGN_END);
                gtk_widget_set_valign(btn_enter, GTK_ALIGN_END);
                gtk_widget_set_vexpand(btn_enter, FALSE);
                gtk_box_pack_end(GTK_BOX(card), btn_enter, FALSE, FALSE, 0);
                
                gtk_flow_box_insert(GTK_FLOW_BOX(flowbox), card, -1);
            }
            g_free(full_path);
        }
        g_dir_close(dir);
    }
    g_free(root);
    gtk_widget_show_all(flowbox);
}

void workspace_explorer_init(GtkWidget *parent_vbox) {
    // Header row
    GtkWidget *header_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    
    GtkWidget *title_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *main_title = gtk_label_new("Local File Architecture");
    gtk_style_context_add_class(gtk_widget_get_style_context(main_title), "title");
    gtk_label_set_xalign(GTK_LABEL(main_title), 0.0);
    
    GtkWidget *sub_title = gtk_label_new("Git-like push/pull mechanics for local continuity and state persistence.\nViewing: All Workspaces");
    gtk_label_set_xalign(GTK_LABEL(sub_title), 0.0);
    
    gtk_box_pack_start(GTK_BOX(title_box), main_title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(title_box), sub_title, FALSE, FALSE, 0);
    
    GtkWidget *spacer = gtk_label_new("");
    gtk_widget_set_hexpand(spacer, TRUE);
    
    GtkWidget *btn_pull = gtk_button_new_with_label("☁ Pull Origin");
    GtkWidget *btn_push = gtk_button_new_with_label("☁ Push Local");
    
    g_signal_connect(btn_pull, "clicked", G_CALLBACK(on_pull_clicked), NULL);
    g_signal_connect(btn_push, "clicked", G_CALLBACK(on_push_clicked), NULL);
    
    gtk_box_pack_start(GTK_BOX(header_hbox), title_box, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(header_hbox), spacer, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(header_hbox), btn_pull, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(header_hbox), btn_push, FALSE, FALSE, 0);
    
    gtk_box_pack_start(GTK_BOX(parent_vbox), header_hbox, FALSE, FALSE, 0);
    
    // Status Bar
    GtkWidget *status_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_style_context_add_class(gtk_widget_get_style_context(status_box), "glass-panel");
    gtk_widget_set_margin_top(status_box, 16);
    gtk_widget_set_margin_bottom(status_box, 16);
    
    GtkWidget *status_icon = gtk_label_new("🖴");
    status_label = gtk_label_new("System Idle - Ready for Sync");
    gtk_label_set_xalign(GTK_LABEL(status_label), 0.0);
    
    gtk_box_pack_start(GTK_BOX(status_box), status_icon, FALSE, FALSE, 8);
    gtk_box_pack_start(GTK_BOX(status_box), status_label, TRUE, TRUE, 8);
    
    gtk_box_pack_start(GTK_BOX(parent_vbox), status_box, FALSE, FALSE, 0);
    
    // Assets Header
    GtkWidget *assets_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *assets_lbl = gtk_label_new("Assets in All Workspaces");
    gtk_style_context_add_class(gtk_widget_get_style_context(assets_lbl), "title");
    GtkWidget *btn_upload = gtk_button_new_with_label("+ Upload File");
    
    GtkWidget *spacer2 = gtk_label_new("");
    gtk_widget_set_hexpand(spacer2, TRUE);
    
    gtk_box_pack_start(GTK_BOX(assets_hbox), assets_lbl, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(assets_hbox), spacer2, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(assets_hbox), btn_upload, FALSE, FALSE, 0);
    
    gtk_box_pack_start(GTK_BOX(parent_vbox), assets_hbox, FALSE, FALSE, 16);
    
    // Flowbox for Cards
    GtkWidget *scrolled = gtk_scrolled_window_new(NULL, NULL);
    flowbox = gtk_flow_box_new();
    gtk_widget_set_valign(GTK_WIDGET(flowbox), GTK_ALIGN_START);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flowbox), 5);
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flowbox), GTK_SELECTION_NONE);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flowbox), 16);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flowbox), 16);
    
    gtk_container_add(GTK_CONTAINER(scrolled), flowbox);
    gtk_box_pack_start(GTK_BOX(parent_vbox), scrolled, TRUE, TRUE, 0);
    
    populate_workspaces();
}

static gboolean reset_status(gpointer data) {
    (void)data;
    if (status_label) {
        gtk_label_set_text(GTK_LABEL(status_label), "System Idle - Ready for Sync");
    }
    return G_SOURCE_REMOVE;
}

void workspace_explorer_push_local(void) {
    if (status_label) {
        gtk_label_set_text(GTK_LABEL(status_label), "Pushing local changes to jenova-snapshot.json...");
    }
    // TODO: use json-glib to parse local MD files and rebuild jenova-snapshot.json
    // For now, this is a mock representation of the sync action.
    g_timeout_add(1500, reset_status, NULL); 
}

void workspace_explorer_pull_origin(void) {
    if (status_label) {
        gtk_label_set_text(GTK_LABEL(status_label), "Pulling changes from jenova-snapshot.json...");
    }
    // TODO: use json-glib to parse jenova-snapshot.json and write to local MD files
    // For now, reload workspaces
    populate_workspaces();
    g_timeout_add(1500, reset_status, NULL);
}
