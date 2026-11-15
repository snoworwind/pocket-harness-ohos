#!/usr/bin/env bash
set -euo pipefail
IEC=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${BUILD:-/tmp/iec-elf-dl-x86-test}
mkdir -p "$BUILD"
cat > "$BUILD/fixture.c" <<'EOF'
extern int host_add(int);
extern int optional_value(void) __attribute__((weak));
static int value;
static int *value_ptr = &value;
__attribute__((constructor)) static void initialize(void) { value = 40; }
int fixture(void) { return host_add(*value_ptr) + (optional_value ? optional_value() : 0); }
EOF
cat > "$BUILD/main.cpp" <<'EOF'
#include "loader.h"
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>
extern "C" int host_add(int value) { return value + 2; }
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(f)), {});
    void *handle = elf_dlopen_mem(bytes.data(), bytes.size(), "fixture.so");
    if (!handle || !elf_dl_owns_handle(handle)) return 2;
    auto run = reinterpret_cast<int (*)()>(elf_dlsym(handle, "fixture"));
    if (!run || run() != 42) return 3;
    std::puts("x86_64 ELF relocations, constructor, weak symbol and host lookup passed");
}
EOF
gcc -shared -fPIC -Wl,--hash-style=sysv "$BUILD/fixture.c" -o "$BUILD/fixture.so"
g++ -std=c++17 -O1 -rdynamic -I "$IEC/loader" "$BUILD/main.cpp" "$IEC/loader/elf_dl.cpp" "$IEC/loader/loader.cpp" "$IEC/loader/guest_switch_x86_64.S" -ldl -pthread -o "$BUILD/test"
"$BUILD/test" "$BUILD/fixture.so"
