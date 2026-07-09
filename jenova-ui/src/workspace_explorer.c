#include "workspace_explorer.h"
#include <dirent.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <gtk/gtk.h>
#include <glib.h>
#include <json-glib/json-glib.h>
#include <glib/gstdio.h>
static GtkWidget *flowbox = NULL;
static GtkWidget *status_label = NULL;
static guint status_timeout_id = 0;

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

extern void main_open_file(const char *filepath);

static void on_push_clicked(GtkButton *btn, gpointer data) {
    (void)btn; (void)data;
    workspace_explorer_push_local();
}

static void on_file_row_activated(GtkListBox *box, GtkListBoxRow *row, gpointer user_data) {
    (void)box; (void)user_data;
    GtkWidget *event_box = gtk_bin_get_child(GTK_BIN(row));
    if (event_box) {
        GtkWidget *child = gtk_bin_get_child(GTK_BIN(event_box));
        if (child) {
            const gchar *filepath = g_object_get_data(G_OBJECT(child), "filepath");
            if (filepath) {
                main_open_file(filepath);
            }
        }
    }
}

static gchar *current_workspace_view = NULL;

static void populate_workspaces(void);

static void do_rename(const gchar *old_path, const gchar *new_name) {
    if (!old_path || !new_name || strlen(new_name) == 0) return;
    gchar *dir = g_path_get_dirname(old_path);
    gchar *new_path = g_build_filename(dir, new_name, NULL);
    if (rename(old_path, new_path) == 0) {
        workspace_explorer_push_local();
        populate_workspaces();
    } else {
        g_printerr("Failed to rename %s to %s\n", old_path, new_path);
    }
    g_free(dir);
    g_free(new_path);
}

static void on_rename_activated(GtkMenuItem *item, gpointer user_data) {
    const gchar *path = (const gchar *)user_data;
    
    GtkWidget *dialog = gtk_dialog_new_with_buttons("Rename", NULL, GTK_DIALOG_MODAL, "Cancel", GTK_RESPONSE_CANCEL, "Rename", GTK_RESPONSE_ACCEPT, NULL);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    GtkWidget *entry = gtk_entry_new();
    gchar *basename = g_path_get_basename(path);
    gtk_entry_set_text(GTK_ENTRY(entry), basename);
    gtk_box_pack_start(GTK_BOX(content), entry, TRUE, TRUE, 10);
    gtk_widget_show_all(dialog);
    
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        do_rename(path, gtk_entry_get_text(GTK_ENTRY(entry)));
    }
    g_free(basename);
    gtk_widget_destroy(dialog);
}

static void remove_recursive(const gchar *path) {
    if (g_file_test(path, G_FILE_TEST_IS_DIR)) {
        GDir *dir = g_dir_open(path, 0, NULL);
        if (dir) {
            const gchar *name;
            while ((name = g_dir_read_name(dir)) != NULL) {
                gchar *child = g_build_filename(path, name, NULL);
                remove_recursive(child);
                g_free(child);
            }
            g_dir_close(dir);
        }
        g_rmdir(path);
    } else {
        g_remove(path);
    }
}

static void do_delete(const gchar *path) {
    if (!path) return;
    remove_recursive(path);
    workspace_explorer_push_local();
    populate_workspaces();
}

static void on_delete_activated(GtkMenuItem *item, gpointer user_data) {
    const gchar *path = (const gchar *)user_data;
    gchar *basename = g_path_get_basename(path);
    GtkWidget *dialog = gtk_message_dialog_new(NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING, GTK_BUTTONS_YES_NO, "Are you sure you want to delete '%s'?", basename);
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_YES) {
        do_delete(path);
    }
    gtk_widget_destroy(dialog);
    g_free(basename);
}

// Global list for Move dropdown
static GList *get_all_workspace_folders() {
    GList *list = NULL;
    gchar *root = get_workspaces_root();
    GDir *dir = g_dir_open(root, 0, NULL);
    if (dir) {
        const gchar *ws;
        while ((ws = g_dir_read_name(dir)) != NULL) {
            if (ws[0] == '.') continue;
            gchar *ws_path = g_build_filename(root, ws, NULL);
            if (g_file_test(ws_path, G_FILE_TEST_IS_DIR)) {
                GDir *fdir = g_dir_open(ws_path, 0, NULL);
                if (fdir) {
                    const gchar *folder;
                    while ((folder = g_dir_read_name(fdir)) != NULL) {
                        if (folder[0] == '.') continue;
                        if (g_strcmp0(folder, "Chats") == 0 || g_strcmp0(folder, "Notes") == 0 || g_strcmp0(folder, "Files") == 0) continue;
                        gchar *fpath = g_build_filename(ws_path, folder, NULL);
                        if (g_file_test(fpath, G_FILE_TEST_IS_DIR)) {
                            list = g_list_append(list, g_strdup_printf("%s/%s", ws, folder));
                        }
                        g_free(fpath);
                    }
                    g_dir_close(fdir);
                }
            }
            g_free(ws_path);
        }
        g_dir_close(dir);
    }
    g_free(root);
    return list;
}

static void on_move_activated(GtkMenuItem *item, gpointer user_data) {
    const gchar *path = (const gchar *)user_data;
    GtkWidget *dialog = gtk_dialog_new_with_buttons("Move to...", NULL, GTK_DIALOG_MODAL, "Cancel", GTK_RESPONSE_CANCEL, "Move", GTK_RESPONSE_ACCEPT, NULL);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    
    GtkWidget *combo = gtk_combo_box_text_new();
    GList *folders = get_all_workspace_folders();
    for (GList *l = folders; l != NULL; l = l->next) {
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), (const gchar *)l->data);
    }
    gtk_combo_box_set_active(GTK_COMBO_BOX(combo), 0);
    gtk_box_pack_start(GTK_BOX(content), combo, TRUE, TRUE, 10);
    gtk_widget_show_all(dialog);
    
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        gchar *selected = gtk_combo_box_text_get_active_text(GTK_COMBO_BOX_TEXT(combo));
        if (selected) {
            gchar *root = get_workspaces_root();
            // Determine if it's a chat or note based on current path
            const gchar *subdir = "Files";
            if (strstr(path, "/Chats/")) subdir = "Chats";
            else if (strstr(path, "/Notes/")) subdir = "Notes";
            
            gchar *dest_dir = g_build_filename(root, selected, subdir, NULL);
            g_mkdir_with_parents(dest_dir, 0755);
            gchar *basename = g_path_get_basename(path);
            gchar *dest_path = g_build_filename(dest_dir, basename, NULL);
            g_free(basename);
            
            if (rename(path, dest_path) == 0) {
                workspace_explorer_push_local();
                populate_workspaces();
            } else {
                g_printerr("Failed to move %s to %s\n", path, dest_path);
            }
            
            g_free(dest_path);
            g_free(dest_dir);
            g_free(root);
            g_free(selected);
        }
    }
    
    for (GList *l = folders; l != NULL; l = l->next) g_free(l->data);
    g_list_free(folders);
    gtk_widget_destroy(dialog);
}

static gboolean on_file_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    if (event->type == GDK_BUTTON_PRESS && event->button == 3) { // Right click
        const gchar *path = (const gchar *)user_data;
        GtkWidget *menu = gtk_menu_new();
        g_object_ref_sink(menu);
        
        GtkWidget *mi_rename = gtk_menu_item_new_with_label("Rename");
        g_signal_connect(mi_rename, "activate", G_CALLBACK(on_rename_activated), (gpointer)path);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), mi_rename);
        
        GtkWidget *mi_move = gtk_menu_item_new_with_label("Move");
        g_signal_connect(mi_move, "activate", G_CALLBACK(on_move_activated), (gpointer)path);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), mi_move);
        
        GtkWidget *mi_del = gtk_menu_item_new_with_label("Delete");
        g_signal_connect(mi_del, "activate", G_CALLBACK(on_delete_activated), (gpointer)path);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), mi_del);
        
        gtk_widget_show_all(menu);
        g_signal_connect(menu, "selection-done", G_CALLBACK(gtk_widget_destroy), NULL);
        g_signal_connect(menu, "destroy", G_CALLBACK(g_object_unref), NULL);
        gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent*)event);
        return TRUE;
    }
    return FALSE;
}

static void on_enter_workspace_clicked(GtkButton *btn, gpointer user_data) {
    (void)user_data;
    const gchar *path = g_object_get_data(G_OBJECT(btn), "workspace_path");
    if (path) {
        g_free(current_workspace_view);
        current_workspace_view = g_strdup(path);
        populate_workspaces();
    }
}

static void on_back_clicked(GtkButton *btn, gpointer user_data) {
    (void)btn; (void)user_data;
    g_free(current_workspace_view);
    current_workspace_view = NULL;
    populate_workspaces();
}

static void generate_uuid(gchar *uuid_str) {
    guint32 r[4];
    for (int i = 0; i < 4; i++) r[i] = g_random_int();
    sprintf(uuid_str, "%08x-%04x-4%03x-%04x-%04x%08x",
            r[0],
            r[1] >> 16,
            r[1] & 0x0FFF,
            (r[2] >> 16 & 0x3FFF) | 0x8000,
            r[2] & 0xFFFF, r[3]);
}

static void populate_workspaces() {
    if (!flowbox) return;

    // Clear existing children
    GList *children, *iter;
    children = gtk_container_get_children(GTK_CONTAINER(flowbox));
    for(iter = children; iter != NULL; iter = g_list_next(iter))
        gtk_widget_destroy(GTK_WIDGET(iter->data));
    g_list_free(children);

    if (current_workspace_view != NULL) {
        // Back button
        GtkWidget *back_btn = gtk_button_new_with_label("← Back to Overview");
        gtk_widget_set_margin_bottom(back_btn, 12);
        g_signal_connect(back_btn, "clicked", G_CALLBACK(on_back_clicked), NULL);
        gtk_flow_box_insert(GTK_FLOW_BOX(flowbox), back_btn, -1);

        const gchar *subdirs[] = {"Chats", "Notes", "Files", NULL};
        for (int i = 0; subdirs[i] != NULL; i++) {
            GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
            gtk_style_context_add_class(gtk_widget_get_style_context(card), "glass-panel");
            gtk_widget_set_size_request(card, 400, 300);
            
            GtkWidget *lbl = gtk_label_new(subdirs[i]);
            gtk_style_context_add_class(gtk_widget_get_style_context(lbl), "title");
            gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
            gtk_box_pack_start(GTK_BOX(card), lbl, FALSE, FALSE, 0);
            
            GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
            gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
            gtk_widget_set_vexpand(scroll, TRUE);
            
            GtkWidget *list_box = gtk_list_box_new();
            gtk_style_context_add_class(gtk_widget_get_style_context(list_box), "sidebar-scroll");
            g_signal_connect(list_box, "row-activated", G_CALLBACK(on_file_row_activated), NULL);
            gtk_container_add(GTK_CONTAINER(scroll), list_box);
            gtk_box_pack_start(GTK_BOX(card), scroll, TRUE, TRUE, 0);
            
            gchar *subdir_full = g_build_filename(current_workspace_view, subdirs[i], NULL);
            GDir *inner_dir = g_dir_open(subdir_full, 0, NULL);
            if (inner_dir) {
                const gchar *file_name;
                while ((file_name = g_dir_read_name(inner_dir)) != NULL) {
                    if (file_name[0] == '.') continue;
                    
                    gchar *clean_name = g_strdup(file_name);
                    gchar *ext = g_strrstr(clean_name, ".md");
                    if (ext) *ext = '\0';
                    gchar *uuid_sep = g_strrstr(clean_name, "_");
                    if (uuid_sep && strlen(uuid_sep) > 10) *uuid_sep = '\0';
                    
                    GtkWidget *item_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                    GtkWidget *file_icon = gtk_label_new(g_strcmp0(subdirs[i], "Chats") == 0 ? "💬" : "📝");
                    GtkWidget *file_lbl = gtk_label_new(clean_name);
                    gtk_label_set_xalign(GTK_LABEL(file_lbl), 0.0);
                    gtk_label_set_ellipsize(GTK_LABEL(file_lbl), PANGO_ELLIPSIZE_END);
                    gtk_box_pack_start(GTK_BOX(item_box), file_icon, FALSE, FALSE, 0);
                    gtk_box_pack_start(GTK_BOX(item_box), file_lbl, TRUE, TRUE, 0);
                    
                    g_object_set_data_full(G_OBJECT(item_box), "filepath", g_build_filename(subdir_full, file_name, NULL), g_free);
                    
                    GtkWidget *event_box = gtk_event_box_new();
                    gtk_container_add(GTK_CONTAINER(event_box), item_box);
                    g_signal_connect(event_box, "button-press-event", G_CALLBACK(on_file_button_press), (gpointer)g_object_get_data(G_OBJECT(item_box), "filepath"));
                    
                    gtk_list_box_insert(GTK_LIST_BOX(list_box), event_box, -1);
                    g_free(clean_name);
                }
                g_dir_close(inner_dir);
            }
            g_free(subdir_full);
            
            gtk_flow_box_insert(GTK_FLOW_BOX(flowbox), card, -1);
        }
        gtk_widget_show_all(flowbox);
        return;
    }

    gchar *root = get_workspaces_root();
    g_mkdir_with_parents(root, 0755);

    GDir *dir = g_dir_open(root, 0, NULL);
    if (dir) {
        const gchar *name;
        while ((name = g_dir_read_name(dir)) != NULL) {
            if (name[0] == '.') continue;
            
            gchar *full_path = g_build_filename(root, name, NULL);
            if (g_file_test(full_path, G_FILE_TEST_IS_DIR)) {
                // Inside a workspace (e.g., 'default'), we have folders (e.g., 'File Explorer')
                GDir *fdir = g_dir_open(full_path, 0, NULL);
                if (fdir) {
                    const gchar *folder_name;
                    while ((folder_name = g_dir_read_name(fdir)) != NULL) {
                        if (folder_name[0] == '.') continue;
                        if (g_strcmp0(folder_name, "Chats") == 0 || g_strcmp0(folder_name, "Notes") == 0 || g_strcmp0(folder_name, "Files") == 0) {
                            continue; // Skip root-level default folders for now, or handle them separately if needed.
                        }
                        
                        gchar *folder_full = g_build_filename(full_path, folder_name, NULL);
                        if (g_file_test(folder_full, G_FILE_TEST_IS_DIR)) {
                            // Create card for this Folder
                            GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
                            gtk_style_context_add_class(gtk_widget_get_style_context(card), "glass-panel");
                            gtk_widget_set_size_request(card, 220, 100);
                            
                            GtkWidget *hbox_title = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                            GtkWidget *icon = gtk_label_new("📁");
                            GtkWidget *lbl_name = gtk_label_new(folder_name);
                            gtk_style_context_add_class(gtk_widget_get_style_context(lbl_name), "title");
                            gtk_label_set_xalign(GTK_LABEL(lbl_name), 0.0);
                            
                            gtk_box_pack_start(GTK_BOX(hbox_title), icon, FALSE, FALSE, 0);
                            gtk_box_pack_start(GTK_BOX(hbox_title), lbl_name, TRUE, TRUE, 0);
                            gtk_box_pack_start(GTK_BOX(card), hbox_title, FALSE, FALSE, 0);
                            
                            // Add ListBox for files
                            GtkWidget *list_box = gtk_list_box_new();
                            gtk_style_context_add_class(gtk_widget_get_style_context(list_box), "sidebar-scroll");
                            g_signal_connect(list_box, "row-activated", G_CALLBACK(on_file_row_activated), NULL);
                            
                            int count = 0;
                            // Helper array of subdirectories to check
                            const gchar *subdirs[] = {"Chats", "Notes", NULL};
                            for (int i = 0; subdirs[i] != NULL && count < 3; i++) {
                                gchar *subdir_full = g_build_filename(folder_full, subdirs[i], NULL);
                                GDir *inner_dir = g_dir_open(subdir_full, 0, NULL);
                                if (inner_dir) {
                                    const gchar *file_name;
                                    while ((file_name = g_dir_read_name(inner_dir)) != NULL && count < 3) {
                                        if (file_name[0] == '.') continue;
                                        if (!g_str_has_suffix(file_name, ".md")) continue;
                                        
                                        // Remove .md extension and UUID if present (basic cleanup for UI)
                                        gchar *clean_name = g_strdup(file_name);
                                        gchar *ext = g_strrstr(clean_name, ".md");
                                        if (ext) *ext = '\0';
                                        gchar *uuid_sep = g_strrstr(clean_name, "_");
                                        if (uuid_sep && strlen(uuid_sep) > 10) *uuid_sep = '\0'; // naive heuristic to strip appended ID
                                        
                                        GtkWidget *item_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
                                        GtkWidget *file_icon = gtk_label_new(g_strcmp0(subdirs[i], "Chats") == 0 ? "💬" : "📝");
                                        GtkWidget *file_lbl = gtk_label_new(clean_name);
                                        gtk_label_set_xalign(GTK_LABEL(file_lbl), 0.0);
                                        gtk_label_set_ellipsize(GTK_LABEL(file_lbl), PANGO_ELLIPSIZE_END);
                                        gtk_box_pack_start(GTK_BOX(item_box), file_icon, FALSE, FALSE, 0);
                                        gtk_box_pack_start(GTK_BOX(item_box), file_lbl, TRUE, TRUE, 0);
                                        
                                        g_object_set_data_full(G_OBJECT(item_box), "filepath", g_build_filename(subdir_full, file_name, NULL), g_free);
                                        
                                        GtkWidget *event_box = gtk_event_box_new();
                                        gtk_container_add(GTK_CONTAINER(event_box), item_box);
                                        g_signal_connect(event_box, "button-press-event", G_CALLBACK(on_file_button_press), (gpointer)g_object_get_data(G_OBJECT(item_box), "filepath"));
                                        
                                        gtk_list_box_insert(GTK_LIST_BOX(list_box), event_box, -1);
                                        g_free(clean_name);
                                        count++;
                                    }
                                    g_dir_close(inner_dir);
                                }
                                g_free(subdir_full);
                            }
                            
                            gtk_box_pack_start(GTK_BOX(card), list_box, TRUE, TRUE, 0);
                            
                            GtkWidget *btn_enter = gtk_button_new_with_label("Enter Workspace →");
                            gtk_widget_set_halign(btn_enter, GTK_ALIGN_END);
                            gtk_widget_set_valign(btn_enter, GTK_ALIGN_END);
                            gtk_widget_set_vexpand(btn_enter, FALSE);
                            // We can use g_object_set_data to store the folder path if we decide to implement "Enter Workspace" later.
                            g_object_set_data_full(G_OBJECT(btn_enter), "workspace_path", g_strdup(folder_full), g_free);
                            g_signal_connect(btn_enter, "clicked", G_CALLBACK(on_enter_workspace_clicked), NULL);
                            gtk_box_pack_end(GTK_BOX(card), btn_enter, FALSE, FALSE, 0);
                            
                            gtk_flow_box_insert(GTK_FLOW_BOX(flowbox), card, -1);
                        }
                        g_free(folder_full);
                    }
                    g_dir_close(fdir);
                }
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
    g_object_add_weak_pointer(G_OBJECT(status_label), (gpointer *)&status_label);
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
    g_object_add_weak_pointer(G_OBJECT(flowbox), (gpointer *)&flowbox);
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
    status_timeout_id = 0;
    return G_SOURCE_REMOVE;
}

void workspace_explorer_push_local(void) {
    if (status_label) {
        gtk_label_set_text(GTK_LABEL(status_label), "Pushing local changes to jenova-snapshot.json...");
    }
    if (status_timeout_id > 0) {
        g_source_remove(status_timeout_id);
    }
    
    gchar *root_path = get_workspaces_root();
    gchar *json_path = g_build_filename(root_path, "jenova-snapshot.json", NULL);
    
    JsonParser *parser = json_parser_new();
    GError *error = NULL;
    JsonObject *root_obj = NULL;
    
    if (json_parser_load_from_file(parser, json_path, &error)) {
        JsonNode *root_node = json_parser_get_root(parser);
        if (root_node && JSON_NODE_HOLDS_OBJECT(root_node)) {
            root_obj = json_node_get_object(root_node);
            json_object_ref(root_obj); // Keep it alive
        }
    } else {
        g_clear_error(&error);
    }
    g_object_unref(parser);
    
    if (!root_obj) {
        root_obj = json_object_new();
        json_object_set_array_member(root_obj, "workspaces", json_array_new());
        json_object_set_array_member(root_obj, "projects", json_array_new());
        json_object_set_array_member(root_obj, "folders", json_array_new());
        json_object_set_array_member(root_obj, "conversations", json_array_new());
        json_object_set_array_member(root_obj, "messages", json_array_new());
        json_object_set_array_member(root_obj, "notes", json_array_new());
        json_object_set_array_member(root_obj, "fileAssets", json_array_new());
    }
    
    JsonArray *ws_array = json_object_get_array_member(root_obj, "workspaces");
    JsonArray *folders_array = json_object_get_array_member(root_obj, "folders");
    if (!ws_array) { ws_array = json_array_new(); json_object_set_array_member(root_obj, "workspaces", ws_array); }
    if (!folders_array) { folders_array = json_array_new(); json_object_set_array_member(root_obj, "folders", folders_array); }
    
    GDir *dir = g_dir_open(root_path, 0, NULL);
    if (dir) {
        const gchar *ws_name;
        while ((ws_name = g_dir_read_name(dir)) != NULL) {
            if (ws_name[0] == '.') continue;
            gchar *ws_full = g_build_filename(root_path, ws_name, NULL);
            if (g_file_test(ws_full, G_FILE_TEST_IS_DIR)) {
                // Check if workspace exists
                gboolean found = FALSE;
                for (guint i = 0; i < json_array_get_length(ws_array); i++) {
                    JsonObject *wo = json_array_get_object_element(ws_array, i);
                    if (g_strcmp0(json_object_get_string_member(wo, "name"), ws_name) == 0) {
                        found = TRUE; break;
                    }
                }
                if (!found) {
                    JsonObject *new_ws = json_object_new();
                    gchar uuid[37]; generate_uuid(uuid);
                    json_object_set_string_member(new_ws, "id", uuid);
                    json_object_set_string_member(new_ws, "name", ws_name);
                    json_array_add_object_element(ws_array, new_ws);
                }
                
                // Scan for folders
                GDir *fdir = g_dir_open(ws_full, 0, NULL);
                if (fdir) {
                    const gchar *f_name;
                    while ((f_name = g_dir_read_name(fdir)) != NULL) {
                        if (f_name[0] == '.') continue;
                        if (g_strcmp0(f_name, "Chats") == 0 || g_strcmp0(f_name, "Notes") == 0 || g_strcmp0(f_name, "Files") == 0) continue;
                        
                        gchar *f_full = g_build_filename(ws_full, f_name, NULL);
                        if (g_file_test(f_full, G_FILE_TEST_IS_DIR)) {
                            gboolean f_found = FALSE;
                            for (guint j = 0; j < json_array_get_length(folders_array); j++) {
                                JsonObject *fo = json_array_get_object_element(folders_array, j);
                                if (g_strcmp0(json_object_get_string_member(fo, "name"), f_name) == 0) {
                                    f_found = TRUE; break;
                                }
                            }
                            if (!f_found) {
                                JsonObject *new_f = json_object_new();
                                gchar uuid[37]; generate_uuid(uuid);
                                json_object_set_string_member(new_f, "id", uuid);
                                
                                const gchar *ws_id = NULL;
                                for (guint k = 0; k < json_array_get_length(ws_array); k++) {
                                    JsonObject *w = json_array_get_object_element(ws_array, k);
                                    if (g_strcmp0(json_object_get_string_member(w, "name"), ws_name) == 0) {
                                        ws_id = json_object_get_string_member(w, "id");
                                        break;
                                    }
                                }
                                if (ws_id) {
                                    json_object_set_string_member(new_f, "workspaceId", ws_id);
                                    json_object_set_string_member(new_f, "projectId", ws_id);
                                } else {
                                    json_object_set_null_member(new_f, "projectId");
                                }
                                json_object_set_string_member(new_f, "name", f_name);
                                json_array_add_object_element(folders_array, new_f);
                            }
                        }
                        g_free(f_full);
                    }
                    g_dir_close(fdir);
                }
            }
            g_free(ws_full);
        }
        g_dir_close(dir);
    }
    
    // Save JSON
    JsonNode *out_node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(out_node, root_obj);
    JsonGenerator *gen = json_generator_new();
    json_generator_set_root(gen, out_node);
    json_generator_to_file(gen, json_path, &error);
    if (error) g_clear_error(&error);
    
    g_object_unref(gen);
    json_node_free(out_node);
    // Note: root_obj is freed when out_node is freed
    g_free(json_path);
    g_free(root_path);
    
    status_timeout_id = g_timeout_add(1500, reset_status, NULL); 
}

void workspace_explorer_pull_origin(void) {
    if (status_label) {
        gtk_label_set_text(GTK_LABEL(status_label), "Pulling changes from jenova-snapshot.json...");
    }
    
    gchar *root_path = get_workspaces_root();
    gchar *json_path = g_build_filename(root_path, "jenova-snapshot.json", NULL);
    
    JsonParser *parser = json_parser_new();
    GError *error = NULL;
    if (json_parser_load_from_file(parser, json_path, &error)) {
        JsonNode *root_node = json_parser_get_root(parser);
        if (root_node && JSON_NODE_HOLDS_OBJECT(root_node)) {
            JsonObject *root_obj = json_node_get_object(root_node);
            JsonArray *ws_array = json_object_get_array_member(root_obj, "workspaces");
            JsonArray *folders_array = json_object_get_array_member(root_obj, "folders");
            
            // Note: Since WebUI handles exact routing, we just ensure directories exist for known folders.
            // SvelteKit WebUI might store folders by UUID as directory names depending on sync setup, 
            // but we'll try to sync their "name" field if they don't exist.
            if (ws_array && folders_array) {
                for (guint i = 0; i < json_array_get_length(ws_array); i++) {
                    JsonObject *wo = json_array_get_object_element(ws_array, i);
                    const gchar *wname = json_object_get_string_member(wo, "name");
                    const gchar *wid = NULL;
                    if (json_object_has_member(wo, "id")) {
                        wid = json_object_get_string_member(wo, "id");
                    }
                    if (wname) {
                        gchar *wpath = g_build_filename(root_path, wname, NULL);
                        g_mkdir_with_parents(wpath, 0755);
                        
                        for (guint j = 0; j < json_array_get_length(folders_array); j++) {
                            JsonObject *fo = json_array_get_object_element(folders_array, j);
                            const gchar *f_ws_id = NULL;
                            if (json_object_has_member(fo, "workspaceId") && JSON_NODE_HOLDS_VALUE(json_object_get_member(fo, "workspaceId"))) {
                                f_ws_id = json_object_get_string_member(fo, "workspaceId");
                            } else if (json_object_has_member(fo, "projectId") && JSON_NODE_HOLDS_VALUE(json_object_get_member(fo, "projectId"))) {
                                f_ws_id = json_object_get_string_member(fo, "projectId");
                            }
                            
                            if (f_ws_id && wid && g_strcmp0(f_ws_id, wid) == 0) {
                                const gchar *fname = json_object_get_string_member(fo, "name");
                                if (fname) {
                                    gchar *fpath = g_build_filename(wpath, fname, NULL);
                                    g_mkdir_with_parents(fpath, 0755);
                                    g_free(fpath);
                                }
                            }
                        }
                        g_free(wpath);
                    }
                }
            }
        }
    } else {
        g_clear_error(&error);
    }
    g_object_unref(parser);
    g_free(json_path);
    g_free(root_path);

    populate_workspaces();
    if (status_timeout_id > 0) {
        g_source_remove(status_timeout_id);
    }
    status_timeout_id = g_timeout_add(1500, reset_status, NULL);
}
