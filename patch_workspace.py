import re

with open("jenova-ui/src/workspace_explorer.c", "r") as f:
    code = f.read()

# 1. Update get_all_workspace_folders
new_get_all_workspace_folders = """static GList *get_all_workspace_folders() {
    GList *list = NULL;
    list = g_list_append(list, g_strdup("Global"));
    gchar *root = get_workspaces_root();
    gchar *spaces_dir = g_build_filename(root, "Spaces", NULL);
    GDir *dir = g_dir_open(spaces_dir, 0, NULL);
    if (dir) {
        const gchar *ws;
        while ((ws = g_dir_read_name(dir)) != NULL) {
            if (ws[0] == '.') continue;
            gchar *ws_path = g_build_filename(spaces_dir, ws, NULL);
            if (g_file_test(ws_path, G_FILE_TEST_IS_DIR)) {
                list = g_list_append(list, g_strdup_printf("Spaces/%s", ws));
                GDir *fdir = g_dir_open(ws_path, 0, NULL);
                if (fdir) {
                    const gchar *folder;
                    while ((folder = g_dir_read_name(fdir)) != NULL) {
                        if (folder[0] == '.') continue;
                        if (g_strcmp0(folder, "Chats") == 0 || g_strcmp0(folder, "Notes") == 0 || g_strcmp0(folder, "Files") == 0) continue;
                        gchar *fpath = g_build_filename(ws_path, folder, NULL);
                        if (g_file_test(fpath, G_FILE_TEST_IS_DIR)) {
                            list = g_list_append(list, g_strdup_printf("Spaces/%s/%s", ws, folder));
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
    g_free(spaces_dir);
    g_free(root);
    return list;
}"""
code = re.sub(r'static GList \*get_all_workspace_folders\(\) \{.*?\n\}', new_get_all_workspace_folders, code, flags=re.DOTALL)

# 2. Update on_move_activated
old_move = """            gchar *dest_dir = g_build_filename(root, selected, subdir, NULL);"""
new_move = """            gchar *dest_dir = NULL;
            if (g_strcmp0(selected, "Global") == 0) {
                dest_dir = g_build_filename(root, subdir, NULL);
            } else {
                dest_dir = g_build_filename(root, selected, subdir, NULL);
            }"""
code = code.replace(old_move, new_move)

# 3. Update workspace_explorer_push_local
old_push_scan = """    GDir *dir = g_dir_open(root_path, 0, NULL);
    if (dir) {
        const gchar *ws_name;
        while ((ws_name = g_dir_read_name(dir)) != NULL) {
            if (ws_name[0] == '.') continue;
            gchar *ws_full = g_build_filename(root_path, ws_name, NULL);"""
new_push_scan = """    gchar *spaces_dir = g_build_filename(root_path, "Spaces", NULL);
    GDir *dir = g_dir_open(spaces_dir, 0, NULL);
    if (dir) {
        const gchar *ws_name;
        while ((ws_name = g_dir_read_name(dir)) != NULL) {
            if (ws_name[0] == '.') continue;
            gchar *ws_full = g_build_filename(spaces_dir, ws_name, NULL);"""
code = code.replace(old_push_scan, new_push_scan)

old_push_end = """        g_dir_close(dir);
    }
    
    // Save JSON"""
new_push_end = """        g_dir_close(dir);
    }
    g_free(spaces_dir);
    
    // Save JSON"""
code = code.replace(old_push_end, new_push_end)

# 4. Update workspace_explorer_pull_origin
old_pull_scan = """                        gchar *wpath = g_build_filename(root_path, wname, NULL);"""
new_pull_scan = """                        gchar *wpath = NULL;
                        if (g_strcmp0(wname, "default") == 0 || g_strcmp0(wname, "global") == 0) {
                            wpath = g_strdup(root_path);
                        } else {
                            wpath = g_build_filename(root_path, "Spaces", wname, NULL);
                        }"""
code = code.replace(old_pull_scan, new_pull_scan)

# 5. Rewrite populate_workspaces inside current_workspace_view == NULL
# Since it's large, we use a regex from gchar *root = get_workspaces_root(); to the end of the function.
new_pop = """    gchar *root = get_workspaces_root();
    g_mkdir_with_parents(root, 0755);

    // Global Assets Card
    GtkWidget *global_card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_style_context_add_class(gtk_widget_get_style_context(global_card), "glass-panel");
    gtk_widget_set_size_request(global_card, 220, 100);
    
    GtkWidget *hbox_title_g = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *icon_g = gtk_label_new("🌍");
    GtkWidget *lbl_name_g = gtk_label_new("Global Assets");
    gtk_style_context_add_class(gtk_widget_get_style_context(lbl_name_g), "title");
    gtk_label_set_xalign(GTK_LABEL(lbl_name_g), 0.0);
    gtk_box_pack_start(GTK_BOX(hbox_title_g), icon_g, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(hbox_title_g), lbl_name_g, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(global_card), hbox_title_g, FALSE, FALSE, 0);
    
    GtkWidget *list_box_g = gtk_list_box_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(list_box_g), "sidebar-scroll");
    g_signal_connect(list_box_g, "row-activated", G_CALLBACK(on_file_row_activated), NULL);
    
    int count_g = 0;
    const gchar *subdirs[] = {"Chats", "Notes", NULL};
    for (int i = 0; subdirs[i] != NULL && count_g < 3; i++) {
        gchar *subdir_full = g_build_filename(root, subdirs[i], NULL);
        GDir *inner_dir = g_dir_open(subdir_full, 0, NULL);
        if (inner_dir) {
            const gchar *file_name;
            while ((file_name = g_dir_read_name(inner_dir)) != NULL && count_g < 3) {
                if (file_name[0] == '.') continue;
                if (!g_str_has_suffix(file_name, ".md")) continue;
                
                gchar *clean_name = g_strdup(file_name);
                gchar *ext = g_strrstr(clean_name, ".md");
                if (ext) *ext = '\\0';
                gchar *uuid_sep = g_strrstr(clean_name, "_");
                if (uuid_sep && strlen(uuid_sep) > 10) *uuid_sep = '\\0';
                
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
                gtk_list_box_insert(GTK_LIST_BOX(list_box_g), event_box, -1);
                g_free(clean_name);
                count_g++;
            }
            g_dir_close(inner_dir);
        }
        g_free(subdir_full);
    }
    gtk_box_pack_start(GTK_BOX(global_card), list_box_g, TRUE, TRUE, 0);
    
    GtkWidget *btn_enter_g = gtk_button_new_with_label("Enter Workspace →");
    gtk_widget_set_halign(btn_enter_g, GTK_ALIGN_END);
    gtk_widget_set_valign(btn_enter_g, GTK_ALIGN_END);
    gtk_widget_set_vexpand(btn_enter_g, FALSE);
    g_object_set_data_full(G_OBJECT(btn_enter_g), "workspace_path", g_strdup(root), g_free);
    g_signal_connect(btn_enter_g, "clicked", G_CALLBACK(on_enter_workspace_clicked), NULL);
    gtk_box_pack_end(GTK_BOX(global_card), btn_enter_g, FALSE, FALSE, 0);
    gtk_flow_box_insert(GTK_FLOW_BOX(flowbox), global_card, -1);

    // Spaces Cards
    gchar *spaces_dir = g_build_filename(root, "Spaces", NULL);
    g_mkdir_with_parents(spaces_dir, 0755);
    GDir *dir = g_dir_open(spaces_dir, 0, NULL);
    if (dir) {
        const gchar *name;
        while ((name = g_dir_read_name(dir)) != NULL) {
            if (name[0] == '.') continue;
            
            gchar *full_path = g_build_filename(spaces_dir, name, NULL);
            if (g_file_test(full_path, G_FILE_TEST_IS_DIR)) {
                // Render card for this workspace
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
                
                GtkWidget *list_box = gtk_list_box_new();
                gtk_style_context_add_class(gtk_widget_get_style_context(list_box), "sidebar-scroll");
                g_signal_connect(list_box, "row-activated", G_CALLBACK(on_file_row_activated), NULL);
                
                int count = 0;
                for (int i = 0; subdirs[i] != NULL && count < 3; i++) {
                    gchar *subdir_full = g_build_filename(full_path, subdirs[i], NULL);
                    GDir *inner_dir = g_dir_open(subdir_full, 0, NULL);
                    if (inner_dir) {
                        const gchar *file_name;
                        while ((file_name = g_dir_read_name(inner_dir)) != NULL && count < 3) {
                            if (file_name[0] == '.') continue;
                            if (!g_str_has_suffix(file_name, ".md")) continue;
                            
                            gchar *clean_name = g_strdup(file_name);
                            gchar *ext = g_strrstr(clean_name, ".md");
                            if (ext) *ext = '\\0';
                            gchar *uuid_sep = g_strrstr(clean_name, "_");
                            if (uuid_sep && strlen(uuid_sep) > 10) *uuid_sep = '\\0';
                            
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
                g_object_set_data_full(G_OBJECT(btn_enter), "workspace_path", g_strdup(full_path), g_free);
                g_signal_connect(btn_enter, "clicked", G_CALLBACK(on_enter_workspace_clicked), NULL);
                gtk_box_pack_end(GTK_BOX(card), btn_enter, FALSE, FALSE, 0);
                
                gtk_flow_box_insert(GTK_FLOW_BOX(flowbox), card, -1);
            }
            g_free(full_path);
        }
        g_dir_close(dir);
    }
    g_free(spaces_dir);
    g_free(root);
    gtk_widget_show_all(flowbox);
}"""

code = re.sub(r'    gchar \*root = get_workspaces_root\(\);\n    g_mkdir_with_parents\(root, 0755\);\n\n    GDir \*dir = g_dir_open\(root, 0, NULL\);.*?\n}', new_pop, code, flags=re.DOTALL)

with open("jenova-ui/src/workspace_explorer.c", "w") as f:
    f.write(code)

