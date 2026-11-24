// Play / open helpers for the discover pages (Home, Search, Browse, genre/chart pages).
// Every "play this whole thing" goes through `api.playPlaylistFrom(..., context)` so Recents and
// Home's shortcuts learn the context (polish.md). The playing check compares the live queue with
// what we started for a card: a mix has no YouTube source id, so its title identifies it.
import { goto } from '$app/navigation';
import * as api from '$lib/api';
import type {
	BrowseItem,
	ExploreItem,
	PlayContext,
	PodcastEpisode,
	ShelfItem,
	SongItem
} from '$lib/api';
import { episodeSong } from '$lib/api';
import { playback, playSong } from '$lib/player.svelte';
import { lib } from '$lib/library.svelte';
import { artistPage, asSong } from '$lib/browse';
import { toast } from '$lib/kit/toast';
import { logUi } from '$lib/errlog';
import { rawError } from '$lib/neterr';
import { albumHref, artistHref, playlistHref, showHref } from '$lib/kit/actions';
import { bookHref, genreHref, playBookById } from '$lib/audiobooks.svelte'; // stream: audiobooks

type Started = { sourceId?: string; sourceName?: string };
/** card key → what the queue looked like when we started it. */
const started = $state<Record<string, Started>>({});

/** Is the queue currently the context this card started (or the same YouTube list)? */
export function isCurrent(key: string, title?: string): boolean {
	if (!playback.now) return false;
	const q = playback.queue;
	if (q.sourceId && (q.sourceId === key || q.sourceId === `VL${key}` || `VL${q.sourceId}` === key)) return true;
	const s = started[key];
	// Started elsewhere (an album page plays its OLAK… list): the queue's name is the context's.
	if (!s) return !!title && q.sourceName === title;
	if (s.sourceId) return q.sourceId === s.sourceId;
	return !q.sourceId && !!s.sourceName && q.sourceName === s.sourceName;
}
/** Playing (not paused) — drives the pause glyph on cards. */
export const isPlaying = (key: string, title?: string) => isCurrent(key, title) && !playback.paused;

/** Click on a card's play button: pause/resume when it's already the queue, else start it. */
export async function toggle(key: string, start: () => Promise<void> | void, title?: string) {
	if (isCurrent(key, title)) {
		await api.togglePause().catch(() => {});
		return;
	}
	await start();
}

const CONTEXT_KINDS = new Set(['album', 'playlist', 'artist']);

/** A card's play failed: the real error to the log (WARN) and on the toast. */
export function playFailed(e: unknown, what: { kind: string; id: string }) {
	logUi('warn', `play ${what.kind} ${what.id} failed: ${rawError(e)}`);
	toast.fail(e, "Couldn't play this", { detail: true });
}

/** Play `songs` as a context (Recents + Home learn it). */
export async function playContext(
	key: string,
	ctx: PlayContext,
	songs: SongItem[],
	opts: { start?: number | null; sourceId?: string; shuffle?: boolean; continuation?: string } = {}
) {
	if (!songs.length) {
		logUi('warn', `play ${ctx.kind} ${ctx.id}: nothing to play`);
		toast.error('There’s nothing to play here.');
		return;
	}
	if (CONTEXT_KINDS.has(ctx.kind))
		lib.notePlayed({
			kind: ctx.kind as BrowseItem['kind'],
			id: ctx.id,
			title: ctx.title,
			subtitle: ctx.subtitle,
			thumbnail: ctx.thumbnail
		});
	started[key] = { sourceId: opts.sourceId, sourceName: ctx.title };
	await api.playPlaylistFrom(
		songs,
		opts.start ?? null,
		ctx,
		opts.sourceId,
		opts.shuffle,
		opts.continuation
	);
}

/** Play a whole browse/explore item without opening it. Never throws. */
export async function playBrowse(item: BrowseItem | ExploreItem, shuffle = false): Promise<void> {
	try {
		const ctx = { kind: item.kind, id: item.id, title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail };
		switch (item.kind) {
			case 'song':
				playSong(asSong(item as BrowseItem));
				return;
			case 'album': {
				const a = await api.getAlbum(item.id);
				await playContext(item.id, ctx as PlayContext, a.items, {
					sourceId: a.playlistId ?? undefined,
					shuffle,
					continuation: a.continuation
				});
				return;
			}
			case 'playlist': {
				const p = await api.getPlaylist(item.id);
				await playContext(item.id, ctx as PlayContext, p.items, {
					sourceId: item.id === api.ON_REPEAT_ID ? undefined : item.id,
					shuffle,
					continuation: p.continuation
				});
				return;
			}
			case 'artist': {
				const page = await artistPage(item.id);
				await playContext(item.id, ctx as PlayContext, page?.topSongs ?? [], {
					sourceId: page?.topSongsId,
					shuffle
				});
				return;
			}
			case 'podcast': {
				const s = await api.podcastShow(item.id);
				const eps = s.episodes.filter((e) => !e.progress.played);
				await playEpisodes(item.id, s.show.title, (eps.length ? eps : s.episodes).slice(0, 1), s.show.thumbnail);
				return;
			}
			case 'episode': {
				// The show is the context, as for an episode on Home.
				const e = await api.podcastEpisode(item.id);
				started[item.id] = { sourceName: e.showTitle };
				await api.playPlaylistFrom([episodeSong(e)], 0, {
					kind: 'podcast',
					id: e.showId ?? `ep:${e.id}`,
					title: e.showTitle,
					thumbnail: e.thumbnail ?? undefined
				});
				return;
			}
			default:
				openExplore(item);
		}
	} catch (e) {
		playFailed(e, item);
	}
}

/** Play podcast episodes (no source id: that's a YouTube-playlist concept). */
export async function playEpisodes(
	key: string,
	title: string,
	eps: PodcastEpisode[],
	thumbnail?: string | null,
	start = 0
) {
	started[key] = { sourceName: title };
	await api.playPlaylistFrom(eps.map(episodeSong), start, {
		kind: 'podcast',
		id: key,
		title,
		thumbnail: thumbnail ?? undefined
	});
}

/** Where an explore/browse item lives. */
export function exploreHref(item: Pick<ExploreItem, 'kind' | 'id'>): string | undefined {
	switch (item.kind) {
		case 'album':
			return albumHref(item.id);
		case 'artist':
			return artistHref(item.id);
		case 'playlist':
			return playlistHref(item.id);
		case 'podcast':
			return showHref(item.id);
		case 'episode':
			return `/episode/${encodeURIComponent(item.id)}`;
		default:
			return undefined;
	}
}

export function openExplore(item: BrowseItem | ExploreItem) {
	if (item.kind === 'song') {
		playSong(asSong(item as BrowseItem));
		return;
	}
	const href = exploreHref(item);
	if (href) goto(href);
}

// ── smartHome shelf items ───────────────────────────────────────────────────────────────────

export const mixHref = (item: ShelfItem) =>
	`/mix/${encodeURIComponent(item.id)}?title=${encodeURIComponent(item.title)}${
		item.subtitle ? `&subtitle=${encodeURIComponent(item.subtitle)}` : ''
	}${item.thumbnail ? `&thumb=${encodeURIComponent(item.thumbnail)}` : ''}`;

export const moodHref = (title: string, params: string, color?: string) =>
	`/genre/${encodeURIComponent(params)}?title=${encodeURIComponent(title)}${
		color ? `&color=${encodeURIComponent(color)}` : ''
	}`;

/** What clicking a shelf item opens (undefined = it plays instead). */
export function shelfHref(item: ShelfItem): string | undefined {
	switch (item.kind) {
		case 'album':
			return albumHref(item.id);
		case 'artist':
			return artistHref(item.id);
		case 'playlist':
			return playlistHref(item.id);
		case 'liked':
			return playlistHref(api.LIKED_ID);
		case 'podcast':
			return showHref(item.id);
		case 'daily_mix':
			return mixHref(item);
		case 'mood':
			return item.params ? moodHref(item.title, item.params, item.color) : undefined;
		case 'episode':
			return `/episode/${encodeURIComponent(item.id)}`;
		case 'audiobook': // stream: audiobooks
			return bookHref(item.id);
		case 'audiobook_genre':
			return genreHref(item.params ?? item.id, item.title);
		default:
			return undefined;
	}
}

/** The key `isPlaying` uses for a shelf item. */
export const shelfKey = (item: ShelfItem) =>
	item.kind === 'liked' ? api.LIKED_ID : item.kind === 'song' ? `song:${item.id}` : item.id;

/** A song shelf item's queue row. */
export const shelfSong = (item: ShelfItem): SongItem =>
	item.song ?? {
		video_id: item.id,
		title: item.title,
		artists: item.subtitle ?? '',
		thumbnail: item.thumbnail,
		explicit: item.explicit
	};

export async function playShelfItem(item: ShelfItem, shuffle = false): Promise<void> {
	const key = shelfKey(item);
	try {
		switch (item.kind) {
			case 'song':
				playSong(shelfSong(item));
				return;
			case 'album':
			case 'artist':
			case 'playlist':
			case 'podcast':
				return playBrowse(
					{ kind: item.kind, id: item.id, title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail } as ExploreItem,
					shuffle
				);
			case 'liked': {
				const p = await api.getPlaylist(api.LIKED_ID);
				await playContext(key, { kind: 'liked', id: api.LIKED_ID, title: 'Liked Songs' }, p.items, {
					sourceId: api.LIKED_ID,
					shuffle,
					continuation: p.continuation
				});
				return;
			}
			case 'daily_mix': {
				const songs = await api.smartMix(item.id);
				await playContext(
					key,
					{ kind: 'daily_mix', id: item.id, title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail },
					songs,
					{ shuffle }
				);
				return;
			}
			case 'episode':
				// The show is the context, so Recents and Home record the show.
				if (!item.song) return;
				await api.playPlaylistFrom([item.song], 0, {
					kind: 'podcast',
					id: item.params ?? `ep:${item.id}`,
					title: item.subtitle ?? item.title,
					thumbnail: item.thumbnail
				});
				return;
			case 'audiobook': // stream: audiobooks — resumes where the book was left
				await playBookById(item.id);
				return;
			case 'mix':
				started[key] = { sourceName: item.title };
				await api.startRadio('artist', item.id, item.title);
				return;
			case 'radio':
				started[key] = { sourceName: item.title };
				await api.startRadio(
					(item.params as 'song' | 'album' | 'playlist' | 'artist') ?? 'song',
					item.id,
					item.title
				);
				return;
			default: {
				const href = shelfHref(item);
				if (href) goto(href);
			}
		}
	} catch (e) {
		playFailed(e, item);
	}
}

/** Primary click: open the item's page; songs and radios (no page to fetch) play instead. */
export function openShelfItem(item: ShelfItem) {
	if (item.kind === 'song') {
		playSong(shelfSong(item));
		return;
	}
	const href = shelfHref(item);
	if (href) goto(href);
	else void toggle(shelfKey(item), () => playShelfItem(item));
}

/** Shelf item as the kit's card-menu item (album / artist / playlist / song only). */
export function shelfMenuItem(item: ShelfItem): BrowseItem | null {
	if (item.kind === 'liked') return { kind: 'playlist', id: api.LIKED_ID, title: 'Liked Songs' };
	if (!['song', 'album', 'artist', 'playlist'].includes(item.kind)) return null;
	return {
		kind: item.kind as BrowseItem['kind'],
		id: item.id,
		title: item.title,
		subtitle: item.subtitle,
		thumbnail: item.thumbnail,
		explicit: item.explicit
	};
}

/** Liked Songs' generated cover (purple → mint gradient + white heart), as an image URL so the kit
 *  Card / ShortcutTile can show it like any artwork. */
export const LIKED_COVER = `data:image/svg+xml;utf8,${encodeURIComponent(
	"<svg xmlns='http://www.w3.org/2000/svg' width='300' height='300'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='#ff4b4b'/><stop offset='1' stop-color='#6a1b9a'/></linearGradient></defs><rect width='300' height='300' fill='url(#g)'/><path transform='translate(102 108) scale(4)' fill='#fff' d='M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z'/></svg>"
)}`;
// Liked Songs also comes back as a plain playlist card (`VLLM`) in Recently played (parity3).
export const shelfImage = (item: ShelfItem) =>
	item.kind === 'liked' || item.id === 'VLLM' ? LIKED_COVER : item.thumbnail;
