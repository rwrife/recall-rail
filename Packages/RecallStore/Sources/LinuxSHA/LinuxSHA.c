#include "LinuxSHA.h"
#include <openssl/sha.h>
void recall_sha256(const unsigned char *bytes, size_t count, unsigned char *output) {
    SHA256(bytes, count, output);
}
