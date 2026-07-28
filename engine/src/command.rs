use crate::{CollectError, CollectResult};
use std::io::{self, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;

pub(crate) fn run_bounded(
    executable: &Path,
    arguments: &[&str],
    limit: usize,
) -> CollectResult<Vec<u8>> {
    let mut child = Command::new(executable)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            CollectError::new(format!(
                "cannot start command {}: {error}",
                executable.display()
            ))
        })?;
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(CollectError::new("command stdout pipe is unavailable"));
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(CollectError::new("command stderr pipe is unavailable"));
        }
    };

    let stdout_reader = thread::Builder::new()
        .name("wallstats-command-stdout".to_owned())
        .spawn(move || read_bounded(stdout, limit))
        .map_err(|error| {
            let _ = child.kill();
            let _ = child.wait();
            CollectError::new(format!("cannot start stdout reader: {error}"))
        })?;
    let stderr_reader = match thread::Builder::new()
        .name("wallstats-command-stderr".to_owned())
        .spawn(move || read_bounded(stderr, limit))
    {
        Ok(reader) => reader,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            return Err(CollectError::new(format!(
                "cannot start stderr reader: {error}"
            )));
        }
    };

    let status = match child.wait() {
        Ok(status) => status,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(CollectError::new(format!(
                "cannot wait for command {}: {error}",
                executable.display()
            )));
        }
    };
    let stdout = join_reader(stdout_reader, "stdout")?;
    let stderr = join_reader(stderr_reader, "stderr")?;
    if stdout.exceeded || stderr.exceeded {
        return Err(CollectError::new(format!(
            "command {} output exceeds the {limit}-byte limit",
            executable.display()
        )));
    }
    if !status.success() {
        let detail = String::from_utf8_lossy(&stderr.bytes);
        let detail = detail.trim();
        return Err(CollectError::new(if detail.is_empty() {
            format!("command {} exited with {status}", executable.display())
        } else {
            format!(
                "command {} exited with {status}: {detail}",
                executable.display()
            )
        }));
    }
    Ok(stdout.bytes)
}

struct BoundedRead {
    bytes: Vec<u8>,
    exceeded: bool,
}

fn read_bounded(mut reader: impl Read, limit: usize) -> io::Result<BoundedRead> {
    let mut bytes = Vec::new();
    let mut exceeded = false;
    let mut chunk = [0_u8; 8192];
    loop {
        let read = reader.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        let remaining = limit.saturating_sub(bytes.len());
        let retained = remaining.min(read);
        bytes.extend_from_slice(&chunk[..retained]);
        exceeded |= retained < read;
    }
    Ok(BoundedRead { bytes, exceeded })
}

fn join_reader(
    reader: thread::JoinHandle<io::Result<BoundedRead>>,
    stream: &str,
) -> CollectResult<BoundedRead> {
    reader
        .join()
        .map_err(|_| CollectError::new(format!("{stream} reader panicked")))?
        .map_err(|error| CollectError::new(format!("cannot read command {stream}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::read_bounded;
    use std::io::Cursor;

    #[test]
    fn bounded_reader_drains_but_retains_only_the_limit() {
        let result = read_bounded(Cursor::new(vec![b'x'; 20]), 8).unwrap();
        assert_eq!(result.bytes, vec![b'x'; 8]);
        assert!(result.exceeded);
    }
}
