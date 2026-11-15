// JACK capture of one port (port of the JackSource in polytracker/audio.py).
//
// libjack is opened at runtime with dlopen, so building needs no JACK headers or -dev package: only the
// libjack.so.0 that every JACK installation has. The RT callback only copies samples into a lock-free ring.
#pragma once

#include <dlfcn.h>
#include <semaphore.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace pt {

class JackSource {
public:
    JackSource(const std::string& source_port, const std::string& client_name, double ring_seconds = 2.0,
               double connect_timeout = 30.0)
        : source_port_(source_port), connect_timeout_(connect_timeout) {
        lib_ = dlopen("libjack.so.0", RTLD_NOW | RTLD_LOCAL);
        if (!lib_) lib_ = dlopen("libjack.so", RTLD_NOW | RTLD_LOCAL);
        if (!lib_) throw std::runtime_error(std::string("cannot load libjack (") + dlerror() + ")");
        sym(client_open_, "jack_client_open");
        sym(client_close_, "jack_client_close");
        sym(get_sample_rate_, "jack_get_sample_rate");
        sym(get_buffer_size_, "jack_get_buffer_size");
        sym(port_register_, "jack_port_register");
        sym(port_get_buffer_, "jack_port_get_buffer");
        sym(port_name_, "jack_port_name");
        sym(set_process_callback_, "jack_set_process_callback");
        sym(set_xrun_callback_, "jack_set_xrun_callback");
        sym(on_shutdown_, "jack_on_shutdown");
        sym(activate_, "jack_activate");
        sym(deactivate_, "jack_deactivate");
        sym(connect_, "jack_connect");
        sym(get_ports_, "jack_get_ports");
        sym(free_, "jack_free");
        rt_priority_ = reinterpret_cast<int (*)(client_t*)>(dlsym(lib_, "jack_client_real_time_priority"));

        int status = 0;
        client_ = client_open_(client_name.c_str(), 0x01 /* JackNoStartServer */, &status);
        if (!client_) throw std::runtime_error("cannot connect to the JACK server (status 0x" + hex(status) + ")");
        sample_rate = int(get_sample_rate_(client_));
        block_size = int(get_buffer_size_(client_));
        inport_ = port_register_(client_, "in", "32 bit float mono audio", 0x1 /* JackPortIsInput */, 0);
        if (!inport_) throw std::runtime_error("cannot register the JACK input port");
        size_t size = 1;
        while (size < size_t(ring_seconds * sample_rate)) size <<= 1;
        ring_.assign(size, 0.0f);
        mask_ = size - 1;
        sem_init(&sem_, 0, 0);
        set_process_callback_(client_, &JackSource::process_cb, this);
        set_xrun_callback_(client_, &JackSource::xrun_cb, this);
        on_shutdown_(client_, &JackSource::shutdown_cb, this);
    }

    ~JackSource() {
        stop();
        sem_destroy(&sem_);
        if (lib_) dlclose(lib_);
    }

    void start() {
        if (activate_(client_)) throw std::runtime_error("cannot activate the JACK client");
        if (source_port_.empty()) return;
        const std::string me = port_name_(inport_);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(connect_timeout_);
        while (true) {
            const int err = connect_(client_, source_port_.c_str(), me.c_str());
            if (err == 0 || err == EEXIST) return;
            if (std::chrono::steady_clock::now() > deadline) {
                std::string avail;
                if (const char** ports = get_ports_(client_, nullptr, "32 bit float mono audio", 0x2)) {
                    for (const char** p = ports; *p; ++p) avail += (avail.empty() ? "" : ", ") + std::string(*p);
                    free_(ports);
                }
                throw std::runtime_error("JACK port '" + source_port_ + "' not found; available: " + avail);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
    }

    void stop() {
        if (!client_) return;
        deactivate_(client_);
        client_close_(client_);
        client_ = nullptr;
    }

    // waits up to `timeout` seconds for new audio (any number of callbacks count as one wake-up)
    bool wait(double timeout) {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        const long ns = ts.tv_nsec + long(timeout * 1e9);
        ts.tv_sec += ns / 1000000000L;
        ts.tv_nsec = ns % 1000000000L;
        const bool ok = sem_timedwait(&sem_, &ts) == 0;
        while (sem_trywait(&sem_) == 0) {}
        return ok;
    }

    // appends every sample that arrived since the last call
    void read_available(std::vector<float>& out) {
        const size_t w = write_.load(std::memory_order_acquire), r = read_.load(std::memory_order_relaxed);
        out.clear();
        for (size_t i = r; i != w; ++i) out.push_back(ring_[i & mask_]);
        read_.store(w, std::memory_order_release);
    }

    // realtime priority of this client's JACK threads (the audio threads of scsynth have the same); -1 if JACK
    // does not run with realtime scheduling or cannot tell
    int rt_priority() const { return rt_priority_ && client_ ? rt_priority_(client_) : -1; }

    int sample_rate = 0, block_size = 0;
    std::atomic<int> xruns{0}, overruns{0};
    std::atomic<bool> shutdown{false};

private:
    template <class F> void sym(F& f, const char* name) {
        f = reinterpret_cast<F>(dlsym(lib_, name));
        if (!f) throw std::runtime_error(std::string("libjack lacks ") + name);
    }
    static std::string hex(int v) { char b[16]; std::snprintf(b, sizeof b, "%x", unsigned(v)); return b; }

    static int process_cb(uint32_t nframes, void* arg) {
        auto* self = static_cast<JackSource*>(arg);
        const float* in = static_cast<const float*>(self->port_get_buffer_(self->inport_, nframes));
        const size_t w = self->write_.load(std::memory_order_relaxed), r = self->read_.load(std::memory_order_acquire);
        const size_t room = self->ring_.size() - (w - r);
        const size_t n = nframes <= room ? nframes : room;
        if (n < nframes) self->overruns.fetch_add(1, std::memory_order_relaxed);
        for (size_t i = 0; i < n; ++i) self->ring_[(w + i) & self->mask_] = in[i];
        self->write_.store(w + n, std::memory_order_release);
        sem_post(&self->sem_);
        return 0;
    }
    static int xrun_cb(void* arg) {
        static_cast<JackSource*>(arg)->xruns.fetch_add(1, std::memory_order_relaxed);
        return 0;
    }
    static void shutdown_cb(void* arg) {
        auto* self = static_cast<JackSource*>(arg);
        self->shutdown = true;
        sem_post(&self->sem_);
    }

    using client_t = void;
    using port_t = void;
    client_t* (*client_open_)(const char*, int, int*, ...) = nullptr;
    int (*client_close_)(client_t*) = nullptr;
    uint32_t (*get_sample_rate_)(client_t*) = nullptr;
    uint32_t (*get_buffer_size_)(client_t*) = nullptr;
    port_t* (*port_register_)(client_t*, const char*, const char*, unsigned long, unsigned long) = nullptr;
    void* (*port_get_buffer_)(port_t*, uint32_t) = nullptr;
    const char* (*port_name_)(const port_t*) = nullptr;
    int (*set_process_callback_)(client_t*, int (*)(uint32_t, void*), void*) = nullptr;
    int (*set_xrun_callback_)(client_t*, int (*)(void*), void*) = nullptr;
    void (*on_shutdown_)(client_t*, void (*)(void*), void*) = nullptr;
    int (*activate_)(client_t*) = nullptr;
    int (*deactivate_)(client_t*) = nullptr;
    int (*connect_)(client_t*, const char*, const char*) = nullptr;
    const char** (*get_ports_)(client_t*, const char*, const char*, unsigned long) = nullptr;
    void (*free_)(void*) = nullptr;
    int (*rt_priority_)(client_t*) = nullptr;  // optional

    void* lib_ = nullptr;
    client_t* client_ = nullptr;
    port_t* inport_ = nullptr;
    std::string source_port_;
    double connect_timeout_;
    std::vector<float> ring_;
    size_t mask_ = 0;
    std::atomic<size_t> write_{0}, read_{0};
    sem_t sem_;
};

}  // namespace pt
