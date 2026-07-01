#include "canvas.h"
#include <math.h>
#include <stdlib.h>

#define NUM_PARTICLES 80

/* Data-oriented struct-of-arrays approach for better cache locality */
typedef struct {
    double x[NUM_PARTICLES];
    double y[NUM_PARTICLES];
    double vx[NUM_PARTICLES];
    double vy[NUM_PARTICLES];
} ParticleSystem;

static ParticleSystem p_sys;
static gboolean initialized = FALSE;

static gboolean on_draw_canvas(GtkWidget *widget, cairo_t *cr, gpointer data G_GNUC_UNUSED) {
    int width = gtk_widget_get_allocated_width(widget);
    int height = gtk_widget_get_allocated_height(widget);

    /* Solid background (#131313) */
    cairo_set_source_rgb(cr, 0x13 / 255.0, 0x13 / 255.0, 0x13 / 255.0);
    cairo_paint(cr);

    if (!initialized) {
        int w = width > 1 ? width : 900;
        int h = height > 1 ? height : 600;
        for (int i = 0; i < NUM_PARTICLES; i++) {
            p_sys.x[i] = g_random_double_range(0, w);
            p_sys.y[i] = g_random_double_range(0, h);
            p_sys.vx[i] = g_random_double_range(-0.25, 0.25);
            p_sys.vy[i] = g_random_double_range(-0.25, 0.25);
        }
        initialized = TRUE;
    }

    /* Update Phase */
    for (int i = 0; i < NUM_PARTICLES; i++) {
        p_sys.x[i] += p_sys.vx[i];
        p_sys.y[i] += p_sys.vy[i];

        if (p_sys.x[i] < 0 || p_sys.x[i] > width) p_sys.vx[i] *= -1;
        if (p_sys.y[i] < 0 || p_sys.y[i] > height) p_sys.vy[i] *= -1;
    }

    /* Screen blend mode mimicking HTML mix-blend-mode: screen */
    cairo_set_operator(cr, CAIRO_OPERATOR_SCREEN);
    cairo_set_line_width(cr, 1.0);

    /* Draw Phase: Particles */
    for (int i = 0; i < NUM_PARTICLES; i++) {
        cairo_arc(cr, p_sys.x[i], p_sys.y[i], 1.5, 0, 2 * G_PI);
        /* 0.4 fill * 0.3 overall opacity = 0.12 */
        cairo_set_source_rgba(cr, 221/255.0, 183/255.0, 255/255.0, 0.4 * 0.3);
        cairo_fill(cr);
    }

    /* Draw Phase: Connections */
    for (int i = 0; i < NUM_PARTICLES; i++) {
        double px = p_sys.x[i];
        double py = p_sys.y[i];
        for (int j = i + 1; j < NUM_PARTICLES; j++) {
            double dx = px - p_sys.x[j];
            double dy = py - p_sys.y[j];
            double dist_sq = dx * dx + dy * dy;

            if (dist_sq < 150.0 * 150.0) {
                double dist = sqrt(dist_sq);
                cairo_move_to(cr, px, py);
                cairo_line_to(cr, p_sys.x[j], p_sys.y[j]);
                /* (1 - dist/150) * 0.3 opacity */
                cairo_set_source_rgba(cr, 185/255.0, 199/255.0, 228/255.0, (1.0 - dist / 150.0) * 0.3);
                cairo_stroke(cr);
            }
        }
    }

    return FALSE; /* let other handlers run if needed */
}

static gboolean on_animate(GtkWidget *widget) {
    gtk_widget_queue_draw(widget);
    return G_SOURCE_CONTINUE; /* Continue timer */
}

GtkWidget* create_neural_canvas(void) {
    GtkWidget *da = gtk_drawing_area_new();
    g_signal_connect(da, "draw", G_CALLBACK(on_draw_canvas), NULL);
    /* Approx 60 FPS (1000ms / 60 = 16.6ms) */
    g_timeout_add(16, (GSourceFunc)on_animate, da);
    return da;
}
