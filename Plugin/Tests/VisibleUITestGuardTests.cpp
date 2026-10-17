#include "VisibleUITestGuard.h"
#include <iostream>

int main() {
    const char* rejected[] = {nullptr, "", "0", "true", "01", "1 ", "1\n"};
    for (const char* value : rejected) {
        if (visibleUITestsAllowed(value)) {
            std::cerr << "Visible UI test opt-in must be exactly 1\n";
            return 1;
        }
    }
    if (!visibleUITestsAllowed("1")) {
        std::cerr << "Explicit visible UI test opt-in must be accepted\n";
        return 1;
    }
    std::cout << "Visible UI test opt-in policy passed without GUI initialization\n";
    return 0;
}
