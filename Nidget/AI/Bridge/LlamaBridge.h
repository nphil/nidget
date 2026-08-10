#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C++ surface over llama.cpp (Metal/CPU on iOS). Mirrors the Android
/// JNI bridge (llmkit.cpp). A loaded model is referenced by an opaque `uint64_t` handle
/// (0 == failure). All calls are blocking — invoke them off the main thread.
@interface LlamaBridge : NSObject

/// Initialize the ggml/llama backends. Idempotent; safe to call repeatedly.
+ (void)initBackend;

/// Names + descriptions of the ggml devices visible at runtime (e.g. "Metal", "CPU").
+ (NSArray<NSString *> *)probeBackends;

/// Load a GGUF model. `gpuLayers` = layers to offload to the Metal GPU (99 = all, 0 = CPU).
/// `embeddings` configures the context for pooled embeddings instead of generation.
/// Returns an opaque handle, or 0 on failure.
+ (uint64_t)loadModelAtPath:(NSString *)path
                 embeddings:(BOOL)embeddings
                  gpuLayers:(int)gpuLayers;

/// Generate a completion from a raw prompt.
+ (NSString *)generateWithHandle:(uint64_t)handle
                          prompt:(NSString *)prompt
                       maxTokens:(int)maxTokens
                     temperature:(float)temperature
                            topK:(int)topK;

/// Generate a chat completion using the model's built-in chat template.
+ (NSString *)chatWithHandle:(uint64_t)handle
                      system:(NSString *)system
                        user:(NSString *)user
                   maxTokens:(int)maxTokens
                 temperature:(float)temperature
                        topK:(int)topK;

/// Compute a mean-pooled, L2-normalized embedding vector.
+ (NSArray<NSNumber *> *)embedWithHandle:(uint64_t)handle text:(NSString *)text;

/// Like `chat`, but also reports timing + token counts for benchmarking.
/// Returns keys: text (NSString), promptTokens, genTokens, prefillMs, genMs (NSNumber).
+ (NSDictionary<NSString *, id> *)benchmarkChatWithHandle:(uint64_t)handle
                                                   system:(NSString *)system
                                                     user:(NSString *)user
                                                maxTokens:(int)maxTokens
                                              temperature:(float)temperature
                                                     topK:(int)topK;

/// Release a model + context. Safe with a stale/zero handle.
+ (void)freeHandle:(uint64_t)handle;

/// Clear the captured llama.cpp log buffer (call before a load to isolate its messages).
+ (void)clearLog;

/// The recent llama.cpp / ggml log output (model-load errors land here).
+ (NSString *)recentLog;

@end

NS_ASSUME_NONNULL_END
