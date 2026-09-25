package musictagger

// Choosing a folder with Windows' own folder picker.
//
// The modern one (IFileOpenDialog with FOS_PICKFOLDERS), the same dialog
// Explorer and every current program shows, not the old tree-view
// SHBrowseForFolder. ole32 is loaded at run time, as the drag-and-drop code
// does it, rather than linked.

import win32 "core:sys/windows"
import rl "vendor:raylib"

@(private)
Folder_Pick_Api :: struct {
	create:  proc "system" (clsid: win32.REFCLSID, outer: win32.LPUNKNOWN, ctx: win32.DWORD,
	                        iid: win32.REFIID, out: ^win32.LPVOID) -> win32.HRESULT,
	free:    proc "system" (p: rawptr),
	tried:   bool,
	ready:   bool,
}

@(private)
folder_pick_api: Folder_Pick_Api

@(private)
load_folder_pick :: proc() -> bool {
	if folder_pick_api.tried { return folder_pick_api.ready }
	folder_pick_api.tried = true
	ole32 := win32.LoadLibraryW(win32.utf8_to_wstring("ole32.dll", context.temp_allocator))
	if ole32 == nil { return false }
	create := win32.GetProcAddress(ole32, "CoCreateInstance")
	free   := win32.GetProcAddress(ole32, "CoTaskMemFree")
	if create == nil || free == nil { return false }
	folder_pick_api.create = auto_cast create
	folder_pick_api.free   = auto_cast free
	folder_pick_api.ready  = true
	return true
}

folder_picker_available :: proc() -> bool { return true }

// Shows the picker and blocks until it closes. Returns the chosen folder, or
// ok = false when cancelled or unavailable.
choose_folder :: proc(title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	if !ensure_ole_initialised() || !load_folder_pick() { return "", false }

	ptr: win32.LPVOID
	hr := folder_pick_api.create(win32.CLSID_FileOpenDialog, nil, win32.CLSCTX_INPROC_SERVER,
	                             win32.IID_IFileOpenDialog, &ptr)
	if hr < 0 || ptr == nil { return "", false }
	dialog := (^win32.IFileOpenDialog)(ptr)
	defer dialog->Release()

	options: win32.FILEOPENDIALOGOPTIONS
	dialog->GetOptions(&options)
	dialog->SetOptions(options | win32.FOS_PICKFOLDERS | win32.FOS_FORCEFILESYSTEM | win32.FOS_PATHMUSTEXIST)
	dialog->SetTitle(win32.utf8_to_wstring(title, context.temp_allocator))

	// The dialog runs its own message loop; nothing may draw meanwhile, the
	// same rule as a drag (see liveresize_windows.odin).
	begin_drag_loop()
	hr = dialog->Show(win32.HWND(rl.GetWindowHandle()))
	end_drag_loop()
	// The click that closed it happened inside that loop, out of raylib's sight.
	ui.held     = false
	ui.captured = nil
	if hr < 0 { return "", false } // cancelled, or failed

	item: ^win32.IShellItem
	if dialog->GetResult(&item) < 0 || item == nil { return "", false }
	defer item->Release()

	wide: win32.LPWSTR
	if item->GetDisplayName(.FILESYSPATH, &wide) < 0 || wide == nil { return "", false }
	defer folder_pick_api.free(wide)

	text, err := win32.wstring_to_utf8(win32.wstring(wide), -1, allocator)
	if err != nil || text == "" { return "", false }
	return text, true
}
