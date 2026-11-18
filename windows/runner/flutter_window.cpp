#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

void CollectPayloadFromPath(const std::wstring& raw_path,
                            flutter::EncodableList* out_items,
                            size_t max_items) {
  if (!out_items || out_items->size() >= max_items || raw_path.empty()) {
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
      if ((find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
        std::wstring child_path = dir_prefix + find_data.cFileName;
        CollectPayloadFromPath(child_path, out_items, max_items);
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

class WinFileDropTarget final : public IDropTarget {
 public:
  explicit WinFileDropTarget(FlutterWindow* owner)
      : ref_count_(1), owner_(owner), has_files_(false) {}

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
    has_files_ = HasHdropData(data_object);
    if (effect) {
      *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    if (has_files_ && owner_) {
      owner_->NotifyFileDragUpdated(true);
    }
    return S_OK;
  }

  STDMETHODIMP DragOver(DWORD /*key_state*/,
                        POINTL /*pt*/,
                        DWORD* effect) override {
    if (effect) {
      *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    return S_OK;
  }

  STDMETHODIMP DragLeave() override {
    has_files_ = false;
    if (owner_) {
      owner_->NotifyFileDragUpdated(false);
    }
    return S_OK;
  }

  STDMETHODIMP Drop(IDataObject* data_object,
                    DWORD /*key_state*/,
                    POINTL /*pt*/,
                    DWORD* effect) override {
    if (owner_) {
      owner_->NotifyFileDragUpdated(false);
    }
    if (!HasHdropData(data_object)) {
      if (effect) {
        *effect = DROPEFFECT_NONE;
      }
      has_files_ = false;
      return S_OK;
    }

    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM stg = {};
    if (SUCCEEDED(data_object->GetData(&fmt, &stg))) {
      HDROP hdrop = static_cast<HDROP>(::GlobalLock(stg.hGlobal));
      if (hdrop) {
        std::vector<std::wstring> paths = ExtractPathsFromHdrop(hdrop);
        ::GlobalUnlock(stg.hGlobal);
        if (!paths.empty() && owner_) {
          owner_->NotifyFilesDropped(paths);
        }
      }
      ::ReleaseStgMedium(&stg);
    }

    if (effect) {
      *effect = DROPEFFECT_COPY;
    }
    has_files_ = false;
    return S_OK;
  }

 private:
  static bool HasHdropData(IDataObject* data_object) {
    if (!data_object) {
      return false;
    }
    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    return SUCCEEDED(data_object->QueryGetData(&fmt));
  }

  LONG ref_count_;
  FlutterWindow* owner_;
  bool has_files_;
};

std::vector<std::wstring> ShowWinFileOpenDialog(HWND parent_hwnd,
                                                bool media_only) {
  std::vector<std::wstring> selected_paths;
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || !dialog) {
    return selected_paths;
  }

  DWORD options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_ALLOWMULTISELECT |
                       FOS_FILEMUSTEXIST);
  }

  if (media_only) {
    const COMDLG_FILTERSPEC filters[] = {
        {L"Images & Videos",
         L"*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.mp4;*.mov;*.mkv;*.webm;*.avi;*.m4v"},
        {L"All Files", L"*.*"},
    };
    dialog->SetFileTypes(2, filters);
  }

  if (SUCCEEDED(dialog->Show(parent_hwnd))) {
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
  }

  dialog->Release();
  return selected_paths;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
          std::vector<std::wstring> paths =
              ShowWinFileOpenDialog(GetHandle(), media_only);
          flutter::EncodableList items;
          for (const auto& p : paths) {
            if (items.size() >= 10) {
              break;
            }
            CollectPayloadFromPath(p, &items, 10);
          }
          result->Success(flutter::EncodableValue(items));
          return;
        }
        result->NotImplemented();
      });

  HWND child_hwnd = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child_hwnd);

  auto* win_drop_target = new WinFileDropTarget(this);
  drop_target_ = win_drop_target;

  HWND top_hwnd = GetHandle();
  if (top_hwnd) {
    ::DragAcceptFiles(top_hwnd, TRUE);
    ::ChangeWindowMessageFilterEx(top_hwnd, WM_DROPFILES, MSGFLT_ALLOW,
                                  nullptr);
    ::ChangeWindowMessageFilterEx(top_hwnd, 0x0049 /*WM_COPYGLOBALDATA*/,
                                  MSGFLT_ALLOW, nullptr);
    ::RevokeDragDrop(top_hwnd);
    ::RegisterDragDrop(top_hwnd, drop_target_);
  }
  if (child_hwnd && child_hwnd != top_hwnd) {
    ::RevokeDragDrop(child_hwnd);
    ::RegisterDragDrop(child_hwnd, drop_target_);
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
  if (flutter_controller_ && flutter_controller_->view()) {
    HWND child_hwnd = flutter_controller_->view()->GetNativeWindow();
    if (child_hwnd) {
      ::RevokeDragDrop(child_hwnd);
    }
  }
  if (GetHandle()) {
    ::RevokeDragDrop(GetHandle());
  }
  if (drop_target_) {
    static_cast<WinFileDropTarget*>(drop_target_)->DetachOwner();
    drop_target_->Release();
    drop_target_ = nullptr;
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
    NotifyFileDragUpdated(false);
    if (!paths.empty()) {
      NotifyFilesDropped(paths);
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
