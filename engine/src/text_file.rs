use crate::collector::read_file_tail;
use crate::{CollectError, CollectResult};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

const DEFAULT_TAIL_BYTES: usize = 64 * 1024;

/// Maximum tail bytes accepted by [`TextFileSet`].
pub const MAX_TEXT_FILE_TAIL_BYTES: usize = 1024 * 1024;

type NameMatcher = dyn Fn(&str) -> bool + Send + Sync + 'static;

/// A cloneable, bounded view over selected regular text files in a directory.
#[derive(Clone)]
pub struct TextFileSet {
    directory: PathBuf,
    matcher: Arc<NameMatcher>,
    max_tail_bytes: usize,
}

impl TextFileSet {
    /// Creates a set that initially selects every filename and reads 64 KiB tails.
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
            matcher: Arc::new(|_| true),
            max_tail_bytes: DEFAULT_TAIL_BYTES,
        }
    }

    /// Replaces the filename predicate.
    pub fn matching(
        mut self,
        matcher: impl Fn(&str) -> bool + Send + Sync + 'static,
    ) -> Self {
        self.matcher = Arc::new(matcher);
        self
    }

    /// Sets the maximum bytes read from the end of each selected file.
    pub fn max_tail_bytes(mut self, max_tail_bytes: usize) -> Self {
        self.max_tail_bytes = max_tail_bytes;
        self
    }

    /// Reads matching regular files and sorts them newest-first.
    pub fn read(&self) -> CollectResult<Vec<TextFile>> {
        if self.directory.as_os_str().is_empty() {
            return Err(CollectError::new("text-file-set directory cannot be empty"));
        }
        if !(1..=MAX_TEXT_FILE_TAIL_BYTES).contains(&self.max_tail_bytes) {
            return Err(CollectError::new(format!(
                "text-file tail limit must contain 1 to {MAX_TEXT_FILE_TAIL_BYTES} bytes"
            )));
        }

        let entries = fs::read_dir(&self.directory).map_err(|error| {
            CollectError::new(format!(
                "cannot read text-file-set directory {}: {error}",
                self.directory.display()
            ))
        })?;
        let mut files = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|error| {
                CollectError::new(format!(
                    "cannot read an entry in {}: {error}",
                    self.directory.display()
                ))
            })?;
            let name = entry.file_name().into_string().map_err(|name| {
                CollectError::new(format!(
                    "filename in {} is not valid UTF-8: {}",
                    self.directory.display(),
                    name.to_string_lossy()
                ))
            })?;
            if !(self.matcher)(&name) {
                continue;
            }
            let path = entry.path();
            let file_type = entry.file_type().map_err(|error| {
                CollectError::new(format!("cannot inspect {}: {error}", path.display()))
            })?;
            if !file_type.is_file() {
                continue;
            }
            let metadata = entry.metadata().map_err(|error| {
                CollectError::new(format!("cannot read metadata for {}: {error}", path.display()))
            })?;
            let modified = metadata.modified().map_err(|error| {
                CollectError::new(format!(
                    "cannot read modification time for {}: {error}",
                    path.display()
                ))
            })?;
            checked_age(SystemTime::now(), modified, &path)?;
            let bytes = read_file_tail(&path, self.max_tail_bytes).map_err(|error| {
                CollectError::new(format!("cannot read text file {}: {error}", path.display()))
            })?;
            let tail = String::from_utf8(bytes).map_err(|error| {
                CollectError::new(format!(
                    "text file {} is not valid UTF-8: {error}",
                    path.display()
                ))
            })?;
            files.push(TextFile {
                path,
                name,
                modified,
                tail,
            });
        }
        sort_newest(&mut files);
        Ok(files)
    }
}

impl fmt::Debug for TextFileSet {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TextFileSet")
            .field("directory", &self.directory)
            .field("max_tail_bytes", &self.max_tail_bytes)
            .finish_non_exhaustive()
    }
}

/// A selected regular text file with a bounded tail held in memory.
#[derive(Clone, Debug)]
pub struct TextFile {
    path: PathBuf,
    name: String,
    modified: SystemTime,
    tail: String,
}

impl TextFile {
    /// Returns the full path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns the UTF-8 filename.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Returns the file modification time observed during the scan.
    pub fn modified(&self) -> SystemTime {
        self.modified
    }

    /// Returns the bounded tail text.
    pub fn tail(&self) -> &str {
        &self.tail
    }

    /// Reports whether the tail contains `needle`.
    pub fn contains(&self, needle: impl AsRef<str>) -> bool {
        self.tail.contains(needle.as_ref())
    }

    /// Reports whether the tail contains every supplied substring.
    pub fn contains_all<I, S>(&self, needles: I) -> bool
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        needles.into_iter().all(|needle| self.contains(needle))
    }

    /// Reports whether the tail contains any supplied substring.
    pub fn contains_any<I, S>(&self, needles: I) -> bool
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        needles.into_iter().any(|needle| self.contains(needle))
    }

    /// Returns elapsed time since the observed modification time.
    pub fn age(&self) -> CollectResult<Duration> {
        checked_age(SystemTime::now(), self.modified, &self.path)
    }
}

fn checked_age(now: SystemTime, modified: SystemTime, path: &Path) -> CollectResult<Duration> {
    now.duration_since(modified).map_err(|error| {
        CollectError::new(format!(
            "text file {} has a modification time in the future: {error}",
            path.display()
        ))
    })
}

fn sort_newest(files: &mut [TextFile]) {
    files.sort_by(|left, right| {
        right
            .modified
            .cmp(&left.modified)
            .then_with(|| right.name.cmp(&left.name))
    });
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_TEXT_FILE_TAIL_BYTES, TextFile, TextFileSet, checked_age, sort_newest,
    };
    use crate::{CollectError, CollectResult, StatusLight};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, SystemTime};

    static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let serial = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "wallstats-text-set-test-{}-{serial}",
                std::process::id()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn file(&self, name: &str, contents: impl AsRef<[u8]>) {
            let path = self.0.join(name);
            fs::write(&path, contents).unwrap();
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn selects_regular_files_and_sorts_newest_first() {
        let directory = TestDirectory::new();
        directory.file("older.log", "old");
        directory.file("newer.log", "new");
        directory.file("ignored.txt", "ignore");
        fs::create_dir(directory.0.join("directory.log")).unwrap();

        let set = TextFileSet::new(&directory.0).matching(|name| name.ends_with(".log"));
        let files = set.clone().read().unwrap();
        assert_eq!(
            files.iter().map(TextFile::name).collect::<Vec<_>>(),
            ["newer.log", "older.log"]
        );
        assert_eq!(files[0].tail(), "new");
        assert_eq!(files[0].path(), directory.0.join("newer.log"));
        let _modified = files[0].modified();

        let now = SystemTime::now();
        let mut synthetic = vec![
            text_file("older.log", "old", now - Duration::from_secs(20)),
            text_file("newer.log", "new", now - Duration::from_secs(5)),
        ];
        sort_newest(&mut synthetic);
        assert_eq!(
            synthetic.iter().map(TextFile::name).collect::<Vec<_>>(),
            ["newer.log", "older.log"]
        );
    }

    #[test]
    fn bounded_tail_discards_a_leading_partial_line_and_supports_predicates() {
        let directory = TestDirectory::new();
        directory.file(
            "events.log",
            "old line\nkeep one\nkeep two\n",
        );
        let files = TextFileSet::new(&directory.0)
            .max_tail_bytes(17)
            .read()
            .unwrap();
        let file = &files[0];
        assert_eq!(file.tail(), "keep two\n");
        assert!(file.tail().len() <= 17);
        assert!(file.contains("two"));
        assert!(file.contains_all(["keep", "two"]));
        assert!(file.contains_any(["missing", "two"]));
        assert!(!file.contains_all(["keep", "missing"]));
    }

    #[test]
    fn filesystem_utf8_limits_and_future_times_are_explicit_errors() {
        let directory = TestDirectory::new();
        assert!(TextFileSet::new(directory.0.join("missing")).read().is_err());
        assert!(
            TextFileSet::new(&directory.0)
                .max_tail_bytes(0)
                .read()
                .is_err()
        );
        assert!(
            TextFileSet::new(&directory.0)
                .max_tail_bytes(MAX_TEXT_FILE_TAIL_BYTES + 1)
                .read()
                .is_err()
        );

        directory.file("invalid.log", [0xff, 0xfe]);
        assert!(
            TextFileSet::new(&directory.0)
                .matching(|name| name == "invalid.log")
                .read()
                .is_err()
        );

        assert!(
            checked_age(
                SystemTime::now(),
                SystemTime::now() + Duration::from_secs(60),
                Path::new("future.log")
            )
            .is_err()
        );
    }

    fn classify(logs: &[TextFile]) -> CollectResult<StatusLight> {
        let latest = logs
            .first()
            .ok_or_else(|| CollectError::new("no backup logs"))?;
        let _saved = logs
            .iter()
            .find(|log| log.contains_all(["snapshot ", " saved"]))
            .ok_or_else(|| CollectError::new("no saved snapshot"))?;
        if latest.contains("FATAL:") {
            Ok(StatusLight::Red)
        } else if latest.contains("Warning: at least one source file could not be read") {
            Ok(StatusLight::Amber)
        } else if latest.contains_all(["snapshot ", " saved"]) {
            Ok(StatusLight::Green)
        } else if latest.age()? <= Duration::from_secs(5 * 60) {
            Ok(StatusLight::Blue)
        } else {
            Ok(StatusLight::Red)
        }
    }

    fn classify_case(latest: &str, latest_age: Duration) -> StatusLight {
        let now = SystemTime::now();
        let mut logs = vec![
            text_file(
                "backup-home-1.log",
                "snapshot old saved\n",
                now - Duration::from_secs(600),
            ),
            text_file("backup-home-2.log", latest, now - latest_age),
        ];
        sort_newest(&mut logs);
        classify(&logs).unwrap()
    }

    fn text_file(name: &str, tail: &str, modified: SystemTime) -> TextFile {
        TextFile {
            path: PathBuf::from(name),
            name: name.to_owned(),
            modified,
            tail: tail.to_owned(),
        }
    }

    #[test]
    fn inline_policy_can_classify_backup_cases() {
        assert_eq!(
            classify_case("FATAL: repository locked\n", Duration::from_secs(1)),
            StatusLight::Red
        );
        assert_eq!(
            classify_case(
                "snapshot abc saved\nWarning: at least one source file could not be read\n",
                Duration::from_secs(1)
            ),
            StatusLight::Amber
        );
        assert_eq!(
            classify_case("snapshot abc saved\n", Duration::from_secs(1)),
            StatusLight::Green
        );
        assert_eq!(
            classify_case("still running\n", Duration::from_secs(1)),
            StatusLight::Blue
        );
    }
}
