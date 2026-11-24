// The "Sign in to YouTube Music" sheet's state, driven by the sign-in window's events
// (src-tauri/src/session.rs, crates/core/src/login.rs). Pure, so `signin.check.ts` can run it.

export type SignInPhase =
	| { kind: 'idle' }
	| { kind: 'waiting' } // host sign-in UI is open; Ztunes isn't signed in yet
	| { kind: 'failed'; message: string };

export type SignInEvent =
	| { type: 'start' } // a sign-in button was pressed
	| { type: 'done' } // `login-done`: Spotless itself is signed in
	| { type: 'picker' } // `account-selection-required`: the channel picker takes over
	| { type: 'cancelled' } // `login-cancelled`, or Cancel / close on the sheet
	| { type: 'error'; message: string }; // `login-error`, or the window wouldn't open

export function nextSignIn(phase: SignInPhase, event: SignInEvent): SignInPhase {
	switch (event.type) {
		case 'start':
			return { kind: 'waiting' };
		case 'error':
			return { kind: 'failed', message: event.message };
		case 'cancelled':
			// A late `login-cancelled` must not wipe an error the sheet is showing.
			return phase.kind === 'failed' ? phase : { kind: 'idle' };
		case 'done':
		case 'picker':
			return { kind: 'idle' };
	}
}
