import tailwindcss from '@tailwindcss/vite';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';

const androidWebView = process.env.ZTUNES_ANDROID_WEBVIEW === '1';
const androidShim = (name: string) => fileURLToPath(new URL(`./src/lib/platform/android/${name}.ts`, import.meta.url));

export default defineConfig({
	resolve: {
		alias: androidWebView ? [
			{ find: '@tauri-apps/api/core', replacement: androidShim('core') },
			{ find: '@tauri-apps/api/event', replacement: androidShim('event') },
			{ find: '@tauri-apps/api/window', replacement: androidShim('window') },
			{ find: '@tauri-apps/api/webview', replacement: androidShim('webview') },
			{ find: '@tauri-apps/api/app', replacement: androidShim('app') },
			{ find: '@tauri-apps/plugin-process', replacement: androidShim('process') },
			{ find: '@tauri-apps/plugin-updater', replacement: androidShim('updater') },
			{ find: '@tauri-apps/plugin-dialog', replacement: androidShim('dialog') },
			{ find: '@tauri-apps/plugin-clipboard-manager', replacement: androidShim('clipboard') }
		] : []
	},
	server: {
		port: 5183,
		strictPort: true,
		// The Browse tile colours live in the core, one list for both apps (discover/data.ts).
		fs: { allow: ['.', '../crates/core/browse_tiles.json'] }
	},
	plugins: [
		{
			name: 'limusic-dev-referrer-policy',
			configureServer(server) {
				server.middlewares.use((_req, res, next) => {
					res.setHeader('Referrer-Policy', 'no-referrer');
					next();
				});
			}
		},
		// stream: perf — each phosphor-svelte icon is a component carrying all six weights' paths, and
		// ~230 KB of them loaded at startup. Spotless only draws regular, fill and bold (kit/Icon.svelte,
		// ui-kit.md rule 4), so the light / thin / duotone branches are cut before compiling: about
		// half of every icon. A cut weight falls through to the component's "unsupported" branch.
		{
			name: 'encore-phosphor-weights',
			enforce: 'pre',
			transform(code, id) {
				if (!/phosphor-svelte[\\/]lib[\\/][^\\/]+\.svelte$/.test(id)) return;
				return code
					.replace(/\{:else if weight === "(?:light|thin|duotone)"\}[\s\S]*?(?=\{:else)/g, '')
					.replace(/\{:else\}\s*\{\(console\.error\([^)]*\), ""\)\}\s*(?=\{\/if\})/g, '');
			}
		},
		tailwindcss(),
		sveltekit({
			alias: { '$lib': 'src/lib' },
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) => filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// SPA fallback so the dynamic /playlist/[id] route resolves on direct load. context/18.
			adapter: adapter({ fallback: 'index.html' })
		})
	]
});
