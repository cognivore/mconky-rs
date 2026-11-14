//! A receipt is evidence of a completed backup, never merely a configured timer.
use std::{fs, path::PathBuf, time::{Duration, SystemTime, UNIX_EPOCH}};
use wallstats::{App, CollectError, ConfigError, Schedule, Stat, Text, Widget};

pub struct BackupWidgets { pub copies: Widget, pub disk: Widget }

pub fn install(app: &mut App, host: &str, receipts: PathBuf) -> Result<BackupWidgets, ConfigError> {
    Ok(BackupWidgets {
        copies: evidence(app, host, receipts.clone(), false)?,
        disk: evidence(app, host, receipts, true)?,
    })
}

fn evidence(app: &mut App, host: &str, receipts: PathBuf, disk: bool) -> Result<Widget, ConfigError> {
    let host = host.to_owned();
    let suffix = if disk { "snapshot" } else { "backups" };
    let metric = app.metric::<Text>(format!("{host}.{suffix}"), Schedule::every(Duration::from_secs(60)), move || {
        if !disk {
            return application_backup(&host);
        }
        let data = match fs::read(&receipts) {
            Ok(data) if data.len() <= 65536 => data,
            Ok(_) => return Err(CollectError::new("Fleet backup receipt exceeds 64 KiB")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok("No verified backup receipt".to_owned()),
            Err(error) => return Err(CollectError::new(format!("Cannot read fleet backup receipt: {error}"))),
        };
        let value: serde_json::Value = serde_json::from_slice(&data)
            .map_err(|error| CollectError::new(format!("Invalid fleet backup receipt: {error}")))?;
        if value["version"].as_u64() != Some(1) {
            return Err(CollectError::new("Unsupported fleet backup receipt version"));
        }
        let receipt = &value["hosts"][&host];
        let now = SystemTime::now().duration_since(UNIX_EPOCH)
            .map_err(|_| CollectError::new("System clock precedes the backup epoch"))?.as_secs();
        let age = |key: &str| -> String {
            match receipt[key].as_u64().and_then(|at| now.checked_sub(at)) {
                None => "not verified".to_owned(),
                Some(seconds) if seconds > 36 * 3600 => format!("STALE {}h", seconds / 3600),
                Some(seconds) if seconds < 3600 => format!("{}m", seconds / 60),
                Some(seconds) => format!("{}h", seconds / 3600),
            }
        };
        if disk {
            if receipt["snapshot_checked_epoch"].as_u64().is_none_or(|at| now.saturating_sub(at) > 1800) {
                return Ok("Status needs refresh".to_owned());
            }
            Ok(match receipt["snapshot_state"].as_str() {
                Some("pending") => format!("Creating · {}", receipt["snapshot_progress"].as_str().unwrap_or("in progress")),
                Some("error") => "Snapshot failed".to_owned(),
                _ if receipt["snapshot_epoch"].as_u64().is_some() => format!("Saved · {}", age("snapshot_epoch")),
                _ => "No disk snapshot yet".to_owned(),
            })
        } else {
            Ok(format!("Mac {} · S3 {}", age("local_capture_epoch"), age("cloud_capture_epoch")))
        }
    })?;
    Ok(Stat::new(if disk { "AWS disk" } else { "backups" }, metric).into())
}

fn application_backup(host: &str) -> Result<String, CollectError> {
    if !["dune-aws", "x1-aws", "web-aws"].contains(&host) {
        return Err(CollectError::new("Backup monitor received an unknown fleet host"));
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| CollectError::new("Cannot locate the Mac backup directory: HOME is absent"))?;
    let root = PathBuf::from(home).join(".local/state/permanent-vacation/application-backups").join(host);
    let path = root.join("latest.json");
    let metadata = match fs::metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok("Awaiting verified Mac copy".to_owned()),
        Err(error) => return Err(CollectError::new(format!("Cannot inspect {host} backup receipt: {error}"))),
    };
    if metadata.len() > 65536 { return Err(CollectError::new("Application backup receipt exceeds 64 KiB")); }
    let data = fs::read(&path).map_err(|error| CollectError::new(format!("Cannot read {host} backup receipt: {error}")))?;
    let receipt: serde_json::Value = serde_json::from_slice(&data)
        .map_err(|error| CollectError::new(format!("Invalid {host} backup receipt: {error}")))?;
    if receipt["version"] != 1 || receipt["node"] != host
        || receipt["cloudReadBackVerified"] != true || receipt["vaultKeyDecryptionVerified"] != true
        || receipt["sqliteIntegrityVerified"] != true
        || (host == "x1-aws" && receipt["nativeZulipArchiveVerified"] != true)
        || (host != "x1-aws" && receipt["fileArchiveVerified"] != true) {
        return Err(CollectError::new(format!("{host} backup lacks the required cloud, decryption or database verification")));
    }
    let epoch = receipt["epoch"].as_u64().ok_or_else(|| CollectError::new("Backup capture time is missing"))?;
    let expected_archive = format!("{host}-{epoch}.tar.gz.age");
    if receipt["archive"] != expected_archive { return Err(CollectError::new("Backup archive does not match its host and capture time")); }
    let archive = fs::metadata(root.join(expected_archive))
        .map_err(|error| CollectError::new(format!("Verified {host} Mac archive is unavailable: {error}")))?;
    if receipt["bytes"].as_u64() != Some(archive.len()) || archive.len() == 0 {
        return Err(CollectError::new("Mac archive size disagrees with its verification receipt"));
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH)
        .map_err(|_| CollectError::new("System clock precedes the backup epoch"))?.as_secs();
    let seconds = now.checked_sub(epoch).ok_or_else(|| CollectError::new("Backup capture time is in the future"))?;
    let age = if seconds < 3600 { format!("{}m", seconds / 60) } else { format!("{}h", seconds / 3600) };
    let phase = match receipt["phase"].as_str() {
        Some("production") if seconds > 9 * 3600 => "STALE",
        Some("production") => "Verified",
        Some("staging") => "Staging only",
        _ => return Err(CollectError::new("Backup receipt has an unknown deployment phase")),
    };
    Ok(format!("{phase} · Mac {age} · S3 {age}"))
}
