#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#if defined(GDK_WINDOWING_WAYLAND) && defined(HAVE_WAYLAND_CLIENT)
#include <wayland-client.h>
#endif
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include "desktop_multi_window/desktop_multi_window_plugin.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

#if defined(GDK_WINDOWING_WAYLAND) && defined(HAVE_WAYLAND_CLIENT)
static const wl_interface* plasma_set_output_types[] = {&wl_output_interface};
static const wl_message plasma_surface_requests[] = {
    {"destroy", "", nullptr},
    {"set_output", "o", plasma_set_output_types},
    {"set_position", "ii", nullptr},
    {"set_role", "u", nullptr},
    {"set_panel_behavior", "u", nullptr},
    {"set_skip_taskbar", "2u", nullptr},
};
static const wl_interface plasma_surface_interface = {
    "org_kde_plasma_surface", 2, G_N_ELEMENTS(plasma_surface_requests),
    plasma_surface_requests, 0, nullptr};
static const wl_interface* plasma_get_surface_types[] = {
    &plasma_surface_interface, &wl_surface_interface};
static const wl_message plasma_shell_requests[] = {
    {"get_surface", "no", plasma_get_surface_types},
};
static const wl_interface plasma_shell_interface = {
    "org_kde_plasma_shell", 2, G_N_ELEMENTS(plasma_shell_requests),
    plasma_shell_requests, 0, nullptr};

static void bind_plasma_shell(void* data, wl_registry* registry, uint32_t name,
                              const char* interface, uint32_t version) {
  if (version >= 2 && g_str_equal(interface, plasma_shell_interface.name)) {
    auto** shell = static_cast<wl_proxy**>(data);
    *shell = static_cast<wl_proxy*>(
        wl_registry_bind(registry, name, &plasma_shell_interface, 2));
  }
}

static void remove_registry_global(void*, wl_registry*, uint32_t) {}

static void destroy_plasma_surface(GtkWidget*, wl_proxy* surface) {
  wl_proxy_marshal_flags(surface, 0, nullptr, wl_proxy_get_version(surface),
                         WL_MARSHAL_FLAG_DESTROY);
}

static void skip_plasma_taskbar(GtkWidget* widget) {
  GdkWindow* window = gtk_widget_get_window(widget);
  if (!GDK_IS_WAYLAND_WINDOW(window)) return;

  wl_surface* surface = gdk_wayland_window_get_wl_surface(window);
  if (surface == nullptr) return;

  wl_display* display =
      gdk_wayland_display_get_wl_display(gdk_window_get_display(window));
  wl_registry* registry = wl_display_get_registry(display);
  wl_proxy* shell = nullptr;
  static const wl_registry_listener listener = {
      bind_plasma_shell, remove_registry_global};
  wl_registry_add_listener(registry, &listener, &shell);
  const int result = wl_display_roundtrip(display);
  wl_registry_destroy(registry);
  if (shell == nullptr) return;
  if (result >= 0) {
    constexpr uint32_t get_surface = 0;
    constexpr uint32_t set_skip_taskbar = 5;
    wl_proxy* metadata = wl_proxy_marshal_flags(
        shell, get_surface, &plasma_surface_interface, 2, 0, nullptr, surface);
    wl_proxy_marshal_flags(metadata, set_skip_taskbar, nullptr, 2, 0, 1u);
    g_signal_connect(widget, "unrealize", G_CALLBACK(destroy_plasma_surface),
                     metadata);
  }
  wl_proxy_destroy(shell);
}
#endif

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  const bool standalone =
      g_strcmp0(self->dart_entrypoint_arguments[0], "standalone_window") == 0;
  gtk_window_set_title(window, "ProxyPin");

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (standalone) {
    if (use_header_bar) {
      gtk_window_set_titlebar(window, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));
    }
    gtk_window_set_decorated(window, FALSE);
    gtk_window_set_skip_taskbar_hint(window, TRUE);
  } else if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "ProxyPin");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }

  gtk_window_set_default_size(window, 1280, 720);
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* bundle = g_path_get_dirname(executable);
    g_autofree gchar* icon = g_build_filename(
        bundle, "data", "flutter_assets", "assets", "icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

  gtk_widget_realize(GTK_WIDGET(window));
#ifdef GDK_WINDOWING_WAYLAND
  GdkWindow* surface = gtk_widget_get_window(GTK_WIDGET(window));
  if (GDK_IS_WAYLAND_WINDOW(surface)) {
    gdk_wayland_window_set_application_id(
        surface, g_application_get_application_id(application));
  }
#endif
#if defined(GDK_WINDOWING_WAYLAND) && defined(HAVE_WAYLAND_CLIENT)
  if (standalone) skip_plasma_taskbar(GTK_WIDGET(window));
#endif
  if (!standalone) gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  desktop_multi_window_plugin_set_window_created_callback([](FlPluginRegistry* registry){
    fl_register_plugins(registry);
  });

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  const gchar* application_id = g_getenv("PROXYPIN_APPLICATION_ID");
  if (application_id == nullptr || !g_application_id_is_valid(application_id)) {
    application_id = APPLICATION_ID;
  }
  g_set_prgname(application_id);
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", application_id,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
