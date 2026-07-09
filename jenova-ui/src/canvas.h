#ifndef JENOVA_CANVAS_H
#define JENOVA_CANVAS_H

#include <gtk/gtk.h>

/* Creates a GtkDrawingArea widget that internally handles the 
 * Neural Canvas 60fps animation loop using cairo. */
GtkWidget* create_neural_canvas(void);

#endif // JENOVA_CANVAS_H
