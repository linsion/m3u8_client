#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <ole2.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  void NotifyFileDragUpdated(bool active);
  void NotifyFilesDropped(const std::vector<std::wstring>& paths);
  void PostFileDragDelta(int delta);
  void PostFilesDropped(std::vector<std::wstring> paths);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native utility method channel (file drag-and-drop & file picker).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> utils_channel_;

  // Separate OLE drag-and-drop targets for top frame and child Flutter view so
  // crossing from window frame into child view never clears `has_files_`.
  IDropTarget* top_drop_target_ = nullptr;
  IDropTarget* child_drop_target_ = nullptr;
  int active_drag_targets_ = 0;

  // Tracks whether an async file picker dialog is currently open.
  std::atomic<bool> is_picking_files_{false};

  // Shared alive flag for background worker threads.
  std::shared_ptr<std::atomic<bool>> window_alive_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
