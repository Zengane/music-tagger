package musictagger

// Which font files to use, per platform.
//
// Nothing is bundled: every system below ships a good UI face, and a bundled
// one would be one more licence to track. Each list is tried in order and the
// first file that exists wins. On Linux fontconfig is asked first, since
// distributions put the same font in half a dozen different places.

import "core:os"
import "core:strings"

Font_Role :: enum { Regular, Bold, Emoji }

when ODIN_OS == .Windows {
	@(private) REGULAR_FONTS := []string{"C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"}
	@(private) BOLD_FONTS    := []string{"C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf"}
	@(private) EMOJI_FONTS   := []string{"C:/Windows/Fonts/seguiemj.ttf"}

	// Yu Gothic is the modern UI font; MS Gothic is the old one and is present
	// on every install. Both are collections, which is why fontfile.odin exists.
	CJK_CANDIDATES := []string{
		"C:/Windows/Fonts/YuGothR.ttc",
		"C:/Windows/Fonts/YuGothM.ttc",
		"C:/Windows/Fonts/msgothic.ttc",
		"C:/Windows/Fonts/meiryo.ttc",
		"C:/Windows/Fonts/malgun.ttf",
		"C:/Windows/Fonts/NanumGothic-Regular.ttf",
	}
} else when ODIN_OS == .Darwin {
	// SF Pro is a variable font, which stb_truetype draws at its default
	// instance only, so the static Helvetica Neue / Arial are preferred.
	@(private) REGULAR_FONTS := []string{
		"/System/Library/Fonts/HelveticaNeue.ttc",
		"/System/Library/Fonts/Supplemental/Arial.ttf",
		"/Library/Fonts/Arial.ttf",
		"/System/Library/Fonts/Helvetica.ttc",
	}
	@(private) BOLD_FONTS := []string{
		"/System/Library/Fonts/Supplemental/Arial Bold.ttf",
		"/Library/Fonts/Arial Bold.ttf",
	}
	// Apple Color Emoji is a bitmap (sbix) font that stb_truetype cannot draw.
	@(private) EMOJI_FONTS := []string{}

	CJK_CANDIDATES := []string{
		"/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
		"/System/Library/Fonts/Hiragino Sans GB.ttc",
		"/System/Library/Fonts/AppleSDGothicNeo.ttc",
		"/Library/Fonts/Arial Unicode.ttf",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	}
} else {
	@(private) REGULAR_FONTS := []string{
		"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	}
	@(private) BOLD_FONTS := []string{
		"/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
		"/usr/share/fonts/noto/NotoSans-Bold.ttf",
		"/usr/share/fonts/google-noto/NotoSans-Bold.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
		"/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
		"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
	}
	// Noto Color Emoji is a bitmap (CBDT) font that stb_truetype cannot draw.
	@(private) EMOJI_FONTS := []string{}

	CJK_CANDIDATES := []string{
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
		"/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
	}
}

// The file to use for `role`, or "" when this system has none.
font_path :: proc(role: Font_Role) -> string {
	@(static) cache: [Font_Role]string
	@(static) looked: [Font_Role]bool
	if looked[role] { return cache[role] }
	looked[role] = true

	when ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD {
		pattern := ""
		switch role {
		case .Regular: pattern = "sans-serif:style=Regular"
		case .Bold:    pattern = "sans-serif:style=Bold"
		case .Emoji:
		}
		if pattern != "" {
			out, code, ok := run_capture({"fc-match", "-f", "%{file}", pattern}, context.temp_allocator)
			if ok && code == 0 {
				file := strings.trim_space(string(out))
				lower := strings.to_lower(file, context.temp_allocator)
				// fc-match always answers, sometimes with a bitmap or Type 1
				// font stb cannot read. Only an outline font is taken.
				if os.exists(file) && (strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") || strings.has_suffix(lower, ".ttc")) {
					cache[role] = strings.clone(file)
					return cache[role]
				}
			}
		}
	}

	list: []string
	switch role {
	case .Regular: list = REGULAR_FONTS
	case .Bold:    list = BOLD_FONTS
	case .Emoji:   list = EMOJI_FONTS
	}
	for p in list {
		if os.exists(p) { cache[role] = p; return p }
	}
	return ""
}
