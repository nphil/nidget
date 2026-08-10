#import "LlamaBridge.h"

#import <llama/llama.h>
#import <llama/ggml-backend.h>

#include <chrono>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>

// Port of the Android JNI bridge (llmkit.cpp) to iOS. llama.cpp owns tokenization,
// sampling, the KV-cache and ggml backend selection (Metal/CPU here); this layer just
// marshals strings and L2-normalizes embeddings. Built against the same pinned llama.cpp
// commit as Android, so the API (6-arg llama_chat_apply_template, etc.) matches.

namespace {

struct Engine {
    llama_model   *model = nullptr;
    llama_context *ctx   = nullptr;
    bool           embeddings = false;
};

inline Engine *as_engine(uint64_t handle) {
    return reinterpret_cast<Engine *>(handle);
}

// Capture llama.cpp/ggml log output so the app can surface real load errors.
std::mutex g_log_mutex;
std::string g_log;

void llmkit_log_cb(ggml_log_level level, const char *text, void *) {
    if (text == nullptr) return;
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_log += text;
    if (g_log.size() > 6000) g_log.erase(0, g_log.size() - 6000);
}

std::string to_std(NSString *s) {
    if (s == nil) return {};
    const char *c = [s UTF8String];
    return c ? std::string(c) : std::string();
}

NSString *to_ns(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

// Tokenize with grow-on-overflow retry (llama_tokenize returns -needed when short).
std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &text, bool add_bos) {
    int n_max = static_cast<int>(text.size()) + 16;
    std::vector<llama_token> tokens(n_max);
    int n = llama_tokenize(vocab, text.c_str(), static_cast<int>(text.size()),
                           tokens.data(), n_max, add_bos, /*parse_special=*/true);
    if (n < 0) {
        tokens.resize(-n);
        n = llama_tokenize(vocab, text.c_str(), static_cast<int>(text.size()),
                           tokens.data(), -n, add_bos, /*parse_special=*/true);
    }
    if (n < 0) n = 0;
    tokens.resize(n);
    return tokens;
}

std::string token_to_piece(const llama_vocab *vocab, llama_token token) {
    char buf[256];
    int n = llama_token_to_piece(vocab, token, buf, sizeof(buf), /*lstrip=*/0, /*special=*/false);
    if (n < 0) return {};
    return std::string(buf, n);
}

std::string run_generation(Engine *eng, const std::string &formatted, bool add_bos,
                           int max_tokens, float temperature, int top_k) {
    const llama_vocab *vocab = llama_model_get_vocab(eng->model);

    llama_memory_clear(llama_get_memory(eng->ctx), true);

    std::vector<llama_token> tokens = tokenize(vocab, formatted, add_bos);
    if (tokens.empty()) return {};

    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int>(tokens.size()));
    if (llama_decode(eng->ctx, batch) != 0) return {};

    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k > 0 ? top_k : 40));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature > 0.f ? temperature : 0.7f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    std::string out;
    for (int i = 0; i < max_tokens; ++i) {
        llama_token tok = llama_sampler_sample(smpl, eng->ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        out += token_to_piece(vocab, tok);
        llama_batch step = llama_batch_get_one(&tok, 1);
        if (llama_decode(eng->ctx, step) != 0) break;
    }

    llama_sampler_free(smpl);
    return out;
}

} // namespace

@implementation LlamaBridge

+ (void)initBackend {
    static bool done = false;
    if (done) return;
    llama_log_set(llmkit_log_cb, nullptr);
    ggml_backend_load_all();
    llama_backend_init();
    done = true;
}

+ (void)clearLog {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_log.clear();
}

+ (NSString *)recentLog {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    return to_ns(g_log);
}

+ (NSArray<NSString *> *)probeBackends {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    const size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char *name = ggml_backend_dev_name(dev);
        const char *desc = ggml_backend_dev_description(dev);
        std::string entry = std::string(name ? name : "?") + " — " + (desc ? desc : "");
        [out addObject:to_ns(entry)];
    }
    return out;
}

+ (uint64_t)loadModelAtPath:(NSString *)path embeddings:(BOOL)embeddings gpuLayers:(int)gpuLayers {
    const std::string p = to_std(path);

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = gpuLayers;   // 99 -> Metal GPU, 0 -> CPU

    llama_model *model = llama_model_load_from_file(p.c_str(), mparams);
    if (model == nullptr) return 0;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx   = 4096;
    cparams.n_batch = 512;
    if (embeddings) {
        cparams.embeddings   = true;
        cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN;
    }

    llama_context *ctx = llama_init_from_model(model, cparams);
    if (ctx == nullptr) {
        llama_model_free(model);
        return 0;
    }

    Engine *eng = new Engine();
    eng->model = model;
    eng->ctx = ctx;
    eng->embeddings = embeddings;
    return reinterpret_cast<uint64_t>(eng);
}

+ (NSString *)generateWithHandle:(uint64_t)handle prompt:(NSString *)prompt
                       maxTokens:(int)maxTokens temperature:(float)temperature topK:(int)topK {
    Engine *eng = as_engine(handle);
    if (eng == nullptr || eng->ctx == nullptr) return @"";
    std::string out = run_generation(eng, to_std(prompt), /*add_bos=*/true, maxTokens, temperature, topK);
    return to_ns(out);
}

+ (NSString *)chatWithHandle:(uint64_t)handle system:(NSString *)system user:(NSString *)user
                   maxTokens:(int)maxTokens temperature:(float)temperature topK:(int)topK {
    Engine *eng = as_engine(handle);
    if (eng == nullptr || eng->ctx == nullptr) return @"";

    const std::string sys_str = to_std(system);
    const std::string usr_str = to_std(user);

    std::vector<llama_chat_message> msgs;
    if (!sys_str.empty()) msgs.push_back({"system", sys_str.c_str()});
    msgs.push_back({"user", usr_str.c_str()});

    // Apply the GGUF's built-in chat template (string form; add_ass=true for the assistant turn).
    const char *tmpl = llama_model_chat_template(eng->model, /*name=*/nullptr);
    std::string formatted(8192, '\0');
    int32_t n = tmpl ? llama_chat_apply_template(tmpl, msgs.data(), msgs.size(),
                                                 /*add_ass=*/true,
                                                 formatted.data(), (int32_t)formatted.size())
                     : -1;
    if (n < 0) {
        formatted = (sys_str.empty() ? "" : sys_str + "\n") + usr_str;   // no template -> raw
    } else if (n > (int32_t)formatted.size()) {
        formatted.assign(static_cast<size_t>(n + 1), '\0');
        llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, formatted.data(), n + 1);
        formatted.resize(n);
    } else {
        formatted.resize(n);
    }

    // Template already emitted BOS -> add_bos=false.
    std::string out = run_generation(eng, formatted, /*add_bos=*/false, maxTokens, temperature, topK);
    return to_ns(out);
}

+ (NSArray<NSNumber *> *)embedWithHandle:(uint64_t)handle text:(NSString *)text {
    Engine *eng = as_engine(handle);
    if (eng == nullptr || eng->ctx == nullptr) return @[];

    const llama_vocab *vocab = llama_model_get_vocab(eng->model);
    const int n_embd = llama_model_n_embd(eng->model);

    llama_memory_clear(llama_get_memory(eng->ctx), true);

    std::vector<llama_token> tokens = tokenize(vocab, to_std(text), /*add_bos=*/true);
    if (tokens.empty()) return @[];

    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int>(tokens.size()));
    if (llama_decode(eng->ctx, batch) != 0) return @[];

    const float *emb = llama_get_embeddings_seq(eng->ctx, 0);
    if (emb == nullptr) emb = llama_get_embeddings(eng->ctx);   // non-pooling fallback
    if (emb == nullptr) return @[];

    double norm = 0.0;
    for (int i = 0; i < n_embd; ++i) norm += static_cast<double>(emb[i]) * emb[i];
    norm = std::sqrt(norm);
    const float inv = norm > 0.0 ? static_cast<float>(1.0 / norm) : 0.f;

    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:n_embd];
    for (int i = 0; i < n_embd; ++i) [out addObject:@(emb[i] * inv)];
    return out;
}

+ (NSDictionary<NSString *, id> *)benchmarkChatWithHandle:(uint64_t)handle
                                                   system:(NSString *)system
                                                     user:(NSString *)user
                                                maxTokens:(int)maxTokens
                                              temperature:(float)temperature
                                                     topK:(int)topK {
    Engine *eng = as_engine(handle);
    if (eng == nullptr || eng->ctx == nullptr) return @{};

    const llama_vocab *vocab = llama_model_get_vocab(eng->model);
    const std::string sys_str = to_std(system);
    const std::string usr_str = to_std(user);

    std::vector<llama_chat_message> msgs;
    if (!sys_str.empty()) msgs.push_back({"system", sys_str.c_str()});
    msgs.push_back({"user", usr_str.c_str()});

    const char *tmpl = llama_model_chat_template(eng->model, nullptr);
    std::string formatted(8192, '\0');
    int32_t n = tmpl ? llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true,
                                                 formatted.data(), (int32_t)formatted.size())
                     : -1;
    if (n < 0) {
        formatted = (sys_str.empty() ? "" : sys_str + "\n") + usr_str;
    } else if (n > (int32_t)formatted.size()) {
        formatted.assign(static_cast<size_t>(n + 1), '\0');
        llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, formatted.data(), n + 1);
        formatted.resize(n);
    } else {
        formatted.resize(n);
    }

    llama_memory_clear(llama_get_memory(eng->ctx), true);
    std::vector<llama_token> tokens = tokenize(vocab, formatted, /*add_bos=*/false);
    if (tokens.empty()) return @{};
    const int promptTokens = static_cast<int>(tokens.size());

    using clock = std::chrono::steady_clock;
    const auto t0 = clock::now();
    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int>(tokens.size()));
    if (llama_decode(eng->ctx, batch) != 0) return @{};
    const auto t1 = clock::now();

    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(topK > 0 ? topK : 40));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature > 0.f ? temperature : 0.7f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    std::string out;
    int gen = 0;
    for (int i = 0; i < maxTokens; ++i) {
        llama_token tok = llama_sampler_sample(smpl, eng->ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        out += token_to_piece(vocab, tok);
        gen++;
        llama_batch step = llama_batch_get_one(&tok, 1);
        if (llama_decode(eng->ctx, step) != 0) break;
    }
    const auto t2 = clock::now();
    llama_sampler_free(smpl);

    const double prefillMs = std::chrono::duration<double, std::milli>(t1 - t0).count();
    const double genMs = std::chrono::duration<double, std::milli>(t2 - t1).count();

    return @{
        @"text": to_ns(out),
        @"promptTokens": @(promptTokens),
        @"genTokens": @(gen),
        @"prefillMs": @(prefillMs),
        @"genMs": @(genMs),
    };
}

+ (void)freeHandle:(uint64_t)handle {
    Engine *eng = as_engine(handle);
    if (eng == nullptr) return;
    if (eng->ctx) llama_free(eng->ctx);
    if (eng->model) llama_model_free(eng->model);
    delete eng;
}

@end
