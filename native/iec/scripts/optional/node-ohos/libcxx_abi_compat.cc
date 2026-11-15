// libcxx_abi_compat.cc — 补上随包 libc++_shared.so 缺的那几个 libc++ 符号。
//
// 背景：本工程的 Node/libnode.so 用 libc++ 22 的头文件（V8 需要 std::ranges），
// 但 ABI 命名空间改成 __n1 以匹配 DevEco SDK 随 HAP 打包的 libc++_shared.so。
// 那套运行库比 22 头文件旧，缺 std::__n1::__hash_memory(void const*, size_t)
// ——新版 libc++ 把字符串哈希的内联实现移到了这个函数里。真机 dlopen 时表现是：
//   _ZNSt4__n113__hash_memoryEPKvm: symbol not found
// 这里按 libc++ 的实现（murmur2）补一份；保证同一进程内哈希值一致。
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace std {
inline namespace __n1 {

size_t __hash_memory(const void* __ptr, size_t __size) noexcept {
  const size_t __m = 0x5bd1e995;
  const int __r = 24;
  size_t __h = 0x9747b28c ^ __size;
  const char* __p = static_cast<const char*>(__ptr);
  size_t __len = __size;

  while (__len >= 4) {
    uint32_t __k;
    std::memcpy(&__k, __p, 4);
    __k *= __m;
    __k ^= __k >> __r;
    __k *= __m;
    __h ^= __k;
    __h *= __m;
    __p += 4;
    __len -= 4;
  }

  switch (__len) {
    case 3:
      __h ^= static_cast<size_t>(static_cast<unsigned char>(__p[2])) << 16;
      [[fallthrough]];
    case 2:
      __h ^= static_cast<size_t>(static_cast<unsigned char>(__p[1])) << 8;
      [[fallthrough]];
    case 1:
      __h ^= static_cast<size_t>(static_cast<unsigned char>(__p[0]));
      __h *= __m;
      break;
    default:
      break;
  }

  __h ^= __h >> 13;
  __h *= __m;
  __h ^= __h >> 15;
  return __h;
}

}  // namespace __n1
}  // namespace std
