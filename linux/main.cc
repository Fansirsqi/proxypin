#include <dlfcn.h>

#include "my_application.h"

int main(int argc, char** argv) {
#ifdef RTLD_DEEPBIND
  const char* quickjs_path = g_getenv("LIBQUICKJSC_PATH");
  if (quickjs_path == nullptr) {
    quickjs_path = "libquickjs_c_bridge_plugin.so";
  }
  if (dlopen(quickjs_path, RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND) == nullptr) {
    g_warning("Could not load the QuickJS bridge: %s", dlerror());
  }
#endif
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
