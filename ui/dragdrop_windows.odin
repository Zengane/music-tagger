package musictagger

// Dragging files out of the window into another application.
//
// Windows has exactly one way to do this, and it is not a message you send.
// The application has to *become* a drag source: implement two COM interfaces,
// hand them to `DoDragDrop`, and let Windows run the drag. `IDataObject`
// answers "what are you carrying" — here, a CF_HDROP list of file paths, the
// same thing Explorer hands over. `IDropSource` answers "should the drag
// continue" as the mouse moves and the buttons change.
//
// COM objects are a pointer to a table of function pointers, so that is what
// is built: a struct whose first field is a vtable pointer, laid out in the
// order the interface declares. The order is the interface — one entry out of
// place and the target calls the wrong method.
//
// `DoDragDrop` runs its own message loop and does not return until the drop
// lands or is cancelled, so the window stops drawing for the duration. That is
// how every drag source behaves, Explorer included: Windows is drawing the
// drag image, not us.
//
// ole32 and shell32 are loaded at run time for the same reason user32 is in
// clipboard.odin — see the note there about raylib's `CloseWindow`.

import win32 "core:sys/windows"

// ── COM plumbing ────────────────────────────────────────────────────────────

@(private) CLSCTX_INPROC :: 1

@(private) DVASPECT_CONTENT :: 1
@(private) TYMED_HGLOBAL    :: 1
@(private) DROPEFFECT_NONE  :: 0
@(private) DROPEFFECT_COPY  :: 1
@(private) DROPEFFECT_MOVE  :: 2
@(private) DROPEFFECT_LINK  :: 4

@(private) DRAGDROP_S_DROP                :: win32.HRESULT(0x00040100)
@(private) DRAGDROP_S_CANCEL              :: win32.HRESULT(0x00040101)
@(private) DRAGDROP_S_USEDEFAULTCURSORS   :: win32.HRESULT(0x00040102)
@(private) DV_E_FORMATETC                 :: win32.HRESULT(-2147221404) // 0x80040064
@(private) DV_E_TYMED                     :: win32.HRESULT(-2147221399) // 0x80040069
@(private) DV_E_DVASPECT                  :: win32.HRESULT(-2147221397) // 0x8004006B
@(private) OLE_E_ADVISENOTSUPPORTED       :: win32.HRESULT(-2147221501) // 0x80040003
@(private) E_NOTIMPL_HR                   :: win32.HRESULT(-2147467263) // 0x80004001
@(private) E_INVALIDARG_HR                :: win32.HRESULT(-2147024809) // 0x80070057
@(private) E_OUTOFMEMORY_HR               :: win32.HRESULT(-2147024882) // 0x8007000E
@(private) E_NOINTERFACE_HR               :: win32.HRESULT(-2147467262) // 0x80004002
@(private) S_OK_HR                        :: win32.HRESULT(0)
@(private) S_FALSE_HR                     :: win32.HRESULT(1)

@(private) MK_LBUTTON :: 0x0001
@(private) MK_RBUTTON :: 0x0002
@(private) MK_ALT     :: 0x0020

@(private)
FORMATETC :: struct {
	cfFormat: win32.WORD,
	ptd:      rawptr,
	dwAspect: win32.DWORD,
	lindex:   win32.LONG,
	tymed:    win32.DWORD,
}

@(private)
STGMEDIUM :: struct {
	tymed:          win32.DWORD,
	hGlobal:        win32.HANDLE, // the union; only the HGLOBAL arm is used
	pUnkForRelease: rawptr,
}

@(private)
IID_IUnknown := win32.GUID{
	0x00000000, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46},
}
@(private)
IID_IDataObject := win32.GUID{
	0x0000010E, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46},
}
@(private)
IID_IDropSource := win32.GUID{
	0x00000121, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46},
}

@(private)
guid_equal :: proc "system" (a, b: ^win32.GUID) -> bool {
	if a == nil || b == nil { return false }
	if a.Data1 != b.Data1 || a.Data2 != b.Data2 || a.Data3 != b.Data3 { return false }
	for i in 0 ..< 8 {
		if a.Data4[i] != b.Data4[i] { return false }
	}
	return true
}

// ── IDropSource ─────────────────────────────────────────────────────────────

@(private)
IDropSource_Vtbl :: struct {
	QueryInterface:    proc "system" (this: rawptr, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT,
	AddRef:            proc "system" (this: rawptr) -> win32.ULONG,
	Release:           proc "system" (this: rawptr) -> win32.ULONG,
	QueryContinueDrag: proc "system" (this: rawptr, escape: win32.BOOL, keys: win32.DWORD) -> win32.HRESULT,
	GiveFeedback:      proc "system" (this: rawptr, effect: win32.DWORD) -> win32.HRESULT,
}

@(private)
Drop_Source :: struct {
	vtbl: ^IDropSource_Vtbl,
	refs: win32.ULONG,
}

@(private)
drop_source_query :: proc "system" (this: rawptr, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT {
	if out == nil { return E_INVALIDARG_HR }
	if guid_equal(riid, &IID_IUnknown) || guid_equal(riid, &IID_IDropSource) {
		out^ = this
		src := (^Drop_Source)(this)
		src.refs += 1
		return S_OK_HR
	}
	out^ = nil
	return E_NOINTERFACE_HR
}

@(private)
drop_source_addref :: proc "system" (this: rawptr) -> win32.ULONG {
	src := (^Drop_Source)(this)
	src.refs += 1
	return src.refs
}

@(private)
drop_source_release :: proc "system" (this: rawptr) -> win32.ULONG {
	src := (^Drop_Source)(this)
	if src.refs > 0 { src.refs -= 1 }
	// The object lives in this module's storage for the length of the drag, so
	// there is nothing to free when the count reaches zero.
	return src.refs
}

@(private)
drop_source_continue :: proc "system" (this: rawptr, escape: win32.BOOL, keys: win32.DWORD) -> win32.HRESULT {
	if escape || (keys & MK_RBUTTON) != 0 { return DRAGDROP_S_CANCEL }
	// The button coming up is the drop. Until then, keep going.
	if (keys & MK_LBUTTON) == 0 {
		drag_alt_at_drop = (keys & MK_ALT) != 0
		return DRAGDROP_S_DROP
	}
	return S_OK_HR
}

@(private)
drop_source_feedback :: proc "system" (this: rawptr, effect: win32.DWORD) -> win32.HRESULT {
	// Windows draws the copy/move cursors; there is nothing better to add.
	return DRAGDROP_S_USEDEFAULTCURSORS
}

// ── IDataObject ─────────────────────────────────────────────────────────────

@(private)
IDataObject_Vtbl :: struct {
	QueryInterface:        proc "system" (this: rawptr, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT,
	AddRef:                proc "system" (this: rawptr) -> win32.ULONG,
	Release:               proc "system" (this: rawptr) -> win32.ULONG,
	GetData:               proc "system" (this: rawptr, fmt: ^FORMATETC, med: ^STGMEDIUM) -> win32.HRESULT,
	GetDataHere:           proc "system" (this: rawptr, fmt: ^FORMATETC, med: ^STGMEDIUM) -> win32.HRESULT,
	QueryGetData:          proc "system" (this: rawptr, fmt: ^FORMATETC) -> win32.HRESULT,
	GetCanonicalFormatEtc: proc "system" (this: rawptr, in_fmt: ^FORMATETC, out_fmt: ^FORMATETC) -> win32.HRESULT,
	SetData:               proc "system" (this: rawptr, fmt: ^FORMATETC, med: ^STGMEDIUM, release: win32.BOOL) -> win32.HRESULT,
	EnumFormatEtc:         proc "system" (this: rawptr, direction: win32.DWORD, out: ^rawptr) -> win32.HRESULT,
	DAdvise:               proc "system" (this: rawptr, fmt: ^FORMATETC, flags: win32.DWORD, sink: rawptr, conn: ^win32.DWORD) -> win32.HRESULT,
	DUnadvise:             proc "system" (this: rawptr, conn: win32.DWORD) -> win32.HRESULT,
	EnumDAdvise:           proc "system" (this: rawptr, out: ^rawptr) -> win32.HRESULT,
}

// Formats the object was handed rather than born with.
//
// The shell's drag-image helper works by calling `SetData` on the source's
// data object to stash the picture it is going to draw, then reading it back
// while the drag runs. An object that refuses `SetData` gets no drag image —
// which is why this exists.
@(private) EXTRA_FORMATS :: 8

@(private)
Stored_Format :: struct {
	format: win32.WORD,
	aspect: win32.DWORD,
	medium: STGMEDIUM,
	used:   bool,
}

@(private)
Data_Object :: struct {
	vtbl:   ^IDataObject_Vtbl,
	refs:   win32.ULONG,
	// The CF_HDROP block, built once when the drag starts. Handed to the
	// target as a copy each time it asks, because the target frees what it
	// gets and may ask more than once.
	source: win32.HGLOBAL,
	bytes:  int,
	extra:  [EXTRA_FORMATS]Stored_Format,
}

@(private)
data_object_query :: proc "system" (this: rawptr, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT {
	if out == nil { return E_INVALIDARG_HR }
	if guid_equal(riid, &IID_IUnknown) || guid_equal(riid, &IID_IDataObject) {
		out^ = this
		obj := (^Data_Object)(this)
		obj.refs += 1
		return S_OK_HR
	}
	out^ = nil
	return E_NOINTERFACE_HR
}

@(private)
data_object_addref :: proc "system" (this: rawptr) -> win32.ULONG {
	obj := (^Data_Object)(this)
	obj.refs += 1
	return obj.refs
}

@(private)
data_object_release :: proc "system" (this: rawptr) -> win32.ULONG {
	obj := (^Data_Object)(this)
	if obj.refs > 0 { obj.refs -= 1 }
	return obj.refs
}

@(private)
wants_hdrop :: proc "system" (fmt: ^FORMATETC) -> win32.HRESULT {
	if fmt == nil { return E_INVALIDARG_HR }
	if fmt.cfFormat != CF_HDROP        { return DV_E_FORMATETC }
	if (fmt.tymed & TYMED_HGLOBAL) == 0 { return DV_E_TYMED }
	if fmt.dwAspect != DVASPECT_CONTENT { return DV_E_DVASPECT }
	return S_OK_HR
}

@(private)
data_object_get :: proc "system" (this: rawptr, fmt: ^FORMATETC, med: ^STGMEDIUM) -> win32.HRESULT {
	if med == nil || fmt == nil { return E_INVALIDARG_HR }
	obj := (^Data_Object)(this)

	// Anything the drag-image helper stored is handed straight back. Its own
	// handles stay its own: the helper set them and the helper frees them.
	for &slot in obj.extra {
		if slot.used && slot.format == fmt.cfFormat && slot.aspect == fmt.dwAspect {
			med^ = slot.medium
			med.pUnkForRelease = nil
			return S_OK_HR
		}
	}

	if hr := wants_hdrop(fmt); hr != S_OK_HR { return hr }

	if obj.source == nil { return E_OUTOFMEMORY_HR }

	// A fresh copy every time: the target takes ownership of what it is given
	// and frees it, so handing out our own block would free it underneath us.
	copy_handle := win32.HGLOBAL(win32.GlobalAlloc(win32.GMEM_MOVEABLE, uint(obj.bytes)))
	if copy_handle == nil { return E_OUTOFMEMORY_HR }

	from := win32.GlobalLock(obj.source)
	to   := win32.GlobalLock(copy_handle)
	if from == nil || to == nil {
		if from != nil { win32.GlobalUnlock(obj.source) }
		if to   != nil { win32.GlobalUnlock(copy_handle) }
		win32.GlobalFree(copy_handle)
		return E_OUTOFMEMORY_HR
	}
	src := ([^]u8)(from)
	dst := ([^]u8)(to)
	for i in 0 ..< obj.bytes { dst[i] = src[i] }
	win32.GlobalUnlock(obj.source)
	win32.GlobalUnlock(copy_handle)

	med.tymed          = TYMED_HGLOBAL
	med.hGlobal        = win32.HANDLE(copy_handle)
	med.pUnkForRelease = nil
	return S_OK_HR
}

@(private)
data_object_get_here :: proc "system" (this: rawptr, fmt: ^FORMATETC, med: ^STGMEDIUM) -> win32.HRESULT {
	// Only meaningful for a caller-supplied medium, which no file drop uses.
	return E_NOTIMPL_HR
}

@(private)
data_object_query_get :: proc "system" (this: rawptr, fmt: ^FORMATETC) -> win32.HRESULT {
	if fmt == nil { return E_INVALIDARG_HR }
	obj := (^Data_Object)(this)
	for &slot in obj.extra {
		if slot.used && slot.format == fmt.cfFormat && slot.aspect == fmt.dwAspect {
			return S_OK_HR
		}
	}
	return wants_hdrop(fmt)
}

@(private)
data_object_canonical :: proc "system" (this: rawptr, in_fmt: ^FORMATETC, out_fmt: ^FORMATETC) -> win32.HRESULT {
	if out_fmt != nil { out_fmt.ptd = nil }
	return S_FALSE_HR // there is only one format, so the request is already canonical
}

@(private)
data_object_set :: proc "system" (this: rawptr, fmt: ^FORMATETC, med: ^STGMEDIUM, release: win32.BOOL) -> win32.HRESULT {
	if fmt == nil || med == nil { return E_INVALIDARG_HR }
	obj := (^Data_Object)(this)

	// Only ownership-transferring calls are accepted, which is what the shell
	// helper makes. Copying a medium we do not own would mean guessing how to
	// free it later.
	if !release { return E_NOTIMPL_HR }

	for &slot in obj.extra {
		if slot.used && slot.format == fmt.cfFormat && slot.aspect == fmt.dwAspect {
			slot.medium = med^
			return S_OK_HR
		}
	}
	for &slot in obj.extra {
		if slot.used { continue }
		slot = Stored_Format{
			format = fmt.cfFormat,
			aspect = fmt.dwAspect,
			medium = med^,
			used   = true,
		}
		return S_OK_HR
	}
	return E_OUTOFMEMORY_HR
}

@(private)
data_object_enum :: proc "system" (this: rawptr, direction: win32.DWORD, out: ^rawptr) -> win32.HRESULT {
	// Some targets — Premiere among them — ask what is on offer rather than
	// guessing. The shell provides a standard enumerator for exactly this, so
	// there is no need to implement IEnumFORMATETC by hand.
	if out == nil { return E_INVALIDARG_HR }
	out^ = nil
	if direction != 1 { return E_NOTIMPL_HR } // DATADIR_GET only
	if ole.enum_fmt == nil { return E_NOTIMPL_HR }

	fmt := FORMATETC{
		cfFormat = CF_HDROP,
		ptd      = nil,
		dwAspect = DVASPECT_CONTENT,
		lindex   = -1,
		tymed    = TYMED_HGLOBAL,
	}
	return ole.enum_fmt(1, &fmt, out)
}

@(private)
data_object_dadvise :: proc "system" (this: rawptr, fmt: ^FORMATETC, flags: win32.DWORD, sink: rawptr, conn: ^win32.DWORD) -> win32.HRESULT {
	return OLE_E_ADVISENOTSUPPORTED
}

@(private)
data_object_dunadvise :: proc "system" (this: rawptr, conn: win32.DWORD) -> win32.HRESULT {
	return OLE_E_ADVISENOTSUPPORTED
}

@(private)
data_object_enum_advise :: proc "system" (this: rawptr, out: ^rawptr) -> win32.HRESULT {
	return OLE_E_ADVISENOTSUPPORTED
}

// ── the OLE entry points ────────────────────────────────────────────────────

@(private)
Ole_Api :: struct {
	initialise:  proc "system" (reserved: rawptr) -> win32.HRESULT,
	do_drag:     proc "system" (data: rawptr, source: rawptr, allowed: win32.DWORD, effect: ^win32.DWORD) -> win32.HRESULT,
	enum_fmt:    proc "system" (count: win32.UINT, formats: ^FORMATETC, out: ^rawptr) -> win32.HRESULT,
	ready:       bool,
	tried:       bool,
	initialised: bool,
}

@(private)
ole: Ole_Api

@(private)
load_ole :: proc() -> bool {
	if ole.tried { return ole.ready }
	ole.tried = true

	ole32 := win32.LoadLibraryW(win32.utf8_to_wstring("ole32.dll", context.temp_allocator))
	if ole32 == nil { return false }
	init := win32.GetProcAddress(ole32, "OleInitialize")
	drag := win32.GetProcAddress(ole32, "DoDragDrop")
	if init == nil || drag == nil { return false }
	ole.initialise = auto_cast init
	ole.do_drag    = auto_cast drag

	// Optional: without it EnumFormatEtc reports "not implemented", which most
	// targets tolerate.
	if shell32 := win32.LoadLibraryW(win32.utf8_to_wstring("shell32.dll", context.temp_allocator));
	   shell32 != nil {
		if p := win32.GetProcAddress(shell32, "SHCreateStdEnumFmtEtc"); p != nil {
			ole.enum_fmt = auto_cast p
		}
	}

	ole.ready = true
	return true
}

// OLE has to be initialised on the thread that starts the drag, and stay
// initialised. Called once, on the drawing thread, before the first drag.
@(private)
ensure_ole_initialised :: proc() -> bool {
	if !load_ole() { return false }
	if ole.initialised { return true }
	hr := ole.initialise(nil)
	// S_FALSE means it was already initialised on this thread, which is fine.
	if hr != S_OK_HR && hr != S_FALSE_HR { return false }
	ole.initialised = true
	return true
}

// ── starting a drag ─────────────────────────────────────────────────────────

@(private) drag_source_object: Drop_Source
@(private) drag_data_object:   Data_Object
@(private) drag_source_vtbl:   IDropSource_Vtbl
@(private) drag_data_vtbl:     IDataObject_Vtbl

drag_in_progress: bool

// Alt was down when the button came up. Premiere ignores Alt on a drop from
// outside, so the app reads it and asks the panel for the replace itself.
drag_alt_at_drop: bool

// Hands `paths` to Windows as a file drag.
//
// Blocks until the drop lands or is cancelled: `DoDragDrop` runs its own
// message loop. Returns whether anything was actually dropped.
drag_files :: proc(paths: []string) -> bool {
	// Nothing may draw while this runs; see `Live_Resize.dragging`.
	begin_drag_loop()
	defer end_drag_loop()
	drag_alt_at_drop = false

	if len(paths) == 0 { return false }
	if drag_in_progress  { return false }
	if !ensure_ole_initialised() { return false }

	block, bytes, built := build_hdrop(paths)
	if !built { return false }

	drag_source_vtbl = IDropSource_Vtbl{
		QueryInterface    = drop_source_query,
		AddRef            = drop_source_addref,
		Release           = drop_source_release,
		QueryContinueDrag = drop_source_continue,
		GiveFeedback      = drop_source_feedback,
	}
	drag_data_vtbl = IDataObject_Vtbl{
		QueryInterface        = data_object_query,
		AddRef                = data_object_addref,
		Release               = data_object_release,
		GetData               = data_object_get,
		GetDataHere           = data_object_get_here,
		QueryGetData          = data_object_query_get,
		GetCanonicalFormatEtc = data_object_canonical,
		SetData               = data_object_set,
		EnumFormatEtc         = data_object_enum,
		DAdvise               = data_object_dadvise,
		DUnadvise             = data_object_dunadvise,
		EnumDAdvise           = data_object_enum_advise,
	}
	drag_source_object = Drop_Source{vtbl = &drag_source_vtbl, refs = 1}
	drag_data_object   = Data_Object{vtbl = &drag_data_vtbl, refs = 1, source = block, bytes = bytes}

	// The card that follows the cursor. Best-effort — a failure here just
	// leaves the plain copy arrow.
	label := path_leaf(paths[0])
	attach_drag_image(&drag_data_object, label, len(paths))

	effect: win32.DWORD
	drag_in_progress = true
	hr := ole.do_drag(&drag_data_object, &drag_source_object,
	                  DROPEFFECT_COPY | DROPEFFECT_LINK, &effect)
	drag_in_progress = false

	// Our own block is ours to free; every copy handed out belongs to whoever
	// took it.
	win32.GlobalFree(block)

	return hr == DRAGDROP_S_DROP && effect != DROPEFFECT_NONE
}

// The CF_HDROP payload: a header saying where the names start, then the paths
// as UTF-16, each null-terminated, with one more null closing the list.
@(private)
build_hdrop :: proc(paths: []string) -> (win32.HGLOBAL, int, bool) {
	wide_total := 0
	wides := make([][]u16, len(paths), context.temp_allocator)
	for path, i in paths {
		w := win32.utf8_to_utf16(path, context.temp_allocator)
		if w == nil { return nil, 0, false }
		wides[i] = w
		wide_total += len(w) + 1
	}
	wide_total += 1

	size := size_of(DROPFILES) + wide_total * size_of(u16)
	handle := win32.HGLOBAL(win32.GlobalAlloc(win32.GMEM_MOVEABLE, uint(size)))
	if handle == nil { return nil, 0, false }

	block := win32.GlobalLock(handle)
	if block == nil {
		win32.GlobalFree(handle)
		return nil, 0, false
	}
	header := (^DROPFILES)(block)
	header^ = DROPFILES{pFiles = size_of(DROPFILES), fWide = true}

	cursor := ([^]u16)(uintptr(block) + size_of(DROPFILES))
	at := 0
	for w in wides {
		for c in w {
			cursor[at] = c
			at += 1
		}
		cursor[at] = 0
		at += 1
	}
	cursor[at] = 0
	win32.GlobalUnlock(handle)

	return handle, size, true
}

// What a drag from the list should carry.
//
// The rendered clip wins when there is one: selecting a range on the waveform
// and dragging is a request for that range, not for the whole track.
drag_current_selection :: proc() -> (count: int, is_clip: bool, dropped: bool) {
	if app.clip_path != "" && player.sel_end > player.sel_start {
		return 1, true, drag_files({app.clip_path})
	}

	targets := tag_targets()
	if len(targets) == 0 { return 0, false, false }

	paths := make([dynamic]string, 0, len(targets), context.temp_allocator)
	for i in targets { append(&paths, lib.tracks[i].path) }
	return len(paths), false, drag_files(paths[:])
}
