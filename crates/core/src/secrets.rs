//! YouTube sign-in cookies in the macOS Keychain (stream import2), not in plaintext SQLite.
//!
//! The database keeps every row it had; only the cookie text in it is replaced by the marker
//! [`SEALED`], and the cookie itself lives in a Keychain "generic password" item:
//!
//! - service `app.spotless.desktop` (the bundle id, so the items are easy to find in Keychain
//!   Access and stable across versions and rebuilds). Before the rename it was
//!   `app.encore.desktop` ([`LEGACY_SERVICE`]): an item missing under the new name is read from
//!   the old one once and saved under the new one ([`Migrating`]);
//! - account `session_cookie` for the active session (`settings.session_cookie`), and
//!   `account:<id>` for each saved Google account (`accounts.session_cookie`).
//!
//! **Migration.** At launch, [`Db::seal_secrets`](crate::db::Db::seal_secrets) moves any cookie
//! still in plaintext into the Keychain. Idempotent.
//!
//! **Fallback.** Desktop retains its historical plaintext fallback when the OS store refuses a
//! write. Android account sign-in is strict: it aborts unless the host's Keystore-backed store
//! accepts the cookie, and ordinary sealing never writes a cookie to SQLite in plaintext. A sealed
//! cookie the store can't give back reads as "not signed in" (the row stays for a later retry).
//!
//! **Prompts and ad-hoc signed builds.** macOS ties a Keychain item to the code signature of the
//! app that created it. A Developer ID build's signature stays the same from release to release,
//! so the item is read silently forever. An ad-hoc signed build (`codesign -s -`, what
//! `scripts/build-mac.sh` and unsigned releases make) is identified by its exact binary hash, so
//! after every rebuild or update macOS asks once "Spotless wants to use your confidential
//! information stored in app.spotless.desktop" (Always Allow covers that binary only). To keep that
//! prompt off every dev rebuild, **debug builds don't move cookies into the Keychain** unless
//! `ENCORE_KEYCHAIN=1` is set; they still read a cookie a release build sealed (one prompt then).
//! Release builds always use the Keychain. `ENCORE_KEYCHAIN=0` turns it off in any build.

use std::sync::OnceLock;

/// What SQLite holds in place of a cookie that lives in the Keychain.
pub const SEALED: &str = "@keychain";
pub const SERVICE: &str = "app.spotless.desktop";
/// The Keychain service before the app was renamed from Encore to Spotless.
pub const LEGACY_SERVICE: &str = "app.encore.desktop";
/// The Keychain account of the active session's cookie.
pub const SESSION: &str = "session_cookie";

pub fn account_name(id: &str) -> String {
    format!("account:{id}")
}

pub trait Store: Send + Sync {
    fn get(&self, name: &str) -> Result<Option<String>, String>;
    fn set(&self, name: &str, value: &str) -> Result<(), String>;
    fn delete(&self, name: &str) -> Result<(), String>;
}

/// The store new cookies are sealed into. Unset (tests, debug builds, other platforms): cookies
/// stay in SQLite.
static STORE: OnceLock<Box<dyn Store>> = OnceLock::new();

/// Whether this build seals cookies into the Keychain (see the module docs).
pub fn wanted() -> bool {
    match std::env::var("ENCORE_KEYCHAIN").ok().as_deref() {
        Some("0") => false,
        Some("1") => cfg!(target_os = "macos"),
        _ => cfg!(target_os = "macos") && !cfg!(debug_assertions),
    }
}

/// Called once at launch, before the first cookie is read. `custom` is the host's own store
/// (`Host::secret_store`, e.g. the iOS Keychain through Swift); without one a Mac uses the Keychain.
pub fn install(custom: Option<Box<dyn Store>>) {
    if let Some(store) = custom {
        let _ = STORE.set(store);
        tracing::info!("secrets: sign-in cookies are kept in the host's store");
        return;
    }
    #[cfg(target_os = "macos")]
    if wanted() {
        let _ = STORE.set(Box::new(Migrating::new(Keychain(SERVICE), Keychain(LEGACY_SERVICE))));
        tracing::info!("secrets: sign-in cookies are kept in the Keychain");
    }
}

/// The installed store. Tests get one per thread (each test runs on its own), so a test that
/// installs one never leaks into another.
#[cfg(not(test))]
fn store() -> Option<&'static dyn Store> {
    STORE.get().map(|s| s.as_ref())
}

#[cfg(test)]
thread_local! {
    static TEST_STORE: std::cell::Cell<Option<&'static Memory>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn store() -> Option<&'static dyn Store> {
    let _ = &STORE;
    TEST_STORE.with(|s| s.get()).map(|m| Box::leak(Box::new(m)) as &'static dyn Store)
}

/// Install a fresh in-memory store for the calling test's thread.
#[cfg(test)]
pub fn install_test_store() -> &'static Memory {
    let m: &'static Memory = Box::leak(Box::default());
    TEST_STORE.with(|s| s.set(Some(m)));
    m
}

/// The store a sealed value is read from: the installed one, or the Keychain itself (a debug
/// build reading what a release build sealed).
fn reader() -> Option<&'static dyn Store> {
    if let Some(s) = store() {
        return Some(s);
    }
    #[cfg(target_os = "macos")]
    {
        static FALLBACK: Migrating<Keychain> =
            Migrating::new(Keychain(SERVICE), Keychain(LEGACY_SERVICE));
        if !cfg!(test) {
            return Some(&FALLBACK);
        }
    }
    None
}

/// Store an authentication cookie before committing its sealed marker to SQLite. Android callers
/// use this strict variant so a failed Keystore write aborts sign-in instead of leaving a
/// signed-in account that cannot survive process restart. Desktop keeps its historical fallback.
pub fn seal_account_cookie(name: &str, value: &str) -> Result<String, String> {
    if value.is_empty() || value == SEALED {
        return Ok(value.to_owned());
    }
    if cfg!(target_os = "android") {
        let store = store().ok_or_else(|| "Android Keystore is unavailable".to_owned())?;
        store
            .set(name, value)
            .map_err(|_| "Android secure credential storage failed".to_owned())?;
        Ok(SEALED.to_owned())
    } else {
        Ok(seal(name, value))
    }
}

/// What to write to SQLite for `value`: [`SEALED`] once the store holds it. Desktop keeps its
/// historical plaintext fallback when no OS store is available; Android fails closed so a cookie
/// can never silently land in the database in plaintext.
pub fn seal(name: &str, value: &str) -> String {
    let Some(store) = store() else {
        if cfg!(target_os = "android") {
            tracing::error!(
                name,
                "secrets: Android Keystore is unavailable; refusing plaintext persistence"
            );
            return SEALED.to_owned();
        }
        return value.to_owned();
    };
    if value.is_empty() || value == SEALED {
        return value.to_owned();
    }
    match store.set(name, value) {
        Ok(()) => SEALED.to_owned(),
        Err(e) if cfg!(target_os = "android") => {
            tracing::error!(name, error = %e, "secrets: Android Keystore write failed; refusing plaintext persistence");
            SEALED.to_owned()
        }
        Err(e) => {
            tracing::warn!(name, error = %e, "secrets: Keychain write failed, keeping it in the database");
            value.to_owned()
        }
    }
}

/// The real value of what SQLite holds. `None` for a sealed value the store can't give back.
pub fn unseal(name: &str, stored: String) -> Option<String> {
    if stored != SEALED {
        return Some(stored);
    }
    match reader().map(|s| s.get(name)) {
        Some(Ok(Some(v))) => Some(v),
        Some(Ok(None)) => {
            tracing::warn!(name, "secrets: sealed cookie missing from the Keychain");
            None
        }
        Some(Err(e)) => {
            tracing::warn!(name, error = %e, "secrets: Keychain read failed");
            None
        }
        None => None,
    }
}

/// Drop a value from the store (sign-out, a removed account). Best effort.
pub fn forget(name: &str) {
    if let Some(store) = reader() {
        if let Err(e) = store.delete(name) {
            tracing::debug!(name, error = %e, "secrets: delete failed");
        }
    }
}

/// A store renamed from `legacy`: a value missing from `current` is read from `legacy` once and
/// saved into `current`, where every later read finds it. The legacy item is left as it was
/// (the old app can still read it); sign-out and removal ([`forget`]) clear both.
pub struct Migrating<S> {
    current: S,
    legacy: S,
}

impl<S> Migrating<S> {
    pub const fn new(current: S, legacy: S) -> Self {
        Self { current, legacy }
    }
}

impl<S: Store> Store for Migrating<S> {
    fn get(&self, name: &str) -> Result<Option<String>, String> {
        if let Some(v) = self.current.get(name)? {
            return Ok(Some(v));
        }
        let Ok(Some(v)) = self.legacy.get(name) else { return Ok(None) };
        match self.current.set(name, &v) {
            Ok(()) => {
                tracing::info!(name, "secrets: moved a cookie to the renamed Keychain service")
            }
            Err(e) => {
                tracing::warn!(name, error = %e, "secrets: could not re-save a legacy cookie")
            }
        }
        Ok(Some(v))
    }

    fn set(&self, name: &str, value: &str) -> Result<(), String> {
        self.current.set(name, value)
    }

    fn delete(&self, name: &str) -> Result<(), String> {
        let _ = self.legacy.delete(name);
        self.current.delete(name)
    }
}

/// The Keychain's generic-password items under one service name.
#[cfg(target_os = "macos")]
struct Keychain(&'static str);

#[cfg(target_os = "macos")]
impl Keychain {
    fn entry(&self, name: &str) -> Result<keyring::Entry, String> {
        keyring::Entry::new(self.0, name).map_err(|e| e.to_string())
    }
}

#[cfg(target_os = "macos")]
impl Store for Keychain {
    fn get(&self, name: &str) -> Result<Option<String>, String> {
        match self.entry(name)?.get_password() {
            Ok(v) => Ok(Some(v)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn set(&self, name: &str, value: &str) -> Result<(), String> {
        self.entry(name)?.set_password(value).map_err(|e| e.to_string())
    }

    fn delete(&self, name: &str) -> Result<(), String> {
        match self.entry(name)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

/// An in-memory store for tests.
#[cfg(test)]
#[derive(Default)]
pub struct Memory {
    pub map: std::sync::Mutex<std::collections::HashMap<String, String>>,
    pub fail_writes: std::sync::atomic::AtomicBool,
}

#[cfg(test)]
impl Store for &'static Memory {
    fn get(&self, name: &str) -> Result<Option<String>, String> {
        Ok(self.map.lock().unwrap().get(name).cloned())
    }
    fn set(&self, name: &str, value: &str) -> Result<(), String> {
        if self.fail_writes.load(std::sync::atomic::Ordering::Relaxed) {
            return Err("refused".into());
        }
        self.map.lock().unwrap().insert(name.to_owned(), value.to_owned());
        Ok(())
    }
    fn delete(&self, name: &str) -> Result<(), String> {
        self.map.lock().unwrap().remove(name);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Live: a real Keychain round trip under a throwaway service name, removed again.
    /// `cargo test -p limusic-app --lib -- --ignored secrets`
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore]
    fn keychain_round_trip() {
        let e = keyring::Entry::new("app.spotless.desktop.selftest", "probe").unwrap();
        e.set_password("SAPISID=probe; __Secure-3PSID=x").unwrap();
        assert_eq!(e.get_password().unwrap(), "SAPISID=probe; __Secure-3PSID=x");
        e.delete_credential().unwrap();
        assert!(matches!(e.get_password(), Err(keyring::Error::NoEntry)));
    }

    #[test]
    fn cookies_move_into_the_store_and_back() {
        use crate::db::{Db, StoredAccount};
        let mem = install_test_store();
        let db = Db::open(std::path::Path::new(":memory:")).unwrap();
        // Plaintext from before this build.
        db.with_conn(|c| {
            c.execute("INSERT INTO settings(key, value) VALUES('session_cookie', 'SAPISID=old')", [])
                .unwrap();
            c.execute(
                "INSERT INTO accounts(id, session_cookie, added_at) VALUES('acc1', 'SAPISID=a1', 1)",
                [],
            )
            .unwrap();
        });
        db.seal_secrets();
        db.seal_secrets(); // idempotent
        let raw =
            |sql: &str| db.with_conn(|c| c.query_row(sql, [], |r| r.get::<_, String>(0)).unwrap());
        assert_eq!(raw("SELECT value FROM settings WHERE key = 'session_cookie'"), SEALED);
        assert_eq!(raw("SELECT session_cookie FROM accounts WHERE id = 'acc1'"), SEALED);
        assert_eq!(db.get_setting("session_cookie").as_deref(), Some("SAPISID=old"));
        assert_eq!(db.get_account("acc1").unwrap().session_cookie, "SAPISID=a1");
        // New writes go straight in.
        db.set_setting("session_cookie", "SAPISID=new");
        assert_eq!(raw("SELECT value FROM settings WHERE key = 'session_cookie'"), SEALED);
        assert_eq!(mem.map.lock().unwrap().get(SESSION).unwrap(), "SAPISID=new");
        db.update_account_cookie("acc1", "SAPISID=a1; rotated");
        assert_eq!(db.list_accounts()[0].session_cookie, "SAPISID=a1; rotated");
        db.upsert_account(&StoredAccount {
            id: "acc2".into(),
            session_cookie: "SAPISID=a2".into(),
            data_sync_id: None,
            selected_identity_json: None,
            account_json: None,
            visitor_data: None,
            added_at: 2,
        })
        .unwrap();
        assert_eq!(db.get_account("acc2").unwrap().session_cookie, "SAPISID=a2");
        assert_eq!(raw("SELECT session_cookie FROM accounts WHERE id = 'acc2'"), SEALED);
        // Sign-out and removal clear the Keychain items too.
        db.remove_account("acc2");
        db.delete_setting("session_cookie");
        let keys: Vec<String> = mem.map.lock().unwrap().keys().cloned().collect();
        assert_eq!(keys, vec![account_name("acc1")]);
    }

    #[test]
    fn a_refused_write_keeps_the_plaintext() {
        let mem = install_test_store();
        mem.fail_writes.store(true, std::sync::atomic::Ordering::Relaxed);
        let db = crate::db::Db::open(std::path::Path::new(":memory:")).unwrap();
        db.set_setting("session_cookie", "SAPISID=x");
        let raw: String = db.with_conn(|c| {
            c.query_row("SELECT value FROM settings WHERE key = 'session_cookie'", [], |r| r.get(0))
                .unwrap()
        });
        assert_eq!(raw, "SAPISID=x");
        assert_eq!(db.get_setting("session_cookie").as_deref(), Some("SAPISID=x"));
    }

    #[test]
    fn a_cookie_under_the_old_service_moves_to_the_new_one_on_first_read() {
        let (current, legacy): (&'static Memory, &'static Memory) =
            (Box::leak(Box::default()), Box::leak(Box::default()));
        legacy.map.lock().unwrap().insert(SESSION.into(), "SAPISID=old".into());
        let store = Migrating::new(current, legacy);
        assert_eq!(store.get(SESSION).unwrap().as_deref(), Some("SAPISID=old"));
        assert_eq!(
            current.map.lock().unwrap().get(SESSION).map(String::as_str),
            Some("SAPISID=old")
        );
        // Later reads come from the new service; the old item is still there for the old app.
        legacy.map.lock().unwrap().insert(SESSION.into(), "SAPISID=stale".into());
        assert_eq!(store.get(SESSION).unwrap().as_deref(), Some("SAPISID=old"));
        // New writes only go to the new service; nothing anywhere reads as nothing.
        store.set("account:a", "x").unwrap();
        assert!(legacy.map.lock().unwrap().get("account:a").is_none());
        assert_eq!(store.get("account:none").unwrap(), None);
        // Sign-out clears both.
        store.delete(SESSION).unwrap();
        assert!(!current.map.lock().unwrap().contains_key(SESSION));
        assert!(!legacy.map.lock().unwrap().contains_key(SESSION));
        assert_eq!(store.get(SESSION).unwrap(), None);
    }

    #[test]
    fn a_lost_keychain_item_reads_as_signed_out() {
        install_test_store();
        assert_eq!(unseal(SESSION, SEALED.into()), None);
        assert_eq!(unseal(SESSION, "plain".into()).as_deref(), Some("plain"));
    }

    #[test]
    fn debug_builds_stay_out_of_the_keychain_by_default() {
        if std::env::var("ENCORE_KEYCHAIN").is_err() {
            assert!(!wanted(), "tests are a debug build");
        }
    }
}
