//! The iOS app's view of the core (docs/research/23-ios-plan.md §1.3, step 2): one `EncoreCore`
//! object over `encore_core`'s `AppState`, plus an `EventListener` callback that receives the
//! same events, with the same JSON payloads, as the desktop UI (`api.ts` contract).
//!
//! First subset (S2): search, album/artist/playlist pages, stream resolution, play-queue control,
//! library likes/playlists, settings. Small, hot types are UniFFI records (`Song`, `StreamInfo`);
//! the big page shapes cross as JSON strings that Swift decodes with `Codable`, so the contract is
//! the one the desktop already tests and the bindings don't have to mirror ~40 serde types yet.
//! A `Song` carries its full JSON too, which is what goes back in for play/like/queue.
//!
//! Every async method runs on the core's tokio runtime (`encore_core::rt`), whatever executor
//! Swift polls it from.

use std::collections::HashSet;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use encore_core::host::Host;
use encore_core::js::{InProcEngine, JsEngine};
use encore_core::state::AppState;
use innertube::SongItem;

uniffi::setup_scaffolding!();

mod account; // stream ios-p2: the optional YouTube account
mod invoke;
mod video;
#[cfg(test)]
mod parity_test; // stream onecore: both bridges register the same commands

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    #[error("{0}")]
    Failed(String),
}

impl From<String> for CoreError {
    fn from(s: String) -> Self {
        CoreError::Failed(s)
    }
}

type R<T> = Result<T, CoreError>;

/// Receives every event the core emits (`queue`, `now-playing`, `position`, `playback-state`,
/// `library-changed`, …). `json` is the payload as the desktop UI gets it.
#[uniffi::export(with_foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, name: String, json: String);
}

/// Where the core keeps its files. iOS: `Application Support/Encore` and `Library/Caches/Encore`.
#[derive(uniffi::Record)]
pub struct CoreConfig {
    pub data_dir: String,
    pub cache_dir: String,
    /// Where a library export lands by default (iOS: the app's Documents, visible in Files).
    #[uniffi(default = None)]
    pub export_dir: Option<String>,
}

/// The app's secret store (the iOS Keychain through the Security framework). The core seals the
/// YouTube sign-in cookie into it instead of SQLite (`encore_core::secrets`).
#[uniffi::export(with_foreign)]
pub trait SecretStore: Send + Sync {
    /// `None` when there's no item of that name.
    fn get(&self, name: String) -> Result<Option<String>, CoreError>;
    fn set(&self, name: String, value: String) -> Result<(), CoreError>;
    fn delete(&self, name: String) -> Result<(), CoreError>;
}

struct ForeignSecrets(Arc<dyn SecretStore>);

impl encore_core::secrets::Store for ForeignSecrets {
    fn get(&self, name: &str) -> Result<Option<String>, String> {
        self.0.get(name.to_owned()).map_err(|e| e.to_string())
    }
    fn set(&self, name: &str, value: &str) -> Result<(), String> {
        self.0.set(name.to_owned(), value.to_owned()).map_err(|e| e.to_string())
    }
    fn delete(&self, name: &str) -> Result<(), String> {
        self.0.delete(name.to_owned()).map_err(|e| e.to_string())
    }
}

/// A track row. `json` is the whole `SongItem` (the desktop's shape), to pass back in.
#[derive(uniffi::Record, Clone)]
pub struct Song {
    pub video_id: String,
    pub title: String,
    pub artists: String,
    pub artist_id: Option<String>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub duration: Option<String>,
    pub thumbnail: Option<String>,
    pub json: String,
}

impl From<&SongItem> for Song {
    fn from(s: &SongItem) -> Self {
        Song {
            video_id: s.video_id.clone(),
            title: s.title.clone(),
            artists: s.artists.clone(),
            artist_id: s.artist_id.clone(),
            album: s.album.clone(),
            album_id: s.album_id.clone(),
            duration: s.duration.clone(),
            thumbnail: s.thumbnail.clone(),
            json: serde_json::to_string(s).unwrap_or_default(),
        }
    }
}

/// What this build's audio engine can do, so the UI hides what it can't (stream ios-eq: MPVKit's
/// FFmpeg has no Rubber Band and no reverb filters; speed runs on `scaletempo2`).
#[derive(uniffi::Record)]
pub struct AudioCapabilities {
    pub pitch: bool,
    pub reverb: bool,
    pub speed: bool,
    /// `full` (desktop FFmpeg: shelves + limiter) or `portable` (equalizer + volume only).
    pub eq_flavor: String,
}

/// A resolved, playable audio stream.
#[derive(uniffi::Record)]
pub struct StreamInfo {
    pub video_id: String,
    /// The googlevideo URL (mpv gets it through the loopback proxy in normal playback).
    pub url: String,
    pub itag: i64,
    /// Which InnerTube client produced it (`VISIONOS`, …).
    pub client: String,
    pub expires_in_seconds: i64,
    /// HTTP headers the stream must be fetched with (User-Agent).
    pub headers: std::collections::HashMap<String, String>,
}

struct FfiHost {
    listener: Arc<dyn EventListener>,
    data_dir: PathBuf,
    cache_dir: PathBuf,
    export_dir: Option<PathBuf>,
    secrets: std::sync::Mutex<Option<Arc<dyn SecretStore>>>,
}

impl Host for FfiHost {
    fn emit_json(&self, event: &str, json: String) {
        self.listener.on_event(event.to_owned(), json);
    }
    fn data_dir(&self) -> PathBuf {
        self.data_dir.clone()
    }
    fn cache_dir(&self) -> PathBuf {
        self.cache_dir.clone()
    }
    fn download_dir(&self) -> Option<PathBuf> {
        self.export_dir.clone()
    }
    /// Asked once at boot (`secrets::install`).
    fn secret_store(&self) -> Option<Box<dyn encore_core::secrets::Store>> {
        let s = self.secrets.lock().unwrap_or_else(|e| e.into_inner()).take()?;
        Some(Box::new(ForeignSecrets(s)))
    }
    /// The cipher runs in-process in JavaScriptCore (S3), never in a WKWebView.
    fn js_engine(&self) -> Option<Arc<dyn JsEngine>> {
        #[cfg(target_vendor = "apple")]
        {
            Some(Arc::new(InProcEngine::jsc()))
        }
        #[cfg(target_os = "android")]
        {
            Some(Arc::new(InProcEngine::quickjs()))
        }
        #[cfg(not(any(target_vendor = "apple", target_os = "android")))]
        {
            None
        }
    }
}

/// stream: instant. Player commands the app sends from its main thread, run in order on one
/// thread of their own so the caller never waits on mpv. Each logs if it took long enough that
/// running it on the main thread would have dropped frames.
fn off_main(what: &'static str, f: impl FnOnce() + Send + 'static) {
    type Job = (&'static str, Box<dyn FnOnce() + Send>);
    static TX: std::sync::OnceLock<std::sync::Mutex<std::sync::mpsc::Sender<Job>>> = std::sync::OnceLock::new();
    let tx = TX.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel::<Job>();
        let _ = std::thread::Builder::new().name("player-ctl".into()).spawn(move || {
            for (what, job) in rx {
                let t0 = std::time::Instant::now();
                job();
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                if ms > 8.0 {
                    tracing::warn!(what, ms, "slow player command (kept off the main thread)");
                }
            }
        });
        std::sync::Mutex::new(tx)
    });
    let _ = tx.lock().unwrap_or_else(|e| e.into_inner()).send((what, Box::new(f)));
}

/// Run `f` on the core's runtime and await it from whatever executor polls this.
async fn on_rt<F, T>(f: F) -> R<T>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Send + 'static,
{
    encore_core::rt::spawn(f).await.map_err(|e| CoreError::Failed(e.to_string()))?.map_err(Into::into)
}

fn song_item(json: &str) -> R<SongItem> {
    serde_json::from_str(json).map_err(|e| CoreError::Failed(format!("bad song json: {e}")))
}

fn to_json<T: serde::Serialize>(v: &T) -> Result<String, String> {
    serde_json::to_string(v).map_err(|e| e.to_string())
}

/// The `discography` command without a running core (pure), so the app's mock client and its tests
/// get the same chips as the real one.
#[uniffi::export]
pub fn discography(args_json: String) -> R<String> {
    Ok(to_json(&invoke::discography(&invoke::Args::parse(&args_json)?)?)?)
}

#[derive(uniffi::Object)]
pub struct EncoreCore {
    state: Arc<AppState>,
}

#[uniffi::export]
impl EncoreCore {
    /// Start the core: open the database, build the transport, player and extraction stack, and
    /// start the background services. Once per process.
    ///
    /// `secrets`: the Keychain store sign-in cookies are sealed into (`None`: they stay in SQLite).
    /// The network monitor is the core's own NWPathMonitor; the cipher runs in JavaScriptCore.
    #[uniffi::constructor(default(secrets = None))]
    pub fn new(
        config: CoreConfig,
        listener: Arc<dyn EventListener>,
        secrets: Option<Arc<dyn SecretStore>>,
    ) -> R<Arc<Self>> {
        init_logging(Path::new(&config.cache_dir));
        let host = Arc::new(FfiHost {
            listener,
            data_dir: PathBuf::from(config.data_dir),
            cache_dir: PathBuf::from(config.cache_dir),
            export_dir: config.export_dir.map(PathBuf::from),
            secrets: std::sync::Mutex::new(secrets),
        });
        let _rt = encore_core::rt::handle();
        let _guard = _rt.enter();
        let booted =
            encore_core::boot::start_core(host).map_err(|e| CoreError::Failed(e.to_string()))?;
        Ok(Arc::new(EncoreCore { state: booted.state.clone() }))
    }

    /// The first screen is up: a restored queue may now start (`play_on_start`).
    pub fn ui_mounted(&self) {
        encore_core::state::UI_MOUNTED.notify_one();
    }

    /// The desktop's Tauri `invoke`: `cmd` and the `camelCase` keys of `args_json` are exactly
    /// `ui/src/lib/api.ts`'s, and the answer is the JSON the desktop UI gets (`null` for none).
    /// See `invoke.rs` for the commands the iOS app uses.
    pub async fn invoke(&self, cmd: String, args_json: String) -> R<String> {
        let st = self.state.clone();
        let args = invoke::Args::parse(&args_json)?;
        on_rt(async move { to_json(&invoke::dispatch(&st, &cmd, args).await?) }).await
    }

    // ── audio output (PlaybackBridge, plan §2.3) ────────────────────────────────────────────────

    /// Reopen mpv's audio output (after an interruption, a route change or a media-services
    /// reset), keeping the file, position and pause state.
    ///
    /// stream: instant. Returns at once: the app calls this from its main thread (foreground,
    /// session activation, a stalled start), and mpv answers a command only once its core thread
    /// gets to it. It runs on [`off_main`]'s thread; a failure is logged.
    pub fn ao_reload(&self) -> R<()> {
        let mpv = self.state.player.raw_mpv().clone();
        off_main("ao_reload", move || {
            if let Err(e) = mpv.command("ao-reload", &[]) {
                tracing::warn!(error = %e, "ao-reload failed");
            }
        });
        Ok(())
    }

    /// Check the loopback stream proxies and rebuild one iOS reclaimed while the app was suspended
    /// (call on foreground and after the audio session is activated). True when one was dead.
    pub fn check_proxies(&self, reason: String) -> bool {
        encore_core::loopback::check_proxies(&reason)
    }

    /// Debug hook (`spotless://debug?audio=kill-proxy`): close both proxy listeners as iOS would.
    pub fn debug_kill_proxies(&self) {
        encore_core::loopback::kill_proxies();
    }

    /// Debug hook (`spotless://debug?audio=kill-proxy-on-load`): kill the audio proxy right after
    /// the next stream URL is handed to mpv, so the load itself is refused.
    pub fn debug_kill_proxy_on_load(&self) {
        encore_core::audioproxy::KILL_ON_NEXT_LOAD.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Pick mpv's audio output driver (`audiounit` on iOS; `pcm` / `null` for tests) and reopen it.
    /// `pcm_file`: where `ao=pcm` writes its WAV.
    pub fn set_audio_output(&self, ao: String, pcm_file: Option<String>) -> R<()> {
        let mpv = self.state.player.raw_mpv();
        let err = |e: libmpv2::Error| CoreError::Failed(e.to_string());
        if let Some(f) = pcm_file {
            mpv.set_property("ao-pcm-file", f.as_str()).map_err(err)?;
        }
        mpv.set_property("ao", ao.as_str()).map_err(err)?;
        let _ = mpv.command("ao-reload", &[]);
        Ok(())
    }

    /// Player volume 0–100 (the app keeps the system volume as the real control, like Spotify).
    /// stream: instant: returns at once, like [`Self::ao_reload`].
    pub fn set_volume(&self, volume: i64) -> R<()> {
        let st = self.state.clone();
        off_main("set_volume", move || {
            if let Err(e) = st.player.set_volume(volume) {
                tracing::warn!(error = %e, "set volume failed");
            }
        });
        Ok(())
    }

    /// Pitch / reverb / speed availability (probed once per process; the first call can take a
    /// moment, so call it off the main thread).
    pub fn audio_capabilities(&self) -> AudioCapabilities {
        let p = &self.state.player;
        AudioCapabilities {
            pitch: p.can_shift_pitch(),
            reverb: p.can_reverb(),
            speed: true,
            eq_flavor: match p.dsp_flavor() {
                player::dsp::Flavor::Full => "full",
                player::dsp::Flavor::Portable => "portable",
            }
            .to_owned(),
        }
    }

    /// The playing position in seconds, read now (Now Playing's elapsed time on seek / pause).
    pub fn position(&self) -> f64 {
        self.state.current_position()
    }

    // ── search & pages ──────────────────────────────────────────────────────────────────────────

    /// Songs for a query (re-ranked, studio version first). `record_history`: a submitted query.
    pub async fn search(&self, query: String, record_history: bool) -> R<Vec<Song>> {
        let st = self.state.clone();
        let items = on_rt(async move { encore_core::api::search(&st, query, record_history).await })
            .await?;
        Ok(items.iter().map(Song::from).collect())
    }

    /// The search page's categorized sections (`SearchResults` JSON).
    pub async fn search_all_json(&self, query: String, record_history: bool) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::api::search_all(&st, query, record_history).await?) })
            .await
    }

    /// An album page (`AlbumPage` JSON). `id` is the `MPRE…` browseId.
    pub async fn album_json(&self, id: String) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::api::get_album(&st, id).await?) }).await
    }

    /// An artist page (`ArtistPage` JSON). `id` is the `UC…` channel browseId.
    pub async fn artist_json(&self, id: String) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::api::get_artist(&st, id).await?) }).await
    }

    /// A playlist page (`PlaylistPage` JSON): YouTube's, a local one, Liked Songs or Made for you.
    pub async fn playlist_json(&self, id: String) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::api::get_playlist(&st, id, None, None).await?) })
            .await
    }

    // ── streams ─────────────────────────────────────────────────────────────────────────────────

    /// Resolve a playable audio stream for `video_id`. `client` pins one InnerTube client (e.g.
    /// `VISIONOS`) by disabling the others; `None` runs the normal chain.
    pub async fn resolve_stream(&self, video_id: String, client: Option<String>) -> R<StreamInfo> {
        let st = self.state.clone();
        on_rt(async move {
            let mut disabled: HashSet<String> = st.disabled_clients();
            if let Some(pin) = &client {
                disabled.extend(
                    std::iter::once(innertube::MAIN_CLIENT)
                        .chain(innertube::STREAM_FALLBACK_ORDER)
                        .filter(|k| k != pin)
                        .map(str::to_owned),
                );
            }
            let d = st
                .orchestrator
                .resolve(&video_id, false, st.quality(), &disabled)
                .await
                .map_err(|e| e.to_string())?;
            Ok(StreamInfo {
                video_id: d.video_id,
                url: d.stream_url,
                itag: d.itag,
                client: d.stream_client,
                expires_in_seconds: d.expires_in_seconds,
                headers: d.headers,
            })
        })
        .await
    }

    // ── play queue ──────────────────────────────────────────────────────────────────────────────

    /// Play a song (a `Song.json`), starting a radio queue behind it.
    pub async fn play(&self, song_json: String) -> R<()> {
        let (st, item) = (self.state.clone(), song_item(&song_json)?);
        on_rt(async move { encore_core::api::play(&st, item).await }).await
    }

    pub async fn play_index(&self, index: u32, start: Option<f64>) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::play_index(&st, index as usize, start).await }).await
    }

    pub async fn toggle_pause(&self) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::toggle_pause(&st).await }).await
    }

    pub async fn next_track(&self) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::next_track(&st).await }).await
    }

    pub async fn prev_track(&self) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::prev_track(&st).await }).await
    }

    pub async fn seek(&self, position: f64) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::seek(&st, position).await }).await
    }

    /// `off` | `all` | `one`.
    pub async fn set_repeat(&self, mode: String) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::set_repeat(&st, mode).await }).await
    }

    pub async fn toggle_shuffle(&self) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::toggle_shuffle(&st).await }).await
    }

    /// "Add to queue" for songs (`Song.json` each).
    pub async fn add_to_queue(&self, songs_json: Vec<String>) -> R<()> {
        let items = songs_json.iter().map(|j| song_item(j)).collect::<R<Vec<_>>>()?;
        let st = self.state.clone();
        on_rt(async move { encore_core::api::add_to_queue(&st, items, None, None).await }).await
    }

    /// The queue as the `queue-changed` event carries it.
    pub async fn queue_json(&self) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::api::get_queue(&st).await?) }).await
    }

    // ── library ─────────────────────────────────────────────────────────────────────────────────

    /// Liked Songs, newest first (`LikedEntry[]` JSON).
    pub async fn liked_songs_json(&self) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::library::lib_liked_songs(&st).await?) }).await
    }

    /// Like songs (`Song.json` each); answers which were new.
    pub async fn like(&self, songs_json: Vec<String>) -> R<Vec<bool>> {
        let items = songs_json.iter().map(|j| song_item(j)).collect::<R<Vec<_>>>()?;
        let st = self.state.clone();
        on_rt(async move { encore_core::library::lib_like(&st, items).await }).await
    }

    pub async fn unlike(&self, video_ids: Vec<String>) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::library::lib_unlike(&st, video_ids).await.map(|_| ()) })
            .await
    }

    /// The library's own playlists (`LibPlaylist[]` JSON).
    pub async fn playlists_json(&self) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::library::lib_playlists(&st).await?) }).await
    }

    /// Create a playlist (default name when `None`); answers it as `LibPlaylist` JSON.
    pub async fn create_playlist(&self, name: Option<String>) -> R<String> {
        let st = self.state.clone();
        on_rt(async move {
            to_json(&encore_core::library::lib_playlist_create(&st, name, None, None).await?)
        })
        .await
    }

    /// Add songs (`Song.json` each) to a library playlist.
    pub async fn add_to_playlist(&self, playlist_id: String, songs_json: Vec<String>) -> R<()> {
        let items = songs_json.iter().map(|j| song_item(j)).collect::<R<Vec<_>>>()?;
        let st = self.state.clone();
        on_rt(async move {
            encore_core::library::lib_playlist_add(&st, playlist_id, items, None, None)
                .await
                .map(|_| ())
        })
        .await
    }

    // ── settings ────────────────────────────────────────────────────────────────────────────────

    /// The UI settings as one JSON object (string values).
    pub async fn settings_json(&self) -> R<String> {
        let st = self.state.clone();
        on_rt(async move { to_json(&encore_core::api::get_settings(&st).await?) }).await
    }

    pub async fn set_setting(&self, key: String, value: String) -> R<()> {
        let st = self.state.clone();
        on_rt(async move { encore_core::api::set_setting(&st, &key, &value).await }).await
    }
}

/// The core's `tracing` log: `<cache_dir>/encore.log` (the previous launch in `encore.log.1`) and
/// stderr (`simctl launch --console-pty`). Info level, as on the desktop. Once per process.
fn init_logging(dir: &Path) {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::Layer;
    let filter = || tracing_subscriber::EnvFilter::new("info");
    let _ = std::fs::create_dir_all(dir);
    let path = dir.join("encore.log");
    let _ = std::fs::rename(&path, dir.join("encore.log.1"));
    let file = std::fs::File::create(&path).ok().map(std::sync::Mutex::new);
    let file_layer = file.map(|f| {
        tracing_subscriber::fmt::layer().with_ansi(false).with_writer(f).with_filter(filter())
    });
    let _ = tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer().with_ansi(false).with_filter(filter()))
        .with(file_layer)
        .try_init();
}
