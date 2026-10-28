//! The web link at a tapped cell (term.h `term_session_link`): an http(s) URL
//! written in the text around it, across soft-wrapped rows.

use vt::RowText;

/// Rows joined each way from the tapped one: a 4 KB URL on a 64-column screen.
const MAX_JOINED_ROWS: u32 = 64;

/// Whether `uri` is an http or https URL, the only links a tap opens.
pub(crate) fn is_web(uri: &str) -> bool {
    starts_with_ignoring_case(uri.chars(), "http://") || starts_with_ignoring_case(uri.chars(), "https://")
}

/// The http(s) URL written through the cell at `col` on row `row`, the rows
/// it soft-wraps across joined; a `www.` host is given `https://`. `row_at`
/// reads a row (None past either end).
pub(crate) fn text_url(row_at: impl Fn(u32) -> Option<RowText>, col: u16, row: u32) -> Option<String> {
    let tapped = row_at(row)?;
    let mut before = Vec::new();
    let mut r = row;
    while r > 0 && row - r < MAX_JOINED_ROWS {
        match row_at(r - 1) {
            Some(prev) if prev.wrapped => before.push(prev),
            _ => break,
        }
        r -= 1;
    }
    let mut chars: Vec<char> = before.iter().rev().flat_map(|row| row.chars.iter().map(|&(_, ch)| ch)).collect();
    let at = chars.len() + cell_index(&tapped, col)?;
    chars.extend(tapped.chars.iter().map(|&(_, ch)| ch));
    let mut wrapped = tapped.wrapped;
    let mut r = row;
    while wrapped && r - row < MAX_JOINED_ROWS {
        r += 1;
        let Some(next) = row_at(r) else { break };
        chars.extend(next.chars.iter().map(|&(_, ch)| ch));
        wrapped = next.wrapped;
    }
    url_at(&chars, at)
}

/// The index in `row.chars` of the character drawn at `col` (the left half
/// when `col` is a wide glyph's right half); None past the row's text.
fn cell_index(row: &RowText, col: u16) -> Option<usize> {
    let i = row.chars.iter().rposition(|&(c, _)| c <= col)?;
    let c = row.chars[i].0;
    let spacer = c + 1 == col && row.chars.get(i + 1).is_some_and(|&(next, _)| next > col);
    // The first character of the cell, so a cluster's later ones never start a URL search mid-cell.
    (c == col || spacer).then(|| row.chars.iter().position(|&(cc, _)| cc == c).unwrap_or(i))
}

/// The URL in `chars` covering index `at`, trailing punctuation left out.
fn url_at(chars: &[char], at: usize) -> Option<String> {
    if !is_url_char(*chars.get(at)?) {
        return None;
    }
    let start = chars[..at].iter().rposition(|&c| !is_url_char(c)).map_or(0, |i| i + 1);
    let end = chars[at..].iter().position(|&c| !is_url_char(c)).map_or(chars.len(), |i| at + i);
    let run = &chars[start..end];
    for i in 0..run.len() {
        let Some((prefix, www)) = url_prefix(run, i) else { continue };
        let len = trimmed_len(&run[i..], i > 0 && run[i - 1] == '\'');
        if len <= prefix || !run[i + prefix].is_alphanumeric() {
            continue;
        }
        if !(start + i..start + i + len).contains(&at) {
            return None;
        }
        let url: String = run[i..i + len].iter().collect();
        return Some(if www { format!("https://{url}") } else { url });
    }
    None
}

/// Characters a URL runs through: not blank, not a control, and none of the
/// ones RFC 3986 leaves out that terminals see around URLs (`"<>\^`{|}`).
fn is_url_char(c: char) -> bool {
    !c.is_whitespace() && !c.is_control() && !"\"<>\\^`{|}".contains(c)
}

/// The length of the URL prefix starting at `run[i]` (`http://`, `https://`,
/// or `www.` not inside a longer name), and whether it is `www.`.
fn url_prefix(run: &[char], i: usize) -> Option<(usize, bool)> {
    let rest = run[i..].iter().copied();
    if starts_with_ignoring_case(rest.clone(), "https://") {
        Some((8, false))
    } else if starts_with_ignoring_case(rest.clone(), "http://") {
        Some((7, false))
    } else if starts_with_ignoring_case(rest, "www.")
        && (i == 0 || !(run[i - 1].is_alphanumeric() || "./-_@:".contains(run[i - 1])))
    {
        Some((4, true))
    } else {
        None
    }
}

/// `url`'s length without trailing `.,;:!?` and closing `)`, `]` or `'`
/// that nothing in the URL opened (`quoted`: a `'` just before it did).
fn trimmed_len(url: &[char], quoted: bool) -> usize {
    let mut n = url.len();
    while let Some(&last) = url[..n].last() {
        let count = |c: char| url[..n].iter().filter(|&&x| x == c).count();
        let trailing = ".,;:!?".contains(last)
            || last == ')' && count('(') < count(')')
            || last == ']' && count('[') < count(']')
            || last == '\'' && (quoted || count('\'') % 2 == 1);
        if !trailing {
            break;
        }
        n -= 1;
    }
    n
}

fn starts_with_ignoring_case(mut s: impl Iterator<Item = char>, prefix: &str) -> bool {
    prefix.chars().all(|p| s.next().is_some_and(|c| c.eq_ignore_ascii_case(&p)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Rows of `cols`-wide text; a row ending in `\` soft-wraps into the next
    /// (the `\` is not part of it).
    fn screen(rows: &[&str]) -> Vec<RowText> {
        rows.iter()
            .map(|r| {
                let (text, wrapped) = r.strip_suffix('\\').map_or((*r, false), |t| (t, true));
                RowText { chars: text.chars().enumerate().map(|(i, c)| (i as u16, c)).collect(), wrapped }
            })
            .collect()
    }

    fn tap(rows: &[&str], col: u16, row: u32) -> Option<String> {
        let rows = screen(rows);
        text_url(|r| rows.get(r as usize).cloned(), col, row)
    }

    // Bug: a URL tap opening nothing, or the word around the tap instead of the URL.
    #[test]
    fn a_url_opens_from_any_of_its_cells() {
        let rows = ["see https://example.com/a?b=c#d now"];
        for col in [4, 12, 30] {
            assert_eq!(tap(&rows, col, 0).as_deref(), Some("https://example.com/a?b=c#d"), "col {col}");
        }
        assert_eq!(tap(&rows, 2, 0), None, "a word before it");
        assert_eq!(tap(&rows, 3, 0), None, "the blank before it");
        assert_eq!(tap(&rows, 33, 0), None, "a word after it");
    }

    // Bug: a URL broken across rows by the terminal opening only the tapped row's part.
    #[test]
    fn a_soft_wrapped_url_opens_whole_from_either_row() {
        let rows = ["$ cat u\\", "rl https://example.com/0123\\", "456789/end ok", "next"];
        for (col, row) in [(5, 1), (2, 2)] {
            assert_eq!(tap(&rows, col, row).as_deref(), Some("https://example.com/0123456789/end"));
        }
    }

    // Bug: rows that end without a soft wrap joined as if they were one line
    // (a hard newline, as omp writes, is a separate line).
    #[test]
    fn rows_without_a_wrap_flag_stay_separate() {
        let rows = ["https://example.com/0123", "456789"];
        assert_eq!(tap(&rows, 3, 0).as_deref(), Some("https://example.com/0123"));
        assert_eq!(tap(&rows, 3, 1), None);
    }

    // Bug: punctuation after a URL in prose sent to the browser (a 404).
    #[test]
    fn trailing_punctuation_is_left_out() {
        for (text, want) in [
            ("Go to https://example.com/a.", "https://example.com/a"),
            ("(see https://example.com/a), then", "https://example.com/a"),
            ("[https://example.com/a]!", "https://example.com/a"),
            ("'https://example.com/a';", "https://example.com/a"),
            ("\"https://example.com/a\"?", "https://example.com/a"),
            ("<https://example.com/a>", "https://example.com/a"),
            ("https://example.com/a:,;!?", "https://example.com/a"),
            ("https://en.wikipedia.org/wiki/Rust_(language)", "https://en.wikipedia.org/wiki/Rust_(language)"),
            ("(https://en.wikipedia.org/wiki/Rust_(language))", "https://en.wikipedia.org/wiki/Rust_(language)"),
            ("https://example.com/a[0]", "https://example.com/a[0]"),
            ("https://example.com/it's", "https://example.com/it's"),
            ("'https://example.com/it's'", "https://example.com/it's"),
        ] {
            let col = text.find("https").unwrap() as u16 + 9;
            assert_eq!(tap(&[text], col, 0).as_deref(), Some(want), "{text}");
        }
    }

    // Bug: a tap on the punctuation after a URL opening it.
    #[test]
    fn a_tap_on_trimmed_punctuation_is_not_a_link() {
        assert_eq!(tap(&["https://example.com/a)."], 21, 0), None);
    }

    // Bug: www. hosts not opening, opening without a scheme, or matching inside another name.
    #[test]
    fn a_www_host_opens_as_https() {
        assert_eq!(tap(&["visit www.example.com."], 8, 0).as_deref(), Some("https://www.example.com"));
        assert_eq!(tap(&["(WWW.example.com/x)"], 3, 0).as_deref(), Some("https://WWW.example.com/x"));
        assert_eq!(tap(&["http://www.example.com"], 12, 0).as_deref(), Some("http://www.example.com"));
        assert_eq!(tap(&["notwww.example.com"], 8, 0), None);
        assert_eq!(tap(&["mail@www.example.com"], 8, 0), None);
    }

    // Bug: other schemes, paths and bare prefixes treated as web links.
    #[test]
    fn only_http_and_https_urls_are_links() {
        for text in [
            "file:///Users/u/notes.md",
            "ssh://host/path",
            "mailto:user@example.com",
            "/usr/local/share/http/x",
            "src/http.rs",
            "https://",
            "https://.",
            "www.",
            "ftp://example.com",
        ] {
            assert_eq!(tap(&[text], 3, 0), None, "{text}");
        }
        assert_eq!(tap(&["HTTPS://Example.com"], 3, 0).as_deref(), Some("HTTPS://Example.com"));
    }

    // Bug: a URL after other text with no space (key=value, markdown) not found,
    // or found from a tap on the text before it.
    #[test]
    fn a_url_glued_to_text_starts_at_its_scheme() {
        let rows = ["url=https://example.com/x [doc](https://example.com/y)"];
        assert_eq!(tap(&rows, 8, 0).as_deref(), Some("https://example.com/x"));
        assert_eq!(tap(&rows, 1, 0), None);
        assert_eq!(tap(&rows, 40, 0).as_deref(), Some("https://example.com/y"));
        assert_eq!(tap(&rows, 28, 0), None, "the link text");
    }

    // Bug: a tap on the right half of a wide glyph inside a URL finding nothing,
    // or a tap past a row's text finding the row's last character.
    #[test]
    fn wide_glyph_halves_and_cells_past_the_text() {
        let row = RowText {
            chars: "https://例.jp/x".chars().scan(0u16, |col, ch| {
                let c = *col;
                *col += if ch == '例' { 2 } else { 1 };
                Some((c, ch))
            }).collect(),
            wrapped: false,
        };
        let rows = [row];
        let read = |r: u32| rows.get(r as usize).cloned();
        assert_eq!(text_url(read, 9, 0).as_deref(), Some("https://例.jp/x"), "the glyph's right half");
        assert_eq!(text_url(read, 20, 0), None, "past the text");
    }

    // Bug: a wrapped run longer than the join limit walking the whole scrollback.
    #[test]
    fn joining_stops_at_the_limit() {
        let mut rows = vec!["https://example.com/\\".to_string()];
        rows.extend((0..200).map(|_| "aaaaaaaaaa\\".to_string()));
        rows.push("end".to_string());
        let refs: Vec<&str> = rows.iter().map(String::as_str).collect();
        let url = tap(&refs, 2, 0).unwrap();
        assert_eq!(url.len(), "https://example.com/".len() + 10 * MAX_JOINED_ROWS as usize);
    }

    #[test]
    fn is_web_accepts_only_http_and_https() {
        assert!(is_web("https://example.com"));
        assert!(is_web("HTTP://example.com"));
        assert!(!is_web("file:///tmp/x"));
        assert!(!is_web("httpx://example.com"));
        assert!(!is_web(""));
    }
}
