// The UI's only door to Rust. context/11 UI contract — commands in, events out. The UI never
// touches YouTube; everything here is a Tauri command or event payload.
import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { t } from './i18n.svelte';

/** How the signed-in user rated a track (innertube `Rating`). The three states are mutually
 *  exclusive: liking a disliked track clears the dislike, and vice versa. */
export type Rating = 'like' | 'dislike' | 'indifferent';

/** One run of an artist line: its text, plus a channel id when that run links an artist. */
export interface ArtistRun {
	text: string;
	id?: string;
}

export interface SongItem {
	video_id: string;
	title: string;
	artists: string;
	/** Primary artist's channel browseId (`UC…`), when linked — makes the artist name navigable. */
	artist_id?: string;
	/** The artist line run by run — a collab links each name to its own page. Empty/absent when
	 * nothing is linked; render plain `artists` then. */
	artist_runs?: ArtistRun[];
	album?: string;
	/** The album's browseId (`MPRE…`), when linked — makes the album navigable. */
	album_id?: string;
	duration?: string;
	/** Play count as YouTube abbreviates it ("53M"). Album, artist and search rows. */
	play_count?: string;
	thumbnail?: string;
	/** Item id within a playlist — present only on playlist tracks; needed to remove them. */
	set_video_id?: string;
	/** Collaborative playlists only: who added this track, and one avatar per person (several on a
	 * Taste Match row more than one member shares). */
	added_by?: string;
	added_by_avatars?: string[];
	/** When the track went into the playlist (unix seconds). Playlists on this machine only:
	 *  YouTube sends no such date for its own. */
	added_at?: number;
	/** The signed-in user's rating (absent when the response didn't say — same as 'indifferent'). */
	rating?: Rating;
	/** "Add to library" off the row's own menu, with a token for each direction. Absent on rows
	 *  YouTube sent no menu for, and on the ones built here (local files, Your Rotation, a Listen
	 *  Together guest's queue) — the menu hides the action rather than offering a dead one.
	 *  Library ▸ Songs is not Liked Music: this is a feedback write, not a rating. */
	library?: { in_library: boolean; add_token?: string; remove_token?: string };
	/** Queued to play next ("Play next", or a guest's session add) — the "Next in queue" block. */
	queued?: boolean;
	/** Appended by "Add to queue": the end of the manual queue ("Next in queue"), ahead of the
	 *  rest of the playing context (Spotify order). */
	queued_end?: boolean;
	/** No client could resolve this row for playback: show it greyed out; playback skips it.
	 *  Playing it explicitly retries and clears the flag on success. */
	unavailable?: boolean;
	/** A podcast episode's queue row (`episodeSong`): its menu adds Download / Remove download. */
	is_episode?: boolean;
	/** The album/playlist either block was added from, for its heading in the queue panel. */
	queued_from?: string;
	/** Appended by autoplay radio continuation — drives the queue's "Autoplay" divider + badge. */
	autoplay?: boolean;
	/** Why the core put this episode next ("From …", "Because you follow …", "Popular in …"):
	 *  podcast up next. The queue rows show it in place of the show name. */
	reason?: string;
	/** YouTube flags the track explicit. Browse/search rows only: `/next` carries no badge, so a
	 *  radio- or autoplay-appended track arrives without it. */
	explicit?: boolean;
	/** This row links a music video rather than the audio track. */
	is_video?: boolean;
	/** The same song's other version (its music video, or back to the audio track), when YouTube
	 *  paired them. What the player view's Song/Video switch plays (#442). */
	counterpart?: string;
	/** One of the user's own YouTube Music uploads. Set by Rust and passed straight back on play:
	 *  only an authenticated client can stream one, and the row is where that is known. */
	is_upload?: boolean;
}

export interface NowPlaying {
	videoId: string;
	title: string;
	artists: string;
	artistId?: string;
	/** The artist line run by run — links each artist of a collab separately. */
	artistRuns?: ArtistRun[];
	thumbnail?: string;
	duration?: string;
	album?: string | null;
	streamClient: string;
	/** The user's rating of the track (null if unknown). */
	rating?: Rating | null;
	/** YouTube's `musicVideoType` says this is a video upload, not the generated audio track.
	 *  Gates the player view's music-video mode. */
	isVideo?: boolean;
	/** A podcast episode: the transport offers speed and 15-second skips (#500). */
	isEpisode?: boolean;
	/** stream: pod-fixes. False: no lyrics surface at all (card, button, takeover, full screen); an
	 *  episode shows its chapters and description instead (core `lyrics::offered`). */
	showsLyrics?: boolean;
	/** A broadcast on air: no length and nothing to seek, so a Live badge stands in for the bar (#424). */
	live?: boolean;
	/** stream: instant. Shown the moment it was picked, ahead of its audio (state.rs
	 *  `show_loading`): the play buttons spin until the next `now-playing` for it arrives. */
	loading?: boolean;
}

export type RepeatMode = 'off' | 'all' | 'one';

export interface QueueState {
	items: SongItem[];
	currentIndex: number;
	shuffle?: boolean;
	repeat?: RepeatMode;
	/** What seeded the queue (playlist/album title, "<song> Radio") — the "Next from" header. */
	sourceName?: string | null;
	/** The playlist the queue was started from, when it was one. What "Remove from this playlist"
	 *  in the player's track menu writes to; absent for radios, single songs and guest queues. */
	sourceId?: string | null;
	/** Title of the track a click replaced this queue mid-play, for the panel's "Back to …" line.
	 *  Set only while `backToPrevious` would actually do something: at the head of the queue, with
	 *  a kept one behind it. */
	prevTrack?: string | null;
	/** The playing device's Autoplay setting: this desktop's, or a linked phone's while the bar
	 *  controls it. Absent from a phone that predates it. */
	autoplay?: boolean | null;
}

export interface Account {
	signedIn: boolean;
	name?: string | null;
	handle?: string | null;
	email?: string | null;
	thumbnail?: string | null;
	channelId?: string | null;
	canSwitch?: boolean;
	/** The cookie authenticated, but a multi-channel login is not complete until one is chosen. */
	selectionRequired?: boolean;
}

export interface AccountIdentity {
	/** Opaque, process-local selector. Raw delegated/data-sync ids stay in Rust. */
	selectionKey: string;
	name: string;
	handle?: string | null;
	email?: string | null;
	thumbnail?: string | null;
	channelId?: string | null;
	selected: boolean;
}

/** One saved Google account (multi-account). Display fields only — cookies stay in Rust. */
export interface SavedAccount {
	/** Opaque, process-local selector. */
	id: string;
	name?: string | null;
	handle?: string | null;
	email?: string | null;
	thumbnail?: string | null;
	/** The account whose session is currently driving requests. */
	active: boolean;
}

export interface BrowseItem {
	kind: 'song' | 'playlist' | 'album' | 'artist';
	/** videoId (song) or browseId (playlist/album/artist). */
	id: string;
	title: string;
	subtitle?: string;
	thumbnail?: string;
	/** "3:47" — song items from a list-style shelf only (card shelves don't carry one). */
	duration?: string;
	/** Song cards only: the track's album (`MPRE…`), what puts "Go to album" in its menus. */
	albumId?: string;
	/** Song cards only: the artist line run by run, so a card that gets played keeps its links. */
	artistRuns?: ArtistRun[];
	/** Play count as YouTube abbreviates it ("2.5B") — search song rows only. */
	playCount?: string;
	/** YouTube flags this track/album explicit. */
	explicit?: boolean;
	/** Song cards only: one of the user's own uploads. Carried into the SongItem `asSong` builds,
	 *  because that flag is what picks the login-only client chain when it plays. */
	isUpload?: boolean;
	/** A broadcast on air (home's Live section): the card wears a Live badge. UI-only. */
	live?: boolean;
}

export interface HomeSection {
	title: string;
	/** Which of home's known sections this is (`HOME_KINDS`), in any language. Absent otherwise. */
	kind?: string;
	items: BrowseItem[];
	moreBrowseId?: string;
	moreParams?: string;
}
/** A mood/genre filter chip above the home feed; `params` re-fetches home filtered to it. */
export interface HomeChip {
	title: string;
	params: string;
}
export interface HomePage {
	chips: HomeChip[];
	sections: HomeSection[];
	continuation?: string;
}

/**
 * The Your Rotation auto-playlist's synthetic browseId (mirrors `ON_REPEAT_ID` in state.rs). It routes
 * like any other playlist; the only thing the UI does differently is draw an icon cover, because
 * a playlist built from local play counts has no artwork of its own.
 */
export const ON_REPEAT_ID = 'LIMUSIC_ON_REPEAT';

/**
 * Liked Music's browseId. YouTube edits this one through the rating endpoint, not `edit_playlist`,
 * so it is never an add/remove/rename target: liking the song is the edit.
 */
export const LIKED_MUSIC_ID = 'VLLM';

/**
 * YouTube Music's own Library ▸ Songs, despite the name: the songs saved to the account's library.
 * It browses like a playlist (no header, no sort menu), so `getPlaylist` reads it and the Library
 * page's Songs tab pages through it with `getPlaylistMore`.
 */
export const LIBRARY_SONGS_ID = 'FEmusic_liked_videos';

/**
 * The tracks the signed-in user uploaded to YouTube Music themselves. Browses like the songs grid
 * above, so the same tab component reads it; the rows come back with `is_upload` set, which is what
 * sends them down the login-only fallback chain when they play (issue #71).
 */
export const LIBRARY_UPLOADS_ID = 'FEmusic_library_privately_owned_tracks';

/**
 * Local music (Rust `local.rs`). A file on disk is a song whose `video_id` is `LOCAL:<path>`, and
 * an album of them is a browseId `LOCALALBUM:<key>` — so local items ride every existing surface
 * (cards, queue, Shortcuts, the album page) and play with no network.
 */
export const LOCAL_SONG_PREFIX = 'LOCAL:';
export const LOCAL_ALBUM_PREFIX = 'LOCALALBUM:';
/** An artist on this disk. Renders through the album route: same page, no YouTube channel. */
export const LOCAL_ARTIST_PREFIX = 'LOCALARTIST:';
/**
 * A playlist kept on this machine, no account needed (#251; mirrors `LOCAL_PLAYLIST_PREFIX` in
 * state.rs). The playlist commands answer it from SQLite, so it rides the same route and the same
 * calls as a YouTube playlist, and can hold local files as well as YouTube tracks.
 */
export const LOCAL_PLAYLIST_PREFIX = 'LOCALPLAYLIST:';
export const isLocalPlaylist = (id: string | undefined | null): boolean =>
	!!id && id.startsWith(LOCAL_PLAYLIST_PREFIX);
/** Anything with no YouTube item behind it: nothing to share, no radio, no account to save it to. */
export const isLocalId = (id: string | undefined | null): boolean =>
	!!id &&
	(id.startsWith(LOCAL_SONG_PREFIX) ||
		id.startsWith(LOCAL_ALBUM_PREFIX) ||
		id.startsWith(LOCAL_ARTIST_PREFIX) ||
		id.startsWith(LOCAL_PLAYLIST_PREFIX));

export interface LocalLibrary {
	/** Watched folders, as absolute paths. */
	folders: string[];
	albums: BrowseItem[];
	artists: BrowseItem[];
	songs: SongItem[];
	/** Song/album/artist ids that were in the library but are gone from disk since the last scan. */
	removed: string[];
}

/** The orders YouTube itself can put a playlist in — everything in `SortKey` but our own `plays`. */
export type ServerSort = 'default' | 'newest' | 'oldest' | 'title' | 'artist' | 'album' | 'top';

export interface SortMenu {
	/** The order YouTube has this list in right now, when it is one we have a name for. */
	selected?: ServerSort;
	/**
	 * The choice is a write, so storing it makes YouTube Music and every other client follow.
	 * Playlists you own only: elsewhere the menu is view-only (Liked Music remembers the last order
	 * asked for anyway, someone else's playlist does not).
	 */
	editable: boolean;
}

/** One day bucket of the play history: YouTube's own heading plus that day's rows. */
export interface HistoryGroup {
	title: string;
	items: SongItem[];
}

export interface PlaylistPage {
	title?: string;
	subtitle?: string;
	thumbnail?: string;
	/** The playlist's own blurb, which the edit dialog prefills its description with. */
	description?: string;
	/** `PUBLIC` / `PRIVATE` / `UNLISTED`. Only playlists you own report it. */
	privacy?: string;
	/** Custom artwork picked on this machine; falls back to `thumbnail` when unset. */
	cover?: string;
	items: SongItem[];
	continuation?: string;
	/** True only when the signed-in user owns this playlist (rename/delete allowed). */
	owned: boolean;
	/** Collaboration is on: others can add to it, and each person may remove only what they added. */
	collaborative: boolean;
	/** Absent on lists YouTube will not reorder: albums, its own radio mixes, Your Rotation. */
	sortMenu?: SortMenu;
	/** YouTube's own suggestions shelf (`getPlaylistSuggestions`), on playlists you own under 100
	 *  tracks. The rest get suggestions all the same, from the playlist's radio. */
	suggestions?: string;
}
export interface PlaylistContinuation {
	items: SongItem[];
	continuation?: string;
}
/** One batch of suggestions; `refresh` swaps it for a fresh one. */
export interface PlaylistSuggestions {
	items: SongItem[];
	refresh?: string;
}

export interface ArtistCarousel {
	title: string;
	/** The core's shelf kind (`innertube::section_kind`). */
	kind: 'albums' | 'singles' | 'videos' | 'featured' | 'playlists' | 'fans' | 'other';
	items: BrowseItem[];
	moreBrowseId?: string;
	moreParams?: string;
}
export interface SearchResults {
	/** The Top result can also be a podcast show or episode. */
	top: (BrowseItem | ExploreItem)[];
	songs: BrowseItem[];
	albums: BrowseItem[];
	artists: BrowseItem[];
	playlists: BrowseItem[];
}

/** Typeahead under a search field: query completions, then a few matching rows. */
export interface SearchSuggestions {
	queries: { text: string; /** One of the account's own past searches. */ history: boolean }[];
	items: BrowseItem[];
}

export interface AlbumPage {
	title?: string;
	artist?: string;
	artistId?: string;
	/** The artist line run by run — links each artist of a collaborative album separately. */
	artistRuns?: ArtistRun[];
	artistThumbnail?: string;
	subtitle?: string;
	secondSubtitle?: string;
	description?: string;
	thumbnail?: string;
	items: SongItem[];
	continuation?: string;
	/** The album itself is flagged explicit (the header wears the badge, not just some tracks). */
	explicit?: boolean;
	/** The album's audio playlist id (`OLAK5uy_…`) — autoplay's radio seed, and the save target. */
	playlistId?: string;
	/** Already saved to the signed-in user's library. */
	inLibrary: boolean;
	/** Card shelves under the tracks: other versions, more from the artist, related releases. */
	sections?: ArtistCarousel[];
}

export interface ArtistPage {
	name?: string;
	/** Wide hero/banner image from the page header. */
	thumbnail?: string;
	/** Round channel avatar. Only channels YouTube Music doesn't treat as artists have one. */
	avatar?: string;
	description?: string;
	subscribers?: string;
	monthlyListeners?: string;
	channelId: string;
	subscribed: boolean;
	topSongs: SongItem[];
	/** `VL…` playlist of all the artist's top songs, behind the shelf's "See all". */
	topSongsId?: string;
	sections: ArtistCarousel[];
}

// --- commands (context/11) -----------------------------------------------------------------
// `recordHistory` is true only for a query the user submitted: a signed-in search is written to the
// account's YouTube search history, so a typeahead preview must stay anonymous (#203).
export const search = (query: string, recordHistory = false) =>
	invoke<SongItem[]>('search', { query, recordHistory });
/** Video uploads only: covers, live sets and remixes with no official release. Empty when the
 *  "hide music videos" setting is on. */
export const searchVideos = (query: string) => invoke<SongItem[]>('search_videos', { query });
/** One song or video by id, title and art included (a pasted YouTube link). */
export const song = (videoId: string) => invoke<SongItem>('song', { videoId });
/** Unfiltered search → categorized sections. */
export const searchAll = (query: string, recordHistory = false) =>
	invoke<SearchResults>('search_all', { query, recordHistory });
/** The typeahead. Signed in, yet never written to search history: it's the request YTM's own
 *  search box sends on every keystroke. */
export const searchSuggestions = (query: string) =>
	invoke<SearchSuggestions>('search_suggestions', { query });
/** Filtered "Show more" card search for one category (albums / artists / playlists). */
export const searchCards = (query: string, category: 'albums' | 'artists' | 'playlists') =>
	invoke<BrowseItem[]>('search_cards', { query, category });
/** A single pick: this song only, then Autoplay (similar songs) when the user queue is empty.
 *  `from` labels "Playing from" (a search query). */
export const play = (item: SongItem, from?: string) => invoke<void>('play', { item, from });
// ── stream: firstaudio ──
/** A track is about to be played (row hovered or pressed): resolve it ahead. Fire and forget. */
export const hintPlay = (item: SongItem) => invoke<void>('hint_play', { item });
// ── end stream: firstaudio ──
/** `start` (seconds) opens the track that far in, for a timecode link. */
export const playIndex = (index: number, start?: number) =>
	invoke<void>('play_index', { index, start });
/** Play the current track's `counterpart` from the same position. Resolves once it plays. */
export const switchVersion = () => invoke<void>('switch_version');
/** Remove an upcoming track from the queue (host/local only — guests are add-only). */
export const removeFromQueue = (index: number) => invoke<void>('remove_from_queue', { index });
/** Drag-to-reorder: move the upcoming queue item at `from` to index `to` (both past the playing
 * track — the history and the playing row don't move). */
export const moveInQueue = (from: number, to: number) =>
	invoke<void>('move_in_queue', { from, to });
/**
 * "Play next": insert tracks right behind the playing one, behind any earlier "Play next" adds.
 * `from` is the album/playlist they came from.
 */
export const playNext = (items: SongItem[], from?: string) =>
	invoke<void>('play_next', { items, from });
/**
 * "Add to queue": the tracks go at the tail of the queue, behind the rest of the playing album or
 * playlist and anything added before, ahead of autoplay (#369). On a radio they go ahead of the
 * generated tracks instead. `continuation` is the source page's next-page token: the backend walks
 * the rest of a long playlist into the queue in the background.
 */
export const addToQueue = (items: SongItem[], from?: string, continuation?: string) =>
	invoke<void>('add_to_queue', { items, from, continuation });
/** Clear every upcoming track added by hand, with Play next or Add to queue. */
export const clearQueued = () => invoke<void>('clear_queued');
export const nextTrack = () => invoke<void>('next_track');
export const prevTrack = () => invoke<void>('prev_track');
/** Put back the queue a click replaced, at the track and position it was left at. Previous does
 *  this too, but only from the top of a track. */
export const backToPrevious = () => invoke<void>('back_to_previous');
export const toggleShuffle = () => invoke<void>('toggle_shuffle');
export const setRepeat = (mode: RepeatMode) => invoke<void>('set_repeat', { mode });
export const togglePause = () => invoke<void>('toggle_pause');
export const seek = (position: number) => invoke<void>('seek', { position });
export const setVolume = (volume: number) => invoke<void>('set_volume', { volume });
export interface Reverb {
	enabled: boolean;
	preset: number;
	dry: number;
	wet: number;
	decay: number;
	preDelay: number;
	damping: number;
	reflections: number;
}
// Lives with the presets, which a Node self-check imports without this module's Tauri imports.
export { DEFAULT_REVERB } from './effect-presets';
/** Tempo, pitch, and independent reverb controls. Music and spoken word keep separate speeds in the
 *  core (speeds.rs): `target` says which one this is, else whatever is playing. */
export type SpeedTarget = 'music' | 'episode';
export const setPlaybackParams = (speed: number, semitones: number, reverb: Reverb, target?: SpeedTarget) =>
	invoke<void>('set_playback_params', { speed, semitones, reverb, target });
export const onPlaybackParams = (cb: (p: { speed: number; semitones: number; reverb: Reverb }) => void) =>
	listen<{ speed: number; semitones: number; reverb: Reverb }>('playback-params', (e) => cb(e.payload));
export const getQueue = () => invoke<QueueState>('get_queue');
/** A `limusicvideo://` URL for the track's music video, or null when there isn't one. `maxHeight`
 *  caps the picture at what the box on screen can actually show. The bytes are proxied through
 *  Rust; the webview never sees a googlevideo URL. */
export const videoStream = (videoId: string, maxHeight: number) =>
	invoke<string | null>('video_stream', { videoId, maxHeight });

/** Drop the backend's memory of this track's video URL, after the element failed to load it. */
export const forgetVideoStream = (videoId: string) =>
	invoke<void>('forget_video_stream', { videoId });


/** What the event stream already reported, for a webview that started after it did. */
export interface PlaybackSnapshot {
	speed: number;
	semitones: number;
	reverb: Reverb;
	now: NowPlaying | null;
	paused: boolean;
	position: number;
	duration: number;
	/** The level restored from last run (or the one another window already set). */
	volume: number;
}
export const getPlayback = () => invoke<PlaybackSnapshot>('get_playback');

// --- settings (context/11) -----------------------------------------------------------------
export const getSettings = () => invoke<Record<string, string>>('get_settings');
export const setSetting = (key: string, value: string) =>
	invoke<void>('set_setting', { key, value });
/** Streamable client keys for the "disabled clients" setting. */
export const getStreamClients = () => invoke<string[]>('get_stream_clients');
/** Wipe both cache tiers (URL cache + mpv on-disk audio cache). */
export const clearCaches = () => invoke<void>('clear_caches');
// --- global hotkeys -------------------------------------------------------------------------
export interface HotkeysConfig {
	enabled: boolean;
	bindings: Record<string, string>;
}

export interface HotkeyRegisterResult {
	success: boolean;
	config: HotkeysConfig;
	errors: Record<string, string>;
}

export const getGlobalHotkeys = () => invoke<HotkeysConfig>('get_global_hotkeys');
export const globalHotkeysOnWayland = () => invoke<boolean>('global_hotkeys_on_wayland');
export const setGlobalHotkeys = (config: HotkeysConfig) =>
	invoke<HotkeyRegisterResult>('set_global_hotkeys', { config });
export const resetGlobalHotkeys = () => invoke<HotkeyRegisterResult>('reset_global_hotkeys');

/** False on Linux builds that aren't the AppImage (.rpm, the AUR package): they update through the
 *  package manager, so the UI offers a download link instead of an install button. */
export const canSelfUpdate = () => invoke<boolean>('can_self_update');
/** Open an http(s) link in the real browser, never in the webview itself. */
export const openExternal = (url: string) => invoke<void>('open_external', { url });
/** Real quit (not close-to-tray). Same path as the tray's Quit item. */
export const quitApp = () => invoke<void>('quit_app');

/** Environment + the redacted tail of `limusic.log`, for pasting into a bug report. */
export const diagnostics = () => invoke<string>('diagnostics');
/** Just the environment block, for prefilling the GitHub bug form. */
export const diagnosticsSummary = () => invoke<string>('diagnostics_summary');
/** The same text, written to a path the user picked in a save dialog. */
export const saveDiagnostics = (path: string) => invoke<void>('save_diagnostics', { path });

// --- auth (context/15) ---------------------------------------------------------------------
export const getAccount = () => invoke<Account>('get_account');
export const getAccountIdentities = () =>
	invoke<AccountIdentity[]>('get_account_identities');
export const switchAccount = (selectionKey: string) =>
	invoke<Account>('switch_account', { selectionKey });
export const signOut = () => invoke<void>('sign_out');
/**
 * Open the in-app Google sign-in webview (context/15 Path A). Result arrives via onAuthChanged.
 * With `addAccount`, Google's AddSession screen is used so a second account can be added even
 * while the webview already holds a Google session.
 */
export const loginWebview = (addAccount = false) => invoke<void>('login_webview', { addAccount });
export const cancelLogin = () => invoke<void>('cancel_login');
/** Saved Google accounts for the account menu (display fields only). */
export const getGoogleAccounts = () => invoke<SavedAccount[]>('get_google_accounts');
/** Activate a saved account without a Google re-login. Fails if its stored session expired. */
export const switchGoogleAccount = (id: string) =>
	invoke<Account>('switch_google_account', { id });
/** Delete a saved account; removing the active one signs out. */
export const removeGoogleAccount = (id: string) => invoke<void>('remove_google_account', { id });

// --- mini player (Rust mini.rs) ---------------------------------------------------------------
/** Hide the app to the tray and open the floating widget (a second window running this same SPA). */
export const openMini = () => invoke<void>('open_mini');
/** Close the widget and bring the app back. */
export const closeMini = () => invoke<void>('close_mini');
/** Shrink the widget to its compact size, or back (#301). Remembered for the next open. */
export const setMiniCompact = (compact: boolean) => invoke<void>('set_mini_compact', { compact });

// --- browse / library (context/08) ---------------------------------------------------------
/** `params` is a `HomeChip.params` token — omit for the unfiltered feed. */
export const getHome = (params?: string) => invoke<HomePage>('get_home', { params });
/** Home's Live section: broadcasts on air from official artist channels, most watched first (#424). */
export const getLiveNow = () => invoke<BrowseItem[]>('get_live_now');
export const getHomeMore = (token: string) => invoke<HomePage>('get_home_more', { token });

/**
 * Your Rotation is the app's own playlist (Rust builds it from this machine's play counts), so its
 * title and subtitle are our English rather than YouTube's, and Rust cannot translate them: the
 * UI language lives in the webview's localStorage and never reaches it. Relabelled here, on the
 * way in, because every surface that draws the tile reads it from one of these two calls.
 */
const relabelOnRepeat = (item: BrowseItem): BrowseItem =>
	item.id !== ON_REPEAT_ID
		? item
		: {
				...item,
				title: t('library.on_repeat'),
				// The count is Rust's leading number ("20 songs"); left alone if it ever isn't.
				subtitle: Number.isNaN(parseInt(item.subtitle ?? '', 10))
					? item.subtitle
					: t('library.songs_count', { count: parseInt(item.subtitle!, 10) })
			};

/** Same reason as Your Rotation: Rust's "12 songs" on a playlist kept on this machine. */
const relabelLocal = (item: BrowseItem): BrowseItem => {
	if (!isLocalPlaylist(item.id)) return relabelOnRepeat(item);
	const count = parseInt(item.subtitle ?? '', 10);
	if (Number.isNaN(count)) return item;
	return {
		...item,
		subtitle:
			count === 1
				? t('library.local_playlist_subtitle_one')
				: t('library.local_playlist_subtitle', { count })
	};
};

/** Every playlist in the library: Your Rotation, the ones on this machine, then the account's. */
export const getLibrary = () =>
	invoke<BrowseItem[]>('get_library').then((items) => items.map(relabelLocal));
/** Just the playlists on this machine. SQLite only, so it answers offline and signed out. */
export const getLocalPlaylists = () =>
	invoke<BrowseItem[]>('local_playlists').then((items) => items.map(relabelLocal));
export const getLibraryAlbums = () => invoke<BrowseItem[]>('get_library_albums');
export const getLibraryArtists = () => invoke<BrowseItem[]>('get_library_artists');
/** Library ▸ Artists ▸ Subscriptions: the channels the account subscribes to. */
export const getLibrarySubscriptions = () => invoke<BrowseItem[]>('get_library_subscriptions');
/**
 * The account's YouTube Music play history, in YouTube's own day buckets (Today, Yesterday, …).
 * Empty when signed out.
 */
export const getHistory = () => invoke<HistoryGroup[]>('get_history');
/**
 * `sort` asks YouTube to order the tracks; omit it to get whatever order the account already has
 * the list in, which is the one a fresh visit wants (it is what YouTube Music would show).
 */
export const getPlaylist = (id: string, sort?: ServerSort, desc?: boolean) =>
	invoke<PlaylistPage>('get_playlist', { id, sort, desc }).then((page) =>
		id !== ON_REPEAT_ID
			? page
			: {
					...page,
					title: t('library.on_repeat'),
					subtitle: t('library.on_repeat_subtitle', { count: page.items.length })
				}
	);
/**
 * Store a sort order on a playlist, so YouTube Music and every other client show it the same way.
 * Only for a list whose `sortMenu.editable` is true.
 */
export const setPlaylistSort = (playlistId: string, sort: ServerSort) =>
	invoke<void>('set_playlist_sort', { playlistId, sort });
/** With `total` (the playlist's track count) it fetches several pages at once, for a walk that wants
 *  the whole list. Without it, one page. */
export const getPlaylistMore = (token: string, total?: number) =>
	invoke<PlaylistContinuation>('get_playlist_more', { token, total });
/** `token` is `PlaylistPage.suggestions`, the last batch's `refresh`, or nothing at all. */
export const getPlaylistSuggestions = (playlistId: string, token?: string) =>
	invoke<PlaylistSuggestions>('get_playlist_suggestions', { playlistId, token });
/**
 * videoId → the ids of the playlists you own that hold it. Read straight from local SQLite, so it
 * answers instantly and is empty until `syncPlaylistIndex` has filled it in at least once.
 */
export const playlistIndex = () => invoke<Record<string, string[]>>('playlist_index');
/**
 * Re-walk your own playlists and answer with the rebuilt map. Skips the crawl while the stored one
 * is still inside its window, so calling this on every launch is cheap.
 */
export const syncPlaylistIndex = () => invoke<Record<string, string[]>>('sync_playlist_index');
/** The library playlists the last `syncPlaylistIndex` crawl found you can't edit: saved ones that
 *  belong to someone else. Empty until that crawl has run. */
export const readonlyPlaylists = () => invoke<string[]>('readonly_playlists');
/**
 * videoId → times played, from the local listening history, over the trailing window Your Rotation uses
 * (a month). A videoId that isn't in the map has not been played inside the window.
 */
export const getPlayCounts = () => invoke<Record<string, number>>('play_counts');

/** The stats page's lists (#396): times played and seconds heard, inside the window. */
export interface TopSong {
	song: SongItem;
	plays: number;
	secs: number;
}
export interface TopArtist {
	name: string;
	/** Their channel (`UC…`) or a local artist (`LOCALARTIST:…`); null when the credit links none. */
	id: string | null;
	/** The cover of their most-heard song, for when there's no photo. */
	thumbnail: string | null;
	plays: number;
	secs: number;
}
/** A show by time heard (podcast episodes count as listening time, never as songs). */
export interface TopPodcast {
	/** The show's browse id when its episodes were played from the show; null otherwise. */
	id: string | null;
	name: string;
	thumbnail: string | null;
	plays: number;
	secs: number;
}
export interface TopAlbum {
	id: string;
	title: string;
	artist: string;
	thumbnail: string | null;
	plays: number;
	secs: number;
}
/** Everything the stats page shows for one window, counted on this device. */
export interface ListeningStats {
	/** Seconds heard, podcast episodes included. */
	secs: number;
	/** Of those, podcast episodes. */
	podcastSecs: number;
	/** Distinct podcast episodes heard. */
	episodes: number;
	/** Seconds in the window of the same length just before this one; null for all time. */
	prevSecs: number | null;
	plays: number;
	songs: number;
	/** Songs played for the first time ever inside the window. */
	newSongs: number;
	artists: number;
	/** Seconds per local day (`2026-10-17`), oldest first, days with nothing left out. */
	days: [string, number][];
	/** Seconds per local weekday (0 = Sunday) and hour: `hours[day * 24 + hour]`. */
	hours: number[];
	topSongs: TopSong[];
	topArtists: TopArtist[];
	topAlbums: TopAlbum[];
	topPodcasts: TopPodcast[];
	/** Unix secs of the oldest play on record; null when nothing has been counted yet. */
	firstAt: number | null;
	/** Days in a row with a play, up to today, and the longest run ever. Whole history. */
	streak: number;
	bestStreak: number;
}
/** `since`: unix secs where the window starts, 0 for all time. It always ends now. */
export const listeningStats = (since: number) =>
	invoke<ListeningStats>('listening_stats', { since });
/** The `limit` most played artists of all time, on the stats page's counts. Home's Familiar Artists. */
export const topArtists = (limit: number) => invoke<TopArtist[]>('top_artists', { limit });
/** Forget every counted play. Your Rotation empties with it. */
export const clearListeningHistory = () => invoke<void>('clear_listening_history');
/**
 * `start`: the clicked track index, or `null` for "just play it" (random opener under shuffle).
 * `sourceId`: the page's playlist/album playlist id — makes autoplay continue with that
 * context's radio (omit to fall back to song radio seeded from the queue's last track).
 * `sourceName`: the page title, for the queue panel's "Next from" header.
 * `shuffle`: turn shuffle on for this queue — pass items in their real order, Rust shuffles.
 */
export const playPlaylist = (
	items: SongItem[],
	start: number | null,
	sourceId?: string,
	sourceName?: string,
	shuffle?: boolean,
	continuation?: string
) => invoke<void>('play_playlist', { items, start, sourceId, sourceName, shuffle, continuation });
/**
 * Start a radio: an endless YouTube-generated queue seeded on this item. `id` is the videoId
 * (song) or browseId/playlistId (everything else) — Rust resolves it to a radio playlist, so the
 * UI never builds one. `name` titles the queue ("<name> Radio").
 *
 * A song radio on the track that's already playing splices in behind it (no re-buffer); every
 * other case replaces the queue. Rejects when YouTube has no radio for the item.
 */
/** `start` (seconds) only applies to a song radio: the seed song opens at that offset. */
export const startRadio = (
	kind: 'song' | 'artist' | 'album' | 'playlist',
	id: string,
	name?: string,
	start?: number
) => invoke<void>('start_radio', { kind, id, name, start });
export const getAlbum = (id: string) => invoke<AlbumPage>('get_album', { id });
export const getArtist = (id: string) => invoke<ArtistPage>('get_artist', { id });
/** Other artists' releases this one is featured on (#456). `songsId` is the page's `topSongsId`. */
export const getArtistAppearsOn = (id: string, songsId: string) =>
	invoke<BrowseItem[]>('get_artist_appears_on', { id, songsId });
/** A Moods & Genres tile. `params` browses `MOODS_CATEGORY_ID` into that mood's playlists. */
export interface Mood {
	title: string;
	params: string;
	/** YouTube's own colour for the tile, `#rrggbb`. */
	color: string;
}
export interface MoodSection {
	title: string;
	items: Mood[];
}
export const MOODS_CATEGORY_ID = 'FEmusic_moods_and_genres_category';
export const getMoods = () => invoke<MoodSection[]>('get_moods');
/** A cover per tile (the first playlist in its category), keyed by the tile's `params`. */
export const getMoodArt = (params: string[]) =>
	invoke<Record<string, string>>('get_mood_art', { params });
export const getBrowseGrid = (id: string, params?: string) =>
	invoke<BrowseItem[]>('get_browse_grid', { id, params });

// --- local music (local.rs) ------------------------------------------------------------------
/** Rescan the watched folders. Cheap when nothing changed (one stat per file). */
export const getLocalLibrary = () => invoke<LocalLibrary>('get_local_library');
export const addLocalFolder = (path: string) => invoke<LocalLibrary>('add_local_folder', { path });
export const removeLocalFolder = (path: string) =>
	invoke<LocalLibrary>('remove_local_folder', { path });

// --- blocked artists (blocked.rs, plan 046) ---------------------------------------------------
/** One entry in the block list. `id` is the channel browseId when the blocked row linked one. */
export interface BlockedArtist {
	id?: string;
	name: string;
}
export const getBlockedArtists = () => invoke<BlockedArtist[]>('get_blocked_artists');
/** Blocks the artist and returns the new list. Rust also drops them out of the live queue. */
export const blockArtist = (id: string | undefined, name: string) =>
	invoke<BlockedArtist[]>('block_artist', { id, name });
/** `key` is the entry's channel id when it has one, else its name. */
export const unblockArtist = (key: string) => invoke<BlockedArtist[]>('unblock_artist', { key });

// --- write actions (context/01 ✎) ----------------------------------------------------------
/** Like, dislike, or clear the rating. YouTube's three states are mutually exclusive, so a dislike
 *  un-likes in the same call. */
export const rate = (videoId: string, rating: Rating) => invoke<void>('rate', { videoId, rating });
/** What `addToPlaylist` rejects with when the playlist belongs to someone else. */
export const PLAYLIST_NOT_EDITABLE = 'not_editable';
/** `false` = the playlist already had this track, so YouTube added nothing. */
export const addToPlaylist = (playlistId: string, videoId: string, allowDuplicates = false) =>
	invoke<boolean>('add_to_playlist', { playlistId, videoId, allowDuplicates });
export const removeFromPlaylist = (playlistId: string, videoId: string, setVideoId: string) =>
	invoke<void>('remove_from_playlist', { playlistId, videoId, setVideoId });

/** Bulk removal: one request, all or nothing. `tracks` is [videoId, setVideoId] per row. */
export const removeManyFromPlaylist = (playlistId: string, tracks: [string, string][]) =>
	invoke<void>('remove_many_from_playlist', { playlistId, tracks });
/** Move a playlist row in front of another one (`beforeSetVideoId`), or to the end when null. */
export const moveInPlaylist = (playlistId: string, setVideoId: string, beforeSetVideoId: string | null) =>
	invoke<void>('move_in_playlist', { playlistId, setVideoId, beforeSetVideoId });
/** `local` keeps it on this machine instead of the account, the only kind there is signed out.
 *  Answers the new id: a `LOCALPLAYLIST:` browseId for a local one, YouTube's playlist id else. */
export const createPlaylist = (title: string, local = false) =>
	invoke<string>('create_playlist', { title, local });
/** Add whole songs to a playlist on this machine, in one write. Answers per song whether it went
 *  in: `false` means the playlist already had it. Local files are fine here. */
export const addToLocalPlaylist = (playlistId: string, items: SongItem[]) =>
	invoke<boolean[]>('add_to_local_playlist', { playlistId, items });
/** Name / description / visibility, from the "Edit playlist" dialog. Leave a field out and
 *  YouTube is never told about it, so an untouched one can't be overwritten. */
export const editPlaylistDetails = (
	playlistId: string,
	changes: { name?: string; description?: string; public?: boolean }
) => invoke<void>('edit_playlist_details', { playlistId, ...changes });
/** Custom playlist artwork. `path` is a file the user picked; `null` drops it. Answers where the
 *  local copy went, and on a removal the thumbnail YouTube rebuilt from the tracks (that one is
 *  worth waiting for: YouTube's own thumbnail is the cover being removed until it lands). */
export const setPlaylistCover = (playlistId: string, path: string | null) =>
	invoke<{ cover?: string; thumbnail?: string }>('set_playlist_cover', { playlistId, path });
export const deletePlaylist = (playlistId: string) =>
	invoke<void>('delete_playlist', { playlistId });
export const subscribe = (channelId: string, subscribed: boolean) =>
	invoke<void>('subscribe', { channelId, subscribed });
/** Add a song to Library ▸ Songs, or take it out. `token` is `SongItem.library.add_token` /
 *  `.remove_token`; YouTube mints them per row, so they come from the list the song was shown in. */
export const setSongSaved = (token: string) => invoke<void>('set_song_saved', { token });
/** Save an album to the library (or remove it). `playlistId` is `AlbumPage.playlistId`. */
export const setAlbumSaved = (playlistId: string, saved: boolean) =>
	invoke<void>('set_album_saved', { playlistId, saved });

// --- Spotify import (spotify.rs, import.rs, #375) ----------------------------------------------
// Rejections are short codes (`private`, `busy`, ...) worded by `importError` in import.svelte.ts.

export type ImportTier = 'pending' | 'matched' | 'check' | 'missing';
export type ImportPhase = 'matching' | 'review' | 'creating' | 'done' | 'failed' | 'cancelled';
/** `liked` is Liked Songs, named in the user's language on this side. */
export type ImportListKind = 'playlist' | 'album' | 'liked' | 'history'; // history: stream import2

export interface ImportListPreview {
	kind: ImportListKind;
	name: string;
	owner?: string | null;
	cover?: string | null;
	count: number;
	/** Rows that aren't songs (podcast episodes), left out. */
	skipped: number;
	/** Spotify only let the first 100 tracks be read. */
	truncated: boolean;
	/** stream import2: a profile playlist, its tracks read once picked (`count` is 0 until then). */
	lazy?: boolean;
}
// ── stream: import2 ──
export interface ImportHistorySummary {
	/** Streams (plays past 30 s) in the export's history, and the distinct songs among them. */
	plays: number;
	songs: number;
	/** Unix seconds of the oldest and newest play. */
	from: number;
	to: number;
}
export interface SpotifyProfile {
	id: string;
	name: string;
	avatar?: string | null;
	playlists: { id: string; name: string; cover?: string | null }[];
	/** Public playlists the profile has; its page lists the first 10. */
	total: number;
}
// ── end stream: import2 ──
export interface ImportPreview {
	lists: ImportListPreview[];
	albums?: number;
	artists?: number;
	history?: ImportHistorySummary | null; // stream: import2
	profile?: SpotifyProfile | null; // stream: import2
}
export interface ImportResult {
	kind: ImportListKind;
	name: string;
	/** The browse id to open: `VL…`, or `LOCALPLAYLIST:<n>` on this device. */
	id: string;
	local: boolean;
	added: number;
	missing: number;
	removed: number;
	/** stream: ios-import-review — an earlier import's playlist got the new songs (no second copy). */
	updated?: boolean;
}
export interface ImportSnapshot {
	phase: ImportPhase;
	/** Distinct tracks across every list being imported. */
	total: number;
	done: number;
	matched: number;
	check: number;
	missing: number;
	lists: { kind: ImportListKind; name: string; count: number; cover?: string | null }[];
	/** The last few tracks matched, newest first. */
	recent: { title: string; artists: string; tier: ImportTier; thumbnail?: string | null }[];
	/** While creating: steps done, steps in all. */
	step: [number, number];
	/** Pausing to stay within the hourly search budget: the unix second it goes on. */
	waitingUntil?: number | null;
	message?: string | null;
	results: ImportResult[];
	/** Set when this is an "Update from Spotify" of that playlist rather than an import. */
	update?: string | null;
}
export interface ImportRow {
	key: string;
	title: string;
	artists: string;
	album?: string | null;
	durationMs?: number | null;
	tier: ImportTier;
	pick?: SongItem | null;
	/** Empty for matched rows. */
	candidates: SongItem[];
}
export type ImportResolved =
	| { kind: 'song'; song: SongItem }
	| { kind: 'album'; id: string }
	| { kind: 'artist'; id: string }
	| { kind: 'playlist' };

export const importReadLink = (link: string) => invoke<ImportPreview>('import_read', { link });
export const importReadPath = (path: string) => invoke<ImportPreview>('import_read', { path });
/** A dropped file: the bytes go over as the raw request body (a webview drop has no path). */
export const importReadFile = async (file: File) =>
	invoke<ImportPreview>('import_read_file', new Uint8Array(await file.arrayBuffer()), {
		headers: { 'x-file-name': encodeURIComponent(file.name) }
	});
/** `lists` are indices into the last preview. */
export const importStart = (lists: number[]) => invoke<ImportSnapshot>('import_start', { lists });
export const importStatus = () => invoke<ImportSnapshot | null>('import_status');
/** First run: offer the import? Empty library and never answered (core `library::import_offer`). */
export const importOffer = () => invoke<boolean>('import_offer');
/** The first-run import offer was answered: the core's `import_onboarding_done`. */
export const importOfferDone = () => invoke<void>('import_offer_done');
export const importRows = (tier: ImportTier) => invoke<ImportRow[]>('import_rows', { tier });
/** `null` leaves the track out. A song picked here is remembered for every later import. */
export const importPick = (key: string, song: SongItem | null) =>
	invoke<ImportSnapshot>('import_pick', { key, song });
export const importCreate = (options: { names?: Record<number, string>; local?: boolean }) =>
	invoke<void>('import_create', { options });
/** Stops a running import, or puts away a finished one. */
export const importCancel = () => invoke<void>('import_cancel');
export const importSource = (playlistId: string) =>
	invoke<string | null>('import_source', { playlistId });
export const importUpdate = (playlistId: string) =>
	invoke<ImportSnapshot>('import_update', { playlistId });
export const importResolve = (link: string) => invoke<ImportResolved>('import_resolve', { link });

// --- events (context/11). Each returns an unlisten fn; call it on component teardown. --------
export const onNowPlaying = (cb: (n: NowPlaying) => void): Promise<UnlistenFn> =>
	listen<NowPlaying>('now-playing', (e) => cb(e.payload));
/**
 * The backend asked YouTube what a track's rating really is and got a different answer than the
 * row we were handed (issue #93). Fires only on a change, at most once per track start.
 */
export const onRating = (cb: (videoId: string, rating: Rating) => void): Promise<UnlistenFn> =>
	listen<{ videoId: string; rating: Rating }>('rating', (e) =>
		cb(e.payload.videoId, e.payload.rating)
	);
export const onQueueChanged = (cb: (q: QueueState) => void): Promise<UnlistenFn> =>
	listen<QueueState>('queue-changed', (e) => cb(e.payload));
/**
 * The queue moved but its track list did not: only the play pointer and the flags changed.
 * Emitted instead of `queue-changed` on every advance and skip, because the full item list is
 * megabytes on a big playlist and a Tauri event delivers its payload as JavaScript *source*.
 * `current` carries the playing row so a metadata backfill (duration, artists) still lands.
 */
export interface QueueIndex {
	currentIndex: number;
	shuffle?: boolean;
	repeat?: RepeatMode;
	sourceName?: string | null;
	sourceId?: string | null;
	prevTrack?: string | null;
	current: SongItem | null;
	autoplay?: boolean | null;
}

export const onQueueIndex = (cb: (q: QueueIndex) => void): Promise<UnlistenFn> =>
	listen<QueueIndex>('queue-index', (e) => cb(e.payload));
/**
 * Autoplay topped the queue up at the tail. Carries only the new rows plus the resulting length, so
 * an endless radio session does not re-ship the whole list (which a Tauri event delivers as
 * JavaScript *source*) every twenty tracks. `len` is the resync guard: if the array we hold does
 * not reach that length once the rows are appended, an event was missed and the panel refetches.
 */
export interface QueueAppended {
	items: SongItem[];
	len: number;
	currentIndex: number;
}

export const onQueueAppended = (cb: (q: QueueAppended) => void): Promise<UnlistenFn> =>
	listen<QueueAppended>('queue-appended', (e) => cb(e.payload));
/** Main window shown/hidden (close-to-tray, the mini player). WebKitGTK never tells the page. */
export const onUiVisible = (cb: (v: boolean) => void): Promise<UnlistenFn> =>
	listen<boolean>('ui-visible', (e) => cb(e.payload));
/** `limusic-app <link>` (#348): the arguments a cold launch was given, handed over once... */
export const takeLaunchArgs = () => invoke<string[]>('take_launch_args');
/** ...and those of a second launch while this one runs. */
export const onOpenLink = (cb: (args: string[]) => void): Promise<UnlistenFn> =>
	listen<string[]>('open-link', (e) => cb(e.payload));
export const onPosition = (cb: (p: number) => void): Promise<UnlistenFn> =>
	listen<{ position: number }>('position', (e) => cb(e.payload.position));
export const onDuration = (cb: (d: number) => void): Promise<UnlistenFn> =>
	listen<{ duration: number }>('duration', (e) => cb(e.payload.duration));
/** Echo of every `set_volume`, so a second window's slider can't drift from what you hear. */
export const onVolume = (cb: (v: number) => void): Promise<UnlistenFn> =>
	listen<number>('volume', (e) => cb(e.payload));
export const onPlaybackState = (cb: (s: 'playing' | 'paused') => void): Promise<UnlistenFn> =>
	listen<'playing' | 'paused'>('playback-state', (e) => cb(e.payload));
export const onPlaybackError = (cb: (msg: string) => void): Promise<UnlistenFn> =>
	listen<{ message: string }>('playback-error', (e) => cb(e.payload.message));
export const onPlaybackNotice = (cb: (msg: string) => void): Promise<UnlistenFn> =>
	listen<{ message: string }>('playback-notice', (e) => cb(e.payload.message));
/** Custom playlist artwork applied here but refused by YouTube Music (it syncs in the background,
 *  so the failure lands long after the picker closed). */
export const onCoverError = (cb: (msg: string) => void): Promise<UnlistenFn> =>
	listen<{ message: string }>('cover-error', (e) => cb(e.payload.message));
export const onImportProgress = (cb: (s: ImportSnapshot) => void): Promise<UnlistenFn> =>
	listen<ImportSnapshot>('import-progress', (e) => cb(e.payload));
export const onAuthChanged = (cb: (a: Account) => void): Promise<UnlistenFn> =>
	listen<Account>('auth-changed', (e) => cb(e.payload));
export const onAccountSelectionRequired = (cb: () => void): Promise<UnlistenFn> =>
	listen('account-selection-required', () => cb());
/** The YouTube session was rejected; the user must import a fresh browser session. */
export const onSessionRejected = (cb: () => void): Promise<UnlistenFn> =>
	listen('session-rejected', () => cb());
/**
 * Local music disappeared from disk. Fired when a play attempt finds nothing there, carrying the
 * song (and album, if that emptied it) so every view holding those ids can drop them at once.
 */
export const onLocalChanged = (cb: (removed: string[]) => void): Promise<UnlistenFn> =>
	listen<{ removed: string[] }>('local-changed', (e) => cb(e.payload.removed));
export const onLoginError = (cb: (msg: string) => void): Promise<UnlistenFn> =>
	listen<string>('login-error', (e) => cb(e.payload));
export const onLoginDone = (cb: () => void): Promise<UnlistenFn> =>
	listen('login-done', () => cb());
/** The user closed the host sign-in UI before signing in. */
export const onLoginCancelled = (cb: () => void): Promise<UnlistenFn> =>
	listen('login-cancelled', () => cb());

// --- lyrics ---------------------------------------------------------------------------------
export interface LyricWord {
	text: string;
	start_ms: number;
	end_ms: number;
	/** Background vocals. Only Limusic Lyrics sends it; drawn smaller. */
	bg?: boolean;
}
export interface LyricLine {
	/** Start cue in milliseconds; present ⇔ the line is synced. */
	time_ms?: number;
	end_time_ms?: number;
	text: string;
	words?: LyricWord[];
	translation?: string;
	/** Latin-script reading of `text` (#202). Word-timed only when Apple Music wrote it. */
	romanized?: string;
	romanized_words?: LyricWord[];
	/** Which singer: `v1`, `v2`, ... and `v1000` for everyone together. A second singer's lines
	 *  sit on the opposite side. */
	agent?: string;
}
export interface Lyrics {
	/** Attribution for the panel footer ("LRCLIB", "Source: Musixmatch", …). */
	source: string;
	/** Id of the provider that answered (`LyricsProvider.id`). */
	provider: string;
	synced: boolean;
	instrumental: boolean;
	lines: LyricLine[];
	/** The source was picked by hand for this song (or its timing nudged). */
	pinned: boolean;
	/** Timing nudge in ms, positive = lyrics later. */
	offset_ms: number;
	/** Limusic's revision of the lyric. Absent from every other source. */
	revision?: number;
	/** Who synced a community lyric on Limusic, oldest first. Absent everywhere else. */
	authors?: string[];
}
// A type, not an interface: `invoke` takes a record, and only a type alias is assignable to one.
export type LyricsTrack = {
	videoId: string;
	title: string;
	artists: string;
	album?: string;
	duration?: number;
	/** Title and artist typed in the source picker, not the song's own. */
	searched?: boolean;
};
/** Cached on the Rust side, down the user's provider order. `null` = none found. `source` asks that
 *  one provider alone and caches nothing (the source picker's preview); it rejects when the
 *  provider couldn't be reached, which is not the same as it having no lyrics. */
export const getLyrics = (args: LyricsTrack & { source?: string }) =>
	invoke<Lyrics | null>('get_lyrics', args);
/** Keep `source`'s lyrics for this song, or (`null`) hand it back to the provider order. */
export const chooseLyricsSource = (args: LyricsTrack & { source: string | null }) =>
	invoke<Lyrics | null>('choose_lyrics_source', args);
export const setLyricsOffset = (videoId: string, offsetMs: number) =>
	invoke<void>('set_lyrics_offset', { videoId, offsetMs });
/** A cached lyric was replaced behind the one on screen. The payload is the video id: ask again. */
export const onLyricsUpdated = (cb: (videoId: string) => void): Promise<UnlistenFn> =>
	listen<string>('lyrics-updated', (e) => cb(e.payload));
/** A pasted or picked lyric file (TTML, eLRC, LRC) as lines, by the parsers the providers use.
 *  Empty for plain text. Rejects with `too_large` over 1 MB. */
export const lyricsParse = (text: string) => invoke<LyricLine[]>('lyrics_parse', { text });
/** A position read from the player this instant and the wall-clock time (Unix ms) of the read:
 *  what the lyric editor places a tap with (`stampTap`). `null` with nothing loaded. */
export interface PlaybackClock {
	position: number;
	atMs: number;
	speed: number;
	paused: boolean;
}
export const playbackClock = () => invoke<PlaybackClock | null>('playback_clock');
export interface LyricsProvider {
	id: string;
	name: string;
	on: boolean;
}
/** Every provider in the user's order (setting `lyrics_providers`: ids, `-id` switched off). */
export const lyricsProviders = () => invoke<LyricsProvider[]>('lyrics_providers');

// --- Window ------------------------------------------------------------------------------------
/** Theater mode's fullscreen. Not `getCurrentWindow().setFullscreen` (#139): Windows needs the
 *  maximized state undone first and the frame recalculated after, in that order, on the main
 *  thread. Rust also puts the maximized state back when theater closes. */
export const theaterFullscreen = (on: boolean) => invoke<void>('theater_fullscreen', { on });
/** macOS "Double-click a window's title bar to": "Maximize"/"Fill" (zoom), "Minimize" or "None". */
export const titleBarDoubleClick = () => invoke<string>('title_bar_double_click');

// ── stream: smart ── (src-tauri/src/smart, docs/streams/smart.md) ─────────────────────────────

export interface SmartSettings {
	shuffle_mode: 'smart' | 'standard';
	explicit_filter: boolean;
	/** Owned by the library stream; read-only here. */
	private_session: boolean;
}
export const smartSettings = () => invoke<SmartSettings>('smart_settings');
/** `key`: `shuffle_mode` ("smart" | "standard") or `explicit_filter` ("true" | "false"). */
export const smartSetSetting = (key: 'shuffle_mode' | 'explicit_filter', value: string) =>
	invoke<void>('smart_set_setting', { key, value });

export interface ShelfItem {
	/** song | album | artist | playlist | liked | mix (startRadio('artist', id)) | radio
	 *  (startRadio('song', id)) | daily_mix (smartMix(id) then playPlaylist) | mood
	 *  (getBrowseGrid('FEmusic_moods_and_genres_category', params)) | podcast | episode |
	 *  podcast_category (podcastCategory(params)). */
	kind: string;
	id: string;
	title: string;
	subtitle?: string;
	thumbnail?: string;
	explicit: boolean;
	song?: SongItem;
	params?: string;
	color?: string;
	/** stream: magic-d4 — `episode` shortcut tiles: 0..1 into a started episode; a new unplayed one. */
	progress?: number;
	newEpisode?: boolean;
}
export interface Shelf {
	/** shortcuts | recently_played | top_mixes | made_for_you | more_like:<UC…> | jump_back_in |
	 *  new_releases | yt:<kind> | moods; offline: offline (a `notice`, no items) | downloaded */
	id: string;
	title: string;
	subtitle?: string;
	layout: 'shortcuts' | 'cards' | 'songs' | 'moods' | 'notice';
	source: 'local' | 'youtube' | 'apple';
	items: ShelfItem[];
}
export const smartHome = () => invoke<Shelf[]>('smart_home');
/** stream: magic-d4 — the local shelves only (shortcuts, recently played…), no network. */
export const smartHomeLocal = () => invoke<Shelf[]>('smart_home_local');
/** stream: home-tiles-pods — Home's Podcasts chip: your shows plus suggestions (smart::podhome). */
export const podcastHome = () => invoke<Shelf[]>('podcast_home');
/** A podcast category tile's page: Apple's top shows in that genre. */
export const podcastCategory = (genre: string) => invoke<ShelfItem[]>('podcast_category', { genre });
export const smartMix = (id: string, size?: number) =>
	invoke<SongItem[]>('smart_mix', { id, size });

export interface Recommendation {
	song: SongItem;
	votes: number;
	because: string[];
	/** `listening`: the playlist had nothing to seed from, so these come from what you play. */
	basis: 'playlist' | 'listening';
}
/** "Recommended" under a playlist; `refresh` = how many times Refresh was pressed. */
export const playlistRecommendations = (playlistId: string, n = 10, refresh = 0) =>
	invoke<Recommendation[]>('playlist_recommendations', { playlistId, n, refresh });

/** videoId → explicit, for dimming rows while the filter is on. `lookup` asks Deezer for unknowns. */
export const explicitFlags = (items: SongItem[], lookup = false) =>
	invoke<Record<string, boolean>>('explicit_flags', { items, lookup });
/** videoId → may play (false: hidden song, blocked artist, or explicit with the filter on). */
export const playableFlags = (items: SongItem[]) =>
	invoke<Record<string, boolean>>('playable_flags', { items });
export const tasteProfile = (limit = 20) =>
	invoke<{
		artists: { key: string; name: string | null; score: number }[];
		tracks: { videoId: string; score: number }[];
	}>('taste_profile', { limit });
// ── end stream: smart ──
// ── stream: library ──────────────────────────────────────────────────────────────────────────
// The local library (Rust `library.rs`): no account needed for any of it. The reactive wrapper is
// `library.svelte.ts`; these are the raw commands. Every mutation has an inverse, noted per line.

/** Liked Songs' id: the same as YouTube's Liked Music, served locally by `get_playlist`. */
export const LIKED_ID = 'VLLM';
export const MAX_PINS = 4;

export interface LikedEntry {
	song: SongItem;
	/** Unix seconds. */
	addedAt: number;
}

export type SavedKind = 'album' | 'playlist' | 'artist';

export interface SavedItem {
	id: string;
	kind: SavedKind;
	title: string;
	subtitle?: string | null;
	thumbnail?: string | null;
	/** The `BrowseItem` card as it was saved. */
	card: BrowseItem;
	/** Also on the signed-in YouTube account. */
	synced: boolean;
	addedAt: number;
}

export interface LibPlaylist {
	/** `LOCALPLAYLIST:<n>`: every playlist command and the /playlist route take it. */
	id: string;
	name: string;
	description: string;
	/** A cover file the user picked (`set_playlist_cover`). */
	cover?: string | null;
	/** First track's artwork, the fallback cover. */
	thumbnail?: string | null;
	count: number;
	createdAt: number;
	updatedAt: number;
	folderId?: string | null;
	pinned: boolean;
	lastPlayedAt?: number | null;
}

export interface PlaylistEntry {
	/** Row id; also the song's `set_video_id`. */
	rowId: number;
	/** 0-based position in the playlist when read/removed. */
	position: number;
	addedAt: number;
	song: SongItem;
}

export interface AddResult {
	added: PlaylistEntry[];
	/** Video ids skipped as already in the playlist (only when duplicates aren't allowed). */
	duplicates: string[];
}

export interface Folder {
	id: string;
	name: string;
	parentId?: string | null;
	position: number;
	createdAt: number;
	updatedAt: number;
	/** Item ids (playlists) directly inside, in order. */
	items: string[];
}

export interface Place {
	folderId?: string | null;
	index: number;
}

export interface FolderSnapshot {
	folder: Folder;
	childFolders: [string, number][];
	items: [string, number][];
}

export type PinKind = 'liked' | 'playlist' | 'album' | 'artist' | 'folder' | 'podcast';

export interface Pin {
	itemId: string;
	kind: PinKind;
	position: number;
}

export interface RecentContext {
	itemId: string;
	kind: string;
	card?: BrowseItem | null;
	playedAt: number;
}

export interface RecentTrack {
	song: SongItem;
	playedAt: number;
	plays: number;
}

export interface HiddenSong {
	videoId: string;
	/** null = hidden everywhere. */
	contextId?: string | null;
	song?: SongItem | null;
	hiddenAt: number;
}

export interface PrivateSession {
	enabled: boolean;
	since?: number | null;
	expiresAt?: number | null;
}

export interface LibrarySnapshot {
	likedIds: string[];
	playlists: LibPlaylist[];
	folders: Folder[];
	pins: Pin[];
	saved: SavedItem[];
	lastPlayed: Record<string, number>;
	/** stream: magic-d4 — item id → unix secs last added to / edited (a like, for Liked Songs).
	 *  Recents sorts by the later of this and `lastPlayed`. Absent from an older core. */
	lastTouched?: Record<string, number>;
	hiddenSongIds: string[];
	privateSession: PrivateSession;
	legacyMigrated: boolean;
}

export interface MigrationReport {
	already: boolean;
	saved: number;
	pins: number;
	recent: number;
}

export interface ExportReport {
	path: string;
	likedSongs: number;
	playlists: number;
	files: string[];
}

export type LibraryScope =
	| 'liked'
	| 'saved'
	| 'playlists'
	| 'folders'
	| 'pins'
	| 'played'
	| 'hidden'
	| 'private'
	| 'touched'
	| 'all';

export const libSnapshot = () => invoke<LibrarySnapshot>('lib_snapshot');
// likes. Inverse of like = unlike; of unlike = libRestoreLikes(returned entries).
export const libLikedIds = () => invoke<string[]>('lib_liked_ids');
export const libLikedSongs = () => invoke<LikedEntry[]>('lib_liked_songs');
export const libLike = (songs: SongItem[]) => invoke<boolean[]>('lib_like', { songs });
export const libUnlike = (videoIds: string[]) => invoke<LikedEntry[]>('lib_unlike', { videoIds });
export const libRestoreLikes = (entries: LikedEntry[]) =>
	invoke<void>('lib_restore_likes', { entries });
// saved albums / playlists / artists. Inverse of save = unsave; of unsave = libRestoreSaved(item).
export const libSaved = (kind?: SavedKind) => invoke<SavedItem[]>('lib_saved', { kind });
export const libSave = (card: BrowseItem, synced?: boolean) =>
	invoke<boolean>('lib_save', { card, synced });
export const libUnsave = (id: string) => invoke<SavedItem | null>('lib_unsave', { id });
export const libRestoreSaved = (item: SavedItem) => invoke<void>('lib_restore_saved', { item });
export const libMarkSynced = (ids: string[], synced = true) =>
	invoke<void>('lib_mark_synced', { ids, synced });
// playlists
export const libPlaylists = () => invoke<LibPlaylist[]>('lib_playlists');
/** Inverse: libPlaylistDelete. A blank name gets "My Playlist #N". */
export const libPlaylistCreate = (name?: string, description?: string, folderId?: string) =>
	invoke<LibPlaylist>('lib_playlist_create', { name, description, folderId });
/** Inverse: call again with the old name/description. */
export const libPlaylistUpdate = (id: string, name?: string, description?: string) =>
	invoke<LibPlaylist>('lib_playlist_update', { id, name, description });
/** Soft delete. Inverse: libPlaylistRestore (until the app restarts). */
export const libPlaylistDelete = (id: string) => invoke<void>('lib_playlist_delete', { id });
export const libPlaylistRestore = (id: string) => invoke<LibPlaylist>('lib_playlist_restore', { id });
export const libPlaylistEntries = (id: string) =>
	invoke<PlaylistEntry[]>('lib_playlist_entries', { id });
export const libPlaylistDuplicates = (id: string, videoIds: string[]) =>
	invoke<string[]>('lib_playlist_duplicates', { id, videoIds });
/** Inverse: libPlaylistRemove(result.added rowIds). `position` null = append. */
export const libPlaylistAdd = (
	id: string,
	songs: SongItem[],
	allowDuplicates = false,
	position?: number
) => invoke<AddResult>('lib_playlist_add', { id, songs, allowDuplicates, position });
/** Inverse: libPlaylistInsertEntries(id, returned entries). */
export const libPlaylistRemove = (id: string, rowIds: number[]) =>
	invoke<PlaylistEntry[]>('lib_playlist_remove', { id, rowIds });
export const libPlaylistInsertEntries = (id: string, entries: PlaylistEntry[]) =>
	invoke<void>('lib_playlist_insert_entries', { id, entries });
/** Answers the previous order. Inverse: libPlaylistSetOrder(id, previous). */
export const libPlaylistMove = (id: string, rowIds: number[], before?: number) =>
	invoke<number[]>('lib_playlist_move', { id, rowIds, before });
export const libPlaylistSetOrder = (id: string, rowIds: number[]) =>
	invoke<number[]>('lib_playlist_set_order', { id, rowIds });
// folders
export const libFolders = () => invoke<Folder[]>('lib_folders');
/** Inverse: libFolderDelete. */
export const libFolderCreate = (name?: string, parentId?: string) =>
	invoke<Folder>('lib_folder_create', { name, parentId });
/** Answers the old name (the inverse). */
export const libFolderRename = (id: string, name: string) =>
	invoke<string>('lib_folder_rename', { id, name });
/** Answers where it was. Inverse: move back there. Refuses cycles ('folder_cycle'). */
export const libFolderMove = (id: string, parentId?: string | null, index?: number) =>
	invoke<Place>('lib_folder_move', { id, parentId, index });
/** Contents move up to the parent. Inverse: libFolderRestore(snapshot). */
export const libFolderDelete = (id: string) => invoke<FolderSnapshot>('lib_folder_delete', { id });
export const libFolderRestore = (snapshot: FolderSnapshot) =>
	invoke<Folder>('lib_folder_restore', { snapshot });
/** Put an item in a folder (null = root). Answers where it was (null = root). */
export const libFolderSetItem = (itemId: string, folderId?: string | null, index?: number) =>
	invoke<Place | null>('lib_folder_set_item', { itemId, folderId, index });
// pins (max 4; 'pins_full' past that)
export const libPins = () => invoke<Pin[]>('lib_pins');
/** Inverse: libUnpin. Re-pinning moves it. */
export const libPin = (itemId: string, kind?: PinKind, index?: number) =>
	invoke<Pin[]>('lib_pin', { itemId, kind, index });
/** Answers the index it had. Inverse: libPin(itemId, kind, index). */
export const libUnpin = (itemId: string) => invoke<number | null>('lib_unpin', { itemId });
export const libPinsReorder = (itemIds: string[]) => invoke<Pin[]>('lib_pins_reorder', { itemIds });
// recents
export const libNotePlayed = (itemId: string, kind?: string, card?: BrowseItem) =>
	invoke<void>('lib_note_played', { itemId, kind, card });
export const libRecentContexts = (limit?: number) =>
	invoke<RecentContext[]>('lib_recent_contexts', { limit });
export const libRecentTracks = (limit?: number) =>
	invoke<RecentTrack[]>('lib_recent_tracks', { limit });
export const libLastPlayed = () => invoke<Record<string, number>>('lib_last_played');
// hidden songs (hidden artists: blockArtist / unblockArtist). Inverse of hide = unhide.
export const libHiddenSongs = (contextId?: string) =>
	invoke<HiddenSong[]>('lib_hidden_songs', { contextId });
export const libHideSong = (videoId: string, song?: SongItem, contextId?: string) =>
	invoke<boolean>('lib_hide_song', { videoId, song, contextId });
export const libUnhideSong = (videoId: string, contextId?: string) =>
	invoke<HiddenSong | null>('lib_unhide_song', { videoId, contextId });
// private session
export const libPrivateSession = () => invoke<PrivateSession>('lib_private_session');
export const libSetPrivateSession = (enabled: boolean) =>
	invoke<PrivateSession>('lib_set_private_session', { enabled });
// migration + export
export const libMigrateLegacy = (blob: unknown) =>
	invoke<MigrationReport>('lib_migrate_legacy', { blob });
/** Writes a zip (library.json + CSV/M3U8/XSPF). No path: ~/Downloads/Spotless Library <date>.zip. */
export const libExport = (path?: string) => invoke<ExportReport>('lib_export', { path });
export const onLibraryChanged = (cb: (scope: LibraryScope) => void): Promise<UnlistenFn> =>
	listen<{ scope: LibraryScope }>('library-changed', (e) => cb(e.payload.scope));
// ── stream: magic-d4 ──
/** `library-changed` with scope `touched`: an item was added to or edited (Recents moves it). */
export const onLibraryTouched = (cb: (itemId: string, at: number) => void): Promise<UnlistenFn> =>
	listen<{ scope: LibraryScope; itemId?: string; at?: number }>('library-changed', (e) => {
		const p = e.payload;
		if (p.scope === 'touched' && p.itemId) cb(p.itemId, p.at ?? Math.floor(Date.now() / 1000));
	});
/** A deleted playlist, recoverable until `purgeAt` (Settings › Recover playlists). */
export interface DeletedPlaylist {
	id: string;
	name: string;
	count: number;
	thumbnail?: string | null;
	deletedAt: number;
	purgeAt: number;
}
export const libDeletedPlaylists = () => invoke<DeletedPlaylist[]>('lib_deleted_playlists');
// ── end stream: magic-d4 ──
// ── end stream: library ──
// ── stream: podcasts ──────────────────────────────────────────────────────────────────────────
// Podcasts with no account: YouTube Music shows (`MPSP…` ids) and RSS feeds (id = feed URL), one
// model. Rust: `src-tauri/src/podcasts/`. State store: `podcasts.svelte.ts`. Docs:
// `docs/streams/podcasts.md`.
//
// Playing: build the queue row with `episodeSong(episode)` and use the normal player commands
// (`play`, `playPlaylist(rows, index)`, `playNext`, `addToQueue`). Don't pass a `sourceId` or a
// `continuation` for episodes: those are YouTube-playlist concepts. Resume, played state,
// SponsorBlock and "no music radio after an episode" all happen in Rust.

/** Where a show's page and episodes come from. */
export type ShowSource = 'youtube' | 'rss';
export type EpisodeSort = 'newest' | 'oldest';

export interface PodcastShow {
	/** `MPSP…` (YouTube Music) or the feed URL (RSS). */
	id: string;
	title: string;
	author: string;
	thumbnail?: string | null;
	/** Plain text. */
	description?: string | null;
	feedUrl?: string | null;
	ytBrowseId?: string | null;
	itunesId?: number | null;
	episodeCount?: number | null;
	source: ShowSource;
	followed: boolean;
	/** stream: search2 — the directory's author when YouTube's channel names someone else. */
	dirAuthor?: string;
}

/** Listening state; `fraction` drives the row's progress bar (1 once played). */
export interface EpisodeProgress {
	positionSecs: number;
	durationSecs: number;
	fraction: number;
	played: boolean;
	/** Unix seconds of the last save; 0 = never started. */
	updatedAt: number;
}

export interface PodcastEpisode {
	/** What the player plays: a YouTube videoId, or `PODURL:` + the enclosure URL. */
	id: string;
	showId?: string | null;
	showTitle: string;
	title: string;
	/** Unix seconds (day precision for YouTube rows). */
	publishedAt?: number | null;
	durationSecs?: number | null;
	/** Show notes: sanitised HTML, safe for `{@html}`. Timestamps are
	 *  `<a href="#t=SECS" data-seek="SECS">` — intercept clicks and seek. */
	description?: string | null;
	thumbnail?: string | null;
	videoId?: string | null;
	enclosureUrl?: string | null;
	guid?: string | null;
	isVideo: boolean;
	progress: EpisodeProgress;
	/** In "Your Episodes". */
	saved: boolean;
}

// ── stream: chapters ──
/** One chapter (core `podcasts::chapters::Chapter`). */
export interface PodcastChapter {
	startSecs: number;
	/** Next chapter's start or the episode's end; null when the length is unknown. */
	endSecs?: number | null;
	title: string;
	/** "1:02:05". */
	startLabel: string;
	/** "2min", "1hr 5min"; empty when the end is unknown. */
	durationLabel?: string;
	img?: string | null;
	url?: string | null;
}
export type ChapterSource = 'feed' | 'id3' | 'youtube' | 'description' | 'sponsorblock';
export interface PodcastChapters {
	source?: ChapterSource | null;
	chapters: PodcastChapter[];
	/** YouTube generated them (its automatic chapters), not the creator. */
	autoGenerated?: boolean;
}
// ── end stream: chapters ──

export interface PodcastShowPage {
	show: PodcastShow;
	episodes: PodcastEpisode[];
	/** Pass to `podcastShowMore` for the next page; null at the end. */
	continuation?: string | null;
	sort: EpisodeSort;
}

export interface PodcastEpisodePage {
	episodes: PodcastEpisode[];
	continuation?: string | null;
}

export interface PodcastSearchResults {
	shows: PodcastShow[];
	episodes: PodcastEpisode[];
}

export interface PodcastRefreshReport {
	checked: number;
	failed: number;
	/** Recent episodes found since the previous refresh, newest first. */
	newEpisodes: PodcastEpisode[];
}

export interface PodcastImportReport {
	found: number;
	added: number;
	alreadyFollowed: number;
}

export interface PodcastSettings {
	/** Auto-skip SponsorBlock segments in YouTube episodes (default on). */
	sponsorblock: boolean;
	/** Any of sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler. */
	sponsorblockCategories: string[];
	/** Two-letter store country for the iTunes directory. */
	country: string;
	/** Podcast Index keys are write-only; this says whether they are set. */
	podcastindex: boolean;
	podcastindexKey?: string | null;
	podcastindexSecret?: string | null;
}

/** `3725` → `"1:02:05"`. */
export const formatEpisodeDuration = (secs: number): string => {
	const h = Math.floor(secs / 3600);
	const m = Math.floor((secs % 3600) / 60);
	const s = Math.floor(secs % 60);
	const mm = h > 0 ? String(m).padStart(2, '0') : String(m);
	return `${h > 0 ? `${h}:` : ''}${mm}:${String(s).padStart(2, '0')}`;
};

/** The queue row for an episode: hand it to `play` / `playPlaylist` / `playNext` / `addToQueue`. */
export const episodeSong = (e: PodcastEpisode): SongItem & { is_episode: true } => ({
	video_id: e.id,
	title: e.title,
	artists: e.showTitle,
	duration: e.durationSecs ? formatEpisodeDuration(e.durationSecs) : undefined,
	thumbnail: e.thumbnail ?? undefined,
	is_episode: true
});

/** Search shows and/or episodes (YouTube Music + iTunes, + Podcast Index when keys are set),
 *  merged and deduplicated, YouTube first. Directory results are cached 24 h. */
export const podcastSearch = (query: string, scope?: 'shows' | 'episodes') =>
	invoke<PodcastSearchResults>('podcast_search', { query, scope });
/** A show page. `id`: `MPSP…` or a feed URL. */
export const podcastShow = (id: string, sort?: EpisodeSort) =>
	invoke<PodcastShowPage>('podcast_show', { id, sort });
export const podcastShowMore = (id: string, continuation: string, sort?: EpisodeSort) =>
	invoke<PodcastEpisodePage>('podcast_show_more', { id, continuation, sort });
/** One episode with full show notes (the episode page). */
export const podcastEpisode = (id: string) => invoke<PodcastEpisode>('podcast_episode', { id });
/** stream: chapters. Cached per episode in the core; never blocks playback. */
export const podcastChapters = (id: string, durationSecs?: number) =>
	invoke<PodcastChapters>('podcast_chapters', { id, durationSecs: durationSecs || null });
/** stream: video-pods. An episode's picture (`podcasts::video`): the YouTube video to show (the
 *  episode, or an RSS episode's YouTube twin) or a video enclosure's URL. Null when it has none, or
 *  on Data Saver / offline. `auto`: start on the video side (off with "audio only"). */
export type EpisodeVideo = { videoId?: string; url?: string; auto: boolean };
export const podcastEpisodeVideo = (id: string) =>
	invoke<EpisodeVideo | null>('podcast_episode_video', { id });
export const podcastFollow = (show: PodcastShow) => invoke<PodcastShow>('podcast_follow', { show });
export const podcastUnfollow = (id: string) => invoke<void>('podcast_unfollow', { id });
/** Followed shows, most recently followed first. */
export const podcastFollows = () => invoke<PodcastShow[]>('podcast_follows');
/** Follow a pasted RSS feed URL (errors on a bad URL / not a feed). */
export const podcastAddFeed = (url: string) => invoke<PodcastShow>('podcast_add_feed', { url });
/** Unplayed episodes of followed shows from the last `days` (default 30), newest first. */
export const podcastNewEpisodes = (limit?: number, days?: number) =>
	invoke<PodcastEpisode[]>('podcast_new_episodes', { limit, days });
/** Started, unfinished episodes, most recent first. */
export const podcastContinueListening = (limit?: number) =>
	invoke<PodcastEpisode[]>('podcast_continue_listening', { limit });
/** "Your Episodes". */
export const podcastSavedEpisodes = () => invoke<PodcastEpisode[]>('podcast_saved_episodes');
export const podcastSaveEpisode = (episode: PodcastEpisode, saved: boolean) =>
	invoke<void>('podcast_save_episode', { episode, saved });
/** Mark played / unplayed (unplayed also resets the position). */
export const podcastMarkPlayed = (id: string, played: boolean) =>
	invoke<EpisodeProgress>('podcast_mark_played', { id, played });
export const podcastMarkShowPlayed = (showId: string) =>
	invoke<number>('podcast_mark_show_played', { showId });
/** Progress for arbitrary episode ids (e.g. queue rows). Missing ids were never started. */
export const podcastProgress = (ids: string[]) =>
	invoke<Record<string, EpisodeProgress>>('podcast_progress', { ids });
/** Refresh every followed show now. The app also does this on launch and every 3 h. */
export const podcastRefresh = () => invoke<PodcastRefreshReport>('podcast_refresh');
/** OPML text of the follows (save it with the dialog plugin). */
export const podcastOpmlExport = () => invoke<string>('podcast_opml_export');
/** Follow every feed in an OPML document. */
export const podcastOpmlImport = (xml: string) =>
	invoke<PodcastImportReport>('podcast_opml_import', { xml });
export const podcastSettings = () => invoke<PodcastSettings>('podcast_settings');
/** Partial update; returns the new settings. */
export const podcastSetSettings = (settings: Partial<PodcastSettings>) =>
	invoke<PodcastSettings>('podcast_set_settings', { settings });

/** Position saved (every 5 s of playback, and on pause / track change). */
export const onPodcastProgress = (cb: (p: { id: string; progress: EpisodeProgress }) => void) =>
	listen<{ id: string; progress: EpisodeProgress }>('podcasts:progress', (e) => cb(e.payload));
/** The background refresh found new episodes. */
export const onPodcastNew = (cb: (r: PodcastRefreshReport) => void) =>
	listen<PodcastRefreshReport>('podcasts:new', (e) => cb(e.payload));
/** A SponsorBlock segment was skipped (for a "Skipped sponsor" toast). */
export const onPodcastSkipped = (
	cb: (s: { id: string; category: string; from: number; to: number }) => void
) =>
	listen<{ id: string; category: string; from: number; to: number }>('podcasts:skipped', (e) =>
		cb(e.payload)
	);
// ── end stream: podcasts ──────────────────────────────────────────────────────────────────────
// ── stream: audio ── equalizer, volume levelling, output device, crossfade, sleep timer
// (src-tauri/src/audio.rs). The reactive store over these is lib/audio.svelte.ts.

export type VolumeLevel = 'quiet' | 'normal' | 'loud';
export interface EqState {
	enabled: boolean;
	/** dB for 60, 150, 400, 1k, 2.4k, 15k Hz, each -12..12. */
	gains: number[];
	/** The preset these gains match, or null ("Custom"). */
	preset: string | null;
	/** The automatic pre-gain the player applies to stop boosts clipping (dB, <= 0). */
	preamp: number;
}
export interface EqInfo {
	bands: { kind: 'lowshelf' | 'peaking' | 'highshelf'; freq: number; q: number }[];
	presets: { name: string; gains: number[] }[];
	maxDb: number;
}
export interface AudioDevice {
	/** mpv's id; `auto` = the system default. */
	name: string;
	description: string;
}
export interface DevicesState {
	devices: AudioDevice[];
	/** What the user picked (`auto` = system default). */
	selected: string;
	/** What is playing now: `selected`, or `auto` while that device is unplugged. */
	active: string;
}
/** `at`: stops at `endsAt` (unix seconds). `endOfTrack`: when the playing track/episode ends. */
export type SleepMode = { kind: 'at'; endsAt: number } | { kind: 'endOfTrack' };
export interface SleepState {
	mode: SleepMode | null;
	/** Seconds left when this was sent (timed mode only). */
	remaining: number | null;
	/** The music fades out over this many seconds before stopping. */
	fadeSecs: number;
}
export interface AudioSettings {
	eq: EqState;
	normalize: boolean;
	level: VolumeLevel;
	/** 0 = off (gapless). */
	crossfadeSecs: number;
	device: string;
	sleep: SleepState;
}

export const audioSettings = () => invoke<AudioSettings>('audio_settings');
export const audioEqInfo = () => invoke<EqInfo>('audio_eq_info');
/** `commit: false` while dragging (live, not saved); `true` on release / preset / switch. */
export const setEq = (enabled: boolean, gains: number[], commit: boolean) =>
	invoke<EqState>('set_eq', { enabled, gains, commit });
export const setEqPreset = (name: string) => invoke<EqState>('set_eq_preset', { name });
export const setNormalizeVolume = (on: boolean) => invoke<void>('set_normalize_volume', { on });
export const setVolumeLevel = (level: VolumeLevel) => invoke<void>('set_volume_level', { level });
/** 0 (off) to 12 s; returns what was stored. */
export const setCrossfadeSecs = (secs: number) => invoke<number>('set_crossfade_secs', { secs });
export const audioDevices = () => invoke<DevicesState>('audio_devices');
export const setAudioDevice = (name: string) => invoke<DevicesState>('set_audio_device', { name });
export const setSleepTimer = (minutes: number | null, endOfTrack = false) =>
	invoke<SleepState>('set_sleep_timer', { minutes, endOfTrack });
export const cancelSleepTimer = () => invoke<SleepState>('cancel_sleep_timer');
export const sleepTimer = () => invoke<SleepState>('sleep_timer');
export const onAudioDevices = (cb: (d: DevicesState) => void): Promise<UnlistenFn> =>
	listen<DevicesState>('audio-devices', (e) => cb(e.payload));
export const onSleepTimer = (cb: (s: SleepState) => void): Promise<UnlistenFn> =>
	listen<SleepState>('sleep-timer', (e) => cb(e.payload));
// ── end stream: audio ──

// ── stream: polish ──
// Browse (charts, new releases, genre/mood pages), playback contexts, skip reasons, playback
// health and the podcast RSS→YouTube switch. See docs/streams/polish.md.

/** A card on an explore surface: a `BrowseItem`, plus podcast kinds (`podcast` = show `MPSP…`,
 *  `episode` = its videoId) that `get_browse_sections` / charts / search's Top result can carry. */
export type ExploreItem = Omit<BrowseItem, 'kind'> & {
	kind: BrowseItem['kind'] | 'podcast' | 'episode';
	isVideo?: boolean;
};
export interface ChartCountry {
	/** ISO 3166 alpha-2; `ZZ` = Global. */
	code: string;
	name: string;
}
export interface ChartEntry extends ExploreItem {
	/** Ranked shelves (top artists, top podcasts) only. */
	rank?: number;
	trend?: 'up' | 'down' | 'neutral' | 'new';
}
export interface ChartSection {
	kind: 'video_charts' | 'genres' | 'top_artists' | 'top_podcasts' | 'other';
	title: string;
	items: ChartEntry[];
}
export interface ChartsPage {
	country?: ChartCountry;
	/** Global first, then YouTube's order. */
	countries: ChartCountry[];
	/** The chart playlists Browse leads with (open as playlists). */
	highlights: { topSongs?: ExploreItem; topVideos?: ExploreItem; trending?: ExploreItem };
	sections: ChartSection[];
}
export interface ExploreSection {
	title: string;
	/** New releases: `albums` | `videos`. */
	kind?: string;
	items: ExploreItem[];
	/** "Show all": `getBrowseGrid(moreBrowseId, moreParams)`. */
	moreBrowseId?: string;
	moreParams?: string;
}
export interface NewReleasesPage {
	/** YouTube's "New Release Mix" playlist. */
	mix?: ExploreItem;
	sections: ExploreSection[];
}
export interface SectionsPage {
	title?: string;
	sections: ExploreSection[];
}
/** Charts for a country (`ZZ` = Global); omitted = the last picked one, else YouTube's guess. */
export const getCharts = (country?: string) => invoke<ChartsPage>('get_charts', { country });
export const getNewReleases = () => invoke<NewReleasesPage>('get_new_releases');
/** A genre/mood page as shelves: `getBrowseSections(MOODS_CATEGORY_ID, tile.params)`. */
export const getBrowseSections = (browseId: string, params?: string) =>
	invoke<SectionsPage>('get_browse_sections', { browseId, params });

/** What a queue was played from. Pass it to `playPlaylistFrom` so Recents and Home's shortcuts
 *  show playlists, albums, artists, Liked Songs, shows and mixes like Spotify. */
export interface PlayContext {
	kind: 'playlist' | 'album' | 'artist' | 'liked' | 'podcast' | 'radio' | 'mix' | 'daily_mix' | 'audiobook'; // audiobook: stream audiobooks
	id: string;
	title: string;
	subtitle?: string;
	thumbnail?: string;
	/** `radio` only: the seed kind when not a song (`startRadio(params ?? 'song', id, title)`). */
	params?: string;
}
/** `playPlaylist` plus the context card (a `BrowseItem` works as one). `startSecs` opens the
 *  start row that far in (a chapter tapped before its episode plays), in the same call. */
export const playPlaylistFrom = (
	items: SongItem[],
	start: number | null,
	context: PlayContext | (Omit<BrowseItem, 'kind'> & { kind: string }),
	sourceId?: string,
	shuffle?: boolean,
	continuation?: string,
	startSecs?: number
) =>
	invoke<void>('play_playlist', {
		items,
		start,
		sourceId,
		sourceName: context.title,
		shuffle,
		continuation,
		startSecs,
		context: {
			kind: context.kind,
			id: context.id,
			title: context.title,
			subtitle: context.subtitle,
			thumbnail: context.thumbnail
		}
	});
export interface RecentPlayContext extends PlayContext {
	plays: number;
	/** Unix seconds. */
	playedAt: number;
}
export const recentPlayContexts = (limit?: number) =>
	invoke<RecentPlayContext[]>('recent_play_contexts', { limit });

/** Why playback steps over a row. Grey these rows (Spotify greys explicit tracks when the
 *  filter is on, even ones added with Play next / Add to queue). `getQueue()` and the
 *  `queue-changed` event also carry this map as `skipReasons`. */
export type SkipReason = 'explicit' | 'unavailable' | 'offline'; // offline: stream downloads
export interface QueueState {
	/** videoId → why playback steps over that row. */
	skipReasons?: Record<string, SkipReason>;
}
export const playbackSkipReasons = (items: SongItem[]) =>
	invoke<Record<string, SkipReason>>('playback_skip_reasons', { items });

export interface PlaybackHealth {
	status: 'ok' | 'failed' | 'offline';
	ok: boolean;
	/** The client that produced the working stream. */
	client?: string;
	videoId: string;
	error?: string;
	elapsedMs: number;
	checkedAt: number;
}
/** Resolve a known video through the normal chain (nothing plays). ~1–5 s. */
export const playbackHealth = () => invoke<PlaybackHealth>('playback_health');
/** Fired once, ~20 s after launch, only when extraction is broken: show the
 *  "Playback is broken right now, an update may fix it" banner. */
export const onPlaybackHealth = (cb: (h: PlaybackHealth) => void): Promise<UnlistenFn> =>
	listen<PlaybackHealth>('playback-health', (e) => cb(e.payload));

/** RSS-only episodes play their ad-free YouTube twin when one is found (default on). */
export const podcastYoutubeMatch = () => invoke<boolean>('podcast_youtube_match');
export const podcastSetYoutubeMatch = (on: boolean) =>
	invoke<boolean>('podcast_set_youtube_match', { on });
/** The matched YouTube video for an RSS episode id, if any (no network). */
export const podcastYoutubeTwin = (id: string) =>
	invoke<string | null>('podcast_youtube_twin', { id });
// ── end stream: polish ──

// ── stream: p-settings ──
/** Bytes in the on-disk audio cache. */
export const cacheSize = () => invoke<number>('cache_size');
/** Reveal a file in Finder. */
export const revealInFinder = (path: string) => invoke<void>('reveal_in_finder', { path });
/** Write a user-picked `.opml`/`.xml` file. */
export const saveTextFile = (path: string, contents: string) =>
	invoke<void>('save_text_file', { path, contents });
// ── end stream: p-settings ──

// ── stream: downloads ──
/** What a download toggle covers. `kind`: playlist | album | liked | episode | song. */
export interface DownloadCollection {
	id: string;
	kind: 'playlist' | 'album' | 'liked' | 'episode' | 'song' | 'audiobook'; // audiobook: stream audiobooks
	title: string;
	subtitle?: string | null;
	thumbnail?: string | null;
}
export interface DownloadCollectionStatus extends DownloadCollection {
	total: number;
	done: number;
	failed: number;
	bytes: number;
	addedAt: number;
}
export interface DownloadProgress {
	videoId: string;
	done: number;
	/** 0 until the size is known. */
	total: number;
}
export interface DownloadNetwork {
	online: boolean;
	metered: boolean;
	/** Only downloaded content plays (offline mode, or no network). */
	offline: boolean;
	offlineMode: boolean;
	allowMetered: boolean;
	/** The queue is waiting (offline, metered, YouTube unreachable). */
	paused: boolean;
}
export interface DownloadsSummary {
	collections: DownloadCollectionStatus[];
	/** Downloaded tracks. */
	count: number;
	bytes: number;
	queued: number;
	failed: number;
}
export interface DownloadsSnapshot extends DownloadsSummary {
	/** Every downloaded videoId. */
	done: string[];
	active: DownloadProgress[];
	network: DownloadNetwork;
	dir: string;
	/** Thumbnail URL → local artwork file (shown while offline). */
	art: Record<string, string>;
	quality: 'HIGH' | 'LOW';
}
export interface DownloadsChanged extends DownloadsSummary {
	added: string[];
	removed: string[];
}
export const downloadsSnapshot = () => invoke<DownloadsSnapshot>('downloads_snapshot');
/** Playlists, albums and Liked Songs are read (and kept in sync) by the backend; pass `songs`
 *  for an episode or a single song. */
export const downloadsAdd = (collection: DownloadCollection, songs?: SongItem[]) =>
	invoke<void>('downloads_add', { collection, songs });
export const downloadsRemove = (id: string) => invoke<void>('downloads_remove', { id });
export const downloadsRemoveAll = () => invoke<void>('downloads_remove_all');
export const downloadsRetry = () => invoke<void>('downloads_retry');
export const downloadsSync = () => invoke<void>('downloads_sync');
export const downloadsSetSettings = (patch: {
	offlineMode?: boolean;
	allowMetered?: boolean;
	quality?: 'HIGH' | 'LOW';
}) => invoke<DownloadsSnapshot>('downloads_set_settings', { patch });
export const downloadsSetDir = (path: string) =>
	invoke<DownloadsSnapshot>('downloads_set_dir', { path });
export const downloadsSongs = () => invoke<SongItem[]>('downloads_songs');
export const onDownloadsChanged = (cb: (s: DownloadsChanged) => void): Promise<UnlistenFn> =>
	listen<DownloadsChanged>('downloads:changed', (e) => cb(e.payload));
export const onDownloadsProgress = (cb: (p: DownloadProgress[]) => void): Promise<UnlistenFn> =>
	listen<DownloadProgress[]>('downloads:progress', (e) => cb(e.payload));
export const onDownloadsNetwork = (cb: (n: DownloadNetwork) => void): Promise<UnlistenFn> =>
	listen<DownloadNetwork>('downloads:network', (e) => cb(e.payload));
// ── end stream: downloads ──

// ── stream: smart2 ── Made for you, What's New, Smart Shuffle (docs/streams/smart2.md).
export type MfyKind = 'daily' | 'discover_weekly' | 'release_radar' | 'repeat_rewind' | 'on_repeat';
/** A Made for you playlist card. Open it with `playlistHref(id)`; `getPlaylist(id)` serves it. */
export interface MfyCard {
	id: string;
	kind: MfyKind;
	title: string;
	description: string;
	/** The generated cover (a local SVG path; `thumb()` converts it). */
	thumbnail?: string | null;
	trackCount: number;
	generatedAt: number;
	nextRefresh: number;
}
/** Your Mix 1–6, Weekly Discoveries, New Release Mix, Your Rotation, Throwback Mix (Spotify's order).
 *  `refresh` rebuilds them all now. */
export const madeForYou = (refresh?: boolean) => invoke<MfyCard[]>('made_for_you', { refresh });
/** Fired after a scheduled or import-triggered rebuild. */
export const onMadeForYouChanged = (cb: () => void): Promise<UnlistenFn> =>
	listen('made-for-you-changed', () => cb());
// ── stream: perf ── YouTube's home answered after Home stopped waiting for it (smart/home.rs).
// stream: magic-d4 — `played`: a context was just started (`context` is its card); Home moves it to
// the first shortcut at once. `youtube`: late YouTube shelves. Older cores send no payload.
export interface HomeChange {
	reason?: 'played' | 'youtube' | 'podcasts';
	context?: { kind: string; id: string; title: string; subtitle?: string; thumbnail?: string; params?: string };
}
export const onHomeChanged = (cb: (change: HomeChange) => void): Promise<UnlistenFn> =>
	listen<HomeChange | null>('home-changed', (e) => cb(e.payload ?? {}));
// ── end stream: perf ──
/** Made for you playlist ids (Your Rotation keeps Limusic's id). */
export const isMadeForYou = (id: string) => id.startsWith('MFY_') || id === ON_REPEAT_ID;

export interface WhatsNewRelease {
	id: string;
	title: string;
	subtitle?: string | null;
	thumbnail?: string | null;
	artist: string;
	artistId: string;
	year: number;
	/** Unix secs when first seen; 0 = already out at the first scan. */
	firstSeen: number;
	followed: boolean;
	ytNew: boolean;
	position: number;
	/** "Single" | "EP" | "Album". */
	releaseType: string;
	isNew: boolean;
}
export type WhatsNewEpisode = PodcastEpisode & { isNew: boolean };
export interface WhatsNew {
	music: WhatsNewRelease[];
	podcasts: WhatsNewEpisode[];
	seenAt: number;
	newCount: number;
}
export const whatsNew = (refresh?: boolean) => invoke<WhatsNew>('whats_new', { refresh });
/** The bell's "New" dot: items since the page was last opened. */
export const whatsNewCount = () => invoke<number>('whats_new_count');
export const whatsNewMarkSeen = () => invoke<void>('whats_new_mark_seen');
export const onWhatsNewChanged = (cb: (newCount: number) => void): Promise<UnlistenFn> =>
	listen<{ newCount: number }>('whats-new-changed', (e) => cb(e.payload.newCount));

export interface SmartShuffleState {
	on: boolean;
	sourceId?: string | null;
	/** Suggested rows in the queue (sparkle rows). */
	recIds: string[];
}
export const smartShuffleState = () => invoke<SmartShuffleState>('smart_shuffle_state');
/** On: shuffle + a suggestion after every 3 songs (own playlists / Liked Songs). Off: suggestions
 *  out and shuffle off. Rejects outside an own playlist. */
export const smartShuffleSet = (on: boolean) => invoke<SmartShuffleState>('smart_shuffle_set', { on });
export const smartShuffleRemove = (videoId: string) =>
	invoke<SmartShuffleState>('smart_shuffle_remove', { videoId });
export const smartShuffleKeep = (videoId: string) =>
	invoke<SmartShuffleState>('smart_shuffle_keep', { videoId });
export const onSmartShuffleChanged = (cb: (s: SmartShuffleState) => void): Promise<UnlistenFn> =>
	listen<SmartShuffleState>('smart-shuffle-changed', (e) => cb(e.payload));
// ── end stream: smart2 ──
// ── stream: parity3 ──
/** The Mac user's first name ("Made for <name>"), or null. Local only. */
export const localUserName = () => invoke<string | null>('local_user_name');
// ── end stream: parity3 ──
// ── stream: podtop ──
/** Which of `shows` (from `podcastSearch`) should be the search page's Top result instead of
 *  YouTube Music's card, like Spotify ("joe rogan", "the daily"): `top` = `searchAll`'s
 *  `top[0]`, `artist` = its `artists[0]`. `null` keeps YouTube's. Pure, local. */
export const podcastTopShow = (
	query: string,
	top: BrowseItem | ExploreItem | null,
	artist: BrowseItem | null,
	shows: PodcastShow[]
) => invoke<number | null>('podcast_top_show', { query, top, artist, shows });
/** An artist query's Songs list with the artist page's "Top songs" order blended in (recent
 *  hits; Borda over the two ranks). `songs` = `search`'s answer, `artist`/`top` = the page's
 *  `name`/`topSongs`. Unchanged when the query doesn't ask for that artist. Pure, local. */
export const searchBlendArtistTop = (query: string, songs: SongItem[], artist: string, top: SongItem[]) =>
	invoke<SongItem[]>('search_blend_artist_top', { query, songs, artist, top });
// ── end stream: podtop ──

// ── stream: search2 ──────────────────────────────────────────────────────────────────────────
// The All view in one call and every chip as an endless list (Rust: crates/core/src/search.rs).

/** Why the results answer something other than what was typed. */
export interface SearchCorrection {
	kind: 'spelling' | 'completion' | 'relaxed' | 'library' | 'offline';
	/** What the results answer. */
	query: string;
	/** What was typed. */
	original: string;
}
/** The last-resort shelf ("Try these"), never an error. */
export interface SearchTryThese {
	songs: SongItem[];
	artists: BrowseItem[];
}
export interface SearchOverview {
	/** The query the results answer; pass it to `searchPage` for the Songs chip's next pages. */
	query: string;
	correction?: SearchCorrection;
	results: SearchResults;
	songs: SongItem[];
	songsContinuation?: string;
	shows: PodcastShow[];
	episodes: PodcastEpisode[];
	/** The directories were still answering: ask `podcastSearch` yourself. */
	podsPending: boolean;
	/** Index into `shows` of the show that is the Top result. */
	topShow?: number;
	/** Podcasts and Episodes shelves go right under the top rows. */
	podcastsFirst: boolean;
	tryThese?: SearchTryThese;
	/** stream: search-dropdown — the top bar's dropdown: ~30 mixed rows in Spotify's order
	 *  (`search::dropdown_order`). */
	dropdown: SearchDropRow[];
}
export type SearchDropRow =
	| { type: 'card'; item: BrowseItem }
	| { type: 'song'; song: SongItem }
	| { type: 'show'; show: PodcastShow };
export type SearchChip = 'songs' | 'videos' | 'artists' | 'albums' | 'playlists' | 'profiles' | 'podcasts' | 'episodes';
export interface SearchPage {
	filter: SearchChip;
	/** The query the rows answer; send it back with `continuation`. */
	query: string;
	songs: SongItem[];
	items: BrowseItem[];
	shows: PodcastShow[];
	episodes: PodcastEpisode[];
	continuation?: string;
	correction?: SearchCorrection;
	tryThese?: SearchTryThese;
}
export const searchOverview = (query: string, recordHistory = false) =>
	invoke<SearchOverview>('search_overview', { query, recordHistory });
export const searchPage = (query: string, filter: SearchChip, continuation?: string) =>
	invoke<SearchPage>('search_page', { query, filter, continuation });
/** A song whose words match the query (lyricsearch). */
export interface LyricMatch {
	song: SongItem;
	score: number;
}
export interface LyricBlend {
	songs: SongItem[];
	/** `songs[0]` is a lyric match that becomes the Top result. */
	leadTop: boolean;
	added: string[];
}
/** Empty at once unless the query reads like lyrics; at most 1.2 s otherwise. Never awaited first. */
export const searchLyrics = (query: string) => invoke<LyricMatch[]>('search_lyrics', { query });
/** `topTitle`: the page's Top result when it is not a song (album, artist, playlist). */
export const searchBlendLyrics = (query: string, songs: SongItem[], lyric: LyricMatch[], interacted: boolean, topTitle?: string) =>
	invoke<LyricBlend>('search_blend_lyrics', { query, songs, lyric, interacted, topTitle });
// ── end stream: search2 ──

// ── device sync (docs/SYNC.md) ──
// Commands and the `sync-changed` event. Screens: devices.ts (words, rules), devices.svelte.ts, settings/devices/.
export type SyncPeer = { id: string; name: string; platform: string; lastSeen: number; lan: boolean };
export type SyncPairing = { code: string; qr: string; expiresAt: number };
export type SyncStatus = {
	paired: boolean;
	deviceId: string;
	deviceName: string;
	platform: string;
	pairId: string | null;
	peers: SyncPeer[];
	/** This device's changes not yet delivered to any peer. */
	pending: number;
	lastSync: number | null;
	lastError: string | null;
	relay: { enabled: boolean; ok: boolean | null };
	lanPort: number | null;
	pairing: SyncPairing | null;
	syncing: boolean;
	active: boolean;
};
export const syncStatus = () => invoke<SyncStatus>('sync_status');
/** Show a code on this device: `{ code, qr, expiresAt, port, addrs }`. */
export const syncStartPairing = () =>
	invoke<SyncPairing & { port: number; addrs: string[] }>('sync_start_pairing');
export const syncCancelPairing = () => invoke<SyncStatus>('sync_cancel_pairing');
/** Join with the code (and the QR payload, or a host/port from Bonjour; with neither the Mac looks on the LAN). */
export const syncJoin = (code: string | null, qr?: string, host?: string, port?: number) =>
	invoke<SyncStatus>('sync_join', { code, qr, host, port });
export const syncUnpair = () => invoke<SyncStatus>('sync_unpair');
export const syncNow = () => invoke<SyncStatus>('sync_now');
/** The window gained or lost focus: polls speed up or slow down. */
export const syncSetActive = (active: boolean) => invoke<SyncStatus>('sync_set_active', { active });
export const onSyncChanged = (
	cb: (p: { status: SyncStatus; entities: string[] }) => void
): Promise<UnlistenFn> =>
	listen<{ status: SyncStatus; entities: string[] }>('sync-changed', (e) => cb(e.payload));
