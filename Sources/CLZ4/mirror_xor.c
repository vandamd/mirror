#include "include/lz4.h"

void mirror_xor(unsigned char *dst, const unsigned char *a, const unsigned char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        dst[i] = a[i] ^ b[i];
    }
}
