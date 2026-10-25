import Foundation

/// VT bytes that exercise the renderer: palettes, styles, Nerd Font
/// icons, Powerline, box drawing, blocks, CJK, emoji and combining marks.
/// Feed it to a local session (`testpage`) and screenshot the result.
enum TestPage {
    static var bytes: Data { Data(text.utf8) }

    static var text: String {
        let e = "\u{1B}["
        var s = "\(e)2J\(e)H\(e)1mterm test page\(e)0m\r\n\r\n"

        s += "16  "
        for c in 30...37 { s += "\(e)\(c)m██" }
        s += "\(e)0m  "
        for c in 90...97 { s += "\(e)\(c)m██" }
        s += "\(e)0m\r\n    "
        for c in 40...47 { s += "\(e)\(c)m  " }
        s += "\(e)0m  "
        for c in 100...107 { s += "\(e)\(c)m  " }
        s += "\(e)0m\r\n"

        s += "256 "
        for row in 0..<6 {
            if row > 0 { s += "    " }
            for g in 0..<6 {
                for b in 0..<6 { s += "\(e)48;5;\(16 + row * 36 + g * 6 + b)m " }
            }
            s += "\(e)0m\r\n"
        }
        s += "    "
        for g in 232...255 { s += "\(e)48;5;\(g)m " }
        s += "\(e)0m\r\n"

        s += "rgb "
        for i in 0..<48 {
            let (r, g, b) = hue(Double(i) / 48)
            let (r2, g2, b2) = hue(Double(i) / 48 + 0.5)
            s += "\(e)38;2;\(r);\(g);\(b);48;2;\(r2);\(g2);\(b2)m▀"
        }
        s += "\(e)0m\r\n\r\n"

        s += "\(e)1mbold\(e)0m \(e)2mfaint\(e)0m \(e)3mitalic\(e)0m \(e)1;3mbold-italic\(e)0m "
        s += "\(e)7minverse\(e)0m \(e)9mstrike\(e)0m \(e)53moverline\(e)0m \(e)5mblink\(e)0m\r\n"
        s += "\(e)4munder\(e)0m \(e)4:2mdouble\(e)0m \(e)4:3;58;2;255;80;80mcurly\(e)0m "
        s += "\(e)4:4mdotted\(e)0m \(e)4:5mdashed\(e)0m \(e)32mgreen\(e)0m \(e)1;34mbright?\(e)0m\r\n\r\n"

        s += "nerd  \u{F179} \u{E7A8} \u{E755} \u{E73C} \u{E62B} \u{F09B} \u{E0A0} \u{F07C} \u{F023} \u{F120} \u{F004} \u{F0E7}\r\n"
        s += "\(e)30;44m ~/src \(e)34;42m\u{E0B0}\(e)30;42m \u{E0A0} main \(e)32;49m\u{E0B0}\(e)0m "
        s += "\(e)35m\u{E0B6}\(e)30;45m pill \(e)35;49m\u{E0B4}\(e)0m "
        s += "\(e)33m\u{E0B2}\(e)30;43m 12:00 \(e)36;43m\u{E0BA}\(e)30;46m ok \(e)0m \u{E0B1} \u{E0B3}\r\n\r\n"

        s += "┌───┬───┐ ┏━━━┳━━━┓ ╔═══╦═══╗ ╭───╮ ┄┄┄┄ ╱╲╳\r\n"
        s += "│ a │ b │ ┃ c ┃ d ┃ ║ e ║ f ║ │ g │ ┅┅┅┅ ╭┬╮\r\n"
        s += "├───┼───┤ ┣━━━╋━━━┫ ╠═══╬═══╣ ╰───╯ ╌╌╌╌ ├┼┤\r\n"
        s += "└───┴───┘ ┗━━━┻━━━┛ ╚═══╩═══╝ ┍┑┕┙  ┈┈┈┈ ╰┴╯\r\n"
        s += "▁▂▃▄▅▆▇█ ▉▊▋▌▍▎▏ ░░▒▒▓▓██ ▖▗▘▙▚▛▜▝▞▟ ▀▄▌▐\r\n\r\n"

        s += "日本語の端末│中文│한국어│\r\n"
        s += "😀 👍🏽 👨‍👩‍👧 🇯🇵 ❤️ 🦀 e\u{301} a\u{308} n\u{303}\r\n"
        return s
    }

    private static func hue(_ h: Double) -> (Int, Int, Int) {
        let x = (h - h.rounded(.down)) * 6
        func ch(_ o: Double) -> Int {
            let v = max(0, min(1, abs((x + o).truncatingRemainder(dividingBy: 6) - 3) - 1))
            return Int(v * 255)
        }
        return (ch(0), ch(4), ch(2))
    }
}
