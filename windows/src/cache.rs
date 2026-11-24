use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::{self, File, Metadata};
use std::io::{self, Write};
use std::os::windows::{ffi::OsStrExt, fs::MetadataExt};
use std::path::{Path, PathBuf};

use windows_sys::Win32::Foundation::{CloseHandle, ERROR_NO_MORE_FILES, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_OFFLINE, FILE_ATTRIBUTE_REPARSE_POINT, MoveFileW,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};

const BROWSER_CACHES: &[&str] = &["Cache", "Code Cache", "GPUCache"];
const CODE_CACHES: &[&str] = &["Cache", "Code Cache", "GPUCache", "CachedData"];

#[derive(Clone, Copy, Deserialize, Serialize)]
enum App {
    Chrome,
    Edge,
    Brave,
    Code,
}

impl App {
    const ALL: [Self; 4] = [Self::Chrome, Self::Edge, Self::Brave, Self::Code];

    fn spec(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::Chrome => ("Chrome", "chrome.exe", r"Google\Chrome\User Data"),
            Self::Edge => ("Edge", "msedge.exe", r"Microsoft\Edge\User Data"),
            Self::Brave => (
                "Brave",
                "brave.exe",
                r"BraveSoftware\Brave-Browser\User Data",
            ),
            Self::Code => ("VS Code", "code.exe", "Code"),
        }
    }

    fn is_browser(self) -> bool {
        !matches!(self, Self::Code)
    }

    fn caches(self) -> &'static [&'static str] {
        if self.is_browser() {
            BROWSER_CACHES
        } else {
            CODE_CACHES
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
struct CacheKey {
    app: App,
    profile: Option<String>,
    folder: String,
}

impl CacheKey {
    fn label(&self) -> String {
        let (app, _, _) = self.app.spec();
        match &self.profile {
            Some(profile) => format!("{app} · {profile} / {}", self.folder),
            None => format!("{app} · {}", self.folder),
        }
    }

    fn location<'a>(&self, roots: &'a Roots) -> io::Result<(&'a Path, PathBuf)> {
        let mut relative = PathBuf::from(self.app.spec().2);
        match (&self.profile, self.app.is_browser()) {
            (Some(profile), true) if browser_profile(profile) => relative.push(profile),
            (None, false) => (),
            _ => return Err(io::Error::other("Unrecognized browser profile.")),
        }
        if !self.app.caches().contains(&self.folder.as_str()) {
            return Err(io::Error::other("Unrecognized cache folder."));
        }
        relative.push(&self.folder);
        let root = roots.for_app(self.app);
        Ok((root, root.join(relative)))
    }
}

#[derive(Clone)]
pub struct Roots {
    pub(crate) local: PathBuf,
    pub(crate) roaming: PathBuf,
}

impl Roots {
    pub fn current() -> io::Result<Self> {
        fn location(var: &str) -> io::Result<PathBuf> {
            std::env::var_os(var)
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .ok_or_else(|| io::Error::other(format!("{var} is unavailable.")))
        }
        Ok(Self {
            local: location("LOCALAPPDATA")?,
            roaming: location("APPDATA")?,
        })
    }

    fn for_app(&self, app: App) -> &Path {
        if app.is_browser() {
            &self.local
        } else {
            &self.roaming
        }
    }

    pub fn recovery(&self) -> PathBuf {
        self.local.join(r"Diskfolio\Recovery")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Entry {
    attributes: u32,
    created: u64,
    modified: u64,
    size: u64,
}

type Snapshot = BTreeMap<PathBuf, Entry>;

#[derive(Clone)]
pub struct Candidate {
    key: CacheKey,
    pub path: PathBuf,
    pub bytes: u64,
    state: Snapshot,
}

impl Candidate {
    pub fn label(&self) -> String {
        self.key.label()
    }
}

#[derive(Default)]
pub struct Review {
    pub candidates: Vec<Candidate>,
    pub skipped: usize,
}

#[derive(Clone)]
pub struct Recovery {
    key: CacheKey,
    record: PathBuf,
    pub path: PathBuf,
}

impl Recovery {
    pub fn label(&self) -> String {
        self.key.label()
    }
}

pub fn preview(roots: &Roots) -> Review {
    let mut review = Review::default();
    for app in App::ALL {
        let base = roots.for_app(app).join(app.spec().2);
        match checked_dir(&base) {
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(_) => {
                review.skipped += 1;
                continue;
            }
        }
        let profiles = if app.is_browser() {
            match fs::read_dir(&base) {
                Ok(children) => children
                    .filter_map(|child| match child {
                        Ok(child) => child
                            .file_name()
                            .into_string()
                            .ok()
                            .filter(|name| browser_profile(name))
                            .map(Some),
                        Err(_) => {
                            review.skipped += 1;
                            None
                        }
                    })
                    .collect(),
                Err(_) => {
                    review.skipped += 1;
                    continue;
                }
            }
        } else {
            vec![None]
        };
        for profile in profiles {
            for folder in app.caches() {
                let key = CacheKey {
                    app,
                    profile: profile.clone(),
                    folder: (*folder).to_owned(),
                };
                let Ok((_, path)) = key.location(roots) else {
                    continue;
                };
                match fs::symlink_metadata(&path) {
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(_) => {
                        review.skipped += 1;
                        continue;
                    }
                    Ok(_) => (),
                }
                match snapshot(&path) {
                    Ok((bytes, state)) if bytes > 0 => review.candidates.push(Candidate {
                        key,
                        path,
                        bytes,
                        state,
                    }),
                    Ok(_) => (),
                    Err(_) => review.skipped += 1,
                }
            }
        }
    }
    review
        .candidates
        .sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.path.cmp(&b.path)));
    review
}

pub fn move_to_recovery(roots: &Roots, item: &Candidate) -> io::Result<()> {
    let (_, path) = item.key.location(roots)?;
    ensure_closed(item.key.app)?;
    if path != item.path || snapshot(&path)?.1 != item.state {
        return Err(io::Error::other("The cache changed. Scan again."));
    }
    checked_dir(&roots.local)?;
    let recovery = roots.recovery();
    for dir in [roots.local.join("Diskfolio"), recovery.clone()] {
        match fs::create_dir(&dir) {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error),
        }
        checked_dir(&dir)?;
    }
    let record = tempfile::Builder::new()
        .prefix("cache-")
        .tempdir_in(&recovery)?;
    let mut manifest = File::create(record.path().join("source.json"))?;
    serde_json::to_writer(&mut manifest, &item.key)?;
    manifest.flush()?;
    manifest.sync_all()?;
    ensure_closed(item.key.app)?;
    checked_dir(&path)?;
    let kept = record.keep();
    if let Err(error) = move_without_replacing(&path, &kept.join("cache")) {
        let _ = fs::remove_file(kept.join("source.json"));
        let _ = fs::remove_dir(kept);
        return Err(error);
    }
    Ok(())
}

pub fn recovery_items(roots: &Roots) -> io::Result<Vec<Recovery>> {
    let location = roots.recovery();
    match checked_dir(&location) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        result => result?,
    };
    let mut items: Vec<_> = fs::read_dir(location)?
        .filter_map(|child| read_recovery(roots, child.ok()?.path()).ok())
        .collect();
    items.sort_by_key(Recovery::label);
    Ok(items)
}

fn read_recovery(roots: &Roots, record: PathBuf) -> io::Result<Recovery> {
    if record.parent() != Some(roots.recovery().as_path()) {
        return Err(io::Error::other("Invalid recovery folder."));
    }
    checked_dir(&record.join("cache"))?;
    let source = record.join("source.json");
    let meta = checked_metadata(&source)?;
    if !meta.is_file() || meta.len() > 4096 {
        return Err(io::Error::other("Invalid recovery record."));
    }
    let key: CacheKey = serde_json::from_reader(File::open(source)?)?;
    let (_, path) = key.location(roots)?;
    Ok(Recovery { key, record, path })
}

pub fn restore(roots: &Roots, item: &Recovery) -> io::Result<()> {
    let actual = read_recovery(roots, item.record.clone())?;
    ensure_closed(actual.key.app)?;
    let parent = actual
        .path
        .parent()
        .ok_or_else(|| io::Error::other("Invalid cache path."))?;
    checked_dir(parent)?;
    match fs::symlink_metadata(&actual.path) {
        Ok(_) => {
            return Err(io::Error::other(
                "The app already has a cache at this location. Move that cache to recovery first.",
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error),
    }
    move_without_replacing(&actual.record.join("cache"), &actual.path)?;
    let _ = fs::remove_file(actual.record.join("source.json"));
    let _ = fs::remove_dir(actual.record);
    Ok(())
}

fn browser_profile(name: &str) -> bool {
    name == "Default"
        || name.strip_prefix("Profile ").is_some_and(|number| {
            !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
        })
}

fn checked_metadata(path: &Path) -> io::Result<Metadata> {
    let data = fs::symlink_metadata(path)?;
    if data.file_attributes() & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_OFFLINE) != 0 {
        return Err(io::Error::other("Linked and offline paths are skipped."));
    }
    Ok(data)
}

fn checked_dir(path: &Path) -> io::Result<()> {
    for ancestor in path.ancestors().collect::<Vec<_>>().into_iter().rev() {
        if !checked_metadata(ancestor)?.is_dir() {
            return Err(io::Error::other("The cache path is not a directory."));
        }
    }
    Ok(())
}

fn snapshot(path: &Path) -> io::Result<(u64, Snapshot)> {
    checked_dir(path)?;
    fn walk(path: &Path, depth: usize, state: &mut Snapshot) -> io::Result<u64> {
        if depth >= 128 {
            return Err(io::Error::other("The cache path is too deep."));
        }
        fn identity(meta: &Metadata) -> Entry {
            Entry {
                attributes: meta.file_attributes(),
                created: meta.creation_time(),
                modified: meta.last_write_time(),
                size: meta.file_size(),
            }
        }
        let meta = checked_metadata(path)?;
        let entry = identity(&meta);
        let bytes = if meta.is_dir() {
            let mut bytes = 0u64;
            for child in fs::read_dir(path)? {
                bytes = bytes
                    .checked_add(walk(&child?.path(), depth + 1, state)?)
                    .ok_or_else(|| io::Error::other("The cache is too large to total."))?;
            }
            bytes
        } else if meta.is_file() {
            meta.len()
        } else {
            return Err(io::Error::other("Unsupported file type."));
        };
        if identity(&checked_metadata(path)?) != entry {
            return Err(io::Error::other("The cache changed. Scan again."));
        }
        state.insert(path.to_owned(), entry);
        Ok(bytes)
    }
    let mut entries = BTreeMap::new();
    let bytes = walk(path, 0, &mut entries)?;
    checked_dir(path)?;
    Ok((bytes, entries))
}

fn ensure_closed(app: App) -> io::Result<()> {
    let (name, image, _) = app.spec();
    // The handle and entry are valid only for the current process snapshot.
    unsafe {
        let handle = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        let mut entry = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(handle, &mut entry) == 0 {
            let error = io::Error::last_os_error();
            CloseHandle(handle);
            return Err(error);
        }
        let running = loop {
            let len = entry
                .szExeFile
                .iter()
                .position(|unit| *unit == 0)
                .unwrap_or(entry.szExeFile.len());
            if String::from_utf16_lossy(&entry.szExeFile[..len]).eq_ignore_ascii_case(image) {
                break Ok(true);
            }
            if Process32NextW(handle, &mut entry) == 0 {
                let error = io::Error::last_os_error();
                break if error.raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
                    Ok(false)
                } else {
                    Err(error)
                };
            }
        };
        CloseHandle(handle);
        if running? {
            return Err(io::Error::other(format!(
                "Quit {name} before moving its cache."
            )));
        }
    }
    Ok(())
}

fn move_without_replacing(source: &Path, destination: &Path) -> io::Result<()> {
    fn wide(path: &Path) -> Vec<u16> {
        OsStr::new(path).encode_wide().chain([0]).collect()
    }
    let source = wide(source);
    let destination = wide(destination);
    // MoveFileW refuses existing destinations and cannot copy a directory across volumes.
    if unsafe { MoveFileW(source.as_ptr(), destination.as_ptr()) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(dir: &tempfile::TempDir) -> io::Result<(Roots, PathBuf, PathBuf)> {
        let local = dir.path().join("Local");
        let roaming = dir.path().join("Roaming");
        let profile = local.join(App::Brave.spec().2).join("Profile 3");
        let cache = profile.join("Cache");
        fs::create_dir_all(&cache)?;
        fs::create_dir(&roaming)?;
        fs::write(cache.join("a.bin"), b"12345")?;
        let preferences = profile.join("Preferences");
        fs::write(&preferences, b"keep")?;
        Ok((Roots { local, roaming }, cache, preferences))
    }

    #[test]
    fn preview_move_and_restore_preserve_profile_data() -> io::Result<()> {
        let dir = tempfile::tempdir()?;
        let (roots, cache, preferences) = fixture(&dir)?;

        let mut items = preview(&roots).candidates;
        assert_eq!(items.len(), 1);
        let candidate = items.pop().unwrap();
        assert_eq!(candidate.bytes, 5);
        assert_eq!(candidate.path, cache);
        assert_eq!(fs::read(cache.join("a.bin"))?, b"12345");

        fs::write(cache.join("a.bin"), b"changed")?;
        assert!(move_to_recovery(&roots, &candidate).is_err());
        assert_eq!(fs::read(cache.join("a.bin"))?, b"changed");

        let candidate = preview(&roots).candidates.pop().unwrap();
        move_to_recovery(&roots, &candidate)?;
        assert!(!cache.exists());
        assert!(preview(&roots).candidates.is_empty());
        let mut items = recovery_items(&roots)?;
        assert_eq!(items.len(), 1);
        let recovery = items.pop().unwrap();

        fs::create_dir(&cache)?;
        assert!(restore(&roots, &recovery).is_err());
        fs::remove_dir(&cache)?;
        restore(&roots, &recovery)?;
        assert_eq!(fs::read(cache.join("a.bin"))?, b"changed");
        assert_eq!(fs::read(preferences)?, b"keep");
        assert!(recovery_items(&roots)?.is_empty());
        Ok(())
    }

    #[test]
    fn recovery_manifest_cannot_target_non_cache_data() -> io::Result<()> {
        let dir = tempfile::tempdir()?;
        let (roots, _, preferences) = fixture(&dir)?;
        let record = roots.recovery().join("cache-fixture");
        fs::create_dir_all(record.join("cache"))?;
        fs::write(
            record.join("source.json"),
            br#"{"app":"Brave","profile":"Profile 3","folder":"Preferences"}"#,
        )?;
        assert!(recovery_items(&roots)?.is_empty());
        assert_eq!(fs::read(preferences)?, b"keep");
        Ok(())
    }
}
