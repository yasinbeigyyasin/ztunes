<script lang="ts">
	/**
	 * Settings (spotify-spec/screens/settings.md, ref/settings.jpg, audit 32): a main-view page.
	 * Title "Settings" 32/700 with a search button on the right that filters rows; sections with
	 * 16/700 headings; rows = 14px #b3b3b3 label left, control right (accent switches, #1f1f1f
	 * selects, outline pills). Spotify's section order, mapped onto Ztunes's real settings.
	 * Opened from the avatar menu, ⌘, and menu://preferences (shell/settings.ts → goto('/settings')).
	 */
	import { onMount, tick } from 'svelte';
	import { goto } from '$app/navigation';
	import { getVersion } from '@tauri-apps/api/app';
	import { open as pickFolder } from '@tauri-apps/plugin-dialog';
	import * as api from '$lib/api';
	import { auth, local, scanLocal, addLocalFolder, removeLocalFolder, prefs, setAutoplay, startSignIn } from '$lib/player.svelte';
	import { lib } from '$lib/library.svelte';
	import { isAndroidHost } from '$lib/platform/android/host';
	import {
		downloads,
		moveDownloads,
		removeAllDownloads,
		retryDownloads,
		setAllowMetered,
		setDownloadQuality,
		setOfflineMode
	} from '$lib/downloads.svelte'; // stream: downloads
	import {
		audio,
		commitEq,
		dragEq,
		pickDevice,
		pickEqPreset,
		refreshDevices,
		resetEq,
		setCrossfade,
		setEqEnabled,
		setLevel,
		setNormalize
	} from '$lib/audio.svelte';
	import { EQ_BANDS } from '$lib/eq-curve';
	import EqGraph from '$lib/components/audio/EqGraph.svelte';
	import Icon from '$lib/kit/Icon.svelte';
	import IconButton from '$lib/kit/IconButton.svelte';
	import Pill from '$lib/kit/Pill.svelte';
	import Slider from '$lib/kit/Slider.svelte';
	import Skeleton from '$lib/kit/Skeleton.svelte';
	import { toast } from '$lib/kit/toast';
	import { confirmDialog } from '$lib/kit/confirm.svelte';
	import Row from '$lib/settings/Row.svelte';
	import { checkForUpdatesInteractive, installUpdate, openDownloadPage, updateState } from '$lib/updater.svelte';
	import RecoverPlaylists from '$lib/settings/RecoverPlaylists.svelte'; // stream: magic-d4
	import DevicesSection from '$lib/settings/devices/DevicesSection.svelte';
	import Switch from '$lib/settings/Switch.svelte';
	import Select from '$lib/settings/Select.svelte';
	import { setPref, uiPrefs } from '$lib/settings/prefs.svelte';
	import {
		exportLibrary,
		exportOpml,
		formatBytes,
		importFromSpotify,
		importOpml,
		openShortcuts
	} from '$lib/settings/actions';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import ArrowSquareOutIcon from 'phosphor-svelte/lib/ArrowSquareOutIcon';
	import InfoIcon from 'phosphor-svelte/lib/InfoIcon';
	import XIcon from 'phosphor-svelte/lib/XIcon';
	import FolderIcon from 'phosphor-svelte/lib/FolderIcon';

	const androidSessionImport = isAndroidHost();

	// ── backend state ──
	let settings = $state<Record<string, string>>({});
	let smart = $state<api.SmartSettings>({ shuffle_mode: 'smart', explicit_filter: false, private_session: false });
	let pods = $state<api.PodcastSettings | null>(null);
	let podTwins = $state(true);
	let cacheBytes = $state<number | null>(null);
	let version = $state('');
	let loaded = $state(false);
	let failed = $state<string | null>(null);

	async function load() {
		failed = null;
		try {
			const [s, sm, ps, tw] = await Promise.all([
				api.getSettings(),
				api.smartSettings().catch(() => null),
				api.podcastSettings().catch(() => null),
				api.podcastYoutubeMatch().catch(() => true)
			]);
			settings = s ?? {};
			if (sm) smart = sm;
			pods = ps;
			podTwins = tw ?? true;
			loaded = true;
		} catch (e) {
			failed = String(e);
		}
		api.cacheSize().then((n) => (cacheBytes = n ?? 0)).catch(() => (cacheBytes = null));
		if (!local.scanned) scanLocal();
		refreshDevices().catch(() => {});
	}

	onMount(() => {
		getVersion().then((v) => (version = v || '0.1.0')).catch(() => (version = '0.1.0'));
		load().then(async () => {
			await tick();
			const id = location.hash.slice(1);
			if (id) document.getElementById(id)?.scrollIntoView({ block: 'start' });
		});
	});

	async function write(key: string, value: string, revert?: string) {
		const prev = settings[key];
		settings[key] = value;
		try {
			await api.setSetting(key, value);
		} catch (e) {
			settings[key] = revert ?? prev;
			toast.error(String(e).replace(/^autostart: /, ''));
		}
	}
	const on = (key: string, dflt = false) => (settings[key] === undefined ? dflt : settings[key] === 'true');

	// Ask first, as the iPhone does: signing out drops the YouTube playlists and recommendations.
	async function signOut() {
		const ok = await confirmDialog({
			title: 'Sign out of YouTube?',
			body: 'Your library on this Mac stays as it is.',
			confirmLabel: 'Sign out'
		});
		if (!ok) return;
		try {
			await api.signOut();
			toast.success('Signed out of YouTube');
		} catch {
			toast.error("Couldn't sign out. Try again.");
		}
	}

	// ── Audio quality ──
	const QUALITY = [
		{ value: 'AUTO', label: 'Automatic' },
		{ value: 'LOW', label: 'Low' },
		{ value: 'NORMAL', label: 'Normal' },
		{ value: 'HIGH', label: 'High' },
		{ value: 'VERY_HIGH', label: 'Very high' }
	];
	// Automatic by default, as on the iPhone (core `streaming_quality`).
	const quality = $derived(settings.quality ?? 'AUTO');
	const LEVELS: { value: api.VolumeLevel; label: string }[] = [
		{ value: 'loud', label: 'Loud' },
		{ value: 'normal', label: 'Normal' },
		{ value: 'quiet', label: 'Quiet' }
	];
	const deviceOptions = $derived([
		{ value: 'auto', label: 'System default' },
		...audio.devices.devices
			.filter((d) => d.name !== 'auto')
			.map((d) => ({ value: d.name, label: d.description || d.name }))
	]);
	const presetOptions = $derived([
		...(audio.eq.preset ? [] : [{ value: '__custom', label: 'Custom' }]),
		...(audio.info?.presets ?? []).map((p) => ({ value: p.name, label: p.name }))
	]);

	// ── Playback ──
	const crossfadeOn = $derived(audio.crossfadeSecs > 0);
	let fadeDrag = $state<number | null>(null);
	const fadeSecs = $derived(fadeDrag ?? (crossfadeOn ? audio.crossfadeSecs : uiPrefs.crossfadeSecs));
	async function toggleCrossfade(next: boolean) {
		await setCrossfade(next ? Math.max(1, uiPrefs.crossfadeSecs) : 0).catch((e) => toast.error(String(e)));
	}
	async function commitFade(v: number) {
		fadeDrag = null;
		const secs = Math.max(1, Math.round(v));
		setPref('crossfadeSecs', secs);
		await setCrossfade(secs).catch((e) => toast.error(String(e)));
	}
	async function smartSet(key: 'shuffle_mode' | 'explicit_filter', value: string) {
		const prev = { ...smart };
		if (key === 'shuffle_mode') smart.shuffle_mode = value as 'smart' | 'standard';
		else smart.explicit_filter = value === 'true';
		try {
			await api.smartSetSetting(key, value);
		} catch (e) {
			smart = prev;
			toast.error(String(e));
		}
	}

	// ── Podcasts ──
	const SB_CATEGORIES: [string, string][] = [
		['sponsor', 'Sponsor'],
		['selfpromo', 'Self-promotion'],
		['interaction', 'Interaction reminder'],
		['intro', 'Intro'],
		['outro', 'Outro'],
		['preview', 'Preview / recap'],
		['music_offtopic', 'Non-music section'],
		['filler', 'Filler']
	];
	async function podSet(patch: Partial<api.PodcastSettings>) {
		const prev = pods;
		if (pods) pods = { ...pods, ...patch };
		try {
			pods = await api.podcastSetSettings(patch);
		} catch (e) {
			pods = prev;
			toast.error(String(e));
		}
	}
	function toggleCategory(c: string) {
		const cur = new Set(pods?.sponsorblockCategories ?? []);
		if (cur.has(c)) cur.delete(c);
		else cur.add(c);
		podSet({ sponsorblockCategories: [...cur] });
	}
	async function setTwins(next: boolean) {
		podTwins = next;
		try {
			podTwins = await api.podcastSetYoutubeMatch(next);
		} catch (e) {
			podTwins = !next;
			toast.error(String(e));
		}
	}

	// ── Startup ──
	const startup = $derived(!on('autostart') ? 'no' : on('start_minimized') ? 'minimized' : 'yes');
	async function setStartup(v: string) {
		if (v === 'no') {
			await write('autostart', 'false');
			if (on('start_minimized')) await write('start_minimized', 'false');
			return;
		}
		await write('autostart', 'true');
		if (!on('autostart')) return; // registration failed
		await write('start_minimized', v === 'minimized' ? 'true' : 'false');
	}

	// ── Library ──
	async function addFolder() {
		const path = await pickFolder({ directory: true, multiple: false, title: 'Add a folder of music' }).catch(() => null);
		if (typeof path === 'string') await addLocalFolder(path);
	}

	// ── Storage ──
	// leftovers: "Clear listening history" (the stats page's action, reachable from Settings).
	async function clearHistory() {
		const ok = await confirmDialog({
			title: 'Clear listening history?',
			body: 'This forgets every play counted on this device. Your stats, Your Rotation and recommendations start over. This can’t be undone.',
			confirmLabel: 'Clear'
		});
		if (!ok) return;
		try {
			await api.clearListeningHistory();
			toast('Listening history cleared');
		} catch (e) {
			toast.error(String(e));
		}
	}

	let clearing = $state(false);
	async function clearCache() {
		const ok = await confirmDialog({
			title: 'Clear cache?',
			body: 'Songs will load from YouTube again the next time you play them. Your library and downloads are not affected.',
			confirmLabel: 'Clear cache'
		});
		if (!ok) return;
		clearing = true;
		try {
			await api.clearCaches();
			cacheBytes = await api.cacheSize().catch(() => 0);
			toast.success('Cache cleared');
		} catch (e) {
			toast.error(String(e));
		} finally {
			clearing = false;
		}
	}

	// ── stream: downloads ── Storage › Downloads, offline mode, download quality.
	const DL_QUALITY = [
		{ value: 'LOW', label: 'Low' },
		{ value: 'HIGH', label: 'High' }
	];
	let removingDownloads = $state(false);
	async function removeDownloads() {
		const ok = await confirmDialog({
			title: 'Remove all downloads?',
			body: "Everything you've downloaded will be removed from this Mac. You won't be able to play it offline.",
			confirmLabel: 'Remove'
		});
		if (!ok) return;
		removingDownloads = true;
		try {
			await removeAllDownloads();
			toast('Removed all downloads');
		} catch (e) {
			toast.error(String(e));
		} finally {
			removingDownloads = false;
		}
	}
	async function retryFailedDownloads() {
		try {
			await retryDownloads();
			toast('Trying the downloads again');
		} catch (e) {
			toast.error(String(e));
		}
	}
	async function changeDownloadsDir() {
		const path = await pickFolder({ directory: true, multiple: false, title: 'Choose where downloads are stored' }).catch(() => null);
		if (typeof path !== 'string') return;
		try {
			await moveDownloads(path);
			toast('Downloads moved');
		} catch (e) {
			toast.error(String(e));
		}
	}

	// ── Account ──
	const account = $derived(auth.account);

	// ── search (filters rows) ──
	let searchOpen = $state(false);
	let query = $state('');
	let input = $state<HTMLInputElement>();
	let content = $state<HTMLElement>();
	let noMatch = $state(false);
	$effect(() => {
		const q = query.trim().toLowerCase();
		if (!content) return;
		void loaded;
		let any = false;
		for (const sec of content.querySelectorAll<HTMLElement>('[data-settings-section]')) {
			const head = (sec.querySelector('h2')?.textContent ?? '').toLowerCase();
			let shown = 0;
			for (const row of sec.querySelectorAll<HTMLElement>('[data-settings-row]')) {
				const hit = !q || head.includes(q) || (row.textContent ?? '').toLowerCase().includes(q);
				row.style.display = hit ? '' : 'none';
				if (hit) shown++;
			}
			sec.style.display = shown ? '' : 'none';
			if (shown) any = true;
		}
		noMatch = !!q && !any;
	});

	const ext = (url: string) => api.openExternal(url).catch((e) => toast.error(String(e)));
</script>

<svelte:head><title>Settings</title></svelte:head>

{#snippet section(id: string, title: string)}
	<h2 {id} class="mt-6 mb-1 scroll-mt-4 text-base font-bold text-white">{title}</h2>
{/snippet}

<div class="max-w-[804px] px-8 pt-8 pb-16" bind:this={content}>
	<!-- Title at y 96 and "Account" at y 175 at the audit viewport, like Spotify. -->
	<header class="flex items-center justify-between gap-4 pb-3">
		<h1 class="text-2xl font-bold text-white">Settings</h1>
		<div class="flex items-center">
			{#if searchOpen}
				<div class="flex h-8 w-[220px] items-center gap-2 rounded-sm bg-bg-elevated-highlight px-2 text-text-subdued">
					<Icon icon={MagnifyingGlassIcon} size={16} />
					<input
						bind:this={input}
						bind:value={query}
						placeholder="Search settings"
						class="h-full min-w-0 flex-1 bg-transparent text-sm text-white outline-none placeholder:text-text-subdued"
						onkeydown={(e) => {
							if (e.key === 'Escape') {
								query = '';
								searchOpen = false;
							}
						}}
						onblur={() => {
							if (!query) searchOpen = false;
						}}
					/>
				</div>
			{:else}
				<IconButton
					icon={MagnifyingGlassIcon}
					label="Search settings"
					onclick={async () => {
						searchOpen = true;
						await tick();
						input?.focus();
					}}
				/>
			{/if}
		</div>
	</header>
    <nav aria-label="Settings pages" class="flex gap-2 border-b border-white/10 pb-4">
        <button class="rounded-full bg-white px-4 py-2 text-sm font-bold text-black" aria-current="page">Settings</button>
        <button class="rounded-full bg-bg-highlight px-4 py-2 text-sm font-bold text-white hover:bg-bg-elevated-highlight" onclick={() => goto('/customization')}>Customization</button>
    </nav>

	{#if failed}
		<div class="py-16 text-center">
			<h2 class="text-2xl font-bold text-white">Something went wrong</h2>
			<p class="mt-2 text-base text-text-subdued">Settings couldn't be loaded. {failed}</p>
			<button class="btn-white mt-6" onclick={load}>Reload</button>
		</div>
	{:else if !loaded}
		<div class="flex flex-col gap-6" aria-busy="true">
			{#each [3, 2, 4, 3] as n, i (i)}
				<div class="flex flex-col gap-3">
					<Skeleton variant="bar" width="120px" height={16} />
					{#each Array(n) as _, j (j)}
						<div class="flex items-center justify-between"><Skeleton variant="bar" width="45%" height={12} /><Skeleton variant="bar" width="42px" height={24} /></div>
					{/each}
				</div>
			{/each}
		</div>
	{:else}
		{#if noMatch}
			<p class="py-8 text-base text-text-subdued">No settings match “{query.trim()}”.</p>
		{/if}

		<!-- Devices (device sync) comes first: the one way to reach the iPhone. -->
		<DevicesSection />

		<!-- Account -->
		<section data-settings-section>
			{@render section('account', 'Account')}
			<Row label="Ztunes works without an account. Your library, likes and history are stored on this device.">
				{#snippet control()}<span class="text-sm text-white">Local profile</span>{/snippet}
			</Row>
			<Row
				label={account?.signedIn
					? `Connected to Google as ${account.name ?? account.email ?? 'your account'}`
					: androidSessionImport
						? 'Import a Chrome or Edge browser session from a computer to access your YouTube Music library; Ztunes will not open the YouTube Music app'
						: 'Connect your Google account (optional) to access your existing YouTube Music library'}
			>
				{#snippet control()}
					{#if account?.signedIn}
						<Pill variant="outline" onclick={signOut}>Sign out</Pill>
					{:else}
						<Pill variant="outline" onclick={() => startSignIn()}>{androidSessionImport ? 'Import session' : 'Sign in'}</Pill>
					{/if}
				{/snippet}
			</Row>
		</section>

		<!-- Language -->
		<section data-settings-section>
			{@render section('language', 'Language')}
			<Row label="Choose language - Changes will be applied after restarting the app">
				{#snippet control()}
					<Select value="en" label="Language" width={238} options={[{ value: 'en', label: 'English (English)' }]} />
				{/snippet}
			</Row>
		</section>

		<!-- Audio quality -->
		<section data-settings-section>
			{@render section('audio', 'Audio quality')}
			<Row label="Streaming quality">
				{#snippet control()}
					<Select value={quality} label="Streaming quality" options={QUALITY} onchange={(v) => write('quality', v)} />
				{/snippet}
			</Row>
			<!-- stream: downloads -->
			<Row label="Download">
				{#snippet control()}
					<Select value={downloads.quality} label="Download quality" options={DL_QUALITY} onchange={(v) => setDownloadQuality(v as 'HIGH' | 'LOW').catch((e) => toast.error(String(e)))} />
				{/snippet}
			</Row>
			<Row label="Download using metered connections - Cellular, a phone's hotspot or Low Data Mode">
				{#snippet control()}
					<Switch label="Download using metered connections" checked={downloads.network.allowMetered} onchange={(v) => setAllowMetered(v).catch((e) => toast.error(String(e)))} />
				{/snippet}
			</Row>
			<Row label="Normalize volume - Set the same volume level for all songs and podcasts">
				{#snippet control()}
					<Switch label="Normalize volume" checked={audio.normalize} onchange={(v) => setNormalize(v).catch((e) => toast.error(String(e)))} />
				{/snippet}
			</Row>
			<Row label="Volume level - Adjust the volume for your environment. Loud may diminish audio quality. No effect on audio quality in Normal or Quiet.">
				{#snippet control()}
					<Select
						value={audio.level}
						label="Volume level"
						options={LEVELS}
						disabled={!audio.normalize}
						onchange={(v) => setLevel(v).catch((e) => toast.error(String(e)))}
					/>
				{/snippet}
			</Row>
			<Row label="Output device">
				{#snippet control()}
					<Select
						value={audio.devices.selected}
						label="Output device"
						width={238}
						options={deviceOptions}
						onchange={(v) => pickDevice(v).catch((e) => toast.error(String(e)))}
					/>
				{/snippet}
			</Row>
			<Row id="equalizer" label="Equalizer - Adjust audio frequencies to suit your listening">
				{#snippet control()}
					<Switch label="Equalizer" checked={audio.eq.enabled} onchange={(v) => setEqEnabled(v).catch((e) => toast.error(String(e)))} />
				{/snippet}
				{#snippet below()}
					<div class="mt-2 {audio.eq.enabled ? '' : 'opacity-40'}">
						<div class="mb-4 flex items-center justify-between gap-4">
							<span class="text-sm text-text-subdued">Presets</span>
							<div class="flex items-center gap-3">
								<button class="text-sm font-bold text-text-subdued hover:text-white disabled:pointer-events-none" disabled={!audio.eq.enabled} onclick={() => resetEq()}>Reset</button>
								<Select
									value={audio.eq.preset ?? '__custom'}
									label="Equalizer preset"
									width={180}
									disabled={!audio.eq.enabled}
									options={presetOptions}
									onchange={(v) => v !== '__custom' && pickEqPreset(v).catch((e) => toast.error(String(e)))}
								/>
							</div>
						</div>
						<div class="eq-skin flex gap-2">
							<div class="flex w-10 shrink-0 flex-col justify-between pt-[12px] pb-[34px] text-right text-xs text-text-subdued">
								<span>+12dB</span><span>0dB</span><span>-12dB</span>
							</div>
							<div class="min-w-0 flex-1">
								<EqGraph
									gains={audio.eq.gains}
									bands={audio.info?.bands?.length ? audio.info.bands.map((b, i) => ({ ...EQ_BANDS[i], ...b })) : EQ_BANDS}
									maxDb={audio.info?.maxDb ?? 12}
									disabled={!audio.eq.enabled}
									height={200}
									ondrag={dragEq}
									oncommit={(g) => commitEq(g).catch((e) => toast.error(String(e)))}
								/>
							</div>
						</div>
					</div>
				{/snippet}
			</Row>
		</section>

		<!-- Your Library -->
		<section data-settings-section>
			{@render section('library', 'Your Library')}
			<Row label="Show Local Files">
				{#snippet control()}
					<Switch label="Show Local Files" checked={uiPrefs.showLocalFiles} onchange={(v) => setPref('showLocalFiles', v)} />
				{/snippet}
			</Row>
			{#if uiPrefs.showLocalFiles}
				<Row label="Show songs from">
					{#snippet control()}
						<Pill variant="outline" onclick={addFolder}>Add a source</Pill>
					{/snippet}
					{#snippet below()}
						<div class="flex flex-col">
							{#each local.folders as f (f)}
								<div class="group flex h-10 items-center gap-3 rounded-sm px-2 text-sm text-white hover:bg-bg-tinted">
									<Icon icon={FolderIcon} size={16} class="shrink-0 text-text-subdued" />
									<span class="min-w-0 flex-1 truncate" title={f}>{f}</span>
									<IconButton icon={XIcon} label="Remove {f.split('/').pop()}" onclick={() => removeLocalFolder(f)} />
								</div>
							{:else}
								<p class="px-2 text-sm text-text-subdued">
									{local.loading ? 'Scanning…' : 'No folders yet. Add a folder of music files to play them in Ztunes.'}
								</p>
							{/each}
							{#if local.error}<p class="px-2 text-sm text-text-negative">{local.error}</p>{/if}
						</div>
					{/snippet}
				</Row>
			{/if}
			<Row label="Import your playlists, Liked Songs, albums and artists from Spotify">
				{#snippet control()}<Pill variant="outline" onclick={importFromSpotify}>Import library</Pill>{/snippet}
			</Row>
			<Row label="Export your Liked Songs and playlists (CSV, M3U and XSPF in a zip in Downloads)">
				{#snippet control()}<Pill variant="outline" onclick={exportLibrary}>Export library</Pill>{/snippet}
			</Row>
			<RecoverPlaylists /><!-- stream: magic-d4 -->
		</section>

		<!-- Display -->
		<section data-settings-section>
			{@render section('display', 'Display')}
			<Row label="Show the now-playing panel on click of play">
				{#snippet control()}
					<Switch label="Show Now Playing view on play" checked={uiPrefs.nowPlayingOnPlay} onchange={(v) => setPref('nowPlayingOnPlay', v)} />
				{/snippet}
			</Row>
			<Row label="Show desktop notifications when the song changes">
				{#snippet control()}
					<Switch label="Desktop notifications" checked={on('track_notifications')} onchange={(v) => write('track_notifications', String(v))} />
				{/snippet}
			</Row>
			<Row label="Show unplayable songs - Greyed out when they can't play right now (explicit, unavailable, or not downloaded while offline). Turn off to leave them out of lists.">
				{#snippet control()}
					<Switch
						label="Show unplayable songs"
						checked={on('show_unplayable', true)}
						onchange={(v) => {
							prefs.showUnplayable = v;
							write('show_unplayable', String(v));
						}}
					/>
				{/snippet}
			</Row>
		</section>

		<!-- Social -->
		<section data-settings-section>
			{@render section('social', 'Social')}
			<Row
				label="Start a private session to listen anonymously"
				hint={lib.privateSession.enabled && lib.privateSession.expiresAt
					? `Ends at ${new Date(lib.privateSession.expiresAt * 1000).toLocaleTimeString(undefined, { timeStyle: 'short' })}. Nothing you play is added to your history or recommendations.`
					: undefined}
			>
				{#snippet control()}
					<Switch
						label="Private session"
						checked={lib.privateSession.enabled}
						onchange={(v) => lib.setPrivateSession(v).catch((e) => toast.error(String(e)))}
					/>
				{/snippet}
			</Row>
			<!-- leftovers: linked from "About recommendations"; the same action as the stats page. -->
			<Row
				id="clear-history"
				label="Clear listening history"
				hint="Forgets every play counted on this Mac. Your stats, Your Rotation and recommendations start over."
			>
				{#snippet control()}
					<Pill variant="outline" onclick={clearHistory}>Clear</Pill>
				{/snippet}
			</Row>
		</section>

		<!-- Explicit content -->
		<section data-settings-section>
			{@render section('explicit', 'Explicit content')}
			<Row label="Allow playback of explicit-rated content">
				{#snippet control()}
					<Switch
						label="Allow explicit content"
						checked={!smart.explicit_filter}
						onchange={(v) => smartSet('explicit_filter', String(!v))}
					/>
				{/snippet}
			</Row>
		</section>

		<!-- Playback -->
		<section data-settings-section>
			{@render section('playback', 'Playback')}
			<Row label="Crossfade songs">
				{#snippet control()}
					{#if crossfadeOn}
						<div class="flex w-[260px] items-center gap-2 text-xs text-text-subdued">
							<span class="w-7 text-right tabular-nums">{Math.round(fadeSecs)} s</span>
							<Slider
								class="flex-1"
								label="Crossfade length"
								value={fadeSecs}
								max={12}
								step={1}
								oninput={(v) => (fadeDrag = Math.max(1, Math.round(v)))}
								onchange={commitFade}
							/>
							<span class="w-7 tabular-nums">12 s</span>
						</div>
					{/if}
					<Switch label="Crossfade songs" checked={crossfadeOn} onchange={toggleCrossfade} />
				{/snippet}
			</Row>
			<Row label="Smart Shuffle suggestions - Shuffle in your own playlists adds recommendations that fit.">
				{#snippet control()}
					<Switch
						label="Smart Shuffle suggestions"
						checked={smart.shuffle_mode === 'smart'}
						onchange={(on) => smartSet('shuffle_mode', on ? 'smart' : 'standard')}
					/>
				{/snippet}
			</Row>
			<Row label="Autoplay - Enjoy nonstop listening. When your audio ends, we'll play you something similar">
				{#snippet control()}<Switch label="Autoplay" checked={prefs.autoplay} onchange={setAutoplay} />{/snippet}
			</Row>
		</section>

		<!-- Podcasts -->
		<section data-settings-section>
			{@render section('podcasts', 'Podcasts')}
			<Row label="Skip sponsored segments in YouTube podcast episodes (SponsorBlock)">
				{#snippet control()}
					<Switch label="SponsorBlock" checked={!!pods?.sponsorblock} disabled={!pods} onchange={(v) => podSet({ sponsorblock: v })} />
				{/snippet}
				{#snippet below()}
					{#if pods?.sponsorblock}
						<div class="flex flex-wrap gap-2">
							{#each SB_CATEGORIES as [id, label] (id)}
								<Pill variant="chip" selected={pods.sponsorblockCategories.includes(id)} onclick={() => toggleCategory(id)}>{label}</Pill>
							{/each}
						</div>
					{/if}
				{/snippet}
			</Row>
			<Row label="Play ad-free YouTube versions of podcast episodes when available">
				{#snippet control()}<Switch label="YouTube versions of podcast episodes" checked={podTwins} onchange={setTwins} />{/snippet}
			</Row>
			<!-- stream: video-pods. The rule (and Data Saver / offline) lives in the core's podcasts::video. -->
			<Row label="Play video podcasts as audio only (you can still switch to video)">
				{#snippet control()}<Switch
						label="Video podcasts as audio only"
						checked={on('podcast_audio_only')}
						onchange={(v) => {
							prefs.podcastAudioOnly = v;
							write('podcast_audio_only', String(v));
						}}
					/>{/snippet}
			</Row>
			<Row label="Import podcasts from another app (OPML)">
				{#snippet control()}<Pill variant="outline" onclick={importOpml}>Import OPML</Pill>{/snippet}
			</Row>
			<Row label="Export the podcasts you follow (OPML)">
				{#snippet control()}<Pill variant="outline" onclick={exportOpml}>Export OPML</Pill>{/snippet}
			</Row>
		</section>

		<!-- Startup and window behavior -->
		<section data-settings-section>
			{@render section('startup', 'Startup and window behavior')}
			<Row label="Open Ztunes automatically after you log into the computer">
				{#snippet control()}
					<Select
						value={startup}
						label="Open at login"
						options={[
							{ value: 'no', label: 'No' },
							{ value: 'yes', label: 'Yes' },
							{ value: 'minimized', label: 'Minimized' }
						]}
						onchange={setStartup}
					/>
				{/snippet}
			</Row>
			<Row label="Close button should minimize the Ztunes window">
				{#snippet control()}
					<Switch label="Close button minimizes" checked={on('close_to_tray', true)} onchange={(v) => write('close_to_tray', String(v))} />
				{/snippet}
			</Row>
		</section>

		<!-- Storage -->
		<section data-settings-section>
			{@render section('storage', 'Storage')}
			<!-- stream: downloads -->
			<Row label="Offline mode - Only play what you've downloaded">
				{#snippet control()}
					<Switch label="Offline mode" checked={downloads.network.offlineMode} onchange={(v) => setOfflineMode(v).catch((e) => toast.error(String(e)))} />
				{/snippet}
			</Row>
			<Row label="Offline storage location">
				{#snippet children()}
					<span class="mt-0.5 block truncate text-sm text-text-subdued" title={downloads.dir}>{downloads.dir || '—'}</span>
				{/snippet}
				{#snippet control()}
					<Pill variant="outline" onclick={changeDownloadsDir}>Change location</Pill>
				{/snippet}
			</Row>
			<Row label={`Downloads: ${formatBytes(downloads.bytes)}`}>
				{#snippet children()}
					<span class="mt-0.5 block text-xs">
						{downloads.count} {downloads.count === 1 ? 'song or episode' : 'songs and episodes'}{#if downloads.queued} · {downloads.queued} waiting{#if downloads.network.paused} (paused{downloads.network.offline ? ', offline' : downloads.network.metered && !downloads.network.allowMetered ? ', metered connection' : ''}){/if}{/if}{#if downloads.failed} · {downloads.failed} couldn't download{/if}
					</span>
				{/snippet}
				{#snippet control()}
					<Pill variant="outline" disabled={removingDownloads || !downloads.count && !downloads.queued} onclick={removeDownloads}>{removingDownloads ? 'Removing…' : 'Remove all downloads'}</Pill>
				{/snippet}
			</Row>
			{#if downloads.failed}
				<Row label={downloads.failed === 1 ? "1 song didn't download" : `${downloads.failed} songs didn't download`}>
					{#snippet control()}
						<Pill variant="outline" onclick={retryFailedDownloads}>Retry</Pill>
					{/snippet}
				</Row>
			{/if}
			<Row label="Cache: audio Ztunes keeps on this Mac so songs start faster">
				{#snippet children()}
					<span class="mt-0.5 block text-xs">{cacheBytes === null ? '—' : formatBytes(cacheBytes)}</span>
				{/snippet}
				{#snippet control()}
					<Pill variant="outline" disabled={clearing} onclick={clearCache}>{clearing ? 'Clearing…' : 'Clear cache'}</Pill>
				{/snippet}
			</Row>
		</section>

		<!-- Keyboard shortcuts -->
		<section data-settings-section>
			{@render section('shortcuts', 'Keyboard shortcuts')}
			<Row label="See every keyboard shortcut (⌘/)">
				{#snippet control()}<Pill variant="outline" onclick={openShortcuts}>Keyboard shortcuts</Pill>{/snippet}
			</Row>
		</section>

		<!-- About -->
		<section data-settings-section>
			{@render section('about', 'About')}
			<!-- Also run by Ztunes › Check for Updates… (menu://check-updates), which lands here. -->
			<Row id="updates" label="Check for updates" hint={`Version ${version || '…'}`}>
				{#if updateState.result}
					<div
						class="mt-1 text-sm {updateState.result.error ? 'text-text-negative' : 'text-white'}"
						role="status"
						data-testid="update-result"
					>
						{updateState.result.message}
					</div>
				{/if}
				{#snippet control()}
					{#if updateState.result?.available && updateState.available}
						{#if updateState.canInstall}
							<Pill variant="white" onclick={installUpdate} disabled={updateState.installing}>
								{updateState.installing ? 'Installing…' : 'Install'}
							</Pill>
						{:else}
							<Pill variant="white" onclick={openDownloadPage}>Download</Pill>
						{/if}
					{/if}
					<Pill variant="outline" onclick={() => checkForUpdatesInteractive()} disabled={updateState.checking || updateState.installing}>
						{updateState.checking ? 'Checking…' : 'Check for updates'}
					</Pill>
				{/snippet}
			</Row>
			<Row label="Ztunes is based on Spotless and Limusic and is licensed under GPL-3.0 or later. Music is supplied by YouTube Music and other services.">
				{#snippet control()}
					<Pill variant="outline" onclick={() => ext('https://www.gnu.org/licenses/gpl-3.0.html')}>
						License <Icon icon={ArrowSquareOutIcon} size={16} />
					</Pill>
				{/snippet}
			</Row>
			<Row label="Credits">
                {#snippet below()}
                    <div class="space-y-2 py-2 text-sm text-white">
                        <p>Developer: Yasin Beigy</p>
                        <p>Designer: Yasin Beigy</p>
                    </div>
                {/snippet}
            </Row>
            <Row label="Open-source licenses and notices" hint="Ztunes uses third-party open-source software.">
                {#snippet control()}
                    <Pill variant="outline" onclick={() => ext('https://github.com/fjenn/spotless/blob/main/THIRD-PARTY-NOTICES.md')}>Notices <Icon icon={ArrowSquareOutIcon} size={16} /></Pill>
                {/snippet}
            </Row>
		</section>
	{/if}
</div>

<style>
	/* Spotify's EQ look: accent curve and fill, white handles, faint grid. */
	.eq-skin {
		--eq-curve: var(--color-accent);
		--eq-fill: var(--color-accent);
		--eq-grid: rgb(255 255 255 / 0.1);
		--eq-zero: rgb(255 255 255 / 0.2);
		--eq-handle: #fff;
		--eq-handle-ring: rgb(255 255 255 / 0.15);
		--eq-label: var(--color-text-subdued);
		--eq-font-size: 12px;
		--eq-disabled-opacity: 1;
	}
</style>
