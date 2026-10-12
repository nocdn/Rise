// Rise's helper process: Chromium runs pages, graphics and networking in copies of this
// executable, each sandboxed before Chromium loads.
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char *argv[]) {
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  // The framework loads after the sandbox, as macOS's sandbox requires.
  CefScopedLibraryLoader library;
  if (!library.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
