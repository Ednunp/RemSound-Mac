#pragma once
#include <functional>
#include <memory>
#include <string>

// AppKit UI only. Never constructed or called by a host audio callback.
class PluginHelpWindow {
  public:
    virtual ~PluginHelpWindow() = default;
    virtual void present(const std::string& title, const std::string& text, void* ownerView) = 0;
    virtual void close() = 0;
};

std::unique_ptr<PluginHelpWindow> makePluginHelpWindow(
    const std::string& manual, std::function<void()> opened, std::function<void()> closed);
