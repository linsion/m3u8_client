#include "flutter_window.h"

#include <algorithm>
using std::max;
using std::min;
#include <commdlg.h>
#include <flutter/standard_method_codec.h>
#include <objidl.h>
#include <gdiplus.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "winmm.lib")

#include <atomic>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr UINT kWmFileDragDelta = WM_APP + 0x41;
constexpr UINT kWmFilesDropped = WM_APP + 0x42;
constexpr UINT kWmPickFilesDone = WM_APP + 0x43;

WNDPROC g_prev_child_wndproc = nullptr;
HWND g_hooked_child_hwnd = nullptr;
FlutterWindow* g_active_flutter_window = nullptr;

struct PickFilesResultPayload {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  flutter::EncodableList items;
};

void CollectPayloadFromPath(const std::wstring& raw_path,
                            flutter::EncodableList* out_items,
                            size_t max_items,
                            int depth = 0) {
  if (!out_items || out_items->size() >= max_items || raw_path.empty() ||
      depth > 3) {
    return;
  }

  WIN32_FILE_ATTRIBUTE_DATA attr = {};
  if (!::GetFileAttributesExW(raw_path.c_str(), GetFileExInfoStandard, &attr)) {
    return;
  }

  if ((attr.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    std::wstring pattern = raw_path;
    if (pattern.back() != L'\\' && pattern.back() != L'/') {
      pattern.push_back(L'\\');
    }
    std::wstring dir_prefix = pattern;
    pattern.push_back(L'*');

    WIN32_FIND_DATAW find_data = {};
    HANDLE find_handle = ::FindFirstFileW(pattern.c_str(), &find_data);
    if (find_handle == INVALID_HANDLE_VALUE) {
      return;
    }
    do {
      if (wcscmp(find_data.cFileName, L".") == 0 ||
          wcscmp(find_data.cFileName, L"..") == 0) {
        continue;
      }
      if ((find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
        std::wstring child_path = dir_prefix + find_data.cFileName;
        CollectPayloadFromPath(child_path, out_items, max_items, depth + 1);
      }
    } while (out_items->size() < max_items &&
             ::FindNextFileW(find_handle, &find_data));
    ::FindClose(find_handle);
    return;
  }

  uint64_t high = static_cast<uint64_t>(attr.nFileSizeHigh);
  uint64_t low = static_cast<uint64_t>(attr.nFileSizeLow);
  int64_t file_size = static_cast<int64_t>((high << 32) | low);
  if (file_size <= 0) {
    return;
  }

  size_t sep = raw_path.find_last_of(L"\\/");
  std::wstring file_name =
      (sep == std::wstring::npos) ? raw_path : raw_path.substr(sep + 1);

  std::string name_utf8 = Utf8FromUtf16(file_name.c_str());
  std::string path_utf8 = Utf8FromUtf16(raw_path.c_str());
  if (path_utf8.empty()) {
    return;
  }

  flutter::EncodableMap item;
  item[flutter::EncodableValue("name")] = flutter::EncodableValue(name_utf8);
  item[flutter::EncodableValue("path")] = flutter::EncodableValue(path_utf8);
  item[flutter::EncodableValue("size")] = flutter::EncodableValue(file_size);
  out_items->push_back(flutter::EncodableValue(item));
}

std::vector<std::wstring> ExtractPathsFromHdrop(HDROP hdrop) {
  std::vector<std::wstring> paths;
  if (!hdrop) {
    return paths;
  }
  UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count && paths.size() < 10; ++i) {
    UINT len = ::DragQueryFileW(hdrop, i, nullptr, 0);
    if (len > 0) {
      std::wstring path(static_cast<size_t>(len) + 1, L'\0');
      ::DragQueryFileW(hdrop, i, path.data(), len + 1);
      path.resize(len);
      paths.push_back(path);
    }
  }
  return paths;
}

LRESULT CALLBACK ChildDropSubclassProc(HWND hwnd,
                                       UINT message,
                                       WPARAM wparam,
                                       LPARAM lparam) {
  if (message == WM_DROPFILES && g_active_flutter_window) {
    HDROP hdrop = reinterpret_cast<HDROP>(wparam);
    std::vector<std::wstring> paths = ExtractPathsFromHdrop(hdrop);
    ::DragFinish(hdrop);
    if (!paths.empty()) {
      g_active_flutter_window->PostFilesDropped(std::move(paths));
    }
    return 0;
  }
  if (g_prev_child_wndproc) {
    return ::CallWindowProcW(g_prev_child_wndproc, hwnd, message, wparam,
                             lparam);
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

class WinFileDropTarget final : public IDropTarget {
 public:
  explicit WinFileDropTarget(FlutterWindow* owner)
      : ref_count_(1), owner_(owner), has_files_(false), is_entered_(false) {}

  virtual ~WinFileDropTarget() = default;

  void DetachOwner() { owner_ = nullptr; }

  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) {
      return E_POINTER;
    }
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IDropTarget)) {
      *ppv = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  STDMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
  }

  STDMETHODIMP_(ULONG) Release() override {
    LONG count = ::InterlockedDecrement(&ref_count_);
    if (count == 0) {
      delete this;
      return 0;
    }
    return static_cast<ULONG>(count);
  }

  STDMETHODIMP DragEnter(IDataObject* data_object,
                         DWORD /*key_state*/,
                         POINTL /*pt*/,
                         DWORD* effect) override {
    has_files_ = HasSupportedFileData(data_object);
    if (effect) {
      *effect = ChooseDropEffect(has_files_, *effect);
    }
    if (has_files_ && !is_entered_) {
      is_entered_ = true;
      if (owner_) {
        owner_->PostFileDragDelta(1);
      }
    }
    return S_OK;
  }

  STDMETHODIMP DragOver(DWORD /*key_state*/,
                        POINTL /*pt*/,
                        DWORD* effect) override {
    if (effect) {
      *effect = ChooseDropEffect(has_files_, *effect);
    }
    return S_OK;
  }

  STDMETHODIMP DragLeave() override {
    has_files_ = false;
    if (is_entered_) {
      is_entered_ = false;
      if (owner_) {
        owner_->PostFileDragDelta(-1);
      }
    }
    return S_OK;
  }

  STDMETHODIMP Drop(IDataObject* data_object,
                    DWORD /*key_state*/,
                    POINTL /*pt*/,
                    DWORD* effect) override {
    if (is_entered_) {
      is_entered_ = false;
      if (owner_) {
        owner_->PostFileDragDelta(-1);
      }
    }

    std::vector<std::wstring> paths = ExtractPathsFromDataObject(data_object);
    if (paths.empty()) {
      if (effect) {
        *effect = DROPEFFECT_NONE;
      }
      has_files_ = false;
      return S_OK;
    }

    if (effect) {
      *effect = ChooseDropEffect(true, *effect);
    }
    has_files_ = false;
    if (owner_) {
      owner_->PostFilesDropped(std::move(paths));
    }
    return S_OK;
  }

 private:
  static DWORD ChooseDropEffect(bool has_files, DWORD allowed) {
    if (!has_files) {
      return DROPEFFECT_NONE;
    }
    if ((allowed & DROPEFFECT_COPY) != 0) {
      return DROPEFFECT_COPY;
    }
    if ((allowed & DROPEFFECT_MOVE) != 0) {
      return DROPEFFECT_MOVE;
    }
    if ((allowed & DROPEFFECT_LINK) != 0) {
      return DROPEFFECT_LINK;
    }
    return DROPEFFECT_COPY;
  }

  static UINT GetFileNameWFormat() {
    static UINT fmt = ::RegisterClipboardFormatW(CFSTR_FILENAMEW);
    return fmt;
  }

  static bool HasSupportedFileData(IDataObject* data_object) {
    if (!data_object) {
      return false;
    }
    FORMATETC fmt_hdrop = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1,
                           TYMED_HGLOBAL};
    if (SUCCEEDED(data_object->QueryGetData(&fmt_hdrop))) {
      return true;
    }
    UINT fn_fmt = GetFileNameWFormat();
    if (fn_fmt != 0) {
      FORMATETC fmt_fn = {static_cast<CLIPFORMAT>(fn_fmt), nullptr,
                          DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
      if (SUCCEEDED(data_object->QueryGetData(&fmt_fn))) {
        return true;
      }
    }
    return false;
  }

  static std::vector<std::wstring> ExtractPathsFromDataObject(
      IDataObject* data_object) {
    std::vector<std::wstring> paths;
    if (!data_object) {
      return paths;
    }

    FORMATETC fmt_hdrop = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1,
                           TYMED_HGLOBAL};
    STGMEDIUM stg = {};
    if (SUCCEEDED(data_object->GetData(&fmt_hdrop, &stg))) {
      HDROP hdrop = static_cast<HDROP>(::GlobalLock(stg.hGlobal));
      if (hdrop) {
        paths = ExtractPathsFromHdrop(hdrop);
        ::GlobalUnlock(stg.hGlobal);
      }
      ::ReleaseStgMedium(&stg);
    }

    if (paths.empty()) {
      UINT fn_fmt = GetFileNameWFormat();
      if (fn_fmt != 0) {
        FORMATETC fmt_fn = {static_cast<CLIPFORMAT>(fn_fmt), nullptr,
                            DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM stg_fn = {};
        if (SUCCEEDED(data_object->GetData(&fmt_fn, &stg_fn))) {
          const wchar_t* raw_str =
              static_cast<const wchar_t*>(::GlobalLock(stg_fn.hGlobal));
          if (raw_str && raw_str[0] != L'\0') {
            paths.emplace_back(raw_str);
          }
          if (raw_str) {
            ::GlobalUnlock(stg_fn.hGlobal);
          }
          ::ReleaseStgMedium(&stg_fn);
        }
      }
    }
    return paths;
  }

  LONG ref_count_;
  FlutterWindow* owner_;
  bool has_files_;
  bool is_entered_;
};

HWND CreateTopmostDialogOwnerWindow(HWND reference_hwnd) {
  int x = 200;
  int y = 200;
  if (reference_hwnd && ::IsWindow(reference_hwnd)) {
    RECT rc = {};
    if (::GetWindowRect(reference_hwnd, &rc)) {
      x = rc.left + 40;
      y = rc.top + 40;
    }
  }
  HWND owner = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", L"",
      WS_POPUP, x, y, 1, 1, nullptr, nullptr, ::GetModuleHandleW(nullptr),
      nullptr);
  if (owner) {
    ::ShowWindow(owner, SW_SHOWNA);
    ::SetForegroundWindow(owner);
  }
  return owner;
}

std::vector<std::wstring> ShowWinGetOpenFileNameFallback(bool media_only,
                                                         HWND owner_hwnd) {
  std::vector<std::wstring> selected_paths;
  std::vector<wchar_t> buffer(32768, L'\0');

  OPENFILENAMEW ofn = {};
  ofn.lStructSize = sizeof(OPENFILENAMEW);
  ofn.hwndOwner = owner_hwnd;
  ofn.lpstrFile = buffer.data();
  ofn.nMaxFile = static_cast<DWORD>(buffer.size());
  if (media_only) {
    ofn.lpstrFilter =
        L"Images & Videos\0*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.mp4;*.mov;*.mkv;*.webm;*.avi;*.m4v\0All Files\0*.*\0\0";
  } else {
    ofn.lpstrFilter = L"All Files\0*.*\0\0";
  }
  ofn.nFilterIndex = 1;
  ofn.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST |
              OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_HIDEREADONLY |
              OFN_DONTADDTORECENT;

  if (::GetOpenFileNameW(&ofn)) {
    const wchar_t* p = buffer.data();
    std::wstring first(p);
    p += first.size() + 1;
    if (*p == L'\0') {
      if (!first.empty()) {
        selected_paths.push_back(first);
      }
    } else {
      std::wstring dir = first;
      if (!dir.empty() && dir.back() != L'\\' && dir.back() != L'/') {
        dir.push_back(L'\\');
      }
      while (*p != L'\0' && selected_paths.size() < 10) {
        std::wstring fname(p);
        selected_paths.push_back(dir + fname);
        p += fname.size() + 1;
      }
    }
  }
  return selected_paths;
}

std::vector<std::wstring> ShowWinFileOpenDialog(bool media_only,
                                                HWND reference_hwnd) {
  HWND owner_hwnd = CreateTopmostDialogOwnerWindow(reference_hwnd);
  std::vector<std::wstring> selected_paths;
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || !dialog) {
    selected_paths = ShowWinGetOpenFileNameFallback(media_only, owner_hwnd);
    if (owner_hwnd) {
      ::DestroyWindow(owner_hwnd);
    }
    return selected_paths;
  }

  DWORD options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_ALLOWMULTISELECT |
                       FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST |
                       FOS_NOCHANGEDIR | FOS_DONTADDTORECENT);
  }

  if (media_only) {
    const COMDLG_FILTERSPEC filters[] = {
        {L"Images & Videos",
         L"*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.mp4;*.mov;*.mkv;*.webm;*.avi;*.m4v"},
        {L"All Files", L"*.*"},
    };
    dialog->SetFileTypes(2, filters);
  } else {
    const COMDLG_FILTERSPEC filters[] = {
        {L"All Files", L"*.*"},
    };
    dialog->SetFileTypes(1, filters);
  }

  HRESULT show_hr = dialog->Show(owner_hwnd);
  if (SUCCEEDED(show_hr)) {
    IShellItemArray* items = nullptr;
    if (SUCCEEDED(dialog->GetResults(&items)) && items) {
      DWORD count = 0;
      items->GetCount(&count);
      for (DWORD i = 0; i < count && selected_paths.size() < 10; ++i) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(items->GetItemAt(i, &item)) && item) {
          PWSTR psz_path = nullptr;
          if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &psz_path)) &&
              psz_path) {
            selected_paths.emplace_back(psz_path);
            ::CoTaskMemFree(psz_path);
          }
          item->Release();
        }
      }
      items->Release();
    }
  } else if (show_hr != HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->Release();
    selected_paths = ShowWinGetOpenFileNameFallback(media_only, owner_hwnd);
    if (owner_hwnd) {
      ::DestroyWindow(owner_hwnd);
    }
    return selected_paths;
  }

  dialog->Release();
  if (owner_hwnd) {
    ::DestroyWindow(owner_hwnd);
  }
  return selected_paths;
}

void EnableWindowDragMessages(HWND hwnd) {
  if (!hwnd) {
    return;
  }
  ::DragAcceptFiles(hwnd, TRUE);
  ::ChangeWindowMessageFilterEx(hwnd, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
  ::ChangeWindowMessageFilterEx(hwnd, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
  ::ChangeWindowMessageFilterEx(hwnd, 0x0049 /*WM_COPYGLOBALDATA*/,
                                MSGFLT_ALLOW, nullptr);
}

void EnsureGdiPlusInitialized() {
  static std::atomic<bool> initialized{false};
  if (!initialized.exchange(true)) {
    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR token = 0;
    Gdiplus::GdiplusStartup(&token, &input, nullptr);
  }
}

bool GetJpegEncoderClsid(CLSID* out_clsid) {
  static bool cached = false;
  static CLSID cached_clsid = {};
  if (cached) {
    *out_clsid = cached_clsid;
    return true;
  }
  UINT num = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) {
    return false;
  }
  std::vector<uint8_t> buf(size);
  auto* info = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buf.data());
  if (Gdiplus::GetImageEncoders(num, size, info) != Gdiplus::Ok) {
    return false;
  }
  for (UINT i = 0; i < num; ++i) {
    if ( info[i].MimeType && wcscmp(info[i].MimeType, L"image/jpeg") == 0) {
      cached_clsid = info[i].Clsid;
      cached = true;
      *out_clsid = cached_clsid;
      return true;
    }
  }
  return false;
}

bool CaptureWinDesktopJpegBytes(int max_width,
                                int quality,
                                std::vector<uint8_t>* out_bytes,
                                int* out_w,
                                int* out_h,
                                double* out_cx,
                                double* out_cy) {
  EnsureGdiPlusInitialized();
  int src_w = ::GetSystemMetrics(SM_CXSCREEN);
  int src_h = ::GetSystemMetrics(SM_CYSCREEN);
  if (src_w <= 0 || src_h <= 0) {
    return false;
  }
  int clamped_max_w = max(480, min(2560, max_width));
  double scale = min(1.0, static_cast<double>(clamped_max_w) / src_w);
  int dst_w = max(1, static_cast<int>(std::round(src_w * scale)));
  int dst_h = max(1, static_cast<int>(std::round(src_h * scale)));

  HDC screen_dc = ::GetDC(nullptr);
  if (!screen_dc) {
    return false;
  }
  HDC mem_dc = ::CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ::ReleaseDC(nullptr, screen_dc);
    return false;
  }
  HBITMAP bmp = ::CreateCompatibleBitmap(screen_dc, dst_w, dst_h);
  if (!bmp) {
    ::DeleteDC(mem_dc);
    ::ReleaseDC(nullptr, screen_dc);
    return false;
  }
  HGDIOBJ old_obj = ::SelectObject(mem_dc, bmp);
  ::SetStretchBltMode(mem_dc, HALFTONE);
  ::SetBrushOrgEx(mem_dc, 0, 0, nullptr);
  BOOL blt_ok = ::StretchBlt(mem_dc, 0, 0, dst_w, dst_h, screen_dc, 0, 0,
                             src_w, src_h, SRCCOPY | CAPTUREBLT);

  POINT cur_pt = {src_w / 2, src_h / 2};
  ::GetCursorPos(&cur_pt);
  double norm_x =
      max(0.0, min(1.0, static_cast<double>(cur_pt.x) / max(1, src_w)));
  double norm_y =
      max(0.0, min(1.0, static_cast<double>(cur_pt.y) / max(1, src_h)));
  int cx = static_cast<int>(std::round(norm_x * dst_w));
  int cy = static_cast<int>(std::round(norm_y * dst_h));

  // Draw actual Windows cursor icon + cyan indicator ring
  CURSORINFO ci = {};
  ci.cbSize = sizeof(ci);
  if (::GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING) && ci.hCursor) {
    ::DrawIconEx(mem_dc, cx, cy, ci.hCursor, 0, 0, 0, nullptr, DI_NORMAL);
  }
  HPEN pen = ::CreatePen(PS_SOLID, 2, RGB(56, 189, 248));
  HGDIOBJ old_pen = ::SelectObject(mem_dc, pen);
  HGDIOBJ old_brush = ::SelectObject(mem_dc, ::GetStockObject(HOLLOW_BRUSH));
  ::Ellipse(mem_dc, cx - 7, cy - 7, cx + 7, cy + 7);
  ::SelectObject(mem_dc, old_brush);
  ::SelectObject(mem_dc, old_pen);
  ::DeleteObject(pen);

  ::SelectObject(mem_dc, old_obj);
  ::DeleteDC(mem_dc);
  ::ReleaseDC(nullptr, screen_dc);

  if (!blt_ok) {
    ::DeleteObject(bmp);
    return false;
  }

  CLSID jpeg_clsid = {};
  if (!GetJpegEncoderClsid(&jpeg_clsid)) {
    ::DeleteObject(bmp);
    return false;
  }

  bool encoded_ok = false;
  {
    Gdiplus::Bitmap gdi_bmp(bmp, nullptr);
    IStream* stream = nullptr;
    if (SUCCEEDED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream)) && stream) {
      ULONG q = static_cast<ULONG>(max(25, min(95, quality)));
      Gdiplus::EncoderParameters ep = {};
      ep.Count = 1;
      ep.Parameter[0].Guid = Gdiplus::EncoderQuality;
      ep.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
      ep.Parameter[0].NumberOfValues = 1;
      ep.Parameter[0].Value = &q;

      if (gdi_bmp.Save(stream, &jpeg_clsid, &ep) == Gdiplus::Ok) {
        HGLOBAL hmem = nullptr;
        if (SUCCEEDED(::GetHGlobalFromStream(stream, &hmem)) && hmem) {
          STATSTG stat = {};
          if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) &&
              stat.cbSize.QuadPart > 0) {
            size_t len = static_cast<size_t>(stat.cbSize.QuadPart);
            void* ptr = ::GlobalLock(hmem);
            if (ptr) {
              out_bytes->resize(len);
              std::memcpy(out_bytes->data(), ptr, len);
              ::GlobalUnlock(hmem);
              encoded_ok = true;
            }
          }
        }
      }
      stream->Release();
    }
  }
  ::DeleteObject(bmp);

  if (encoded_ok) {
    *out_w = dst_w;
    *out_h = dst_h;
    *out_cx = norm_x;
    *out_cy = norm_y;
  }
  return encoded_ok;
}

bool InjectWinDesktopMouse(const std::string& type,
                           double nx,
                           double ny,
                           int delta_x,
                           int delta_y) {
  int sw = max(1, ::GetSystemMetrics(SM_CXSCREEN));
  int sh = max(1, ::GetSystemMetrics(SM_CYSCREEN));
  double clamped_nx = max(0.0, min(1.0, nx));
  double clamped_ny = max(0.0, min(1.0, ny));
  int px = static_cast<int>(std::round(clamped_nx * (sw - 1)));
  int py = static_cast<int>(std::round(clamped_ny * (sh - 1)));
  LONG abs_x = static_cast<LONG>(std::round(clamped_nx * 65535.0));
  LONG abs_y = static_cast<LONG>(std::round(clamped_ny * 65535.0));

  ::SetCursorPos(px, py);

  auto send_mouse_flags = [&](DWORD flags, DWORD mouse_data = 0) {
    INPUT inp = {};
    inp.type = INPUT_MOUSE;
    inp.mi.dx = abs_x;
    inp.mi.dy = abs_y;
    inp.mi.mouseData = mouse_data;
    inp.mi.dwFlags = flags | MOUSEEVENTF_ABSOLUTE;
    ::SendInput(1, &inp, sizeof(INPUT));
  };

  send_mouse_flags(MOUSEEVENTF_MOVE);

  if (type == "move" || type == "drag") {
    return true;
  }
  if (type == "down") {
    send_mouse_flags(MOUSEEVENTF_LEFTDOWN);
    return true;
  }
  if (type == "up") {
    send_mouse_flags(MOUSEEVENTF_LEFTUP);
    return true;
  }
  if (type == "tap") {
    send_mouse_flags(MOUSEEVENTF_LEFTDOWN);
    send_mouse_flags(MOUSEEVENTF_LEFTUP);
    return true;
  }
  if (type == "double_tap") {
    send_mouse_flags(MOUSEEVENTF_LEFTDOWN);
    send_mouse_flags(MOUSEEVENTF_LEFTUP);
    send_mouse_flags(MOUSEEVENTF_LEFTDOWN);
    send_mouse_flags(MOUSEEVENTF_LEFTUP);
    return true;
  }
  if (type == "right_click") {
    send_mouse_flags(MOUSEEVENTF_RIGHTDOWN);
    send_mouse_flags(MOUSEEVENTF_RIGHTUP);
    return true;
  }
  if (type == "scroll") {
    if (delta_y != 0) {
      send_mouse_flags(MOUSEEVENTF_WHEEL,
                       static_cast<DWORD>(static_cast<int>(delta_y * 3)));
    }
    if (delta_x != 0) {
      send_mouse_flags(MOUSEEVENTF_HWHEEL,
                       static_cast<DWORD>(static_cast<int>(delta_x * 3)));
    }
    return true;
  }
  return true;
}

void SendWinVirtualKeyChord( const std::vector<WORD>& mods, WORD main_vk) {
  std::vector<INPUT> inputs;
  for (WORD m : mods) {
    INPUT inp = {};
    inp.type = INPUT_KEYBOARD;
    inp.ki.wVk = m;
    inputs.push_back(inp);
  }
  if (main_vk != 0) {
    INPUT down = {};
    down.type = INPUT_KEYBOARD;
    down.ki.wVk = main_vk;
    inputs.push_back(down);

    INPUT up = {};
    up.type = INPUT_KEYBOARD;
    up.ki.wVk = main_vk;
    up.ki.dwFlags = KEYEVENTF_KEYUP;
    inputs.push_back(up);
  }
  for (auto it = mods.rbegin(); it != mods.rend(); ++it) {
    INPUT inp = {};
    inp.type = INPUT_KEYBOARD;
    inp.ki.wVk = *it;
    inp.ki.dwFlags = KEYEVENTF_KEYUP;
    inputs.push_back(inp);
  }
  if (!inputs.empty()) {
    ::SendInput(static_cast<UINT>(inputs.size()), inputs.data(),
                sizeof(INPUT));
  }
}

bool InjectWinDesktopKey(const std::string& raw_key,
                         const std::string& text_utf8,
                         HWND app_hwnd) {
  if (!text_utf8.empty()) {
    int wlen =
        ::MultiByteToWideChar(CP_UTF8, 0, text_utf8.c_str(), -1, nullptr, 0);
    if (wlen <= 1) {
      return false;
    }
    std::wstring wstr(static_cast<size_t>(wlen) - 1, L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, text_utf8.c_str(), -1, wstr.data(),
                          wlen);
    std::vector<INPUT> inputs;
    inputs.reserve(wstr.size() * 2);
    for (wchar_t ch : wstr) {
      INPUT down = {};
      down.type = INPUT_KEYBOARD;
      down.ki.wScan = ch;
      down.ki.dwFlags = KEYEVENTF_UNICODE;
      inputs.push_back(down);

      INPUT up = {};
      up.type = INPUT_KEYBOARD;
      up.ki.wScan = ch;
      up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      inputs.push_back(up);
    }
    ::SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    return true;
  }

  std::string key;
  key.reserve(raw_key.size());
  for (unsigned char c : raw_key) {
    if (!std::isspace(c)) {
      key.push_back(static_cast<char>(std::tolower(c)));
    }
  }
  if (key.empty()) {
    return false;
  }

  if (key == "minimize_app" || key == "hide_app") {
    if (app_hwnd && ::IsWindow(app_hwnd)) {
      ::ShowWindow(app_hwnd, SW_MINIMIZE);
    }
    return true;
  }
  if (key == "show_desktop" || key == "win+d") {
    if (app_hwnd && ::IsWindow(app_hwnd)) {
      ::ShowWindow(app_hwnd, SW_MINIMIZE);
    }
    SendWinVirtualKeyChord({VK_LWIN}, 'D');
    return true;
  }
  if (key == "mission_control" || key == "win+tab") {
    SendWinVirtualKeyChord({VK_LWIN}, VK_TAB);
    return true;
  }

  std::vector<WORD> mods;
  std::string base_key = key;
  size_t plus_pos = 0;
  while ((plus_pos = base_key.find('+')) != std::string::npos) {
    std::string mod = base_key.substr(0, plus_pos);
    base_key.erase(0, plus_pos + 1);
    if (mod == "ctrl" || mod == "control" || mod == "cmd" || mod == "command") {
      mods.push_back(VK_CONTROL);
    } else if (mod == "alt" || mod == "option") {
      mods.push_back(VK_MENU);
    } else if (mod == "shift") {
      mods.push_back(VK_SHIFT);
    } else if (mod == "win" || mod == "meta") {
      mods.push_back(VK_LWIN);
    }
  }

  WORD vk = 0;
  if (base_key == "enter" || base_key == "ok" || base_key == "return") {
    vk = VK_RETURN;
  } else if (base_key == "back" || base_key == "escape" || base_key == "esc") {
    vk = VK_ESCAPE;
  } else if (base_key == "tab") {
    vk = VK_TAB;
  } else if (base_key == "space" || base_key == "play_pause") {
    vk = VK_SPACE;
  } else if (base_key == "backspace") {
    vk = VK_BACK;
  } else if (base_key == "delete" || base_key == "del") {
    vk = VK_DELETE;
  } else if (base_key == "up") {
    vk = VK_UP;
  } else if (base_key == "down") {
    vk = VK_DOWN;
  } else if (base_key == "left") {
    vk = VK_LEFT;
  } else if (base_key == "right") {
    vk = VK_RIGHT;
  } else if (base_key == "home") {
    vk = VK_HOME;
  } else if (base_key == "end") {
    vk = VK_END;
  } else if (base_key == "pageup") {
    vk = VK_PRIOR;
  } else if (base_key == "pagedown") {
    vk = VK_NEXT;
  } else if (base_key.size() == 1) {
    char ch = base_key[0];
    if (ch >= 'a' && ch <= 'z') {
      vk = static_cast<WORD>(ch - 'a' + 'A');
    } else if (ch >= '0' && ch <= '9') {
      vk = static_cast<WORD>(ch);
    }
  } else if (base_key.size() >= 2 && base_key[0] == 'f') {
    int fn = std::atoi(base_key.c_str() + 1);
    if (fn >= 1 && fn <= 12) {
      vk = static_cast<WORD>(VK_F1 + (fn - 1));
    }
  }

  if (vk != 0 || !mods.empty()) {
    SendWinVirtualKeyChord(mods, vk);
    return true;
  }
  return false;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project),
      window_alive_(std::make_shared<std::atomic<bool>>(true)) {}

FlutterWindow::~FlutterWindow() {
  if (window_alive_) {
    window_alive_->store(false);
  }
  if (g_active_flutter_window == this) {
    g_active_flutter_window = nullptr;
  }
}

void FlutterWindow::PostFileDragDelta(int delta) {
  HWND hwnd = GetHandle();
  if (hwnd) {
    ::PostMessageW(hwnd, kWmFileDragDelta, static_cast<WPARAM>(delta), 0);
  }
}

void FlutterWindow::PostFilesDropped(std::vector<std::wstring> paths) {
  if (paths.empty()) {
    return;
  }
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  auto* heap_paths = new std::vector<std::wstring>(std::move(paths));
  if (!::PostMessageW(hwnd, kWmFilesDropped, 0,
                      reinterpret_cast<LPARAM>(heap_paths))) {
    delete heap_paths;
  }
}

void FlutterWindow::NotifyFileDragUpdated(bool active) {
  if (!utils_channel_) {
    return;
  }
  flutter::EncodableMap args;
  args[flutter::EncodableValue("active")] = flutter::EncodableValue(active);
  utils_channel_->InvokeMethod(
      "onFileDragUpdated",
      std::make_unique<flutter::EncodableValue>(args));
}

void FlutterWindow::NotifyFilesDropped(
    const std::vector<std::wstring>& paths) {
  if (!utils_channel_ || paths.empty()) {
    return;
  }
  flutter::EncodableList items;
  for (const auto& path : paths) {
    if (items.size() >= 10) {
      break;
    }
    CollectPayloadFromPath(path, &items, 10);
  }
  if (!items.empty()) {
    utils_channel_->InvokeMethod(
        "onFilesDropped",
        std::make_unique<flutter::EncodableValue>(items));
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  ::OleInitialize(nullptr);
  g_active_flutter_window = this;

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  utils_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.linsion.m3u8_client/native_utils",
          &flutter::StandardMethodCodec::GetInstance());
  utils_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "pickFiles") {
          bool media_only = false;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = map->find(flutter::EncodableValue("mediaOnly"));
            if (it != map->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) {
                media_only = *b;
              }
            }
          }

          if (is_picking_files_.exchange(true)) {
            result->Success(
                flutter::EncodableValue(flutter::EncodableList()));
            return;
          }

          ::AllowSetForegroundWindow(ASFW_ANY);
          HWND target_hwnd = GetHandle();
          auto alive_flag = window_alive_;
          auto* payload = new PickFilesResultPayload();
          payload->result = std::move(result);

          std::thread([this, target_hwnd, media_only, alive_flag, payload]() {
            HRESULT hr_com =
                ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
            std::vector<std::wstring> paths =
                ShowWinFileOpenDialog(media_only, target_hwnd);
            for (const auto& p : paths) {
              if (payload->items.size() >= 10) {
                break;
              }
              CollectPayloadFromPath(p, &payload->items, 10);
            }
            if (SUCCEEDED(hr_com)) {
              ::CoUninitialize();
            }
            if (alive_flag && alive_flag->load() && target_hwnd &&
                ::IsWindow(target_hwnd)) {
              if (::PostMessageW(target_hwnd, kWmPickFilesDone, 0,
                                 reinterpret_cast<LPARAM>(payload))) {
                return;
              }
              is_picking_files_.store(false);
            }
            delete payload;
          }).detach();
          return;
        }
        if (call.method_name() == "revealFileInFinder") {
          std::string path_utf8;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = map->find(flutter::EncodableValue("path"));
            if (it != map->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) {
                path_utf8 = *s;
              }
            }
          }
          if (!path_utf8.empty()) {
            int wlen = ::MultiByteToWideChar(CP_UTF8, 0, path_utf8.c_str(), -1,
                                             nullptr, 0);
            if (wlen > 1) {
              std::wstring wpath(static_cast<size_t>(wlen) - 1, L'\0');
              ::MultiByteToWideChar(CP_UTF8, 0, path_utf8.c_str(), -1,
                                    wpath.data(), wlen);
              for (auto& ch : wpath) {
                if (ch == L'/') ch = L'\\';
              }
              DWORD attr = ::GetFileAttributesW(wpath.c_str());
              if (attr != INVALID_FILE_ATTRIBUTES &&
                  (attr & FILE_ATTRIBUTE_DIRECTORY) == 0) {
                std::wstring param = L"/select,\"" + wpath + L"\"";
                ::ShellExecuteW(nullptr, L"open", L"explorer.exe",
                                param.c_str(), nullptr, SW_SHOWNORMAL);
              } else {
                ::ShellExecuteW(nullptr, L"open", L"explorer.exe",
                                wpath.c_str(), nullptr, SW_SHOWNORMAL);
              }
              result->Success(flutter::EncodableValue(true));
              return;
            }
          }
          result->Success(flutter::EncodableValue(false));
          return;
        }
        if (call.method_name() == "captureDesktopScreenJpeg") {
          int max_width = 1280;
          int quality = 72;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it_w = map->find(flutter::EncodableValue("maxWidth"));
            if (it_w != map->end()) {
              if (const auto* v = std::get_if<int32_t>(&it_w->second)) {
                max_width = *v;
              } else if (const auto* v64 =
                             std::get_if<int64_t>(&it_w->second)) {
                max_width = static_cast<int>(*v64);
              }
            }
            auto it_q = map->find(flutter::EncodableValue("quality"));
            if (it_q != map->end()) {
              if (const auto* v = std::get_if<int32_t>(&it_q->second)) {
                quality = *v;
              } else if (const auto* v64 =
                             std::get_if<int64_t>(&it_q->second)) {
                quality = static_cast<int>(*v64);
              }
            }
          }
          std::vector<uint8_t> jpeg_bytes;
          int out_w = 1280;
          int out_h = 720;
          double out_cx = 0.5;
          double out_cy = 0.5;
          if (CaptureWinDesktopJpegBytes(max_width, quality, &jpeg_bytes,
                                         &out_w, &out_h, &out_cx, &out_cy) &&
              !jpeg_bytes.empty()) {
            flutter::EncodableMap resp;
            resp[flutter::EncodableValue("bytes")] =
                flutter::EncodableValue(std::move(jpeg_bytes));
            resp[flutter::EncodableValue("width")] =
                flutter::EncodableValue(out_w);
            resp[flutter::EncodableValue("height")] =
                flutter::EncodableValue(out_h);
            resp[flutter::EncodableValue("cursorX")] =
                flutter::EncodableValue(out_cx);
            resp[flutter::EncodableValue("cursorY")] =
                flutter::EncodableValue(out_cy);
            result->Success(flutter::EncodableValue(resp));
          } else {
            result->Success(flutter::EncodableValue());
          }
          return;
        }
        if (call.method_name() == "injectDesktopMouseEvent") {
          std::string type = "tap";
          double nx = 0.5;
          double ny = 0.5;
          int delta_x = 0;
          int delta_y = 0;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it_t = map->find(flutter::EncodableValue("type"));
            if (it_t != map->end()) {
              if (const auto* s = std::get_if<std::string>(&it_t->second)) {
                type = *s;
              }
            }
            auto read_double = [&](const char* k, double def_val) -> double {
              auto it = map->find(flutter::EncodableValue(k));
              if (it == map->end()) return def_val;
              if (const auto* d = std::get_if<double>(&it->second)) return *d;
              if (const auto* i = std::get_if<int32_t>(&it->second))
                return static_cast<double>(*i);
              if (const auto* i64 = std::get_if<int64_t>(&it->second))
                return static_cast<double>(*i64);
              return def_val;
            };
            nx = read_double("nx", 0.5);
            ny = read_double("ny", 0.5);
            delta_x = static_cast<int>(std::round(read_double("deltaX", 0.0)));
            delta_y = static_cast<int>(std::round(read_double("deltaY", 0.0)));
          }
          bool ok = InjectWinDesktopMouse(type, nx, ny, delta_x, delta_y);
          result->Success(flutter::EncodableValue(ok));
          return;
        }
        if (call.method_name() == "injectDesktopKeyEvent") {
          std::string key;
          std::string text;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it_k = map->find(flutter::EncodableValue("key"));
            if (it_k != map->end()) {
              if (const auto* s = std::get_if<std::string>(&it_k->second)) {
                key = *s;
              }
            }
            auto it_t = map->find(flutter::EncodableValue("text"));
            if (it_t != map->end()) {
              if (const auto* s = std::get_if<std::string>(&it_t->second)) {
                text = *s;
              }
            }
          }
          bool ok = InjectWinDesktopKey(key, text, GetHandle());
          result->Success(flutter::EncodableValue(ok));
          return;
        }
        if (call.method_name() == "minimizeAppWindow") {
          HWND hwnd = GetHandle();
          if (hwnd && ::IsWindow(hwnd)) {
            ::ShowWindow(hwnd, SW_MINIMIZE);
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Success(flutter::EncodableValue(false));
          }
          return;
        }
        if (call.method_name() == "checkDesktopPermissions" ||
            call.method_name() == "requestDesktopPermissions") {
          flutter::EncodableMap resp;
          resp[flutter::EncodableValue("screenCapture")] =
              flutter::EncodableValue(true);
          resp[flutter::EncodableValue("accessibility")] =
              flutter::EncodableValue(true);
          result->Success(flutter::EncodableValue(resp));
          return;
        }
        if (call.method_name() == "startVoiceRecording") {
          ::mciSendStringW(L"close lg_tg_voice", nullptr, 0, nullptr);
          MCIERROR err = ::mciSendStringW(
              L"open new Type waveaudio Alias lg_tg_voice", nullptr, 0,
              nullptr);
          if (err == 0) {
            ::mciSendStringW(
                L"set lg_tg_voice time format ms bitspersample 16 channels 1 "
                L"samplespersec 16000",
                nullptr, 0, nullptr);
            err = ::mciSendStringW(L"record lg_tg_voice", nullptr, 0, nullptr);
          }
          flutter::EncodableMap resp;
          if (err == 0) {
            resp[flutter::EncodableValue("ok")] =
                flutter::EncodableValue(true);
            resp[flutter::EncodableValue("mimeType")] =
                flutter::EncodableValue("audio/wav");
          } else {
            resp[flutter::EncodableValue("ok")] =
                flutter::EncodableValue(false);
            resp[flutter::EncodableValue("error")] =
                flutter::EncodableValue("无法开启麦克风录音设备");
          }
          result->Success(flutter::EncodableValue(resp));
          return;
        }
        if (call.method_name() == "stopVoiceRecording") {
          ::mciSendStringW(L"stop lg_tg_voice", nullptr, 0, nullptr);
          wchar_t temp_dir[MAX_PATH] = {};
          ::GetTempPathW(MAX_PATH, temp_dir);
          std::wstring file_name =
              L"voice_" + std::to_wstring(::GetTickCount64()) + L".wav";
          std::wstring full_path = std::wstring(temp_dir) + file_name;
          std::wstring save_cmd =
              L"save lg_tg_voice \"" + full_path + L"\"";
          MCIERROR err =
              ::mciSendStringW(save_cmd.c_str(), nullptr, 0, nullptr);
          ::mciSendStringW(L"close lg_tg_voice", nullptr, 0, nullptr);
          if (err == 0) {
            std::ifstream ifs(full_path, std::ios::binary | std::ios::ate);
            if (ifs.is_open()) {
              auto sz = ifs.tellg();
              if (sz > 0) {
                std::vector<uint8_t> bytes(static_cast<size_t>(sz));
                ifs.seekg(0, std::ios::beg);
                ifs.read(reinterpret_cast<char*>(bytes.data()), sz);
                ifs.close();
                flutter::EncodableMap resp;
                resp[flutter::EncodableValue("ok")] =
                    flutter::EncodableValue(true);
                resp[flutter::EncodableValue("path")] =
                    flutter::EncodableValue(Utf8FromUtf16(full_path.c_str()));
                resp[flutter::EncodableValue("name")] =
                    flutter::EncodableValue(Utf8FromUtf16(file_name.c_str()));
                resp[flutter::EncodableValue("mimeType")] =
                    flutter::EncodableValue("audio/wav");
                resp[flutter::EncodableValue("size")] =
                    flutter::EncodableValue(static_cast<int64_t>(sz));
                resp[flutter::EncodableValue("bytes")] =
                    flutter::EncodableValue(std::move(bytes));
                result->Success(flutter::EncodableValue(resp));
                return;
              }
            }
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "cancelVoiceRecording") {
          ::mciSendStringW(L"stop lg_tg_voice", nullptr, 0, nullptr);
          ::mciSendStringW(L"close lg_tg_voice", nullptr, 0, nullptr);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "recognizeVoiceToText") {
          // Trigger Windows native Voice Typing (Win + H) if no wave file or alongside wave file
          SendWinVirtualKeyChord({VK_LWIN}, 'H');
          flutter::EncodableMap resp;
          resp[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
          resp[flutter::EncodableValue("text")] = flutter::EncodableValue("");
          resp[flutter::EncodableValue("dictationTriggered")] =
              flutter::EncodableValue(true);
          result->Success(flutter::EncodableValue(resp));
          return;
        }
        if (call.method_name() == "reportIncomingSystemCall") {
          HWND hwnd = GetHandle();
          if (hwnd && ::IsWindow(hwnd)) {
            FLASHWINFO fwi = {};
            fwi.cbSize = sizeof(FLASHWINFO);
            fwi.hwnd = hwnd;
            fwi.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
            fwi.uCount = 6;
            fwi.dwTimeout = 0;
            ::FlashWindowEx(&fwi);
          }
          ::MessageBeep(MB_ICONINFORMATION);
          flutter::EncodableMap resp;
          resp[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
          resp[flutter::EncodableValue("callKit")] =
              flutter::EncodableValue(false);
          result->Success(flutter::EncodableValue(resp));
          return;
        }
        if (call.method_name() == "startOutgoingSystemCall") {
          flutter::EncodableMap resp;
          resp[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
          resp[flutter::EncodableValue("callKit")] =
              flutter::EncodableValue(false);
          result->Success(flutter::EncodableValue(resp));
          return;
        }
        if (call.method_name() == "endSystemCall") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });

  HWND child_hwnd = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child_hwnd);

  HWND top_hwnd = GetHandle();
  if (top_hwnd) {
    EnableWindowDragMessages(top_hwnd);
    top_drop_target_ = new WinFileDropTarget(this);
    ::RevokeDragDrop(top_hwnd);
    ::RegisterDragDrop(top_hwnd, top_drop_target_);
  }
  if (child_hwnd && child_hwnd != top_hwnd) {
    EnableWindowDragMessages(child_hwnd);
    child_drop_target_ = new WinFileDropTarget(this);
    ::RevokeDragDrop(child_hwnd);
    ::RegisterDragDrop(child_hwnd, child_drop_target_);

    g_hooked_child_hwnd = child_hwnd;
    g_prev_child_wndproc = reinterpret_cast<WNDPROC>(::SetWindowLongPtrW(
        child_hwnd, GWLP_WNDPROC,
        reinterpret_cast<LONG_PTR>(ChildDropSubclassProc)));
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_alive_) {
    window_alive_->store(false);
  }
  if (g_active_flutter_window == this) {
    g_active_flutter_window = nullptr;
  }
  if (g_hooked_child_hwnd && g_prev_child_wndproc) {
    ::SetWindowLongPtrW(g_hooked_child_hwnd, GWLP_WNDPROC,
                        reinterpret_cast<LONG_PTR>(g_prev_child_wndproc));
    g_hooked_child_hwnd = nullptr;
    g_prev_child_wndproc = nullptr;
  }
  if (flutter_controller_ && flutter_controller_->view()) {
    HWND child_hwnd = flutter_controller_->view()->GetNativeWindow();
    if (child_hwnd) {
      ::RevokeDragDrop(child_hwnd);
    }
  }
  if (GetHandle()) {
    ::RevokeDragDrop(GetHandle());
  }
  if (child_drop_target_) {
    static_cast<WinFileDropTarget*>(child_drop_target_)->DetachOwner();
    child_drop_target_->Release();
    child_drop_target_ = nullptr;
  }
  if (top_drop_target_) {
    static_cast<WinFileDropTarget*>(top_drop_target_)->DetachOwner();
    top_drop_target_->Release();
    top_drop_target_ = nullptr;
  }
  utils_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  ::OleUninitialize();

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_DROPFILES) {
    HDROP hdrop = reinterpret_cast<HDROP>(wparam);
    std::vector<std::wstring> paths = ExtractPathsFromHdrop(hdrop);
    ::DragFinish(hdrop);
    active_drag_targets_ = 0;
    NotifyFileDragUpdated(false);
    if (!paths.empty()) {
      NotifyFilesDropped(paths);
    }
    return 0;
  }

  if (message == kWmFileDragDelta) {
    int delta = static_cast<int>(wparam);
    bool was_active = active_drag_targets_ > 0;
    active_drag_targets_ += delta;
    if (active_drag_targets_ < 0) {
      active_drag_targets_ = 0;
    }
    bool now_active = active_drag_targets_ > 0;
    if (was_active != now_active) {
      NotifyFileDragUpdated(now_active);
    }
    return 0;
  }

  if (message == kWmFilesDropped) {
    auto* heap_paths = reinterpret_cast<std::vector<std::wstring>*>(lparam);
    active_drag_targets_ = 0;
    NotifyFileDragUpdated(false);
    if (heap_paths) {
      if (!heap_paths->empty()) {
        NotifyFilesDropped(*heap_paths);
      }
      delete heap_paths;
    }
    return 0;
  }

  if (message == kWmPickFilesDone) {
    is_picking_files_.store(false);
    auto* payload = reinterpret_cast<PickFilesResultPayload*>(lparam);
    if (payload) {
      if (payload->result) {
        payload->result->Success(flutter::EncodableValue(payload->items));
      }
      delete payload;
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
