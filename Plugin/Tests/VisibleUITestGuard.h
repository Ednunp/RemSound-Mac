#pragma once
#include <cstdio>
#include <cstdlib>
#include <cstring>

inline constexpr int visibleUITestSkipped = 77;

inline bool visibleUITestsAllowed(const char* value) {
    return value != nullptr && std::strcmp(value, "1") == 0;
}

inline bool skipVisibleUITest() {
    if (visibleUITestsAllowed(std::getenv("REMSOUND_ALLOW_VISIBLE_UI_TESTS"))) return false;
    std::puts("SKIP: visible UI test is unverified. After agreeing a test window, set REMSOUND_ALLOW_VISIBLE_UI_TESTS=1.");
    return true;
}
