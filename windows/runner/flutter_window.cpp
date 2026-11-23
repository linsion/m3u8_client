#include "flutter_window.h"

#include <commdlg.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <atomic>
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

std::vector<std::wstring> ShowWinGetOpenFileNameFallback(bool media_only) {
  std::vector<std::wstring> selected_paths;
  std::vector<wchar_t> buffer(32768, L'\0');

  OPENFILENAMEW ofn = {};
  ofn.lStructSize = sizeof(OPENFILENAMEW);
  ofn.hwndOwner = nullptr;
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

std::vector<std::wstring> ShowWinFileOpenDialog(bool media_only) {
  std::vector<std::wstring> selected_paths;
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || !dialog) {
    return ShowWinGetOpenFileNameFallback(media_only);
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

  // Pass nullptr as parent_hwnd on this dedicated background STA thread so the
  // dialog runs on its own message queue without ever locking or disabling the
  // Flutter UI window or causing cross-thread SendMessage deadlocks.
  HRESULT show_hr = dialog->Show(nullptr);
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
    return ShowWinGetOpenFileNameFallback(media_only);
  }

  dialog->Release();
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

          std::thread([target_hwnd, media_only, alive_flag, payload]() {
            HRESULT hr_com =
                ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
            std::vector<std::wstring> paths = ShowWinFileOpenDialog(media_only);
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
            }
            delete payload;
          }).detach();
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
