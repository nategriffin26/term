use std::net::IpAddr;

use crate::{Connection, Error, Result};

const FALLBACK_PATHS: [&str; 2] = ["/opt/homebrew/bin/mosh-server", "/usr/local/bin/mosh-server"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MoshConnect {
    pub ip: IpAddr,
    pub port: u16,
    /// 22-character base64 session key.
    pub key: String,
    pub pid: u32,
}

/// Starts a mosh-server over SSH and returns where to reach it.
///
/// `server_path` and `command` are shell text, interpreted by the remote
/// login shell. With no `server_path`, a missing `mosh-server` (exit 127)
/// falls back to the Homebrew locations, because non-interactive SSH on macOS
/// has no Homebrew PATH.
pub async fn mosh_bootstrap(
    conn: &Connection,
    server_path: Option<&str>,
    command: Option<&str>,
    idle_timeout: u32,
) -> Result<MoshConnect> {
    let candidates: Vec<&str> = match server_path {
        Some(path) => vec![path],
        None => std::iter::once("mosh-server")
            .chain(FALLBACK_PATHS)
            .collect(),
    };
    let tail = command.map(|c| format!(" -- {c}")).unwrap_or_default();
    let timeout = if idle_timeout == 0 { String::new() }
        else { format!("MOSH_SERVER_NETWORK_TMOUT={idle_timeout} ") };

    let mut last_stderr = String::new();
    for server in &candidates {
        let out = conn
            .exec(&format!("{timeout}{server} new -s -c 256 -l LANG=en_US.UTF-8{tail}"))
            .await?;
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if out.exit_status == 0 {
            let mut result = parse_connect(&stdout, conn.peer_ip()).ok_or_else(|| {
                Error::Mosh(format!(
                    "{server} printed no MOSH CONNECT line. stderr: {stderr}"
                ))
            })?;
            result.pid = parse_pid(&stderr).ok_or_else(|| Error::Mosh(format!(
                "{server} printed no detached server pid. stderr: {stderr}"
            )))?;
            return Ok(result);
        }
        if out.exit_status != 127 {
            return Err(Error::Mosh(format!(
                "{server} exited {}: {stderr}",
                out.exit_status
            )));
        }
        last_stderr = stderr;
    }
    Err(Error::Mosh(format!(
        "mosh-server not found on the host (tried {}): {last_stderr}",
        candidates.join(", ")
    )))
}

/// Only signal the login user's mosh-server, never a reused PID of another program.
pub fn end_server_command(pid: u32) -> String {
    format!("case \"$(ps -p {pid} -o comm=)\" in mosh-server|*/mosh-server) \
        if [ \"$(ps -p {pid} -o uid= | tr -d ' ')\" = \"$(id -u)\" ]; then \
        kill -TERM {pid} 2>/dev/null || :; fi;; esac; ")
}

fn parse_pid(stderr: &str) -> Option<u32> {
    stderr.lines().find_map(|line| {
        line.trim().strip_prefix("[mosh-server detached, pid = ")?
            .strip_suffix(']')?.parse::<u32>().ok().filter(|&pid| pid > 1)
    })
}

fn parse_connect(stdout: &str, ip: IpAddr) -> Option<MoshConnect> {
    stdout.lines().find_map(|line| {
        let mut words = line.trim().split_ascii_whitespace();
        if (words.next()?, words.next()?) != ("MOSH", "CONNECT") {
            return None;
        }
        let port = words.next()?.parse().ok()?;
        let key = words.next()?;
        let valid_key = key.len() == 22
            && key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/');
        if !valid_key || words.next().is_some() {
            return None;
        }
        Some(MoshConnect {
            ip,
            port,
            key: key.to_string(),
            pid: 0,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const IP: IpAddr = IpAddr::V4(std::net::Ipv4Addr::LOCALHOST);

    #[test]
    fn finds_connect_line_among_noise() {
        let out = "Welcome\n\nMOSH CONNECT 60001 AbCdEfGhIjKlMnOpQrStUv\n\n[mosh-server detached, pid = 5]\n";
        let c = parse_connect(out, IP).unwrap();
        assert_eq!((c.port, c.key.as_str()), (60001, "AbCdEfGhIjKlMnOpQrStUv"));
    }

    #[test]
    fn rejects_malformed_lines() {
        for bad in [
            "MOSH CONNECT 70000 AbCdEfGhIjKlMnOpQrStUv",
            "MOSH CONNECT 6001 short",
            "MOSH CONNECT x AbCdEfGhIjKlMnOpQrStUv",
            "MOSH CONNECT 6001 AbCdEfGhIjKlMnOpQrStUv extra",
            "xMOSH CONNECT 6001 AbCdEfGhIjKlMnOpQrStUv",
            "",
        ] {
            assert!(parse_connect(bad, IP).is_none(), "{bad}");
        }
    }
}
