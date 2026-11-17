// Native polyphonic pitch tracker: same command line, OSC protocol and results as `python -m polytracker`.
//
//   polytracker run    --input system:capture_1 --bus 130 ...   realtime (what classes/inputtracker.scd starts)
//   polytracker bench  [--hop 256|512] [--seconds 4]            per-frame cost on this machine
//   polytracker frames FILE.f32 [--sample-rate 48000] [--hop 256] [--probs OUT.f32]
//                                                               offline run of a raw float32 mono file (tests)
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "jack_source.h"
#include "osc.h"
#include "tracker.h"

using namespace pt;

namespace {

// ------------------------------------------------------------------ command line

struct Args {
    std::string cmd;
    std::vector<std::string> pos;
    std::map<std::string, std::string> opt;  // --name value (flags: "1")
    bool has(const std::string& k) const { return opt.count(k) > 0; }
    std::string str(const std::string& k, const std::string& d) const { auto it = opt.find(k); return it == opt.end() ? d : it->second; }
    double num(const std::string& k, double d) const { auto it = opt.find(k); return it == opt.end() ? d : std::stod(it->second); }
};

const char* FLAGS[] = {"--no-refine", "--no-osc", "--verbose", "-v"};

Args parse(int argc, char** argv) {
    Args a;
    if (argc < 2) return a;
    a.cmd = argv[1];
    for (int i = 2; i < argc; ++i) {
        std::string s = argv[i];
        if (s.rfind("-", 0) == 0 && s.size() > 1 && !std::isdigit(static_cast<unsigned char>(s[1]))) {
            if (s == "-v") s = "--verbose";
            bool flag = false;
            for (const char* f : FLAGS) flag |= s == f;
            if (flag) { a.opt[s] = "1"; continue; }
            const size_t eq = s.find('=');
            if (eq != std::string::npos) { a.opt[s.substr(0, eq)] = s.substr(eq + 1); continue; }
            if (i + 1 >= argc) throw std::runtime_error("missing value for " + s);
            a.opt[s] = argv[++i];
        } else {
            a.pos.push_back(s);
        }
    }
    return a;
}

// unknown options are an error (like argparse): a typo in inputtracker.scd's decoderArgs must not pass silently
void check_options(const Args& a, std::initializer_list<const char*> extra) {
    static const char* decoder[] = {"--on", "--off", "--onset", "--gate-db", "--voices", "--no-refine", "--model"};
    for (const auto& kv : a.opt) {
        bool ok = false;
        for (const char* k : decoder) ok |= kv.first == k;
        for (const char* k : extra) ok |= kv.first == k;
        if (!ok) throw std::runtime_error("unknown option " + kv.first + " for '" + a.cmd + "'");
    }
}

DecoderParams decoder_params(const Args& a) {
    DecoderParams p;
    p.on_thresh = a.num("--on", p.on_thresh);
    p.off_thresh = a.num("--off", p.off_thresh);
    p.onset_thresh = a.num("--onset", p.onset_thresh);
    p.gate_db = a.num("--gate-db", p.gate_db);
    p.max_voices = int(a.num("--voices", p.max_voices));
    p.refine = !a.has("--no-refine");
    return p;
}

std::string exe_dir() {
    char buf[4096];
    const ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
    if (n <= 0) return ".";
    std::string s(buf, size_t(n));
    return s.substr(0, s.rfind('/'));
}

// --model may name the .npz (what inputtracker.scd passes): the native tracker reads the .ptm next to it
std::string model_path(const Args& a) {
    std::string p = a.str("--model", exe_dir() + "/../../models/guitar_v1.ptm");
    if (p.size() > 4 && p.compare(p.size() - 4, 4, ".npz") == 0) p = p.substr(0, p.size() - 4) + ".ptm";
    if (!std::ifstream(p)) throw std::runtime_error("model " + p + " not found; create it with: .venv/bin/python native/export_model.py");
    return p;
}

std::pair<std::string, int> hostport(const std::string& s) {
    const size_t c = s.rfind(':');
    if (c == std::string::npos) return {"127.0.0.1", std::stoi(s)};
    return {c == 0 ? "127.0.0.1" : s.substr(0, c), std::stoi(s.substr(c + 1))};
}

double now_s() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ------------------------------------------------------------------ benchmark (port of polytracker/perf.py)

constexpr double AUTO_MEAN_LOAD = 0.45, AUTO_P99_LOAD = 0.80;

// six ringing strings (open E major chord) plus noise: the decoder's worst case, every voice busy
std::vector<float> bench_signal(int sr, double seconds) {
    const size_t n = size_t(sr * seconds);
    std::vector<float> x(n);
    const double f0s[] = {82.41, 123.47, 164.81, 207.65, 246.94, 329.63};
    std::mt19937 rng(0);
    std::normal_distribution<double> noise(0.0, 1.0);
    for (size_t i = 0; i < n; ++i) {
        const double t = double(i) / sr;
        double v = 0.0;
        for (double f : f0s)
            for (int h = 1; h <= 8; ++h) v += 0.06 * std::sin(2 * M_PI * f * h * t) / h;
        x[i] = float(v + 0.002 * noise(rng));
    }
    return x;
}

// wall-clock milliseconds per frame of Tracker::process
// stages: if set, the mean time per frame of frontend / network / decoder (ms) after the warmup
std::vector<double> measure(Tracker& tr, double seconds, int warmup = 20, double* stages = nullptr) {
    const int hop = tr.cfg.hop, H = tr.history(), sr = tr.cfg.sample_rate;
    std::vector<float> x = bench_signal(sr, seconds);
    std::vector<float> padded(H, 0.0f);
    padded.insert(padded.end(), x.begin(), x.end());
    std::vector<NoteEvent> ev;
    std::vector<double> ms;
    const size_t frames = (x.size() - hop) / hop;
    for (size_t i = 0; i < frames; ++i) {
        const size_t end = (i + 1) * hop;
        ev.clear();
        if (int(i) == warmup && stages) {
            tr.stage = Tracker::StageTimes{};
            tr.timing = true;
        }
        const double t0 = now_s();
        tr.process(&padded[end], double(end) / sr, ev);
        if (int(i) >= warmup) ms.push_back((now_s() - t0) * 1e3);
    }
    if (stages && tr.stage.frames) {
        stages[0] = 1e3 * tr.stage.frontend / tr.stage.frames;
        stages[1] = 1e3 * tr.stage.network / tr.stage.frames;
        stages[2] = 1e3 * tr.stage.decoder / tr.stage.frames;
    }
    tr.timing = false;
    tr.reset();
    return ms;
}

struct Stats { double mean, p50, p99, max; };

Stats stats(std::vector<double> ms) {
    std::sort(ms.begin(), ms.end());
    auto pct = [&](double q) {  // numpy's default linear interpolation
        const double pos = q / 100.0 * (ms.size() - 1);
        const size_t lo = size_t(pos);
        const size_t hi = std::min(lo + 1, ms.size() - 1);
        return ms[lo] + (ms[hi] - ms[lo]) * (pos - lo);
    };
    double s = 0.0;
    for (double v : ms) s += v;
    return {s / ms.size(), pct(50), pct(99), ms.back()};
}

double budget_ms(const Tracker& tr) { return 1e3 * tr.cfg.hop / tr.cfg.sample_rate; }

std::string summary(const Tracker& tr, const Stats& s) {
    char b[256];
    std::snprintf(b, sizeof b, "hop %d (%.2f ms budget): mean %.3f ms  p50 %.3f  p99 %.3f  max %.3f  -> %.1f%% of one core",
                  tr.cfg.hop, budget_ms(tr), s.mean, s.p50, s.p99, s.max, 100 * s.mean / budget_ms(tr));
    return b;
}

// the smallest hop this machine can sustain
std::unique_ptr<Tracker> choose_hop(PitchNet& net, const DecoderParams& p, int sr) {
    std::unique_ptr<Tracker> tr;
    for (int hop : {256, 512}) {
        tr = std::make_unique<Tracker>(net, p, sr, hop);
        const Stats s = stats(measure(*tr, 1.0));
        const double b = budget_ms(*tr);
        const bool ok = s.mean / b <= AUTO_MEAN_LOAD && s.p99 / b <= AUTO_P99_LOAD;
        std::printf("[polytracker] auto hop: %s, p99 %.0f%% -> %s\n", summary(*tr, s).c_str(), 100 * s.p99 / b,
                    ok ? "ok" : "too slow");
        std::fflush(stdout);
        if (ok) return tr;
    }
    std::printf("[polytracker] warning: even hop %d is tight on this machine; try --voices 4, --no-refine or an "
                "idle core (--cpu)\n", tr->cfg.hop);
    std::fflush(stdout);
    return tr;
}

// ------------------------------------------------------------------ OSC output (port of polytracker/outputs.py)

constexpr int HEADER = 4;
const char* MONO_MODES[] = {"latest", "lowest", "highest", "loudest"};

bool valid_mono(const std::string& m) {
    for (const char* k : MONO_MODES) if (m == k) return true;
    return false;
}

class OscOutput {
public:
    OscOutput(std::pair<std::string, int> sc, std::pair<std::string, int> lang, int base, int voices, std::string mono)
        : mono_mode(std::move(mono)), sc_(sc.first, sc.second), lang_(lang.first, lang.second), base_(base),
          voices_(voices), block_(HEADER + 3 * voices, 0.0f), last_(block_.size(), 0.0f) {}

    void send_block(const Decoder& d) {
        build(d);
        const double now = now_s();
        bool changed = !have_last_;
        for (size_t i = 0; i < block_.size() && !changed; ++i)
            if (i != 3 && block_[i] != last_[i]) changed = true;
        if (!changed && now - last_t_ <= 0.05) return;
        beat_ = (beat_ + 1) % 16000000;
        block_[3] = float(beat_);
        send_setn();
        last_ = block_;
        have_last_ = true;
        last_t_ = now;
    }

    void send_events(const std::vector<NoteEvent>& ev) {
        for (const NoteEvent& e : ev) {
            if (e.on) {
                osc::Writer w("/polytracker/noteOn");
                lang_.send(w.i(e.voice).i(e.pitch).f(float(e.freq)).f(float(e.amp)).packet());
            } else {
                osc::Writer w("/polytracker/noteOff");
                lang_.send(w.i(e.voice).i(e.pitch).packet());
            }
        }
    }

    // xruns: JACK xruns since the start (every JACK client is told about every xrun of the whole graph)
    void send_stats(double load, long frames, long dropped, double worst_ms, int xruns) {
        osc::Writer w("/polytracker/stats");
        lang_.send(w.f(float(load)).i(int32_t(frames)).i(int32_t(dropped)).f(float(worst_ms)).i(int32_t(xruns)).packet());
    }

    void hello(const std::string& model_name) {
        osc::Writer w("/polytracker/ready");
        lang_.send(w.s(model_name).i(base_).i(voices_).packet());
    }

    void clear() {
        std::fill(block_.begin(), block_.end(), 0.0f);
        ++beat_;
        block_[3] = float(beat_);
        send_setn();
        have_last_ = false;
    }

    std::string mono_mode;

private:
    int pick_mono(const Decoder& d) const {
        int best = -1;
        for (int v = 0; v < voices_; ++v) {
            if (d.v_pitch[v] < 0) continue;
            if (best < 0) { best = v; continue; }
            if (mono_mode == "lowest") { if (d.v_midi[v] < d.v_midi[best]) best = v; }
            else if (mono_mode == "highest") { if (d.v_midi[v] > d.v_midi[best]) best = v; }
            else if (mono_mode == "loudest") { if (d.v_amp[v] > d.v_amp[best]) best = v; }
            else if (d.v_t_on[v] > d.v_t_on[best]) best = v;  // latest
        }
        return best;
    }

    void build(const Decoder& d) {
        const int V = voices_;
        const int m = pick_mono(d);
        block_[0] = m >= 0 ? float(d.v_freq[m]) : 0.0f;
        block_[1] = m >= 0 ? float(d.v_amp[m]) : 0.0f;
        int n = 0;
        for (int v = 0; v < V; ++v) {
            const bool on = d.v_pitch[v] >= 0;
            n += on;
            block_[HEADER + v] = float(d.v_freq[v]);
            block_[HEADER + V + v] = float(d.v_amp[v]);
            block_[HEADER + 2 * V + v] = on ? 1.0f : 0.0f;
        }
        block_[2] = float(n);
    }

    void send_setn() {
        osc::Writer w("/c_setn");
        w.i(base_).i(int32_t(block_.size()));
        for (float v : block_) w.f(v);
        sc_.send(w.packet());
    }

    osc::UdpSender sc_, lang_;
    int base_, voices_;
    std::vector<float> block_, last_;
    bool have_last_ = false;
    double last_t_ = 0.0;
    long beat_ = 0;
};

// ------------------------------------------------------------------ control messages from sclang

struct Setting {
    std::string name;
    osc::Arg value;
};

class ControlServer {
public:
    explicit ControlServer(int port) {
        fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        int one = 1;
        setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        timeval tv{0, 250000};
        setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons(uint16_t(port));
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
        if (bind(fd_, reinterpret_cast<sockaddr*>(&a), sizeof a) < 0)
            throw std::runtime_error("cannot bind control port " + std::to_string(port) + ": " + std::strerror(errno));
    }
    ~ControlServer() { stop(); }

    void start() { thread_ = std::thread([this] { run(); }); }
    void stop() {
        running_ = false;
        if (thread_.joinable()) thread_.join();
        if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
    }

    // called by the analysis loop; never blocks it
    bool take(std::vector<Setting>& sets, bool& reset, bool& quit) {
        std::unique_lock<std::mutex> lock(mu_, std::try_to_lock);
        if (!lock.owns_lock() || (pending_.empty() && !reset_ && !quit_)) return false;
        sets.swap(pending_);
        pending_.clear();
        reset = reset_;
        quit = quit_;
        reset_ = false;
        return true;
    }

private:
    void run() {
        char buf[4096];
        std::vector<osc::Message> msgs;
        while (running_) {
            const ssize_t n = recv(fd_, buf, sizeof buf, 0);
            if (n <= 0) continue;
            msgs.clear();
            osc::decode(buf, size_t(n), msgs);
            std::lock_guard<std::mutex> lock(mu_);
            for (osc::Message& m : msgs) {
                if (m.address == "/polytracker/set" && !m.args.empty()) {
                    Setting s;
                    s.name = m.args[0].tag == 's' ? m.args[0].str : std::to_string(m.args[0].num);
                    if (m.args.size() > 1) s.value = m.args[1];
                    else s.value.tag = 'N';
                    pending_.push_back(std::move(s));
                } else if (m.address == "/polytracker/reset") {
                    reset_ = true;
                } else if (m.address == "/polytracker/quit") {
                    quit_ = true;
                }
            }
        }
    }

    int fd_ = -1;
    std::atomic<bool> running_{true};
    std::thread thread_;
    std::mutex mu_;
    std::vector<Setting> pending_;
    bool reset_ = false, quit_ = false;
};

// sclang sends camelCase: monoMode -> mono_mode
std::string snake(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        const char c = s[i];
        if (i > 0 && std::isupper(static_cast<unsigned char>(c))) out += '_';
        out += char(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

double arg_num(const osc::Arg& a) { return a.tag == 's' ? std::stod(a.str) : a.num; }

// ------------------------------------------------------------------ realtime runner (port of realtime.py)

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop = true; }

// The analysis thread gets SCHED_FIFO so that ordinary processes (sclang, the desktop) cannot delay it, but it
// must stay below the JACK audio threads: a late pitch frame is inaudible, a late audio block is a dropout.
// jack_priority: realtime priority of JACK's client threads (-1 = unknown or not realtime).
void set_realtime(int priority, int cpu, int jack_priority) {
    if (priority > 0 && jack_priority > 0 && priority >= jack_priority) {
        const int capped = jack_priority > 1 ? jack_priority - 1 : 1;
        std::printf("[polytracker] realtime priority %d lowered to %d: the JACK audio threads run at %d\n", priority,
                    capped, jack_priority);
        priority = capped;
    }
    if (cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        if (sched_setaffinity(0, sizeof set, &set))
            std::printf("[polytracker] cannot pin to cpu %d: %s\n", cpu, std::strerror(errno));
    }
    if (priority > 0) {
        sched_param sp{};
        sp.sched_priority = priority;
        if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0)
            std::printf("[polytracker] SCHED_FIFO priority %d\n", priority);
        else
            std::printf("[polytracker] no realtime priority (%s); add the user to the 'audio' group with rtprio limits\n",
                        std::strerror(errno));
    }
    std::fflush(stdout);
}

bool parent_alive(int pid) {
    if (pid <= 0) return true;
    if (kill(pid, 0) != 0 && errno == ESRCH) return false;
    return getppid() == pid || getppid() != 1;
}

class Runner {
public:
    Runner(Tracker& tr, JackSource& src, OscOutput* out, ControlServer* ctl, int parent_pid, bool verbose,
           int max_backlog_hops = 8)
        : tr_(tr), src_(src), out_(out), ctl_(ctl), parent_pid_(parent_pid), verbose_(verbose),
          max_backlog_(max_backlog_hops) {}

    void run() {
        const int hop = tr_.cfg.hop, H = tr_.history(), sr = tr_.cfg.sample_rate;
        const long cap = H + hop * 64L + 8192;
        std::vector<float> buf(size_t(cap), 0.0f), fresh;
        fresh.reserve(size_t(4 * sr));
        long fill = H, base = -H;  // buf[0] is absolute sample `base`; the first H samples are leading silence
        long total = 0, next_end = hop, frames = 0, dropped = 0;
        double busy = 0.0, worst = 0.0;
        double last_stats = now_s(), last_parent = last_stats;
        bool paused = false, was_paused = false, quit = false;
        std::vector<NoteEvent> events;
        events.reserve(64);
        std::vector<Setting> sets;

        if (ctl_) ctl_->start();
        src_.start();
        if (out_) out_->hello(tr_.net.name);
        std::printf("[polytracker] running: %d Hz, hop %d (%.1f ms), history %d, voices %d, native (%s)\n", sr, hop,
                    1000.0 * hop / sr, H, tr_.dec.p.max_voices, simd_info());
        std::fflush(stdout);

        while (!g_stop && !quit && !src_.shutdown) {
            src_.wait(0.05);
            src_.read_available(fresh);
            const long n = long(fresh.size());
            if (n) {
                if (fill + n > cap) {
                    const long keep = H + hop * 16L;
                    std::memmove(buf.data(), buf.data() + (fill - keep), sizeof(float) * size_t(keep));
                    base += fill - keep;
                    fill = keep;
                }
                const long m = std::min(n, cap - fill);
                std::memcpy(buf.data() + fill, fresh.data(), sizeof(float) * size_t(m));
                fill += m;
                total += n;
                if (total - next_end >= max_backlog_ * hop && !paused) {  // fell behind: jump to the newest frame
                    const long skip = (total - next_end) / hop;
                    dropped += skip;
                    next_end += skip * hop;
                }
            }
            if (ctl_) {
                bool reset = false;
                if (ctl_->take(sets, reset, quit)) {
                    for (const Setting& s : sets) apply(s, paused);
                    if (reset) {
                        tr_.reset();
                        if (out_) out_->clear();
                    }
                    sets.clear();
                }
            }
            if (paused) {  // idle: keep draining audio, but spend no CPU on analysis
                if (!was_paused) {
                    tr_.reset();
                    if (out_) out_->clear();
                    was_paused = true;
                }
                next_end = (total / hop + 1) * hop;
            } else {
                was_paused = false;
            }
            while (next_end <= total && !paused) {
                const long lo = next_end - base - H;
                events.clear();
                const double t0 = now_s();
                tr_.process(buf.data() + lo, double(next_end) / sr, events);
                if (out_) {
                    out_->send_block(tr_.dec);
                    if (!events.empty()) out_->send_events(events);
                }
                const double dt = now_s() - t0;
                busy += dt;
                worst = std::max(worst, dt);
                ++frames;
                next_end += hop;
                if (verbose_)
                    for (const NoteEvent& e : events)
                        std::printf("%9.3f %-3s v%d midi %d %7.2f Hz amp %.2f\n", e.t, e.on ? "on" : "off", e.voice,
                                    e.pitch, e.freq, e.amp);
            }
            const double now = now_s();
            if (now - last_stats >= 1.0) {
                const double load = busy / (now - last_stats);
                if (out_) out_->send_stats(load, frames, dropped, worst * 1e3, src_.xruns.load());
                if (verbose_)
                    std::printf("[polytracker] load %.1f%%  worst %.2f ms  frames %ld dropped %ld xruns %d\n",
                                100 * load, worst * 1e3, frames, dropped, src_.xruns.load());
                last_stats = now;
                busy = worst = 0.0;
            }
            if (now - last_parent >= 1.0) {
                last_parent = now;
                if (!parent_alive(parent_pid_)) {
                    std::printf("[polytracker] parent process gone, exiting\n");
                    break;
                }
            }
            if (verbose_) std::fflush(stdout);
        }
        if (out_) out_->clear();
        if (ctl_) ctl_->stop();
        src_.stop();
        std::fflush(stdout);
    }

private:
    void apply(const Setting& s, bool& paused) {
        static const std::map<std::string, double DecoderParams::*> settable = {
            {"on", &DecoderParams::on_thresh}, {"off", &DecoderParams::off_thresh},
            {"onset", &DecoderParams::onset_thresh}, {"gate_db", &DecoderParams::gate_db},
            {"retrigger_ms", &DecoderParams::retrigger_ms}, {"on_confirm_ms", &DecoderParams::on_confirm_ms},
            {"off_confirm_ms", &DecoderParams::off_confirm_ms}, {"amp_range_db", &DecoderParams::amp_range_db},
            {"glide_alpha", &DecoderParams::glide_alpha},
        };
        const std::string name = snake(s.name);
        try {
            if (name == "mono_mode") {
                const std::string v = s.value.tag == 's' ? s.value.str : "";
                if (!valid_mono(v))
                    std::printf("[polytracker] mono_mode must be one of latest, lowest, highest, loudest, got '%s'\n", v.c_str());
                else if (out_) out_->mono_mode = v;
            } else if (name == "refine") {
                tr_.dec.p.refine = int(arg_num(s.value)) != 0;
            } else if (name == "pause") {
                paused = int(arg_num(s.value)) != 0;
            } else if (auto it = settable.find(name); it != settable.end()) {
                tr_.dec.p.*(it->second) = arg_num(s.value);
            } else {
                std::printf("[polytracker] unknown setting '%s'; known: amp_range_db, gate_db, glide_alpha, "
                            "mono_mode, off, off_confirm_ms, on, on_confirm_ms, onset, pause, refine, retrigger_ms\n",
                            name.c_str());
            }
        } catch (const std::exception& e) {  // a malformed message must never kill the tracker
            std::printf("[polytracker] bad control message for '%s': %s\n", name.c_str(), e.what());
        }
        std::fflush(stdout);
    }

    Tracker& tr_;
    JackSource& src_;
    OscOutput* out_;
    ControlServer* ctl_;
    int parent_pid_;
    bool verbose_;
    int max_backlog_;
};

// ------------------------------------------------------------------ commands

// lock current and future pages in RAM: a page fault in the analysis thread is a missed deadline
void lock_memory() { mlockall(MCL_CURRENT | MCL_FUTURE); }

int cmd_run(const Args& a) {
    check_options(a, {"--input", "--client-name", "--hop", "--scsynth", "--lang", "--bus", "--control-port", "--mono-mode",
                      "--no-osc", "--cpu", "--rt-priority", "--parent-pid", "--verbose"});
    prctl(PR_SET_PDEATHSIG, SIGTERM);  // get SIGTERM when sclang goes away so the tracker never lingers
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    const std::string hop_s = a.str("--hop", "auto");
    const int voices = int(a.num("--voices", 6));
    const std::string mono = a.str("--mono-mode", "latest");
    if (!valid_mono(mono)) throw std::runtime_error("--mono-mode must be one of latest, lowest, highest, loudest");

    JackSource src(a.str("--input", "system:capture_1"), a.str("--client-name", "polytracker"));
    lock_memory();
    set_realtime(int(a.num("--rt-priority", 50)), int(a.num("--cpu", -1)), src.rt_priority());  // before measuring: the choice reflects the real scheduling
    PitchNet net = PitchNet::load(model_path(a));
    const DecoderParams params = decoder_params(a);
    std::unique_ptr<Tracker> tr = hop_s == "auto" ? choose_hop(net, params, src.sample_rate)
                                                  : std::make_unique<Tracker>(net, params, src.sample_rate, std::stoi(hop_s));
    if (src.sample_rate != net.cfg.sample_rate)
        std::printf("[polytracker] warning: JACK runs at %d Hz, model was trained at %d Hz (windows are rescaled)\n",
                    src.sample_rate, net.cfg.sample_rate);
    std::unique_ptr<OscOutput> out;
    if (!a.has("--no-osc")) {
        if (!a.has("--bus")) throw std::runtime_error("--bus (first control bus of the tracker block) is required unless --no-osc");
        out = std::make_unique<OscOutput>(hostport(a.str("--scsynth", "127.0.0.1:57110")),
                                          hostport(a.str("--lang", "127.0.0.1:57120")), int(a.num("--bus", 0)),
                                          voices, mono);
    }
    std::unique_ptr<ControlServer> ctl;
    const int cport = int(a.num("--control-port", 57150));
    if (cport > 0) ctl = std::make_unique<ControlServer>(cport);
    Runner(*tr, src, out.get(), ctl.get(), int(a.num("--parent-pid", 0)), a.has("--verbose")).run();
    return 0;
}

int cmd_bench(const Args& a) {
    check_options(a, {"--hop", "--sample-rate", "--seconds"});
    PitchNet net = PitchNet::load(model_path(a));
    const DecoderParams params = decoder_params(a);
    const int sr = int(a.num("--sample-rate", 48000));
    const double seconds = a.num("--seconds", 4.0);
    std::vector<int> hops;
    if (a.has("--hop")) hops.push_back(std::stoi(a.str("--hop", "256")));
    else hops = {256, 512};
    std::printf("native (C++, %s)\n", simd_info());
    for (int hop : hops) {
        Tracker tr(net, params, sr, hop);
        double st[3] = {0, 0, 0};
        std::printf("%s\n", summary(tr, stats(measure(tr, seconds, 20, st))).c_str());
        std::printf("    frontend %.3f ms  network %.3f ms  decoder %.3f ms\n", st[0], st[1], st[2]);
    }
    std::printf("(six voices sounding; `run --hop auto` picks the smallest hop with mean <= 45%% and p99 <= 80%% of it)\n");
    return 0;
}

// Offline run of a raw float32 mono file through the realtime path, frame by frame (used by the tests).
// Prints one line per event: on|off  t  voice  midi  freq  amp
int cmd_frames(const Args& a) {
    check_options(a, {"--sample-rate", "--hop", "--probs", "--features", "--voices-out"});
    if (a.pos.empty()) throw std::runtime_error("usage: polytracker frames FILE.f32 [--sample-rate N] [--hop N] [--probs OUT.f32]");
    std::ifstream f(a.pos[0], std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("cannot open " + a.pos[0]);
    std::vector<float> x(size_t(f.tellg()) / sizeof(float));
    f.seekg(0);
    f.read(reinterpret_cast<char*>(x.data()), std::streamsize(x.size() * sizeof(float)));
    PitchNet net = PitchNet::load(model_path(a));
    Tracker tr(net, decoder_params(a), int(a.num("--sample-rate", 48000)), int(a.num("--hop", 256)));
    const int hop = tr.cfg.hop, H = tr.history(), sr = tr.cfg.sample_rate;
    std::vector<float> padded(H, 0.0f);
    padded.insert(padded.end(), x.begin(), x.end());
    std::unique_ptr<std::ofstream> probs, feats, voices;
    if (a.has("--probs")) probs = std::make_unique<std::ofstream>(a.str("--probs", ""), std::ios::binary);
    if (a.has("--features")) feats = std::make_unique<std::ofstream>(a.str("--features", ""), std::ios::binary);
    if (a.has("--voices-out")) voices = std::make_unique<std::ofstream>(a.str("--voices-out", ""), std::ios::binary);
    std::vector<NoteEvent> ev;
    for (size_t end = hop; end <= x.size(); end += hop) {
        ev.clear();
        tr.process(&padded[end], double(end) / sr, ev);
        if (probs) probs->write(reinterpret_cast<const char*>(tr.last_probs), std::streamsize(sizeof(float) * 2 * net.out_len));
        if (feats) feats->write(reinterpret_cast<const char*>(tr.feat.x.data()), std::streamsize(sizeof(float) * tr.feat.x.size()));
        if (voices) {  // per frame and voice: freq, amp (float64)
            for (int v = 0; v < tr.dec.p.max_voices; ++v) {
                const double fa[2] = {tr.dec.v_freq[v], tr.dec.v_amp[v]};
                voices->write(reinterpret_cast<const char*>(fa), sizeof fa);
            }
        }
        for (const NoteEvent& e : ev)
            std::printf("%s %.9g %d %d %.9g %.9g\n", e.on ? "on" : "off", e.t, e.voice, e.pitch, e.freq, e.amp);
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const Args a = parse(argc, argv);
        if (a.cmd == "run") return cmd_run(a);
        if (a.cmd == "bench") return cmd_bench(a);
        if (a.cmd == "frames") return cmd_frames(a);
        std::fprintf(stderr, "usage: polytracker {run,bench,frames} ...  (see the comment at the top of main.cpp)\n");
        return 2;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[polytracker] error: %s\n", e.what());
        std::fflush(stdout);
        return 1;
    }
}
