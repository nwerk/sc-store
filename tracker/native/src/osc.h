// Minimal OSC 1.0 encoder/decoder and UDP helpers (port of polytracker/oscmini.py).
#pragma once

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace pt::osc {

struct Arg {
    char tag;  // 'i', 'f', 'd', 's', 'T', 'F'
    double num = 0.0;
    std::string str;
};

struct Message {
    std::string address;
    std::vector<Arg> args;
};

class Writer {
public:
    explicit Writer(const char* address) { str(address); tags_ = ","; }
    Writer& i(int32_t v) { tags_ += 'i'; be32(uint32_t(v)); return *this; }
    Writer& f(float v) { uint32_t u; std::memcpy(&u, &v, 4); tags_ += 'f'; be32(u); return *this; }
    Writer& s(const std::string& v) { tags_ += 's'; pad_str(args_, v); return *this; }
    const std::string& packet() {
        out_ = head_;
        pad_str(out_, tags_);
        out_ += args_;
        return out_;
    }

private:
    static void pad_str(std::string& dst, const std::string& v) {
        dst += v;
        dst.append(4 - v.size() % 4, '\0');
    }
    void str(const char* a) { pad_str(head_, a); }
    void be32(uint32_t u) {
        const char b[4] = {char(u >> 24), char(u >> 16), char(u >> 8), char(u)};
        args_.append(b, 4);
    }
    std::string head_, tags_, args_, out_;
};

namespace detail {
inline bool read_str(const char* d, size_t n, size_t& i, std::string& out) {
    const void* z = std::memchr(d + i, 0, n - i);
    if (!z) return false;
    const size_t j = size_t(static_cast<const char*>(z) - d);
    out.assign(d + i, j - i);
    i = (j + 4) & ~size_t(3);
    return true;
}
inline uint32_t be32(const char* p) {
    const auto* u = reinterpret_cast<const unsigned char*>(p);
    return (uint32_t(u[0]) << 24) | (uint32_t(u[1]) << 16) | (uint32_t(u[2]) << 8) | u[3];
}
}  // namespace detail

// Decodes a message or bundle (flattened). Malformed data yields what could be read.
inline void decode(const char* d, size_t n, std::vector<Message>& out) {
    using namespace detail;
    if (n >= 8 && std::memcmp(d, "#bundle", 8) == 0) {
        size_t i = 16;
        while (i + 4 <= n) {
            const size_t size = be32(d + i);
            if (i + 4 + size > n) return;
            decode(d + i + 4, size, out);
            i += 4 + size;
        }
        return;
    }
    Message m;
    size_t i = 0;
    if (!read_str(d, n, i, m.address)) return;
    std::string tags;
    if (i >= n || !read_str(d, n, i, tags) || tags.empty() || tags[0] != ',') {
        out.push_back(std::move(m));
        return;
    }
    for (size_t k = 1; k < tags.size(); ++k) {
        Arg a;
        a.tag = tags[k];
        if (a.tag == 'i' || a.tag == 'f') {
            if (i + 4 > n) break;
            const uint32_t u = be32(d + i);
            i += 4;
            if (a.tag == 'i') a.num = int32_t(u);
            else { float f; std::memcpy(&f, &u, 4); a.num = f; }
        } else if (a.tag == 'd') {
            if (i + 8 > n) break;
            const uint64_t u = (uint64_t(be32(d + i)) << 32) | be32(d + i + 4);
            i += 8;
            double v; std::memcpy(&v, &u, 8); a.num = v;
        } else if (a.tag == 's') {
            if (!read_str(d, n, i, a.str)) break;
        } else if (a.tag == 'T' || a.tag == 'F') {
            a.num = a.tag == 'T';
        } else {
            break;  // unknown type: the rest cannot be parsed
        }
        m.args.push_back(std::move(a));
    }
    out.push_back(std::move(m));
}

class UdpSender {
public:
    UdpSender(const std::string& host, int port) {
        fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        std::memset(&addr_, 0, sizeof addr_);
        addr_.sin_family = AF_INET;
        addr_.sin_port = htons(uint16_t(port));
        ::inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host.c_str(), &addr_.sin_addr);
    }
    ~UdpSender() { if (fd_ >= 0) ::close(fd_); }
    UdpSender(const UdpSender&) = delete;
    UdpSender& operator=(const UdpSender&) = delete;
    // best effort: the receiver may not be up yet
    void send(const std::string& p) const {
        ::sendto(fd_, p.data(), p.size(), MSG_DONTWAIT, reinterpret_cast<const sockaddr*>(&addr_), sizeof addr_);
    }

private:
    int fd_ = -1;
    sockaddr_in addr_{};
};

}  // namespace pt::osc
