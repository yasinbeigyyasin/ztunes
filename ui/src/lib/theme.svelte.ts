// Ztunes accent preferences are local to this device. The default is red.
export const ACCENTS = {
  red:    { label: 'Red',    base: '#ff4b4b', hover: '#ff6969', press: '#df3636', text: '#ff7171', tile: '#511719' },
  blue:   { label: 'Blue',   base: '#63b5ff', hover: '#84c5ff', press: '#4297e8', text: '#86c5ff', tile: '#173450' },
  green:  { label: 'Green',  base: '#55d999', hover: '#75e5ad', press: '#35bd7d', text: '#7ce8ae', tile: '#123e2c' },
  amber:  { label: 'Amber',  base: '#ffbf47', hover: '#ffd06d', press: '#dd9c29', text: '#ffd06d', tile: '#49300b' },
  violet: { label: 'Violet', base: '#c29aff', hover: '#d2b6ff', press: '#a37ce0', text: '#d6beff', tile: '#34234d' }
} as const;
export type AccentName = keyof typeof ACCENTS;
export const accentState = $state<{ name: AccentName }>({ name: 'red' });
const ACCENT_KEY = 'ztunes.accent';
function applyAccent(name: AccentName) {
  const p = ACCENTS[name];
  const style = document.documentElement.style;
  style.setProperty('--color-accent', p.base);
  style.setProperty('--color-accent-hover', p.hover);
  style.setProperty('--color-accent-press', p.press);
  style.setProperty('--color-accent-text', p.text);
  style.setProperty('--color-accent-tile', p.tile);
}
export function setAccent(name: AccentName) {
  if (!(name in ACCENTS)) return;
  accentState.name = name;
  if (typeof document !== 'undefined') applyAccent(name);
  try { localStorage.setItem(ACCENT_KEY, name); } catch { /* unavailable storage: keep session state */ }
}
function initAccent() {
  let name: AccentName = 'red';
  try {
    const saved = localStorage.getItem(ACCENT_KEY);
    if (saved && Object.prototype.hasOwnProperty.call(ACCENTS, saved)) name = saved as AccentName;
  } catch { /* keep the default */ }
  accentState.name = name;
  applyAccent(name);
}

// UI preferences that are not colours. Spotless has exactly one look (the Spotify-dark token set in
// routes/layout.css), so the old theme presets, custom accent/font layer, Matugen seed and the
// "adapt colours to artwork" document tint are gone. What stays is `appearance`: a handful of
// behaviour toggles the kept leaf components read (lyrics animation, now-playing options).
// Artwork-derived *header* colours live in `artcolor.ts` / `kit/tint.svelte.ts`.

const APPEARANCE_KEY = 'appearance';

/** Enhanced lyrics' tuning (#591), what each reset icon in its settings card puts back. */
export const LYRICS_DEFAULTS = {
	enhancedLyricsLineSync: false,
	lyricsAnim: 'bounce' as LyricsAnim,
	lyricsStyle: 'feather' as LyricsStyle,
	lyricsAnimStrength: 100,
	lyricsGlow: 50
};

/**
 * Looks the UI reads directly rather than through a CSS token. Same store and same reasoning as
 * the theme above (a pure UI preference, no backend round-trip), which also means a component can
 * read it during its first render instead of flashing the default while a command round-trips.
 */
export const appearance = $state({
	/** Ztunes: reduce interface animation and use narrower content margins. */
	reducedMotion: false,
	compactLayout: false,
	/** Blur the playing track's artwork behind the now-playing view. */
	artworkBackground: true,
	/** Blur the cover behind a playlist's header. Sharp, a square cover stretched to the page's
	 *  width is often too small for it and shows its pixels (#461). */
	blurPlaylistHeader: false,
	/** The "Now playing" pill a list floats over its rows while the playing one is off screen, in
	 *  the queue and on a playlist (#366). Off for whoever finds it in the way. */
	nowPlayingPill: true,
	/** The original now-playing view, before the redesign (title and album under the picture, a
	 *  lit backdrop, a full-height queue/lyrics column) became the default. A new key rather than
	 *  `stagePlayer` flipped: that one was saved as `false` for everyone, so a new default would
	 *  never have reached them. */
	classicPlayer: false,
	/**
	 * The now-playing view carries queue and lyrics itself, as tabs, and the player bar's two
	 * buttons switch between them while it's open. Off, those buttons only ever open the floating
	 * side panels, which then sit over the now-playing view like they sit over a page (#62).
	 */
	tabbedPlayer: true,
	/** Starting playback opens the now-playing view. Off, it plays and leaves you where you are (#64). */
	openPlayerOnPlay: true,
	/** A click on empty player-bar space toggles the now-playing view, and one around the artwork
	 *  closes it (#302). Off, only the buttons and shortcuts do, for whoever trips it by accident. */
	emptyClickTogglesPlayer: true,
	/** Take the accent colour from the playing track's cover, crossfading on each change. */
	artworkAccent: false,
	/** Theater mode's second and third columns (#297). Sticky, like every view toggle. */
	theaterLyrics: true,
	theaterQueue: false,
	/** Theater mode: a small clock in a top corner, for a screen that hides the system clock. */
	theaterClock: false,
	theaterClockSide: 'right' as 'left' | 'right',
	theaterClockFormat: 'auto' as 'auto' | '12' | '24',
	enhancedLyrics: false,
	...LYRICS_DEFAULTS
});

export type LyricsAnim = 'bounce' | 'float' | 'wave' | 'pop' | 'slide' | 'none';
export type LyricsStyle = 'feather' | 'accent' | 'crisp' | 'word';
export const LYRICS_ANIMS: LyricsAnim[] = ['bounce', 'float', 'wave', 'pop', 'slide', 'none'];
export const LYRICS_STYLES: LyricsStyle[] = ['feather', 'accent', 'crisp', 'word'];

function applyAppearance(): void {
    if (typeof document !== 'undefined')
        document.documentElement.dataset.reduceMotion = String(appearance.reducedMotion);
}
export function setAppearance(patch: Partial<typeof appearance>): void {
    Object.assign(appearance, patch);
    applyAppearance();
    try { localStorage.setItem(APPEARANCE_KEY, JSON.stringify(appearance)); } catch { /* session only */ }
}

/** Kept for win.svelte.ts: the window reports when it is hidden to the tray. Nothing restyles any
 *  more, so there is nothing to defer; the flag is exposed for anything that wants to pause work. */
export const uiState = $state({ visible: true });
export function setUiVisible(visible: boolean): void {
	uiState.visible = visible;
}

/** Load the stored appearance preferences on startup. */
export function initTheme(): void {
	initAccent();
	try {
		const saved = JSON.parse(localStorage.getItem(APPEARANCE_KEY) ?? '{}');

		for (const k of [
            'reducedMotion',
            'compactLayout',
			'artworkBackground',
			'blurPlaylistHeader',
			'nowPlayingPill',
			'classicPlayer',
			'tabbedPlayer',
			'openPlayerOnPlay',
			'emptyClickTogglesPlayer',
			'artworkAccent',
			'theaterLyrics',
			'theaterQueue',
			'theaterClock',
			'enhancedLyrics',
			'enhancedLyricsLineSync'
		] as const) {
			if (typeof saved?.[k] === 'boolean') appearance[k] = saved[k];
		}
		// Not booleans, so they are not in the list above: one value each, checked on its own.
		if (saved?.theaterClockSide === 'left' || saved?.theaterClockSide === 'right')
			appearance.theaterClockSide = saved.theaterClockSide;
		if (['auto', '12', '24'].includes(saved?.theaterClockFormat))
			appearance.theaterClockFormat = saved.theaterClockFormat;
		if (LYRICS_ANIMS.includes(saved?.lyricsAnim)) appearance.lyricsAnim = saved.lyricsAnim;
		if (LYRICS_STYLES.includes(saved?.lyricsStyle)) appearance.lyricsStyle = saved.lyricsStyle;
		if (typeof saved?.lyricsAnimStrength === 'number') {
			appearance.lyricsAnimStrength = Math.min(200, Math.max(25, saved.lyricsAnimStrength));
		}
		if (typeof saved?.lyricsGlow === 'number') {
			appearance.lyricsGlow = Math.min(100, Math.max(0, saved.lyricsGlow));
		}
	} catch {
		// unparseable — keep the defaults
	} finally {
        applyAppearance();
    }
}
