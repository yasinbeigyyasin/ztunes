//! System tray: app icon + menu (Show / Play-Pause / Next / Previous / Restart / Quit). Menu actions
//! route into the same [`AppState`] methods the OS media keys use (see media.rs), so the tray
//! can never behave differently from MPRIS.
//!
//! macOS menu-bar extra via Tauri's `tray-icon` (Encore is a Mac app; Limusic's Linux `ksni`
//! backend was dropped).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tauri::{AppHandle, Emitter, Manager};

use crate::state::AppState;

pub use imp::{init, set_playing, set_track};

/// Whether a tray icon actually exists for the user to click.
///
/// On Linux it is a StatusNotifierItem, and a bar that only speaks the older XEmbed systray spec
/// (i3bar, dwm, xfce4-panel without its SNI plugin) runs no `StatusNotifierWatcher` at all, so
/// registration fails and no icon ever appears (#232). Closing to a tray that isn't there leaves
/// the app running with no window and no way back except a second launch, so ✕ checks this before
/// hiding. Optimistic: cleared by the Linux backend once it knows there is no watcher, and by
/// [`set_available`] when `init` fails.
static AVAILABLE: AtomicBool = AtomicBool::new(true);

/// Can the window be brought back from the tray? See [`AVAILABLE`].
pub fn available() -> bool {
    AVAILABLE.load(Ordering::Relaxed)
}

pub fn set_available(val: bool) {
    AVAILABLE.store(val, Ordering::Relaxed);
}

/// Bring the main window back from close-to-tray, minimize, or the mini player. Every "come back"
/// path — tray menu, tray click, second launch, the widget's restore button — goes through here so
/// they can't drift apart.
pub fn show_main(app: &AppHandle) {
    crate::mini::close(app);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        set_main_visible(app, true);
    }
}

/// Tell the main window's SPA whether anyone can see it.
///
/// WebKitGTK does not pass a GTK hide down to the page: `document.visibilityState` stays
/// `"visible"` for a window that is closed to the tray, so the SPA cannot work this out on its own
/// and keeps restyling for nobody. That is worse than wasted work. While the window is unmapped
/// the web process never gives any of it back: measured over 20 track changes with the window
/// hidden, it grew 137 MB and held it, then dropped the whole lot within two seconds of the window
/// being shown again. A night in the tray is thousands of those. See `theme.svelte.ts`.
pub fn set_main_visible(app: &AppHandle, visible: bool) {
    let _ = app.emit_to("main", "ui-visible", visible);
}

/// Shared by both backends: menu ids are the contract between them.
fn handle_menu(app: &AppHandle, id: &str) {
    match id {
        "show" => show_main(app),
        "quit" | "restart" => {
            if id == "restart" {
                // `request_restart`, not `restart`: it goes through RunEvent::Exit, which is
                // where the single-instance plugin releases the D-Bus name. Skip that and the
                // relaunched process hands off to the still-dying one and exits, leaving no app.
                //
                // ponytail: under `cargo tauri dev` this leaves you with no window. The CLI
                // exits when its child does, taking the vite server with it, so the relaunched
                // binary navigates to a dead devUrl and the transparent frameless window paints
                // nothing (taskbar + tray entry, no visible window). Release builds embed the
                // frontend, so restart is only usable there.
                app.request_restart();
            } else {
                app.exit(0);
            }
        }
        other => {
            let Some(state) = app.try_state::<Arc<AppState>>() else { return };
            let state = state.inner().clone();
            let id = other.to_string();
            tauri::async_runtime::spawn(async move {
                match id.as_str() {
                    "play_pause" => state.resume_or_toggle().await,
                    "next" => state.next_in_queue().await,
                    "prev" => state.prev_in_queue().await,
                    _ => {}
                }
            });
        }
    }
}

mod imp {
    use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
    use tauri::tray::{MouseButton, TrayIconBuilder, TrayIconEvent};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Mutex;

    use tauri::{AppHandle, Manager, Wry};

    use super::{handle_menu, show_main};

    /// 44x44 (22 pt @2x) black-on-transparent note. ── stream: polish ──
    pub(super) const TEMPLATE_PNG: &[u8] = include_bytes!("../icons/tray-template.png");

    /// Managed handle to the live-label item so the mpv event pump can flip "Play"/"Pause".
    struct TrayState {
        play_pause: MenuItem<Wry>,
        /// Disabled first row of the menu: what's playing.
        now_playing: MenuItem<Wry>,
        /// The short "Title · Artist" shown next to the menu-bar icon while playing.
        label: Mutex<String>,
        playing: AtomicBool,
    }

    /// Menu-bar text is precious: keep it to about the width of a short song name.
    const LABEL_MAX: usize = 32;

    pub(super) fn short_label(title: &str, artists: &str) -> String {
        let full = if artists.is_empty() { title.to_string() } else { format!("{title} · {artists}") };
        if full.chars().count() <= LABEL_MAX {
            full
        } else {
            let cut: String = full.chars().take(LABEL_MAX - 1).collect();
            format!("{}…", cut.trim_end())
        }
    }

    /// The icon shows the label only while something plays, like a now-playing indicator;
    /// paused or stopped, it's just the icon again.
    fn refresh_title(app: &AppHandle, t: &TrayState) {
        let label = t.label.lock().map(|l| l.clone()).unwrap_or_default();
        let show = t.playing.load(Ordering::Relaxed) && !label.is_empty();
        if let Some(tray) = app.tray_by_id("main") {
            let _ = tray.set_title(if show { Some(label.as_str()) } else { None });
        }
    }

    pub fn init(app: &AppHandle) -> tauri::Result<()> {
        let now_playing = MenuItem::with_id(app, "now_playing", "Nothing playing", false, None::<&str>)?;
        let show = MenuItem::with_id(app, "show", "Show Ztunes", true, None::<&str>)?;
        let play_pause = MenuItem::with_id(app, "play_pause", "Play", true, None::<&str>)?;
        let next = MenuItem::with_id(app, "next", "Next", true, None::<&str>)?;
        let prev = MenuItem::with_id(app, "prev", "Previous", true, None::<&str>)?;
        let restart = MenuItem::with_id(app, "restart", "Restart", true, None::<&str>)?;
        let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
        let menu = Menu::with_items(
            app,
            &[
                &now_playing,
                &PredefinedMenuItem::separator(app)?,
                &show,
                &PredefinedMenuItem::separator(app)?,
                &play_pause,
                &next,
                &prev,
                &PredefinedMenuItem::separator(app)?,
                &restart,
                &quit,
            ],
        )?;

        // Menu on right-click only, so a left double-click can't also pop it open behind the
        // window it just restored.
        let mut builder = TrayIconBuilder::with_id("main")
            .menu(&menu)
            .show_menu_on_left_click(false)
            .tooltip("Ztunes")
            .on_menu_event(|app, event| handle_menu(app, event.id.as_ref()))
            .on_tray_icon_event(|tray, event| {
                if let TrayIconEvent::DoubleClick { button: MouseButton::Left, .. } = event {
                    show_main(tray.app_handle());
                }
            });
        // ── stream: polish ── a monochrome template image (the app icon's note glyph, made by
        // scripts/brand/gen-brand.py), so macOS tints it for light/dark menu bars like every
        // other menu-bar extra. Falls back to the colour app icon if it can't be decoded.
        match tauri::image::Image::from_bytes(TEMPLATE_PNG) {
            Ok(icon) => builder = builder.icon(icon).icon_as_template(true),
            Err(_) => {
                if let Some(icon) = app.default_window_icon() {
                    builder = builder.icon(icon.clone());
                }
            }
        }
        // ── end stream: polish ──
        builder.build(app)?;

        app.manage(TrayState { play_pause, now_playing, label: Mutex::new(String::new()), playing: AtomicBool::new(false) });
        Ok(())
    }

    pub fn set_playing(app: &AppHandle, playing: bool) {
        if let Some(t) = app.try_state::<TrayState>() {
            let _ = t.play_pause.set_text(if playing { "Pause" } else { "Play" });
            t.playing.store(playing, Ordering::Relaxed);
            refresh_title(app, &t);
        }
    }

    /// A new track: the menu's first row gets the full name, the menu bar a short one.
    pub fn set_track(app: &AppHandle, title: &str, artists: &str) {
        if let Some(t) = app.try_state::<TrayState>() {
            let full = if artists.is_empty() { title.to_string() } else { format!("{title} — {artists}") };
            let _ = t.now_playing.set_text(if full.is_empty() { "Nothing playing".into() } else { full });
            if let Ok(mut l) = t.label.lock() {
                *l = short_label(title, artists);
            }
            refresh_title(app, &t);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering;

    use super::{available, AVAILABLE};

    /// ── stream: polish ── the menu-bar template decodes and is a pure alpha mask.
    #[test]
    fn menu_bar_label_is_short() {
        assert_eq!(super::imp::short_label("Song", "Artist"), "Song · Artist");
        assert_eq!(super::imp::short_label("Song", ""), "Song");
        let long = super::imp::short_label("A very long song title that goes on", "Somebody");
        assert!(long.chars().count() <= 32 && long.ends_with('…'));
    }

    #[test]
    fn tray_template_is_a_monochrome_mask() {
        let img = tauri::image::Image::from_bytes(super::imp::TEMPLATE_PNG).unwrap();
        assert_eq!((img.width(), img.height()), (44, 44));
        let px = img.rgba();
        assert!(px.chunks(4).all(|p| p[0] == 0 && p[1] == 0 && p[2] == 0));
        let ink = px.chunks(4).filter(|p| p[3] > 128).count();
        assert!(ink > 200 && ink < 44 * 44 / 2, "{ink}");
    }

    /// The gate lib.rs reads before hiding the window on ✕.
    #[test]
    fn no_watcher_means_no_close_to_tray() {
        assert!(available(), "a desktop with a working tray is the default");
        AVAILABLE.store(false, Ordering::Relaxed); // what watcher_offline does on i3bar (#232)
        assert!(!available());
        AVAILABLE.store(true, Ordering::Relaxed);
    }
}
