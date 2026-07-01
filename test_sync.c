#include <glib.h>
#include <stdio.h>
int main() {
    GError *error = NULL;
    gint exit_status = 0;
    if (g_spawn_command_line_sync("echo hello > out.txt", NULL, NULL, &exit_status, &error)) {
        printf("Success\n");
    } else {
        printf("Error\n");
    }
    return 0;
}
