/* qdock — the games Pi's app dock: one icon per app, GNOME/macOS style.
 *
 * A pinned icon starts its app when nothing of it is open; once the app has a window the same icon stands for it
 * (bar underneath = running, shaded = focused). Clicking a running app's icon brings it forward; clicking the focused
 * one minimizes it (with several windows of one app, clicks cycle through them). Apps that are not pinned get an icon
 * of their own while they run. It never starts a second copy of an app: one window per app type saves the Pi's RAM
 * and GPU. Right-click: Close.
 *
 * Runs as a layer-shell surface over the left end of wf-panel-pi (which keeps the clock, volume and power; its own
 * launchers and window list are switched off). wf-panel-pi cannot be replaced without root: the system labwc
 * autostart respawns it. Windows come from wlr-foreign-toplevel-management (labwc supports it).
 *
 * Config: ~/.config/qdock/pinned — one .desktop id per line (e.g. qgames-chess), '#' comments. Restart to reload.
 * A window belongs to a pinned app when its app_id (or, failing that, its title) equals the .desktop StartupWMClass,
 * id, Exec basename or Name, case-insensitively. QDOCK_DEBUG=1 prints every window's app_id and title.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#include <gdk/gdkwayland.h>
#include <gio/gdesktopappinfo.h>
#include <gtk-layer-shell.h>
#include <gtk/gtk.h>
#include <wayland-client.h>

#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

#define PANEL_HEIGHT 52       /* wf-panel-pi with icon_size=48 (measured from a screenshot, 2026-11-18) */
#define ICON_SIZE 44
#define LAUNCH_TIMEOUT_S 40   /* a Godot game takes a few seconds on the Pi; Chromium longer when cold */

typedef struct App App;

typedef struct {
  struct zwlr_foreign_toplevel_handle_v1 *h;
  char *app_id, *title;
  gboolean activated, minimized, pending_activated, pending_minimized;
  guint64 focus_seq;   /* when it was last activated: the window an app click brings back */
  App *app;
} Win;

struct App {
  char *id;                /* desktop id without .desktop, or the app_id of an unknown app */
  char **keys;             /* lowercase app_id values that belong to this app */
  GDesktopAppInfo *info;   /* NULL: no .desktop found */
  gboolean pinned;
  GList *wins;
  GtkWidget *button, *image;
  gint64 launching_until;  /* monotonic µs; 0 = not starting */
};

static GtkWidget *window, *box;
static GList *apps;        /* App*, display order */
static struct wl_seat *seat;
static struct zwlr_foreign_toplevel_manager_v1 *manager;
static guint64 focus_counter;
static gboolean debug;
static GList *all_infos;   /* lazily loaded GAppInfo list, for unpinned apps */

static char *lower(const char *s) { return s ? g_ascii_strdown(s, -1) : NULL; }

static gboolean app_matches(App *a, const char *app_id) {
  g_autofree char *l = lower(app_id);
  if (!l) return FALSE;
  for (char **k = a->keys; k && *k; k++)
    if (strcmp(*k, l) == 0) return TRUE;
  return FALSE;
}

/* The app_id values a .desktop entry's windows may carry: StartupWMClass, the desktop id, the Exec basename, the Name.
 * Godot under Wayland and Chromium --class use one of these. */
static char **keys_for(GDesktopAppInfo *info, const char *id) {
  GPtrArray *k = g_ptr_array_new();
  const char *wm = g_desktop_app_info_get_startup_wm_class(info);
  if (wm) g_ptr_array_add(k, lower(wm));
  g_ptr_array_add(k, lower(id));
  const char *exe = g_app_info_get_executable(G_APP_INFO(info));
  if (exe) { g_autofree char *b = g_path_get_basename(exe); g_ptr_array_add(k, lower(b)); }
  const char *name = g_app_info_get_name(G_APP_INFO(info));
  if (name) g_ptr_array_add(k, lower(name));
  g_ptr_array_add(k, NULL);
  return (char **)g_ptr_array_free(k, FALSE);
}

static GDesktopAppInfo *info_for_app_id(const char *app_id) {
  g_autofree char *d = g_strconcat(app_id, ".desktop", NULL);
  GDesktopAppInfo *info = g_desktop_app_info_new(d);
  if (info) return info;
  g_autofree char *l = lower(app_id);
  g_autofree char *dl = g_strconcat(l, ".desktop", NULL);
  if ((info = g_desktop_app_info_new(dl))) return info;
  if (!all_infos) all_infos = g_app_info_get_all();
  for (GList *i = all_infos; i; i = i->next) {
    if (!G_IS_DESKTOP_APP_INFO(i->data)) continue;
    const char *wm = g_desktop_app_info_get_startup_wm_class(i->data);
    if (wm && g_ascii_strcasecmp(wm, app_id) == 0) return g_object_ref(i->data);
  }
  return NULL;
}

/* ---- UI ---- */

static void refresh(App *a) {
  GtkStyleContext *sc = gtk_widget_get_style_context(a->button);
  gboolean running = a->wins != NULL, focused = FALSE;
  for (GList *w = a->wins; w; w = w->next) focused |= ((Win *)w->data)->activated;
  if (running) a->launching_until = 0;
  gboolean starting = a->launching_until > g_get_monotonic_time();
  (running ? gtk_style_context_add_class : gtk_style_context_remove_class)(sc, "running");
  (focused ? gtk_style_context_add_class : gtk_style_context_remove_class)(sc, "focused");
  (starting ? gtk_style_context_add_class : gtk_style_context_remove_class)(sc, "starting");
  const char *name = a->info ? g_app_info_get_name(G_APP_INFO(a->info)) : a->id;
  if (!a->info && a->wins && ((Win *)a->wins->data)->title) name = ((Win *)a->wins->data)->title;
  g_autofree char *tip = starting ? g_strdup_printf("%s — starting…", name) : g_strdup(name);
  gtk_widget_set_tooltip_text(a->button, tip);
}

static void remove_app(App *a) {
  apps = g_list_remove(apps, a);
  gtk_widget_destroy(a->button);
  g_strfreev(a->keys);
  g_clear_object(&a->info);
  g_free(a->id);
  g_free(a);
}

static Win *latest_win(App *a) {
  Win *best = NULL;
  for (GList *w = a->wins; w; w = w->next)
    if (!best || ((Win *)w->data)->focus_seq > best->focus_seq) best = w->data;
  return best;
}

static void activate(Win *w) {
  if (w->minimized) zwlr_foreign_toplevel_handle_v1_unset_minimized(w->h);
  zwlr_foreign_toplevel_handle_v1_activate(w->h, seat);
}

static void detach_child(gpointer data) { (void)data; setsid(); }   /* the app outlives a dock restart */

static void launch(App *a) {
  if (!a->info) return;
  GAppLaunchContext *ctx = G_APP_LAUNCH_CONTEXT(gdk_display_get_app_launch_context(gdk_display_get_default()));
  GError *err = NULL;
  if (!g_desktop_app_info_launch_uris_as_manager(a->info, NULL, ctx, G_SPAWN_SEARCH_PATH, detach_child, NULL, NULL,
                                                 NULL, &err)) {
    g_warning("launch %s: %s", a->id, err->message);
    g_error_free(err);
  } else {
    a->launching_until = g_get_monotonic_time() + LAUNCH_TIMEOUT_S * G_USEC_PER_SEC;
  }
  g_object_unref(ctx);
  refresh(a);
}

static void on_click(App *a) {
  if (!a->wins) {
    if (a->launching_until > g_get_monotonic_time()) return;   /* already starting: no second copy */
    launch(a);
    return;
  }
  Win *focused = NULL;
  for (GList *w = a->wins; w; w = w->next)
    if (((Win *)w->data)->activated) focused = w->data;
  if (!focused) { activate(latest_win(a)); return; }
  if (!a->wins->next) { zwlr_foreign_toplevel_handle_v1_set_minimized(focused->h); return; }
  /* several windows: the next one after the focused, in list order */
  GList *n = g_list_find(a->wins, focused)->next;
  activate(n ? n->data : a->wins->data);
}

static void on_close(GtkMenuItem *item, App *a) {
  (void)item;
  for (GList *w = a->wins; w; w = w->next) zwlr_foreign_toplevel_handle_v1_close(((Win *)w->data)->h);
}

static gboolean on_button_release(GtkWidget *b, GdkEventButton *ev, App *a) {
  if (ev->button == 1) {
    on_click(a);
  } else if (ev->button == 3 && a->wins) {
    GtkWidget *menu = gtk_menu_new();
    GtkWidget *close = gtk_menu_item_new_with_label(a->wins->next ? "Close all windows" : "Close");
    g_signal_connect(close, "activate", G_CALLBACK(on_close), a);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), close);
    gtk_widget_show_all(menu);
    gtk_menu_popup_at_widget(GTK_MENU(menu), b, GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST, (GdkEvent *)ev);
  }
  return TRUE;
}

static App *add_app(const char *id, GDesktopAppInfo *info, gboolean pinned) {
  App *a = g_new0(App, 1);
  a->id = g_strdup(id);
  a->info = info;
  a->pinned = pinned;
  if (info) {
    a->keys = keys_for(info, id);
  } else {
    a->keys = g_new0(char *, 2);
    a->keys[0] = lower(id);
  }
  a->button = gtk_button_new();
  gtk_button_set_relief(GTK_BUTTON(a->button), GTK_RELIEF_NONE);
  gtk_widget_set_can_focus(a->button, FALSE);
  GIcon *icon = info ? g_app_info_get_icon(G_APP_INFO(info)) : NULL;
  a->image = icon ? gtk_image_new_from_gicon(icon, GTK_ICON_SIZE_DIALOG)
                  : gtk_image_new_from_icon_name("application-x-executable", GTK_ICON_SIZE_DIALOG);
  gtk_image_set_pixel_size(GTK_IMAGE(a->image), ICON_SIZE);
  gtk_container_add(GTK_CONTAINER(a->button), a->image);
  gtk_widget_add_events(a->button, GDK_BUTTON_RELEASE_MASK);
  g_signal_connect(a->button, "button-release-event", G_CALLBACK(on_button_release), a);
  gtk_box_pack_start(GTK_BOX(box), a->button, FALSE, FALSE, 0);
  gtk_widget_show_all(a->button);
  apps = g_list_append(apps, a);
  refresh(a);
  return a;
}

/* ---- windows (wlr-foreign-toplevel) ---- */

static void assign(Win *w) {
  App *target = NULL;
  for (GList *l = apps; l && !target; l = l->next)
    if (app_matches(l->data, w->app_id)) target = l->data;
  /* Exported Godot games all report one app_id (Godot_Engine under Xwayland, org.godotengine.Godot under Wayland):
   * tell them apart by window title, which is the game's name (= the .desktop Name / StartupWMClass). */
  for (GList *l = apps; l && !target; l = l->next)
    if (((App *)l->data)->pinned && app_matches(l->data, w->title)) target = l->data;
  if (target == w->app) return;
  if (w->app) {
    App *old = w->app;
    old->wins = g_list_remove(old->wins, w);
    if (!old->pinned && !old->wins) remove_app(old); else refresh(old);
  }
  if (!target && w->app_id && *w->app_id) {
    GDesktopAppInfo *info = info_for_app_id(w->app_id);
    /* an unpinned app that has a .desktop: key it by its desktop id so its other windows join it */
    target = add_app(w->app_id, info, FALSE);
    if (info) {
      char **k = keys_for(info, w->app_id);
      g_strfreev(target->keys);
      target->keys = k;
    }
  }
  w->app = target;
  if (target) target->wins = g_list_append(target->wins, w);
}

static void h_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t) {
  (void)h; Win *w = d; g_free(w->title); w->title = g_strdup(t);
}
static void h_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *id) {
  (void)h; Win *w = d; g_free(w->app_id); w->app_id = g_strdup(id);
}
static void h_output_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) { (void)d; (void)h; (void)o; }
static void h_output_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) { (void)d; (void)h; (void)o; }
static void h_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *st) {
  (void)h; Win *w = d; uint32_t *s;
  w->pending_activated = w->pending_minimized = FALSE;
  wl_array_for_each(s, st) {
    if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) w->pending_activated = TRUE;
    if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED) w->pending_minimized = TRUE;
  }
}
static void h_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
  (void)h; Win *w = d;
  if (w->pending_activated && !w->activated) w->focus_seq = ++focus_counter;
  w->activated = w->pending_activated;
  w->minimized = w->pending_minimized;
  if (debug) g_printerr("qdock: window app_id=%s title=%s%s%s\n", w->app_id, w->title,
                        w->activated ? " [focused]" : "", w->minimized ? " [minimized]" : "");
  assign(w);
  for (GList *l = apps; l; l = l->next) refresh(l->data);
}
static void h_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
  Win *w = d;
  if (w->app) {
    App *a = w->app;
    a->wins = g_list_remove(a->wins, w);
    if (!a->pinned && !a->wins) remove_app(a); else refresh(a);
  }
  zwlr_foreign_toplevel_handle_v1_destroy(h);
  g_free(w->app_id); g_free(w->title); g_free(w);
}
static void h_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p) {
  (void)d; (void)h; (void)p;
}
static const struct zwlr_foreign_toplevel_handle_v1_listener handle_listener = {
  h_title, h_app_id, h_output_enter, h_output_leave, h_state, h_done, h_closed, h_parent,
};

static void m_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m, struct zwlr_foreign_toplevel_handle_v1 *h) {
  (void)d; (void)m;
  Win *w = g_new0(Win, 1);
  w->h = h;
  zwlr_foreign_toplevel_handle_v1_add_listener(h, &handle_listener, w);
}
static void m_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) { (void)d; (void)m; }
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = { m_toplevel, m_finished };

static void r_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
  (void)d;
  if (strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
    manager = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, MIN(version, 3));
    zwlr_foreign_toplevel_manager_v1_add_listener(manager, &manager_listener, NULL);
  }
}
static void r_remove(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = { r_global, r_remove };

/* ---- stacking: wf-panel-pi restarts (lwrespawn) would put a fresh panel surface above the dock ---- */

static pid_t panel_pid(void) {
  GDir *proc = g_dir_open("/proc", 0, NULL);
  const char *e; pid_t found = 0;
  while (proc && (e = g_dir_read_name(proc)) && !found) {
    if (e[0] < '0' || e[0] > '9') continue;
    g_autofree char *p = g_strdup_printf("/proc/%s/comm", e), *comm = NULL;
    if (g_file_get_contents(p, &comm, NULL, NULL) && strcmp(g_strchomp(comm), "wf-panel-pi") == 0) found = atoi(e);
  }
  if (proc) g_dir_close(proc);
  return found;
}

static gboolean restack(gpointer d) {
  (void)d;
  gtk_widget_hide(window);
  gtk_widget_show_all(window);
  return G_SOURCE_REMOVE;
}

static gboolean tick(gpointer d) {
  (void)d;
  static pid_t last;
  pid_t p = panel_pid();
  if (p && last && p != last) g_timeout_add(2000, restack, NULL);   /* after the new panel has mapped */
  if (p) last = p;
  for (GList *l = apps; l; l = l->next) {   /* expire "starting" */
    App *a = l->data;
    if (a->launching_until && a->launching_until <= g_get_monotonic_time()) { a->launching_until = 0; refresh(a); }
  }
  return G_SOURCE_CONTINUE;
}

/* ---- setup ---- */

static void load_pinned(void) {
  g_autofree char *path = g_build_filename(g_get_user_config_dir(), "qdock", "pinned", NULL);
  g_autofree char *text = NULL;
  if (!g_file_get_contents(path, &text, NULL, NULL)) { g_warning("no %s", path); return; }
  g_auto(GStrv) lines = g_strsplit(text, "\n", -1);
  for (char **l = lines; *l; l++) {
    char *id = g_strstrip(*l);
    if (!*id || *id == '#') continue;
    if (g_str_has_suffix(id, ".desktop")) id[strlen(id) - 8] = 0;
    g_autofree char *d = g_strconcat(id, ".desktop", NULL);
    GDesktopAppInfo *info = g_desktop_app_info_new(d);
    if (!info) { g_warning("pinned %s: no such .desktop", id); continue; }
    add_app(id, info, TRUE);
  }
}

/* running: a short bar under the icon; focused: shaded, longer blue bar (GNOME dash / macOS dot) */
static const char *CSS =
  "window.qdock { background-color: @qdock_bg; }\n"
  "window.qdock button { padding: 0 5px; margin: 0; min-height: 0; border-radius: 0; border: none;"
  "  background: none; box-shadow: none; transition: none; }\n"
  "window.qdock button:hover { background-color: alpha(black, 0.06); }\n"
  "window.qdock button.running { background-image: linear-gradient(#4d4d4d, #4d4d4d);"
  "  background-size: 14px 3px; background-position: center bottom; background-repeat: no-repeat; }\n"
  "window.qdock button.focused { background-color: #bbbbb8; background-image: linear-gradient(#1a5fb4, #1a5fb4);"
  "  background-size: 30px 3px; }\n"
  "window.qdock button.starting image { opacity: 0.45; }\n";

int main(int argc, char **argv) {
  debug = g_getenv("QDOCK_DEBUG") != NULL;
  /* one dock per session */
  g_autofree char *lock = g_build_filename(g_get_user_runtime_dir(), "qdock.lock", NULL);
  int fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) return 0;

  g_setenv("NO_AT_BRIDGE", "1", TRUE);   /* no accessibility bus on the Pi: skip the AT-SPI bridge */
  gdk_set_allowed_backends("wayland");
  gtk_init(&argc, &argv);
  GdkDisplay *gd = gdk_display_get_default();
  if (!gd || !GDK_IS_WAYLAND_DISPLAY(gd)) { g_printerr("qdock: needs a Wayland session\n"); return 1; }

  GtkCssProvider *css = gtk_css_provider_new();
  g_autofree char *full = g_strdup_printf("@define-color qdock_bg %s;\n%s",
                                          g_getenv("QDOCK_BG") ? g_getenv("QDOCK_BG") : "#deddda", CSS);
  gtk_css_provider_load_from_data(css, full, -1, NULL);
  gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(css),
                                            GTK_STYLE_PROVIDER_PRIORITY_USER);

  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_style_context_add_class(gtk_widget_get_style_context(window), "qdock");
  gtk_layer_init_for_window(GTK_WINDOW(window));
  gtk_layer_set_namespace(GTK_WINDOW(window), "qdock");
  gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_TOP);
  gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
  gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
  gtk_layer_set_exclusive_zone(GTK_WINDOW(window), -1);   /* sit on the panel, not below it */
  gtk_layer_set_keyboard_mode(GTK_WINDOW(window), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
  gtk_widget_set_size_request(window, -1, PANEL_HEIGHT);
  box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_container_add(GTK_CONTAINER(window), box);

  load_pinned();

  struct wl_display *wd = gdk_wayland_display_get_wl_display(gd);
  seat = gdk_wayland_seat_get_wl_seat(gdk_display_get_default_seat(gd));
  struct wl_registry *reg = wl_display_get_registry(wd);
  wl_registry_add_listener(reg, &registry_listener, NULL);
  wl_display_roundtrip(wd);
  if (!manager) { g_printerr("qdock: compositor lacks wlr-foreign-toplevel-management\n"); return 1; }

  gtk_widget_show_all(window);
  g_timeout_add_seconds(3, tick, NULL);
  gtk_main();
  return 0;
}
