#include <gtk/gtk.h>

int main(int argc, char *argv[]) {
    gtk_init(&argc, &argv);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(win), 400, 300);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    GtkWidget *hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_container_add(GTK_CONTAINER(win), hbox);

    // Sidebar
    GtkWidget *sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_size_request(sidebar, 280, -1);
    
    // Add CSS background to sidebar to see its width
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p, "box { background-color: blue; padding: 16px 2px 16px 16px; }", -1, NULL);
    gtk_style_context_add_provider(gtk_widget_get_style_context(sidebar), GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_USER);
    g_object_unref(p);
    
    gtk_box_pack_start(GTK_BOX(hbox), sidebar, FALSE, FALSE, 0);

    GtkWidget *sw = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_shadow_type(GTK_SCROLLED_WINDOW(sw), GTK_SHADOW_NONE);
    gtk_widget_set_vexpand(sw, TRUE);
    gtk_widget_set_hexpand(sw, TRUE);
    gtk_widget_set_halign(sw, GTK_ALIGN_FILL);
    
    // Add CSS background to sw to see if it fills
    GtkCssProvider *p3 = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p3, "scrolledwindow { background-color: yellow; }", -1, NULL);
    gtk_style_context_add_provider(gtk_widget_get_style_context(sw), GTK_STYLE_PROVIDER(p3), GTK_STYLE_PROVIDER_PRIORITY_USER);
    g_object_unref(p3);

    gtk_box_pack_start(GTK_BOX(sidebar), sw, TRUE, TRUE, 0);

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    
    gtk_container_add(GTK_CONTAINER(sw), vbox);

    // Add a short button
    GtkWidget *btn = gtk_button_new();
    GtkWidget *lbl = gtk_label_new("Short");
    gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(lbl), 1);
    gtk_container_add(GTK_CONTAINER(btn), lbl);
    gtk_box_pack_start(GTK_BOX(vbox), btn, FALSE, FALSE, 0);
    
    gtk_widget_show_all(win);
    
    gint64 start_time = g_get_monotonic_time();
    while (g_get_monotonic_time() - start_time < 500000) {
        while (gtk_events_pending()) {
            gtk_main_iteration();
        }
        GtkAllocation alloc;
        gtk_widget_get_allocation(sw, &alloc);
        if (alloc.width > 0) break;
        g_usleep(10000);
    }
    
    GtkAllocation alloc;
    gtk_widget_get_allocation(sw, &alloc);
    g_print("SW allocated width: %d\n", alloc.width);
    if (alloc.width <= 0) {
        return 1;
    }

    GtkAllocation btn_alloc;
    gtk_widget_get_allocation(btn, &btn_alloc);
    g_print("Btn allocated width: %d\n", btn_alloc.width);
    if (btn_alloc.width <= 0 || btn_alloc.width > alloc.width) {
        g_print("Error: Invalid btn width (%d) relative to SW width (%d)\n", btn_alloc.width, alloc.width);
        return 1;
    }

    return 0;
}
