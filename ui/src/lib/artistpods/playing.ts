import { playback } from '$lib/player.svelte';
import * as api from '$lib/api';

/** The queue was started from one of `ids` (an artist id, its top-songs playlist…). */
export const isContext = (...ids: (string | null | undefined)[]): boolean =>
	!!playback.now && ids.some((id) => !!id && playback.queue.sourceId === id);

/** This context is the one playing right now (pause glyph on its play buttons). */
export const isPlayingContext = (...ids: (string | null | undefined)[]): boolean =>
	isContext(...ids) && !playback.paused;

/** Accent play button: pause/resume when it's this context, else start it. */
export function playOrToggle(ids: (string | null | undefined)[], start: () => unknown) {
	if (isContext(...ids)) return api.togglePause();
	return start();
}

/** Spotify's Liked Songs cover (purple → mint, white heart) as an image URL, for card grids. */
export const LIKED_COVER =
	'data:image/svg+xml;utf8,' +
	encodeURIComponent(
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff4b4b"/><stop offset="1" stop-color="#6a1b9a"/></linearGradient></defs><rect width="300" height="300" fill="url(#g)"/><path transform="translate(102 108) scale(4)" fill="#fff" d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>`
	);
