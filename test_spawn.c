#include <glib.h>
#include <stdio.h>
int main() {
    GError *error = NULL;
    if (!g_spawn_command_line_async("env LD_LIBRARY_PATH='test' ls", &error)) {
        printf("Error: %s\n", error->message);
    } else {
        printf("Success\n");
    }
    return 0;
}
