#pragma once
#include <cstddef>
struct SharedHostModuleAPI {
    void *(*create)(double, int);
    bool (*ready)(void *);
    bool (*connected)(void *);
    void (*feed)(void *, float, size_t);
    void (*stop)(void *);
    void (*destroy)(void *);
};
using SharedHostModuleEntry = const SharedHostModuleAPI *(*)();
