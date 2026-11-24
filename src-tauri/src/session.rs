//! Login webview (context/15 Path A). Opens a visible Google sign-in window with a spoofed desktop
//! UA, watches for the redirect back to music.youtube.com, captures the resulting cookies, and
//! feeds them through the **same** sign-in path as cookie-paste (`AppState::sign_in`).
//!
//! Persistent (non-incognito) on purpose: the webview keeps its own Google session, so a later
//! re-login is one click with no password/paste — the real fix for KI-2 (cookie staleness), where
//! Google's short-lived `__Secure-*SIDTS` cookies rotate and a pasted cookie eventually stops
//! authenticating.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::webview::cookie::Cookie;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::state::AppState;

const LOGIN_LABEL: &str = "login";
/// The hidden twin of [`LOGIN_LABEL`], used by [`refresh_session`]. Its own label so a refresh can
/// never collide with a sign-in window the user has open.
const REFRESH_LABEL: &str = "login-refresh";
/// Where the refresh webview goes. YTM itself, not the sign-in page: an already-signed-in jar
/// needs rotating, not a login.
const REFRESH_URL: &str = "https://music.youtube.com/";
/// How long to wait for that page to load before giving up on this attempt.
const REFRESH_TIMEOUT: Duration = Duration::from_secs(45);
/// Google rotates roughly hourly, so anything under this is a burst of 401s from one dead cookie,
/// not a second thing to fix.
const REFRESH_COOLDOWN: Duration = Duration::from_secs(5 * 60);

/// WebKitGTK and WKWebView are WebKit engines, so a macOS Safari UA is the most
/// internally-consistent spoof and the least likely to trip Google's "this browser may not be
/// secure" block. **Tune here** if Google rejects it — this is the fragile part (context/15 Path A).
#[cfg(not(target_os = "windows"))]
const LOGIN_UA: Option<&str> = Some(
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
     (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15",
);

/// Windows is WebView2, a Chromium engine, and overriding its UA does not touch the client hints it
/// sends: `Sec-CH-UA` still announces Edge and `Sec-CH-UA-Platform` still says Windows. A macOS
/// Safari UA therefore contradicts the request it rides on, and Google answers the login with
/// "This browser or app may not be secure" (#152). WebView2's own default UA is Edge's, which
/// agrees with those hints, so there is nothing to spoof here.
#[cfg(target_os = "windows")]
const LOGIN_UA: Option<&str> = None;

/// YouTube's own sign-in hand-off: the page Google's login continues to, which turns the Google
/// session into youtube.com cookies (SAPISID) and then goes on to YouTube Music. Continuing to
/// music.youtube.com directly could land the user on YTM still signed out, with its own "Sign in"
/// button to press a second time.
const YOUTUBE_HANDOFF_URL: &str = "https://www.youtube.com/signin?action_handle_signin=true&app=desktop&next=https%3A%2F%2Fmusic.youtube.com%2F";

/// What YouTube Music's own "Sign in" button opens (taken from the page's `SIGNIN_URL`): Google's
/// login, continuing through [`YOUTUBE_HANDOFF_URL`].
const LOGIN_URL: &str = "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F";

/// Google's own "Add account" entry point. Unlike ServiceLogin it presents the fresh sign-in
/// screen rather than continuing straight through on an existing session, which is what lets a
/// second account be added. Same hand-off as [`LOGIN_URL`].
const ADD_ACCOUNT_URL: &str = "https://accounts.google.com/AddSession?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F";

/// Set once the sign-in window has been sent through [`YOUTUBE_HANDOFF_URL`] by hand, so a
/// hand-off that doesn't take is not repeated every second. Reset when a window opens.
static HANDED_OFF: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Size of the sign-in window, in logical pixels.
const LOGIN_SIZE: (f64, f64) = (480.0, 680.0);

/// Open the sign-in window, or bring it forward if it is already open. Returns immediately: the
/// sign-in finishes in [`encore_core::login::capture`], which tells the UI through `login-done`,
/// `login-error` or `login-cancelled` (plus `auth-changed` from the sign-in itself). `add_account`
/// picks the AddSession flow so an additional Google account can be added while another is
/// signed in.
///
/// A window attached to the main one rather than a webview inside it: a second webview in the main
/// window makes `get_webview_window("main")` return `None` for as long as it is there (Tauri only
/// calls a window a webview window while it holds exactly one), which would break the tray, the
/// mini player and everything else that looks the main window up, and it needs Tauri's
/// `unstable` feature. The attached window moves with the main one, stays above it, has no Dock or
/// taskbar entry, and the main window shows a "Signing in" sheet behind it with Cancel.
pub fn open_login(app: AppHandle, state: Arc<AppState>, add_account: bool) {
    // Window creation must happen on the main thread (GTK).
    let app2 = app.clone();
    let dispatched = app.run_on_main_thread(move || {
        // Already open: bring it back rather than building a second one under the same label.
        if let Some(w) = app2.get_webview_window(LOGIN_LABEL) {
            let _ = w.unminimize();
            let _ = w.show();
            let _ = w.set_focus();
            return;
        }
        // Add-account flow: sign the *webview* out of Google first, so the fresh sign-in is the
        // webview's only session and music.youtube.com lands on the new account instead of
        // auto-continuing into whichever one it was already holding. The app's own saved sessions
        // live in SQLite (`accounts`), not in this cookie store, so they are never touched here.
        if add_account {
            if let Err(e) = clear_google_webview_cookies(&app2) {
                let _ =
                    app2.emit("login-error", format!("Couldn't clear the previous session: {e}"));
                return;
            }
        }
        HANDED_OFF.store(false, std::sync::atomic::Ordering::SeqCst);
        let url = if add_account { ADD_ACCOUNT_URL } else { LOGIN_URL };
        let Ok(url) = tauri::Url::parse(url) else { return };
        // Every page load and navigation wakes the cookie poll, so a finished login is seen at
        // once rather than at the next tick.
        let (tx, nudge) = tokio::sync::mpsc::unbounded_channel::<()>();
        let tx2 = tx.clone();
        let builder = WebviewWindowBuilder::new(&app2, LOGIN_LABEL, WebviewUrl::External(url))
            .title("Google sign-in · Ztunes")
            .inner_size(LOGIN_SIZE.0, LOGIN_SIZE.1)
            .skip_taskbar(true)
            .minimizable(false)
            .on_page_load(move |_w, _payload| {
                let _ = tx.send(());
            })
            .on_navigation(move |_url| {
                let _ = tx2.send(());
                true
            });
        let builder = match LOGIN_UA {
            Some(ua) => builder.user_agent(ua),
            None => builder,
        };
        let main = app2.get_webview_window("main").filter(|m| m.is_visible().unwrap_or(false));
        let builder = match main {
            Some(main) => {
                let builder = match centred_on(&main) {
                    Some((x, y)) => builder.position(x, y),
                    None => builder.center(),
                };
                match builder.parent(&main) {
                    Ok(b) => b,
                    Err(e) => {
                        let _ = app2
                            .emit("login-error", format!("Couldn't open the sign-in window: {e}"));
                        return;
                    }
                }
            }
            None => builder.center(),
        };
        match crate::http::proxied(builder).build() {
            Ok(win) => {
                no_webgl(&win);
                let app = app2.clone();
                tauri::async_runtime::spawn(async move {
                    let mut nudge = nudge;
                    let end = encore_core::login::capture(
                        &state,
                        || read_login_jar(&app),
                        &mut nudge,
                        encore_core::login::POLL,
                        encore_core::login::TIMEOUT,
                    )
                    .await;
                    tracing::info!(?end, "sign-in window finished");
                    // Also after a manual close (`Cancelled`): nothing left to close, but the
                    // main window still needs its focus back.
                    close_login(&app);
                });
            }
            Err(e) => {
                let _ = app2.emit("login-error", format!("Couldn't open the sign-in window: {e}"));
            }
        }
    });
    if let Err(e) = dispatched {
        let _ = app.emit("login-error", format!("Couldn't open the sign-in window: {e}"));
    }
}

/// Close the sign-in window (the main window's Cancel). The capture sees it gone and reports
/// `login-cancelled`.
pub fn cancel_login(app: &AppHandle) {
    close_login(app);
}

/// Top-left corner that centres the sign-in window over the main window, in logical pixels.
fn centred_on(main: &tauri::WebviewWindow) -> Option<(f64, f64)> {
    let scale = main.scale_factor().ok()?;
    let pos = main.outer_position().ok()?.to_logical::<f64>(scale);
    let size = main.outer_size().ok()?.to_logical::<f64>(scale);
    let x = pos.x + (size.width - LOGIN_SIZE.0) / 2.0;
    // A little above centre, below the title bar: where a sheet sits.
    let y = pos.y + ((size.height - LOGIN_SIZE.1) / 3.0).max(28.0);
    Some((x, y))
}

/// The sign-in window's youtube.com `Cookie` header, or `None` once the window is gone. Empty
/// while it is off Google's and YouTube's own pages: nothing it does there can sign us in.
///
/// If the window sits on YouTube Music signed out while Google already has the user signed in
/// (a login flow that skipped YouTube's hand-off), it is sent through the hand-off once, so the
/// user never has to press YTM's own "Sign in".
async fn read_login_jar(app: &AppHandle) -> Option<String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let app2 = app.clone();
    app.run_on_main_thread(move || {
        let jar = app2.get_webview_window(LOGIN_LABEL).map(|wv| {
            let url = wv.url().ok();
            let host = url.as_ref().and_then(|u| u.host_str()).unwrap_or_default().to_owned();
            if !is_google_host(&host) {
                return String::new();
            }
            let cookies = match wv.cookies() {
                Ok(c) => c,
                Err(e) => {
                    tracing::debug!(error = %e, "could not read the sign-in window's cookies");
                    return String::new();
                }
            };
            let jar = youtube_cookie_header(cookies.clone());
            if needs_youtube_handoff(&host, &cookies, &jar)
                && !HANDED_OFF.swap(true, std::sync::atomic::Ordering::SeqCst)
            {
                if let Ok(to) = tauri::Url::parse(YOUTUBE_HANDOFF_URL) {
                    tracing::info!("signed in to Google but not YouTube; handing off");
                    let _ = wv.navigate(to);
                }
            }
            jar
        });
        let _ = tx.send(jar);
    })
    .ok()?;
    rx.await.ok()?
}

/// On YouTube Music, with a Google session in the jar but no YouTube one.
fn needs_youtube_handoff(host: &str, cookies: &[Cookie<'static>], youtube_jar: &str) -> bool {
    let google_session = cookies.iter().any(|c| {
        let domain = c.domain().unwrap_or_default().trim_start_matches('.');
        (domain == "google.com" || domain.ends_with(".google.com"))
            && matches!(c.name(), "SID" | "__Secure-1PSID" | "__Secure-3PSID")
    });
    host == "music.youtube.com"
        && google_session
        && innertube::cookie_sapisid(youtube_jar).is_none()
}

fn is_google_host(host: &str) -> bool {
    ["google.com", "youtube.com"]
        .iter()
        .any(|d| host == *d || host.strip_suffix(d).is_some_and(|h| h.ends_with('.')))
}

/// WebGL off in the Google webviews, as it already is in the main window (`tune_webview`).
///
/// accounts.google.com opens a WebGL context the moment "Next" is clicked, and music.youtube.com
/// opens one on load (fingerprinting, measured in WebKitGTK 2.52.5). On some Linux GPU stacks that
/// kills the web process: the sign-in window sits on its loading bar, then goes blank (reported on
/// CachyOS + niri, where the rest of the app ran fine because the main window has WebGL off). Both
/// pages take the `null` context in stride and carry on. Only WebGL: the rest of the fingerprint
/// surface stays at the defaults, so Google has less reason to call this browser unsafe.
fn no_webgl(win: &tauri::WebviewWindow) {
    #[cfg(target_os = "linux")]
    {
        use webkit2gtk::{SettingsExt, WebViewExt};
        let res = win.with_webview(|wv| {
            if let Some(settings) = WebViewExt::settings(&wv.inner()) {
                settings.set_enable_webgl(false);
            }
        });
        if let Err(e) = res {
            tracing::warn!(label = win.label(), error = %e, "could not turn WebGL off");
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = win;
}

/// Re-mint the stored cookie from the login webview's own Google session, with no user
/// interaction. Issue #165 / KI-2.
///
/// The exported `Cookie` header is a snapshot; Google rotates `__Secure-*SIDTS` out from under it
/// and eventually rejects it, at which point every account-scoped call 401s and the UI's "Try
/// again" can only repeat the same dead request. But the webview jar is *not* a snapshot: it is
/// persistent and still holds the long-lived `__Secure-1PSID`, so loading music.youtube.com in it
/// gets fresh rotated cookies exactly the way opening the site in a browser does. Then we export
/// them again through the ordinary sign-in path.
///
/// Nothing is emitted on failure: the user is already looking at "sign in again", and a webview
/// session that has genuinely expired leaves them exactly where they were.
pub async fn refresh_session(app: AppHandle, state: Arc<AppState>) {
    if !state.it.is_logged_in() || !claim_refresh() {
        return;
    }
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    let app2 = app.clone();
    let dispatched = app.run_on_main_thread(move || {
        if let Some(w) = app2.get_webview_window(REFRESH_LABEL) {
            let _ = w.destroy();
        }
        let Ok(url) = tauri::Url::parse(REFRESH_URL) else { return };
        // Not 1x1 like the cipher harness: this is a real page, and YouTube's own startup is what
        // makes Google hand out the rotated cookies.
        let builder = WebviewWindowBuilder::new(&app2, REFRESH_LABEL, WebviewUrl::External(url))
            .title("YouTube Music")
            .visible(false)
            .inner_size(1024.0, 768.0)
            .skip_taskbar(true)
            .decorations(false)
            .focused(false);
        let builder = match LOGIN_UA {
            Some(ua) => builder.user_agent(ua),
            None => builder,
        };
        let builder = builder.on_page_load(move |_w, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished)
                && payload.url().host_str() == Some("music.youtube.com")
            {
                let _ = tx.send(());
            }
        });
        match crate::http::proxied(builder).build() {
            Ok(win) => no_webgl(&win),
            Err(e) => tracing::warn!(error = %e, "could not open the session-refresh webview"),
        }
    });
    if dispatched.is_err() {
        return;
    }

    // `None` here is the build having failed (the sender was dropped), not a slow page.
    if !matches!(tokio::time::timeout(REFRESH_TIMEOUT, rx.recv()).await, Ok(Some(()))) {
        tracing::debug!("session refresh: the webview never reached music.youtube.com");
        close(&app, REFRESH_LABEL);
        return;
    }

    // Landing on the page and *having rotated* are not the same instant, so poll. Signing in with
    // a jar identical to the one we already hold would only spend two requests to be told the same
    // thing, so wait for a different one.
    //
    //
    // The jar must also still belong to the account being healed. The webview holds one Google
    // session at a time and "Add account" replaces it, so after a switch back to an earlier saved
    // account it is a *different* account's session sitting there; signing in with it would move
    // the app to that account behind the user's back. That account is then simply not refreshable
    // from here, and the user signs in with it again.
    // Re-read the live jar every pass rather than snapshotting it: a switch or a sign-out landing
    // mid-poll would otherwise leave the loop still hunting for the account it started on and
    // sign back into it behind the user.
    for _ in 0..8 {
        let current = state.it.cookie().unwrap_or_default();
        let Some(account) = innertube::cookie_sapisid(&current) else {
            close(&app, REFRESH_LABEL);
            return;
        };
        let cookie = read_login_cookies(&app, REFRESH_LABEL).await;
        if innertube::cookie_sapisid(&cookie) == Some(account) && !same_jar(&cookie, &current) {
            // The switch could still land during the export above, so the account is checked once
            // more under `AppState::auth`, where nothing can move underneath it.
            match state.sign_in(cookie, Some(account)).await {
                Ok(_) => tracing::info!("re-minted the login session from the login webview"),
                Err(error) => tracing::warn!(%error, "could not re-mint the login session"),
            }
            close(&app, REFRESH_LABEL);
            return;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    tracing::debug!("session refresh: the login webview had nothing fresher to offer");
    close(&app, REFRESH_LABEL);
}

/// Same cookies, whatever order they came out in. The stored header is rebuilt by two different
/// paths (the webview export sorts, the transport's rotation merge appends), so comparing the
/// strings would report a change on every launch.
fn same_jar(a: &str, b: &str) -> bool {
    let pairs = |s: &str| {
        let mut v: Vec<String> = s.split(';').map(|kv| kv.trim().to_owned()).collect();
        v.sort();
        v
    };
    pairs(a) == pairs(b)
}

/// One refresh at a time, and not more than one per [`REFRESH_COOLDOWN`]: a stale session throws
/// off a burst of 401s (nine of them in the report), and each is a signal to heal.
fn claim_refresh() -> bool {
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    let mut last = LAST.lock().unwrap();
    if last.is_some_and(|t| t.elapsed() < REFRESH_COOLDOWN) {
        return false;
    }
    *last = Some(Instant::now());
    true
}

/// Delete every google.com / youtube.com cookie from the webview's cookie store (one shared store
/// for all of the app's webviews). Only the webview-side Google session is lost: the app's saved
/// accounts are SQLite rows in `Db`, and the main window never sends YouTube cookies itself.
/// Reads through the main window's webview: it is always alive, and the store is profile-wide.
/// Verified on WebView2; if add-account ever lands on the wrong account on WebKitGTK, check
/// whether its cookie store is really shared.
///
/// Errors instead of carrying on: a half-cleared store leaves the old Google session in place and
/// the sign-in lands on the wrong account, which is exactly what this exists to prevent.
fn clear_google_webview_cookies(app: &AppHandle) -> Result<(), String> {
    let wv = app.get_webview_window("main").ok_or("main window missing")?;
    let cookies = wv.cookies().map_err(|e| e.to_string())?;
    let mut cleared = 0;
    for cookie in cookies {
        let domain = cookie.domain().unwrap_or_default().trim_start_matches('.').to_owned();
        let google = domain == "google.com" || domain.ends_with(".google.com");
        let youtube = domain == "youtube.com" || domain.ends_with(".youtube.com");
        if google || youtube {
            wv.delete_cookie(cookie).map_err(|e| e.to_string())?;
            cleared += 1;
        }
    }
    tracing::info!(cleared, "cleared the webview's Google session for add-account sign-in");
    Ok(())
}

/// Merge the youtube-domain cookies into a `Cookie` header string. Reads the platform cookie store
/// (HttpOnly + secure included), matching what a browser sends to music.youtube.com.
///
/// Hops to the main thread: both backends drive their platform event loop while they wait for the
/// store (`gtk::main_iteration` on WebKitGTK, `NSRunLoop::mainRunLoop` on WKWebView), so they are
/// written to be called from the thread that owns it.
async fn read_login_cookies(app: &AppHandle, label: &'static str) -> String {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let app2 = app.clone();
    if app
        .run_on_main_thread(move || {
            let jar = app2.get_webview_window(label).map(|wv| jar_of(&wv)).unwrap_or_default();
            let _ = tx.send(jar);
        })
        .is_err()
    {
        return String::new();
    }
    rx.await.unwrap_or_default()
}

/// Main thread only (see [`read_login_cookies`]).
fn jar_of(wv: &tauri::WebviewWindow) -> String {
    match wv.cookies() {
        Ok(cookies) => youtube_cookie_header(cookies),
        Err(e) => {
            tracing::debug!(label = wv.label(), error = %e, "could not read the webview's cookies");
            String::new()
        }
    }
}

/// Domain-match by hand rather than with `cookies_for_url`: WKWebView's implementation compares the
/// cookie's domain to the URL's host with `==`, so YouTube's `.youtube.com` cookies never match
/// music.youtube.com and macOS got an empty jar (no SAPISID, so sign-in gave up silently).
/// WebKitGTK matches domains properly, which is why Linux never saw it.
///
/// Anything outside youtube.com is dropped, google.com cookies included: this becomes a `Cookie`
/// header sent to YouTube, and a cookie without a domain we recognise doesn't belong in it.
fn youtube_cookie_header(mut cookies: Vec<Cookie<'static>>) -> String {
    // `Cookie::domain()` has already stripped the leading dot. Sorting means the most specific
    // domain is inserted last and so wins a name collision, the way a browser resolves one.
    cookies.sort_by_key(|c| c.domain().unwrap_or_default().len());
    let mut jar = std::collections::BTreeMap::new();
    for c in cookies {
        let domain = c.domain().unwrap_or_default();
        if domain == "youtube.com" || domain.ends_with(".youtube.com") {
            jar.insert(c.name().to_string(), c.value().to_string());
        }
    }
    jar.into_iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cookie(s: &str) -> Cookie<'static> {
        Cookie::parse(s.to_string()).unwrap()
    }

    #[test]
    fn keeps_the_youtube_jar_and_drops_everything_else() {
        // `.youtube.com` is where the auth cookies actually live, and the domain WKWebView refuses
        // to match against music.youtube.com.
        let header = youtube_cookie_header(vec![
            cookie("SAPISID=abc; Domain=.youtube.com"),
            cookie("SID=def; Domain=.youtube.com"),
            cookie("VISITOR_INFO1_LIVE=xyz; Domain=music.youtube.com"),
            cookie("SAPISID=notthisone; Domain=.google.com"),
            cookie("nodomain=1"),
        ]);
        assert_eq!(header, "SAPISID=abc; SID=def; VISITOR_INFO1_LIVE=xyz");
        // The check open_login gates on: no SAPISID means sign-in silently gives up.
        assert_eq!(innertube::cookie_sapisid(&header), Some("abc"));
    }

    #[test]
    fn the_most_specific_domain_wins_a_name_collision() {
        let header = youtube_cookie_header(vec![
            cookie("PREF=broad; Domain=.youtube.com"),
            cookie("PREF=specific; Domain=music.youtube.com"),
        ]);
        assert_eq!(header, "PREF=specific");
    }

    #[test]
    fn a_reordered_jar_is_not_a_fresher_one() {
        // The webview export sorts and the transport's rotation merge appends, so the same
        // cookies routinely arrive in a different order. Calling that "changed" would re-sign-in
        // on every launch; missing a real rotation would leave the session dead.
        assert!(same_jar("SAPISID=a; SID=b", "SID=b; SAPISID=a"));
        assert!(!same_jar("SAPISID=a; __Secure-3PSIDTS=new", "SAPISID=a; __Secure-3PSIDTS=old"));
    }

    #[test]
    fn a_signed_out_ytm_with_a_google_session_is_handed_off() {
        let google = vec![cookie("SID=g; Domain=.google.com"), cookie("NID=n; Domain=.google.com")];
        assert!(needs_youtube_handoff("music.youtube.com", &google, "PREF=x"));
        // YouTube already has its session: nothing to do.
        assert!(!needs_youtube_handoff("music.youtube.com", &google, "SAPISID=a; PREF=x"));
        // Not signed in to Google yet: the user is still logging in.
        let anon = vec![cookie("NID=n; Domain=.google.com")];
        assert!(!needs_youtube_handoff("music.youtube.com", &anon, "PREF=x"));
        // Still on Google's pages.
        assert!(!needs_youtube_handoff("accounts.google.com", &google, "PREF=x"));
    }

    #[test]
    fn the_login_continues_through_youtubes_own_hand_off() {
        for url in [LOGIN_URL, ADD_ACCOUNT_URL] {
            let url = tauri::Url::parse(url).unwrap();
            let next = url.query_pairs().find(|(k, _)| k == "continue").unwrap().1.into_owned();
            assert_eq!(next, YOUTUBE_HANDOFF_URL);
            let next = tauri::Url::parse(&next).unwrap();
            assert_eq!(next.host_str(), Some("www.youtube.com"));
            let to = next.query_pairs().find(|(k, _)| k == "next").unwrap().1.into_owned();
            assert_eq!(to, "https://music.youtube.com/");
        }
    }

    #[test]
    fn only_google_and_youtube_pages_are_read() {
        for host in ["accounts.google.com", "google.com", "music.youtube.com", "youtube.com"] {
            assert!(is_google_host(host), "{host}");
        }
        for host in ["notgoogle.com", "google.com.evil.example", "support.example.org"] {
            assert!(!is_google_host(host), "{host}");
        }
    }
}

/// Close the sign-in window and hand focus back to the main window: macOS otherwise activates
/// whichever app was in front before, as if Spotless had been left.
fn close_login(app: &AppHandle) {
    close(app, LOGIN_LABEL);
    // After the window is really gone: macOS picks the next active app once the destroy lands.
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(200)).await;
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Some(main) =
                app2.get_webview_window("main").filter(|m| m.is_visible().unwrap_or(false))
            {
                let _ = main.set_focus();
            }
        });
    });
}

fn close(app: &AppHandle, label: &'static str) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = app2.get_webview_window(label) {
            let _ = w.destroy();
        }
    });
}
