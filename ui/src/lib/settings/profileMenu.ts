// The top-bar avatar menu (settings.md "Avatar menu", audit 31): Spotify's text-only list, ≈196px.
// No account is needed for anything: the profile is the local "Spotless" one, and YouTube Music
// sign-in is an optional extra at the bottom. Stream p-settings owns the content; TopBar opens it.
import { goto } from '$app/navigation';
import * as api from '$lib/api';
import { auth, startSignIn } from '$lib/player.svelte';
import { isAndroidHost } from '$lib/platform/android/host';
import { lib } from '$lib/library.svelte';
import { openMenu, type MenuEntry, type MenuTarget } from '$lib/kit/menus';
import { goSettings, importFromSpotify, togglePrivateSession } from './actions';
import { linked, openPairing } from '$lib/devices.svelte';
import { W } from '$lib/devices';

export function profileMenuEntries(): MenuEntry[] {
	const account = auth.account;
	return [
		{ type: 'heading', label: account?.signedIn && account.name ? `Ztunes · ${account.name}` : 'Ztunes · Local profile' },
		{ label: 'Listening stats', onSelect: () => goto('/stats') },
		{ label: 'Recently played', onSelect: () => goto('/history') },
		{ label: 'Import from Spotify', onSelect: importFromSpotify },
		// Device sync: link the iPhone, or (linked) see it in Settings › Devices.
		linked() ? { label: W.menuLinked, onSelect: () => goSettings('devices') } : { label: W.menuLink, onSelect: () => openPairing() },
		{ label: 'Private session', checked: lib.privateSession.enabled, onSelect: togglePrivateSession },
		{ label: 'Customization', onSelect: () => goto('/customization') },
		{ label: 'Settings', hint: '⌘,', onSelect: () => goSettings() },
		{ type: 'separator' },
		account?.signedIn
			? { label: 'Disconnect Google account', onSelect: () => api.signOut() }
			: { label: isAndroidHost() ? 'Import browser session' : 'Connect Google account', onSelect: () => startSignIn() }
	];
}

export function openProfileMenu(target: MenuTarget) {
	openMenu(target, profileMenuEntries(), { width: 240, align: 'end' });
}
