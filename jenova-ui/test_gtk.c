#include <gtk/gtk.h>

int main(int argc, char *argv[]) {
    gtk_init(&argc, &argv);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(win), 400, 300);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_container_add(GTK_CONTAINER(win), paned);

    GtkWidget *sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p, "box { background-color: blue; }", -1, NULL);
    gtk_style_context_add_provider(gtk_widget_get_style_context(sidebar), GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_USER);
    
    gtk_paned_pack1(GTK_PANED(paned), sidebar, FALSE, FALSE);
    gtk_paned_set_position(GTK_PANED(paned), 150);

    GtkWidget *main_area = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkCssProvider *p2 = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p2, "box { background-color: red; }", -1, NULL);
    gtk_style_context_add_provider(gtk_widget_get_style_context(main_area), GTK_STYLE_PROVIDER(p2), GTK_STYLE_PROVIDER_PRIORITY_USER);
    gtk_paned_pack2(GTK_PANED(paned), main_area, TRUE, FALSE);

    // Style the paned separator to be invisible
    GtkCssProvider *p3 = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p3, "paned separator { background-color: transparent; min-width: 5px; }", -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(p3), GTK_STYLE_PROVIDER_PRIORITY_USER);

    gtk_widget_show_all(win);
    return 0;
}
