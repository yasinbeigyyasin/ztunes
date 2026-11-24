<script lang="ts">
	import type { Snippet } from 'svelte';
	import { afterNavigate, goto } from '$app/navigation';
	import { page } from '$app/state';
	import Icon from '$lib/kit/Icon.svelte';
	import Logo from '$lib/kit/Logo.svelte';
	import { openSettings } from '$lib/shell/settings';
	import { createPlaylistDialog } from '$lib/kit/actions';
	import HouseIcon from 'phosphor-svelte/lib/HouseIcon';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import BooksIcon from 'phosphor-svelte/lib/BooksIcon';
	import PlusIcon from 'phosphor-svelte/lib/PlusIcon';
	import CaretLeftIcon from 'phosphor-svelte/lib/CaretLeftIcon';
	import GearSixIcon from 'phosphor-svelte/lib/GearSixIcon';
	import AndroidMiniPlayer from './AndroidMiniPlayer.svelte';

	let { children }: { children: Snippet } = $props();
	let selectedTab = $state<'home' | 'search' | 'library'>('home');
	const path = $derived(page.url.pathname);
	const tabRoot = $derived(path === '/' || path === '/search' || path === '/library');
	const heading = $derived.by(() => {
		if (path === '/search') return 'Search';
		if (path === '/library') return 'Your Library';
		if (path === '/settings') return 'Settings';
		if (path.startsWith('/playlist/')) return 'Playlist';
		if (path.startsWith('/album/')) return 'Album';
		if (path.startsWith('/artist/')) return 'Artist';
		if (path.startsWith('/radio/')) return 'Radio';
		if (path.startsWith('/episode/')) return 'Episode';
		if (path.startsWith('/show/')) return 'Podcast';
		if (path === '/history') return 'Listening history';
		return 'Ztunes';
	});

	afterNavigate(() => {
		if (path === '/') selectedTab = 'home';
		else if (path === '/search') selectedTab = 'search';
		else if (path === '/library') selectedTab = 'library';
	});

	function selectTab(tab: 'home' | 'search' | 'library') {
		selectedTab = tab;
		const target = tab === 'home' ? '/' : `/${tab}`;
		if (path !== target) goto(target);
		else document.querySelector<HTMLElement>('[data-main-scroll]')?.scrollTo({ top: 0, behavior: 'smooth' });
	}

	function back() {
		if (history.length > 1) history.back();
		else goto('/');
	}
</script>

<div class="android-shell" data-android-shell>
	<header class="android-topbar">
		{#if tabRoot}
			<a class="android-brand" href="/" aria-label="Ztunes home">
				<Logo size={28} />
				<span>Ztunes</span>
			</a>
		{:else}
			<button class="android-header-back" type="button" aria-label="Back" onclick={back}>
				<Icon icon={CaretLeftIcon} size={24} />
			</button>
			<span class="android-header-title">{heading}</span>
		{/if}
		<div class="android-header-spacer"></div>
		<button class="android-header-action" type="button" aria-label="Settings" onclick={() => openSettings()}>
			<Icon icon={GearSixIcon} size={22} />
		</button>
	</header>

	<main
		id="main-view"
		tabindex="-1"
		data-app-main
		data-main-scroll
		class="android-main scroll-area"
	>
		{#key `${page.url.pathname}:${page.url.search}`}
			{@render children()}
		{/key}
	</main>

	<AndroidMiniPlayer />

	<nav class="android-tabbar" aria-label="Primary navigation">
		<button type="button" class:active={selectedTab === 'home'} aria-current={selectedTab === 'home' ? 'page' : undefined} onclick={() => selectTab('home')}>
			<Icon icon={HouseIcon} size={22} fill={selectedTab === 'home'} />
			<span>Home</span>
		</button>
		<button type="button" class:active={selectedTab === 'search'} aria-current={selectedTab === 'search' ? 'page' : undefined} onclick={() => selectTab('search')}>
			<Icon icon={MagnifyingGlassIcon} size={22} />
			<span>Search</span>
		</button>
		<button type="button" class:active={selectedTab === 'library'} aria-current={selectedTab === 'library' ? 'page' : undefined} onclick={() => selectTab('library')}>
			<Icon icon={BooksIcon} size={22} fill={selectedTab === 'library'} />
			<span>Library</span>
		</button>
		<button type="button" aria-label="Create playlist" onclick={() => createPlaylistDialog()}>
			<Icon icon={PlusIcon} size={22} />
			<span>Create</span>
		</button>
	</nav>
</div>
