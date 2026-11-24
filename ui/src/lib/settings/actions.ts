// Settings-owned actions shared by the Settings page, the avatar menu and the first-run step
// (stream p-settings).
import { goto } from '$app/navigation';
import { save as pickSave } from '@tauri-apps/plugin-dialog';
import * as api from '$lib/api';
import { lib } from '$lib/library.svelte';
import { toast } from '$lib/kit/toast';
import { openImport } from '$lib/import.svelte';
import { ui } from '$lib/player.svelte';

/** Settings opens as a page (Spotify `/preferences`), from the avatar menu, ⌘, and the menu bar. */
export function goSettings(section?: string) {
	goto(section ? `/settings#${section}` : '/settings');
}

export function importFromSpotify() {
	openImport();
}

/** Library export: a zip in Downloads, then a toast with "Show in Finder". */
export async function exportLibrary() {
	toast('Exporting your library…');
	try {
		const r = await lib.exportLibrary();
		toast.success(
			`Library exported: ${r.likedSongs} liked ${r.likedSongs === 1 ? 'song' : 'songs'}, ${r.playlists} ${r.playlists === 1 ? 'playlist' : 'playlists'}`,
			{ action: { label: 'Show in Finder', onClick: () => api.revealInFinder(r.path).catch(() => {}) } }
		);
	} catch (e) {
		toast.error(`Couldn't export your library. ${String(e)}`);
	}
}

/** OPML: pick a file (the webview's own picker hands us its text), follow every show in it. */
export function importOpml() {
	const input = document.createElement('input');
	input.type = 'file';
	input.accept = '.opml,.xml,text/xml,application/xml';
	input.onchange = async () => {
		const file = input.files?.[0];
		if (!file) return;
		try {
			const r = await api.podcastOpmlImport(await file.text());
			toast.success(
				r.added
					? `Following ${r.added} new ${r.added === 1 ? 'show' : 'shows'}`
					: `No new shows (${r.alreadyFollowed} already followed)`
			);
		} catch (e) {
			toast.error(`Couldn't read that OPML file. ${String(e)}`);
		}
	};
	input.click();
}

export async function exportOpml() {
	const path = await pickSave({
		title: 'Export podcasts (OPML)',
		defaultPath: 'Ztunes Podcasts.opml',
		filters: [{ name: 'OPML', extensions: ['opml'] }]
	}).catch(() => null);
	if (!path) return;
	try {
		await api.saveTextFile(path, await api.podcastOpmlExport());
		toast.success('Podcasts exported', {
			action: { label: 'Show in Finder', onClick: () => api.revealInFinder(path).catch(() => {}) }
		});
	} catch (e) {
		toast.error(`Couldn't export your podcasts. ${String(e)}`);
	}
}

export function openShortcuts() {
	ui.shortcutsOpen = true;
}

export async function togglePrivateSession() {
	const on = !lib.privateSession.enabled;
	try {
		await lib.setPrivateSession(on);
		toast(on ? 'Private session started' : 'Private session ended');
	} catch (e) {
		toast.error(String(e));
	}
}

/** "1.2 GB" */
export function formatBytes(n: number): string {
	if (!n) return '0 MB';
	const units = ['B', 'KB', 'MB', 'GB', 'TB'];
	let i = 0;
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${units[i]}`;
}
